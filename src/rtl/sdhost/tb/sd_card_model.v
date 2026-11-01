`timescale 1ns/1ps
//============================================================================
// sd_card_model.v -- behavioural SD card for the host testbench (native bus,
// 1 or 4 data lines).  Enough of the protocol for Linux's init sequence and
// block traffic: CMD0/8/55/ACMD41/2/3/7/9/13/16/17/18/24/25/12, ACMD6/51,
// CMD6.  Responses and data change on the clock rising edge (tODLY), as a
// real card does; the host must sample a period later.  Commands are CRC7
// checked, written blocks CRC16 checked (bad CRC -> status token 101).
// `inject_crc` corrupts the CRC of the next read block.
//============================================================================
module sd_card_model (
    input  wire       clk,
    inout  wire       cmd,
    inout  wire [3:0] dat
);
    parameter integer MEM_BYTES = 1 << 20;
    reg  [7:0] mem [0:MEM_BYTES-1];
    reg        inject_crc = 0;
    integer    crc_fail = 0;        // write blocks received with bad CRC
    integer    cmd_crc_bad = 0;     // commands received with bad CRC7
    integer    blocks_read = 0, blocks_written = 0;

    // ---- line drivers ------------------------------------------------
    reg        cmd_o = 1, cmd_oe = 0;
    reg  [3:0] dat_o = 4'hF; reg dat_oe = 0;
    reg        bus4 = 0;
    assign cmd = cmd_oe ? cmd_o : 1'bz;
    assign dat[0]   = dat_oe ? dat_o[0] : 1'bz;
    assign dat[3:1] = (dat_oe && bus4) ? dat_o[3:1] : 3'bzzz;

    // ---- state -------------------------------------------------------
    reg        app = 0;             // CMD55 seen
    reg        idle = 1;            // before ACMD41 completes
    integer    acmd41_n = 0;
    reg [15:0] rca = 16'h1234;
    reg [127:0] cid = 128'h03534453_44333247_80ABCDEF_01234501;   // ends with crc byte + 1 (end bit)
    reg [127:0] csd = 128'h400E0032_5B590000_1D8A7F80_0A400001;   // SDHC-like CSD v2
    reg [31:0] card_status = 32'h0000_0900;   // ready_for_data, tran state (4<<9)
    reg [31:0] ocr = 32'hC0FF_8000;
    reg [63:0] scr = 64'h0205_8000_0000_0000;  // SD v2, 4-bit + 1-bit widths
    integer    i;

    function [6:0] crc7(input [39:0] d);   // over 40 bits
        integer k; reg [6:0] c; reg x;
        begin
            c = 0;
            for (k = 39; k >= 0; k = k - 1) begin x = c[6] ^ d[k]; c = {c[5:3], c[2]^x, c[1:0], x}; end
            crc7 = c;
        end
    endfunction
    function [6:0] crc7_120(input [119:0] d);
        integer k; reg [6:0] c; reg x;
        begin
            c = 0;
            for (k = 119; k >= 0; k = k - 1) begin x = c[6] ^ d[k]; c = {c[5:3], c[2]^x, c[1:0], x}; end
            crc7_120 = c;
        end
    endfunction
    function [15:0] crc16_bit(input [15:0] c, input b);
        reg x;
        begin x = c[15] ^ b; crc16_bit = {c[14:12], c[11]^x, c[10:5], c[4]^x, c[3:0], x}; end
    endfunction

    // ---- command receiver ----------------------------------------------
    reg [47:0] csh = 0; integer cbits = 0; reg in_cmd = 0;
    reg [5:0]  idx; reg [31:0] arg; reg cmd_valid = 0;
    always @(posedge clk) begin
        cmd_valid <= 0;
        if (!cmd_oe) begin
            if (!in_cmd) begin
                if (cmd === 1'b0) begin in_cmd <= 1; csh <= 48'd0; cbits <= 1; end
            end else begin
                csh <= {csh[46:0], cmd};
                cbits <= cbits + 1;
                if (cbits == 47) begin
                    in_cmd <= 0;
                    // {csh[46:0], cmd} = start(0) tx(1) idx(6) arg(32) crc(7) end(1)
                    idx <= csh[44:39]; arg <= csh[38:7];
                    if (crc7({2'b01, csh[44:39], csh[38:7]}) !== csh[6:0]) cmd_crc_bad = cmd_crc_bad + 1;
                    cmd_valid <= 1;
                end
            end
        end
    end

    // ---- response / data tasks -----------------------------------------
    task send_bits(input integer n, input [135:0] v);   // MSB first, change after rising edge
        integer k;
        begin
            for (k = n - 1; k >= 0; k = k - 1) begin
                @(posedge clk); #2; cmd_oe = 1; cmd_o = v[k];
            end
            @(posedge clk); #2; cmd_oe = 0; cmd_o = 1;
        end
    endtask
    task resp48(input [5:0] ix, input [31:0] payload);
        reg [47:0] r;
        begin
            r = {2'b00, ix, payload, 7'd0, 1'b1};
            r[7:1] = crc7({2'b00, ix, payload});
            repeat (4) @(posedge clk);        // Ncr
            send_bits(48, {88'd0, r});
        end
    endtask
    task resp136(input [127:0] body);      // body[127:8] content, crc added, end bit
        reg [135:0] r;
        begin
            r = {2'b00, 6'h3F, body[127:8], crc7_120(body[127:8]), 1'b1};
            repeat (4) @(posedge clk);
            send_bits(136, r);
        end
    endtask
    // busy on DAT0 for n clocks (after the response)
    task busy(input integer n);
        begin
            @(posedge clk); #2; dat_oe = 1; dat_o = 4'hE;
            repeat (n) @(posedge clk);
            #2; dat_o = 4'hF; @(posedge clk); #2; dat_oe = 0;
        end
    endtask
    // send one data block of len bytes from mem[a..]
    task send_block(input integer a, input integer len);
        reg [15:0] c [0:3]; integer k, b, nb; reg [3:0] nibv; reg [7:0] byt;
        begin
            for (k = 0; k < 4; k = k + 1) c[k] = 0;
            repeat (6) @(posedge clk);
            if (stop_req) disable send_block;                   // CMD12 arrived between blocks
            @(posedge clk); #2; dat_oe = 1; dat_o = 4'h0;       // start bit(s)
            if (bus4) begin
                for (b = 0; b < len; b = b + 1) begin
                    byt = mem[a + b];
                    if (stop_req) begin @(posedge clk); #2; dat_o = 4'hF; dat_oe = 0; disable send_block; end
                    for (nb = 0; nb < 2; nb = nb + 1) begin
                        nibv = nb == 0 ? byt[7:4] : byt[3:0];
                        @(posedge clk); #2; dat_o = nibv;
                        for (k = 0; k < 4; k = k + 1) c[k] = crc16_bit(c[k], nibv[k]);
                    end
                end
            end else begin
                for (b = 0; b < len; b = b + 1) begin
                    byt = mem[a + b];
                    if (stop_req) begin @(posedge clk); #2; dat_o = 4'hF; dat_oe = 0; disable send_block; end
                    for (nb = 7; nb >= 0; nb = nb - 1) begin
                        @(posedge clk); #2; dat_o = {3'b111, byt[nb]};
                        c[0] = crc16_bit(c[0], byt[nb]);
                    end
                end
            end
            if (inject_crc) begin c[0] = ~c[0]; inject_crc = 0; end
            for (k = 15; k >= 0; k = k - 1) begin
                @(posedge clk); #2; dat_o = bus4 ? {c[3][k], c[2][k], c[1][k], c[0][k]} : {3'b111, c[0][k]};
            end
            @(posedge clk); #2; dat_o = 4'hF;                   // end bit
            @(posedge clk); #2; dat_oe = 0;
            blocks_read = blocks_read + 1;
        end
    endtask
    // receive one block into mem[a..]; returns crc ok
    task recv_block(input integer a, input integer len, output ok);
        reg [15:0] c [0:3]; reg [15:0] rc [0:3]; integer k, b, nb; reg [3:0] nibv; reg [7:0] byt;
        begin
            for (k = 0; k < 4; k = k + 1) begin c[k] = 0; rc[k] = 0; end
            // start bit (give up when CMD12 arrives first)
            @(posedge clk); while (dat[0] !== 1'b0 && !stop_req) @(posedge clk);
            if (stop_req) disable recv_block;
            if (bus4) begin
                for (b = 0; b < len; b = b + 1) begin
                    @(posedge clk); nibv = dat; byt[7:4] = nibv;
                    for (k = 0; k < 4; k = k + 1) c[k] = crc16_bit(c[k], nibv[k]);
                    @(posedge clk); nibv = dat; byt[3:0] = nibv;
                    for (k = 0; k < 4; k = k + 1) c[k] = crc16_bit(c[k], nibv[k]);
                    mem[a + b] = byt;
                end
            end else begin
                for (b = 0; b < len; b = b + 1) begin
                    for (nb = 7; nb >= 0; nb = nb - 1) begin
                        @(posedge clk); byt[nb] = dat[0]; c[0] = crc16_bit(c[0], dat[0]);
                    end
                    mem[a + b] = byt;
                end
            end
            for (k = 15; k >= 0; k = k - 1) begin
                @(posedge clk);
                rc[0][k] = dat[0]; rc[1][k] = dat[1]; rc[2][k] = dat[2]; rc[3][k] = dat[3];
            end
            @(posedge clk);                                     // end bit
            ok = bus4 ? (rc[0] == c[0] && rc[1] == c[1] && rc[2] == c[2] && rc[3] == c[3]) : (rc[0] == c[0]);
            if (!ok) crc_fail = crc_fail + 1;
            // CRC status token after 2 clocks: start, 3 bits, end; then busy
            @(posedge clk); @(posedge clk); #2; dat_oe = 1; dat_o = 4'hE;
            @(posedge clk); #2; dat_o = {3'b111, ok ? 1'b0 : 1'b1};
            @(posedge clk); #2; dat_o = {3'b111, ok ? 1'b1 : 1'b0};
            @(posedge clk); #2; dat_o = {3'b111, ok ? 1'b0 : 1'b1};
            @(posedge clk); #2; dat_o = 4'hF;                   // end bit
            @(posedge clk); #2; dat_o = 4'hE;                   // busy
            repeat (12) @(posedge clk);
            #2; dat_o = 4'hF; @(posedge clk); #2; dat_oe = 0;
            blocks_written = blocks_written + 1;
        end
    endtask

    // ---- command handling ----------------------------------------------
    reg        stop_req = 0;
    reg        multi_rd = 0, multi_wr = 0;
    integer    blk_addr;
    integer    blklen = 512;
    reg        ok;
    always @(posedge clk) if (cmd_valid) begin
        if (app) begin
            app = 0;
            case (idx)
                6'd41: begin acmd41_n = acmd41_n + 1; if (acmd41_n >= 2) idle = 0;
                             resp48(6'h3F, idle ? (ocr & 32'h7FFFFFFF) : ocr); end
                6'd6:  begin bus4 = arg[1:0] == 2'b10; resp48(6'd6, card_status); end
                6'd51: begin stop_req = 0; resp48(6'd51, card_status);
                             for (i = 0; i < 8; i = i + 1) mem[MEM_BYTES - 8 + i] = scr[63 - 8*i -: 8];
                             send_block(MEM_BYTES - 8, 8); end
                6'd13: begin stop_req = 0; resp48(6'd13, card_status); send_block(MEM_BYTES - 64, 64); end
                default: resp48(idx, card_status);
            endcase
        end else case (idx)
            6'd0:  begin idle = 1; acmd41_n = 0; bus4 = 0; end
            6'd8:  resp48(6'd8, {20'd0, arg[11:0]});
            6'd55: begin app = 1; resp48(6'd55, card_status | 32'h20); end
            6'd2:  resp136(cid);
            6'd3:  resp48(6'd3, {rca, 16'h0700});
            6'd7:  begin resp48(6'd7, card_status); busy(10); end
            6'd9:  resp136(csd);
            6'd10: resp136(cid);
            6'd13: resp48(6'd13, card_status);
            6'd16: begin blklen = arg; resp48(6'd16, card_status); end
            6'd6:  begin stop_req = 0; resp48(6'd6, card_status); send_block(MEM_BYTES - 64, 64); end
            6'd17: begin stop_req = 0; resp48(6'd17, card_status); send_block(arg * 512, blklen); end
            6'd18: begin stop_req = 0; resp48(6'd18, card_status); blk_addr = arg * 512;
                         while (!stop_req) begin send_block(blk_addr, blklen); blk_addr = blk_addr + blklen; end end
            6'd24: begin stop_req = 0; resp48(6'd24, card_status); recv_block(arg * 512, blklen, ok); end
            6'd25: begin stop_req = 0; resp48(6'd25, card_status); blk_addr = arg * 512;
                         while (!stop_req) begin recv_block(blk_addr, blklen, ok); blk_addr = blk_addr + blklen; end end
            6'd12: ;          // handled by the watcher below (the handler may be inside a block loop)
            default: ;        // no response (host sees a timeout)
        endcase
    end
    // CMD12 must be answered while the handler above may still be inside a
    // multi-block loop: decode and respond here (no busy: DAT is owned by the loop)
    always @(posedge clk) if (cmd_valid && !app && idx == 6'd12) begin
        stop_req = 1;
        resp48(6'd12, card_status);
    end
endmodule
