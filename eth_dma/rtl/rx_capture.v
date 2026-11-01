`default_nettype none
//============================================================================
// rx_capture.v -- RX engine, MAC-clock side (rx_mac_clk domain).
//
// Consumes the Gowin TSE byte stream (rx_mac_valid/data/last/error -- the MAC
// has NO buffer, so we must accept every valid cycle) and packs it little-endian
// into 32-bit words for the RX CDC FIFO.  Emits one word per 4 bytes and a final
// (possibly partial) word at end-of-frame.  At end-of-frame it also emits a
// one-cycle frame trailer with the byte length and error flag (rx_mac_error is
// only meaningful on rx_mac_last per IPUG538).
//
// Downstream (bus side) reads `frame_len` bytes => ceil(len/4) words from the
// data FIFO and DMAs them to the RX ring buffer.  The trailer goes through a
// separate small metadata FIFO (one entry per frame).
//============================================================================
module rx_capture (
    input  wire        rx_mac_clk,
    input  wire        rstn,            // active-low, sync to rx_mac_clk
    // MAC RX stream
    input  wire        rx_mac_valid,
    input  wire [7:0]  rx_mac_data,
    input  wire        rx_mac_last,
    input  wire        rx_mac_error,
    // packed word output (-> data CDC FIFO input)
    output reg         word_valid,
    output reg [31:0]  word_data,
    // per-frame trailer (-> metadata CDC FIFO input)
    output reg         frame_valid,
    output reg [15:0]  frame_len,       // total bytes in the frame
    output reg         frame_err
);
    reg [1:0]  bidx;        // byte position within the word being assembled
    reg [31:0] wacc;        // word accumulator
    reg [15:0] bcnt;        // byte count this frame

    // place the incoming byte at lane `bidx`
    reg [31:0] wnext;
    always @(*) begin
        wnext = wacc;
        wnext[bidx*8 +: 8] = rx_mac_data;
    end

    always @(posedge rx_mac_clk or negedge rstn) begin
        if (!rstn) begin
            bidx <= 2'd0; wacc <= 32'd0; bcnt <= 16'd0;
            word_valid <= 1'b0; word_data <= 32'd0;
            frame_valid <= 1'b0; frame_len <= 16'd0; frame_err <= 1'b0;
        end else begin
            word_valid  <= 1'b0;       // defaults (pulses)
            frame_valid <= 1'b0;
            if (rx_mac_valid) begin
                wacc <= wnext;
                bcnt <= bcnt + 16'd1;
                if (bidx == 2'd3 || rx_mac_last) begin
                    word_valid <= 1'b1;     // emit a (full or final partial) word
                    word_data  <= wnext;
                    bidx       <= 2'd0;
                end else begin
                    bidx <= bidx + 2'd1;
                end
                if (rx_mac_last) begin      // end of frame: emit trailer + reset
                    frame_valid <= 1'b1;
                    frame_len   <= bcnt + 16'd1;
                    frame_err   <= rx_mac_error;
                    bcnt <= 16'd0;
                    bidx <= 2'd0;
                    wacc <= 32'd0;
                end
            end
        end
    end
endmodule
`default_nettype wire
