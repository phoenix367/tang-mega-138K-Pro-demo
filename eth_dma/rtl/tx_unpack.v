`default_nettype none
//============================================================================
// tx_unpack.v -- TX engine, MAC-clock side (tx_mac_clk domain).
//
// Reverse of rx_capture: reads a frame's length (metadata FIFO) and its 32-bit
// words (data FIFO), unpacks each word little-endian into 4 bytes, and streams
// them to the Gowin TSE tx_mac interface (valid/data/last, honoring tx_mac_ready
// back-pressure).  Pulses frame_done when the last byte is accepted.
//
// Ethernet forbids mid-frame gaps, so we only START once `meta_valid` is set --
// the bus side pushes the metadata token AFTER all the frame's data words, and
// with equal CDC pointer-sync latency that guarantees the whole frame has
// already crossed into the data FIFO.  No underrun.
//============================================================================
module tx_unpack (
    input  wire        tx_mac_clk,
    input  wire        rstn,
    // metadata (metadata CDC FIFO output): one {len} per frame
    input  wire        meta_valid,
    input  wire [15:0] meta_len,
    output reg         meta_ready,
    // data words (data CDC FIFO output)
    input  wire        data_valid,
    input  wire [31:0] data_word,
    output wire        data_ready,
    // tx_mac stream
    output wire        tx_mac_valid,
    output wire [7:0]  tx_mac_data,
    output wire        tx_mac_last,
    input  wire        tx_mac_ready,
    // completion
    output reg         frame_done
);
    localparam S_IDLE=2'd0, S_SEND=2'd1, S_DONE=2'd2;
    reg [1:0]  state;
    reg [15:0] len, byte_cnt;

    wire last_byte = (byte_cnt == len - 16'd1);

    assign tx_mac_valid = (state == S_SEND) && data_valid;
    assign tx_mac_data  = data_word[byte_cnt[1:0]*8 +: 8];
    assign tx_mac_last  = (state == S_SEND) && last_byte;
    // pop a word when its 4th byte is sent, or on the final (possibly partial) word
    assign data_ready   = tx_mac_valid && tx_mac_ready && (byte_cnt[1:0] == 2'd3 || last_byte);

    always @(posedge tx_mac_clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; len <= 0; byte_cnt <= 0;
            meta_ready <= 0; frame_done <= 0;
        end else begin
            meta_ready <= 1'b0; frame_done <= 1'b0;
            case (state)
                S_IDLE: if (meta_valid && data_valid) begin
                    len <= meta_len; byte_cnt <= 0;
                    meta_ready <= 1'b1;
                    state <= S_SEND;
                end
                S_SEND: if (tx_mac_valid && tx_mac_ready) begin
                    if (last_byte) state <= S_DONE;
                    else           byte_cnt <= byte_cnt + 16'd1;
                end
                S_DONE: begin frame_done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
