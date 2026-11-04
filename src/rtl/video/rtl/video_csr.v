`default_nettype none
//============================================================================
// video_csr.v -- AHB-lite slave register block of the LCD video core
// (EXTS port, CPU base 0xE8001000).  Zero-wait: capture the address phase,
// service the data phase next cycle (same scheme as eth_dma/rtl/csr.v).
//
// Register map (byte offset):
//   0x00 CTRL      rw  [0] enable scan-out  [1] test pattern (colour bars, no DMA)
//                      [2] YUV 4:2:0 planar framebuffer (Y at FB_BASE, U/V below)
//                      [3] full-range YUV (JPEG) instead of BT.601 limited range
//                      [4] scaler: the source picture (SRC_SIZE) is shown in the
//                          DST window, nearest neighbour, background elsewhere;
//                          0 = 1:1 over the whole active area (as before)
//                      [5] OSD: ARGB8888 layer (OSD_*) blended over the picture
//   0x08 FB_BASE   rw  framebuffer physical address (32-byte aligned): RGB565, or the Y plane
//   0x0C STRIDE    rw  [15:0] bytes per framebuffer (Y) line (multiple of 32)
//   0x10 HTIM      rw  [15:0] active pixels (multiple of 16, <= 1024) [31:16] total
//   0x14 HSTART    rw  [15:0] first active pixel of a line (DE start)
//   0x18 VTIM      rw  [15:0] active lines  [31:16] total lines
//   0x1C VSTART    rw  [15:0] first active line of a frame
//   0x20 FRAMES    ro  frames scanned out
//   0x24 UNDERRUN  ro  active lines whose fetch had not completed in time
//   0x28 CRC       ro  CRC-32 (zlib) of the last frame's active pixels as sent,
//                      RGB565 little-endian, row by row
//   0x2C ID        ro  0x56494430 ("VID0")
//   0x30 FB_BASE_U rw  U plane address (32-byte aligned), YUV mode
//   0x34 FB_BASE_V rw  V plane address (32-byte aligned), YUV mode
//   0x38 STRIDE_C  rw  [15:0] bytes per chroma line (multiple of 32), YUV mode
//   0x3C SRC_SIZE  rw  [15:0] source width (YUV <= 2048, RGB <= 1024) [31:16] height
//   0x40 DST_POS   rw  [15:0] x [31:16] y of the picture window in the active area
//   0x44 DST_SIZE  rw  [15:0] width [31:16] height of the window
//   0x48 STEP_X    rw  source pixels per window pixel, 16.16 (src_w * 65536 / dst_w)
//   0x4C STEP_Y    rw  source lines per window line, 16.16
//                      (sample k = floor((k * step + step / 2) / 65536), clamped)
//   0x50 BG        rw  [15:0] RGB565 colour around the window
//   0x54 OSD_BASE  rw  first OSD pixel's address (32-byte aligned), ARGB8888
//                      (a little-endian 0xAARRGGBB word per pixel)
//   0x58 OSD_STRIDE rw [15:0] bytes per OSD line (multiple of 32)
//   0x5C OSD_POS   rw  [15:0] x [31:16] y of the OSD window in the active area
//   0x60 OSD_SIZE  rw  [15:0] width (<= 1024) [31:16] height
//   0x64 CAPS      ro  [0] YUV 4:2:0  [1] scaler  [2] OSD
// The scaler and OSD registers, like the framebuffer bases, apply from the
// next frame (exactly so for vstart >= 2).
// YUV mode: chroma is subsampled 2x2 and the core repeats each chroma sample
// (no interpolation); chroma line = Y line / 2.
// Timing registers are read by the pixel clock domain without synchronisation:
// change them only while CTRL.enable and CTRL.test are 0.  Totals <= 4095
// (12-bit pixel-clock counters), htotal >= 16.  Reset values are
// the Sipeed 5" 800x480 panel: H 800 + 210 front / 182 back porch, V 480 + 45
// / 8 (DE mode, ~52 Hz at 33.3 MHz).
//============================================================================
module video_csr (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB-lite slave
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire        hsel,
    input  wire        hready_in,
    input  wire [31:0] hwdata,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,
    // configuration
    output reg         enable,
    output reg         test,
    output reg         yuv,
    output reg         full_range,
    output reg         scale,
    output reg         osd,
    output reg  [15:0] src_w, src_h, dst_x, dst_y, dst_w, dst_h,
    output reg  [21:0] step_x, step_y,
    output reg  [15:0] bg,
    output reg  [31:0] osd_base,
    output reg  [15:0] osd_stride, osd_x, osd_y, osd_w, osd_h,
    output reg  [31:0] fb_base,
    output reg  [31:0] fb_base_u,
    output reg  [31:0] fb_base_v,
    output reg  [15:0] stride,
    output reg  [15:0] stride_c,
    output reg  [15:0] hactive, htotal, hstart,
    output reg  [15:0] vactive, vtotal, vstart,
    // status (bus domain)
    input  wire [31:0] frames,
    input  wire [31:0] underruns,
    input  wire [31:0] frame_crc
);
    assign hready = 1'b1;
    assign hresp  = 1'b0;

    reg  [5:0] a_off;
    reg        a_wr, a_sel;
    wire       a_active = hsel && hready_in && htrans[1];

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off <= 0; a_wr <= 0; a_sel <= 0;
            enable <= 0; test <= 0; yuv <= 0; full_range <= 0; scale <= 0; osd <= 0;
            src_w <= 16'd800; src_h <= 16'd480; dst_x <= 0; dst_y <= 0; dst_w <= 16'd800; dst_h <= 16'd480;
            step_x <= 22'h10000; step_y <= 22'h10000; bg <= 0;
            osd_base <= 0; osd_stride <= 16'd3200; osd_x <= 0; osd_y <= 0; osd_w <= 0; osd_h <= 0;
            fb_base <= 0; fb_base_u <= 0; fb_base_v <= 0; stride <= 16'd1600; stride_c <= 16'd416;
            hactive <= 16'd800; htotal <= 16'd1192; hstart <= 16'd182;
            vactive <= 16'd480; vtotal <= 16'd533;  vstart <= 16'd8;
        end else begin
            a_off <= haddr[7:2]; a_wr <= hwrite; a_sel <= a_active;
            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00: begin enable <= hwdata[0]; test <= hwdata[1]; yuv <= hwdata[2]; full_range <= hwdata[3];
                                 scale <= hwdata[4]; osd <= hwdata[5]; end
                    6'h0F: begin src_w <= hwdata[15:0]; src_h <= hwdata[31:16]; end
                    6'h10: begin dst_x <= hwdata[15:0]; dst_y <= hwdata[31:16]; end
                    6'h11: begin dst_w <= hwdata[15:0]; dst_h <= hwdata[31:16]; end
                    6'h12: step_x <= hwdata[21:0];
                    6'h13: step_y <= hwdata[21:0];
                    6'h14: bg <= hwdata[15:0];
                    6'h15: osd_base <= {hwdata[31:5], 5'b00000};
                    6'h16: osd_stride <= {hwdata[15:5], 5'b00000};
                    6'h17: begin osd_x <= hwdata[15:0]; osd_y <= hwdata[31:16]; end
                    6'h18: begin osd_w <= hwdata[15:0]; osd_h <= hwdata[31:16]; end
                    6'h02: fb_base <= {hwdata[31:5], 5'b00000};
                    6'h03: stride  <= {hwdata[15:5], 5'b00000};
                    6'h0C: fb_base_u <= {hwdata[31:5], 5'b00000};
                    6'h0D: fb_base_v <= {hwdata[31:5], 5'b00000};
                    6'h0E: stride_c  <= {hwdata[15:5], 5'b00000};
                    6'h04: begin hactive <= {hwdata[15:2], 2'b00}; htotal <= hwdata[31:16]; end
                    6'h05: hstart <= hwdata[15:0];
                    6'h06: begin vactive <= hwdata[15:0]; vtotal <= hwdata[31:16]; end
                    6'h07: vstart <= hwdata[15:0];
                    default: ;
                endcase
            end
        end
    end

    reg [31:0] rd;
    always @(*) begin
        case (a_off)
            6'h00: rd = {26'b0, osd, scale, full_range, yuv, test, enable};
            6'h02: rd = fb_base;
            6'h03: rd = {16'b0, stride};
            6'h04: rd = {htotal, hactive};
            6'h05: rd = {16'b0, hstart};
            6'h06: rd = {vtotal, vactive};
            6'h07: rd = {16'b0, vstart};
            6'h08: rd = frames;
            6'h09: rd = underruns;
            6'h0A: rd = frame_crc;
            6'h0B: rd = 32'h5649_4430;
            6'h0C: rd = fb_base_u;
            6'h0D: rd = fb_base_v;
            6'h0E: rd = {16'b0, stride_c};
            6'h0F: rd = {src_h, src_w};
            6'h10: rd = {dst_y, dst_x};
            6'h11: rd = {dst_h, dst_w};
            6'h12: rd = {10'b0, step_x};
            6'h13: rd = {10'b0, step_y};
            6'h14: rd = {16'b0, bg};
            6'h15: rd = osd_base;
            6'h16: rd = {16'b0, osd_stride};
            6'h17: rd = {osd_y, osd_x};
            6'h18: rd = {osd_h, osd_w};
            6'h19: rd = 32'h7;                  // CAPS: YUV, scaler, OSD
            default: rd = 32'h0;
        endcase
    end
    assign hrdata = rd;
endmodule
`default_nettype wire
