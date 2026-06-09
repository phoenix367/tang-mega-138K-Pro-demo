`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_gw_eth_dma.v -- full-core loopback. CPU (AHB master on EXTS) programs the
// rings, queues a TX frame; tx_mac is wired back to rx_mac, so the frame
// transmits, loops, and is received into the RX ring. Verifies the RX ring
// contents == the original TX frame. Exercises csr + tx_path + rx_path + the
// (behavioral stand-in) AHB arbiter + DRAM, end to end.
//============================================================================
module tb_gw_eth_dma;
    localparam TX_BASE = 32'h0000_0000;
    localparam RX_BASE = 32'h0000_8000;
    localparam FLEN    = 32;

    reg mac_clk = 0; always #4  mac_clk = ~mac_clk;   // 125 MHz
    reg bus_clk = 0; always #10 bus_clk = ~bus_clk;   //  50 MHz
    reg arst_n = 0;

    // MAC loopback: tx_mac -> rx_mac
    wire        tx_mac_valid, tx_mac_last;
    wire [7:0]  tx_mac_data;
    wire        rx_mac_valid = tx_mac_valid;
    wire [7:0]  rx_mac_data  = tx_mac_data;
    wire        rx_mac_last  = tx_mac_last;
    wire        tx_mac_ready = 1'b1;

    // EXTS (CSR) AHB master driven by the tb
    reg  [31:0] s_haddr = 0, s_hwdata = 0;
    reg  [1:0]  s_htrans = 0;
    reg         s_hwrite = 0, s_hsel = 0;
    wire [31:0] s_hrdata;
    wire        s_hready, s_hresp;

    // EXTM master ports + arbiter + DRAM
    wire [31:0] m0_haddr, m0_hwdata, m0_hrdata, m1_haddr, m1_hwdata, m1_hrdata;
    wire [1:0]  m0_htrans, m1_htrans;
    wire        m0_hwrite, m0_hready, m0_hresp, m0_busy, m1_hwrite, m1_hready, m1_hresp, m1_busy;
    wire [2:0]  m0_hsize, m0_hburst, m1_hsize, m1_hburst;
    wire [31:0] e_haddr, e_hwdata, e_hrdata;
    wire [1:0]  e_htrans; wire e_hwrite, e_hready, e_hresp; wire [2:0] e_hsize, e_hburst;

    wire        irq; wire [2:0] eth_mode;
    wire [4:0]  miim_phyad, miim_regad; wire [15:0] miim_wrdata; wire miim_wren, miim_rden;

    gw_eth_dma_core dut (
        .rx_mac_clk(mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(1'b0),
        .tx_mac_clk(mac_clk), .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data),
        .tx_mac_last(tx_mac_last), .tx_mac_ready(tx_mac_ready),
        .bus_clk(bus_clk), .arst_n(arst_n),
        .s_haddr(s_haddr), .s_htrans(s_htrans), .s_hwrite(s_hwrite), .s_hsel(s_hsel),
        .s_hready_in(1'b1), .s_hwdata(s_hwdata), .s_hrdata(s_hrdata), .s_hready(s_hready), .s_hresp(s_hresp),
        .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite), .m0_hsize(m0_hsize),
        .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata), .m0_hrdata(m0_hrdata), .m0_hready(m0_hready),
        .m0_hresp(m0_hresp), .m0_busy(m0_busy),
        .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite), .m1_hsize(m1_hsize),
        .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata), .m1_hrdata(m1_hrdata), .m1_hready(m1_hready),
        .m1_hresp(m1_hresp), .m1_busy(m1_busy),
        .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
        .miim_wren(miim_wren), .miim_rden(miim_rden), .miim_rddata(16'b0),
        .miim_rddata_valid(1'b0), .miim_busy(1'b0), .irq(irq), .eth_mode(eth_mode)
    );

    ahb_arbiter_beh arb (
        .m0_busy(m0_busy), .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite),
        .m0_hsize(m0_hsize), .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata),
        .m0_hrdata(m0_hrdata), .m0_hready(m0_hready), .m0_hresp(m0_hresp),
        .m1_busy(m1_busy), .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite),
        .m1_hsize(m1_hsize), .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata),
        .m1_hrdata(m1_hrdata), .m1_hready(m1_hready), .m1_hresp(m1_hresp),
        .haddr(e_haddr), .htrans(e_htrans), .hwrite(e_hwrite), .hsize(e_hsize), .hburst(e_hburst),
        .hwdata(e_hwdata), .hrdata(e_hrdata), .hready(e_hready), .hresp(e_hresp)
    );
    ahb_slave_ram #(.AW(14)) dram (
        .hclk(bus_clk), .hresetn(arst_n), .haddr(e_haddr), .htrans(e_htrans), .hwrite(e_hwrite),
        .hsize(e_hsize), .hburst(e_hburst), .hwdata(e_hwdata), .hrdata(e_hrdata),
        .hready(e_hready), .hresp(e_hresp)
    );

    function [7:0] pat(input integer i); pat = 8'h10 + i; endfunction

    task ahb_write(input [31:0] addr, input [31:0] data);
        begin
            @(negedge bus_clk); s_haddr=addr; s_htrans=2'b10; s_hwrite=1; s_hsel=1;
            @(negedge bus_clk); s_haddr=0; s_htrans=2'b00; s_hwrite=0; s_hsel=0; s_hwdata=data;
            @(negedge bus_clk); s_hwdata=0;
        end
    endtask

    integer i, w, j, errors;
    reg [31:0] word;
    initial begin
        errors = 0;
        // pre-load the TX frame at TX ring buffer 0
        dram.mem[TX_BASE>>2] = {16'b0, FLEN[15:0]};           // header {len}
        for (w = 0; w < ((FLEN+3)>>2); w = w + 1) begin
            word = 0;
            for (j = 0; j < 4; j = j + 1) if (w*4+j < FLEN) word[j*8 +: 8] = pat(w*4+j);
            dram.mem[(TX_BASE + 4 + w*4) >> 2] = word;
        end

        arst_n = 0;
        #500 arst_n = 1;
        #2000;
        // program rings
        ahb_write(32'h10, RX_BASE);   // RX_BASE
        ahb_write(32'h14, 32'd4);     // RX_LEN
        ahb_write(32'h30, TX_BASE);   // TX_BASE
        ahb_write(32'h34, 32'd4);     // TX_LEN
        ahb_write(32'h00, 32'h3);     // CTRL rx_en|tx_en
        ahb_write(32'h38, 32'd1);     // TX_TAIL = 1  (queue the frame)

        // wait for the looped-back frame to land in the RX ring
        fork
            begin wait (dut.u_rx.rx_head == 16'd1); end
            begin #200000; end
        join_any
        repeat (20) @(posedge bus_clk);

        if (dut.u_rx.rx_head !== 16'd1) begin
            errors = errors + 1; $display("  rx_head=%0d (frame did not loop back)", dut.u_rx.rx_head);
        end else begin
            // check the RX ring buffer 0: header + data
            if (dram.mem[RX_BASE>>2] !== {16'b0, FLEN[15:0]}) begin
                errors = errors + 1;
                $display("  RX header got %08x exp %08x", dram.mem[RX_BASE>>2], {16'b0, FLEN[15:0]});
            end
            for (i = 0; i < FLEN; i = i + 1) begin
                if (dram.mem[(RX_BASE+4+i)>>2][(i%4)*8 +: 8] !== pat(i)) begin
                    errors = errors + 1;
                    if (errors < 8) $display("  RX byte %0d got %02x exp %02x", i,
                        dram.mem[(RX_BASE+4+i)>>2][(i%4)*8 +: 8], pat(i));
                end
            end
        end
        if (errors == 0) $display("RESULT: PASS (frame round-tripped CPU->TX->MAC-loop->RX->CPU; tx_head=%0d)", dut.u_tx.tx_head);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #400000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
