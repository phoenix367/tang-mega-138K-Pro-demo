`timescale 1ns/1ps
//============================================================================
// tb_sdspi.v -- sdspi_core on an AHB-lite master model with an SPI slave
// model (mode 0): the slave shifts MOSI in on rising SCK edges and drives
// MISO with a byte stream of its own on falling edges.  Checks registers,
// TX byte order, RX capture, chip select, clock divider, long transfers,
// discard mode and card detect.
//============================================================================
module tb_sdspi;
    reg hclk = 0;  always #10 hclk = ~hclk;       // 50 MHz
    reg hresetn = 0;

    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0;
    wire [31:0] hrdata;
    wire        hready, hresp;
    wire        sck, mosi, cs_n;
    wire        miso;
    reg         det_n = 1;

    sdspi_core dut (
        .hclk(hclk), .hresetn(hresetn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel),
        .s_hready_in(1'b1), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .spi_sck(sck), .spi_mosi(mosi), .spi_miso(miso), .spi_cs_n(cs_n), .sd_det_n(det_n)
    );

    // ---- SPI slave model --------------------------------------------------
    reg  [7:0] slv_rx [0:4095];     // bytes received from the master
    integer    slv_n = 0;
    reg  [7:0] slv_sh = 0;
    reg  [2:0] slv_bit = 0;
    reg  [7:0] slv_tx = 8'hA5;      // byte being shifted out
    reg  [7:0] slv_next = 8'hA5;    // next byte: a counter
    reg        miso_r = 1;
    assign miso = cs_n ? 1'bz : miso_r;
    integer    bytes_while_cs_high = 0;
    always @(posedge sck) begin
        if (cs_n) bytes_while_cs_high = bytes_while_cs_high + 1;
        slv_sh = {slv_sh[6:0], mosi};
        if (slv_bit == 7) begin
            slv_rx[slv_n] = slv_sh; slv_n = slv_n + 1;
            slv_bit = 0;
        end else slv_bit = slv_bit + 1;
    end
    // MISO: MSB first.  Bit 7 of a byte is presented when CS falls (first
    // byte) or on the falling edge that follows the byte's last rising edge.
    reg [3:0] obits = 0;
    always @(negedge cs_n) begin
        slv_tx = slv_next; slv_next = slv_next + 8'h11;
        miso_r = slv_tx[7]; obits = 1;
    end
    always @(negedge sck) if (!cs_n) begin
        if (obits == 8) begin slv_tx = slv_next; slv_next = slv_next + 8'h11; obits = 0; end
        miso_r = slv_tx[7 - obits]; obits = obits + 1;
    end

    // ---- bus tasks --------------------------------------------------------
    task bus_wr(input [15:0] off, input [31:0] d);
    begin
        @(posedge hclk); haddr <= 32'hE801_0000 | off; htrans <= 2'b10; hwrite <= 1; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0; hwrite <= 0; hwdata <= d;
        @(posedge hclk); hwdata <= 0;
    end
    endtask
    task bus_rd(input [15:0] off, output [31:0] d);
    begin
        @(posedge hclk); haddr <= 32'hE801_0000 | off; htrans <= 2'b10; hwrite <= 0; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0; haddr <= 32'h0;  // address changes in the data phase
        #1 d = hrdata;
        @(posedge hclk);
    end
    endtask
    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %08x expected %08x @%0t", what, got, exp, $time);
            errors = errors + 1;
        end
    endtask
    task wait_done;
        reg [31:0] s;
        begin
            s = 1;
            while (s[0]) begin #200; bus_rd(16'h0004, s); end
        end
    endtask
    task xfer(input integer n);     // start n bytes and wait
        begin
            bus_wr(16'h0008, n); wait_done;
        end
    endtask

    // expected slave output stream: A5, B6, C7, ... (counter step 0x11)
    reg [7:0] exp_miso; integer i, k;
    reg [31:0] d;
    real t0, t1;
    initial begin
        $dumpfile("tb_sdspi.vcd"); $dumpvars(0, tb_sdspi);
        repeat (5) @(posedge hclk); hresetn = 1; repeat (3) @(posedge hclk);

        bus_rd(16'h000C, d); check("ID", d, 32'h53445350);
        bus_rd(16'h0000, d); check("CTRL reset (cs high, div 62)", d, 32'h00003E01);
        bus_rd(16'h0004, d); check("STATUS no card", d[1:0], 2'b00);
        det_n = 0; repeat (4) @(posedge hclk);
        bus_rd(16'h0004, d); check("STATUS card inserted", d[1], 1'b1);

        // 6-byte command at DIV 0 (25 MHz): CMD0 = 40 00 00 00 00 95
        bus_wr(16'h0000, 32'h0000_0000);            // cs low, div 0
        bus_wr(16'h0800, 32'h00000040);              // bytes 40 00 00 00
        bus_wr(16'h0804, 32'h00009500);              // bytes 00 95 xx xx
        t0 = $realtime;
        xfer(6);
        t1 = $realtime;
        check("slave got 6 bytes", slv_n, 6);
        check("byte0", slv_rx[0], 8'h40); check("byte1", slv_rx[1], 8'h00);
        check("byte4", slv_rx[4], 8'h00); check("byte5", slv_rx[5], 8'h95);
        // RX = slave stream A5 B6 C7 D8 E9 FA
        bus_rd(16'h1000, d); check("rx word0", d, 32'hD8C7B6A5);
        bus_rd(16'h1004, d); check("rx word1 (bytes 4,5)", d[15:0], 16'hFAE9);
        bus_rd(16'h0004, d); check("STATUS len 6", d[27:16], 12'd6);
        check("CS low during transfer", bytes_while_cs_high, 0);
        // timing: 6 bytes = 48 clocks at 25 MHz = 1920 ns plus a few load cycles
        if (t1 - t0 > 2600.0 || t1 - t0 < 1900.0) begin
            $display("FAIL timing at div 0: %0f ns for 6 bytes", t1 - t0); errors = errors + 1;
        end

        // divider 4 -> 5 MHz: 2 bytes = 16 clocks = 3200 ns
        bus_wr(16'h0000, 32'h0000_0400);
        bus_wr(16'h0800, 32'h0000FF55);
        t0 = $realtime; xfer(2); t1 = $realtime;
        check("byte6", slv_rx[6], 8'h55); check("byte7", slv_rx[7], 8'hFF);
        if (t1 - t0 > 4200.0 || t1 - t0 < 3200.0) begin
            $display("FAIL timing at div 4: %0f ns for 2 bytes", t1 - t0); errors = errors + 1;
        end
        bus_rd(16'h1000, d); check("rx after 2 bytes", d[15:0], 16'h1C0B);   // 0B, 1C

        // full 2048-byte block at div 0: TX = pattern, check slave received all
        bus_wr(16'h0000, 32'h0000_0000);
        for (i = 0; i < 512; i = i + 1) bus_wr(16'h0800 + i * 4, {8'(i*4+3), 8'(i*4+2), 8'(i*4+1), 8'(i*4)});
        slv_n = 0;
        xfer(2048);
        check("slave got 2048", slv_n, 2048);
        for (i = 0; i < 2048; i = i + 1) if (slv_rx[i] !== i[7:0]) begin
            if (errors < 5) $display("FAIL tx byte %0d: %02x", i, slv_rx[i]); errors = errors + 1;
        end
        // RX: contiguous counter stream continues; just check two spots are consistent
        bus_rd(16'h1000, d); exp_miso = d[7:0];
        bus_rd(16'h17FC, d); check("rx last word consistent with stream", d[7:0], 8'(exp_miso + 8'h11 * 2044));

        // discard mode: RX buffer must keep the old content
        bus_wr(16'h0000, 32'h0001_0000);
        bus_rd(16'h1000, d); k = d;
        xfer(8);
        bus_rd(16'h1000, d); check("rx unchanged in discard mode", d, k);

        // CS release
        bus_wr(16'h0000, 32'h0000_0001);
        repeat (2) @(posedge hclk);
        check("cs_n high", cs_n, 1'b1);
        check("mosi idle high", mosi, 1'b1);
        check("sck idle low", sck, 1'b0);

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
