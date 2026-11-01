`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_rx_sf_buffer.v -- store-and-forward staging buffer with rewindable write
// pointer.  Proves the fix for the data/metadata desync:
//   Phase 1: drain always ready -> every frame delivered byte-exact, 0 drops.
//   Phase 2: drain stalled while many frames pour in -> the RAM / info FIFO
//            overflow, frames are REWOUND (dropped whole).  After draining,
//            every delivered frame is still byte-exact and an in-order
//            subsequence of what was sent; delivered + drop_cnt == sent.
// A misaligned ("shifted") frame -- the old bug -- would fail the byte-exact
// subsequence check.
//============================================================================
module tb_rx_sf_buffer;
    localparam AW = 6, INFO_AW = 2;        // 64-word RAM, 4-frame info FIFO (small -> overflow)
    localparam MAXLEN = 64;

    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;

    reg        in_word_valid = 0, in_eof = 0, in_err = 0;
    reg [31:0] in_word = 0;
    reg [15:0] in_len  = 0;

    wire        data_valid, meta_valid;
    wire [31:0] data_word;
    wire [16:0] meta_word;
    reg         data_ready = 0, meta_ready = 0;
    wire [15:0] drop_cnt;

    rx_sf_buffer #(.AW(AW), .INFO_AW(INFO_AW)) dut (
        .clk(clk), .rstn(rstn),
        .in_word_valid(in_word_valid), .in_word(in_word),
        .in_eof(in_eof), .in_len(in_len), .in_err(in_err),
        .data_valid(data_valid), .data_word(data_word), .data_ready(data_ready),
        .meta_valid(meta_valid), .meta_word(meta_word), .meta_ready(meta_ready),
        .drop_cnt(drop_cnt)
    );

    // unique, frame-distinguishable pattern
    function [7:0] pat(input integer f, input integer i);
        pat = (f*8 + i + 1) & 8'hff;
    endfunction

    // ---- sent log ----
    integer sent_len [0:63];
    reg [7:0] sent_b  [0:63][0:MAXLEN-1];
    integer ns;

    // ---- delivered log (filled by the consumer) ----
    integer del_len [0:63];
    reg [7:0] del_b  [0:63][0:MAXLEN-1];
    integer nd;

    // consumer: collect data words, finalize on metadata
    reg [31:0] cur [0:MAXLEN/4];
    integer cur_nw;
    integer k, b;
    always @(posedge clk) begin
        if (!rstn) begin nd <= 0; cur_nw <= 0; end
        else begin
            if (data_valid && data_ready) begin
                cur[cur_nw] <= data_word;
                cur_nw <= cur_nw + 1;
            end
            if (meta_valid && meta_ready) begin
                del_len[nd] = meta_word[15:0];
                for (b = 0; b < del_len[nd]; b = b + 1)
                    del_b[nd][b] = cur[b>>2][(b%4)*8 +: 8];
                nd <= nd + 1;
                cur_nw <= 0;
            end
        end
    end

    // driver: send one frame (record it in the sent log)
    task send_frame(input integer f, input integer len);
        integer i, w, nwords;
        reg [31:0] word;
        begin
            sent_len[ns] = len;
            for (i = 0; i < len; i = i + 1) sent_b[ns][i] = pat(f, i);
            nwords = (len + 3) >> 2;
            for (w = 0; w < nwords; w = w + 1) begin
                word = 32'h0;
                for (i = 0; i < 4; i = i + 1)
                    if (w*4 + i < len) word[i*8 +: 8] = pat(f, w*4 + i);
                @(negedge clk);
                in_word_valid = 1; in_word = word;
                in_eof = (w == nwords-1); in_len = (w==nwords-1) ? len[15:0] : 16'd0;
                in_err = 0;
            end
            @(negedge clk); in_word_valid = 0; in_eof = 0; in_len = 0;
            ns = ns + 1;
        end
    endtask

    integer si, d, match, errors, dropped_implied;
    reg ok;
    initial begin
        ns = 0; errors = 0;
        rstn = 0; repeat (4) @(negedge clk); rstn = 1;

        // ---- Phase 1: drain always ready ----
        data_ready = 1; meta_ready = 1;
        send_frame(1, 8);
        send_frame(2, 13);
        send_frame(3, 4);
        repeat (60) @(negedge clk);
        if (drop_cnt !== 16'd0) begin
            errors = errors + 1; $display("  P1 unexpected drops=%0d", drop_cnt);
        end
        if (nd !== 3) begin errors = errors + 1; $display("  P1 delivered %0d/3", nd); end

        // ---- Phase 2: stall the drain, flood, then resume ----
        data_ready = 0; meta_ready = 0;
        repeat (2) @(negedge clk);
        for (k = 0; k < 24; k = k + 1) send_frame(10 + k, 8 + (k % 20));
        repeat (10) @(negedge clk);
        data_ready = 1; meta_ready = 1;        // resume draining
        repeat (1500) @(negedge clk);          // let everything drain

        // ---- verify: delivered is an in-order, byte-exact subsequence of sent ----
        si = 0;
        for (d = 0; d < nd; d = d + 1) begin
            // advance through sent[] (skipping dropped frames) until a full match
            match = 0;
            while (si < ns && !match) begin
                ok = (sent_len[si] == del_len[d]);
                for (b = 0; ok && b < del_len[d]; b = b + 1)
                    if (sent_b[si][b] !== del_b[d][b]) ok = 0;
                if (ok) match = 1;
                else    si = si + 1;            // this sent frame was dropped
            end
            if (!match) begin
                errors = errors + 1;
                $display("  delivered frame %0d (len %0d) matches no remaining sent frame (MISALIGNED?)", d, del_len[d]);
            end else si = si + 1;
        end

        dropped_implied = ns - nd;
        $display("sent=%0d delivered=%0d drop_cnt=%0d (implied drops=%0d)", ns, nd, drop_cnt, dropped_implied);
        if (dropped_implied !== drop_cnt) begin
            errors = errors + 1;
            $display("  drop accounting mismatch: implied %0d != drop_cnt %0d", dropped_implied, drop_cnt);
        end
        if (nd == 0) begin errors = errors + 1; $display("  nothing delivered"); end

        if (errors == 0) $display("RESULT: PASS (every delivered frame byte-exact & in-order; drops reconcile)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #500000; $display("RESULT: FAIL (timeout nd=%0d)", nd); $finish; end
endmodule
`default_nettype wire
