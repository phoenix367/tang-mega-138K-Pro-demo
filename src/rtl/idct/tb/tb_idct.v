`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_idct.v -- idct_core on a 64-bit AHB RAM (the EXTM memory model): a
// small 4:2:0 frame of random sparse blocks is written as records into a
// ring in that RAM (with the CPU-side flow control: wait for HEAD before
// overwriting), the core runs, and the Y/U/V planes in the RAM are compared
// pixel by pixel with a model of FFmpeg's integer IDCT (the same functions
// as libavcodec/simple_idct_template.c).  FLAGS=0 relies on the automatic
// band flush (only the frame's last blocks carry the flag); H selects the
// height (a non-multiple of 16 exercises the clipped last band); RING the
// ring size (small = wraps).  The done interrupt must fire exactly once.
//============================================================================
module tb_idct;
    parameter W = 96, H = 48, FLAGS = 1, RING = 4096;

    reg hclk = 0; always #10 hclk = ~hclk;
    reg hresetn = 0;

    // registers
    reg  [31:0] s_haddr = 0, s_hwdata = 0;
    reg  [1:0]  s_htrans = 0;
    reg         s_hwrite = 0, s_hsel = 0;
    wire [31:0] s_hrdata;
    wire        s_hready, s_hresp, irq;
    // master <-> RAM
    wire        m_busy, m_hwrite, m_hready, m_hresp;
    wire [31:0] m_haddr;
    wire [1:0]  m_htrans;
    wire [2:0]  m_hsize, m_hburst;
    wire [63:0] m_hwdata, m_hrdata;

    idct_core dut (
        .hclk(hclk), .hresetn(hresetn),
        .s_haddr(s_haddr), .s_htrans(s_htrans), .s_hwrite(s_hwrite), .s_hsel(s_hsel),
        .s_hready_in(1'b1), .s_hwdata(s_hwdata), .s_hrdata(s_hrdata), .s_hready(s_hready), .s_hresp(s_hresp),
        .m_busy(m_busy), .m_haddr(m_haddr), .m_htrans(m_htrans), .m_hwrite(m_hwrite), .m_hsize(m_hsize),
        .m_hburst(m_hburst), .m_hwdata(m_hwdata), .m_hrdata(m_hrdata), .m_hready(m_hready), .m_hresp(m_hresp),
        .irq(irq)
    );
    ahb_slave_ram64 #(.AW(16)) ram (                 // 512 KB
        .hclk(hclk), .hresetn(hresetn), .haddr(m_haddr), .htrans(m_htrans), .hwrite(m_hwrite),
        .hsize(m_hsize), .hburst(m_hburst), .hwdata(m_hwdata), .hsel(1'b1), .hready_in(1'b1),
        .hrdata(m_hrdata), .hready(m_hready), .hresp(m_hresp)
    );

    task reg_wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge hclk); s_haddr = {24'hE80400, a}; s_htrans = 2'b10; s_hwrite = 1; s_hsel = 1;
            @(negedge hclk); s_htrans = 0; s_hsel = 0; s_hwrite = 0; s_hwdata = d;
            @(negedge hclk);
        end
    endtask
    task reg_rd(input [7:0] a, output [31:0] d);
        begin
            @(negedge hclk); s_haddr = {24'hE80400, a}; s_htrans = 2'b10; s_hwrite = 0; s_hsel = 1;
            @(negedge hclk); s_htrans = 0; s_hsel = 0;
            @(posedge hclk); #1 d = s_hrdata;
        end
    endtask

    // ---- FFmpeg simple_idct model ----
    localparam integer W1 = 22725, W2 = 21407, W3 = 19266, W4 = 16383, W5 = 12873, W6 = 8867, W7 = 4520;
    integer blk [0:63], tmp [0:63], out [0:63];
    task model_block;                                  // blk -> out (8-bit pixels)
        integer r, c, a0, a1, a2, a3, b0, b1, b2, b3, x0, x1, x2, x3, x4, x5, x6, x7, v;
        begin
            for (r = 0; r < 8; r = r + 1) begin
                x0 = blk[r*8]; x1 = blk[r*8+1]; x2 = blk[r*8+2]; x3 = blk[r*8+3];
                x4 = blk[r*8+4]; x5 = blk[r*8+5]; x6 = blk[r*8+6]; x7 = blk[r*8+7];
                if (x1 == 0 && x2 == 0 && x3 == 0 && x4 == 0 && x5 == 0 && x6 == 0 && x7 == 0) begin
                    v = x0 * 8; v = v & 32'hFFFF; if (v >= 32768) v = v - 65536;
                    for (c = 0; c < 8; c = c + 1) tmp[r*8+c] = v;
                end else begin
                    a0 = W4*x0 + W2*x2 + W4*x4 + W6*x6 + 1024; a1 = W4*x0 + W6*x2 - W4*x4 - W2*x6 + 1024;
                    a2 = W4*x0 - W6*x2 - W4*x4 + W2*x6 + 1024; a3 = W4*x0 - W2*x2 + W4*x4 - W6*x6 + 1024;
                    b0 = W1*x1 + W3*x3 + W5*x5 + W7*x7; b1 = W3*x1 - W7*x3 - W1*x5 - W5*x7;
                    b2 = W5*x1 - W1*x3 + W7*x5 + W3*x7; b3 = W7*x1 - W5*x3 + W3*x5 - W1*x7;
                    tmp[r*8+0] = sx16((a0 + b0) >>> 11); tmp[r*8+1] = sx16((a1 + b1) >>> 11);
                    tmp[r*8+2] = sx16((a2 + b2) >>> 11); tmp[r*8+3] = sx16((a3 + b3) >>> 11);
                    tmp[r*8+4] = sx16((a3 - b3) >>> 11); tmp[r*8+5] = sx16((a2 - b2) >>> 11);
                    tmp[r*8+6] = sx16((a1 - b1) >>> 11); tmp[r*8+7] = sx16((a0 - b0) >>> 11);
                end
            end
            for (c = 0; c < 8; c = c + 1) begin
                x0 = tmp[c]; x1 = tmp[8+c]; x2 = tmp[16+c]; x3 = tmp[24+c];
                x4 = tmp[32+c]; x5 = tmp[40+c]; x6 = tmp[48+c]; x7 = tmp[56+c];
                a0 = W4*x0 + W2*x2 + W4*x4 + W6*x6 + 524256; a1 = W4*x0 + W6*x2 - W4*x4 - W2*x6 + 524256;
                a2 = W4*x0 - W6*x2 - W4*x4 + W2*x6 + 524256; a3 = W4*x0 - W2*x2 + W4*x4 - W6*x6 + 524256;
                b0 = W1*x1 + W3*x3 + W5*x5 + W7*x7; b1 = W3*x1 - W7*x3 - W1*x5 - W5*x7;
                b2 = W5*x1 - W1*x3 + W7*x5 + W3*x7; b3 = W7*x1 - W5*x3 + W3*x5 - W1*x7;
                out[0*8+c] = clip((a0 + b0) >>> 20); out[1*8+c] = clip((a1 + b1) >>> 20);
                out[2*8+c] = clip((a2 + b2) >>> 20); out[3*8+c] = clip((a3 + b3) >>> 20);
                out[4*8+c] = clip((a3 - b3) >>> 20); out[5*8+c] = clip((a2 - b2) >>> 20);
                out[6*8+c] = clip((a1 - b1) >>> 20); out[7*8+c] = clip((a0 - b0) >>> 20);
            end
        end
    endtask
    function integer sx16(input integer v);            // keep 16 bits, signed
        integer t; begin t = v & 32'hFFFF; sx16 = (t >= 32768) ? t - 65536 : t; end
    endfunction
    function integer clip(input integer v); clip = v < 0 ? 0 : v > 255 ? 255 : v; endfunction

    // ---- frame geometry and memory map ----
    localparam RING_BASE = 32'h10000, Y_BASE = 32'h20000, U_BASE = 32'h40000, V_BASE = 32'h50000;
    localparam YS = W, CS = W / 2;                     // strides (multiples of 8: W multiple of 16)
    localparam CH = H / 2, CW = W / 2;
    integer model_y [0:127][0:2047];                   // up to 2048 wide (the band RAM's limit), 128 high
    integer model_u [0:63][0:1023], model_v [0:63][0:1023];

    // ---- CPU-side ring writer with flow control ----
    integer tail;
    reg [31:0] head_r;
    task ring_word(input [63:0] w);
        integer free;
        begin
            reg_rd(8'h14, head_r);
            free = RING - ((tail - head_r) & (RING - 1)) - 8;
            while (free < 8) begin
                repeat (20) @(posedge hclk);
                reg_rd(8'h14, head_r);
                free = RING - ((tail - head_r) & (RING - 1)) - 8;
            end
            ram.mem[(RING_BASE + tail) >> 3] = w;
            tail = (tail + 8) & (RING - 1);
            reg_wr(8'h10, tail);                       // publish each word (the CPU would batch)
        end
    endtask
    // write one block record (blk[] holds the coefficients), compute the model
    task put_block(input integer plane, input integer x, input integer y, input integer flush, input integer irqf);
        integer n, i;
        reg [63:0] w;
        begin
            n = 0;
            for (i = 0; i < 64; i = i + 1) if (blk[i] != 0) n = i + 1;
            w = 0;
            w[6:0] = n; w[7] = flush; w[9:8] = plane; w[21:10] = x; w[33:22] = y; w[34] = irqf;
            ring_word(w);
            for (i = 0; i < n; i = i + 4) begin
                w = 0;
                w[15:0]  = blk[i];
                w[31:16] = (i + 1 < n) ? blk[i+1] : 16'd0;
                w[47:32] = (i + 2 < n) ? blk[i+2] : 16'd0;
                w[63:48] = (i + 3 < n) ? blk[i+3] : 16'd0;
                ring_word(w);
            end
            model_block;
            for (i = 0; i < 64; i = i + 1)
                case (plane)
                    0: model_y[y + i / 8][x + i % 8] = out[i];
                    1: model_u[y + i / 8][x + i % 8] = out[i];
                    default: model_v[y + i / 8][x + i % 8] = out[i];
                endcase
        end
    endtask
    // flush-only record (header bit 35): the plane's band if dirty, nothing else
    task put_flush(input integer plane, input integer irqf);
        reg [63:0] w;
        begin
            w = 0; w[9:8] = plane; w[34] = irqf; w[35] = 1'b1;
            ring_word(w);
        end
    endtask
    task random_block(input integer kind);
        integer i, lim;
        begin
            lim = (kind == 0) ? 1 : (kind == 1) ? 6 : (kind == 2) ? 20 : 64;   // DC-only, sparse, medium, dense
            for (i = 0; i < 64; i = i + 1)
                blk[i] = (i < lim) ? ($random % 1024) : 0;
            if (kind == 4) for (i = 0; i < 64; i = i + 1) blk[i] = ($random % 2 == 0) ? 2047 : -2048;   // clamp stress
        end
    endtask

    integer errors, x, y, mx, my, nmcu_x, nmcu_y, k, last_mcu, nblocks, irq_count;
    reg [31:0] r, st;
    integer t_start, t_end;
    reg [7:0] got;
    always @(posedge irq) irq_count = irq_count + 1;

    initial begin
        errors = 0; irq_count = 0; tail = 0;
        for (y = 0; y < 128; y = y + 1) for (x = 0; x < 2048; x = x + 1) model_y[y][x] = 0;
        for (y = 0; y < 64; y = y + 1) for (x = 0; x < 1024; x = x + 1) begin model_u[y][x] = 0; model_v[y][x] = 0; end
        for (k = 0; k < 65536; k = k + 1) ram.mem[k] = 64'h0;
        repeat (5) @(posedge hclk); hresetn = 1; repeat (5) @(posedge hclk);

        reg_rd(8'h34, r);
        if (r !== 32'h49444354) begin errors = errors + 1; $display("  ID %08x", r); end
        reg_rd(8'h04, r);                              // capabilities: JPEG records, 2048-wide bands
        if (r[9:8] !== 2'b11) begin errors = errors + 1; $display("  STATUS capabilities %b", r[9:8]); end
        reg_wr(8'h08, RING_BASE);
        reg_wr(8'h0C, RING - 1);
        reg_wr(8'h18, Y_BASE); reg_wr(8'h1C, U_BASE); reg_wr(8'h20, V_BASE);
        reg_wr(8'h24, {16'(CS), 16'(YS)});
        reg_wr(8'h28, {16'(H), 16'(W)});
        reg_wr(8'h00, 32'h5);                          // enable + done irq

        // MCU order like a 4:2:0 baseline JPEG: Y0 Y1 Y2 Y3 U V per 16x16 MCU
        nmcu_x = W / 16; nmcu_y = (H + 15) / 16; nblocks = 0;
        t_start = $time;
        for (my = 0; my < nmcu_y; my = my + 1)
            for (mx = 0; mx < nmcu_x; mx = mx + 1) begin
                last_mcu = (mx == nmcu_x - 1);
                for (k = 0; k < 4; k = k + 1) begin
                    random_block((mx + my + k) % 5);
                    put_block(0, mx * 16 + (k % 2) * 8, my * 16 + (k / 2) * 8,
                              (FLAGS == 1 || (FLAGS == 0 && my == nmcu_y - 1)) && last_mcu && k == 3, 0);
                    nblocks = nblocks + 1;
                end
                random_block((mx * 3 + my) % 5);
                put_block(1, mx * 8, my * 8, (FLAGS == 1 || (FLAGS == 0 && my == nmcu_y - 1)) && last_mcu, 0);
                random_block((mx + my * 7) % 5);
                put_block(2, mx * 8, my * 8, (FLAGS == 1 || (FLAGS == 0 && my == nmcu_y - 1)) && last_mcu, FLAGS != 2 && my == nmcu_y - 1 && last_mcu);
                nblocks = nblocks + 2;
            end
        if (FLAGS == 2) begin                          // no flags at all: flush-only records end the frame
            put_flush(0, 0); put_flush(1, 0); put_flush(2, 1);
            put_flush(0, 0);                           // a second one on a clean band: no-op
        end

        // wait for idle
        reg_rd(8'h04, st); k = 0;
        while (st[0] && k < 200000) begin repeat (10) @(posedge hclk); reg_rd(8'h04, st); k = k + 1; end
        t_end = $time;
        if (st[0]) begin errors = errors + 1; $display("  still busy"); end
        if (!st[1]) begin errors = errors + 1; $display("  no done irq flag"); end
        if (st[3]) begin errors = errors + 1; $display("  bad-record flag set"); end
        repeat (20) @(posedge hclk);
        if (irq_count != 1) begin errors = errors + 1; $display("  irq fired %0d times", irq_count); end
        reg_wr(8'h04, 32'h2);                          // clear
        reg_rd(8'h04, st);
        if (st[1] || irq) begin errors = errors + 1; $display("  done irq not cleared"); end
        reg_rd(8'h2C, r);
        if (r != nblocks) begin errors = errors + 1; $display("  blocks %0d, expected %0d", r, nblocks); end

        // compare the planes (only inside the frame; the band flush clips)
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1) begin
                got = ram.mem[(Y_BASE + y * YS + x) >> 3][(x % 8) * 8 +: 8];
                if (got !== model_y[y][x]) begin errors = errors + 1; if (errors < 8) $display("  Y(%0d,%0d) got %0d exp %0d", x, y, got, model_y[y][x]); end
            end
        for (y = 0; y < CH; y = y + 1)
            for (x = 0; x < CW; x = x + 1) begin
                got = ram.mem[(U_BASE + y * CS + x) >> 3][(x % 8) * 8 +: 8];
                if (got !== model_u[y][x]) begin errors = errors + 1; if (errors < 8) $display("  U(%0d,%0d) got %0d exp %0d", x, y, got, model_u[y][x]); end
                got = ram.mem[(V_BASE + y * CS + x) >> 3][(x % 8) * 8 +: 8];
                if (got !== model_v[y][x]) begin errors = errors + 1; if (errors < 8) $display("  V(%0d,%0d) got %0d exp %0d", x, y, got, model_v[y][x]); end
            end
        // nothing written past the planes' last lines
        for (x = 0; x < W; x = x + 8)
            if (ram.mem[(Y_BASE + H * YS + x) >> 3] !== 64'h0) begin errors = errors + 1; $display("  Y written past the frame at x=%0d", x); end
        for (x = 0; x < CW; x = x + 8)
            if (ram.mem[(U_BASE + CH * CS + x) >> 3] !== 64'h0 || ram.mem[(V_BASE + CH * CS + x) >> 3] !== 64'h0) begin
                errors = errors + 1; $display("  chroma written past the frame at x=%0d", x); end

        if (errors == 0) $display("RESULT: PASS (%0dx%0d, %0d blocks bit-exact, flags=%0d ring=%0d, %0d ns = %0d cycles/block)",
                                  W, H, nblocks, FLAGS, RING, t_end - t_start, (t_end - t_start) / 20 / nblocks);
        else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #50000000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
