`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_csr.v -- exercise the CSR AHB-lite slave: write/read config registers,
// read status inputs, check IRQ latch+mask, and the MDIO trigger/result path.
//============================================================================
module tb_csr;
    reg hclk = 0; always #5 hclk = ~hclk;
    reg hresetn = 0;

    // AHB master signals
    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0, hready_in = 1;
    wire [31:0] hrdata;
    wire        hready, hresp;

    // CSR I/O
    wire        rx_en, tx_en, irq;
    wire [31:0] rx_base, tx_base;
    wire [15:0] rx_ring_len, rx_tail, tx_ring_len, tx_tail;
    reg  [15:0] rx_head = 16'h1234, rx_drop = 16'h5, tx_head = 16'hABCD, tx_fetch = 16'h9;
    reg         rx_irq_set = 0, tx_irq_set = 0;
    wire [4:0]  miim_phyad, miim_regad;
    wire [15:0] miim_wrdata;
    wire        miim_wren, miim_rden;
    reg  [15:0] miim_rddata = 0;
    reg         miim_rddata_valid = 0, miim_busy = 0;
    wire [2:0]  eth_mode;

    csr dut (
        .hclk(hclk), .hresetn(hresetn), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsel(hsel), .hready_in(hready_in), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp),
        .rx_en(rx_en), .rx_base(rx_base), .rx_ring_len(rx_ring_len), .rx_tail(rx_tail),
        .rx_head(rx_head), .rx_drop(rx_drop),
        .tx_en(tx_en), .tx_base(tx_base), .tx_ring_len(tx_ring_len), .tx_tail(tx_tail),
        .tx_head(tx_head), .tx_fetch(tx_fetch),
        .rx_irq_set(rx_irq_set), .tx_irq_set(tx_irq_set), .irq(irq),
        .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
        .miim_wren(miim_wren), .miim_rden(miim_rden), .miim_rddata(miim_rddata),
        .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy), .eth_mode(eth_mode)
    );

    integer errors = 0;
    reg [31:0] rv;

    task ahb_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge hclk); haddr=addr; htrans=2'b10; hwrite=1; hsel=1;
            @(negedge hclk); haddr=0; htrans=2'b00; hwrite=0; hsel=0; hwdata=data;
            @(negedge hclk); hwdata=0;
        end
    endtask
    task ahb_read(input [31:0] addr, output [31:0] data);
        begin
            @(negedge hclk); haddr=addr; htrans=2'b10; hwrite=0; hsel=1;
            @(negedge hclk); haddr=0; htrans=2'b00; hsel=0;
            data = hrdata;
        end
    endtask
    task chk(input [31:0] got, input [31:0] exp, input [127:0] name);
        if (got !== exp) begin errors=errors+1; $display("  %0s got %08x exp %08x", name, got, exp); end
    endtask

    initial begin
        repeat (3) @(posedge hclk); hresetn = 1; @(negedge hclk);

        // config registers round-trip
        ahb_write(32'h10, 32'hDEAD_BEEF);     // RX_BASE
        ahb_write(32'h14, 32'd64);            // RX_LEN
        ahb_write(32'h18, 32'd7);             // RX_TAIL
        ahb_write(32'h30, 32'hCAFE_0000);     // TX_BASE
        ahb_write(32'h34, 32'd16);            // TX_LEN
        ahb_write(32'h38, 32'd3);             // TX_TAIL
        ahb_write(32'h00, 32'h3);             // CTRL rx_en|tx_en
        ahb_write(32'h60, 32'd1);             // ETH_MODE = 1000M

        chk({31'b0, rx_en}, 1, "rx_en");
        chk({31'b0, tx_en}, 1, "tx_en");
        chk(rx_base, 32'hDEAD_BEEF, "rx_base");
        chk({16'b0, rx_ring_len}, 64, "rx_len");
        chk({16'b0, rx_tail}, 7, "rx_tail");
        chk(tx_base, 32'hCAFE_0000, "tx_base");
        chk({16'b0, tx_tail}, 3, "tx_tail");
        chk({29'b0, eth_mode}, 1, "eth_mode");

        ahb_read(32'h10, rv); chk(rv, 32'hDEAD_BEEF, "rd RX_BASE");
        ahb_read(32'h1C, rv); chk(rv, 32'h1234, "rd RX_HEAD");      // status input
        ahb_read(32'h20, rv); chk(rv, 32'h5,    "rd RX_DROP");
        ahb_read(32'h3C, rv); chk(rv, 32'hABCD, "rd TX_HEAD");
        ahb_read(32'h40, rv); chk(rv, 32'h9,    "rd TX_FETCH");

        // IRQ: enable rx, pulse rx_irq_set -> irq, then W1C
        ahb_write(32'h08, 32'h1);             // IRQ_EN rx
        @(negedge hclk); rx_irq_set = 1; @(negedge hclk); rx_irq_set = 0;
        repeat (2) @(negedge hclk);
        chk({31'b0, irq}, 1, "irq asserted");
        ahb_read(32'h04, rv); chk(rv, 32'h1, "IRQ_STAT");
        ahb_write(32'h04, 32'h1);             // W1C
        repeat (2) @(negedge hclk);
        chk({31'b0, irq}, 0, "irq cleared");

        // MDIO: addr + read trigger -> miim_rden pulse + phyad/regad, then result
        ahb_write(32'h50, {22'b0, 5'd7, 5'd9});  // regad=7 phyad=9
        chk({27'b0, miim_phyad}, 9, "miim_phyad");
        chk({27'b0, miim_regad}, 7, "miim_regad");
        fork
            begin ahb_write(32'h58, 32'h1); end  // read pulse
            begin : catch_rden integer k; reg seen; seen=0;
                  for (k=0;k<6;k=k+1) begin @(posedge hclk); if (miim_rden) seen=1; end
                  if (!seen) begin errors=errors+1; $display("  miim_rden not pulsed"); end
            end
        join
        // model the PHY returning data
        @(negedge hclk); miim_rddata = 16'hBEEF; miim_rddata_valid = 1;
        @(negedge hclk); miim_rddata_valid = 0;
        repeat (2) @(negedge hclk);
        ahb_read(32'h5C, rv);
        chk(rv[15:0], 32'hBEEF, "mdio rddata");
        chk(rv[16], 1, "mdio rd_valid");

        if (errors == 0) $display("RESULT: PASS (CSR registers, status, IRQ, MDIO all correct)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #50000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
