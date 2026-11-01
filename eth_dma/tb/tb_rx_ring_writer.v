`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_rx_ring_writer.v -- rx_ring_writer + 64-bit ahb_master + ahb_slave_ram.
// Feed frames' words (packed in pairs into 64-bit entries per frame, as the
// rx_path pair packer does) + their {len,err} trailers; verify each frame
// lands in its ring buffer as [header {err,len}][data...].  Lengths cover odd
// and even word counts up to a full-size frame; WAIT_PCT (iverilog -P) adds
// slave wait states, and the slave checks the burst protocol.
//============================================================================
module tb_rx_ring_writer;
    parameter WAIT_PCT = 0;
    localparam BUF_SHIFT = 11;        // 2 KB buffers
    localparam NF = 6;
    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;

    // config
    reg         rx_en = 0;
    reg  [31:0] buf_base = 32'h0000_0000;
    reg  [15:0] ring_len = 16'd8;
    reg  [15:0] rx_tail  = 16'd0;
    wire [15:0] rx_head, drop_cnt;
    wire        irq;

    // metadata queue (tb-driven)
    reg  [15:0] mlen [0:7];
    reg         merr [0:7];
    integer     midx = 0, mcount = 0;
    wire        meta_valid = (midx < mcount);
    wire [15:0] meta_len   = mlen[midx];
    wire        meta_err   = merr[midx];
    wire        meta_ready;
    always @(posedge clk) if (meta_valid && meta_ready) midx <= midx + 1;

    // data source: 64-bit entries {w[2i+1], w[2i]} per frame (mimics the CDC FIFO)
    reg  [31:0] dmem [0:2047];        // all frames' 32-bit words, in order
    reg  [63:0] emem [0:1023];
    integer     eidx = 0, etotal = 0;
    wire        data_valid = (eidx < etotal);
    wire [63:0] data_word  = emem[eidx];
    wire        data_ready;
    always @(posedge clk) if (data_valid && data_ready) eidx <= eidx + 1;

    // DUT + AHB master + slave RAM
    wire        cmd_valid, cmd_ready, cmd_wr, cmd_done, w_req;
    wire [31:0] cmd_addr;
    wire [63:0] w_data;
    wire [15:0] cmd_len;
    wire [31:0] haddr;
    wire [63:0] hwdata, hrdata;
    wire [1:0]  htrans;  wire hwrite, hready, hresp;  wire [2:0] hsize, hburst;

    rx_ring_writer #(.BUF_SHIFT(BUF_SHIFT)) dut (
        .clk(clk), .rstn(rstn), .rx_en(rx_en), .buf_base(buf_base),
        .ring_len(ring_len), .rx_tail(rx_tail), .rx_head(rx_head),
        .drop_cnt(drop_cnt), .irq(irq),
        .meta_valid(meta_valid), .meta_len(meta_len), .meta_err(meta_err), .meta_ready(meta_ready),
        .data_valid(data_valid), .data_word(data_word), .data_ready(data_ready),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr),
        .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done), .w_req(w_req), .w_data(w_data)
    );
    ahb_master #(.DATA_W(64)) m (
        .hclk(clk), .hresetn(rstn), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done),
        .cmd_err(), .w_req(w_req), .w_data(w_data), .r_valid(), .r_data(),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
    );
    ahb_slave_ram #(.DATA_W(64), .AW(12), .WAIT_PCT(WAIT_PCT)) slv (
        .hclk(clk), .hresetn(rstn), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    // 32-bit word at a byte address of the 64-bit slave RAM
    function [31:0] word_at(input [31:0] b);
        word_at = slv.mem[b >> 3][b[2]*32 +: 32];
    endfunction

    integer f, w, ws, nw, errors;
    reg [31:0] base, exp;
    initial begin
        errors = 0;
        // byte lengths -> 1, 2, 4, 15 (err), 378, 379 words
        mlen[0]=16'd4;    merr[0]=1'b0;
        mlen[1]=16'd8;    merr[1]=1'b0;
        mlen[2]=16'd14;   merr[2]=1'b0;
        mlen[3]=16'd60;   merr[3]=1'b1;
        mlen[4]=16'd1512; merr[4]=1'b0;
        mlen[5]=16'd1514; merr[5]=1'b0;
        mcount = NF;
        ws = 0; etotal = 0;
        for (f = 0; f < NF; f = f + 1) begin
            nw = (mlen[f] + 3) >> 2;
            for (w = 0; w < nw; w = w + 1) dmem[ws + w] = 32'hC0DE0000 + (f << 12) + w;
            for (w = 0; w < nw; w = w + 2) begin
                emem[etotal] = {(w + 1 < nw) ? dmem[ws + w + 1] : 32'hBAD0BAD0, dmem[ws + w]};
                etotal = etotal + 1;
            end
            ws = ws + nw;
        end

        repeat (3) @(posedge clk); rstn = 1; repeat (2) @(posedge clk);
        rx_en = 1;
        wait (rx_head == NF);
        repeat (4) @(posedge clk);

        ws = 0;
        for (f = 0; f < NF; f = f + 1) begin
            base = (f % ring_len) << BUF_SHIFT;          // buf_base = 0
            exp  = {15'b0, merr[f], mlen[f]};
            if (word_at(base) !== exp) begin
                errors = errors + 1;
                $display("  frame %0d header @%08x got %08x exp %08x", f, base, word_at(base), exp);
            end
            for (w = 0; w < ((mlen[f]+3)>>2); w = w + 1) begin
                if (word_at(base + 4 + w*4) !== dmem[ws]) begin
                    errors = errors + 1;
                    if (errors < 8) $display("  frame %0d word %0d got %08x exp %08x",
                        f, w, word_at(base + 4 + w*4), dmem[ws]);
                end
                ws = ws + 1;
            end
        end
        if (eidx != etotal) begin
            errors = errors + 1;
            $display("  consumed %0d of %0d data entries", eidx, etotal);
        end
        errors = errors + slv.proto_err;
        if (errors == 0) $display("RESULT: PASS (%0d frames DMA'd to ring; headers+data correct; drops=%0d; wait %0d%%)", NF, drop_cnt, WAIT_PCT);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #400000; $display("RESULT: FAIL (timeout rx_head=%0d)", rx_head); $finish; end
endmodule
`default_nettype wire
