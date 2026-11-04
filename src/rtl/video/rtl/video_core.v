`default_nettype none
//============================================================================
// video_core.v -- simple scan-out video core for a DE-mode RGB LCD.
//
//   CPU --EXTS--> video_csr (registers, bus clock)
//   DDR3 --ahb_ddr3_bridge video port (BL8 reads)--> video_fetch --+
//                                         (DDR3 user clock)        v
//     line RAMs, 2 lines each, dual clock (write: DDR clock, read: pclk):
//     Y/RGB 2 x 64, U 2 x 32, V 2 x 32, OSD 2 x 128 words of 256 bit
//                                                                  |
//   panel <-- video_out (timing, scaler, YUV -> RGB, OSD blend,  <-+
//                RGB666, frame CRC) (pixel clock)
//
// The framebuffer is RGB565 or planar YUV 4:2:0 (converted in video_out),
// fetched one line ahead into double-buffered line RAMs (see video_out /
// video_fetch); a nearest-neighbour scaler shows a source picture of any
// size in a window, and an ARGB8888 OSD layer is blended over it.  The fetch reads DDR3 directly on
// the bridge's video port, next to the CPU's data-memory traffic, so it costs
// neither the SoC's data-memory bus nor EXTM time.  Frame count, CRC and
// underrun count cross to the bus clock on each frame-end toggle (the values
// are stable for a whole frame).  The pixel clock is forwarded to the panel by
// the top level.
//============================================================================
module video_core (
    // bus clock (EXTS)
    input  wire         hclk,
    input  wire         hresetn,
    // AHB-lite slave: registers
    input  wire [31:0]  s_haddr,
    input  wire [1:0]   s_htrans,
    input  wire         s_hwrite,
    input  wire         s_hsel,
    input  wire         s_hready_in,
    input  wire [31:0]  s_hwdata,
    output wire [31:0]  s_hrdata,
    output wire         s_hready,
    output wire         s_hresp,
    // DDR3 video read port (ahb_ddr3_bridge, DDR3 user clock)
    input  wire         vclk,
    input  wire         vrstn,
    output wire         v_req,
    output wire [31:0]  v_addr,
    input  wire         v_ack,
    input  wire         v_rvalid,
    input  wire [255:0] v_rdata,
    // pixel clock + panel
    input  wire         pclk,
    output wire         lcd_de,
    output wire [5:0]   lcd_r,
    output wire [5:0]   lcd_g,
    output wire [5:0]   lcd_b
);
    // ---- registers ----
    wire        enable, test, yuv, full_range, scale, osd;
    wire [15:0] src_w, src_h, dst_x, dst_y, dst_w, dst_h, bg, osd_stride, osd_x, osd_y, osd_w, osd_h;
    wire [21:0] step_x, step_y;
    wire [31:0] osd_base;
    wire [31:0] fb_base, fb_base_u, fb_base_v;
    wire [15:0] stride, stride_c, hactive, htotal, hstart, vactive, vtotal, vstart;
    reg  [31:0] frames, underruns_b, crc_b;
    video_csr csr (
        .hclk(hclk), .hresetn(hresetn),
        .haddr(s_haddr), .htrans(s_htrans), .hwrite(s_hwrite), .hsel(s_hsel),
        .hready_in(s_hready_in), .hwdata(s_hwdata),
        .hrdata(s_hrdata), .hready(s_hready), .hresp(s_hresp),
        .enable(enable), .test(test), .yuv(yuv), .full_range(full_range), .scale(scale), .osd(osd),
        .src_w(src_w), .src_h(src_h), .dst_x(dst_x), .dst_y(dst_y), .dst_w(dst_w), .dst_h(dst_h),
        .step_x(step_x), .step_y(step_y), .bg(bg), .osd_base(osd_base), .osd_stride(osd_stride),
        .osd_x(osd_x), .osd_y(osd_y), .osd_w(osd_w), .osd_h(osd_h),
        .fb_base(fb_base), .fb_base_u(fb_base_u), .fb_base_v(fb_base_v), .stride(stride), .stride_c(stride_c),
        .hactive(hactive), .htotal(htotal), .hstart(hstart),
        .vactive(vactive), .vtotal(vtotal), .vstart(vstart),
        .frames(frames), .underruns(underruns_b), .frame_crc(crc_b)
    );

    // ---- pixel-clock reset ----
    wire prstn;
    Reset_Synchronizer #(.EXTRA_DEPTH(0), .RESET_ACTIVE_STATE(0)) prs (
        .receiving_clock(pclk), .reset_in(hresetn), .reset_out(prstn)
    );

    // ---- frame-synchronous copies of the framebuffer registers ----
    // Software may write new bases (a buffer flip) at any time: the fetcher
    // only sees them from the next frame on (loaded at the frame-end toggle,
    // or continuously while scan-out is off), so a frame is always scanned
    // from one buffer.  The mode bit goes with them so fetch and output stage
    // interpret the same frame the same way (video_out applies its own copy
    // at the frame wrap, which precedes the next frame's first line request
    // for any vstart >= 1).
    reg  [31:0] fb_base_a, fb_base_u_a, fb_base_v_a, osd_base_a;
    reg  [15:0] stride_a, stride_c_a, osd_stride_a, osd_w_a;
    reg         yuv_a;
    // the scaler / OSD settings of the frame, as video_out uses them: the
    // window [dx, dxe) x [dy, dye), steps, source size, background, OSD window
    // (scaler off: the whole active area, 1:1)
    reg  [15:0] w_dx, w_dxe, w_dy, w_dye, w_srcw, w_srch, w_bg, o_x, o_xe, o_y, o_ye;
    reg  [21:0] w_stepx, w_stepy;
    reg         o_en;

    // ---- line fetch (DDR clock) ----
    wire         req_tgl, done_tgl;
    wire [15:0]  req_line, done_line;
    wire [25:0]  req_info;
    wire         we_y, we_u, we_v, we_o;
    wire [7:0]   ram_waddr;
    wire [255:0] ram_wdata, y_rdata, u_rdata, vp_rdata, o_rdata;
    wire [6:0]   y_raddr;
    wire [5:0]   c_raddr;
    wire [7:0]   o_raddr;
    video_fetch fetch (
        .clk(vclk), .rstn(vrstn),
        .yuv(yuv_a), .fb_base(fb_base_a), .fb_base_u(fb_base_u_a), .fb_base_v(fb_base_v_a),
        .stride(stride_a), .stride_c(stride_c_a), .src_w(w_srcw),
        .osd_base(osd_base_a), .osd_stride(osd_stride_a), .osd_w(osd_w_a),
        .req_tgl(req_tgl), .req_line(req_line), .req_info(req_info),
        .done_tgl(done_tgl), .done_line(done_line),
        .v_req(v_req), .v_addr(v_addr), .v_ack(v_ack),
        .v_rvalid(v_rvalid), .v_rdata(v_rdata),
        .we_y(we_y), .we_u(we_u), .we_v(we_v), .we_o(we_o), .ram_waddr(ram_waddr), .ram_wdata(ram_wdata)
    );

    // ---- line RAMs ({half, word}) ----
    RAM_Simple_Dual_Port_Dual_Clock #(.WORD_WIDTH(256), .ADDR_WIDTH(7), .DEPTH(128), .RAMSTYLE(""),
        .USE_INIT_FILE(0), .INIT_FILE(""), .INIT_VALUE(256'd0)) lram_y (
        .write_clock(vclk), .wren(we_y), .write_addr({ram_waddr[7], ram_waddr[5:0]}), .write_data(ram_wdata),
        .read_clock(pclk), .rden(1'b1), .read_addr(y_raddr), .read_data(y_rdata));
    RAM_Simple_Dual_Port_Dual_Clock #(.WORD_WIDTH(256), .ADDR_WIDTH(6), .DEPTH(64), .RAMSTYLE(""),
        .USE_INIT_FILE(0), .INIT_FILE(""), .INIT_VALUE(256'd0)) lram_u (
        .write_clock(vclk), .wren(we_u), .write_addr({ram_waddr[7], ram_waddr[4:0]}), .write_data(ram_wdata),
        .read_clock(pclk), .rden(1'b1), .read_addr(c_raddr), .read_data(u_rdata));
    RAM_Simple_Dual_Port_Dual_Clock #(.WORD_WIDTH(256), .ADDR_WIDTH(6), .DEPTH(64), .RAMSTYLE(""),
        .USE_INIT_FILE(0), .INIT_FILE(""), .INIT_VALUE(256'd0)) lram_v (
        .write_clock(vclk), .wren(we_v), .write_addr({ram_waddr[7], ram_waddr[4:0]}), .write_data(ram_wdata),
        .read_clock(pclk), .rden(1'b1), .read_addr(c_raddr), .read_data(vp_rdata));
    RAM_Simple_Dual_Port_Dual_Clock #(.WORD_WIDTH(256), .ADDR_WIDTH(8), .DEPTH(256), .RAMSTYLE(""),
        .USE_INIT_FILE(0), .INIT_FILE(""), .INIT_VALUE(256'd0)) lram_o (
        .write_clock(vclk), .wren(we_o), .write_addr(ram_waddr), .write_data(ram_wdata),
        .read_clock(pclk), .rden(1'b1), .read_addr(o_raddr), .read_data(o_rdata));

    // ---- scan-out (pixel clock) ----
    wire        frame_tgl;
    wire [31:0] frame_crc, underruns;
    video_out out (
        .pclk(pclk), .prstn(prstn),
        .cfg_enable(enable), .cfg_test(test), .cfg_yuv(yuv), .cfg_full(full_range),
        .hactive(hactive), .htotal(htotal), .hstart(hstart),
        .vactive(vactive), .vtotal(vtotal), .vstart(vstart),
        .cfg_dx(w_dx), .cfg_dxe(w_dxe), .cfg_dy(w_dy), .cfg_dye(w_dye),
        .cfg_stepx(w_stepx), .cfg_stepy(w_stepy), .cfg_srcw(w_srcw), .cfg_srch(w_srch), .cfg_bg(w_bg),
        .cfg_osd(o_en), .cfg_ox(o_x), .cfg_oxe(o_xe), .cfg_oy(o_y), .cfg_oye(o_ye),
        .req_tgl(req_tgl), .req_line(req_line), .req_info(req_info),
        .done_tgl(done_tgl), .done_line(done_line),
        .y_raddr(y_raddr), .y_rdata(y_rdata), .c_raddr(c_raddr), .u_rdata(u_rdata), .v_rdata(vp_rdata),
        .o_raddr(o_raddr), .o_rdata(o_rdata),
        .frame_tgl(frame_tgl), .frame_crc(frame_crc), .underruns(underruns),
        .lcd_de(lcd_de), .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    // ---- frame status into the bus clock ----
    reg [2:0] fr_s;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            fr_s <= 0; frames <= 0; underruns_b <= 0; crc_b <= 0;
            fb_base_a <= 0; fb_base_u_a <= 0; fb_base_v_a <= 0; stride_a <= 0; stride_c_a <= 0; yuv_a <= 0;
            osd_base_a <= 0; osd_stride_a <= 0; osd_w_a <= 0;
            w_dx <= 0; w_dxe <= 0; w_dy <= 0; w_dye <= 0; w_srcw <= 0; w_srch <= 0; w_bg <= 0;
            w_stepx <= 22'h10000; w_stepy <= 22'h10000; o_en <= 0; o_x <= 0; o_xe <= 0; o_y <= 0; o_ye <= 0;
        end else begin
            fr_s <= {fr_s[1:0], frame_tgl};
            if (fr_s[2] ^ fr_s[1]) begin
                frames      <= frames + 32'd1;
                crc_b       <= frame_crc;
                underruns_b <= underruns;
            end
            if (!enable || (fr_s[2] ^ fr_s[1])) begin
                fb_base_a   <= fb_base;
                fb_base_u_a <= fb_base_u;
                fb_base_v_a <= fb_base_v;
                stride_a    <= stride;
                stride_c_a  <= stride_c;
                yuv_a       <= yuv;
                // scaler: the window and steps as video_out uses them
                w_dx    <= scale ? dst_x : 16'd0;
                w_dxe   <= scale ? dst_x + dst_w : hactive;
                w_dy    <= scale ? dst_y : 16'd0;
                w_dye   <= scale ? dst_y + dst_h : vactive;
                w_stepx <= scale ? step_x : 22'h10000;
                w_stepy <= scale ? step_y : 22'h10000;
                w_srcw  <= scale ? src_w : hactive;
                w_srch  <= scale ? src_h : vactive;
                w_bg    <= scale ? bg : 16'd0;
                // OSD
                o_en         <= osd;
                o_x          <= osd_x;
                o_xe         <= osd_x + osd_w;
                o_y          <= osd_y;
                o_ye         <= osd_y + osd_h;
                osd_base_a   <= osd_base;
                osd_stride_a <= osd_stride;
                osd_w_a      <= osd_w;
            end
        end
    end
endmodule
`default_nettype wire
