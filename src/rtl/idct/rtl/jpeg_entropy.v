`default_nettype none
//============================================================================
// jpeg_entropy.v -- baseline JPEG entropy decoder in front of the IDCT core:
// the typed records of the ring (Huffman tables, quantisation tables, scans)
// go here; a scan's entropy-coded segment comes out as dequantised 8x8
// coefficient blocks in the core's block buffer, MCU by MCU (4:2:0: Y0 Y1
// Y2 Y3 Cb Cr), with the same semantics as FFmpeg's mjpegdec.c so the
// pixels are bit-exact with the software decoder:
//   - DC: predictor per component in dequantised units, starting at 1024
//     (FFmpeg's 4 << bits) at the scan start and after every RST marker;
//     block[0] = clip16(diff * q[0] + pred), pred keeps the unclipped value
//   - AC: symbol (run, size); run + 1 positions per symbol, EOB = 0x00,
//     ZRL = 0xF0; a coefficient past position 63 is an error; the product
//     level * q[k] is truncated to 16 bits (FFmpeg stores it into int16)
//   - bytes FF 00 are a data FF, FF D0..D7 restart markers, FF FF fill,
//     any other marker ends the data; past the end the stream reads zeros
//
// Records (the parser has taken the header word; type in header [39:36]):
//   1 Huffman table: id = slot (0 DC 0, 1 DC 1, 2 AC 0, 3 AC 1); bytes =
//     16 + n: the DHT counts BITS[1..16], then the n symbol values
//   2 quantisation table: id = table 0..3; 64 bytes, zigzag order (DQT, 8-bit)
//   3 scan: one parameter word, then `bytes` bytes of entropy-coded data
//     (the bytes between the SOS header and the EOI marker, as in the file)
//       [7:0] MCU columns  [15:8] MCU rows  [31:16] restart interval (MCUs,
//       0 = none)  [32]/[33] Y DC/AC table  [34]/[35] Cb  [36]/[37] Cr
//       [39:38] Y quant table  [41:40] Cb  [43:42] Cr
// Payload bytes are packed eight per 64-bit word, the first in bits [7:0].
//
// Canonical Huffman decoding without code tables: for each code length l
// the table keeps the left-aligned limit (first code of length l + count)
// << (16 - l); the code length is the smallest l whose limit the next 16
// bits are below, the symbol index is offs[l] + code (offs = first index
// of length l - first code, mod 256).  One symbol per four clocks (code
// length; address; symbol; extra bits), the dequantising multiply and the
// block write in a two-stage pipeline behind it.  Corrupt data (no code
// matches, a DC size > 16, a coefficient past 63) raises `err` and the rest
// of the scan record is skipped; every block ends within 64 symbols, so
// nothing a stream contains can hang the core.
//============================================================================
module jpeg_entropy (
    input  wire        clk,
    input  wire        rstn,
    input  wire        srst,
    // a typed record (the parser has popped its header word this cycle)
    input  wire        start,
    input  wire [3:0]  rtype,
    input  wire [1:0]  rid,
    input  wire [23:0] rbytes,
    output wire        busy,
    // the ring FIFO
    input  wire        f_have,
    input  wire [63:0] fw,
    output wire        f_pop,
    // the parser's block buffer
    input  wire        bk_free,            // the engine has read the previous block
    output reg         bk_clear,
    output reg         bk_we,
    output reg  [5:0]  bk_idx,
    output reg  [15:0] bk_data,
    output reg         bk_ready,           // a block is complete in the buffer
    output reg  [1:0]  bk_plane,
    output reg  [11:0] bk_x,
    output reg  [11:0] bk_y,
    input  wire        bk_taken,
    output reg         err
);
    localparam [2:0] S_IDLE = 3'd0, S_DHT = 3'd1, S_DQT = 3'd2, S_PARAM = 3'd3, S_SCAN = 3'd4, S_DRAIN = 3'd5;
    localparam [2:0] H_BWAIT = 3'd0, H_CODE = 3'd1, H_ADDR = 3'd2, H_SYM = 3'd3, H_EXT = 3'd4,
                     H_FIN = 3'd5, H_RDY = 3'd6, H_RST = 3'd7;

    reg  [2:0]  st;
    reg  [2:0]  hs;
    assign busy = (st != S_IDLE);

    // ---- record bytes: one 64-bit word at a time, consumed low cb first ----
    reg  [1:0]  r_id;
    reg  [23:0] left;                       // record bytes not yet loaded
    reg  [63:0] cw;
    reg  [3:0]  cw_n;                       // valid bytes in cw
    wire        cw_empty = (cw_n == 4'd0);
    wire        rec_end  = cw_empty && (left == 24'd0);
    wire [7:0]  cb     = cw[7:0];
    wire [3:0]  ld_n     = (left >= 24'd8) ? 4'd8 : left[3:0];
    wire        ld       = (st == S_DHT || st == S_DQT || st == S_SCAN) && cw_empty && left != 24'd0 && f_have;
    wire        dr_pop   = (st == S_DRAIN) && cw_empty && left != 24'd0 && f_have;
    wire        pa_pop   = (st == S_PARAM) && f_have;
    assign f_pop = ld | dr_pop | pa_pop;

    // ---- tables ----
    reg  [16:0] lim16 [0:63];               // {slot, l-1}: left-aligned code limit
    reg  [7:0]  offs  [0:63];               // {slot, l-1}: symbol index - code
    reg  [8:0]  bidx;                       // cb index in a table record
    reg  [17:0] hcode;                      // canonical code construction
    reg  [8:0]  hk;
    wire [17:0] h_lim = hcode + {10'd0, cb};
    wire [32:0] h_lsh = {15'd0, h_lim} << (4'd15 - bidx[3:0]);   // left-aligned to 16 bits
    // symbol values: {slot, index}
    wire        hv_we = (st == S_DHT) && !cw_empty && bidx >= 9'd16;
    wire [7:0]  hv_rdata;
    reg  [9:0]  hv_raddr;
    idct_ram #(.ADDR_WIDTH(10), .WORD_WIDTH(8)) u_hv (.clk(clk), .wren(hv_we),
        .write_addr({r_id, bidx[7:0] - 8'd16}), .write_data(cb), .read_addr(hv_raddr), .read_data(hv_rdata));
    // quantisation: {table, zigzag position}
    wire        q_we = (st == S_DQT) && !cw_empty && bidx < 9'd64;
    wire [7:0]  q_rdata;
    reg  [7:0]  q_raddr;
    idct_ram #(.ADDR_WIDTH(8), .WORD_WIDTH(8)) u_q (.clk(clk), .wren(q_we),
        .write_addr({r_id, bidx[5:0]}), .write_data(cb), .read_addr(q_raddr), .read_data(q_rdata));

    // ---- scan state ----
    reg  [7:0]  mcux, mcuy, mx, my;
    reg  [15:0] ri, rcnt;
    reg  [2:0]  bi;                         // block in the MCU
    reg  [5:0]  tsel_bits;                  // {Cr Ta, Cr Td, Cb Ta, Cb Td, Y Ta, Y Td}
    reg  [5:0]  tq_bits;                    // {Cr, Cb, Y} quant tables
    reg  signed [31:0] last_dc [0:2];
    reg  [63:0] bb;                         // bit buffer, next bit in [63]
    reg  [6:0]  bn;                         // valid bits
    reg         ffp, mk, eos;               // FF seen; RST marker reached; other marker
    reg         dcph;                       // decoding the DC symbol
    reg  [6:0]  kk;                         // zigzag position of the last coefficient
    reg  [4:0]  L_r;                        // code length 1..16
    reg  [15:0] code_r;                     // the 16 bits the code was read from
    reg  [7:0]  sym_r;
    reg  [1:0]  fin;

    wire [1:0]  comp = (bi[2] == 1'b0) ? 2'd0 : (bi[0] ? 2'd2 : 2'd1);    // 0-3 Y, 4 Cb, 5 Cr
    wire        td   = tsel_bits[{comp, 1'b0}];
    wire        ta   = tsel_bits[{comp, 1'b1}];
    wire [1:0]  tsel = dcph ? {1'b0, td} : {1'b1, ta};
    wire [1:0]  tq   = tq_bits[{comp, 1'b0} +: 2];
    wire        blocked = mk || eos || rec_end;

    // code length: the smallest l whose limit the window is below
    wire [15:0] win = bb[63:48];
    reg  [4:0]  L_c;
    integer l;
    always @(*) begin
        L_c = 5'd0;
        for (l = 16; l >= 1; l = l - 1)
            if ({1'b0, win} < lim16[{tsel, l[3:0] - 4'd1}]) L_c = l[4:0];
    end
    // symbol address (from registers only: stable from H_ADDR through H_SYM)
    wire [15:0] code_sh = code_r >> (5'd16 - L_r);
    always @(*) hv_raddr = {tsel, offs[{tsel, L_r[3:0] - 4'd1}] + code_sh[7:0]};

    // extra bits of the symbol in sym_r
    wire        is_dc  = dcph;
    wire [4:0]  s_len  = is_dc ? sym_r[4:0] : {1'b0, sym_r[3:0]};
    wire [3:0]  s_run  = sym_r[7:4];
    wire        dc_bad = is_dc && (sym_r > 8'd16);
    wire        eob    = !is_dc && (sym_r == 8'd0);
    wire        ext_ok = (bn >= {2'b00, s_len});
    wire [15:0] xv     = (s_len == 5'd0) ? 16'd0 : (win >> (5'd16 - s_len));
    wire [16:0] xmask  = (17'd1 << s_len) - 17'd1;
    wire        xmsb   = (s_len == 5'd0) ? 1'b1 : xv[s_len - 5'd1];
    wire signed [17:0] level = xmsb ? $signed({2'b00, xv}) : ($signed({2'b00, xv}) - $signed({1'b0, xmask}));
    wire [6:0]  knew   = kk + {3'b000, s_run} + 7'd1;
    wire        take_ext = (st == S_SCAN) && (hs == H_EXT) && !dc_bad && !eob && ext_ok;
    always @(*) q_raddr = {tq, is_dc ? 6'd0 : knew[5:0]};

    // decoder bit consumption this cycle (the refill yields to it)
    wire        dec_consume = (st == S_SCAN) && ((hs == H_ADDR) || take_ext);
    wire [4:0]  c_amt = (hs == H_ADDR) ? L_r : s_len;

    // dequantise / write pipeline
    reg         dq_v, dq_dc;
    reg  [1:0]  dq_c;
    reg  signed [17:0] dq_lvl;
    reg  [5:0]  dq_j;
    reg         w_v, w_dc;
    reg  [1:0]  w_c;
    reg  signed [26:0] w_prod;
    reg  [5:0]  w_j;
    wire signed [31:0] dc_val = {{5{w_prod[26]}}, w_prod} + last_dc[w_c];

    function [5:0] zz(input [5:0] k);       // zigzag position -> natural index
        case (k)
            6'd0: zz = 0;   6'd1: zz = 1;   6'd2: zz = 8;   6'd3: zz = 16;  6'd4: zz = 9;   6'd5: zz = 2;   6'd6: zz = 3;   6'd7: zz = 10;
            6'd8: zz = 17;  6'd9: zz = 24;  6'd10: zz = 32; 6'd11: zz = 25; 6'd12: zz = 18; 6'd13: zz = 11; 6'd14: zz = 4;  6'd15: zz = 5;
            6'd16: zz = 12; 6'd17: zz = 19; 6'd18: zz = 26; 6'd19: zz = 33; 6'd20: zz = 40; 6'd21: zz = 48; 6'd22: zz = 41; 6'd23: zz = 34;
            6'd24: zz = 27; 6'd25: zz = 20; 6'd26: zz = 13; 6'd27: zz = 6;  6'd28: zz = 7;  6'd29: zz = 14; 6'd30: zz = 21; 6'd31: zz = 28;
            6'd32: zz = 35; 6'd33: zz = 42; 6'd34: zz = 49; 6'd35: zz = 56; 6'd36: zz = 57; 6'd37: zz = 50; 6'd38: zz = 43; 6'd39: zz = 36;
            6'd40: zz = 29; 6'd41: zz = 22; 6'd42: zz = 15; 6'd43: zz = 23; 6'd44: zz = 30; 6'd45: zz = 37; 6'd46: zz = 44; 6'd47: zz = 51;
            6'd48: zz = 58; 6'd49: zz = 59; 6'd50: zz = 52; 6'd51: zz = 45; 6'd52: zz = 38; 6'd53: zz = 31; 6'd54: zz = 39; 6'd55: zz = 46;
            6'd56: zz = 53; 6'd57: zz = 60; 6'd58: zz = 61; 6'd59: zz = 54; 6'd60: zz = 47; 6'd61: zz = 55; 6'd62: zz = 62; default: zz = 63;
        endcase
    endfunction

    function [15:0] clip16(input signed [31:0] v);
        clip16 = (v > 32'sd32767) ? 16'h7FFF : (v < -32'sd32768) ? 16'h8000 : v[15:0];
    endfunction

    integer i;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            st <= S_IDLE; hs <= H_BWAIT; r_id <= 0; left <= 0; cw <= 0; cw_n <= 0; bidx <= 0; hcode <= 0; hk <= 0;
            for (i = 0; i < 64; i = i + 1) begin lim16[i] <= 17'd0; offs[i] <= 8'd0; end
            mcux <= 0; mcuy <= 0; mx <= 0; my <= 0; ri <= 0; rcnt <= 0; bi <= 0; tsel_bits <= 0; tq_bits <= 0;
            for (i = 0; i < 3; i = i + 1) last_dc[i] <= 32'sd1024;
            bb <= 0; bn <= 0; ffp <= 0; mk <= 0; eos <= 0; dcph <= 0; kk <= 0; L_r <= 5'd1; code_r <= 0; sym_r <= 0; fin <= 0;
            dq_v <= 0; dq_dc <= 0; dq_c <= 0; dq_lvl <= 0; dq_j <= 0; w_v <= 0; w_dc <= 0; w_c <= 0; w_prod <= 0; w_j <= 0;
            bk_clear <= 0; bk_we <= 0; bk_idx <= 0; bk_data <= 0; bk_ready <= 0; bk_plane <= 0; bk_x <= 0; bk_y <= 0; err <= 0;
        end else if (srst) begin
            st <= S_IDLE; hs <= H_BWAIT; cw_n <= 0; left <= 0; dq_v <= 0; w_v <= 0;
            bk_clear <= 0; bk_we <= 0; bk_ready <= 0; err <= 0;
        end else begin
            bk_clear <= 1'b0;
            bk_we    <= 1'b0;
            err      <= 1'b0;

            // ---- dequantise (W1) and block write (W2) ----
            dq_v <= 1'b0;
            w_v  <= dq_v;
            if (dq_v) begin
                w_prod <= dq_lvl * $signed({1'b0, q_rdata});
                w_dc <= dq_dc; w_c <= dq_c; w_j <= dq_j;
            end
            if (w_v) begin
                bk_we <= 1'b1;
                if (w_dc) begin
                    last_dc[w_c] <= dc_val;
                    bk_idx  <= 6'd0;
                    bk_data <= clip16(dc_val);
                end else begin
                    bk_idx  <= w_j;
                    bk_data <= w_prod[15:0];
                end
            end

            // ---- word loader ----
            if (ld) begin
                cw <= fw; cw_n <= ld_n; left <= left - {20'd0, ld_n};
            end

            case (st)
            S_IDLE: if (start) begin
                r_id <= rid; left <= rbytes; cw_n <= 4'd0; bidx <= 9'd0; hcode <= 18'd0; hk <= 9'd0;
                case (rtype)
                    4'd1: st <= S_DHT;
                    4'd2: st <= S_DQT;
                    4'd3: st <= S_PARAM;
                    default: st <= S_DRAIN;
                endcase
            end
            S_DHT: begin
                if (!cw_empty) begin
                    if (bidx < 9'd16) begin             // BITS[l]: the codes of length l
                        lim16[{r_id, bidx[3:0]}] <= h_lsh[16:0];
                        offs[{r_id, bidx[3:0]}]  <= hk[7:0] - hcode[7:0];
                        hk    <= hk + {1'b0, cb};
                        hcode <= {h_lim[16:0], 1'b0};
                    end
                    cw <= cw >> 8; cw_n <= cw_n - 4'd1; bidx <= bidx + 9'd1;
                end else if (rec_end) st <= S_IDLE;
            end
            S_DQT: begin
                if (!cw_empty) begin
                    cw <= cw >> 8; cw_n <= cw_n - 4'd1; bidx <= bidx + 9'd1;
                end else if (rec_end) st <= S_IDLE;
            end
            S_PARAM: if (f_have) begin
                mcux <= fw[7:0]; mcuy <= fw[15:8]; ri <= fw[31:16]; rcnt <= fw[31:16];
                tsel_bits <= fw[37:32]; tq_bits <= fw[43:38];
                mx <= 0; my <= 0; bi <= 0;
                for (i = 0; i < 3; i = i + 1) last_dc[i] <= 32'sd1024;
                bb <= 0; bn <= 0; ffp <= 0; mk <= 0; eos <= 0;
                hs <= H_BWAIT;
                st <= (fw[7:0] == 8'd0 || fw[15:8] == 8'd0) ? S_DRAIN : S_SCAN;
            end
            S_SCAN: begin
                // ---- bit buffer: consumption, else refill / restart drop ----
                if (dec_consume) begin
                    bb <= bb << c_amt;
                    bn <= bn - {2'b00, c_amt};
                end else if (hs == H_RST) begin
                    if (!blocked && !cw_empty) begin    // drop bytes up to the marker
                        cw <= cw >> 8; cw_n <= cw_n - 4'd1;
                        if (ffp) begin
                            ffp <= (cb == 8'hFF);
                            if (cb[7:3] == 5'b11010) mk <= 1'b1;
                            else if (cb != 8'h00 && cb != 8'hFF) eos <= 1'b1;
                        end else if (cb == 8'hFF) ffp <= 1'b1;
                    end
                end else if (bn <= 7'd56) begin
                    if (!blocked && !cw_empty) begin
                        cw <= cw >> 8; cw_n <= cw_n - 4'd1;
                        if (ffp) begin
                            ffp <= (cb == 8'hFF);
                            if (cb == 8'h00) begin                     // stuffed: a data FF
                                bb <= bb | ({8'hFF, 56'd0} >> bn); bn <= bn + 7'd8;
                            end else if (cb[7:3] == 5'b11010) mk <= 1'b1;   // RSTn
                            else if (cb != 8'hFF) eos <= 1'b1;             // another marker
                        end else if (cb == 8'hFF) begin
                            ffp <= 1'b1;
                        end else begin
                            bb <= bb | ({cb, 56'd0} >> bn); bn <= bn + 7'd8;
                        end
                    end else if (blocked) begin
                        bn <= bn + 7'd8;                // past the data: zeros
                    end
                end

                // ---- decoder ----
                case (hs)
                H_BWAIT: if (bk_free) begin
                    bk_clear <= 1'b1;
                    dcph <= 1'b1; kk <= 7'd0;
                    hs <= H_CODE;
                end
                H_CODE: if (bn >= 7'd16) begin
                    if (L_c == 5'd0) begin err <= 1'b1; st <= S_DRAIN; end
                    else begin L_r <= L_c; code_r <= win; hs <= H_ADDR; end
                end
                H_ADDR: hs <= H_SYM;                    // L_r bits consumed, symbol read issued
                H_SYM: begin sym_r <= hv_rdata; hs <= H_EXT; end
                H_EXT: begin
                    if (dc_bad) begin
                        err <= 1'b1; st <= S_DRAIN;
                    end else if (eob) begin
                        fin <= 2'd3; hs <= H_FIN;
                    end else if (ext_ok) begin
                        if (is_dc) begin
                            dq_v <= 1'b1; dq_dc <= 1'b1; dq_c <= comp; dq_lvl <= level; dq_j <= 6'd0;
                            dcph <= 1'b0; kk <= 7'd0;
                            hs <= H_CODE;
                        end else if (s_len == 5'd0) begin         // ZRL (or run-only symbol)
                            kk <= knew;
                            if (knew >= 7'd63) begin fin <= 2'd3; hs <= H_FIN; end
                            else hs <= H_CODE;
                        end else if (knew > 7'd63) begin
                            err <= 1'b1; st <= S_DRAIN;
                        end else begin
                            dq_v <= 1'b1; dq_dc <= 1'b0; dq_c <= comp; dq_lvl <= level; dq_j <= zz(knew[5:0]);
                            kk <= knew;
                            if (knew == 7'd63) begin fin <= 2'd3; hs <= H_FIN; end
                            else hs <= H_CODE;
                        end
                    end
                end
                H_FIN: begin                            // the last writes land in the buffer
                    if (fin == 2'd0) begin
                        bk_ready <= 1'b1;
                        bk_plane <= comp;
                        bk_x <= (comp == 2'd0) ? {mx, bi[0], 3'b000} : {1'b0, mx, 3'b000};
                        bk_y <= (comp == 2'd0) ? {my, bi[1], 3'b000} : {1'b0, my, 3'b000};
                        hs <= H_RDY;
                    end else fin <= fin - 2'd1;
                end
                H_RDY: if (bk_taken) begin
                    bk_ready <= 1'b0;
                    if (bi == 3'd5) begin
                        bi <= 3'd0;
                        if (mx == mcux - 8'd1 && my == mcuy - 8'd1) begin
                            st <= S_DRAIN;                      // the scan is complete
                        end else begin
                            if (mx == mcux - 8'd1) begin mx <= 8'd0; my <= my + 8'd1; end
                            else mx <= mx + 8'd1;
                            if (ri != 16'd0 && rcnt == 16'd1) begin rcnt <= ri; hs <= H_RST; end
                            else begin
                                if (ri != 16'd0) rcnt <= rcnt - 16'd1;
                                hs <= H_BWAIT;
                            end
                        end
                    end else begin
                        bi <= bi + 3'd1;
                        hs <= H_BWAIT;
                    end
                end
                H_RST: if (blocked) begin               // at the marker: cb-aligned restart
                    bb <= 64'd0; bn <= 7'd0; mk <= 1'b0; ffp <= 1'b0;
                    for (i = 0; i < 3; i = i + 1) last_dc[i] <= 32'sd1024;
                    hs <= H_BWAIT;
                end
                default: hs <= H_BWAIT;
                endcase
            end
            S_DRAIN: begin                              // skip what is left of the record
                if (!cw_empty) cw_n <= 4'd0;
                else if (left != 24'd0) begin
                    if (f_have) left <= left - {20'd0, ld_n};
                end else st <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
