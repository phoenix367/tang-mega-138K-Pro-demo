`default_nettype none
//============================================================================
// idct_1d.v -- pipelined 8-point 1-D inverse DCT, the integer algorithm of
// FFmpeg's libavcodec/simple_idct_template.c (IN_IDCT_DEPTH 16, BIT_DEPTH 8),
// so that hardware and software decode bit-exactly the same picture:
//
//   a0 = W4 x0 + W2 x2 + W4 x4 + W6 x6 + rnd   b0 = W1 x1 + W3 x3 + W5 x5 + W7 x7
//   a1 = W4 x0 + W6 x2 - W4 x4 - W2 x6 + rnd   b1 = W3 x1 - W7 x3 - W1 x5 - W5 x7
//   a2 = W4 x0 - W6 x2 - W4 x4 + W2 x6 + rnd   b2 = W5 x1 - W1 x3 + W7 x5 + W3 x7
//   a3 = W4 x0 - W2 x2 + W4 x4 - W6 x6 + rnd   b3 = W7 x1 - W5 x3 + W3 x5 - W1 x7
//   y0..3 = (a0..3 + b0..3) >> s,  y7..4 = (a0..3 - b0..3) >> s
//
// Row pass (col = 0): s = 11, rnd = 1 << 10, results kept as 16 bits; a row
// whose x1..x7 are all zero yields x0 << 3 in every position (FFmpeg's DC
// shortcut, which is not the same value as the full formula).  Column pass
// (col = 1): s = 20, rnd = W4 * 32, results clamped to 0..255.
// One transform per cycle, latency 4 (22 multipliers, 16 x 16 signed).
//============================================================================
module idct_1d (
    input  wire               clk,
    input  wire               rstn,
    input  wire               in_valid,
    input  wire               in_col,                 // 0 = row pass, 1 = column pass
    input  wire signed [15:0] x0, x1, x2, x3, x4, x5, x6, x7,
    output reg                out_valid,
    output reg                out_col,
    output reg  [15:0]        y0, y1, y2, y3, y4, y5, y6, y7
);
    localparam signed [15:0] W1 = 16'sd22725, W2 = 16'sd21407, W3 = 16'sd19266, W4 = 16'sd16383,
                             W5 = 16'sd12873, W6 = 16'sd8867,  W7 = 16'sd4520;
    localparam signed [31:0] RND_ROW = 32'sd1024;
    localparam signed [31:0] RND_COL = 32'sd524256;    // W4 * ((1 << 19) / W4)

    // stage 1: products (DSP), the DC-shortcut flag, x0 for it
    reg         v1, c1, dc1;
    reg  [15:0] x0_1;
    reg signed [31:0] p40, p44, p22, p62, p66, p26;            // even part
    reg signed [31:0] p11, p31, p51, p71, p33, p73, p13, p53;  // odd part
    reg signed [31:0] p55, p15, p75, p35, p77, p57, p37, p17;
    // stage 2: sums
    reg         v2, c2, dc2;
    reg  [15:0] x0_2;
    reg signed [31:0] a0, a1, a2, a3, b0, b1, b2, b3;
    // stage 3: outputs before shift
    reg         v3, c3, dc3;
    reg  [15:0] x0_3;
    reg signed [31:0] s0, s1, s2, s3, s4, s5, s6, s7;

    function [15:0] fin(input signed [31:0] v, input col, input dc, input [15:0] x0dc);
        reg signed [31:0] sh;
        begin
            if (col) begin
                sh = v >>> 20;
                fin = (sh < 0) ? 16'd0 : (sh > 255) ? 16'd255 : sh[15:0];
            end else if (dc) begin
                fin = x0dc << 3;
            end else begin
                sh = v >>> 11;
                fin = sh[15:0];
            end
        end
    endfunction

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            v1 <= 0; c1 <= 0; dc1 <= 0; x0_1 <= 0;
            p40 <= 0; p44 <= 0; p22 <= 0; p62 <= 0; p66 <= 0; p26 <= 0;
            p11 <= 0; p31 <= 0; p51 <= 0; p71 <= 0; p33 <= 0; p73 <= 0; p13 <= 0; p53 <= 0;
            p55 <= 0; p15 <= 0; p75 <= 0; p35 <= 0; p77 <= 0; p57 <= 0; p37 <= 0; p17 <= 0;
            v2 <= 0; c2 <= 0; dc2 <= 0; x0_2 <= 0;
            a0 <= 0; a1 <= 0; a2 <= 0; a3 <= 0; b0 <= 0; b1 <= 0; b2 <= 0; b3 <= 0;
            v3 <= 0; c3 <= 0; dc3 <= 0; x0_3 <= 0;
            s0 <= 0; s1 <= 0; s2 <= 0; s3 <= 0; s4 <= 0; s5 <= 0; s6 <= 0; s7 <= 0;
            out_valid <= 0; out_col <= 0;
            y0 <= 0; y1 <= 0; y2 <= 0; y3 <= 0; y4 <= 0; y5 <= 0; y6 <= 0; y7 <= 0;
        end else begin
            // ---- stage 1 ----
            v1   <= in_valid;
            c1   <= in_col;
            dc1  <= !in_col && (x1 == 0) && (x2 == 0) && (x3 == 0) && (x4 == 0) && (x5 == 0) && (x6 == 0) && (x7 == 0);
            x0_1 <= x0;
            p40 <= W4 * x0; p44 <= W4 * x4; p22 <= W2 * x2; p62 <= W6 * x2; p66 <= W6 * x6; p26 <= W2 * x6;
            p11 <= W1 * x1; p31 <= W3 * x1; p51 <= W5 * x1; p71 <= W7 * x1;
            p33 <= W3 * x3; p73 <= W7 * x3; p13 <= W1 * x3; p53 <= W5 * x3;
            p55 <= W5 * x5; p15 <= W1 * x5; p75 <= W7 * x5; p35 <= W3 * x5;
            p77 <= W7 * x7; p57 <= W5 * x7; p37 <= W3 * x7; p17 <= W1 * x7;
            // ---- stage 2 ----
            v2 <= v1; c2 <= c1; dc2 <= dc1; x0_2 <= x0_1;
            a0 <= p40 + p22 + p44 + p66 + (c1 ? RND_COL : RND_ROW);
            a1 <= p40 + p62 - p44 - p26 + (c1 ? RND_COL : RND_ROW);
            a2 <= p40 - p62 - p44 + p26 + (c1 ? RND_COL : RND_ROW);
            a3 <= p40 - p22 + p44 - p66 + (c1 ? RND_COL : RND_ROW);
            b0 <= p11 + p33 + p55 + p77;
            b1 <= p31 - p73 - p15 - p57;
            b2 <= p51 - p13 + p75 + p37;
            b3 <= p71 - p53 + p35 - p17;
            // ---- stage 3 ----
            v3 <= v2; c3 <= c2; dc3 <= dc2; x0_3 <= x0_2;
            s0 <= a0 + b0; s1 <= a1 + b1; s2 <= a2 + b2; s3 <= a3 + b3;
            s4 <= a3 - b3; s5 <= a2 - b2; s6 <= a1 - b1; s7 <= a0 - b0;
            // ---- stage 4: shift / shortcut / clamp ----
            out_valid <= v3;
            out_col   <= c3;
            y0 <= fin(s0, c3, dc3, x0_3); y1 <= fin(s1, c3, dc3, x0_3);
            y2 <= fin(s2, c3, dc3, x0_3); y3 <= fin(s3, c3, dc3, x0_3);
            y4 <= fin(s4, c3, dc3, x0_3); y5 <= fin(s5, c3, dc3, x0_3);
            y6 <= fin(s6, c3, dc3, x0_3); y7 <= fin(s7, c3, dc3, x0_3);
        end
    end
endmodule
`default_nettype wire
