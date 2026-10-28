`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_eth_core.v -- FULL Ethernet core simulation with the REAL Gowin TSE MAC
// (ref-design gate-level .vo + gw5a prim_sim).  Path under test:
//   CPU(CSR) -> DRAM -> tx_path DMA -> MAC TX -> RGMII loopback -> MAC RX
//            -> rx_path DMA -> DRAM -> CPU
// through the custom eth_ahb_arbiter + extm_bridge + a 64-bit DRAM model.
// No SoC, no PHY: the RGMII is wire-looped (MAC's internal IODELAY handles
// timing) and MDIO is unused (loopback is always active).
//============================================================================
module tb_eth_core;
    reg bus_clk = 0; always #10 bus_clk = ~bus_clk;   // 50 MHz (EXTS / DMA bus)
    reg gtx_clk = 0; always #4  gtx_clk = ~gtx_clk;   // 125 MHz (MAC GTX, 1000M)
    reg arst_n = 1;   // start high so the 1->0 pulse below is a real negedge

    GSR GSR (.GSRI(1'b1));

    // ---- MAC <-> DMA core streams + MDIO ----
    wire        rx_mac_clk, rx_mac_valid, rx_mac_last, rx_mac_error;
    wire [7:0]  rx_mac_data;
    wire        tx_mac_clk, tx_mac_valid, tx_mac_last, tx_mac_ready;
    wire [7:0]  tx_mac_data;
    wire [4:0]  miim_phyad, miim_regad;
    wire [15:0] miim_wrdata, miim_rddata;
    wire        miim_wren, miim_rden, miim_rddata_valid, miim_busy;
    wire [2:0]  eth_mode;
    wire        irq;

    // ---- RGMII (wire loopback, RGMII-ID: delay RXC ~2ns to center-sample data) ----
    wire        rgmii_txc, rgmii_tx_ctl;  wire [3:0] rgmii_txd;
    wire        rgmii_rxc;  assign #4 rgmii_rxc = rgmii_txc;   // ref PHY model delays RXC by half-period
    wire        rgmii_rx_ctl = rgmii_tx_ctl;
    wire [3:0]  rgmii_rxd  = rgmii_txd;
    // RGMII activity counters: did the MAC drive TX? is the RX clock running? did RX produce data?
    integer txctl = 0, rxval = 0, rxclk = 0, lastcnt = 0, m0cnt = 0;
    always @(posedge rgmii_txc)  if (rgmii_tx_ctl === 1'b1) txctl = txctl + 1;
    always @(posedge rx_mac_clk) begin rxclk = rxclk + 1;
        if (rx_mac_valid === 1'b1) rxval = rxval + 1;
        if (rx_mac_valid === 1'b1 && rx_mac_last === 1'b1) lastcnt = lastcnt + 1; end
    always @(posedge bus_clk) if (m0_busy === 1'b1) m0cnt = m0cnt + 1;
    // confirm root cause: count real rx_capture pushes (frame_valid) before meta_valid first asserts
    integer fvcnt = 0;  reg seen_mv = 0;
    always @(posedge rx_mac_clk) if (u_core.u_rx.frame_valid === 1'b1) fvcnt = fvcnt + 1;
    always @(posedge bus_clk) if (!seen_mv && u_core.u_rx.meta_valid === 1'b1) begin
        seen_mv <= 1'b1;
        $display("  >>> meta_valid FIRST high: real_pushes(fvcnt)=%0d meta_out=%05x in_clear=%b out_clear=%b",
                 fvcnt, u_core.u_rx.meta_out, u_core.u_rx.in_clear, u_core.u_rx.out_clear);
    end

    // ---- speed from CSR eth_mode (00=10 01=100 10=1000, [2]=FD) ----
    wire        speedis1000 = (eth_mode[1:0] == 2'b10);
    wire        speedis10   = (eth_mode[1:0] == 2'b00);
    wire        duplex_status = eth_mode[2];

    // ---- EXTS slave (CSR) driven by the tb ----
    reg  [31:0] s_haddr = 0, s_hwdata = 0;  reg [1:0] s_htrans = 0;  reg s_hwrite = 0, s_hsel = 0;
    wire [31:0] s_hrdata;  wire s_hready, s_hresp;

    // ---- two AHB masters -> arbiter -> bridge -> 64-bit DRAM ----
    wire [31:0] m0_haddr, m1_haddr, m1_hwdata, m1_hrdata;
    wire [63:0] m0_hwdata, m0_hrdata;
    wire [1:0]  m0_htrans, m1_htrans;
    wire        m0_hwrite, m0_hready, m0_hresp, m0_busy, m1_hwrite, m1_hready, m1_hresp, m1_busy;
    wire [2:0]  m0_hsize, m0_hburst, m1_hsize, m1_hburst;
    wire [31:0] ah;
    wire [63:0] awd, ard;    // merged arbiter bus is 64-bit
     wire [1:0] at;  wire aw, ardy, ars, aact;  wire [2:0] asz, abt;
    wire [31:0] eh, ewd;  wire [63:0] e64wd, e64rd;  wire [1:0] et;  wire ew, ehsel, ehrdy_in, ehrdyout, ehresp;
    wire [2:0]  esz, ebt;  wire [3:0] eprot;
    wire [3:0]  dbg_extm = {ehresp, ehrdyout, et[1], ehsel};

    gw_eth_dma_core u_core (
        .rx_mac_clk(rx_mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .tx_mac_clk(tx_mac_clk), .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data),
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
        .miim_wren(miim_wren), .miim_rden(miim_rden), .miim_rddata(miim_rddata),
        .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy),
        .irq(irq), .eth_mode(eth_mode), .dbg_extm(dbg_extm));

    mac u_mac (
        .rgmii_rxc(rgmii_rxc), .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_rxd(rgmii_rxd),
        .gtx_clk(gtx_clk), .speedis1000(speedis1000), .speedis10(speedis10), .duplex_status(duplex_status),
        .rstn(arst_n),
        .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data), .tx_mac_last(tx_mac_last), .tx_mac_error(1'b0),
        .rx_fcs_fwd_ena(1'b0), .rx_jumbo_ena(1'b0), .tx_fcs_fwd_ena(1'b0),
        .tx_ifg_delay_ena(1'b0), .tx_ifg_delay(8'b0),
        .tx_pause_req(1'b0), .tx_pause_val(16'b0), .tx_pause_source_addr(48'b0),
        .clk(bus_clk), .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
        .miim_wren(miim_wren), .miim_rden(miim_rden), .mdio_in(1'b1),
        .rgmii_txc(rgmii_txc), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txd(rgmii_txd),
        .rx_mac_clk(rx_mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .rx_statistics_valid(), .rx_statistics_vector(),
        .tx_mac_clk(tx_mac_clk), .tx_mac_ready(tx_mac_ready), .tx_collision(), .tx_retransmit(),
        .tx_statistics_valid(), .tx_statistics_vector(), .rx_pause_req(), .rx_pause_val(),
        .miim_rddata(miim_rddata), .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy),
        .mdc(), .mdio_out(), .mdio_oen());

    eth_ahb_arbiter u_arb (.clk(bus_clk), .rstn(arst_n),
        .m0_busy(m0_busy), .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite),
        .m0_hsize(m0_hsize), .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata),
        .m0_hrdata(m0_hrdata), .m0_hready(m0_hready), .m0_hresp(m0_hresp),
        .m1_busy(m1_busy), .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite),
        .m1_hsize(m1_hsize), .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata),
        .m1_hrdata(m1_hrdata), .m1_hready(m1_hready), .m1_hresp(m1_hresp),
        .active(aact), .haddr(ah), .htrans(at), .hwrite(aw), .hsize(asz), .hburst(abt), .hwdata(awd),
        .hrdata(ard), .hready(ardy), .hresp(ars));

    extm_bridge u_br (.hclk(bus_clk), .hresetn(arst_n),
        .a_haddr(ah), .a_htrans(at), .a_hwrite(aw), .a_hsize(asz), .a_hburst(abt), .a_hwdata(awd),
        .a_active(aact), .a_hready_in(ehrdyout), .a_hrdata(ard), .a_hready(ardy), .a_hresp(ars),
        .extm_haddr(eh), .extm_htrans(et), .extm_hwrite(ew), .extm_hsize(esz), .extm_hburst(ebt),
        .extm_hprot(eprot), .extm_hwdata(e64wd), .extm_hsel(ehsel), .extm_hready(ehrdy_in),
        .extm_hrdata(e64rd), .extm_hreadyout(ehrdyout), .extm_hresp(ehresp));

    ahb_slave_ram64 #(.AW(13)) dram (.hclk(bus_clk), .hresetn(arst_n), .haddr(eh), .htrans(et),
        .hwrite(ew), .hsize(esz), .hburst(ebt), .hwdata(e64wd), .hsel(ehsel), .hready_in(ehrdy_in),
        .hrdata(e64rd), .hready(ehrdyout), .hresp(ehresp));

    localparam RXB = 32'h00001000, TXB = 32'h00002000, FLEN = 64;
    function [7:0] pat(input integer i); pat = (i < 6) ? 8'hFF : (8'h10 + i[7:0]); endfunction
    // write a 32-bit word at byte address `a` into the 64-bit DRAM lane
    task ram_w32(input [31:0] a, input [31:0] v); dram.mem[a[15:3]][a[2]*32 +: 32] = v; endtask
    function [31:0] ram_r32(input [31:0] a); ram_r32 = dram.mem[a[15:3]][a[2]*32 +: 32]; endfunction

    task ahb_write(input [31:0] addr, input [31:0] data);
        begin @(negedge bus_clk); s_haddr=addr; s_htrans=2'b10; s_hwrite=1; s_hsel=1;
              @(negedge bus_clk); s_haddr=0; s_htrans=0; s_hwrite=0; s_hsel=0; s_hwdata=data;
              @(negedge bus_clk); s_hwdata=0; end
    endtask

    integer i, w, j, errors;  reg [31:0] word;
    initial begin
        errors = 0;
        // build TX frame in DRAM: word0 = len, then data
        ram_w32(TXB, FLEN);
        for (w = 0; w < ((FLEN+3)/4); w = w + 1) begin
            word = 0; for (j=0;j<4;j=j+1) if (w*4+j<FLEN) word[j*8 +: 8] = pat(w*4+j);
            ram_w32(TXB + 4 + w*4, word);
        end
        #20 arst_n = 0; #600 arst_n = 1; repeat (40) @(posedge bus_clk);  // clean 1->0->1 reset pulse
        ahb_write(32'h60, 32'd6);          // ETH_MODE = 1000M FD
        ahb_write(32'h10, RXB); ahb_write(32'h14, 32'd4); ahb_write(32'h18, 0);  // RX ring
        ahb_write(32'h30, TXB); ahb_write(32'h34, 32'd4);                        // TX ring
        ahb_write(32'h00, 32'h3);          // rx_en | tx_en
        ahb_write(32'h38, 32'd1);          // TX_TAIL = 1 (queue the frame)
        // wait for the frame to loop back (with progress)
        begin: w8 integer k; for (k=0;k<12000;k=k+1) begin @(posedge bus_clk);
              if (k % 2000 == 0) begin
                $display("  k=%0d txh=%0d rxh=%0d drop=%0d txctl=%0d rxval=%0d last=%0d m0=%0d rxhdr=%08x",
                  k, u_core.u_tx.tx_head, u_core.u_rx.rx_head, u_core.u_rx.drop_cnt,
                  txctl, rxval, lastcnt, m0cnt, ram_r32(RXB));
                $display("    grant=%0d m0busy=%b m1busy=%b | merged htrans=%b hwrite=%b active=%b hready=%b | ehsel=%b ehwrite=%b ehrdyout=%b m0addr=%08x",
                  u_arb.grant, m0_busy, m1_busy, at, aw, aact, ardy, ehsel, ew, ehrdyout, m0_haddr);
              end
              if (u_core.u_rx.rx_head != 0) disable w8; end end
        repeat (50) @(posedge bus_clk);
        $display("RESULT: RX hdr=%08x d0=%08x d1=%08x | txctl=%0d rxval=%0d", ram_r32(RXB), ram_r32(RXB+4), ram_r32(RXB+8), txctl, rxval);
        begin : chk integer bad; reg [7:0] g,e; bad = ((ram_r32(RXB) & 16'hFFFF) != FLEN);
            for (i=0;i<FLEN;i=i+1) begin g = ram_r32(RXB+4+(i/4)*4) >> ((i%4)*8); e = pat(i);
                if (g[7:0] !== e) bad = bad + 1; end
            if (bad==0) $display("RESULT: PASS (frame DMA->MAC->RGMII-loopback->MAC->DMA intact, len=%0d)", FLEN);
            else $display("RESULT: FAIL (%0d byte/len mismatches; RX len=%0d)", bad, ram_r32(RXB)&16'hFFFF); end
        $finish;
    end
    initial begin #4000000; $display("RESULT: FAIL (timeout; RX hdr=%08x)", ram_r32(RXB)); $finish; end
endmodule
`default_nettype wire
