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
    // DMA master port -> 64-bit memory model (ring buffer at 0x0010_0000)
    wire        m_busy, m_hwrite, m_hready, m_hresp;
    wire [31:0] m_haddr;
    wire [1:0]  m_htrans;
    wire [2:0]  m_hsize, m_hburst;
    wire [63:0] m_hwdata, m_hrdata;

    audio_core dut (
        .hclk(clk), .hresetn(rstn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel),
        .s_hready_in(hready), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .irq(irq), .i2s_bck(bck), .i2s_ws(ws), .i2s_din(din), .pa_en(pa_en),
        .m_busy(m_busy), .m_haddr(m_haddr), .m_htrans(m_htrans), .m_hwrite(m_hwrite), .m_hsize(m_hsize),
        .m_hburst(m_hburst), .m_hwdata(m_hwdata), .m_hrdata(m_hrdata), .m_hready(m_hready), .m_hresp(m_hresp)
    );
    localparam RING = 32'h0010_0000;
    localparam DMA_ADDR = 8'h30, DMA_SIZE = 8'h34, DMA_PERIOD = 8'h38, DMA_LIMIT = 8'h3C, DMA_FETCH = 8'h40,
               DMA_IRQ = 8'h44, DMA_FILL = 8'h48;
    reg [63:0] mem [0:8191];                   // 64 KB
    reg        mdph = 0; reg [63:0] mrd_q; reg mwait = 0; integer mws = 0; integer m_reads = 0;
    assign m_hready = !mwait;
    assign m_hresp  = 1'b0;
    assign m_hrdata = mrd_q;
    always @(posedge clk) begin
        if (m_hready) begin
            mdph <= m_htrans[1];
            if (m_htrans[1] && !m_hwrite) begin mrd_q <= mem[(m_haddr - RING) >> 3]; m_reads = m_reads + 1; end
        end
        if (m_htrans[1] || mdph) begin
            if (!mwait && ($random % 5 == 0)) begin mwait <= 1; mws <= 1 + ($random & 3); end
            else if (mwait) begin if (mws == 0) mwait <= 0; else mws <= mws - 1; end
        end else mwait <= 0;
    end
    // put n random frames into the ring (frame i at byte 4*i) and model them
    task ring_fill(input integer n, input integer model_n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) wbuf[i] = rnd_frame(0);
            for (i = 0; i < n; i = i + 2) mem[i >> 1] = {wbuf[i+1], wbuf[i]};
            for (i = 0; i < model_n; i = i + 1) begin exp[exp_n] = wbuf[i % n]; exp_n = exp_n + 1; model_frame(wbuf[i % n]); end
        end
    endtask

    integer errors = 0;
    integer irqs = 0;

    // period interrupts: count and clear (as the driver would)
    always @(posedge irq) begin
        irqs = irqs + 1;
        @(posedge clk); #1;
        haddr = BASE | DMA_IRQ; htrans = 2'b10; hwrite = 1; hsel = 1;
        @(posedge clk); #1; htrans = 0; hsel = 0; hwdata = 32'h3;
        @(posedge clk); #1;
    end
    // underruns expected after the limit: whatever the serialiser output as zeros is counted
    function integer f_after_limit(input dummy);
        begin f_after_limit = dut.underruns; end
    endfunction
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

        // ---- DMA mode --------------------------------------------------------
        // (a) 1024-frame ring, all committed, 64-frame period: bit-exact output,
        //     one period IRQ per 64 frames fetched, no underrun
        $display("DMA: full ring");
        ahb_write(THRESH, 0);                                 // level irq off for the period-count checks
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        ring_fill(1024, 1024);
        ahb_write(DMA_ADDR, RING); ahb_write(DMA_SIZE, 1024 * 4); ahb_write(DMA_PERIOD, 64 * 4);
        ahb_write(DMA_LIMIT, 1024 * 4); ahb_write(DMA_FILL, 32'h0020_0200);   // fill to 512, 32 beats
        ahb_write(RATE, RATE_FAST);
        irqs = 0;
        wait_mid_frame; ahb_write(CTRL, 32'h43);           // enable + irq_en + dma
        wait_frames(1024);
        ahb_read(DMA_FETCH, v); check(v == 4096, "DMA_FETCH all", v, 4096);
        ahb_read(STATUS, v);    check(v[15:0] == 0, "FIFO empty at limit", v[15:0], 0);
        repeat (2000) @(posedge clk);
        ahb_write(CTRL, 32'h0);
        check_sequence(0); check_stats(f_after_limit(0), 0);
        $display("  period irqs seen: %0d (expect 16), bus reads %0d", irqs, m_reads);
        check(irqs == 16, "period irqs", irqs, 16);
        // (b) limit semantics: commit 300 frames, play, commit 200 more later
        $display("DMA: limit");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear; irqs = 0;
        ring_fill(1024, 300);
        ahb_write(DMA_LIMIT, 300 * 4);
        wait_mid_frame; ahb_write(CTRL, 32'h43);
        wait_frames(300);
        ahb_read(DMA_FETCH, v); check(v == 1200, "fetched exactly the limit", v, 1200);
        repeat (400) @(posedge ws);                           // zeros while nothing is committed
        exp_n = 0; model_reset; rx_clear;                    // restart the recorder's expectation
        ring_fill(1024, 0);                                   // new ring contents
        for (i = 300; i < 500; i = i + 1) begin exp[exp_n] = wbuf[i]; exp_n = exp_n + 1; end
        ahb_write(DMA_LIMIT, 500 * 4);
        wait_frames(500);
        repeat (300) @(posedge clk);
        ahb_write(CTRL, 32'h0);
        check_sequence(0);
        ahb_read(UNDERRUN, v); $display("  underruns while starved: %0d (expected > 0)", v);
        check(v > 0, "underruns counted while starved", v, 1);
        // (c) ring wrap: 256-frame ring, 1000 frames committed
        $display("DMA: wrap");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear; irqs = 0;
        ring_fill(256, 1000);
        ahb_write(DMA_SIZE, 256 * 4); ahb_write(DMA_LIMIT, 1000 * 4); ahb_write(DMA_PERIOD, 256 * 4);
        wait_mid_frame; ahb_write(CTRL, 32'h43);
        wait_frames(1000);
        repeat (300) @(posedge clk);
        ahb_write(CTRL, 32'h0);
        check_sequence(0); check_stats(f_after_limit(0), 0);
        check(irqs == 3, "wrap period irqs", irqs, 3);
        // (d) end of stream: THRESH=1 raises the level irq once the FIFO runs dry after the limit
        $display("DMA: end-of-stream level irq");
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear; irqs = 0;
        ring_fill(256, 64);
        ahb_write(DMA_SIZE, 256 * 4); ahb_write(DMA_LIMIT, 64 * 4); ahb_write(DMA_PERIOD, 1024 * 4);
        ahb_write(THRESH, 1);
        wait_mid_frame; ahb_write(CTRL, 32'h43 | 32'h10);     // + stop_empty
        wait_frames(64);
        repeat (3) @(posedge ws);
        check(irq == 1, "level irq at end of stream", irq, 1);
        ahb_read(CTRL, v); check(v[0] == 0, "stopped by stop_empty", v, 0);
        ahb_read(UNDERRUN, v); check(v == 0, "no underrun for the tail", v, 0);
        ahb_write(CTRL, 32'h0);
        check_sequence(0);
        // (e) odd frame counts: limits ending mid-beat (65, then 130, then 131 frames)
        $display("DMA: odd limits");
        ahb_write(THRESH, 0);
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear; irqs = 0;
        ring_fill(256, 131);
        ahb_write(DMA_SIZE, 256 * 4); ahb_write(DMA_PERIOD, 0);
        ahb_write(DMA_LIMIT, 65 * 4);
        wait_mid_frame; ahb_write(CTRL, 32'h43);
        wait_frames(65);
        ahb_read(DMA_FETCH, v); check(v == 65 * 4, "fetched 65 frames", v, 260);
        ahb_write(DMA_LIMIT, 130 * 4);
        wait_frames(130);
        ahb_read(DMA_FETCH, v); check(v == 130 * 4, "fetched 130 frames", v, 520);
        ahb_write(DMA_LIMIT, 131 * 4);
        wait_frames(131);
        repeat (300) @(posedge clk);
        ahb_write(CTRL, 32'h0);
        check_sequence(0);
        // also across the ring end: 255 frames in a 256-frame ring, then 257
        ahb_write(CTRL, 32'h4); model_reset; exp_n = 0; rx_clear;
        ring_fill(256, 257);
        ahb_write(DMA_LIMIT, 255 * 4);
        wait_mid_frame; ahb_write(CTRL, 32'h43);
        wait_frames(255);
        ahb_write(DMA_LIMIT, 257 * 4);
        wait_frames(257);
        repeat (300) @(posedge clk);
        ahb_write(CTRL, 32'h0);
        check_sequence(0);
        // (f) FIFO reset clears the fetch counters
        ahb_write(CTRL, 32'h4);
        ahb_read(DMA_FETCH, v); check(v == 0, "DMA_FETCH after reset", v, 0);
        ahb_read(DMA_IRQ, v);   check(v == 0, "DMA_IRQ after reset", v, 0);

        if (errors == 0) $display("RESULT: PASS (0 errors)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #200_000_000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
