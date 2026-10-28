`timescale 1ns/1ps
// Behavioral model of the Gowin DDR3 Memory Interface IP *user port* (1:4,
// x16, BL8 = 128 bits per command), enough to exercise ahb_ddr3_bridge:
//  * cmd/cmd_en/cmd_ready and wr_data_* handshakes with random back-pressure
//  * in-order read returns after a random latency (1 command = 1 beat)
//  * byte-masked writes (wr_data_mask 1 = byte NOT written)
//  * checks: write data must accompany its command, read addresses 16 B aligned,
//    and (LOOKAHEAD_CHECK) a command is only issued when cmd_ready (and
//    wr_data_rdy) was also high in the previous cycle -- the contract Sipeed's
//    known-good DDR test relies on (cmd_en registered from cmd_ready)
//  * XROW_REORDER=1: like the real Gowin MC, reads that target a different
//    DRAM row than the previous read may complete out of command order (a
//    row miss costs extra latency, a later row-hit read can overtake it);
//    +noreorder turns it off at run time
module ddr3_ui_model #(
    parameter XROW_REORDER = 0,
    parameter LOOKAHEAD_CHECK = 1,
    parameter ROW_SHIFT = 7,            // 16 B word index -> bank+row (2 KB rows, x16)
    parameter WORDS   = 4096,           // 16 B words modelled (64 KB)
    parameter LAT_MIN = 6,
    parameter LAT_MAX = 24,
    parameter RDY_PCT = 80,             // % of cycles cmd_ready / wr_data_rdy high
    parameter ADDR_W  = 28              // addr port width (= bridge ADDR_BITS)
) (
    input  wire         clk,
    output reg          calib_done,
    output reg          cmd_ready,
    input  wire [2:0]   cmd,
    input  wire         cmd_en,
    input  wire [ADDR_W-1:0] addr,
    output reg          wr_data_rdy,
    input  wire [127:0] wr_data,
    input  wire         wr_data_en,
    input  wire         wr_data_end,
    input  wire [15:0]  wr_data_mask,
    output reg  [127:0] rd_data,
    output reg          rd_data_valid,
    output integer      errors
);
    reg [127:0] mem [0:WORDS-1];
    integer i, now;

    // read return queue
    reg [127:0] q_data [0:255];
    integer     q_time [0:255];
    integer     q_w, q_r, last_time;
    reg         q_done [0:255];
    reg [31:0]  last_row;
    integer     lat, j, best;
    reg         cmd_ready_d = 0, wr_data_rdy_d = 0;
    integer     la_viol = 0;
    // +max_rd=N: a read command while N reads are still unanswered is a
    // protocol error (checks the bridge's "one read in flight" mode, N = 1)
    integer     max_rd = 0, n_ret = 0, mr_viol = 0;
    initial if ($value$plusargs("max_rd=%d", max_rd)) ;
    // +rdy_pct=N overrides RDY_PCT (heavy back-pressure fills the command FIFO)
    integer     rdy_pct = RDY_PCT;
    initial if ($value$plusargs("rdy_pct=%d", rdy_pct)) ;
    reg         xrow = XROW_REORDER;
    initial if ($test$plusargs("noreorder")) xrow = 1'b0;

    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = {4{$random}};
        calib_done = 0; cmd_ready = 0; wr_data_rdy = 0;
        rd_data = 0; rd_data_valid = 0; errors = 0;
        q_w = 0; q_r = 0; now = 0; last_time = 0; last_row = 32'hffffffff;
        repeat (20) @(posedge clk);
        calib_done <= 1;
    end

    function [127:0] wmerge(input [127:0] old, input [127:0] d, input [15:0] m);
        integer b;
        begin
            wmerge = old;
            for (b = 0; b < 16; b = b + 1)
                if (!m[b]) wmerge[b*8 +: 8] = d[b*8 +: 8];
        end
    endfunction

    wire [ADDR_W-2:0] waddr = addr[ADDR_W-2:0];  // x16 word address
    wire [31:0] widx  = (waddr >> 3) % WORDS;    // 16 B word index

    always @(posedge clk) begin
        now = now + 1;
        if (calib_done && cmd_en && LOOKAHEAD_CHECK &&
            (!cmd_ready_d || (cmd == 3'b000 && !wr_data_rdy_d))) begin
            if (la_viol < 5) $display("%0t DDR model: command without ready in the previous cycle", $time);
            la_viol = la_viol + 1; errors = errors + 1;
        end
        cmd_ready_d   = cmd_ready;
        wr_data_rdy_d = wr_data_rdy;
        if (calib_done && cmd_en) begin
            if (!cmd_ready) begin
                $display("%0t DDR model: cmd_en while !cmd_ready", $time); errors = errors + 1;
            end
            if (waddr[2:0] != 3'b000) begin
                $display("%0t DDR model: unaligned addr %h", $time, waddr); errors = errors + 1;
            end
            if (cmd == 3'b000) begin                         // write
                if (!(wr_data_en && wr_data_end && wr_data_rdy)) begin
                    $display("%0t DDR model: write cmd without data", $time); errors = errors + 1;
                end
                mem[widx] <= wmerge(mem[widx], wr_data, wr_data_mask);
            end else if (cmd == 3'b001) begin                // read
                if (max_rd > 0 && q_w - n_ret >= max_rd) begin
                    if (mr_viol < 5) $display("%0t DDR model: read issued with %0d reads in flight (max %0d)",
                                              $time, q_w - n_ret, max_rd);
                    mr_viol = mr_viol + 1; errors = errors + 1;
                end
                q_data[q_w % 256] = mem[widx];
                lat = LAT_MIN + ($random & 32'h7fffffff) % (LAT_MAX - LAT_MIN + 1);
                if (xrow && (widx >> ROW_SHIFT) != last_row) begin
                    // different row than the previous read: row miss, slower,
                    // and NOT ordered against earlier reads (may overtake or
                    // be overtaken); same-row followers stay behind it
                    last_time = now + lat + ($random & 15);
                end else begin
                    last_time = (now + lat > last_time) ? now + lat : last_time + 1;
                end
                q_time[q_w % 256] = last_time;
                last_row = widx >> ROW_SHIFT;
                q_done[q_w % 256] = 1'b0;
                q_w = q_w + 1;
            end else begin
                $display("%0t DDR model: bad cmd %b", $time, cmd); errors = errors + 1;
            end
        end else if (wr_data_en) begin
            $display("%0t DDR model: wr_data_en without cmd", $time); errors = errors + 1;
        end

        rd_data_valid <= 1'b0;
        // return the earliest-completing pending read (in order unless reordered)
        best = -1;
        for (j = q_r; j < q_w; j = j + 1)
            if (!q_done[j % 256] && q_time[j % 256] <= now && (best < 0 || q_time[j % 256] < q_time[best % 256]))
                best = j;
        if (best >= 0) begin
            rd_data_valid <= 1'b1;
            rd_data       <= q_data[best % 256];
            q_done[best % 256] = 1'b1;
            n_ret = n_ret + 1;
            while (q_r != q_w && q_done[q_r % 256]) q_r = q_r + 1;
        end

        cmd_ready   <= calib_done && (($random & 32'h7fffffff) % 100 < rdy_pct);
        wr_data_rdy <= calib_done && (($random & 32'h7fffffff) % 100 < rdy_pct);
    end
endmodule
