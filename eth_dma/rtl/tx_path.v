`default_nettype none
//============================================================================
// tx_path.v -- complete Ethernet TX DMA path.
//
//   DRAM ring --(ahb_master read)--> tx_ring_reader --> data CDC_FIFO_Buffer --\
//                                                   \--> meta CDC_FIFO_Buffer --+--> tx_unpack --> tx_mac
//   frame_done (tx_mac_clk) --toggle--> CDC_Bit_Synchronizer --> bus edge --> tx_head (serial pacing)
//
// Crosses the ~50 MHz bus domain to the 125 MHz MAC domain via the library CDC
// FIFOs.  Serial v1: one frame fetched/transmitted at a time.
//============================================================================
module tx_path #(
    parameter DATA_DEPTH = 512,
    parameter META_DEPTH = 8,
    parameter BUF_SHIFT  = 11
)(
    // MAC TX stream domain
    input  wire        tx_mac_clk,
    output wire        tx_mac_valid,
    output wire [7:0]  tx_mac_data,
    output wire        tx_mac_last,
    input  wire        tx_mac_ready,
    // bus domain
    input  wire        bus_clk,
    input  wire        arst_n,
    // CSRs (bus domain)
    input  wire        tx_en,
    input  wire [31:0] buf_base,
    input  wire [15:0] ring_len,
    input  wire [15:0] tx_tail,
    output wire [15:0] tx_head,
    output wire [15:0] tx_fetch,
    output wire        tx_irq,          // 1-cycle pulse per frame transmitted
    output wire        busy,            // AHB master command in progress (for arbiter)
    // AHB-lite master port (read) -> DRAM via EXTM
    output wire [31:0] haddr,
    output wire [1:0]  htrans,
    output wire        hwrite,
    output wire [2:0]  hsize,
    output wire [2:0]  hburst,
    output wire [31:0] hwdata,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp
);
    wire in_clear, out_clear;          // TX CDC crosses bus(in) -> tx_mac(out)
    cdc_fifo_reset #(.HOLD(64)) rstgen (
        .arst_n(arst_n), .in_clk(bus_clk), .out_clk(tx_mac_clk),
        .in_clear(in_clear), .out_clear(out_clear)
    );
    wire bus_rstn = ~in_clear;
    wire mac_rstn = ~out_clear;

    // ---- tx_ring_reader + ahb_master (bus) ----
    wire        cmd_valid, cmd_ready, cmd_wr, cmd_done, r_valid;
    wire [31:0] cmd_addr, r_data;
    wire [15:0] cmd_len;
    wire        data_in_valid, data_in_ready, meta_in_valid, meta_in_ready;
    wire [31:0] data_in_data;
    wire [15:0] meta_in_data;
    wire [15:0] tx_head_cnt;

    tx_ring_reader #(.BUF_SHIFT(BUF_SHIFT)) rd (
        .clk(bus_clk), .rstn(bus_rstn), .tx_en(tx_en), .buf_base(buf_base),
        .ring_len(ring_len), .tx_tail(tx_tail), .tx_fetch(tx_fetch), .tx_head(tx_head_cnt),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr),
        .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done), .r_valid(r_valid), .r_data(r_data),
        .data_in_valid(data_in_valid), .data_in_data(data_in_data),
        .meta_in_valid(meta_in_valid), .meta_in_data(meta_in_data)
    );
    ahb_master ahbm (
        .hclk(bus_clk), .hresetn(bus_rstn), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done),
        .cmd_err(), .busy(busy), .w_req(), .w_data(32'b0), .r_valid(r_valid), .r_data(r_data),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
    );

    // ---- data CDC FIFO (bus -> tx_mac) ----
    wire        data_out_valid, data_out_ready;
    wire [31:0] data_out_data;
    CDC_FIFO_Buffer #(.WORD_WIDTH(32), .DEPTH(DATA_DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) dfifo (
        .input_clock(bus_clk),   .input_clear(in_clear),
        .input_valid(data_in_valid), .input_ready(data_in_ready), .input_data(data_in_data),
        .output_clock(tx_mac_clk), .output_clear(out_clear),
        .output_valid(data_out_valid), .output_ready(data_out_ready), .output_data(data_out_data)
    );
    // ---- metadata CDC FIFO (16-bit len) ----
    wire        meta_out_valid, meta_out_ready;
    wire [15:0] meta_out_data;
    CDC_FIFO_Buffer #(.WORD_WIDTH(16), .DEPTH(META_DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) mfifo (
        .input_clock(bus_clk),   .input_clear(in_clear),
        .input_valid(meta_in_valid), .input_ready(meta_in_ready), .input_data(meta_in_data),
        .output_clock(tx_mac_clk), .output_clear(out_clear),
        .output_valid(meta_out_valid), .output_ready(meta_out_ready), .output_data(meta_out_data)
    );

    // ---- tx_unpack (tx_mac) ----
    wire frame_done;
    tx_unpack un (
        .tx_mac_clk(tx_mac_clk), .rstn(mac_rstn),
        .meta_valid(meta_out_valid), .meta_len(meta_out_data), .meta_ready(meta_out_ready),
        .data_valid(data_out_valid), .data_word(data_out_data), .data_ready(data_out_ready),
        .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data), .tx_mac_last(tx_mac_last),
        .tx_mac_ready(tx_mac_ready), .frame_done(frame_done)
    );

    // ---- completion: frame_done (tx_mac) -> toggle -> bus edge -> tx_head ----
    reg done_tog;
    always @(posedge tx_mac_clk or negedge mac_rstn)
        if (!mac_rstn)      done_tog <= 1'b0;
        else if (frame_done) done_tog <= ~done_tog;
    wire done_tog_bus;
    CDC_Bit_Synchronizer #(.EXTRA_DEPTH(0)) bsync (
        .receiving_clock(bus_clk), .bit_in(done_tog), .bit_out(done_tog_bus)
    );
    reg done_tog_bus_d;
    reg [15:0] tx_head_r;
    always @(posedge bus_clk or negedge bus_rstn)
        if (!bus_rstn) begin done_tog_bus_d <= 1'b0; tx_head_r <= 16'd0; end
        else begin
            done_tog_bus_d <= done_tog_bus;
            if (done_tog_bus ^ done_tog_bus_d) tx_head_r <= tx_head_r + 16'd1;
        end
    assign tx_head_cnt = tx_head_r;
    assign tx_head     = tx_head_r;
    assign tx_irq      = done_tog_bus ^ done_tog_bus_d;

    wire _unused = &{data_in_ready, hrdata[0], 1'b0};
endmodule
`default_nettype wire
