`default_nettype none
//============================================================================
// rx_ring_writer.v -- RX engine, bus-clock side.
//
// Drains the RX path FIFOs (filled by rx_capture across the CDC):
//   * metadata stream: one {len,err} trailer per received frame
//   * data stream:     the frame's 32-bit words packed in pairs into 64-bit
//                      entries {w[2i+1], w[2i]} (an odd last word has an unused
//                      upper half); the trailer only appears once the whole
//                      frame is already in the data FIFO
// and DMAs each frame into a ring of fixed-size DRAM buffers via a 64-bit
// ahb_master:
//   buffer = buf_base + (rx_head & (ring_len-1)) << BUF_SHIFT
//   word0  = header {err, len}     (the CPU learns the length from this)
//   word1+ = frame data
// as one command of 64-bit beats.  The header leads, so the data is one 32-bit
// word out of step with the FIFO entries: beat 0 = {w0, header}, beat k =
// {w[2k], w[2k-1]} -- each beat takes the low half of the entry it pops and the
// high half saved from the previous one.  An odd number of 32-bit words fills
// the last beat with an unused upper half (still inside the 2 KB buffer).
// Then rx_head bumps and irq pulses.  rx_tail (CPU's consumed count) gives flow
// control: a full ring drops the frame (counted) but still drains its entries
// so the data/metadata streams stay aligned.
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
    // data stream (data CDC FIFO output): pairs of 32-bit words
    input  wire        data_valid,
    input  wire [63:0] data_word,
    output wire        data_ready,
    // ahb_master command (64-bit beats) + write-data
    output reg         cmd_valid,
    input  wire        cmd_ready,
    output reg  [31:0] cmd_addr,
    output reg  [15:0] cmd_len,
    output wire        cmd_wr,
    input  wire        cmd_done,
    input  wire        w_req,
    output wire [63:0] w_data
);
    localparam S_IDLE=3'd0, S_DATA_I=3'd1, S_DATA_W=3'd2, S_DONE=3'd3, S_DROP=3'd4;

    reg [2:0]  state;
    reg [15:0] len;
    reg        err;
    reg [31:0] dst;
    reg [15:0] nbeats;        // 64-bit beats: header + data words, rounded up
    reg [15:0] eleft;         // entries still to pop (writing or dropping)
    reg        hdr_next;      // the next beat is beat 0 (carries the header)
    reg [31:0] hi_q;          // upper word of the last popped entry

    wire [15:0] occupancy = rx_head - rx_tail;
    wire [15:0] idx       = rx_head & (ring_len - 16'd1);
    wire        ring_full = (occupancy >= ring_len);
    wire [15:0] nwords    = (meta_len + 16'd3) >> 2;      // 32-bit words of data

    assign cmd_wr     = 1'b1;                              // RX always writes
    assign w_data     = {(eleft != 16'd0) ? data_word[31:0] : 32'd0,
                         hdr_next ? {15'b0, err, len} : hi_q};
    assign data_ready = (state == S_DATA_W && w_req && eleft != 16'd0) ||
                        (state == S_DROP   && data_valid && eleft != 16'd0);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; rx_head <= 0; drop_cnt <= 0; irq <= 0;
            meta_ready <= 0; cmd_valid <= 0; cmd_addr <= 0; cmd_len <= 0;
            len <= 0; err <= 0; dst <= 0; nbeats <= 0; eleft <= 0;
            hdr_next <= 0; hi_q <= 0;
        end else begin
            irq <= 1'b0; meta_ready <= 1'b0; cmd_valid <= 1'b0;
            case (state)
                S_IDLE: if (rx_en && meta_valid) begin
                    len    <= meta_len;
                    err    <= meta_err;
                    nbeats <= (nwords + 16'd2) >> 1;
                    eleft  <= (nwords + 16'd1) >> 1;       // entries to pop
                    dst    <= buf_base + (idx << BUF_SHIFT);
                    meta_ready <= 1'b1;                    // pop the trailer
                    state  <= ring_full ? S_DROP : S_DATA_I;
                end
                S_DATA_I: begin                            // header + data @ dst
                    cmd_valid <= 1'b1; cmd_addr <= dst; cmd_len <= nbeats;
                    hdr_next  <= 1'b1;
                    state <= S_DATA_W;
                end
                S_DATA_W: begin
                    if (w_req) begin
                        hdr_next <= 1'b0;
                        if (eleft != 16'd0) begin
                            hi_q  <= data_word[63:32];
                            eleft <= eleft - 16'd1;
                        end
                    end
                    if (cmd_done) state <= S_DONE;
                end
                S_DONE: begin
                    rx_head <= rx_head + 16'd1;
                    irq     <= 1'b1;
                    state   <= S_IDLE;
                end
                S_DROP: begin                              // discard frame entries
                    if (data_valid && eleft != 16'd0) eleft <= eleft - 16'd1;
                    if (eleft == 16'd0) begin
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
