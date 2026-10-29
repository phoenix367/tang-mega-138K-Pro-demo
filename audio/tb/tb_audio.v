`timescale 1ns/1ps
//============================================================================
// tb_audio.v -- audio_core on an AHB-lite master model, decoded by a PT8211
// receiver model (DIN sampled on BCK rising edges, each channel = the 16 bits
// clocked before a WS transition).  Checks: reset values, measured frame rate
// for two RATE values, every frame in order, FRAMES / CRC against a model,
// underrun and overrun counting, the FIFO full flag, the level interrupt,
// channel swap and FIFO reset.  Prints "RESULT: PASS" or "RESULT: FAIL".
//============================================================================
module tb_audio;
    localparam BASE     = 32'hE800_2000;
    localparam CTRL = 8'h00, STATUS = 8'h04, DATA = 8'h08, THRESH = 8'h0C,
               RATE = 8'h10, UNDERRUN = 8'h14, OVERRUN = 8'h18, FRAMES = 8'h1C,
               CRC = 8'h20, DEPTH = 8'h24, ID = 8'h2C;
    localparam RATE_48K  = 32'd131941395;     // 48000 * 2^37 / 50e6
    localparam RATE_44K1 = 32'd121221157;     // 44100 * 2^37 / 50e6
    localparam RATE_FAST = 32'h4000_0000;     // BCK = 4 clocks: 390625 frames/s

    reg clk = 0, rstn = 0;
    always #10 clk = ~clk;                    // 50 MHz

    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0;
    wire [31:0] hrdata;
    wire        hready, hresp, irq, bck, ws, din, pa_en;

    audio_core dut (
        .hclk(clk), .hresetn(rstn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel),
        .s_hready_in(hready), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .irq(irq), .i2s_bck(bck), .i2s_ws(ws), .i2s_din(din), .pa_en(pa_en)
    );

    integer errors = 0;
    task check(input cond, input [8*64-1:0] what, input [31:0] got, input [31:0] exp);
        if (!cond) begin
            errors = errors + 1;
            $display("  FAIL %0t: %0s: got %0d (0x%08x), expected %0d (0x%08x)", $time, what, got, got, exp, exp);
        end
    endtask

    // ---- AHB-lite master ------------------------------------------------
    task ahb_write(input [7:0] off, input [31:0] d);
        begin
            @(posedge clk); #1;
            haddr = BASE | off; htrans = 2'b10; hwrite = 1; hsel = 1;
            @(posedge clk); #1;
            htrans = 0; hsel = 0; hwdata = d;
            @(posedge clk); #1;
        end
    endtask
    task ahb_read(input [7:0] off, output [31:0] d);
        begin
            @(posedge clk); #1;
            haddr = BASE | off; htrans = 2'b10; hwrite = 0; hsel = 1;
            @(posedge clk); #1;
            htrans = 0; hsel = 0;
            #5 d = hrdata;
            @(posedge clk); #1;
        end
    endtask
    // back-to-back pipelined DATA writes of wbuf[0..n-1] (one per clock)
    reg [31:0] wbuf [0:4095];
    task ahb_burst(input integer n);
        integer i;
        begin
            @(posedge clk); #1;
            for (i = 0; i < n; i = i + 1) begin
                haddr = BASE | DATA; htrans = 2'b10; hwrite = 1; hsel = 1;
                hwdata = (i > 0) ? wbuf[i-1] : 32'hxxxx_xxxx;
                @(posedge clk); #1;
            end
            htrans = 0; hsel = 0; hwdata = wbuf[n-1];
            @(posedge clk); #1;
        end
    endtask
    task wait_frames(input [31:0] k);        // poll until FRAMES == k
        reg [31:0] v; integer guard;
        begin
            guard = 0;
            ahb_read(FRAMES, v);
            while (v != k && guard < 2000000) begin ahb_read(FRAMES, v); guard = guard + 1; end
            check(v == k, "wait_frames timeout", v, k);
        end
    endtask
    task wait_mid_frame;                       // 30 clocks after a frame start
        begin @(negedge ws); repeat (30) @(posedge clk); #1; end
    endtask

    // ---- PT8211 receiver model / recorder --------------------------------
    reg  [15:0] shreg = 0, rx_l = 0;
    reg         ws_q = 0;
    reg  [31:0] rx_frame [0:8191];              // {R, L} as the DAC would hold
    integer     rx_count = 0, ws_falls = 0;
    always @(posedge bck) begin
        if (ws != ws_q) begin
            if (!ws_q) rx_l <= shreg;
            else begin rx_frame[rx_count] <= {shreg, rx_l}; rx_count <= rx_count + 1; end
        end
        shreg <= {shreg[14:0], din};
        ws_q  <= ws;
    end
    always @(negedge ws) ws_falls = ws_falls + 1;
    task rx_clear; begin @(posedge clk); rx_count = 0; end endtask

    // ---- models ----------------------------------------------------------
    reg [31:0] model_crc; integer model_frames;
    task model_reset; begin model_crc = 32'hFFFFFFFF; model_frames = 0; end endtask
    task model_byte(input [7:0] b);
        integer i;
        begin
            model_crc = model_crc ^ b;
            for (i = 0; i < 8; i = i + 1)
                model_crc = (model_crc >> 1) ^ (model_crc[0] ? 32'hEDB88320 : 0);
        end
    endtask
    task model_frame(input [31:0] f);
        begin
            model_byte(f[7:0]); model_byte(f[15:8]); model_byte(f[23:16]); model_byte(f[31:24]);
            model_frames = model_frames + 1;
        end
    endtask
    function [31:0] rnd_frame(input dummy);
        reg [31:0] r;
        begin r = $random; if (r[15:0] == 0) r[0] = 1'b1; rnd_frame = r; end  // never all-zero
    endfunction
    task fill(input integer n, input integer accept);  // write n frames, model the first `accept`
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) wbuf[i] = rnd_frame(0);
            for (i = 0; i < accept; i = i + 1) begin exp[exp_n] = wbuf[i]; exp_n = exp_n + 1; model_frame(wbuf[i]); end
            ahb_burst(n);
        end
    endtask
    reg [31:0] exp [0:8191]; integer exp_n;

    // recorder must hold: [zeros][exp[0..exp_n-1] in order (swapped if sw)][zeros]
    task check_sequence(input sw);
        integer i, j, data_seen;
        reg [31:0] e;
        begin
            i = 0; data_seen = 0;
            while (i < rx_count && rx_frame[i] == 0) i = i + 1;
            for (j = 0; j < exp_n; j = j + 1) begin
                e = sw ? {exp[j][15:0], exp[j][31:16]} : exp[j];
                if (i + j >= rx_count) begin
                    errors = errors + 1; $display("  FAIL: only %0d frames received, %0d expected", rx_count - i, exp_n); j = exp_n;
                end else if (rx_frame[i+j] !== e) begin
                    errors = errors + 1; $display("  FAIL: frame %0d: got %08x, expected %08x", j, rx_frame[i+j], e); j = exp_n;
                end else data_seen = data_seen + 1;
            end
            for (j = i + exp_n; j < rx_count; j = j + 1)
                if (rx_frame[j] !== 0) begin errors = errors + 1; $display("  FAIL: trailing frame %0d = %08x, not zero", j, rx_frame[j]); j = rx_count; end
            $display("  sequence: %0d leading zero frames, %0d data frames ok, %0d trailing zero frames",
                     i, data_seen, rx_count - i - exp_n);
        end
    endtask
    task check_stats(input [31:0] e_ur, input [31:0] e_or);
        reg [31:0] v;
        begin
            ahb_read(FRAMES, v);   check(v == model_frames, "FRAMES", v, model_frames);
            ahb_read(CRC, v);      check(v == ~model_crc, "CRC", v, ~model_crc);
            ahb_read(UNDERRUN, v); check(v == e_ur, "UNDERRUN", v, e_ur);
            ahb_read(OVERRUN, v);  check(v == e_or, "OVERRUN", v, e_or);
        end
    endtask
    task measure_rate(input [31:0] rate, input real fs);
        real t0, per;
        begin
            ahb_write(RATE, rate);
            repeat (3) @(negedge ws);
            @(negedge ws); t0 = $realtime;
            repeat (20) @(negedge ws);
            per = ($realtime - t0) / 20.0;
            $display("  RATE 0x%08x: frame period %.1f ns (expected %.1f), %.4f Hz", rate, per, 1e9 / fs, 1e9 / per);
            if (per < 1e9 / fs * 0.999 || per > 1e9 / fs * 1.001) begin
                errors = errors + 1; $display("  FAIL: frame rate off by more than 0.1 %%");
            end
        end
    endtask

    // ---- test sequence ----------------------------------------------------
    reg [31:0] v;
    integer f0, f1, i, ur_exp;
    initial begin
        #100 rstn = 1;
        repeat (5) @(posedge clk);

        $display("T1 reset values");
        ahb_read(ID, v);     check(v == 32'h41554430, "ID", v, 32'h41554430);
        ahb_read(DEPTH, v);  check(v == 2048, "DEPTH", v, 2048);
        ahb_read(RATE, v);   check(v == RATE_48K, "RATE reset", v, RATE_48K);
        ahb_read(STATUS, v); check(v == 32'h0001_0000 || v == 0, "STATUS reset", v, 0);
        ahb_read(CTRL, v);   check(v == 32'h20, "CTRL reset (amp on)", v, 32'h20);
        check(pa_en == 1, "PA_EN reset", pa_en, 1);
        ahb_read(CRC, v);    check(v == 0, "CRC reset (~0xFFFFFFFF)", v, 0);

        $display("T2 frame rate");
        measure_rate(RATE_48K, 48000.0);
        measure_rate(RATE_44K1, 44100.0);
        ahb_write(RATE, RATE_FAST);

        $display("T3 playback of 300 pre-filled frames, then 3 underrun frames");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0;
        fill(300, 300);
        ahb_read(STATUS, v); check(v[15:0] == 300, "level after 300 writes", v[15:0], 300);
        rx_clear;
        wait_mid_frame; ahb_write(CTRL, 32'h1);
        wait_frames(300);
        f0 = ws_falls; repeat (3) @(negedge ws); ahb_write(CTRL, 32'h0); f1 = ws_falls;  // 3 more frame starts = underruns
        repeat (3) @(negedge ws);
        check_sequence(0); check_stats(f1 - f0, 0);

        $display("T4 underrun before data: enable on an empty FIFO");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        wait_mid_frame; ahb_write(CTRL, 32'h1); f0 = ws_falls;
        repeat (4) @(negedge ws); wait_mid_frame; f1 = ws_falls;
        fill(50, 50);
        wait_frames(50); ahb_write(CTRL, 32'h0);
        repeat (3) @(negedge ws);
        check_sequence(0); check_stats(f1 - f0, 0);

        $display("T5 overrun + full flag, level interrupt, 2048 + 200 frames");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        fill(2058, 2048);
        ahb_read(STATUS, v); check(v[15:0] == 2048, "level full", v[15:0], 2048);
        check(v[17] == 1, "full flag", v, 0);
        ahb_read(OVERRUN, v); check(v == 10, "OVERRUN", v, 10);
        ahb_write(THRESH, 2049); ahb_read(STATUS, v); check(v[16] == 1, "STATUS.irq level<2049", v, 0);
        ahb_write(THRESH, 2048); ahb_read(STATUS, v); check(v[16] == 0, "STATUS.irq level<2048", v, 0);
        check(irq == 0, "irq pin without irq_en", irq, 0);
        ahb_write(THRESH, 1024);
        wait_mid_frame; ahb_write(CTRL, 32'h3);            // enable + irq_en
        repeat (3) @(posedge clk); check(irq == 0, "irq while level >= 1024", irq, 0);
        ahb_read(STATUS, v);
        while (v[15:0] >= 1024) ahb_read(STATUS, v);
        repeat (3) @(posedge clk); check(irq == 1, "irq when level < 1024", irq, 1);
        fill(200, 200);
        repeat (3) @(posedge clk); check(irq == 0, "irq cleared by refill", irq, 0);
        ahb_read(STATUS, v); check(v[16] == 0, "STATUS.irq after refill", v, 0);
        ahb_write(CTRL, 32'h1);                             // irq_en off
        ahb_read(STATUS, v); while (v[15:0] >= 1024) ahb_read(STATUS, v);
        repeat (3) @(posedge clk); check(irq == 0, "irq masked", irq, 0);
        ahb_read(STATUS, v); check(v[16] == 1, "STATUS.irq while masked", v, 1);
        wait_frames(2248); ahb_write(CTRL, 32'h0);
        repeat (3) @(negedge ws);
        check_sequence(0); check_stats(0, 10);

        $display("T6 channel swap");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        fill(20, 20);
        wait_mid_frame; ahb_write(CTRL, 32'h9);            // enable + swap
        wait_frames(20); ahb_write(CTRL, 32'h0);
        repeat (3) @(negedge ws);
        check_sequence(1); check_stats(0, 0);

        $display("T7 FIFO reset mid-stream");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        fill(500, 500);
        wait_mid_frame; ahb_write(CTRL, 32'h1);
        ahb_read(FRAMES, v); while (v < 100) ahb_read(FRAMES, v);
        ahb_write(CTRL, 32'h5);                             // enable + FIFO reset
        ahb_read(STATUS, v);   check(v[15:0] == 0, "level after reset", v[15:0], 0);
        ahb_read(FRAMES, v);   check(v == 0, "FRAMES after reset", v, 0);
        ahb_read(CRC, v);      check(v == 0, "CRC after reset", v, 0);
        ahb_read(OVERRUN, v);  check(v == 0, "OVERRUN after reset", v, 0);
        ahb_read(CTRL, v);     check(v == 1, "CTRL after reset (bit 2 self-clears)", v, 1);
        wait_mid_frame; ahb_write(CTRL, 32'h0);
        ahb_read(UNDERRUN, v); check(v <= 2, "UNDERRUN after reset (frames before disable)", v, 0);
        // and it plays again after the reset
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        fill(40, 40);
        wait_mid_frame; ahb_write(CTRL, 32'h1);
        wait_frames(40); ahb_write(CTRL, 32'h0);
        repeat (3) @(negedge ws);
        check_sequence(0); check_stats(0, 0);

        $display("T8 stop when empty (CTRL[4]): the core disables itself, no underrun");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        fill(30, 30);
        wait_mid_frame; ahb_write(CTRL, 32'h11);           // enable + stop_empty
        wait_frames(30); repeat (4) @(negedge ws);
        ahb_read(CTRL, v);   check(v == 32'h10, "CTRL after self-stop", v, 32'h10);
        check_sequence(0); check_stats(0, 0);
        rx_clear; exp_n = 0;                                // model keeps running (no FIFO reset)
        fill(10, 10);                                       // more data: re-enable (as the driver's .ack)
        wait_mid_frame; ahb_write(CTRL, 32'h1);
        wait_frames(40); repeat (2) @(negedge ws); ahb_write(CTRL, 32'h0);
        repeat (3) @(negedge ws);
        check_sequence(0); check_stats(2, 0);              // 2 frame starts without stop_empty

        $display("T9 amplifier enable (CTRL[5]) drives PA_EN");
        ahb_write(CTRL, 32'h0);  repeat (2) @(posedge clk); check(pa_en == 0, "PA_EN off", pa_en, 0);
        ahb_write(CTRL, 32'h21); repeat (2) @(posedge clk); check(pa_en == 1, "PA_EN on with enable", pa_en, 1);
        ahb_read(CTRL, v);       check(v == 32'h21, "CTRL readback", v, 32'h21);
        ahb_write(CTRL, 32'h20);

        if (errors == 0) $display("RESULT: PASS (0 errors)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #200_000_000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
