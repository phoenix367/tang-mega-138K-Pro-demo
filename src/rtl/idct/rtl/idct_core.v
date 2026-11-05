`default_nettype none
//============================================================================
// idct_core.v -- hardware 8x8 inverse DCT with frame assembly for the JPEG
// (MJPEG) decoder: the CPU keeps the Huffman decoding and dequantisation,
// the core does the IDCT and writes the pixels into the YUV 4:2:0 planes.
//
//   CPU --EXTS--> registers                           EXTM (AHB-lite 64-bit,
//   DRAM ring of coefficient records --> reader --+    through the arbiter)
//                                                 v
//             parser -> block (64 x int16) -> 2-D IDCT (idct_1d: rows, then
//             columns through a transpose buffer) -> band RAM (one MCU band
//             per plane: 16 luma / 8 chroma lines of up to 2048 / 1024
//             pixels) -> flush engine -> DRAM
//
// Records in the ring (64-bit words, little-endian, any number of them, the
// ring wraps at RING_MASK + 1 bytes):
//   word 0  [6:0] n = coefficients that follow (0..64, natural order, the
//           rest of the block is zero)  [7] flush this plane's band after
//           the block  [9:8] plane (0 Y, 1 U, 2 V)  [21:10] x  [33:22] y
//           (pixels, multiples of 8)  [34] interrupt after that flush
//           [35] no block: only flush the plane's band if it is dirty (x, y
//           and n ignored, n = 0) -- the end of a frame, whatever came last
//           [39:36] record type: 0 = this coefficient block; 1..3 = JPEG
//           records for the entropy decoder (jpeg_entropy.v: Huffman table,
//           quantisation table, scan), [9:8] their table id, [63:40] their
//           payload bytes; 4..15 = bad record (skipped, nothing follows)
//   words 1.. ceil(n/4) x four int16 coefficients, low half first
// The CPU writes TAIL past the last record it wrote (and has written back
// from its cache); the core consumes up to TAIL and reports HEAD.  A block
// whose band differs from the band the plane holds flushes that band first,
// so correctness never depends on the flush flags; the flags only decide
// when the last band of a frame lands.  When everything up to TAIL has been
// processed and flushed the core is idle (STATUS.busy = 0) and raises the
// done interrupt once.
//
// Band flushes are the point: the IDCT output goes to DRAM as whole lines
// in 128-byte bursts instead of the 8 scattered rows of every block, which
// is what made the software decoder memory-bound on the A25.
//
// Registers (EXTS, CPU base 0xE8040000, zero wait states):
//   0x00 CTRL      rw  [0] enable  [1] reset (self-clearing: pointers, state)
//                      [2] done interrupt enable  [3] band interrupt enable
//   0x04 STATUS    rw1c [0] busy  [1] done irq  [2] band irq  [3] bad record
//                      (or corrupt JPEG data)  [8] ro 1: JPEG records supported
//                      [9] ro 1: frames up to 2048 wide (before: up to 1024)
//   0x08 RING_BASE rw  byte address, 8-byte aligned
//   0x0C RING_MASK rw  ring size - 1 (size a power of two >= 64 bytes)
//   0x10 TAIL      rw  byte offset in the ring, 8-byte aligned
//   0x14 HEAD      ro  byte offset the core has consumed up to
//   0x18 Y_BASE    rw  plane addresses (8-byte aligned)
//   0x1C U_BASE    rw
//   0x20 V_BASE    rw
//   0x24 STRIDES   rw  [15:0] luma stride  [31:16] chroma stride (bytes, x8)
//   0x28 SIZE      rw  [15:0] width  [31:16] height (luma pixels; width x16,
//                      <= 2048; chroma planes are half of both)
//   0x2C BLOCKS    ro  blocks transformed
//   0x30 BANDS     ro  bands flushed
//   0x34 ID        ro  0x49444354 ("IDCT")
//============================================================================
module idct_core (
    input  wire         hclk,
    input  wire         hresetn,
    // AHB-lite slave: registers (EXTS)
    input  wire [31:0]  s_haddr,
    input  wire [1:0]   s_htrans,
    input  wire         s_hwrite,
    input  wire         s_hsel,
    input  wire         s_hready_in,
    input  wire [31:0]  s_hwdata,
    output wire [31:0]  s_hrdata,
    output wire         s_hready,
    output wire         s_hresp,
    // AHB-lite master (64-bit) to the EXTM arbiter
    output wire         m_busy,
    output wire [31:0]  m_haddr,
    output wire [1:0]   m_htrans,
    output wire         m_hwrite,
    output wire [2:0]   m_hsize,
    output wire [2:0]   m_hburst,
    output wire [63:0]  m_hwdata,
    input  wire [63:0]  m_hrdata,
    input  wire         m_hready,
    input  wire         m_hresp,
    output wire         irq
);
    // ======================================================================
    // registers
    // ======================================================================
    assign s_hready = 1'b1;
    assign s_hresp  = 1'b0;
    reg  [5:0]  a_off;
    reg         a_wr, a_sel;
    wire        a_active = s_hsel && s_hready_in && s_htrans[1];

    reg         enable, irq_en_done, irq_en_band, soft_rst;
    reg         done_irq, band_irq, bad_rec;
    reg  [31:0] ring_base, ring_mask, tail, head;
    reg  [31:0] y_base, u_base, v_base;
    reg  [15:0] y_stride, c_stride, width, height;
    reg  [31:0] blocks, bands;
    reg         work;                       // a TAIL write since the last done interrupt
    wire        busy;                       // below
    wire        set_done, set_band, set_bad; // from the engines

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off <= 0; a_wr <= 0; a_sel <= 0;
            enable <= 0; irq_en_done <= 0; irq_en_band <= 0; soft_rst <= 0;
            done_irq <= 0; band_irq <= 0; bad_rec <= 0; work <= 0;
            ring_base <= 0; ring_mask <= 32'h3F; tail <= 0;
            y_base <= 0; u_base <= 0; v_base <= 0;
            y_stride <= 16'd800; c_stride <= 16'd416; width <= 16'd800; height <= 16'd480;
        end else begin
            a_off <= s_haddr[7:2]; a_wr <= s_hwrite; a_sel <= a_active;
            soft_rst <= 1'b0;
            if (set_done && work) begin done_irq <= 1'b1; work <= 1'b0; end
            if (set_band) band_irq <= 1'b1;
            if (set_bad)  bad_rec  <= 1'b1;
            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00: begin enable <= s_hwdata[0]; soft_rst <= s_hwdata[1];
                                 irq_en_done <= s_hwdata[2]; irq_en_band <= s_hwdata[3]; end
                    6'h01: begin if (s_hwdata[1]) done_irq <= 1'b0; if (s_hwdata[2]) band_irq <= 1'b0;
                                 if (s_hwdata[3]) bad_rec <= 1'b0; end
                    6'h02: ring_base <= {s_hwdata[31:3], 3'b000};
                    6'h03: ring_mask <= {s_hwdata[31:3], 3'b111};
                    6'h04: begin tail <= {s_hwdata[31:3], 3'b000}; work <= 1'b1; end
                    6'h06: y_base <= {s_hwdata[31:3], 3'b000};
                    6'h07: u_base <= {s_hwdata[31:3], 3'b000};
                    6'h08: v_base <= {s_hwdata[31:3], 3'b000};
                    6'h09: begin y_stride <= {s_hwdata[15:3], 3'b000}; c_stride <= {s_hwdata[31:19], 3'b000}; end
                    6'h0A: begin width <= {s_hwdata[15:4], 4'b0000}; height <= s_hwdata[31:16]; end
                    default: ;
                endcase
            end
        end
    end

    reg [31:0] rd;
    always @(*) begin
        case (a_off)
            6'h00: rd = {28'b0, irq_en_band, irq_en_done, 1'b0, enable};
            6'h01: rd = {22'b0, 1'b1, 1'b1, 4'b0, bad_rec, band_irq, done_irq, busy};
            6'h02: rd = ring_base;
            6'h03: rd = ring_mask;
            6'h04: rd = tail;
            6'h05: rd = head;
            6'h06: rd = y_base;
            6'h07: rd = u_base;
            6'h08: rd = v_base;
            6'h09: rd = {c_stride, y_stride};
            6'h0A: rd = {height, width};
            6'h0B: rd = blocks;
            6'h0C: rd = bands;
            6'h0D: rd = 32'h4944_4354;
            default: rd = 32'h0;
        endcase
    end
    assign s_hrdata = rd;
    assign irq = (done_irq & irq_en_done) | (band_irq & irq_en_band);

    // ======================================================================
    // the shared AHB master: reads for the ring reader, writes for the flush
    // ======================================================================
    wire        cmd_ready, cmd_done, cmd_err, w_req, r_valid;
    wire [63:0] r_data;
    reg         rd_cmd, fl_cmd;             // command requests
    reg  [31:0] rd_addr, fl_addr;
    reg  [15:0] rd_len, fl_len;
    wire [63:0] fl_wdata;
    wire        cmd_valid = fl_cmd | rd_cmd;
    ahb_master #(.ADDR_W(32), .DATA_W(64), .MAX_BURST(16)) u_m (
        .hclk(hclk), .hresetn(hresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(fl_cmd ? fl_addr : rd_addr), .cmd_len(fl_cmd ? fl_len : rd_len), .cmd_wr(fl_cmd),
        .cmd_done(cmd_done), .cmd_err(cmd_err), .busy(m_busy),
        .w_req(w_req), .w_data(fl_wdata), .r_valid(r_valid), .r_data(r_data),
        .haddr(m_haddr), .htrans(m_htrans), .hwrite(m_hwrite), .hsize(m_hsize), .hburst(m_hburst),
        .hwdata(m_hwdata), .hrdata(m_hrdata), .hready(m_hready), .hresp(m_hresp)
    );

    // ======================================================================
    // ring reader: bursts of up to 16 words into a 32-word FIFO
    // ======================================================================
    reg  [63:0] fifo [0:31];
    reg  [4:0]  f_wp, f_rp;
    reg  [5:0]  f_cnt;
    wire        f_pop;                      // parser takes fifo[f_rp]
    reg         rd_active;                  // a read command is in flight
    reg  [15:0] rd_beats;
    wire [31:0] avail = (tail - head) & ring_mask;             // bytes to read
    wire [31:0] to_end = ring_mask + 32'd1 - head;             // bytes to the ring end
    wire [31:0] want = avail < to_end ? avail : to_end;
    wire [15:0] want_beats = want[18:3] > 16'd16 ? 16'd16 : want[18:3];
    wire        flush_busy;                 // below
    integer k;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            f_wp <= 0; f_rp <= 0; f_cnt <= 0; rd_cmd <= 0; rd_addr <= 0; rd_len <= 0; rd_active <= 0; rd_beats <= 0;
            head <= 0;
        end else if (soft_rst) begin
            f_wp <= 0; f_rp <= 0; f_cnt <= 0; rd_cmd <= 0; rd_active <= 0; head <= 0;
        end else begin
            if (r_valid) begin fifo[f_wp] <= r_data; f_wp <= f_wp + 5'd1; end
            if (f_pop) f_rp <= f_rp + 5'd1;
            f_cnt <= f_cnt + (r_valid ? 6'd1 : 6'd0) - (f_pop ? 6'd1 : 6'd0);
            if (!rd_active) begin
                // a burst only when the FIFO can take all of it and no flush is pending
                if (enable && want_beats != 0 && f_cnt <= 6'd16 && !fl_req && !flush_busy && cmd_ready && !rd_cmd) begin
                    rd_cmd   <= 1'b1;
                    rd_addr  <= ring_base + head;
                    rd_len   <= want_beats;
                    rd_beats <= want_beats;
                end
                // accepted when the master is ready and the flush is not using it
                if (rd_cmd && cmd_ready && !fl_cmd) begin rd_cmd <= 1'b0; rd_active <= 1'b1; end
            end else if (cmd_done) begin
                rd_active <= 1'b0;
                head <= (head + {rd_beats, 3'b000}) & ring_mask;
            end
        end
    end

    // ======================================================================
    // parser -> block buffer; band bookkeeping; engine handshake
    // ======================================================================
    localparam [3:0] P_IDLE = 4'd0, P_HDR = 4'd1, P_COEF = 4'd2, P_BAND = 4'd3, P_RUN = 4'd4, P_POST = 4'd5, P_FLUSH = 4'd6,
                     P_JPEG = 4'd7, P_JBLK = 4'd8;
    reg  [3:0]  pst;
    reg         r_jpeg;                     // the block in the buffer came from the entropy decoder
    reg  [15:0] blk [0:63];
    reg  [6:0]  n_coef, c_idx;
    reg         r_flush, r_irq;
    reg  [1:0]  r_plane;
    reg  [11:0] r_x, r_y;
    wire [63:0] fw = fifo[f_rp];
    wire        f_have = (f_cnt != 0);
    // bands held by each plane
    reg         band_dirty [0:2];
    reg  [11:0] band_y0 [0:2];
    reg         band_irq_req [0:2];
    wire [11:0] r_y0 = (r_plane == 2'd0) ? {r_y[11:4], 4'b0} : {r_y[11:3], 3'b0};
    // flush requests
    reg         fl_req;
    reg  [1:0]  fl_plane;
    wire        fl_done;
    // engine
    reg         eng_start;
    wire        eng_done, eng_busy;
    wire        eng_reading;                // the engine reads blk[] (E_ROWS)

    // JPEG entropy decoder (typed records)
    wire [3:0]  h_type  = fw[39:36];
    wire        j_start = (pst == P_HDR) && f_have && h_type != 4'd0 && h_type <= 4'd3;
    wire        j_busy, j_pop, j_clear, j_we, j_ready, j_err;
    wire [5:0]  j_idx;
    wire [15:0] j_data;
    wire [1:0]  j_plane;
    wire [11:0] j_x, j_y;
    wire        band_go;                    // P_BAND starts the engine this cycle
    wire        j_taken = band_go && r_jpeg;
    jpeg_entropy u_je (
        .clk(hclk), .rstn(hresetn), .srst(soft_rst),
        .start(j_start), .rtype(h_type), .rid(fw[9:8]), .rbytes(fw[63:40]), .busy(j_busy),
        .f_have(f_have && pst == P_JPEG), .fw(fw), .f_pop(j_pop),
        .bk_free(!eng_start && !eng_reading), .bk_clear(j_clear), .bk_we(j_we), .bk_idx(j_idx), .bk_data(j_data),
        .bk_ready(j_ready), .bk_plane(j_plane), .bk_x(j_x), .bk_y(j_y), .bk_taken(j_taken), .err(j_err)
    );

    assign f_pop = (pst == P_HDR && f_have) || (pst == P_COEF && f_have) || (pst == P_JPEG && j_pop);
    assign band_go = (pst == P_BAND) && !(n_coef > 7'd64 || r_plane == 2'd3) &&
                     !(band_dirty[r_plane] && band_y0[r_plane] != r_y0) && !fl_req && !eng_busy;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pst <= P_IDLE; n_coef <= 0; c_idx <= 0; r_flush <= 0; r_irq <= 0; r_plane <= 0; r_x <= 0; r_y <= 0; r_jpeg <= 0;
            for (k = 0; k < 64; k = k + 1) blk[k] <= 16'd0;
            for (k = 0; k < 3; k = k + 1) begin band_dirty[k] <= 1'b0; band_y0[k] <= 12'd0; band_irq_req[k] <= 1'b0; end
            fl_req <= 0; fl_plane <= 0; eng_start <= 0; blocks <= 0;
        end else if (soft_rst) begin
            pst <= P_IDLE; fl_req <= 0; eng_start <= 0; blocks <= 0;
            for (k = 0; k < 3; k = k + 1) band_dirty[k] <= 1'b0;
        end else begin
            eng_start <= 1'b0;
            if (fl_done) begin band_dirty[fl_plane] <= 1'b0; band_irq_req[fl_plane] <= 1'b0; fl_req <= 1'b0; end
            if (eng_done) blocks <= blocks + 32'd1;
            // the entropy decoder writes the block buffer (only while it owns it)
            if (j_clear) for (k = 0; k < 64; k = k + 1) blk[k] <= 16'd0;
            if (j_we) blk[j_idx] <= j_data;
            case (pst)
            // a header may clear / refill blk[]: not while the engine still reads it
            P_IDLE: if (enable && f_have && !fl_req && !eng_start && !eng_reading) pst <= P_HDR;
            P_HDR: if (f_have) begin                    // header word
                n_coef  <= fw[6:0];
                r_flush <= fw[7];
                r_plane <= fw[9:8];
                r_x     <= fw[21:10];
                r_y     <= fw[33:22];
                r_irq   <= fw[34];
                r_jpeg  <= 1'b0;
                c_idx   <= 7'd0;
                if (h_type == 4'd0) begin
                    for (k = 0; k < 64; k = k + 1) blk[k] <= 16'd0;
                    pst <= fw[35] ? P_FLUSH : (fw[6:0] == 7'd0) ? P_BAND : P_COEF;
                end else if (h_type <= 4'd3) pst <= P_JPEG;   // the entropy decoder takes the record
                else pst <= P_IDLE;                           // unknown type: bad record
            end
            P_JPEG: begin
                if (j_ready) pst <= P_JBLK;
                else if (!j_busy) pst <= P_IDLE;
            end
            P_JBLK: if (!eng_busy && !eng_start) begin  // the previous block is in the band RAM
                r_plane <= j_plane; r_x <= j_x; r_y <= j_y;
                n_coef <= 7'd0; r_flush <= 1'b0; r_irq <= 1'b0; r_jpeg <= 1'b1;
                pst <= P_BAND;
            end
            P_FLUSH: if (!fl_req && !eng_busy && !eng_start) begin   // flush-only record: after the last block is in the band RAM
                if (r_plane != 2'd3 && band_dirty[r_plane]) begin
                    fl_req <= 1'b1; fl_plane <= r_plane; band_irq_req[r_plane] <= r_irq;
                end
                pst <= P_IDLE;
            end
            P_COEF: if (f_have) begin                   // four coefficients per word
                for (k = 0; k < 4; k = k + 1)
                    if (c_idx + k < n_coef && c_idx + k < 64) blk[c_idx + k] <= fw[16*k +: 16];
                c_idx <= c_idx + 7'd4;
                if (c_idx + 7'd4 >= n_coef) pst <= P_BAND;
            end
            P_BAND: begin                               // the block's band: flush a different one first
                if (n_coef > 7'd64 || r_plane == 2'd3) begin
                    pst <= P_IDLE;                      // bad record: skipped (STATUS.bad)
                end else if (band_dirty[r_plane] && band_y0[r_plane] != r_y0) begin
                    if (!fl_req) begin fl_req <= 1'b1; fl_plane <= r_plane; end
                end else if (!fl_req && !eng_busy) begin
                    band_dirty[r_plane] <= 1'b1;
                    band_y0[r_plane]    <= r_y0;
                    eng_start <= 1'b1;
                    pst <= r_jpeg ? P_JPEG : P_RUN;     // a JPEG block: decode the next one meanwhile
                end
            end
            P_RUN: if (eng_done) pst <= P_POST;
            P_POST: begin                               // the record's own flush request
                if (r_flush && !fl_req) begin
                    fl_req <= 1'b1; fl_plane <= r_plane; band_irq_req[r_plane] <= r_irq;
                end
                pst <= P_IDLE;
            end
            default: pst <= P_IDLE;
            endcase
        end
    end
    assign set_bad = ((pst == P_BAND) && (n_coef > 7'd64 || r_plane == 2'd3)) ||
                     ((pst == P_HDR) && f_have && h_type > 4'd3) || j_err;

    // ======================================================================
    // 2-D engine: 8 rows through idct_1d into the transpose buffer, 8 columns
    // through idct_1d into the output block, 8 row writes into the band RAM
    // ======================================================================
    localparam [2:0] E_IDLE = 3'd0, E_ROWS = 3'd1, E_RWAIT = 3'd2, E_COLS = 3'd3, E_CWAIT = 3'd4, E_WRITE = 3'd5;
    reg  [2:0]  est;
    reg  [3:0]  e_i;                        // row / column / write index
    reg  [3:0]  e_got;                      // results received
    reg  [15:0] tbuf [0:63];                // transpose buffer [row*8 + col]
    reg  [7:0]  obuf [0:63];                // output pixels [row*8 + col]
    wire        o_valid, o_col;
    wire [15:0] o0, o1, o2, o3, o4, o5, o6, o7;
    reg         in_valid, in_col;
    reg signed [15:0] ix0, ix1, ix2, ix3, ix4, ix5, ix6, ix7;
    reg  [3:0]  o_row_idx;                  // index of the result arriving
    idct_1d u_1d (
        .clk(hclk), .rstn(hresetn), .in_valid(in_valid), .in_col(in_col),
        .x0(ix0), .x1(ix1), .x2(ix2), .x3(ix3), .x4(ix4), .x5(ix5), .x6(ix6), .x7(ix7),
        .out_valid(o_valid), .out_col(o_col),
        .y0(o0), .y1(o1), .y2(o2), .y3(o3), .y4(o4), .y5(o5), .y6(o6), .y7(o7)
    );
    // band RAM write
    reg         br_we;
    reg  [11:0] br_waddr;
    reg  [63:0] br_wdata;
    reg  [1:0]  br_wplane;
    // the block's position, latched at the start: the parser moves on to the
    // next record (JPEG mode) while the engine is still writing this block
    reg  [1:0]  e_plane;
    reg  [11:0] e_x, e_y;
    wire [11:0] y_waddr = {e_y[3:0] + e_i[2:0], e_x[10:3]};            // 16 lines x 256 words
    wire [11:0] c_waddr = {2'b00, e_y[2:0] + e_i[2:0], e_x[9:3]};      // 8 lines x 128 words

    assign eng_busy = (est != E_IDLE);
    assign eng_reading = (est == E_ROWS);
    assign eng_done = (est == E_WRITE) && (e_i == 4'd7);

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            est <= E_IDLE; e_i <= 0; e_got <= 0; in_valid <= 0; in_col <= 0;
            ix0 <= 0; ix1 <= 0; ix2 <= 0; ix3 <= 0; ix4 <= 0; ix5 <= 0; ix6 <= 0; ix7 <= 0;
            for (k = 0; k < 64; k = k + 1) begin tbuf[k] <= 16'd0; obuf[k] <= 8'd0; end
            br_we <= 0; br_waddr <= 0; br_wdata <= 0; br_wplane <= 0; e_plane <= 0; e_x <= 0; e_y <= 0;
        end else if (soft_rst) begin
            est <= E_IDLE; in_valid <= 0; br_we <= 0;
        end else begin
            in_valid <= 1'b0;
            br_we    <= 1'b0;
            // results coming back
            if (o_valid && !o_col) begin
                tbuf[e_got*8 + 0] <= o0; tbuf[e_got*8 + 1] <= o1; tbuf[e_got*8 + 2] <= o2; tbuf[e_got*8 + 3] <= o3;
                tbuf[e_got*8 + 4] <= o4; tbuf[e_got*8 + 5] <= o5; tbuf[e_got*8 + 6] <= o6; tbuf[e_got*8 + 7] <= o7;
                e_got <= e_got + 4'd1;
            end
            if (o_valid && o_col) begin                 // column e_got: pixels rows 0..7
                obuf[0*8 + e_got] <= o0[7:0]; obuf[1*8 + e_got] <= o1[7:0]; obuf[2*8 + e_got] <= o2[7:0]; obuf[3*8 + e_got] <= o3[7:0];
                obuf[4*8 + e_got] <= o4[7:0]; obuf[5*8 + e_got] <= o5[7:0]; obuf[6*8 + e_got] <= o6[7:0]; obuf[7*8 + e_got] <= o7[7:0];
                e_got <= e_got + 4'd1;
            end
            case (est)
            E_IDLE: if (eng_start) begin est <= E_ROWS; e_i <= 0; e_got <= 0; e_plane <= r_plane; e_x <= r_x; e_y <= r_y; end
            E_ROWS: begin                               // feed row e_i
                in_valid <= 1'b1; in_col <= 1'b0;
                ix0 <= blk[e_i*8 + 0]; ix1 <= blk[e_i*8 + 1]; ix2 <= blk[e_i*8 + 2]; ix3 <= blk[e_i*8 + 3];
                ix4 <= blk[e_i*8 + 4]; ix5 <= blk[e_i*8 + 5]; ix6 <= blk[e_i*8 + 6]; ix7 <= blk[e_i*8 + 7];
                e_i <= e_i + 4'd1;
                if (e_i == 4'd7) est <= E_RWAIT;
            end
            E_RWAIT: if (e_got == 4'd8) begin est <= E_COLS; e_i <= 0; e_got <= 0; end
            E_COLS: begin                               // feed column e_i
                in_valid <= 1'b1; in_col <= 1'b1;
                ix0 <= tbuf[0*8 + e_i]; ix1 <= tbuf[1*8 + e_i]; ix2 <= tbuf[2*8 + e_i]; ix3 <= tbuf[3*8 + e_i];
                ix4 <= tbuf[4*8 + e_i]; ix5 <= tbuf[5*8 + e_i]; ix6 <= tbuf[6*8 + e_i]; ix7 <= tbuf[7*8 + e_i];
                e_i <= e_i + 4'd1;
                if (e_i == 4'd7) est <= E_CWAIT;
            end
            E_CWAIT: if (e_got == 4'd8) begin est <= E_WRITE; e_i <= 0; end
            E_WRITE: begin                              // row e_i of the block into the band RAM
                br_we     <= 1'b1;
                br_wplane <= e_plane;
                br_waddr  <= (e_plane == 2'd0) ? y_waddr : c_waddr;
                br_wdata  <= {obuf[e_i*8 + 7], obuf[e_i*8 + 6], obuf[e_i*8 + 5], obuf[e_i*8 + 4],
                              obuf[e_i*8 + 3], obuf[e_i*8 + 2], obuf[e_i*8 + 1], obuf[e_i*8 + 0]};
                e_i <= e_i + 4'd1;
                if (e_i == 4'd7) est <= E_IDLE;
            end
            default: est <= E_IDLE;
            endcase
        end
    end

    // ======================================================================
    // band RAMs (64-bit words): Y 16 x 256, U/V 8 x 128 (2048 / 1024 pixels a line)
    // ======================================================================
    reg  [11:0] br_raddr;
    wire [63:0] br_rdata_y, br_rdata_u, br_rdata_v;
    idct_ram #(.ADDR_WIDTH(12)) ram_y (.clk(hclk), .wren(br_we && br_wplane == 2'd0), .write_addr(br_waddr),
                                       .write_data(br_wdata), .read_addr(br_raddr), .read_data(br_rdata_y));
    idct_ram #(.ADDR_WIDTH(10)) ram_u (.clk(hclk), .wren(br_we && br_wplane == 2'd1), .write_addr(br_waddr[9:0]),
                                       .write_data(br_wdata), .read_addr(br_raddr[9:0]), .read_data(br_rdata_u));
    idct_ram #(.ADDR_WIDTH(10)) ram_v (.clk(hclk), .wren(br_we && br_wplane == 2'd2), .write_addr(br_waddr[9:0]),
                                       .write_data(br_wdata), .read_addr(br_raddr[9:0]), .read_data(br_rdata_v));

    // ======================================================================
    // flush engine: the dirty band of plane fl_plane, line by line, as write
    // commands of a whole line (the master splits them into 128 B bursts)
    // ======================================================================
    localparam [2:0] F_IDLE = 3'd0, F_MUL = 3'd1, F_ADDR = 3'd2, F_PRE = 3'd3, F_CMD = 3'd4, F_WAIT = 3'd5, F_NEXT = 3'd6;
    reg  [2:0]  fst;
    reg  [3:0]  f_line;                     // line within the band
    reg  [11:0] f_y;                        // plane line being written
    reg  [27:0] f_off;                      // f_y * stride
    wire [15:0] p_width  = (fl_plane == 2'd0) ? width  : {1'b0, width[15:1]};
    wire [15:0] p_height = (fl_plane == 2'd0) ? height : ((height + 16'd1) >> 1);   // chroma: ceil(h/2), as FFmpeg
    wire [15:0] p_stride = (fl_plane == 2'd0) ? y_stride : c_stride;
    wire [31:0] p_base   = (fl_plane == 2'd0) ? y_base : (fl_plane == 2'd1) ? u_base : v_base;
    wire [3:0]  band_h   = (fl_plane == 2'd0) ? 4'd15 : 4'd7;          // last line index
    wire [15:0] line_beats = {3'b000, p_width[15:3]};
    wire [11:0] line_w0  = (fl_plane == 2'd0) ? {f_line, 8'b0} : {2'b00, f_line[2:0], 7'b0};  // first word of the line
    wire [63:0] br_rdata = (fl_plane == 2'd0) ? br_rdata_y : (fl_plane == 2'd1) ? br_rdata_u : br_rdata_v;

    // prefetch FIFO between the band RAM (read latency 1) and the master, which
    // takes one word per beat (w_req) and can do a beat per cycle: a RAM read is
    // issued whenever the FIFO has room, so the head is always the current beat's
    // word even on back-to-back beats and however the slave inserts wait states.
    reg  [63:0] pf_q [0:3];
    reg  [1:0]  pf_wp, pf_rp;
    reg  [2:0]  pf_cnt;
    reg         pf_inflight;                // a RAM read was issued last cycle
    reg  [15:0] pf_left;                    // words of the line still to read
    wire        pf_issue = (pf_left != 16'd0) && ({1'b0, pf_cnt} + {3'b0, pf_inflight} < 4'd4);
    assign fl_wdata = pf_q[pf_rp];
    assign flush_busy = (fst != F_IDLE);
    assign fl_done = (fst == F_NEXT) && ((f_line == band_h) || (f_y + 12'd1 >= p_height[11:0]));

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            fst <= F_IDLE; f_line <= 0; f_y <= 0; f_off <= 0; fl_cmd <= 0; fl_addr <= 0; fl_len <= 0; br_raddr <= 0; bands <= 0;
            pf_wp <= 0; pf_rp <= 0; pf_cnt <= 0; pf_inflight <= 0; pf_left <= 0;
        end else if (soft_rst) begin
            fst <= F_IDLE; fl_cmd <= 0;
            pf_wp <= 0; pf_rp <= 0; pf_cnt <= 0; pf_inflight <= 0; pf_left <= 0;
        end else begin
            // ---- prefetch FIFO ----
            pf_inflight <= pf_issue;
            if (pf_issue) begin br_raddr <= br_raddr + 12'd1; pf_left <= pf_left - 16'd1; end
            if (pf_inflight) begin pf_q[pf_wp] <= br_rdata; pf_wp <= pf_wp + 2'd1; end
            if (w_req) pf_rp <= pf_rp + 2'd1;
            pf_cnt <= pf_cnt + {2'b0, pf_inflight} - {2'b0, w_req};
            case (fst)
            F_IDLE: if (fl_req && !rd_active && !rd_cmd && cmd_ready) begin
                f_line <= 4'd0;
                f_y    <= band_y0[fl_plane];
                fst    <= F_MUL;
            end
            F_MUL: begin
                f_off <= f_y * p_stride;                // DSP multiply, registered
                fst   <= F_ADDR;
            end
            F_ADDR: begin                               // (the previous line's FIFO is drained: cmd_done)
                fl_addr  <= p_base + {4'b0, f_off};
                fl_len   <= line_beats;
                br_raddr <= line_w0;                    // the prefetch starts reading next cycle
                pf_left  <= line_beats;
                fst      <= F_PRE;
            end
            F_PRE: begin                                // prime the FIFO, then issue the command
                if (pf_cnt >= 3'd2 || (pf_left == 16'd0 && !pf_inflight && pf_cnt != 3'd0)) begin
                    fl_cmd <= 1'b1;
                    fst    <= F_CMD;
                end
            end
            F_CMD: begin                                // accepted when the master is ready (it is idle:
                if (cmd_ready) begin fl_cmd <= 1'b0; fst <= F_WAIT; end   // a read in flight ends first)
            end
            F_WAIT: begin
                if (cmd_done) fst <= F_NEXT;
            end
            F_NEXT: begin
                if ((f_line == band_h) || (f_y + 12'd1 >= p_height[11:0])) begin
                    bands <= bands + 32'd1;
                    fst   <= F_IDLE;
                end else begin
                    f_line <= f_line + 4'd1;
                    f_y    <= f_y + 12'd1;
                    fst    <= F_MUL;
                end
            end
            default: fst <= F_IDLE;
            endcase
        end
    end
    assign set_band = fl_done && band_irq_req[fl_plane];

    // ======================================================================
    // status
    // ======================================================================
    wire pending = (((tail - head) & ring_mask) != 32'd0) || (f_cnt != 0) || (pst != P_IDLE) || eng_busy || fl_req || flush_busy || rd_active;
    reg  pend_d;
    always @(posedge hclk or negedge hresetn)
        if (!hresetn) pend_d <= 1'b0; else pend_d <= pending;
    assign set_done = pend_d && !pending;       // just went idle
    assign busy = pending | pend_d;             // busy drops in the cycle the done flag rises
endmodule
`default_nettype wire
