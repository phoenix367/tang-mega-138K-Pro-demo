`default_nettype none
//============================================================================
// rx_path.v -- complete Ethernet RX DMA path.
//
//   rx_mac stream (rx_mac_clk) --> rx_capture --> data  CDC_FIFO_Buffer --\
//                                            \--> meta  CDC_FIFO_Buffer --+--> rx_ring_writer
//   cdc_fifo_reset drives both FIFOs' clears; rx_ring_writer DMAs frames   |
//   into the DRAM ring via ahb_master (EXTM).                              v
//                                                                     AHB master port
//
// Crosses the 125 MHz MAC domain to the ~50 MHz bus domain via the library CDC
// FIFOs.  CSRs (rx_en/buf_base/ring_len/rx_tail) and the AHB master are in the
// bus domain; rx_head/drop_cnt/irq report status.
//============================================================================
module rx_path #(
    parameter DATA_DEPTH = 512,       // words (>= 1 MTU); power of two
    parameter META_DEPTH = 8,         // frames in flight; power of two
    parameter BUF_SHIFT  = 11         // 2 KB ring buffers
)(
    // MAC RX stream domain
    input  wire        rx_mac_clk,
    input  wire        rx_mac_valid,
    input  wire [7:0]  rx_mac_data,
    input  wire        rx_mac_last,
    input  wire        rx_mac_error,
    // bus domain
    input  wire        bus_clk,
    input  wire        arst_n,
    // CSRs (bus domain)
    input  wire        rx_en,
    input  wire [31:0] buf_base,
    input  wire [15:0] ring_len,
    input  wire [15:0] rx_tail,
    output wire [15:0] rx_head,
    output wire [15:0] drop_cnt,
    output wire        irq,
    output wire        busy,           // AHB master command in progress (for arbiter)
    // AHB-lite master port (bus domain) -> DRAM via EXTM
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
    // ---- reset for both CDC FIFOs (and the two domains' logic) ----
    wire in_clear, out_clear;
    cdc_fifo_reset #(.HOLD(64)) rstgen (
        .arst_n(arst_n), .in_clk(rx_mac_clk), .out_clk(bus_clk),
        .in_clear(in_clear), .out_clear(out_clear)
    );

    // ---- rx_capture (rx_mac_clk) ----
    wire        word_valid;  wire [31:0] word_data;
    wire        frame_valid; wire [15:0] frame_len;  wire frame_err;
    rx_capture cap (
        .rx_mac_clk(rx_mac_clk), .rstn(~in_clear),
        .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .word_valid(word_valid), .word_data(word_data),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_err(frame_err)
    );

    // ---- data CDC FIFO (32-bit words) ----
    wire        data_valid, data_ready, data_iready;
    wire [31:0] data_word;
    CDC_FIFO_Buffer #(.WORD_WIDTH(32), .DEPTH(DATA_DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) dfifo (
        .input_clock(rx_mac_clk),  .input_clear(in_clear),
        .input_valid(word_valid),  .input_ready(data_iready), .input_data(word_data),
        .output_clock(bus_clk),    .output_clear(out_clear),
        .output_valid(data_valid), .output_ready(data_ready), .output_data(data_word)
    );

    // ---- metadata CDC FIFO ({err,len} = 17 bits) ----
    wire        meta_valid, meta_ready, meta_iready;
    wire [16:0] meta_out;
    CDC_FIFO_Buffer #(.WORD_WIDTH(17), .DEPTH(META_DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) mfifo (
        .input_clock(rx_mac_clk),  .input_clear(in_clear),
        .input_valid(frame_valid), .input_ready(meta_iready), .input_data({frame_err, frame_len}),
        .output_clock(bus_clk),    .output_clear(out_clear),
        .output_valid(meta_valid), .output_ready(meta_ready), .output_data(meta_out)
    );

    // ---- ring writer + AHB master (bus_clk) ----
    wire        cmd_valid, cmd_ready, cmd_wr, cmd_done, w_req;
    wire [31:0] cmd_addr, w_data;
    wire [15:0] cmd_len;
    rx_ring_writer #(.BUF_SHIFT(BUF_SHIFT)) wr (
        .clk(bus_clk), .rstn(~out_clear), .rx_en(rx_en), .buf_base(buf_base),
        .ring_len(ring_len), .rx_tail(rx_tail), .rx_head(rx_head),
        .drop_cnt(drop_cnt), .irq(irq),
        .meta_valid(meta_valid), .meta_len(meta_out[15:0]), .meta_err(meta_out[16]),
        .meta_ready(meta_ready),
        .data_valid(data_valid), .data_word(data_word), .data_ready(data_ready),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr),
        .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done), .w_req(w_req), .w_data(w_data)
    );
    ahb_master ahbm (
        .hclk(bus_clk), .hresetn(~out_clear), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done),
        .cmd_err(), .busy(busy), .w_req(w_req), .w_data(w_data), .r_valid(), .r_data(),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
    );

    // (input_ready of the FIFOs is unused: the MAC cannot backpressure, so the
    //  data FIFO must be sized >= worst-case bus latency; overflow == loss.)
    wire _unused = &{data_iready, meta_iready, 1'b0};
endmodule
`default_nettype wire
