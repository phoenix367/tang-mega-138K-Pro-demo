`default_nettype none
//============================================================================
// rx_ring_writer.v -- RX engine, bus-clock side.
//
// Drains the RX path FIFOs (filled by rx_capture across the CDC):
//   * metadata stream: one {len,err} trailer per received frame
//   * data stream:     the frame's 32-bit words (the trailer only appears once
//                      the whole frame is already in the data FIFO)
// and DMAs each frame into a ring of fixed-size DRAM buffers via ahb_master:
//   buffer = buf_base + (rx_head & (ring_len-1)) << BUF_SHIFT
//   word0  = header {err, len}     (the CPU learns the length from this)
//   word1+ = frame data
// then bumps rx_head and pulses irq.  rx_tail (CPU's consumed count) gives flow
// control: a full ring drops the frame (counted) but still drains its words so
// the data/metadata streams stay aligned.
//
// FIFO ports use the FPGADesignElements ready/valid convention.
//============================================================================
module rx_ring_writer #(
    parameter BUF_SHIFT = 11          // 2^11 = 2 KB per buffer
)(
    input  wire        clk,
    input  wire        rstn,
    // configuration (CSRs)
    input  wire        rx_en,
    input  wire [31:0] buf_base,
    input  wire [15:0] ring_len,      // power of two
    input  wire [15:0] rx_tail,       // frames consumed by the CPU
    output reg  [15:0] rx_head,       // frames written by the DMA
    output reg  [15:0] drop_cnt,
    output reg         irq,           // 1-cycle pulse per completed frame
    // metadata stream (metadata CDC FIFO output)
    input  wire        meta_valid,
    input  wire [15:0] meta_len,
    input  wire        meta_err,
    output reg         meta_ready,
    // data word stream (data CDC FIFO output)
    input  wire        data_valid,
    input  wire [31:0] data_word,
    output wire        data_ready,
    // ahb_master command + write-data
    output reg         cmd_valid,
    input  wire        cmd_ready,
    output reg  [31:0] cmd_addr,
    output reg  [15:0] cmd_len,
    output wire        cmd_wr,
    input  wire        cmd_done,
    input  wire        w_req,
    output wire [31:0] w_data
);
    localparam S_IDLE=3'd0, S_STAT_I=3'd1, S_STAT_W=3'd2,
               S_DATA_I=3'd3, S_DATA_W=3'd4, S_DONE=3'd5, S_DROP=3'd6;

    reg [2:0]  state;
    reg [15:0] len;
    reg        err;
    reg [31:0] dst;
    reg [15:0] nwords;
    reg [15:0] dropn;

    wire [15:0] occupancy = rx_head - rx_tail;
    wire        ring_full = (occupancy >= ring_len);
    wire [15:0] idx       = rx_head & (ring_len - 16'd1);

    assign cmd_wr     = 1'b1;                              // RX always writes
    assign w_data     = (state == S_DATA_W) ? data_word : {15'b0, err, len};
    assign data_ready = (state == S_DATA_W && w_req) ||
                        (state == S_DROP   && data_valid && (dropn != nwords));

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; rx_head <= 0; drop_cnt <= 0; irq <= 0;
            meta_ready <= 0; cmd_valid <= 0; cmd_addr <= 0; cmd_len <= 0;
            len <= 0; err <= 0; dst <= 0; nwords <= 0; dropn <= 0;
        end else begin
            irq <= 1'b0; meta_ready <= 1'b0; cmd_valid <= 1'b0;
            case (state)
                S_IDLE: if (rx_en && meta_valid) begin
                    len    <= meta_len;
                    err    <= meta_err;
                    nwords <= (meta_len + 16'd3) >> 2;
                    dst    <= buf_base + (idx << BUF_SHIFT);
                    meta_ready <= 1'b1;                    // pop the trailer
                    dropn  <= 16'd0;
                    state  <= ring_full ? S_DROP : S_STAT_I;
                end
                S_STAT_I: begin                            // header write @ dst
                    cmd_valid <= 1'b1; cmd_addr <= dst; cmd_len <= 16'd1;
                    state <= S_STAT_W;
                end
                S_STAT_W: if (cmd_done) state <= S_DATA_I;
                S_DATA_I: begin                            // data write @ dst+4
                    cmd_valid <= 1'b1; cmd_addr <= dst + 32'd4; cmd_len <= nwords;
                    state <= S_DATA_W;
                end
                S_DATA_W: if (cmd_done) state <= S_DONE;
                S_DONE: begin
                    rx_head <= rx_head + 16'd1;
                    irq     <= 1'b1;
                    state   <= S_IDLE;
                end
                S_DROP: begin                              // discard frame words
                    if (data_valid && dropn != nwords) dropn <= dropn + 16'd1;
                    if (dropn == nwords) begin
                        drop_cnt <= drop_cnt + 16'd1;
                        state    <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
