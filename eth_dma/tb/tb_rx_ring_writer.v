`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_rx_ring_writer.v -- rx_ring_writer + ahb_master + ahb_slave_ram.
// Feed 3 frames' worth of words + their {len,err} trailers; verify each frame
// lands in its ring buffer as [header {err,len}][data...].
//============================================================================
module tb_rx_ring_writer;
    localparam BUF_SHIFT = 11;        // 2 KB buffers
    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;

    // config
    reg         rx_en = 0;
    reg  [31:0] buf_base = 32'h0000_0000;
    reg  [15:0] ring_len = 16'd4;
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

    // data word source (mimics the CDC FIFO output the writer reads)
    reg  [31:0] dmem [0:1023];
    integer     didx = 0, dtotal = 0;
    wire        data_valid = (didx < dtotal);
    wire [31:0] data_word  = dmem[didx];
    wire        data_ready;
    always @(posedge clk) if (data_valid && data_ready) didx <= didx + 1;

    // DUT + AHB master + slave RAM
    wire        cmd_valid, cmd_ready, cmd_wr, cmd_done, w_req;
    wire [31:0] cmd_addr, w_data;
    wire [15:0] cmd_len;
    wire [31:0] haddr, hwdata, hrdata;
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
    ahb_master m (
        .hclk(clk), .hresetn(rstn), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done),
        .cmd_err(), .w_req(w_req), .w_data(w_data), .r_valid(), .r_data(),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
    );
    ahb_slave_ram #(.AW(12)) slv (
        .hclk(clk), .hresetn(rstn), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    integer i, f, w, ws, errors;
    reg [31:0] base, exp;
    initial begin
        errors = 0;
        // 3 frames: 14B, 60B(err), 4B.  Words = 4 + 15 + 1 = 20.
        mlen[0]=16'd14; merr[0]=1'b0;
        mlen[1]=16'd60; merr[1]=1'b1;
        mlen[2]=16'd4;  merr[2]=1'b0;
        mcount = 3;
        dtotal = 4 + 15 + 1;
        for (i = 0; i < dtotal; i = i + 1) dmem[i] = 32'hC0DE0000 + i;

        repeat (3) @(posedge clk); rstn = 1; repeat (2) @(posedge clk);
        rx_en = 1;
        wait (rx_head == 3);
        repeat (4) @(posedge clk);

        ws = 0;
        for (f = 0; f < 3; f = f + 1) begin
            base = (f % ring_len) << BUF_SHIFT;          // buf_base = 0
            exp  = {15'b0, merr[f], mlen[f]};
            if (slv.mem[base[13:2]] !== exp) begin
                errors = errors + 1;
                $display("  frame %0d header @%08x got %08x exp %08x", f, base, slv.mem[base[13:2]], exp);
            end
            for (w = 0; w < ((mlen[f]+3)>>2); w = w + 1) begin
                if (slv.mem[(base+4+w*4) >> 2] !== dmem[ws]) begin
                    errors = errors + 1;
                    if (errors < 8) $display("  frame %0d word %0d got %08x exp %08x",
                        f, w, slv.mem[(base+4+w*4)>>2], dmem[ws]);
                end
                ws = ws + 1;
            end
        end
        if (errors == 0) $display("RESULT: PASS (3 frames DMA'd to ring; headers+data correct; drops=%0d)", drop_cnt);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #100000; $display("RESULT: FAIL (timeout rx_head=%0d)", rx_head); $finish; end
endmodule
`default_nettype wire
