`default_nettype none
//============================================================================
// video_core.v -- simple scan-out video core for a DE-mode RGB LCD.
//
//   CPU --EXTS--> video_csr (registers, bus clock)
//   DDR3 --ahb_ddr3_bridge video port (BL8 reads)--> video_fetch --+
//                                         (DDR3 user clock)        v
//              line RAM: 2 lines x 64 x 256 bit, dual clock (write: DDR clock)
//                                                                  |
//   panel <-- video_out (timing, RGB565 -> RGB666, frame CRC) <----+
//                (pixel clock)
//
// The framebuffer is RGB565 or planar YUV 4:2:0 (converted in video_out),
// fetched one line ahead into a double-buffered line RAM (see video_out /
// video_fetch).  The fetch reads DDR3 directly on
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
    wire        enable, test, yuv, full_range;
    wire [31:0] fb_base, fb_base_u, fb_base_v;
    wire [15:0] stride, stride_c, hactive, htotal, hstart, vactive, vtotal, vstart;
    reg  [31:0] frames, underruns_b, crc_b;
    video_csr csr (
        .hclk(hclk), .hresetn(hresetn),
        .haddr(s_haddr), .htrans(s_htrans), .hwrite(s_hwrite), .hsel(s_hsel),
        .hready_in(s_hready_in), .hwdata(s_hwdata),
        .hrdata(s_hrdata), .hready(s_hready), .hresp(s_hresp),
        .enable(enable), .test(test), .yuv(yuv), .full_range(full_range),
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
    reg  [31:0] fb_base_a, fb_base_u_a, fb_base_v_a;
    reg  [15:0] stride_a, stride_c_a;
    reg         yuv_a;

    // ---- line fetch (DDR clock) ----
    wire         req_tgl, done_tgl;
    wire [15:0]  req_line, done_line;
    wire         ram_we;
    wire [6:0]   ram_waddr, ram_raddr;
    wire [255:0] ram_wdata, ram_rdata;
    video_fetch fetch (
        .clk(vclk), .rstn(vrstn),
        .yuv(yuv_a), .fb_base(fb_base_a), .fb_base_u(fb_base_u_a), .fb_base_v(fb_base_v_a),
        .stride(stride_a), .stride_c(stride_c_a), .hactive(hactive),
        .req_tgl(req_tgl), .req_line(req_line),
        .done_tgl(done_tgl), .done_line(done_line),
        .v_req(v_req), .v_addr(v_addr), .v_ack(v_ack),
        .v_rvalid(v_rvalid), .v_rdata(v_rdata),
        .ram_we(ram_we), .ram_waddr(ram_waddr), .ram_wdata(ram_wdata)
    );

    // ---- line RAM: 2 x 64 x 256 bit ----
    RAM_Simple_Dual_Port_Dual_Clock #(
        .WORD_WIDTH(256), .ADDR_WIDTH(7), .DEPTH(128), .RAMSTYLE(""),
        .USE_INIT_FILE(0), .INIT_FILE(""), .INIT_VALUE(256'd0)
    ) lram (
        .write_clock(vclk), .wren(ram_we), .write_addr(ram_waddr), .write_data(ram_wdata),
        .read_clock(pclk), .rden(1'b1), .read_addr(ram_raddr), .read_data(ram_rdata)
    );

    // ---- scan-out (pixel clock) ----
    wire        frame_tgl;
    wire [31:0] frame_crc, underruns;
    video_out out (
        .pclk(pclk), .prstn(prstn),
        .cfg_enable(enable), .cfg_test(test), .cfg_yuv(yuv), .cfg_full(full_range),
        .hactive(hactive), .htotal(htotal), .hstart(hstart),
        .vactive(vactive), .vtotal(vtotal), .vstart(vstart),
        .req_tgl(req_tgl), .req_line(req_line),
        .done_tgl(done_tgl), .done_line(done_line),
        .ram_raddr(ram_raddr), .ram_rdata(ram_rdata),
        .frame_tgl(frame_tgl), .frame_crc(frame_crc), .underruns(underruns),
        .lcd_de(lcd_de), .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    // ---- frame status into the bus clock ----
    reg [2:0] fr_s;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            fr_s <= 0; frames <= 0; underruns_b <= 0; crc_b <= 0;
            fb_base_a <= 0; fb_base_u_a <= 0; fb_base_v_a <= 0; stride_a <= 0; stride_c_a <= 0; yuv_a <= 0;
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
            end
        end
    end
endmodule
`default_nettype wire
