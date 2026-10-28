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
//============================================================================
module tb_video;
    parameter WAIT_PCT        = 0;
    parameter EXPECT_UNDERRUN = 0;

    // timing (iverilog -P): the defaults have blanking on every side; run_tb.sh
    // also runs DE from h = 0 on line 0, and DE to the end of the line on the
    // frame's last lines (no blanking after the frame's last pixel)
    parameter  HA = 64, HT = 100, HS = 20, VA = 12, VT = 20, VS = 3;
    localparam STRIDE = 160, FB = 32'h1000;

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
    ddr3_ui_model #(.WORDS(256), .LAT_MIN(10), .LAT_MAX(40), .RDY_PCT(100 - WAIT_PCT)) ddr (
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
    reg [31:0]  r, crc, model_crc, frames0;
    reg [255:0] w;
    initial begin
        errors = 0;
        #1;     // after the DDR model's random initialisation
        // fill the framebuffer (padding words get a marker that must never show)
        for (i = 0; i < 256; i = i + 1) ddr.mem[i] = {8{32'hDEAD_BEEF}};
        for (y = 0; y < VA; y = y + 1)
            for (x = 0; x < HA; x = x + 16) begin
                w = {fbpix(x+15,y), fbpix(x+14,y), fbpix(x+13,y), fbpix(x+12,y),
                     fbpix(x+11,y), fbpix(x+10,y), fbpix(x+9,y),  fbpix(x+8,y),
                     fbpix(x+7,y),  fbpix(x+6,y),  fbpix(x+5,y),  fbpix(x+4,y),
                     fbpix(x+3,y),  fbpix(x+2,y),  fbpix(x+1,y),  fbpix(x,y)};
                ddr.mem[(FB + y*STRIDE + x*2) >> 5] = w;
            end
        model_crc = 32'hFFFFFFFF;
        for (y = 0; y < VA; y = y + 1)
            for (x = 0; x < HA; x = x + 1) model_crc = crc16(model_crc, fbpix(x, y));
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
        reg_wr(8'h00, 32'h1);                        // enable

        // let it run 4 frames; the capture of the last full frame is checked
        reg_rd(8'h20, frames0);
        r = frames0;
        while (r < frames0 + 4) reg_rd(8'h20, r);
        reg_rd(8'h28, crc);
        if (!EXPECT_UNDERRUN) begin
            for (y = 0; y < VA; y = y + 1)
                for (x = 0; x < HA; x = x + 1)
                    if (cap[y][x] !== to666(fbpix(x, y))) begin
                        errors = errors + 1;
                        if (errors < 8) $display("  pixel (%0d,%0d) got %05x exp %05x", x, y, cap[y][x], to666(fbpix(x, y)));
                    end
            if (crc !== model_crc) begin errors = errors + 1; $display("  CRC %08x model %08x", crc, model_crc); end
        end
        reg_rd(8'h24, r);
        if (EXPECT_UNDERRUN ? (r == 0) : (r != 0)) begin
            errors = errors + 1; $display("  underruns %0d (expected %s)", r, EXPECT_UNDERRUN ? "some" : "none");
        end
        errors = errors + shape_err + ddr_errors;

        // test pattern: bars, no DMA
        reg_wr(8'h00, 32'h2);
        reg_rd(8'h20, frames0); r = frames0;
        while (r < frames0 + 2) reg_rd(8'h20, r);
        if (!EXPECT_UNDERRUN && (cap[0][0] !== to666(16'hFFFF) || cap[5][HA-1] !== to666(16'hFFFF))) begin
            errors = errors + 1; $display("  test pattern pixel %05x / %05x", cap[0][0], cap[5][HA-1]);
        end

        if (errors == 0 && EXPECT_UNDERRUN) $display("RESULT: PASS (starved fetch detected as underruns, wait %0d%%)", WAIT_PCT);
        else if (errors == 0) $display("RESULT: PASS (frame %0dx%0d pixel-exact, CRC %08x matches, no underruns, wait %0d%%)",
                                       HA, VA, crc, WAIT_PCT);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #20000000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
