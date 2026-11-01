`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_tx_unpack.v -- feed metadata (lengths) + data words; collect the tx_mac
// byte stream and verify it reconstructs the words little-endian, with tx_mac_last
// on the right byte, under tx_mac_ready back-pressure.
//============================================================================
module tb_tx_unpack;
    reg clk = 0; always #4 clk = ~clk;        // 125 MHz
    reg rstn = 0;

    // metadata queue
    reg  [15:0] mlen [0:7];
    integer     midx = 0, mcount = 0;
    wire        meta_valid = (midx < mcount);
    wire [15:0] meta_len   = mlen[midx];
    wire        meta_ready;
    always @(posedge clk) if (meta_valid && meta_ready) midx <= midx + 1;

    // data word source
    reg  [31:0] dmem [0:1023];
    integer     didx = 0, dtotal = 0;
    wire        data_valid = (didx < dtotal);
    wire [31:0] data_word  = dmem[didx];
    wire        data_ready;
    always @(posedge clk) if (data_valid && data_ready) didx <= didx + 1;

    // tx_mac sink with back-pressure
    wire        tx_mac_valid, tx_mac_last;
    wire [7:0]  tx_mac_data;
    reg         tx_mac_ready = 1;
    wire        frame_done;

    tx_unpack dut (
        .tx_mac_clk(clk), .rstn(rstn),
        .meta_valid(meta_valid), .meta_len(meta_len), .meta_ready(meta_ready),
        .data_valid(data_valid), .data_word(data_word), .data_ready(data_ready),
        .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data),
        .tx_mac_last(tx_mac_last), .tx_mac_ready(tx_mac_ready), .frame_done(frame_done)
    );

    // pseudo-random back-pressure
    integer seed = 7;
    always @(posedge clk) tx_mac_ready <= ($random(seed) % 4 != 0);   // ~75% ready

    // collect emitted bytes + per-frame last positions
    reg  [7:0] sbuf [0:4095];
    integer    sidx = 0;
    integer    last_at [0:7]; integer ndone = 0;
    always @(posedge clk) begin
        if (tx_mac_valid && tx_mac_ready) begin
            sbuf[sidx] = tx_mac_data;
            if (tx_mac_last) last_at[ndone] = sidx;   // index of this frame's last byte
            sidx = sidx + 1;
        end
        if (frame_done) ndone = ndone + 1;
    end

    // no mid-frame gap: between a frame's first and last accepted byte the
    // MAC must see tx_mac_valid every cycle (Ethernet cannot pause a frame)
    reg     in_frame = 0;
    integer gaps = 0;
    always @(posedge clk) begin
        if (in_frame && !tx_mac_valid) gaps = gaps + 1;
        if (tx_mac_valid && tx_mac_ready) in_frame = !tx_mac_last;
    end

    integer f, i, ws, base, errors;
    reg [7:0] got, exp;
    initial begin
        errors = 0;
        // 3 frames: 7, 16, 1 bytes -> words 2,4,1
        mlen[0]=16'd7; mlen[1]=16'd16; mlen[2]=16'd1; mcount = 3;
        dtotal = 2 + 4 + 1;
        for (i = 0; i < dtotal; i = i + 1) dmem[i] = 32'hABCD0000 + i*17 + 1;

        repeat (3) @(posedge clk); rstn = 1;
        wait (ndone == 3);
        repeat (4) @(posedge clk);

        ws = 0; base = 0;
        for (f = 0; f < 3; f = f + 1) begin
            for (i = 0; i < mlen[f]; i = i + 1) begin
                got = sbuf[base + i];
                exp = dmem[ws + (i/4)][(i%4)*8 +: 8];
                if (got !== exp) begin
                    errors = errors + 1;
                    if (errors < 8) $display("  frame %0d byte %0d got %02x exp %02x", f, i, got, exp);
                end
            end
            // last byte position must be the frame's final byte
            if (last_at[f] !== base + mlen[f]-1) begin
                errors = errors + 1;
                $display("  frame %0d last@%0d exp %0d", f, last_at[f], base+mlen[f]-1);
            end
            base = base + mlen[f];
            ws = ws + ((mlen[f]+3)>>2);
        end
        if (gaps != 0) begin
            errors = errors + 1;
            $display("  %0d mid-frame cycles without tx_mac_valid", gaps);
        end
        if (errors == 0) $display("RESULT: PASS (3 frames unpacked to tx_mac with correct bytes/last)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #100000; $display("RESULT: FAIL (timeout ndone=%0d)", ndone); $finish; end
endmodule
`default_nettype wire
