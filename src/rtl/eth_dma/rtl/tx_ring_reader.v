`default_nettype none
//============================================================================
// tx_ring_reader.v -- TX engine, bus-clock side.
//
// Reverse of rx_ring_writer.  When a frame is queued (tx_fetch != tx_tail) and
// the previous one has fully transmitted (tx_fetch == tx_head -- serial v1), it
// reads that frame from its TX ring buffer via ahb_master:
//   buffer = buf_base + (tx_fetch & (ring_len-1)) << BUF_SHIFT
//   word0  = header {len}     (read first to learn the length)
//   word1+ = frame data       (read into the data CDC FIFO)
// then pushes the len token into the metadata CDC FIFO (AFTER all data, so the
// MAC side never underruns) and bumps tx_fetch.
//
// Serial operation means the data/metadata FIFOs are empty when a fetch starts,
// so no overflow check is needed (the deep data FIFO holds one MTU).
//============================================================================
module tx_ring_reader #(
    parameter BUF_SHIFT = 11
)(
    input  wire        clk,
    input  wire        rstn,
    // configuration (CSRs)
    input  wire        tx_en,
    input  wire [31:0] buf_base,
    input  wire [15:0] ring_len,      // power of two
    input  wire [15:0] tx_tail,       // frames queued by the CPU
    output reg  [15:0] tx_fetch,      // frames fetched into the FIFOs
    input  wire [15:0] tx_head,       // frames transmitted (completion)
    // ahb_master read command + read data
    output reg         cmd_valid,
    input  wire        cmd_ready,
    output reg  [31:0] cmd_addr,
    output reg  [15:0] cmd_len,
    output wire        cmd_wr,
    input  wire        cmd_done,
    input  wire        r_valid,
    input  wire [31:0] r_data,
    // data FIFO input (bus side)
    output wire        data_in_valid,
    output wire [31:0] data_in_data,
    // metadata FIFO input (bus side)
    output reg         meta_in_valid,
    output wire [15:0] meta_in_data
);
    localparam S_IDLE=3'd0, S_HDR_I=3'd1, S_HDR_W=3'd2,
               S_DAT_I=3'd3, S_DAT_W=3'd4, S_META=3'd5, S_DONE=3'd6;

    reg [2:0]  state;
    reg [31:0] src;
    reg [15:0] len, nwords;

    assign cmd_wr        = 1'b0;                       // TX reads memory
    assign data_in_valid = (state == S_DAT_W) && r_valid;
    assign data_in_data  = r_data;
    assign meta_in_data  = len;

    wire [15:0] idx = tx_fetch & (ring_len - 16'd1);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; tx_fetch <= 0; cmd_valid <= 0; cmd_addr <= 0;
            cmd_len <= 0; src <= 0; len <= 0; nwords <= 0; meta_in_valid <= 0;
        end else begin
            cmd_valid <= 1'b0;
            case (state)
                S_IDLE: if (tx_en && (tx_fetch != tx_tail) && (tx_fetch == tx_head)) begin
                    src   <= buf_base + (idx << BUF_SHIFT);
                    state <= S_HDR_I;
                end
                S_HDR_I: begin                          // read header word
                    cmd_valid <= 1'b1; cmd_addr <= src; cmd_len <= 16'd1;
                    state <= S_HDR_W;
                end
                S_HDR_W: begin
                    if (r_valid) begin
                        len    <= r_data[15:0];
                        nwords <= (r_data[15:0] + 16'd3) >> 2;
                    end
                    if (cmd_done) state <= S_DAT_I;
                end
                S_DAT_I: begin                          // read data words
                    cmd_valid <= 1'b1; cmd_addr <= src + 32'd4; cmd_len <= nwords;
                    state <= S_DAT_W;
                end
                S_DAT_W: if (cmd_done) state <= S_META;  // pushed via data_in_valid=r_valid
                S_META: begin
                    meta_in_valid <= 1'b1;               // push len AFTER all data
                    state <= S_DONE;
                end
                S_DONE: begin
                    meta_in_valid <= 1'b0;
                    tx_fetch <= tx_fetch + 16'd1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
