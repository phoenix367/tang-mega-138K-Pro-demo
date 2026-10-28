`default_nettype none
//============================================================================
// rx_path.v -- complete Ethernet RX DMA path.
//
//   rx_mac stream (rx_mac_clk) --> rx_capture --> rx_sf_buffer --\
//                                  (pack bytes)  (store&forward)  |
//                                                                 v
//      data  CDC_FIFO_Buffer --\                          (rewindable write
//      meta  CDC_FIFO_Buffer --+--> rx_ring_writer         pointer; whole-frame
//                              |    (bus_clk) --> AHB        commit or rewind)
//                              v    master port -> DRAM ring
//
// rx_sf_buffer is a single-clock (MAC domain) store-and-forward stage: it buffers
// each frame and only releases COMPLETE frames into the CDC FIFOs, data words
// first then the {err,len} trailer, WITH back-pressure.  The Gowin TSE MAC cannot
// be back-pressured, so an over-long stall drops a WHOLE frame at the staging
// input (rewinding the speculative write pointer) -- it can never lose part of a
// frame's words while keeping its trailer, which is what previously desynced the
// two CDC FIFOs and misaligned every delivered frame.  See rx_sf_buffer.v.
//
// Crosses the 125 MHz MAC domain to the ~50 MHz bus domain via the library CDC
// FIFOs.  CSRs (rx_en/buf_base/ring_len/rx_tail) and the AHB master are in the
// bus domain; rx_head/drop_cnt/irq report status.
//============================================================================
module rx_path #(
    parameter DATA_DEPTH = 1024,      // words; MUST hold one whole max frame
    parameter META_DEPTH = 8,         // frames in flight; power of two
    parameter STAGE_AW   = 10,        // staging RAM = 2^STAGE_AW words
    parameter INFO_AW    = 4,         // staging frame-info FIFO depth = 2^INFO_AW
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
    output reg  [31:0] stat_frames,     // frames the MAC delivered (bus domain)
    output reg  [31:0] stat_bad,        // ... of which it flagged bad (CRC/PHY err)
    output wire        irq,
    output wire        busy,           // AHB master command in progress (for arbiter)
    output wire        dbg_done,        // debug: ahb_master cmd_done pulse
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

    // ---- rx_capture (rx_mac_clk): pack the byte stream into 32-bit words ----
    wire        word_valid;  wire [31:0] word_data;
    wire        frame_valid; wire [15:0] frame_len;  wire frame_err;
    rx_capture cap (
        .rx_mac_clk(rx_mac_clk), .rstn(~in_clear),
        .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .word_valid(word_valid), .word_data(word_data),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_err(frame_err)
    );

    // ---- rx_sf_buffer (rx_mac_clk): store-and-forward with rewindable wptr ----
    // Releases only WHOLE frames into the CDC FIFOs (data words, then metadata),
    // back-pressured -- so the FIFOs cannot lose entries independently.
    wire        sf_data_valid, sf_meta_valid;
    wire [31:0] sf_data_word;
    wire [16:0] sf_meta_word;
    wire        sf_data_ready, sf_meta_ready;     // = CDC FIFO input_ready
    wire [15:0] sf_drop;                          // whole-frame drops (MAC domain)
    rx_sf_buffer #(.AW(STAGE_AW), .INFO_AW(INFO_AW)) sf (
        .clk(rx_mac_clk), .rstn(~in_clear),
        .in_word_valid(word_valid), .in_word(word_data),
        .in_eof(frame_valid), .in_len(frame_len), .in_err(frame_err),
        .data_valid(sf_data_valid), .data_word(sf_data_word), .data_ready(sf_data_ready),
        .meta_valid(sf_meta_valid), .meta_word(sf_meta_word), .meta_ready(sf_meta_ready),
        .drop_cnt(sf_drop)
    );

    // ---- data CDC FIFO (32-bit words) ----
    wire        data_valid, data_ready;
    wire [31:0] data_word;
    CDC_FIFO_Buffer #(.WORD_WIDTH(32), .DEPTH(DATA_DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) dfifo (
        .input_clock(rx_mac_clk),  .input_clear(in_clear),
        .input_valid(sf_data_valid), .input_ready(sf_data_ready), .input_data(sf_data_word),
        .output_clock(bus_clk),    .output_clear(out_clear),
        .output_valid(data_valid), .output_ready(data_ready), .output_data(data_word)
    );

    // ---- metadata CDC FIFO ({err,len} = 17 bits) ----
    wire        meta_valid, meta_ready;
    wire [16:0] meta_out;
    CDC_FIFO_Buffer #(.WORD_WIDTH(17), .DEPTH(META_DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) mfifo (
        .input_clock(rx_mac_clk),  .input_clear(in_clear),
        .input_valid(sf_meta_valid), .input_ready(sf_meta_ready), .input_data(sf_meta_word),
        .output_clock(bus_clk),    .output_clear(out_clear),
        .output_valid(meta_valid), .output_ready(meta_ready), .output_data(meta_out)
    );

    // ---- ring writer + AHB master (bus_clk) ----
    wire        cmd_valid, cmd_ready, cmd_wr, cmd_done, w_req;
    wire [31:0] cmd_addr, w_data;
    wire [15:0] cmd_len;
    wire [15:0] ring_drop;
    rx_ring_writer #(.BUF_SHIFT(BUF_SHIFT)) wr (
        .clk(bus_clk), .rstn(~out_clear), .rx_en(rx_en), .buf_base(buf_base),
        .ring_len(ring_len), .rx_tail(rx_tail), .rx_head(rx_head),
        .drop_cnt(ring_drop), .irq(irq),
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

    assign dbg_done = cmd_done;

    // ---- drop_cnt = ring-full drops (bus) + staging drops (MAC, synced over) ----
    wire [15:0] sf_drop_bus;
    wire        drp_v;
    CDC_Word_Synchronizer #(.WORD_WIDTH(16), .EXTRA_CDC_DEPTH(0),
                            .OUTPUT_BUFFER_TYPE("HALF"), .OUTPUT_BUFFER_CIRCULAR(0),
                            .FIFO_BUFFER_DEPTH(), .FIFO_BUFFER_RAMSTYLE()) drpsync (
        .sending_clock(rx_mac_clk), .sending_clear(in_clear),
        .sending_data(sf_drop), .sending_valid(1'b1), .sending_ready(),
        .receiving_clock(bus_clk), .receiving_clear(out_clear),
        .receiving_data(sf_drop_bus), .receiving_valid(drp_v), .receiving_ready(drp_v)
    );
    assign drop_cnt = ring_drop + sf_drop_bus;

    // ---- line-rate RX statistics ----
    // Every frame the MAC hands over, and those it flagged bad, counted whether
    // or not the ring or staging buffer had room -- so a host can flood the link
    // and measure the error rate far below one per million frames.  Each event
    // toggles a flop in the MAC domain; frames are >= 672 ns apart, much longer
    // than the 2-flop synchronizer, so the bus side sees every toggle.
    reg frm_tgl, bad_tgl;
    always @(posedge rx_mac_clk or posedge in_clear) begin
        if (in_clear) begin
            frm_tgl <= 1'b0; bad_tgl <= 1'b0;
        end else if (frame_valid) begin
            frm_tgl <= ~frm_tgl;
            if (frame_err) bad_tgl <= ~bad_tgl;
        end
    end
    reg [2:0] frm_s, bad_s;
    always @(posedge bus_clk or posedge out_clear) begin
        if (out_clear) begin
            frm_s <= 3'd0; bad_s <= 3'd0; stat_frames <= 32'd0; stat_bad <= 32'd0;
        end else begin
            frm_s <= {frm_s[1:0], frm_tgl};
            bad_s <= {bad_s[1:0], bad_tgl};
            if (frm_s[2] ^ frm_s[1]) stat_frames <= stat_frames + 32'd1;
            if (bad_s[2] ^ bad_s[1]) stat_bad    <= stat_bad + 32'd1;
        end
    end
endmodule
`default_nettype wire
