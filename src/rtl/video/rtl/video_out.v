`default_nettype none
//============================================================================
// video_out.v -- pixel-clock side of the LCD video core.
//
// Timing generator for a DE-mode RGB panel: counters h (0..htotal-1) and
// v (0..vtotal-1); DE is high for h in [hstart, hstart+hactive) on lines
// v in [vstart, vstart+vactive).  Enable / test / YUV mode changes take
// effect at the start of a frame.
//
// Line fetch: early in each line (h == 7) it requests the active line shown
// during the NEXT line period (req_tgl toggles, req_line holds
// {frame parity, index}); video_fetch reads it into line-RAM half (index & 1),
// the half the display left two lines ago, and returns the request as
// done_line, which tags that half.  An active line whose half does not carry
// its tag at the first pixel counts as an underrun and shows whatever the half
// holds -- a late fetch costs one line, never the frame alignment.  (The next
// line's fetch may well finish before this line starts: it fills the other
// half.)
//
// Pixels, RGB565 mode: line RAM words (256 bit = 16 pixels) are read with one
// cycle of latency and the lane selected.  YUV 4:2:0 mode: the half holds the
// Y plane in words 0..31 (32 pixels per word), U in 32..47 and V in 48..63
// (32 chroma samples = 64 pixels per word).  A new word is only needed every
// 16 pixels, so the first three cycles of every 16-pixel group read the Y, U
// and V words of that group into a holding set (two sets, by group parity);
// four cycles later the pixel's bytes are picked from them and converted with
// fixed-point BT.601 (limited range, or full range for JPEG material):
//   R = (ky*Y + ko + krv*(V-128)) >> 8, G = (.. - kgu*(U-128) - kgv*(V-128)) >> 8,
//   B = (.. + kbu*(U-128)) >> 8, clamped, packed as RGB565 -- so the CRC and
// the panel path below see RGB565 in both modes.  Chroma samples are repeated
// (no interpolation).  Both modes go through the same 6 extra stages, so DE and
// the picture stay aligned whatever the mode.
//
// RGB565 is expanded to the panel's RGB666 (5-bit channels repeat their MSB).
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
// The pixel path is staged (RAM -> lane select -> ... -> CRC data term -> CRC
// state), the CRC split as crc16(c, d) = F(c) ^ G(d).  Counters are 12 bits:
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
    // line-fetch handshake with video_fetch (DDR clock)
    output reg         req_tgl,
    output reg  [15:0] req_line,      // {frame parity, index}, held until the next request
    input  wire        done_tgl,      // asynchronous
    input  wire [15:0] done_line,     // a req_line value, stable when done_tgl toggles
    // line RAM read port
    output reg  [6:0]   ram_raddr,
    input  wire [255:0] ram_rdata,
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
    localparam EXTRA = 6;               // pipeline stages added after the RAM data

    function [15:0] bar_rgb(input [2:0] b);     // white yellow cyan green magenta red blue black
        case (b)
            3'd0: bar_rgb = 16'hFFFF;  3'd1: bar_rgb = 16'hFFE0;
            3'd2: bar_rgb = 16'h07FF;  3'd3: bar_rgb = 16'h07E0;
            3'd4: bar_rgb = 16'hF81F;  3'd5: bar_rgb = 16'hF800;
            3'd6: bar_rgb = 16'h001F;  default: bar_rgb = 16'h0000;
        endcase
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
    reg         cur_act, fpar, run, test, yuv, full;
    reg         run_n, test_n, yuv_n, full_n;   // next frame's, decided early in its last line
    // next-line pipeline (inputs stable for the whole line, settled by h == 5)
    reg         v_wrap;                 // v == vtotal-1
    reg  [11:0] vp1, yp1, vn, ny;
    reg         vn_s, vn_e, vn_0, na, npar;
    reg  [7:0]  lsd;                    // lsd[k]: h == k
    // stage 1: horizontal events, delayed line state
    reg         hs1, he1, hz1, act1, par1, run1, test1;
    reg  [11:0] y1;
    // stage 2: DE window, pixel index, underrun check inputs
    reg         in_h2, de2, test2, ev2;
    reg  [9:0]  x2;
    reg  [11:0] y2;
    reg  [15:0] tsel2, ytag2;
    // stage 3: RAM data valid
    reg         de3, test3, ev3, tok3;
    reg  [3:0]  lane3;
    reg  [5:0]  x3;
    reg  [2:0]  bar3;
    // stage 4: RGB / test pixel, underrun
    reg         de4, ur4;
    reg  [15:0] pix4;
    // stages 4..10: delay of the RGB pixel and DE; YUV word sets and conversion
    reg  [15:0] pix_d [0:EXTRA-1];      // pix_d[EXTRA-1] belongs to stage 4+EXTRA
    reg  [EXTRA-1:0] de_d;
    reg  [5:0]  x_d [0:2];              // x3 delayed to stage 6: selects the stage-7 samples
    reg  [255:0] yw [0:1], uw [0:1], vw [0:1];
    reg  [7:0]  y7, u7, v7;
    reg  signed [19:0] py8, prv8, pgu8, pgv8, pbu8;
    reg  signed [20:0] r9, g9, b9;
    reg  [15:0] pixy10;
    // stage 4+EXTRA (= 10): the pixel; 11: outputs, CRC data term; 12: CRC
    reg         de11;
    reg  [31:0] g11, crc;
    reg  [4+EXTRA:0] fend;              // fend[k]: the frame's last position, k+1 cycles ago

    // ---- fetch completion from the DDR clock ----
    reg  [2:0]  done_s;
    reg  [15:0] tag0, tag1;             // request held by each RAM half
    wire        done_edge = done_s[2] ^ done_s[1];

    wire        in_h_n = (hs1 & c_hact_nz) | (in_h2 & ~he1 & ~hz1);
    wire [9:0]  x2n = de2 ? x2 + 10'd1 : 10'd0;      // next value of x2

    // conversion coefficients (x256): BT.601 limited range / JPEG full range
    wire signed [19:0] ky  = full ? 20'sd256 : 20'sd298;
    wire signed [19:0] ko  = full ? 20'sd128 : -20'sd4640;      // 128 - 298*16
    wire signed [19:0] krv = full ? 20'sd359 : 20'sd409;
    wire signed [19:0] kgu = full ? 20'sd88  : 20'sd100;
    wire signed [19:0] kgv = full ? 20'sd183 : 20'sd208;
    wire signed [19:0] kbu = full ? 20'sd454 : 20'sd516;
    wire signed [19:0] cu7 = $signed({12'd0, u7}) - 20'sd128;
    wire signed [19:0] cv7 = $signed({12'd0, v7}) - 20'sd128;
    wire [5:0]  x7 = x_d[2];            // the pixel whose samples are registered next (stage 7)
    wire        set7 = x7[4];
    wire [7:0]  rc9 = clamp8(r9), gc9 = clamp8(g9), bc9 = clamp8(b9);
    wire [15:0] pix10 = (yuv && !test) ? pixy10 : pix_d[EXTRA-1];   // stage 10, either mode
    integer k;

    always @(posedge pclk) begin
        if (!prstn) begin
            h <= 0; v <= 0; cur_y <= 0; h_wrap <= 0; cur_act <= 0; fpar <= 0; run <= 0; test <= 0; yuv <= 0; full <= 0;
            run_n <= 0; test_n <= 0; yuv_n <= 0; full_n <= 0;
            v_wrap <= 0; vp1 <= 0; yp1 <= 0; vn <= 0; ny <= 0;
            vn_s <= 0; vn_e <= 0; vn_0 <= 0; na <= 0; npar <= 0; lsd <= 0;
            hs1 <= 0; he1 <= 0; hz1 <= 0; act1 <= 0; par1 <= 0; run1 <= 0; test1 <= 0; y1 <= 0;
            in_h2 <= 0; de2 <= 0; test2 <= 0; ev2 <= 0; x2 <= 0; y2 <= 0; tsel2 <= 0; ytag2 <= 0;
            ram_raddr <= 0;
            de3 <= 0; test3 <= 0; ev3 <= 0; tok3 <= 0; lane3 <= 0; x3 <= 0; bar3 <= 0;
            de4 <= 0; ur4 <= 0; pix4 <= 0;
            for (k = 0; k < EXTRA; k = k + 1) pix_d[k] <= 0;
            de_d <= 0;
            for (k = 0; k < 3; k = k + 1) x_d[k] <= 0;
            yw[0] <= 0; yw[1] <= 0; uw[0] <= 0; uw[1] <= 0; vw[0] <= 0; vw[1] <= 0;
            y7 <= 0; u7 <= 0; v7 <= 0;
            py8 <= 0; prv8 <= 0; pgu8 <= 0; pgv8 <= 0; pbu8 <= 0;
            r9 <= 0; g9 <= 0; b9 <= 0; pixy10 <= 0;
            de11 <= 0; g11 <= 0; crc <= CRC_INIT; fend <= 0;
            req_tgl <= 0; req_line <= 0; done_s <= 0; tag0 <= 16'hFFFF; tag1 <= 16'hFFFF;
            lcd_de <= 0; lcd_r <= 0; lcd_g <= 0; lcd_b <= 0;
            frame_crc <= 0; frame_tgl <= 0; underruns <= 0;
        end else begin
            // ---- stage 0: horizontal counter (wrap flag a cycle ahead) ----
            h      <= h_wrap ? 12'd0 : h + 12'd1;
            h_wrap <= (h == c_htot_m2);
            lsd    <= {lsd[6:0], h_wrap};

            // next line: v + 1 (or 0), its window events, active flag,
            // index and frame parity
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
                if (v_wrap) begin
                    run  <= run_n;
                    test <= test_n;
                    yuv  <= yuv_n;
                    full <= full_n;
                end
            end

            // request the line shown during the next line period
            if (lsd[7] && na && (v_wrap ? run_n && !test_n : run && !test)) begin
                req_line <= {npar, 3'd0, ny};
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
            y1    <= cur_y;

            // ---- stage 2: DE window and pixel index ----
            in_h2 <= in_h_n;
            de2   <= in_h_n & act1 & run1;
            x2    <= x2n;
            y2    <= y1;
            test2 <= test1;
            // underrun check: first pixel of an active line, its half's tag
            ev2   <= hs1 & c_hact_nz & act1 & run1 & ~test1;
            tsel2 <= y1[0] ? tag1 : tag0;
            ytag2 <= {par1, 3'd0, y1};

            // RAM address of the stage-2 pixel (registered together with x2,
            // data at stage 3): RGB its 16-pixel word; YUV the group's Y, U
            // and V words in the group's first three cycles
            if (!yuv)                 ram_raddr <= {y1[0], x2n[9:4]};
            else case (x2n[3:0])
                4'd1:    ram_raddr <= {y1[0], 2'b10, x2n[9:6]};
                4'd2:    ram_raddr <= {y1[0], 2'b11, x2n[9:6]};
                default: ram_raddr <= {y1[0], 1'b0, x2n[9:5]};
            endcase

            // ---- stage 3: RAM data valid ----
            de3   <= de2;
            test3 <= test2;
            lane3 <= x2[3:0];
            x3    <= x2[5:0];
            bar3  <= x2[9:7];
            ev3   <= ev2;
            tok3  <= (tsel2 == ytag2);

            // ---- stage 4: the RGB / test pixel ----
            pix4  <= test3 ? bar_rgb(bar3) : ram_rdata[lane3*16 +: 16];
            de4   <= de3;
            ur4   <= ev3 & ~tok3;
            if (ur4) underruns <= underruns + 32'd1;

            // YUV: the group's words into the holding set of its parity
            if (x3[3:0] == 4'd0) yw[x3[4]] <= ram_rdata;
            if (x3[3:0] == 4'd1) uw[x3[4]] <= ram_rdata;
            if (x3[3:0] == 4'd2) vw[x3[4]] <= ram_rdata;

            // ---- stages 5..10: delays (RGB) and the YUV conversion ----
            pix_d[0] <= pix4;
            for (k = 1; k < EXTRA; k = k + 1) pix_d[k] <= pix_d[k-1];
            de_d     <= {de_d[EXTRA-2:0], de4};
            x_d[0]   <= x3;
            for (k = 1; k < 3; k = k + 1) x_d[k] <= x_d[k-1];

            // stage 7: the pixel's samples
            y7 <= yw[set7][x7[4:0]*8 +: 8];
            u7 <= uw[set7][x7[5:1]*8 +: 8];
            v7 <= vw[set7][x7[5:1]*8 +: 8];
            // stage 8: products (DSP)
            py8  <= $signed({12'd0, y7}) * ky + ko;
            prv8 <= cv7 * krv;
            pgu8 <= cu7 * kgu;
            pgv8 <= cv7 * kgv;
            pbu8 <= cu7 * kbu;
            // stage 9: sums
            r9 <= py8 + prv8;
            g9 <= py8 - pgu8 - pgv8;
            b9 <= py8 + pbu8;
            // stage 10: clamp, pack
            pixy10 <= {rc9[7:3], gc9[7:2], bc9[7:3]};

            // ---- stage 11: panel outputs and CRC term from the stage-10 pixel ----
            lcd_de <= de_d[EXTRA-1];
            lcd_r  <= de_d[EXTRA-1] ? {pix10[15:11], pix10[15]} : 6'd0;
            lcd_g  <= de_d[EXTRA-1] ? pix10[10:5]               : 6'd0;
            lcd_b  <= de_d[EXTRA-1] ? {pix10[4:0], pix10[4]}    : 6'd0;
            de11   <= de_d[EXTRA-1];
            g11    <= crc16(32'd0, pix10);

            // ---- stage 12: CRC of what was sent; publish with the frame's
            // last position (stage 11 then holds it), so frame_tgl changes
            // before the next frame's first pixel reaches the panel ----
            fend <= {fend[3+EXTRA:0], h_wrap & v_wrap};
            if (fend[4+EXTRA]) begin
                frame_crc <= ~(de11 ? crc16(crc, 16'd0) ^ g11 : crc);
                frame_tgl <= ~frame_tgl;
                crc       <= CRC_INIT;
            end else if (de11) begin
                crc       <= crc16(crc, 16'd0) ^ g11;
            end
        end
    end
endmodule
`default_nettype wire
