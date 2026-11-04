`default_nettype none
//============================================================================
// video_out.v -- pixel-clock side of the LCD video core.
//
// Timing generator for a DE-mode RGB panel: counters h (0..htotal-1) and
// v (0..vtotal-1); DE is high for h in [hstart, hstart+hactive) on lines
// v in [vstart, vstart+vactive).  Enable / test / YUV mode changes take
// effect at the start of a frame.
//
// Line fetch: early in each line (h == 11) it requests the active line shown
// during the NEXT line period (req_tgl toggles, req_line holds
// {frame parity, index}); video_fetch reads it into line-RAM half (index & 1),
// the half the display left two lines ago, and returns the request as
// done_line, which tags that half.  An active line whose half does not carry
// its tag at the first pixel counts as an underrun and shows whatever the half
// holds -- a late fetch costs one line, never the frame alignment.  (The next
// line's fetch may well finish before this line starts: it fills the other
// half.)
//
// Scaler (nearest neighbour): the picture window [dx, dxe) x [dy, dye) of the
// active area shows the source picture; around it the background colour.
// Window line k shows source line floor((k*step_y + step_y/2) / 65536) and
// window pixel k source pixel floor((k*step_x + step_x/2) / 65536), both
// clamped to the source size: a DDA per line (in the next-line pipeline, the
// source line goes with the fetch request) and one per pixel.  Off (CTRL[4]
// = 0) the bus side sets the window to the active area and the steps to 1.0,
// which samples pixel k exactly.
//
// Line RAMs (written by video_fetch, read here; half = active line & 1):
// Y/RGB (64 words of 32 Y samples or 16 RGB565 pixels), U and V (32 words of
// 32 samples), OSD (128 words of 8 ARGB8888 pixels).  Each has its own read
// port, so every pixel reads the words holding its own samples -- any scale
// factor works.  Per pixel: sample selection, YUV -> RGB888 in fixed-point
// BT.601 (limited, or full range for JPEG material):
//   R = (ky*Y + ko + krv*(V-128)) >> 8, G = (.. - kgu*(U-128) - kgv*(V-128)) >> 8,
//   B = (.. + kbu*(U-128)) >> 8, clamped; or RGB565 widened to RGB888 (bits
// repeated); chroma samples repeated (no interpolation).
//
// OSD (CTRL[5]): an ARGB8888 layer in the window [ox, oxe) x [oy, oye), one
// OSD pixel per panel pixel, fetched per line after the video planes.  It is
// blended over the picture (or background) in RGB888:
//   out = (osd * a' + pic * (256 - a')) >> 8, a' = A + A[7] (0..256)
// so A = 0 leaves the picture bit-exact and A = 255 shows the OSD pixel.
// The result is packed as RGB565 -- the CRC and the panel see RGB565 -- and
// widened to the panel's RGB666 (5-bit channels repeat their MSB).
//
// The scaler and OSD settings come frame-latched from the bus clock and are
// taken over at the end of line 0 (or continuously while scan-out is off),
// before the frame's first line request when vstart >= 2.
// Outputs are registered.  A zlib CRC-32 of each frame's active pixels (as
// RGB565, little-endian) is kept for checking the picture against the
// framebuffer; frame_tgl toggles when a frame (and its CRC / underrun count)
// completes.
//
// Logic depth: no arithmetic feeds a compare in the same cycle.  The timing
// values are copied into the pixel clock with their derived constants
// (hstart+hactive, htotal-2, ...), every timing event is a registered 12-bit
// equality compare against one of them, and window flags / pixel index / line
// index are set, cleared and counted by those events.  The next line's state
// (active, index, frame parity) is worked out in a short pipeline while the
// current line runs -- v changes once a line -- and loaded at the line wrap.
// The pixel path is staged (window/DDA -> RAM addresses -> RAM -> sample
// select -> products -> sums -> pixel -> blend -> pack -> outputs + CRC data
// term -> CRC state), the CRC split as crc16(c, d) = F(c) ^ G(d).  Counters are 12 bits:
// totals up to 4095, and htotal must be at least 16.
//============================================================================
module video_out (
    input  wire        pclk,
    input  wire        prstn,         // synchronous to pclk, active low
    // configuration (bus clock; enable/test/yuv/full are synchronised here,
    // the timing values are static while scan-out runs)
    input  wire        cfg_enable,
    input  wire        cfg_test,
    input  wire        cfg_yuv,
    input  wire        cfg_full,
    input  wire [15:0] hactive, htotal, hstart,
    input  wire [15:0] vactive, vtotal, vstart,
    // scaler and OSD (frame-latched on the bus side, taken over once a frame)
    input  wire [15:0] cfg_dx, cfg_dxe, cfg_dy, cfg_dye,   // picture window [dx, dxe) x [dy, dye)
    input  wire [21:0] cfg_stepx, cfg_stepy,               // 16.16
    input  wire [15:0] cfg_srcw, cfg_srch,                 // source size (>= 1)
    input  wire [15:0] cfg_bg,                             // RGB565 around the window
    input  wire        cfg_osd,
    input  wire [15:0] cfg_ox, cfg_oxe, cfg_oy, cfg_oye,   // OSD window
    // line-fetch handshake with video_fetch (DDR clock)
    output reg         req_tgl,
    output reg  [15:0] req_line,      // {frame parity, line}, held until the next request
    output reg  [25:0] req_info,      // {video, osd, source line, OSD line}
    input  wire        done_tgl,      // asynchronous
    input  wire [15:0] done_line,     // a req_line value, stable when done_tgl toggles
    // line RAM read ports ({half, word}; data one cycle after the address)
    output reg  [6:0]   y_raddr,
    input  wire [255:0] y_rdata,
    output reg  [5:0]   c_raddr,      // U and V RAMs
    input  wire [255:0] u_rdata,
    input  wire [255:0] v_rdata,
    output reg  [7:0]   o_raddr,
    input  wire [255:0] o_rdata,
    // frame status (to the bus clock)
    output reg         frame_tgl,
    output reg  [31:0] frame_crc,     // stable after frame_tgl toggles
    output reg  [31:0] underruns,
    // panel
    output reg         lcd_de,
    output reg  [5:0]  lcd_r,
    output reg  [5:0]  lcd_g,
    output reg  [5:0]  lcd_b
);
    // zlib CRC-32 (reflected 0xEDB88320) over 16 bits, low byte first.  It is
    // linear: crc16(c, d) = crc16(c, 0) ^ crc16(0, d).
    function [31:0] crc16(input [31:0] c, input [15:0] d);
        integer i;
        reg [31:0] r;
        begin
            r = c;
            for (i = 0; i < 16; i = i + 1)
                r = (r >> 1) ^ ((r[0] ^ d[i]) ? 32'hEDB88320 : 32'h0);
            crc16 = r;
        end
    endfunction
    localparam [31:0] CRC_INIT = 32'hFFFFFFFF;
    localparam OUTST = 12;              // the stage holding the panel outputs

    function [15:0] bar_rgb(input [2:0] b);     // white yellow cyan green magenta red blue black
        case (b)
            3'd0: bar_rgb = 16'hFFFF;  3'd1: bar_rgb = 16'hFFE0;
            3'd2: bar_rgb = 16'h07FF;  3'd3: bar_rgb = 16'h07E0;
            3'd4: bar_rgb = 16'hF81F;  3'd5: bar_rgb = 16'hF800;
            3'd6: bar_rgb = 16'h001F;  default: bar_rgb = 16'h0000;
        endcase
    endfunction
    function [23:0] rgb888(input [15:0] p);     // RGB565 widened, bits repeated
        rgb888 = {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
    endfunction

    // saturate a >> 8 of a signed 21-bit sum to 0..255
    function [7:0] clamp8(input signed [20:0] v);
        begin
            if (v < 0)                 clamp8 = 8'd0;
            else if (v[20:8] > 13'd255) clamp8 = 8'd255;
            else                       clamp8 = v[15:8];
        end
    endfunction

    // ---- timing in the pixel clock + derived constants (static) ----
    reg [11:0] c_hstart, c_hend, c_htot_m2, c_vstart, c_vend, c_vtot_m1;
    reg        c_hact_nz, c_vact_nz;
    always @(posedge pclk) begin
        c_hstart  <= hstart[11:0];
        c_hend    <= hstart[11:0] + hactive[11:0];
        c_htot_m2 <= htotal[11:0] - 12'd2;
        c_vstart  <= vstart[11:0];
        c_vend    <= vstart[11:0] + vactive[11:0];
        c_vtot_m1 <= vtotal[11:0] - 12'd1;
        c_hact_nz <= (hactive[11:0] != 12'd0);
        c_vact_nz <= (vactive[11:0] != 12'd0);
    end

    // ---- enable / test / mode: synchronised, applied at the frame wrap ----
    reg [1:0] en_s, test_s, yuv_s, full_s;
    always @(posedge pclk) begin
        en_s   <= {en_s[0], cfg_enable};
        test_s <= {test_s[0], cfg_test};
        yuv_s  <= {yuv_s[0], cfg_yuv};
        full_s <= {full_s[0], cfg_full};
    end

    // Stage naming: a "...N" register holds information about the counter
    // position N cycles ago, so signals with the same N belong together.
    // stage 0: counters and the state of the current line
    reg  [11:0] h, v, cur_y;
    reg         h_wrap;                 // h == htotal-1
    reg         v_is0;                  // v == 0
    reg         cur_act, fpar, run, test, yuv, full;
    reg         cur_vid, cur_osd;       // this line shows picture / OSD pixels
    reg  [29:0] cur_acc;                // this line's vertical DDA (14.16)
    reg         run_n, test_n, yuv_n, full_n;   // next frame's, decided early in its last line
    // scaler / OSD settings of the frame
    reg  [11:0] c_dx, c_dxe, c_dy, c_dye, c_ox, c_oxe, c_oy, c_oye, c_srcw_m1, c_srch_m1;
    reg  [21:0] c_stepx, c_stepy;
    reg  [15:0] c_bg;
    reg         c_osd;
    // next-line pipeline (inputs stable for the whole line, settled by h == 9)
    reg         v_wrap;                 // v == vtotal-1
    reg  [11:0] vp1, yp1, vn, ny;
    reg         vn_s, vn_e, vn_0, na, npar;
    reg         nvid, nosd, nfst;
    reg  [11:0] nol, nsrc;
    reg  [29:0] nacc;
    reg  [11:0] lsd;                    // lsd[k]: h == k
    // stage 1: horizontal events, delayed line state
    reg         hs1, he1, hz1, act1, par1, run1, test1, vid1, osd1;
    reg  [11:0] y1;
    // stage 2: DE window, pixel index, underrun check inputs
    reg         in_h2, de2, test2, ev2, vid2, osd2, half2;
    reg  [9:0]  x2;
    reg  [15:0] tsel2, ytag2;
    // stage 3: windows and DDAs
    reg         de3, test3, ev3, tok3, vw3, ow3, half3;
    reg  [2:0]  bar3;
    reg  [28:0] acc3;                   // horizontal DDA (13.16)
    reg  [9:0]  oc3;                    // OSD pixel index
    // stage 4: RAM addresses registered (data at stage 5), underrun
    reg         de4, test4, vw4, ow4, ur4;
    reg  [2:0]  bar4, osel4;
    reg  [4:0]  ysel4, csel4;
    reg  [3:0]  rsel4;
    // stage 5: RAM data valid
    reg         de5, test5, vw5, ow5;
    reg  [2:0]  bar5, osel5;
    reg  [4:0]  ysel5, csel5;
    reg  [3:0]  rsel5;
    // stage 6: the pixel's samples
    reg         de6, test6, vw6, ow6;
    reg  [2:0]  bar6;
    reg  [7:0]  y6, u6, v6;
    reg  [15:0] rgb6;
    reg  [31:0] osd6;
    // stages 7, 8: YUV products and sums
    reg         de7, test7, vw7, ow7, de8, test8, vw8, ow8;
    reg  [2:0]  bar7, bar8;
    reg  [15:0] rgb7, rgb8;
    reg  [31:0] osd7, osd8;
    reg  signed [19:0] py7, prv7, pgu7, pgv7, pbu7;
    reg  signed [20:0] r8, g8, b8;
    // stage 9: picture pixel (RGB888) and OSD alpha; 10: blend; 11: RGB565
    reg         de9, de10, de11;
    reg  [23:0] pic9, osd9;
    reg  [8:0]  a9;
    reg  [16:0] br10, bg10, bb10;
    reg  [15:0] pix11;
    // stage 12: outputs, CRC data term; 13: CRC
    reg         de12;
    reg  [31:0] g12, crc;
    reg  [OUTST-1:0] fend;              // fend[k]: the frame's last position, k+1 cycles ago

    // ---- fetch completion from the DDR clock ----
    reg  [2:0]  done_s;
    reg  [15:0] tag0, tag1;             // request held by each RAM half
    wire        done_edge = done_s[2] ^ done_s[1];

    wire        in_h_n = (hs1 & c_hact_nz) | (in_h2 & ~he1 & ~hz1);
    wire [11:0] x2e = {2'b00, x2};

    // conversion coefficients (x256): BT.601 limited range / JPEG full range
    wire signed [19:0] ky  = full ? 20'sd256 : 20'sd298;
    wire signed [19:0] ko  = full ? 20'sd128 : -20'sd4640;      // 128 - 298*16
    wire signed [19:0] krv = full ? 20'sd359 : 20'sd409;
    wire signed [19:0] kgu = full ? 20'sd88  : 20'sd100;
    wire signed [19:0] kgv = full ? 20'sd183 : 20'sd208;
    wire signed [19:0] kbu = full ? 20'sd454 : 20'sd516;
    wire signed [19:0] cu6 = $signed({12'd0, u6}) - 20'sd128;
    wire signed [19:0] cv6 = $signed({12'd0, v6}) - 20'sd128;
    // stage 3 -> 4: the source pixel, clamped
    wire [12:0] sx3  = acc3[28:16];
    wire [11:0] sxc3 = (sx3 > {1'b0, c_srcw_m1}) ? c_srcw_m1 : sx3[11:0];
    // stage 9 -> 10: blend weights
    wire [8:0]  ia9 = 9'd256 - a9;
    integer k;

    always @(posedge pclk) begin
        if (!prstn) begin
            h <= 0; v <= 0; cur_y <= 0; h_wrap <= 0; v_is0 <= 0; cur_act <= 0; fpar <= 0; run <= 0; test <= 0; yuv <= 0; full <= 0;
            cur_vid <= 0; cur_osd <= 0; cur_acc <= 0;
            run_n <= 0; test_n <= 0; yuv_n <= 0; full_n <= 0;
            c_dx <= 0; c_dxe <= 0; c_dy <= 0; c_dye <= 0; c_ox <= 0; c_oxe <= 0; c_oy <= 0; c_oye <= 0;
            c_srcw_m1 <= 0; c_srch_m1 <= 0; c_stepx <= 22'h10000; c_stepy <= 22'h10000; c_bg <= 0; c_osd <= 0;
            v_wrap <= 0; vp1 <= 0; yp1 <= 0; vn <= 0; ny <= 0;
            vn_s <= 0; vn_e <= 0; vn_0 <= 0; na <= 0; npar <= 0; lsd <= 0;
            nvid <= 0; nosd <= 0; nfst <= 0; nol <= 0; nsrc <= 0; nacc <= 0;
            hs1 <= 0; he1 <= 0; hz1 <= 0; act1 <= 0; par1 <= 0; run1 <= 0; test1 <= 0; vid1 <= 0; osd1 <= 0; y1 <= 0;
            in_h2 <= 0; de2 <= 0; test2 <= 0; ev2 <= 0; vid2 <= 0; osd2 <= 0; half2 <= 0; x2 <= 0; tsel2 <= 0; ytag2 <= 0;
            de3 <= 0; test3 <= 0; ev3 <= 0; tok3 <= 0; vw3 <= 0; ow3 <= 0; half3 <= 0; bar3 <= 0; acc3 <= 0; oc3 <= 0;
            y_raddr <= 0; c_raddr <= 0; o_raddr <= 0;
            de4 <= 0; test4 <= 0; vw4 <= 0; ow4 <= 0; ur4 <= 0; bar4 <= 0; osel4 <= 0; ysel4 <= 0; csel4 <= 0; rsel4 <= 0;
            de5 <= 0; test5 <= 0; vw5 <= 0; ow5 <= 0; bar5 <= 0; osel5 <= 0; ysel5 <= 0; csel5 <= 0; rsel5 <= 0;
            de6 <= 0; test6 <= 0; vw6 <= 0; ow6 <= 0; bar6 <= 0; y6 <= 0; u6 <= 0; v6 <= 0; rgb6 <= 0; osd6 <= 0;
            de7 <= 0; test7 <= 0; vw7 <= 0; ow7 <= 0; bar7 <= 0; rgb7 <= 0; osd7 <= 0;
            de8 <= 0; test8 <= 0; vw8 <= 0; ow8 <= 0; bar8 <= 0; rgb8 <= 0; osd8 <= 0;
            py7 <= 0; prv7 <= 0; pgu7 <= 0; pgv7 <= 0; pbu7 <= 0; r8 <= 0; g8 <= 0; b8 <= 0;
            de9 <= 0; de10 <= 0; de11 <= 0; pic9 <= 0; osd9 <= 0; a9 <= 0; br10 <= 0; bg10 <= 0; bb10 <= 0; pix11 <= 0;
            de12 <= 0; g12 <= 0; crc <= CRC_INIT; fend <= 0;
            req_tgl <= 0; req_line <= 0; req_info <= 0; done_s <= 0; tag0 <= 16'hFFFF; tag1 <= 16'hFFFF;
            lcd_de <= 0; lcd_r <= 0; lcd_g <= 0; lcd_b <= 0;
            frame_crc <= 0; frame_tgl <= 0; underruns <= 0;
        end else begin
            // ---- stage 0: horizontal counter (wrap flag a cycle ahead) ----
            h      <= h_wrap ? 12'd0 : h + 12'd1;
            h_wrap <= (h == c_htot_m2);
            lsd    <= {lsd[10:0], h_wrap};
            v_is0  <= (v == 12'd0);

            // scaler / OSD settings: at the end of line 0 (the bus side has
            // latched them at the frame end), or all the time while stopped
            if ((h_wrap && v_is0) || !run) begin
                c_dx  <= cfg_dx[11:0];  c_dxe <= cfg_dxe[11:0];
                c_dy  <= cfg_dy[11:0];  c_dye <= cfg_dye[11:0];
                c_ox  <= cfg_ox[11:0];  c_oxe <= cfg_oxe[11:0];
                c_oy  <= cfg_oy[11:0];  c_oye <= cfg_oye[11:0];
                c_srcw_m1 <= cfg_srcw[11:0] - 12'd1;
                c_srch_m1 <= cfg_srch[11:0] - 12'd1;
                c_stepx <= cfg_stepx; c_stepy <= cfg_stepy;
                c_bg <= cfg_bg; c_osd <= cfg_osd;
            end

            // next line: v + 1 (or 0), its window events, active flag,
            // index and frame parity; then its picture / OSD flags and source line
            v_wrap <= (v == c_vtot_m1);
            vp1    <= v + 12'd1;
            yp1    <= cur_y + 12'd1;
            vn     <= v_wrap ? 12'd0 : vp1;
            vn_s   <= (vn == c_vstart) & c_vact_nz;
            vn_e   <= (vn == c_vend);
            vn_0   <= (vn == 12'd0);
            na     <= vn_s | (cur_act & ~vn_e & ~vn_0);
            ny     <= vn_s ? 12'd0 : yp1;
            npar   <= v_wrap ? ~fpar : fpar;
            nvid   <= na & (ny >= c_dy) & (ny < c_dye);
            nosd   <= na & c_osd & (ny >= c_oy) & (ny < c_oye);
            nfst   <= (ny == c_dy);
            nol    <= ny - c_oy;
            nacc   <= nfst ? {9'd0, c_stepy[21:1]} : cur_acc + {8'd0, c_stepy};
            nsrc   <= (nacc[29:16] > {2'b00, c_srch_m1}) ? c_srch_m1 : nacc[27:16];

            // enable / test / mode for the next frame are sampled early in
            // this frame's last line, so that line already requests the next
            // frame's first line (vstart = 0) by the new mode
            if (lsd[6] && v_wrap) begin
                run_n  <= en_s[1] | test_s[1];
                test_n <= test_s[1];
                yuv_n  <= yuv_s[1];
                full_n <= full_s[1];
            end

            // line wrap: load the next line's state; frame wrap: the new mode
            if (h_wrap) begin
                v       <= vn;
                cur_act <= na;
                cur_y   <= ny;
                fpar    <= npar;
                cur_vid <= nvid;
                cur_osd <= nosd;
                cur_acc <= nacc;
                if (v_wrap) begin
                    run  <= run_n;
                    test <= test_n;
                    yuv  <= yuv_n;
                    full <= full_n;
                end
            end

            // request the line shown during the next line period (when it
            // shows picture or OSD pixels)
            if (lsd[11] && na && (nvid || nosd) && (v_wrap ? run_n && !test_n : run && !test)) begin
                req_line <= {npar, 3'd0, ny};
                req_info <= {nvid, nosd, nsrc, nol};
                req_tgl  <= ~req_tgl;
            end

            // fetch completions tag their RAM half
            done_s <= {done_s[1:0], done_tgl};
            if (done_edge) begin
                if (done_line[0]) tag1 <= done_line;
                else              tag0 <= done_line;
            end

            // ---- stage 1 ----
            hs1   <= (h == c_hstart);
            he1   <= (h == c_hend);
            hz1   <= (h == 12'd0);
            act1  <= cur_act;
            par1  <= fpar;
            run1  <= run;
            test1 <= test;
            vid1  <= cur_vid;
            osd1  <= cur_osd;
            y1    <= cur_y;

            // ---- stage 2: DE window and pixel index ----
            in_h2 <= in_h_n;
            de2   <= in_h_n & act1 & run1;
            x2    <= de2 ? x2 + 10'd1 : 10'd0;
            test2 <= test1;
            vid2  <= vid1;
            osd2  <= osd1;
            half2 <= y1[0];
            // underrun check: first pixel of a fetched line, its half's tag
            ev2   <= hs1 & c_hact_nz & act1 & run1 & ~test1 & (vid1 | osd1);
            tsel2 <= y1[0] ? tag1 : tag0;
            ytag2 <= {par1, 3'd0, y1};

            // ---- stage 3: picture / OSD windows, horizontal DDA ----
            de3   <= de2;
            test3 <= test2;
            bar3  <= x2[9:7];
            half3 <= half2;
            vw3   <= de2 & vid2 & (x2e >= c_dx) & (x2e < c_dxe);
            acc3  <= (x2e == c_dx) ? {8'd0, c_stepx[21:1]} : acc3 + {7'd0, c_stepx};
            ow3   <= de2 & osd2 & ~test2 & (x2e >= c_ox) & (x2e < c_oxe);
            oc3   <= (x2e == c_ox) ? 10'd0 : oc3 + 10'd1;
            ev3   <= ev2;
            tok3  <= (tsel2 == ytag2);

            // ---- stage 4: RAM addresses of the pixel's words (data at stage 5) ----
            y_raddr <= {half3, yuv ? sxc3[10:5] : sxc3[9:4]};
            c_raddr <= {half3, sxc3[10:6]};
            o_raddr <= {half3, oc3[9:3]};
            de4   <= de3;
            test4 <= test3;
            bar4  <= bar3;
            vw4   <= vw3;
            ow4   <= ow3;
            ysel4 <= sxc3[4:0];
            rsel4 <= sxc3[3:0];
            csel4 <= sxc3[5:1];
            osel4 <= oc3[2:0];
            ur4   <= ev3 & ~tok3;
            if (ur4) underruns <= underruns + 32'd1;

            // ---- stage 5: RAM data valid ----
            de5 <= de4; test5 <= test4; bar5 <= bar4; vw5 <= vw4; ow5 <= ow4;
            ysel5 <= ysel4; rsel5 <= rsel4; csel5 <= csel4; osel5 <= osel4;

            // ---- stage 6: the pixel's samples ----
            y6   <= y_rdata[ysel5*8 +: 8];
            u6   <= u_rdata[csel5*8 +: 8];
            v6   <= v_rdata[csel5*8 +: 8];
            rgb6 <= y_rdata[rsel5*16 +: 16];
            osd6 <= o_rdata[osel5*32 +: 32];
            de6 <= de5; test6 <= test5; bar6 <= bar5; vw6 <= vw5; ow6 <= ow5;

            // ---- stage 7: products (DSP) ----
            py7  <= $signed({12'd0, y6}) * ky + ko;
            prv7 <= cv6 * krv;
            pgu7 <= cu6 * kgu;
            pgv7 <= cv6 * kgv;
            pbu7 <= cu6 * kbu;
            de7 <= de6; test7 <= test6; bar7 <= bar6; vw7 <= vw6; ow7 <= ow6; rgb7 <= rgb6; osd7 <= osd6;

            // ---- stage 8: sums ----
            r8 <= py7 + prv7;
            g8 <= py7 - pgu7 - pgv7;
            b8 <= py7 + pbu7;
            de8 <= de7; test8 <= test7; bar8 <= bar7; vw8 <= vw7; ow8 <= ow7; rgb8 <= rgb7; osd8 <= osd7;

            // ---- stage 9: the picture pixel in RGB888; the OSD pixel and weight ----
            pic9 <= test8 ? rgb888(bar_rgb(bar8)) : !vw8 ? rgb888(c_bg) :
                    yuv ? {clamp8(r8), clamp8(g8), clamp8(b8)} : rgb888(rgb8);
            osd9 <= osd8[23:0];
            a9   <= ow8 ? {1'b0, osd8[31:24]} + {8'd0, osd8[31]} : 9'd0;
            de9  <= de8;

            // ---- stage 10: blend ----
            br10 <= osd9[23:16] * a9 + pic9[23:16] * ia9;
            bg10 <= osd9[15:8]  * a9 + pic9[15:8]  * ia9;
            bb10 <= osd9[7:0]   * a9 + pic9[7:0]   * ia9;
            de10 <= de9;

            // ---- stage 11: RGB565 ----
            pix11 <= {br10[15:11], bg10[15:10], bb10[15:11]};
            de11  <= de10;

            // ---- stage 12: panel outputs and CRC term ----
            lcd_de <= de11;
            lcd_r  <= de11 ? {pix11[15:11], pix11[15]} : 6'd0;
            lcd_g  <= de11 ? pix11[10:5]               : 6'd0;
            lcd_b  <= de11 ? {pix11[4:0], pix11[4]}    : 6'd0;
            de12   <= de11;
            g12    <= crc16(32'd0, pix11);

            // ---- stage 13: CRC of what was sent; publish with the frame's
            // last position (stage 12 then holds it), so frame_tgl changes
            // before the next frame's first pixel reaches the panel ----
            fend <= {fend[OUTST-2:0], h_wrap & v_wrap};
            if (fend[OUTST-1]) begin
                frame_crc <= ~(de12 ? crc16(crc, 16'd0) ^ g12 : crc);
                frame_tgl <= ~frame_tgl;
                crc       <= CRC_INIT;
            end else if (de12) begin
                crc       <= crc16(crc, 16'd0) ^ g12;
            end
        end
    end
endmodule
`default_nettype wire
