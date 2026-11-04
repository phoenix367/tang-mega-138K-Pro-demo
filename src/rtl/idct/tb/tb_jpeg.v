`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_jpeg.v -- idct_core's JPEG path: the records jpeg_ref.py made from a
// real JPEG file (Huffman + quantisation tables, the scan with its raw
// entropy-coded bytes, flush-only records) go through the ring in a 64-bit
// AHB RAM with the CPU-side flow control; the decoded Y/U/V planes in the
// RAM must equal jpeg_ref.py's model of FFmpeg byte for byte, inside the
// picture, and nothing may be written below it.  CORRUPT=1: the frames
// before the last one carry damaged data -- the core must flag them (bad
// record), not hang, and still decode the last frame exactly.
//============================================================================
module tb_jpeg;
    parameter W = 96, H = 48, CW = 96, NW = 100, RING = 4096, CORRUPT = 0;
    localparam CH = ((H + 15) / 16) * 16;           // coded height
    localparam PH = H, PCH = (H + 1) / 2;           // picture lines per plane
    localparam YS = CW, CS = CW / 2;
    // memory map in the 1 MB RAM model: ring, then the three planes (a full 800x480 frame fits)
    localparam RING_BASE = 32'h10000, Y_BASE = 32'h30000;
    localparam U_BASE = Y_BASE + ((YS * (CH + 16) + 4095) / 4096) * 4096;
    localparam V_BASE = U_BASE + ((CS * (CH / 2 + 8) + 4095) / 4096) * 4096;

    reg hclk = 0; always #10 hclk = ~hclk;
    reg hresetn = 0;
    reg  [31:0] s_haddr = 0, s_hwdata = 0;
    reg  [1:0]  s_htrans = 0;
    reg         s_hwrite = 0, s_hsel = 0;
    wire [31:0] s_hrdata;
    wire        s_hready, s_hresp, irq;
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
    ahb_slave_ram64 #(.AW(17)) ram (
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

    reg [63:0] words [0:131071];
    reg [7:0]  exp_y [0:CW*CH-1];
    reg [7:0]  exp_u [0:CS*CH/2-1];
    reg [7:0]  exp_v [0:CS*CH/2-1];

    // CPU-side ring writer: wait for HEAD before overwriting, publish TAIL every 8 words
    integer tail, pub;
    reg [31:0] head_r;
    task ring_word(input [63:0] w);
        integer free;
        begin
            free = RING - ((tail - head_r) & (RING - 1)) - 8;
            while (free < 8) begin
                if (pub != tail) begin reg_wr(8'h10, tail); pub = tail; end
                repeat (20) @(posedge hclk);
                reg_rd(8'h14, head_r);
                free = RING - ((tail - head_r) & (RING - 1)) - 8;
            end
            ram.mem[(RING_BASE + tail) >> 3] = w;
            tail = (tail + 8) & (RING - 1);
            if (((tail >> 3) & 7) == 0) begin reg_wr(8'h10, tail); pub = tail; end
        end
    endtask

    integer errors, x, y, k, irq_count, nblk;
    reg [31:0] r, st;
    integer t_start, t_end;
    reg [7:0] got;
    always @(posedge irq) irq_count = irq_count + 1;

    initial begin
        errors = 0; irq_count = 0; tail = 0; pub = 0; head_r = 0;
        $readmemh("ring.hex", words);
        $readmemh("exp_y.hex", exp_y);
        $readmemh("exp_u.hex", exp_u);
        $readmemh("exp_v.hex", exp_v);
        for (k = 0; k < 131072; k = k + 1) ram.mem[k] = 64'h0;
        repeat (5) @(posedge hclk); hresetn = 1; repeat (5) @(posedge hclk);

        reg_rd(8'h04, r);
        if (!r[8]) begin errors = errors + 1; $display("  STATUS[8] (JPEG records) not set: %08x", r); end
        reg_wr(8'h08, RING_BASE);
        reg_wr(8'h0C, RING - 1);
        reg_wr(8'h18, Y_BASE); reg_wr(8'h1C, U_BASE); reg_wr(8'h20, V_BASE);
        reg_wr(8'h24, {16'(CS), 16'(YS)});
        reg_wr(8'h28, {16'(H), 16'(CW)});
        reg_wr(8'h00, 32'h5);                          // enable + done irq

        t_start = $time;
        for (k = 0; k < NW; k = k + 1) ring_word(words[k]);
        if (pub != tail) begin reg_wr(8'h10, tail); pub = tail; end

        reg_rd(8'h04, st); k = 0;
        while (st[0] && k < 400000) begin repeat (10) @(posedge hclk); reg_rd(8'h04, st); k = k + 1; end
        t_end = $time;
        if (st[0]) begin errors = errors + 1; $display("  still busy"); end
        if (!st[1]) begin errors = errors + 1; $display("  no done irq flag"); end
        if (st[3] !== CORRUPT[0]) begin errors = errors + 1; $display("  bad flag %0d, expected %0d", st[3], CORRUPT); end
        repeat (20) @(posedge hclk);
        if (irq_count != 1) begin errors = errors + 1; $display("  irq fired %0d times", irq_count); end
        reg_rd(8'h2C, r); nblk = r;
        if (!CORRUPT && nblk != (CW / 16) * (CH / 16) * 6) begin
            errors = errors + 1; $display("  blocks %0d, expected %0d", nblk, (CW / 16) * (CH / 16) * 6); end

        for (y = 0; y < PH; y = y + 1)
            for (x = 0; x < CW; x = x + 1) begin
                got = ram.mem[(Y_BASE + y * YS + x) >> 3][(x % 8) * 8 +: 8];
                if (got !== exp_y[y * CW + x]) begin errors = errors + 1; if (errors < 8) $display("  Y(%0d,%0d) got %0d exp %0d", x, y, got, exp_y[y * CW + x]); end
            end
        for (y = 0; y < PCH; y = y + 1)
            for (x = 0; x < CS; x = x + 1) begin
                got = ram.mem[(U_BASE + y * CS + x) >> 3][(x % 8) * 8 +: 8];
                if (got !== exp_u[y * CS + x]) begin errors = errors + 1; if (errors < 8) $display("  U(%0d,%0d) got %0d exp %0d", x, y, got, exp_u[y * CS + x]); end
                got = ram.mem[(V_BASE + y * CS + x) >> 3][(x % 8) * 8 +: 8];
                if (got !== exp_v[y * CS + x]) begin errors = errors + 1; if (errors < 8) $display("  V(%0d,%0d) got %0d exp %0d", x, y, got, exp_v[y * CS + x]); end
            end
`ifdef ROWMAP
        for (y = 0; y < PH; y = y + 1) begin
            k = 0;
            for (x = 0; x < CW; x = x + 1) if (ram.mem[(Y_BASE + y * YS + x) >> 3][(x % 8) * 8 +: 8] !== exp_y[y * CW + x]) k = k + 1;
            if (k) $display("  row map: Y line %0d: %0d bad", y, k);
        end
        for (y = 0; y < PCH; y = y + 1) begin
            k = 0;
            for (x = 0; x < CS; x = x + 1) begin
                if (ram.mem[(U_BASE + y * CS + x) >> 3][(x % 8) * 8 +: 8] !== exp_u[y * CS + x]) k = k + 1;
                if (ram.mem[(V_BASE + y * CS + x) >> 3][(x % 8) * 8 +: 8] !== exp_v[y * CS + x]) k = k + 1000;
            end
            if (k) $display("  row map: C line %0d: %0d U bad, %0d V bad", y, k % 1000, k / 1000);
        end
`endif
        for (x = 0; x < CW; x = x + 8)
            if (ram.mem[(Y_BASE + PH * YS + x) >> 3] !== 64'h0) begin errors = errors + 1; $display("  Y written below the picture at x=%0d", x); end
        for (x = 0; x < CS; x = x + 8)
            if (ram.mem[(U_BASE + PCH * CS + x) >> 3] !== 64'h0 || ram.mem[(V_BASE + PCH * CS + x) >> 3] !== 64'h0) begin
                errors = errors + 1; $display("  chroma written below the picture at x=%0d", x); end

        if (errors == 0) $display("RESULT: PASS (%0dx%0d, %0d blocks bit-exact%s, ring %0d, %0d words, %0d cycles/block)",
                                  W, H, nblk, CORRUPT ? " after corrupt frames" : "", RING, NW, (t_end - t_start) / 20 / nblk);
        else $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #2000000000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
