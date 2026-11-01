`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_tx_path.v -- full TX path end-to-end. Pre-load 3 frames into the DRAM ring,
// queue them (tx_tail=3); verify the tx_mac byte stream (50 MHz bus -> 125 MHz
// MAC) reproduces each frame, with tx_mac_last delimiting, under back-pressure.
//============================================================================
module tb_tx_path;
    localparam BUF_SHIFT = 11;

    reg tx_mac_clk = 0; always #4  tx_mac_clk = ~tx_mac_clk;   // 125 MHz
    reg bus_clk    = 0; always #10 bus_clk    = ~bus_clk;      //  50 MHz
    reg arst_n = 0;

    wire        tx_mac_valid, tx_mac_last;
    wire [7:0]  tx_mac_data;
    reg         tx_mac_ready = 1;

    reg        tx_en = 0;
    reg [31:0] buf_base = 32'h0;
    reg [15:0] ring_len = 16'd4;
    reg [15:0] tx_tail  = 16'd0;
    wire [15:0] tx_head, tx_fetch;

    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans; wire hwrite, hready, hresp; wire [2:0] hsize, hburst;

    tx_path #(.DATA_DEPTH(512), .META_DEPTH(8), .BUF_SHIFT(BUF_SHIFT)) dut (
        .tx_mac_clk(tx_mac_clk), .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data),
        .tx_mac_last(tx_mac_last), .tx_mac_ready(tx_mac_ready),
        .bus_clk(bus_clk), .arst_n(arst_n),
        .tx_en(tx_en), .buf_base(buf_base), .ring_len(ring_len), .tx_tail(tx_tail),
        .tx_head(tx_head), .tx_fetch(tx_fetch),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hburst(hburst),
        .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
    );
    ahb_slave_ram #(.AW(12)) slv (
        .hclk(bus_clk), .hresetn(arst_n), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    function [7:0] pat(input integer f, input integer i); pat = 8'h10 + (f << 6) + i; endfunction

    // back-pressure
    integer seed = 3;
    always @(posedge tx_mac_clk) tx_mac_ready <= ($random(seed) % 5 != 0);

    // collect tx_mac stream
    reg  [7:0] sbuf [0:4095];
    integer    sidx = 0, nf = 0, fend [0:7];
    always @(posedge tx_mac_clk) begin
        if (tx_mac_valid && tx_mac_ready) begin
            sbuf[sidx] = tx_mac_data;
            if (tx_mac_last) begin fend[nf] = sidx; nf = nf + 1; end
            sidx = sidx + 1;
        end
    end

    integer flen [0:2];
    integer f, i, w, j, base, start, errors;
    reg [31:0] word;
    initial begin
        errors = 0;
        flen[0]=14; flen[1]=60; flen[2]=4;
        // pre-load the DRAM ring
        for (f = 0; f < 3; f = f + 1) begin
            base = (f % ring_len) << BUF_SHIFT;            // bytes
            slv.mem[base >> 2] = {16'b0, flen[f][15:0]};   // header
            for (w = 0; w < ((flen[f]+3)>>2); w = w + 1) begin
                word = 32'd0;
                for (j = 0; j < 4; j = j + 1)
                    if (w*4 + j < flen[f]) word[j*8 +: 8] = pat(f, w*4 + j);
                slv.mem[(base + 4 + w*4) >> 2] = word;
            end
        end

        arst_n = 0;
        #500 arst_n = 1;
        #2000;
        tx_tail = 16'd3; tx_en = 1;

        wait (nf == 3);
        repeat (10) @(posedge tx_mac_clk);

        start = 0;
        for (f = 0; f < 3; f = f + 1) begin
            if ((fend[f] - start + 1) !== flen[f]) begin
                errors = errors + 1;
                $display("  frame %0d length got %0d exp %0d", f, fend[f]-start+1, flen[f]);
            end
            for (i = 0; i < flen[f]; i = i + 1) begin
                if (sbuf[start + i] !== pat(f, i)) begin
                    errors = errors + 1;
                    if (errors < 8) $display("  frame %0d byte %0d got %02x exp %02x", f, i, sbuf[start+i], pat(f,i));
                end
            end
            start = fend[f] + 1;
        end
        if (errors == 0) $display("RESULT: PASS (3 frames DRAM->DMA->CDC->tx_mac intact; tx_head=%0d)", tx_head);
        else             $display("RESULT: FAIL (%0d errors, tx_head=%0d tx_fetch=%0d)", errors, tx_head, tx_fetch);
        $finish;
    end
    initial begin #300000; $display("RESULT: FAIL (timeout nf=%0d tx_fetch=%0d tx_head=%0d)", nf, tx_fetch, tx_head); $finish; end
endmodule
`default_nettype wire
