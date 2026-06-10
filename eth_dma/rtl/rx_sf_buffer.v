`default_nettype none
//============================================================================
// rx_sf_buffer.v -- RX store-and-forward staging buffer with a REWINDABLE
// write pointer.  Single clock domain (rx_mac_clk).
//
// Sits between rx_capture and the two RX CDC FIFOs.  The Gowin TSE MAC cannot
// be back-pressured, so a frame's words are written SPECULATIVELY into a RAM as
// they arrive.  A frame is COMMITTED only when it ends cleanly AND every word
// fit AND the frame-info FIFO had a free slot:
//
//   * speculative pointer `wptr`  -- advances on every stored word
//   * committed   pointer `commit`-- advances only at a clean end-of-frame
//
// If the RAM (or the info FIFO) would overflow mid-frame, the frame is ABORTED:
// `wptr` is REWOUND to `commit`, discarding the partial frame, and a whole-frame
// drop is counted.  Nothing partial is ever exposed downstream.
//
// A drain FSM emits each committed frame to the CDC FIFOs in the order the
// consumer (rx_ring_writer) requires -- ALL data words first, then the {err,len}
// metadata -- but now with full ready/valid back-pressure, so neither CDC FIFO
// can ever drop a word or a trailer independently.  This makes the data/metadata
// desynchronisation that misaligned every received frame structurally
// impossible: the sole loss point is whole-frame, at the staging input, counted
// in `drop_cnt`.
//============================================================================
module rx_sf_buffer #(
    parameter AW      = 10,          // staging RAM = 2^AW words (>= max frame)
    parameter INFO_AW = 4            // frame-info FIFO = 2^INFO_AW frames
)(
    input  wire        clk,          // rx_mac_clk
    input  wire        rstn,
    // frame stream in (from rx_capture)
    input  wire        in_word_valid,
    input  wire [31:0] in_word,
    input  wire        in_eof,       // = frame_valid (asserted with the last word)
    input  wire [15:0] in_len,       // total bytes (valid with in_eof)
    input  wire        in_err,
    // data stream out (-> data CDC FIFO input)
    output wire        data_valid,
    output wire [31:0] data_word,
    input  wire        data_ready,
    // metadata stream out (-> metadata CDC FIFO input)
    output wire        meta_valid,
    output wire [16:0] meta_word,    // {err, len}
    input  wire        meta_ready,
    // frames dropped at the staging input (whole-frame only, never mid-frame)
    output reg  [15:0] drop_cnt
);
    localparam DEPTH = (1 << AW);

    // ---- pointers (AW+1 bits: the extra MSB separates full from empty) ----
    reg  [AW:0] wptr;                 // speculative write pointer
    reg  [AW:0] commit;               // committed write boundary
    reg  [AW:0] drain;                // drain (read) pointer
    reg         abort;                // current frame cannot be stored
    wire [AW:0] occ  = wptr - drain;  // words in use (committed + speculative)
    wire        full = occ[AW];       // occ == DEPTH

    // ---- staging RAM (1W1R, single clock); registered write, registered read ----
    reg  [31:0] mem [0:DEPTH-1];
    reg  [31:0] rdata;
    reg         wr_en;  reg [AW-1:0] wr_addr;  reg [31:0] wr_data;

    // ---- frame-info FIFO ({err,len}; single clock) ----
    localparam IDEPTH = (1 << INFO_AW);
    reg  [16:0]      info [0:IDEPTH-1];
    reg  [INFO_AW:0] iwr, ird;
    wire             info_empty = (iwr == ird);
    wire             info_full  = ((iwr - ird) == IDEPTH[INFO_AW:0]);

    // ====================================================================
    // WRITE SIDE: speculative store, rewind-on-abort, commit-on-clean-EOF
    // ====================================================================
    wire        can_write  = in_word_valid && !abort && !full;
    wire [AW:0] wptr_after  = wptr + (can_write ? {{AW{1'b0}},1'b1} : {(AW+1){1'b0}});
    // bad => discard the whole frame: a word was lost, or no info slot at EOF
    wire        bad_at_eof  = abort || (in_word_valid && full) || info_full;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wptr <= 0; commit <= 0; abort <= 0; iwr <= 0; drop_cnt <= 0;
            wr_en <= 1'b0; wr_addr <= 0; wr_data <= 0;
        end else begin
            wr_en <= 1'b0;
            wptr  <= wptr_after;                         // default advance
            if (can_write) begin                         // speculative store
                wr_en   <= 1'b1;
                wr_addr <= wptr[AW-1:0];
                wr_data <= in_word;
            end
            if (in_word_valid && (full || abort))        // latch a mid-frame loss
                abort <= 1'b1;
            if (in_eof) begin
                abort <= 1'b0;                           // ready for the next frame
                if (bad_at_eof) begin
                    wptr     <= commit;                  // REWIND: drop partial frame
                    drop_cnt <= drop_cnt + 16'd1;
                end else begin
                    commit  <= wptr_after;               // COMMIT
                    info[iwr[INFO_AW-1:0]] <= {in_err, in_len};
                    iwr     <= iwr + {{INFO_AW{1'b0}},1'b1};
                end
            end
        end
    end

    // ====================================================================
    // DRAIN SIDE: per committed frame, push all data words then the metadata
    // ====================================================================
    localparam D_IDLE = 2'd0, D_READ = 2'd1, D_PUSH = 2'd2, D_META = 2'd3;
    reg  [1:0]  dstate;
    reg  [16:0] d_info;               // {err,len} of the frame being drained
    reg  [15:0] d_left;               // data words remaining
    wire [15:0] pop_len    = info[ird[INFO_AW-1:0]][15:0];
    wire [15:0] pop_nwords = (pop_len + 16'd3) >> 2;

    // Combinational read address/enable: assert in D_READ so the registered RAM
    // output `rdata` holds mem[drain] by the time we reach D_PUSH.
    wire             rd_en   = (dstate == D_READ);
    wire [AW-1:0]    rd_addr = drain[AW-1:0];
    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        if (rd_en) rdata        <= mem[rd_addr];
    end

    assign data_valid = (dstate == D_PUSH);
    assign data_word  = rdata;
    assign meta_valid = (dstate == D_META);
    assign meta_word  = d_info;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dstate <= D_IDLE; drain <= 0; ird <= 0; d_left <= 0; d_info <= 0;
        end else begin
            case (dstate)
                D_IDLE: if (!info_empty) begin
                    d_info <= info[ird[INFO_AW-1:0]];
                    d_left <= pop_nwords;
                    ird    <= ird + {{INFO_AW{1'b0}},1'b1};
                    dstate <= (pop_nwords == 16'd0) ? D_META : D_READ;
                end
                D_READ: dstate <= D_PUSH;                // rd_en asserted -> rdata next cycle
                D_PUSH: if (data_ready) begin            // word accepted by CDC FIFO
                    drain  <= drain + {{AW{1'b0}},1'b1};
                    d_left <= d_left - 16'd1;
                    dstate <= (d_left == 16'd1) ? D_META : D_READ;
                end
                D_META: if (meta_ready) dstate <= D_IDLE;
                default: dstate <= D_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
