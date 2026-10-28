`timescale 1ns/1ps
// Randomized self-checking test for ahb_ddr3_bridge.
//
// A pipelined AHB-lite master issues the A25's real access patterns (WRAP4
// 64-bit line fills, critical word first; WRAP4 evictions; SINGLE accesses of
// every size; plus INCR4 / undefined-INCR bursts and ascending line streams)
// over a small address window so line-buffer hits, write invalidations and
// in-flight conflicts happen constantly.  Every read beat is checked against a
// byte-accurate reference memory updated in AHB bus order.
//
// +video=P adds a client on the video read port: P % of uclk cycles it wants
// a BL8 read of a second window [WIN, 2*WIN) that AHB traffic never writes,
// and every return is checked against the DDR model (routing by issue order).
//
// +wrheavy makes the traffic back-to-back line evictions (posted writes keep
// the command FIFO full -- the case that would starve the video port), and
// +vmaxwait=N fails the run if a video request waits longer than N uclk.
//
// Plusargs: +seed=N +ops=N +hclk_ns=N +uclk_ns=N +video=P +wrheavy +vmaxwait=N
module tb_ahb_ddr3_bridge;
    parameter NBUF     = 8;
    parameter PREFETCH = 1;
    parameter ADDR_BITS = 28;                  // bridge address width (28 = 256 MB, 29 = 512 MB)
    parameter WIN      = 4096;                 // bytes exercised (power of 2)
    parameter XROW_REORDER = 0;                // DDR model may reorder cross-row reads (the real MC
                                               // does not -- read BIST on hardware: 0 errors)
    parameter LAT_MIN  = 6;                    // DDR model read latency (uclk); HW measures ~28
    parameter LAT_MAX  = 24;

    integer seed = 1, ops = 20000, hclk_ns = 20, uclk_ns = 10;
    integer busy_pct = 20;                      // +busy=N: % chance of BUSY before a SEQ beat
    initial if ($value$plusargs("busy=%d", busy_pct)) ;
    reg [31:0] tb_mode = 32'd0;                 // +mode=N or +mode=0xH: bridge debug mode bits
    initial if (!$value$plusargs("mode=0x%h", tb_mode)) if ($value$plusargs("mode=%d", tb_mode)) ;
    // +bist=P: halfway through, run the read BIST (pattern P, 256 iterations)
    integer bist_pat = -1;
    initial if ($value$plusargs("bist=%d", bist_pat)) begin
        wait (done_ops >= ops / 2);
        tb_mode[26:25] = bist_pat; tb_mode[31:28] = 0;
        tb_mode[24] = ~tb_mode[24];
    end
    reg [31:0] dbg_line = 32'hFFFFFFFF;          // +dbg=<hex byte addr>: trace that 32 B line
    initial if ($value$plusargs("dbg=%h", dbg_line)) dbg_line = dbg_line & ~32'h1F;
    always @(posedge uclk)
        if (cmd_en && ({addr[26:0], 1'b0} & ~32'h1F) == dbg_line)
            $display("%0t   DDR %s addr %h data %h mask %h", $time, cmd[0] ? "RD" : "WR",
                     {addr[26:0], 1'b0}, wr_data, wr_data_mask);
    reg hclk = 0, uclk = 0, hresetn = 0;
    initial begin
        if ($value$plusargs("seed=%d", seed)) ;
        if ($value$plusargs("ops=%d", ops)) ;
        if ($value$plusargs("hclk_ns=%d", hclk_ns)) ;
        if ($value$plusargs("uclk_ns=%d", uclk_ns)) ;
    end
    always #(hclk_ns/2.0) hclk = ~hclk;
    initial begin #3.3; forever #(uclk_ns/2.0) uclk = ~uclk; end

    // AHB
    reg  [31:0] haddr = 0; reg [1:0] htrans = 0; reg hwrite = 0;
    reg  [2:0]  hsize = 0, hburst = 0; reg [3:0] hprot = 4'b0011;
    reg  [63:0] hwdata = 0;
    wire        hready; wire [1:0] hresp; wire [63:0] hrdata;
    // DDR UI
    wire        calib_done, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid;
    wire [2:0]  cmd; wire [ADDR_BITS-1:0] addr; wire [127:0] wr_data, rd_data; wire [15:0] wr_data_mask;
    wire [511:0] perf_cnt;
    integer ddr_errors;
    // video read port
    integer      vid_pct = 0, vmaxwait = 0;
    reg          wrheavy = 1'b0;
    initial if ($value$plusargs("video=%d", vid_pct)) ;
    initial if ($value$plusargs("vmaxwait=%d", vmaxwait)) ;
    initial if ($test$plusargs("wrheavy")) wrheavy = 1'b1;
    reg          v_req = 1'b0;
    reg  [31:0]  v_addr = 32'd0;
    wire         v_rstn, v_ack, v_rvalid;
    wire [127:0] v_rdata;

    ahb_ddr3_bridge #(.NBUF(NBUF), .PREFETCH(PREFETCH), .ADDR_BITS(ADDR_BITS)) dut (
        .hclk(hclk), .hresetn(hresetn), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hburst(hburst), .hprot(hprot), .hwdata(hwdata), .hready(hready),
        .hresp(hresp), .hrdata(hrdata), .mode(tb_mode), .perf_en(1'b1), .perf_clr(1'b0), .perf_cnt(perf_cnt),
        .uclk(uclk), .calib_done(calib_done), .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en),
        .addr(addr), .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en),
        .wr_data_end(wr_data_end), .wr_data_mask(wr_data_mask), .rd_data(rd_data),
        .rd_data_valid(rd_data_valid),
        .v_rstn(v_rstn), .v_req(v_req), .v_addr(v_addr[ADDR_BITS-1:0]), .v_ack(v_ack),
        .v_rvalid(v_rvalid), .v_rdata(v_rdata));

    ddr3_ui_model #(.WORDS(2*WIN/16), .XROW_REORDER(XROW_REORDER), .ADDR_W(ADDR_BITS),
                    .LAT_MIN(LAT_MIN), .LAT_MAX(LAT_MAX)) ddr (
        .clk(uclk), .calib_done(calib_done), .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en),
        .addr(addr), .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en),
        .wr_data_end(wr_data_end), .wr_data_mask(wr_data_mask), .rd_data(rd_data),
        .rd_data_valid(rd_data_valid), .errors(ddr_errors));

    // reference memory, initialised from the DDR model's random contents
    reg [7:0] refm [0:WIN-1];
    integer i, b;
    initial begin
        #1;
        for (i = 0; i < WIN/16; i = i + 1)
            for (b = 0; b < 16; b = b + 1)
                refm[i*16 + b] = ddr.mem[i][b*8 +: 8];
    end

    // ---------------- video client (uclk) ----------------
    reg  [27:0] vq [0:63];                     // addresses of video reads in flight
    integer     vq_w = 0, vq_r = 0, v_errors = 0, v_wait = 0, v_maxwait = 0;
    reg         v_seed_init = 0;
    integer     vseed;
    always @(posedge uclk) begin
        if (!v_seed_init) begin vseed = seed * 31 + 7; v_seed_init = 1; end
        if (v_rvalid) begin
            if (vq_r == vq_w) begin
                $display("%0t VIDEO: return with no read in flight", $time); v_errors = v_errors + 1;
            end else begin
                if (v_rdata !== ddr.mem[(vq[vq_r % 64] >> 4) % (2*WIN/16)]) begin
                    if (v_errors < 10) $display("%0t VIDEO MISMATCH addr %h: got %h exp %h", $time,
                                                vq[vq_r % 64], v_rdata, ddr.mem[(vq[vq_r % 64] >> 4) % (2*WIN/16)]);
                    v_errors = v_errors + 1;
                end
                vq_r = vq_r + 1;
            end
        end
        if (v_ack) begin vq[vq_w % 64] = v_addr; vq_w = vq_w + 1; end
        if (v_req && !v_ack) v_wait = v_wait + 1; else v_wait = 0;
        if (v_wait > v_maxwait) v_maxwait = v_wait;
        if (!v_req || v_ack) begin             // a request is held until issued
            v_req  <= (v_rstn === 1'b1) && done_ops < ops && ($random(vseed) & 32'h7fffffff) % 100 < vid_pct;
            v_addr <= WIN + (($random(vseed) & 32'h7fffffff) % (WIN/16)) * 16;
        end
    end

    // ---------------- beat queue (generator -> pipelined master) ----------------
    reg [31:0] qa [0:63]; reg qw_[0:63]; reg [2:0] qs [0:63], qb [0:63]; reg [1:0] qt [0:63];
    reg [63:0] qd [0:63];
    integer qh = 0, qn = 0;

    task push_beat(input [31:0] a, input w, input [2:0] s, input [2:0] hb, input [1:0] t);
        begin
            qa[(qh+qn)%64] = a; qw_[(qh+qn)%64] = w; qs[(qh+qn)%64] = s;
            qb[(qh+qn)%64] = hb; qt[(qh+qn)%64] = t;
            qd[(qh+qn)%64] = {$random(seed), $random(seed)};
            qn = qn + 1;
        end
    endtask

    integer stream_line = 0;
    task gen_op;
        integer r, line, k, crit, sz, n;
        reg w;
        reg [31:0] a;
        begin
            r = ($random(seed) & 32'h7fffffff) % 100;
            line = ($random(seed) & 32'h7fffffff) % (WIN/32);
            w = $random(seed);
            if (wrheavy && r < 90) begin r = 0; w = 1'b1; end   // mostly WRAP4 evictions
            if (r < 40) begin                      // WRAP4 64-bit line fill / eviction
                crit = ($random(seed) & 3);
                for (k = 0; k < 4; k = k + 1)
                    push_beat(line*32 + ((crit + k) % 4)*8, w, 3, 3'd2, k ? 2'b11 : 2'b10);
            end else if (r < 55) begin             // ascending stream of line fills
                for (n = 0; n < 4; n = n + 1) begin
                    stream_line = (stream_line + 1) % (WIN/32);
                    for (k = 0; k < 4; k = k + 1)
                        push_beat(stream_line*32 + k*8, 1'b0, 3, 3'd2, k ? 2'b11 : 2'b10);
                end
            end else if (r < 80) begin             // SINGLE of random size
                sz = ($random(seed) & 3);
                a  = ($random(seed) & (WIN-1)) & ~((1 << sz) - 1);
                push_beat(a, w, sz, 3'd0, 2'b10);
            end else if (r < 88) begin             // read-modify-write of one line,
                // back to back: read X, write into X, read X again (the read's
                // address phase lands on the write's data phase)
                crit = ($random(seed) & 3);
                for (k = 0; k < 4; k = k + 1)
                    push_beat(line*32 + ((crit + k) % 4)*8, 1'b0, 3, 3'd2, k ? 2'b11 : 2'b10);
                sz = ($random(seed) & 3);
                a  = line*32 + ((($random(seed) & 31)) & ~((1 << sz) - 1));
                push_beat(a, 1'b1, sz, 3'd0, 2'b10);
                for (k = 0; k < 4; k = k + 1)
                    push_beat(line*32 + ((crit + k) % 4)*8, 1'b0, 3, 3'd2, k ? 2'b11 : 2'b10);
            end else if (r < 93) begin             // INCR4 64-bit
                for (k = 0; k < 4; k = k + 1)
                    push_beat(line*32 + k*8, w, 3, 3'd3, k ? 2'b11 : 2'b10);
            end else begin                         // undefined-length INCR, 32-bit, may cross lines
                n = 1 + ($random(seed) & 7);
                a = (($random(seed) & (WIN-1)) & ~3);
                for (k = 0; k < n; k = k + 1)
                    push_beat((a + 4*k) & (WIN-1), w, 2, 3'd1, k ? 2'b11 : 2'b10);
            end
        end
    endtask

    // ---------------- pipelined AHB master ----------------
    reg        dpv = 0, dpw = 0; reg [31:0] dpa = 0; reg [2:0] dps = 0; reg [63:0] dpd = 0;
    integer    errors = 0, reads = 0, writes = 0, done_ops = 0, cyc = 0, stall = 0;
    reg [63:0] expv;

    always @(posedge hclk) if (hresetn) begin
        cyc = cyc + 1;
        if (!hready) stall = stall + 1;
        if (hready) begin
            // data phase completes
            if (dpv && (dpa & ~32'h1F) == dbg_line)
                $display("%0t AHB %s %h size %0d data %h (ref %h%h%h%h)", $time, dpw ? "WR" : "RD", dpa, dps,
                         dpw ? dpd : hrdata, refm[(dpa&~7)+3], refm[(dpa&~7)+2], refm[(dpa&~7)+1], refm[(dpa&~7)]);
            if (dpv) begin
                if (dpw) begin
                    for (b = 0; b < (1 << dps); b = b + 1)
                        refm[(dpa & ~((1 << dps) - 1)) + b] = dpd[((dpa[2:0] & ~((1 << dps) - 1)) + b)*8 +: 8];
                    writes = writes + 1;
                end else begin
                    for (b = 0; b < (1 << dps); b = b + 1) begin
                        if (hrdata[((dpa[2:0]) + b)*8 +: 8] !== refm[dpa + b]) begin
                            if (errors < 20)
                                $display("%0t READ MISMATCH addr %h size %0d byte %0d: got %h exp %h",
                                         $time, dpa, dps, b, hrdata[((dpa[2:0]) + b)*8 +: 8], refm[dpa + b]);
                            errors = errors + 1;
                        end
                    end
                    reads = reads + 1;
                end
            end
            // address phase -> data phase
            dpv = (htrans[1] === 1'b1);
            if (dpv) begin
                dpw = hwrite; dpa = haddr; dps = hsize;
                dpd = qd[(qh + 63) % 64];         // data of the beat just accepted
                hwdata <= dpw ? dpd : 64'hx;
            end
            // next address phase
            if (qn == 0 && done_ops < ops) begin
                if (!wrheavy && ($random(seed) & 3) == 0) begin   // idle gap between bursts
                    htrans <= 2'b00;
                end else begin
                    gen_op; done_ops = done_ops + 1;
                end
            end
            if (qn > 0 && qt[qh] == 2'b11 && busy_pct > 0 && ($random(seed) & 32'h7fffffff) % 100 < busy_pct) begin
                // BUSY inside a burst (the A25 does this): next beat's address, no transfer
                haddr <= qa[qh]; hwrite <= qw_[qh]; hsize <= qs[qh]; hburst <= qb[qh];
                htrans <= 2'b01;
            end else if (qn > 0) begin
                haddr <= qa[qh]; hwrite <= qw_[qh]; hsize <= qs[qh]; hburst <= qb[qh];
                htrans <= qt[qh];
                qh = (qh + 1) % 64; qn = qn - 1;
            end else if (qn == 0) begin
                htrans <= 2'b00;
            end
        end
    end

    initial begin
        #200 hresetn = 1;
        wait (done_ops >= ops && qn == 0);
        repeat (50) @(posedge hclk);
        wait (hready);
        // drain: every posted write must have been issued to the DDR model
        // before memory is compared (heavy back-pressure takes a while)
        wait (!dut.wb_valid && dut.wq_n == 0 && !dut.wh_v && !dut.cfq_push &&
              dut.cf_empty && !dut.hq_v && !dut.is_v);
        repeat (2000) @(posedge hclk);
        $display("seed %0d NBUF %0d PF %0d hclk %0dns uclk %0dns: %0d reads, %0d writes, %0d cycles, %0d stall",
                 seed, NBUF, PREFETCH, hclk_ns, uclk_ns, reads, writes, cyc, stall);
        $display("perf: hit0 %0d demand %0d prefetch %0d wrpush %0d | rdcmd %0d lat_sum %0d wrcmd %0d rdvalid %0d",
                 perf_cnt[31:0], perf_cnt[63:32], perf_cnt[95:64], perf_cnt[127:96],
                 perf_cnt[159:128], perf_cnt[191:160], perf_cnt[223:192], perf_cnt[255:224]);
        if (vid_pct > 0)
            $display("video: %0d reads, %0d returned, longest wait for issue %0d uclk, %0d errors",
                     vq_w, vq_r, v_maxwait, v_errors);
        if (vmaxwait > 0 && v_maxwait > vmaxwait) begin
            $display("VIDEO: a request waited %0d uclk (limit %0d)", v_maxwait, vmaxwait);
            v_errors = v_errors + 1;
        end
        if (vq_r != vq_w) begin
            $display("VIDEO: %0d reads never returned", vq_w - vq_r); v_errors = v_errors + 1;
        end
        errors = errors + v_errors;
        if (bist_pat >= 0)
            $display("bist: status %h err %0d reorder %0d first %h addr %h got %h exp %h extra %0d",
                     perf_cnt[287:256], perf_cnt[319:288], perf_cnt[351:320], perf_cnt[383:352],
                     perf_cnt[415:384], perf_cnt[447:416], perf_cnt[479:448], perf_cnt[511:480]);
        // final memory check: every byte the bridge wrote must be in DDR
        for (i = 0; i < WIN/16; i = i + 1)
            for (b = 0; b < 16; b = b + 1)
                if (ddr.mem[i][b*8 +: 8] !== refm[i*16 + b]) begin
                    if (errors < 40) $display("FINAL MISMATCH byte %h: ddr %h refm %h", i*16+b, ddr.mem[i][b*8 +: 8], refm[i*16+b]);
                    errors = errors + 1;
                end
        if (errors == 0 && ddr_errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED: %0d data errors, %0d DDR protocol errors", errors, ddr_errors);
        $finish;
    end

    initial begin
        #(64'd400_000_000);
        $display("TIMEOUT (deadlock?) ops %0d qn %0d hready %b", done_ops, qn, hready);
        $display("TEST FAILED");
        $finish;
    end
    // progress watchdog: no completed operation for 100k hclk cycles = deadlock
    integer wd_ops = -1, wd_cyc = 0;
    always @(posedge hclk) begin
        if (done_ops != wd_ops) begin wd_ops = done_ops; wd_cyc = 0; end
        else wd_cyc = wd_cyc + 1;
        if (wd_cyc == 100000) begin      // also covers the final drain
            $display("TIMEOUT (no progress for 100k hclk) ops %0d qn %0d hready %b", done_ops, qn, hready);
            $display("TEST FAILED");
            $finish;
        end
    end
endmodule
