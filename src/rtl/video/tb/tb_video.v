`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_video.v -- video_core on the video port of the real ahb_ddr3_bridge,
// against the DDR3 user-port model (ddr_bridge/tb/ddr3_ui_model.v) holding
// the framebuffer; the bridge's AHB side is idle.
// Small timing (64x12 active in 100x20) and a padded stride; captures the
// panel outputs and checks a whole frame pixel by pixel (RGB565 -> RGB666),
// the line/frame shape, the hardware frame CRC against a model CRC of the
// framebuffer, no underruns, no DDR protocol errors, then the test pattern.
// WAIT_PCT (iverilog -P) holds the DDR command port off that % of cycles;
// EXPECT_UNDERRUN=1 checks that a starved fetch is detected instead.
// SCALE=1: a SW x SH source picture in the window DX, DY, DW x DH (nearest
// neighbour, steps as the driver computes them, background BG around it);
// OSD=1: an ARGB8888 layer (alpha 0, 255 and in between) in OX, OY, OW x OH,
// blended over picture and background -- every pixel against the model.
//============================================================================
module tb_video;
    parameter WAIT_PCT        = 0;
    parameter EXPECT_UNDERRUN = 0;

    // timing (iverilog -P): the defaults have blanking on every side; run_tb.sh
    // also runs DE from h = 0 on line 0, and DE to the end of the line on the
    // frame's last lines (no blanking after the frame's last pixel)
    parameter  HA = 64, HT = 100, HS = 20, VA = 12, VT = 20, VS = 3;
    parameter  YUV = 0, FULL = 1;        // YUV 4:2:0 planar framebuffer, full/limited range
    parameter  SCALE = 0, SW = 64, SH = 12, DX = 0, DY = 0, DW = 64, DH = 12;    // scaler
    parameter  OSD = 0, OX = 0, OY = 0, OW = 16, OH = 4;                       // OSD window
    localparam [15:0] BG = 16'h3A6B;
    localparam STRIDE = 256, FB = 32'h1000, FB_U = 32'h3000, FB_V = 32'h3800, STRIDE_C = 96, FB2 = 32'h0000;
    localparam OSD_BASE = 32'h4000, OSD_STRIDE = 256;
    localparam PW = SCALE ? SW : HA, PH = SCALE ? SH : VA;                      // the source picture
    localparam [31:0] STEPX = SCALE ? (SW * 65536) / DW : 65536, STEPY = SCALE ? (SH * 65536) / DH : 65536;
    localparam WX = SCALE ? DX : 0, WY = SCALE ? DY : 0, WW = SCALE ? DW : HA, WH = SCALE ? DH : VA;

    reg hclk = 0; always #10 hclk = ~hclk;      // 50 MHz (registers, bridge AHB side)
    reg uclk = 0; initial begin #3.3; forever #5 uclk = ~uclk; end   // 100 MHz DDR3 user clock
    reg pclk = 0; always #15 pclk = ~pclk;      // 33.3 MHz
    reg hresetn = 0;

    // register bus (tb-driven)
    reg  [31:0] s_haddr = 0, s_hwdata = 0;
    reg  [1:0]  s_htrans = 0;
    reg         s_hwrite = 0, s_hsel = 0;
    wire [31:0] s_hrdata;
    wire        s_hready, s_hresp;

    // video port and DDR3 user port
    wire         vrstn, v_req, v_ack, v_rvalid;
    wire [31:0]  v_addr;
    wire [255:0] v_rdata;
    wire         calib_done, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid;
    wire [2:0]   cmd;
    wire [28:0]  addr;                    // bridge ADDR_BITS (30) - 1
    wire [255:0] wr_data, rd_data;
    wire [31:0]  wr_data_mask;
    wire [63:0]  b_hrdata;
    wire [1:0]   b_hresp;
    wire         b_hready;
    integer      ddr_errors;

    wire       lcd_de;
    wire [5:0] lcd_r, lcd_g, lcd_b;

    video_core dut (
        .hclk(hclk), .hresetn(hresetn),
        .s_haddr(s_haddr), .s_htrans(s_htrans), .s_hwrite(s_hwrite), .s_hsel(s_hsel),
        .s_hready_in(1'b1), .s_hwdata(s_hwdata), .s_hrdata(s_hrdata),
        .s_hready(s_hready), .s_hresp(s_hresp),
        .vclk(uclk), .vrstn(vrstn), .v_req(v_req), .v_addr(v_addr), .v_ack(v_ack),
        .v_rvalid(v_rvalid), .v_rdata(v_rdata),
        .pclk(pclk), .lcd_de(lcd_de), .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );
    ahb_ddr3_bridge bridge (
        .hclk(hclk), .hresetn(hresetn), .haddr(32'd0), .htrans(2'b00), .hwrite(1'b0),
        .hsize(3'd0), .hburst(3'd0), .hprot(4'd0), .hwdata(64'd0), .hready(b_hready),
        .hresp(b_hresp), .hrdata(b_hrdata), .mode(32'h10000), .perf_en(1'b0), .perf_clr(1'b0),
        .perf_cnt(),
        .uclk(uclk), .calib_done(calib_done), .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en),
        .addr(addr), .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en),
        .wr_data_end(wr_data_end), .wr_data_mask(wr_data_mask), .rd_data(rd_data),
        .rd_data_valid(rd_data_valid),
        .v_rstn(vrstn), .v_req(v_req), .v_addr(v_addr[29:0]), .v_ack(v_ack),
        .v_rvalid(v_rvalid), .v_rdata(v_rdata)
    );
    ddr3_ui_model #(.WORDS(1024), .LAT_MIN(10), .LAT_MAX(40), .RDY_PCT(100 - WAIT_PCT)) ddr (
        .clk(uclk), .calib_done(calib_done), .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en),
        .addr(addr), .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en),
        .wr_data_end(wr_data_end), .wr_data_mask(wr_data_mask), .rd_data(rd_data),
        .rd_data_valid(rd_data_valid), .errors(ddr_errors)
    );

    task reg_wr(input [7:0] a, input [31:0] d);
        begin
            @(negedge hclk); s_haddr = {24'hE80010, a}; s_htrans = 2'b10; s_hwrite = 1; s_hsel = 1;
            @(negedge hclk); s_htrans = 0; s_hsel = 0; s_hwrite = 0; s_hwdata = d;
            @(negedge hclk);
        end
    endtask
    task reg_rd(input [7:0] a, output [31:0] d);
        begin
            @(negedge hclk); s_haddr = {24'hE80010, a}; s_htrans = 2'b10; s_hwrite = 0; s_hsel = 1;
            @(negedge hclk); s_htrans = 0; s_hsel = 0;
            @(posedge hclk); #1 d = s_hrdata;
        end
    endtask

    // framebuffer contents and the model
    function [15:0] fbpix(input integer x, input integer y);
        fbpix = {y[4:0] ^ 5'h15, x[5:0], (x[4:0] + y[4:0]) ^ 5'h0A};
    endfunction
    // YUV planes and the model of the core's fixed-point conversion
    function [7:0] ysamp(input integer x, input integer y); ysamp = (x * 3 + y * 5) & 255; endfunction
    function [7:0] usamp(input integer cx, input integer cy); usamp = (cx * 7 + cy * 11 + 40) & 255; endfunction
    function [7:0] vsamp(input integer cx, input integer cy); vsamp = (200 - cx * 5 + cy * 3) & 255; endfunction
    function integer clamp8(input integer v);
        integer c;
        begin c = v >>> 8; clamp8 = v < 0 ? 0 : c > 255 ? 255 : c; end
    endfunction
    function [23:0] yuv888(input integer x, input integer y);
        integer Y, U, V, r, g, b, ky, ko, krv, kgu, kgv, kbu;
        begin
            Y = ysamp(x, y); U = usamp(x / 2, y / 2) - 128; V = vsamp(x / 2, y / 2) - 128;
            ky = FULL ? 256 : 298; ko = FULL ? 128 : -4640;
            krv = FULL ? 359 : 409; kgu = FULL ? 88 : 100; kgv = FULL ? 183 : 208; kbu = FULL ? 454 : 516;
            r = clamp8(ky * Y + ko + krv * V);
            g = clamp8(ky * Y + ko - kgu * U - kgv * V);
            b = clamp8(ky * Y + ko + kbu * U);
            yuv888 = {r[7:0], g[7:0], b[7:0]};
        end
    endfunction
    function [23:0] rgb888(input [15:0] p);
        rgb888 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
    endfunction
    // the OSD layer: alpha 0, 255 and values in between, colours varying
    function [31:0] osdpix(input integer x, input integer y);
        reg [7:0] a, r, g, b;
        begin
            case (x % 4) 0: a = 0; 1: a = 255; 2: a = (x * 13 + y * 7) & 255; default: a = 128; endcase
            r = (x * 9 + y) & 255; g = (255 - x * 5) & 255; b = (y * 20 + x) & 255;
            osdpix = {a, r, g, b};
        end
    endfunction
    integer ox_v = OX;                  // the OSD position the model uses (moved by the change test)
    // the panel pixel (active-area coordinates): window, scaler, source, OSD blend
    function [15:0] mpix(input integer x, input integer y);
        integer sx, sy, a, i;
        reg [23:0] pic, o;
        reg [31:0] op;
        reg [16:0] c [0:2];
        begin
            if (x >= WX && x < WX + WW && y >= WY && y < WY + WH) begin
                sx = ((x - WX) * STEPX + STEPX / 2) >> 16; if (sx > PW - 1) sx = PW - 1;
                sy = ((y - WY) * STEPY + STEPY / 2) >> 16; if (sy > PH - 1) sy = PH - 1;
                pic = YUV ? yuv888(sx, sy) : rgb888(fbpix(sx, sy));
            end else pic = rgb888(BG);
            if (OSD && x >= ox_v && x < ox_v + OW && y >= OY && y < OY + OH) begin
                op = osdpix(x - ox_v, y - OY);
                a = op[31:24] + op[31];
            end else begin op = 0; a = 0; end
            for (i = 0; i < 3; i = i + 1) c[i] = op[i*8 +: 8] * a + pic[i*8 +: 8] * (256 - a);
            mpix = {c[2][15:11], c[1][15:10], c[0][15:11]};
        end
    endfunction
    function [17:0] to666(input [15:0] p);
        to666 = {p[15:11], p[15], p[10:5], p[4:0], p[4]};
    endfunction
    function [31:0] crc16(input [31:0] c, input [15:0] d);
        integer i; reg [31:0] r;
        begin
            r = c;
            for (i = 0; i < 16; i = i + 1) r = (r >> 1) ^ ((r[0] ^ d[i]) ? 32'hEDB88320 : 32'h0);
            crc16 = r;
        end
    endfunction

    // capture: frame_tgl marks the end of a frame; count DE runs as lines.
    // In one cycle the frame toggle can meet the DE fall after the frame's
    // last pixel (no blanking after it) or the next frame's first pixel (DE
    // from h = 0 on line 0), so events go: line end, frame end, pixel.
    reg  [17:0] cap [0:VA-1][0:HA-1];
    integer     cx = 0, cy = 0, cap_frames = 0, shape_err = 0;
    reg         de_q = 0, ft_q = 0;
    always @(posedge pclk) begin
        de_q <= lcd_de;
        ft_q <= dut.out.frame_tgl;
        if (!lcd_de && de_q) begin
            if (cx != HA) begin shape_err = shape_err + 1; $display("  line %0d had %0d pixels", cy, cx); end
            cx = 0; cy = cy + 1;
        end
        if (dut.out.frame_tgl != ft_q) begin
            if (cap_frames > 0 && cy != VA) begin shape_err = shape_err + 1; $display("  frame had %0d lines", cy); end
            cap_frames = cap_frames + 1; cy = 0;
        end
        if (lcd_de) begin
            if (cy < VA && cx < HA) cap[cy][cx] = {lcd_r, lcd_g, lcd_b};
            cx = cx + 1;
        end
    end

    integer x, y, i, errors;
    reg [31:0]  r, crc, model_crc, model_crc2, frames0;
    integer     flips_old, flips_new, flips_mixed;
    reg [255:0] w;
    initial begin
        errors = 0;
        #1;     // after the DDR model's random initialisation
        // fill the framebuffer (padding words get a marker that must never show)
        for (i = 0; i < 1024; i = i + 1) ddr.mem[i] = {8{32'hDEAD_BEEF}};
        for (y = 0; y < PH; y = y + 1)                       // Y plane (and U/V, YUV mode)
            for (x = 0; x < PW; x = x + 32) begin
                for (i = 0; i < 32; i = i + 1) w[i*8 +: 8] = ysamp(x + i, y);
                ddr.mem[(FB + y*STRIDE + x) >> 5] = w;
            end
        for (y = 0; y < (PH + 1) / 2; y = y + 1)
            for (x = 0; x < (PW + 1) / 2; x = x + 32) begin
                for (i = 0; i < 32; i = i + 1) w[i*8 +: 8] = usamp(x + i, y);
                ddr.mem[(FB_U + y*STRIDE_C + x) >> 5] = w;
                for (i = 0; i < 32; i = i + 1) w[i*8 +: 8] = vsamp(x + i, y);
                ddr.mem[(FB_V + y*STRIDE_C + x) >> 5] = w;
            end
        if (!YUV) for (y = 0; y < PH; y = y + 1)
            for (x = 0; x < PW; x = x + 16) begin
                w = {fbpix(x+15,y), fbpix(x+14,y), fbpix(x+13,y), fbpix(x+12,y),
                     fbpix(x+11,y), fbpix(x+10,y), fbpix(x+9,y),  fbpix(x+8,y),
                     fbpix(x+7,y),  fbpix(x+6,y),  fbpix(x+5,y),  fbpix(x+4,y),
                     fbpix(x+3,y),  fbpix(x+2,y),  fbpix(x+1,y),  fbpix(x,y)};
                ddr.mem[(FB + y*STRIDE + x*2) >> 5] = w;
            end
        if (OSD) for (y = 0; y < OH; y = y + 1)
            for (x = 0; x < OW; x = x + 8) begin
                for (i = 0; i < 8; i = i + 1) w[i*32 +: 32] = osdpix(x + i, y);
                ddr.mem[(OSD_BASE + y*OSD_STRIDE + x*4) >> 5] = w;
            end
        model_crc = 32'hFFFFFFFF;
        for (y = 0; y < VA; y = y + 1)
            for (x = 0; x < HA; x = x + 1) model_crc = crc16(model_crc, mpix(x, y));
        model_crc = ~model_crc;

        repeat (5) @(posedge hclk); hresetn = 1; repeat (5) @(posedge hclk);
        reg_rd(8'h2C, r);
        if (r !== 32'h56494430) begin errors = errors + 1; $display("  ID %08x", r); end
        reg_wr(8'h08, FB);
        reg_wr(8'h0C, STRIDE);
        reg_wr(8'h10, {16'(HT), 16'(HA)});
        reg_wr(8'h14, HS);
        reg_wr(8'h18, {16'(VT), 16'(VA)});
        reg_wr(8'h1C, VS);
        reg_wr(8'h30, FB_U);
        reg_wr(8'h34, FB_V);
        reg_wr(8'h38, STRIDE_C);
        reg_wr(8'h3C, {16'(SH), 16'(SW)});
        reg_wr(8'h40, {16'(DY), 16'(DX)});
        reg_wr(8'h44, {16'(DH), 16'(DW)});
        reg_wr(8'h48, STEPX);
        reg_wr(8'h4C, STEPY);
        reg_wr(8'h50, BG);
        reg_wr(8'h54, OSD_BASE);
        reg_wr(8'h58, OSD_STRIDE);
        reg_wr(8'h5C, {16'(OY), 16'(OX)});
        reg_wr(8'h60, {16'(OH), 16'(OW)});
        reg_rd(8'h64, r);
        if (r[2:0] !== 3'b111) begin errors = errors + 1; $display("  CAPS %08x", r); end
        reg_wr(8'h00, 32'h1 | (YUV ? 32'h4 : 32'h0) | (FULL ? 32'h8 : 32'h0) |   // enable (+ YUV mode,
                      (SCALE ? 32'h10 : 32'h0) | (OSD ? 32'h20 : 32'h0));        //  scaler, OSD)

        // let it run 4 frames; the capture of the last full frame is checked
        reg_rd(8'h20, frames0);
        r = frames0;
        while (r < frames0 + 4) reg_rd(8'h20, r);
        reg_rd(8'h28, crc);
        if (!EXPECT_UNDERRUN) begin
            for (y = 0; y < VA; y = y + 1)
                for (x = 0; x < HA; x = x + 1)
                    if (cap[y][x] !== to666(mpix(x, y))) begin
                        errors = errors + 1;
                        if (errors < 8) $display("  pixel (%0d,%0d) got %05x exp %05x", x, y, cap[y][x], to666(mpix(x, y)));
                    end
            if (crc !== model_crc) begin errors = errors + 1; $display("  CRC %08x model %08x", crc, model_crc); end
        end
        reg_rd(8'h24, r);
        if (EXPECT_UNDERRUN ? (r == 0) : (r != 0)) begin
            errors = errors + 1; $display("  underruns %0d (expected %s)", r, EXPECT_UNDERRUN ? "some" : "none");
        end
        errors = errors + shape_err + ddr_errors;

        // buffer flip: a second framebuffer (inverted pattern) at FB2, FB_BASE
        // rewritten in the middle of a frame; every frame's CRC must be that
        // of one whole buffer, never a mix (the core latches bases per frame)
        // (with vstart = 0 the next frame's first line is requested before the
        // frame-end toggle that loads the new base, so one mixed frame is expected:
        // the Linux driver uses vstart = 8, the test skips that timing)
        if (!YUV && !SCALE && !OSD && !EXPECT_UNDERRUN && VS != 0) begin
            for (y = 0; y < VA; y = y + 1)
                for (x = 0; x < HA; x = x + 16) begin
                    for (i = 0; i < 16; i = i + 1) w[i*16 +: 16] = ~fbpix(x + i, y);
                    ddr.mem[(FB2 + y*STRIDE + x*2) >> 5] = w;
                end
            model_crc2 = 32'hFFFFFFFF;
            for (y = 0; y < VA; y = y + 1)
                for (x = 0; x < HA; x = x + 1) model_crc2 = crc16(model_crc2, ~fbpix(x, y));
            model_crc2 = ~model_crc2;
            reg_rd(8'h20, frames0); r = frames0;
            while (r == frames0) reg_rd(8'h20, r);         // just after a frame end
            repeat (HT * 5) @(posedge pclk);                 // five lines into the frame
            reg_wr(8'h08, FB2);
            flips_old = 0; flips_new = 0; flips_mixed = 0;
            for (i = 0; i < 4; i = i + 1) begin
                frames0 = r;
                while (r == frames0) reg_rd(8'h20, r);
                reg_rd(8'h28, crc);
                if (crc == model_crc) flips_old = flips_old + 1;
                else if (crc == model_crc2) flips_new = flips_new + 1;
                else flips_mixed = flips_mixed + 1;
            end
            if (flips_mixed != 0 || flips_new < 2) begin
                errors = errors + 1;
                $display("  flip: %0d old, %0d new, %0d mixed frames", flips_old, flips_new, flips_mixed);
            end
            reg_wr(8'h08, FB);
        end

        // settings changed while running: the OSD moves two pixels right in the
        // middle of a frame; every frame must be all old or all new (the core
        // latches the scaler / OSD settings per frame)
        if (OSD && !EXPECT_UNDERRUN && VS >= 2 && OX + OW + 2 <= HA) begin
            ox_v = OX + 2;
            model_crc2 = 32'hFFFFFFFF;
            for (y = 0; y < VA; y = y + 1)
                for (x = 0; x < HA; x = x + 1) model_crc2 = crc16(model_crc2, mpix(x, y));
            model_crc2 = ~model_crc2;
            reg_rd(8'h20, frames0); r = frames0;
            while (r == frames0) reg_rd(8'h20, r);
            repeat (HT * (VS + 4)) @(posedge pclk);          // into the frame's active lines
            reg_wr(8'h5C, {16'(OY), 16'(OX + 2)});
            flips_old = 0; flips_new = 0; flips_mixed = 0;
            for (i = 0; i < 4; i = i + 1) begin
                frames0 = r;
                while (r == frames0) reg_rd(8'h20, r);
                reg_rd(8'h28, crc);
                if (crc == model_crc) flips_old = flips_old + 1;
                else if (crc == model_crc2) flips_new = flips_new + 1;
                else flips_mixed = flips_mixed + 1;
            end
            if (flips_mixed != 0 || flips_new < 2) begin
                errors = errors + 1;
                $display("  OSD move: %0d old, %0d new, %0d mixed frames", flips_old, flips_new, flips_mixed);
            end
            for (y = 0; y < VA; y = y + 1)                   // and the moved layer pixel-exact
                for (x = 0; x < HA; x = x + 1)
                    if (cap[y][x] !== to666(mpix(x, y))) begin
                        errors = errors + 1;
                        if (errors < 8) $display("  moved OSD: pixel (%0d,%0d) got %05x exp %05x", x, y, cap[y][x], to666(mpix(x, y)));
                    end
        end

        // test pattern: bars, no DMA
        reg_wr(8'h00, 32'h2);
        reg_rd(8'h20, frames0); r = frames0;
        while (r < frames0 + 2) reg_rd(8'h20, r);
        if (!EXPECT_UNDERRUN && (cap[0][0] !== to666(16'hFFFF) || cap[5][HA-1] !== to666(16'hFFFF))) begin
            errors = errors + 1; $display("  test pattern pixel %05x / %05x", cap[0][0], cap[5][HA-1]);
        end

        if (errors == 0 && EXPECT_UNDERRUN) $display("RESULT: PASS (starved fetch detected as underruns, wait %0d%%)", WAIT_PCT);
        else if (errors == 0 && (SCALE || OSD)) $display("RESULT: PASS (%s %0dx%0d source in %0dx%0d+%0d+%0d%s, frame %0dx%0d pixel-exact, CRC %08x matches, no underruns, wait %0d%%)",
                                       YUV ? "YUV420" : "RGB565", PW, PH, WW, WH, WX, WY, OSD ? " + OSD" : "", HA, VA, crc, WAIT_PCT);
        else if (errors == 0 && YUV) $display("RESULT: PASS (YUV420 %s frame %0dx%0d pixel-exact, CRC %08x matches, no underruns, wait %0d%%)",
                                       FULL ? "full-range" : "BT.601    ", HA, VA, crc, WAIT_PCT);
        else if (errors == 0) $display("RESULT: PASS (RGB565 frame %0dx%0d pixel-exact, CRC %08x matches, no underruns, wait %0d%%)",
                                       HA, VA, crc, WAIT_PCT);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #20000000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
