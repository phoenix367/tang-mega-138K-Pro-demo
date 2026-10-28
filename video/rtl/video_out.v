`default_nettype none
//============================================================================
// video_out.v -- pixel-clock side of the LCD video core.
//
// Timing generator for a DE-mode RGB panel: counters h (0..htotal-1) and
// v (0..vtotal-1); DE is high for h in [hstart, hstart+hactive) on lines
// v in [vstart, vstart+vactive).  Enable / test changes take effect at the
// start of a frame.
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
// Pixels: line RAM (128-bit words = 8 RGB565 pixels) read with one cycle of
// latency; RGB565 is expanded to the panel's RGB666 (5-bit channels repeat
// their MSB).  Outputs are registered.  A zlib CRC-32 of each frame's active
// pixels (as RGB565, little-endian) is kept for checking the picture against
// the framebuffer; frame_tgl toggles when a frame (and its CRC / underrun
// count) completes.
//
// Logic depth: no arithmetic feeds a compare in the same cycle.  The timing
// values are copied into the pixel clock with their derived constants
// (hstart+hactive, htotal-2, ...), every timing event is a registered 12-bit
// equality compare against one of them, and window flags / pixel index / line
// index are set, cleared and counted by those events.  The next line's state
// (active, index, frame parity) is worked out in a short pipeline while the
// current line runs -- v changes once a line -- and loaded at the line wrap.
// The pixel path is staged (RAM -> lane select -> CRC data term -> CRC state),
// the CRC split as crc16(c, d) = F(c) ^ G(d).  Counters are 12 bits: totals
// up to 4095, and htotal must be at least 16.
//============================================================================
module video_out (
    input  wire        pclk,
    input  wire        prstn,         // synchronous to pclk, active low
    // configuration (bus clock; enable/test are synchronised here, the
    // timing values are static while scan-out runs)
    input  wire        cfg_enable,
    input  wire        cfg_test,
    input  wire [15:0] hactive, htotal, hstart,
    input  wire [15:0] vactive, vtotal, vstart,
    // line-fetch handshake with video_fetch (DDR clock)
    output reg         req_tgl,
    output reg  [15:0] req_line,      // {frame parity, index}, held until the next request
    input  wire        done_tgl,      // asynchronous
    input  wire [15:0] done_line,     // a req_line value, stable when done_tgl toggles
    // line RAM read port
    output wire [7:0]   ram_raddr,
    input  wire [127:0] ram_rdata,
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

    function [15:0] bar_rgb(input [2:0] b);     // white yellow cyan green magenta red blue black
        case (b)
            3'd0: bar_rgb = 16'hFFFF;  3'd1: bar_rgb = 16'hFFE0;
            3'd2: bar_rgb = 16'h07FF;  3'd3: bar_rgb = 16'h07E0;
            3'd4: bar_rgb = 16'hF81F;  3'd5: bar_rgb = 16'hF800;
            3'd6: bar_rgb = 16'h001F;  default: bar_rgb = 16'h0000;
        endcase
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

    // ---- enable / test: synchronised, applied at the frame wrap ----
    reg [1:0] en_s, test_s;
    always @(posedge pclk) begin
        en_s   <= {en_s[0], cfg_enable};
        test_s <= {test_s[0], cfg_test};
    end

    // Stage naming: a "...N" register holds information about the counter
    // position N cycles ago, so signals with the same N belong together.
    // stage 0: counters and the state of the current line
    reg  [11:0] h, v, cur_y;
    reg         h_wrap;                 // h == htotal-1
    reg         cur_act, fpar, run, test;
    reg         run_n, test_n;          // next frame's, decided early in its last line
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
    reg  [2:0]  lane3, bar3;
    // stages 4..6: pixel, CRC data term, CRC state
    reg         de4, de5, ur4;
    reg  [15:0] pix4;
    reg  [31:0] g5, crc;
    reg  [4:0]  fend;                   // fend[k]: the frame's last position, k+1 cycles ago

    // ---- fetch completion from the DDR clock ----
    reg  [2:0]  done_s;
    reg  [15:0] tag0, tag1;             // request held by each RAM half
    wire        done_edge = done_s[2] ^ done_s[1];

    assign ram_raddr = {y2[0], x2[9:3]};

    wire        in_h_n = (hs1 & c_hact_nz) | (in_h2 & ~he1 & ~hz1);

    always @(posedge pclk) begin
        if (!prstn) begin
            h <= 0; v <= 0; cur_y <= 0; h_wrap <= 0; cur_act <= 0; fpar <= 0; run <= 0; test <= 0;
            run_n <= 0; test_n <= 0;
            v_wrap <= 0; vp1 <= 0; yp1 <= 0; vn <= 0; ny <= 0;
            vn_s <= 0; vn_e <= 0; vn_0 <= 0; na <= 0; npar <= 0; lsd <= 0;
            hs1 <= 0; he1 <= 0; hz1 <= 0; act1 <= 0; par1 <= 0; run1 <= 0; test1 <= 0; y1 <= 0;
            in_h2 <= 0; de2 <= 0; test2 <= 0; ev2 <= 0; x2 <= 0; y2 <= 0; tsel2 <= 0; ytag2 <= 0;
            de3 <= 0; test3 <= 0; ev3 <= 0; tok3 <= 0; lane3 <= 0; bar3 <= 0;
            de4 <= 0; de5 <= 0; ur4 <= 0; pix4 <= 0; g5 <= 0; crc <= CRC_INIT; fend <= 0;
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

            // enable / test for the next frame are sampled early in this
            // frame's last line, so that line already requests the next
            // frame's first line (vstart = 0) by the new mode
            if (lsd[6] && v_wrap) begin
                run_n  <= en_s[1] | test_s[1];
                test_n <= test_s[1];
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
            x2    <= de2 ? x2 + 10'd1 : 10'd0;
            y2    <= y1;
            test2 <= test1;
            // underrun check: first pixel of an active line, its half's tag
            ev2   <= hs1 & c_hact_nz & act1 & run1 & ~test1;
            tsel2 <= y1[0] ? tag1 : tag0;
            ytag2 <= {par1, 3'd0, y1};

            // ---- stage 3: RAM data valid ----
            de3   <= de2;
            test3 <= test2;
            lane3 <= x2[2:0];
            bar3  <= x2[9:7];
            ev3   <= ev2;
            tok3  <= (tsel2 == ytag2);

            // ---- stage 4: the pixel ----
            pix4  <= test3 ? bar_rgb(bar3) : ram_rdata[lane3*16 +: 16];
            de4   <= de3;
            ur4   <= ev3 & ~tok3;
            if (ur4) underruns <= underruns + 32'd1;

            // ---- stage 5: registered panel outputs, CRC data term ----
            lcd_de <= de4;
            lcd_r  <= de4 ? {pix4[15:11], pix4[15]} : 6'd0;
            lcd_g  <= de4 ? pix4[10:5]              : 6'd0;
            lcd_b  <= de4 ? {pix4[4:0], pix4[4]}    : 6'd0;
            de5    <= de4;
            g5     <= crc16(32'd0, pix4);

            // ---- stage 6: CRC of what was sent; publish with the frame's
            // last position (stage 5 then holds it), so frame_tgl changes
            // before the next frame's first pixel reaches the panel ----
            fend <= {fend[3:0], h_wrap & v_wrap};
            if (fend[4]) begin
                frame_crc <= ~(de5 ? crc16(crc, 16'd0) ^ g5 : crc);
                frame_tgl <= ~frame_tgl;
                crc       <= CRC_INIT;
            end else if (de5) begin
                crc       <= crc16(crc, 16'd0) ^ g5;
            end
        end
    end
endmodule
`default_nettype wire
