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
//
// Timing (125 MHz): tx_mac_valid/data/last come straight from registers -- a
// 2-entry skid buffer (main + skid) -- so no FIFO-RAM read, byte select or
// length compare reaches the MAC's TX state machine / CRC in the same cycle.
// The skid entry keeps one byte per cycle across tx_mac_ready stalls, so the
// MAC still sees a gap-free frame.  `last_byte` is a registered flag, not a
// 16-bit `byte_cnt == len - 1` compare.
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
    reg        last_byte;          // byte_cnt == len - 1

    // ---- output register stage (main m_*, skid s_*) ----
    reg        m_valid, m_last, s_valid, s_last;
    reg [7:0]  m_data, s_data;
    assign tx_mac_valid = m_valid;
    assign tx_mac_data  = m_data;
    assign tx_mac_last  = m_last;
    wire m_load = !m_valid || tx_mac_ready;      // main register takes a new byte

    // ---- byte stream into the output stage ----
    wire       u_valid = (state == S_SEND) && data_valid;
    wire [7:0] u_data  = data_word[byte_cnt[1:0]*8 +: 8];
    wire       u_fire  = u_valid && !s_valid;    // accepted while the skid is empty
    // pop a word when its 4th byte is sent, or on the final (possibly partial) word
    assign data_ready  = u_fire && (byte_cnt[1:0] == 2'd3 || last_byte);

    always @(posedge tx_mac_clk or negedge rstn) begin
        if (!rstn) begin
            m_valid <= 1'b0; m_last <= 1'b0; m_data <= 8'd0;
            s_valid <= 1'b0; s_last <= 1'b0; s_data <= 8'd0;
        end else if (m_load) begin
            if (s_valid) begin                   // drain the skid first
                m_valid <= 1'b1; m_data <= s_data; m_last <= s_last; s_valid <= 1'b0;
            end else begin
                m_valid <= u_fire; m_data <= u_data; m_last <= last_byte;
            end
        end else if (u_fire) begin               // main stalled: park in the skid
            s_valid <= 1'b1; s_data <= u_data; s_last <= last_byte;
        end
    end

    always @(posedge tx_mac_clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; len <= 0; byte_cnt <= 0; last_byte <= 1'b0;
            meta_ready <= 0; frame_done <= 0;
        end else begin
            meta_ready <= 1'b0; frame_done <= 1'b0;
            case (state)
                S_IDLE: if (meta_valid && data_valid) begin
                    len <= meta_len; byte_cnt <= 0;
                    last_byte <= (meta_len == 16'd1);
                    meta_ready <= 1'b1;
                    state <= S_SEND;
                end
                S_SEND: if (u_fire) begin
                    if (last_byte) state <= S_DONE;
                    else begin
                        byte_cnt  <= byte_cnt + 16'd1;
                        last_byte <= (byte_cnt + 16'd2 == len);
                    end
                end
                // wait until the MAC has taken the last byte from the output stage
                S_DONE: if (m_valid && tx_mac_ready && m_last) begin
                    frame_done <= 1'b1; state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
