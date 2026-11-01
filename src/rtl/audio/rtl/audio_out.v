`default_nettype none
//============================================================================
// audio_out.v -- bit clock NCO + PT8211 serialiser + frame CRC/counters.
// Everything runs on the bus clock (50 MHz); BCK/WS/DIN are registered
// outputs of it.
//
// Bit clock.  A 32-bit phase accumulator advances by RATE every clock; its
// MSB is BCK (average frequency RATE / 2^32 * clk, duty 50 % to within one
// clock).  At each BCK falling edge the serialiser advances one bit, so DIN
// and WS change together with BCK's falling edge and the DAC, which latches
// DIN on the rising edge, sees them half a BCK period early.
//
// Frame format (as the Sipeed audio_music example for this board, which the
// PT8211's LSB-justified "Japanese" 16-bit format accepts): 32 BCK per
// stereo frame; WS low for bits 0..15 = left MSB..LSB, WS high for bits
// 16..31 = right MSB..LSB.  The DAC takes the 16 bits clocked before each WS
// transition as that channel's sample.
//
// A frame is taken from the FIFO (pop) at bit 0 when enable is set and a
// frame is available; otherwise zeros go out, counted in UNDERRUN while
// enabled -- unless stop_empty is set, in which case enable is cleared
// instead (end of a stream).  FRAMES counts popped frames and CRC runs over their bytes in
// memory order (L lo, L hi, R lo, R hi): zlib CRC-32, bit-exact against the
// WAV data chunk the CPU played.
//============================================================================
module audio_out (
    input  wire        clk,
    input  wire        rstn,
    input  wire        enable,
    input  wire        lr_swap,
    input  wire        stop_empty,
    output reg         enable_clr,     // one-cycle pulse: FIFO empty at a frame start with stop_empty
    input  wire [31:0] rate,
    input  wire        clear,          // FIFO reset: counters and CRC
    // next frame from the FIFO: {R, L}
    input  wire        head_valid,
    input  wire [31:0] head,
    output reg         pop,            // one-cycle pulse: head consumed
    // statistics
    output reg  [31:0] frames,
    output reg  [31:0] underruns,
    output wire [31:0] crc,
    // DAC
    output reg         bck,
    output reg         ws,
    output reg         din
);
    // zlib CRC-32 (reflected 0xEDB88320) over 16 bits, low byte first
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

    // NCO: bck follows acc[31] one clock later; fall = the clock in which
    // bck is 1 and acc[31] already 0, so bck, ws and din update together.
    reg  [31:0] acc;
    wire        fall = bck & ~acc[31];

    reg  [4:0]  bit_idx;                // bit currently on DIN
    wire [4:0]  nxt = bit_idx + 5'd1;
    reg  [31:0] sr;                     // bits still to send, next at [31]
    wire [31:0] word = lr_swap ? {head[31:16], head[15:0]} : {head[15:0], head[31:16]};  // L first
    wire        take = enable & head_valid;

    reg  [31:0] crc_r;
    reg  [15:0] crc_l, crc_h;
    reg  [1:0]  crc_step;
    assign crc = ~crc_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            acc <= 0; bck <= 0; ws <= 0; din <= 0; bit_idx <= 0; sr <= 0;
            pop <= 0; enable_clr <= 0; frames <= 0; underruns <= 0;
            crc_r <= 32'hFFFFFFFF; crc_l <= 0; crc_h <= 0; crc_step <= 0;
        end else begin
            acc <= acc + rate;
            bck <= acc[31];
            pop <= 1'b0;
            enable_clr <= 1'b0;
            crc_step <= {crc_step[0], 1'b0};
            if (fall) begin
                bit_idx <= nxt;
                ws      <= nxt[4];
                if (nxt == 5'd0) begin
                    if (take) begin
                        din <= word[31];
                        sr  <= {word[30:0], 1'b0};
                        pop <= 1'b1;
                        frames <= frames + 1;
                        crc_l <= head[15:0];
                        crc_h <= head[31:16];
                        crc_step <= 2'b01;
                    end else begin
                        din <= 1'b0;
                        sr  <= 32'd0;
                        if (enable && stop_empty) enable_clr <= 1'b1;
                        else if (enable) underruns <= underruns + 1;
                    end
                end else begin
                    din <= sr[31];
                    sr  <= {sr[30:0], 1'b0};
                end
            end
            // CRC: one 16-bit half per clock, well before the next pop
            if (crc_step[0]) crc_r <= crc16(crc_r, crc_l);
            if (crc_step[1]) crc_r <= crc16(crc_r, crc_h);
            if (clear) begin
                frames <= 0; underruns <= 0; crc_r <= 32'hFFFFFFFF; crc_step <= 0;
            end
        end
    end
endmodule
`default_nettype wire
