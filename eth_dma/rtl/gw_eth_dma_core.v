`default_nettype none
//============================================================================
// gw_eth_dma_core.v -- Ethernet DMA engine core (no MAC, no arbiter).
//
//   csr (EXTS slave)  --config-->  rx_path (master0, write) + tx_path (master1, read)
//   MAC stream ports (rx_mac_*, tx_mac_*) connect to the encrypted Gowin TSE MAC
//   in ae350_demo.v.  The two AHB master ports (m0_*, m1_*) go to the Gowin
//   AHBBusArbiter (synth) or the behavioral arbiter (sim) -> EXTM -> DRAM.
//============================================================================
module gw_eth_dma_core (
    // MAC RX stream (rx_mac_clk)
    input  wire        rx_mac_clk,
    input  wire        rx_mac_valid,
    input  wire [7:0]  rx_mac_data,
    input  wire        rx_mac_last,
    input  wire        rx_mac_error,
    // MAC TX stream (tx_mac_clk)
    input  wire        tx_mac_clk,
    output wire        tx_mac_valid,
    output wire [7:0]  tx_mac_data,
    output wire        tx_mac_last,
    input  wire        tx_mac_ready,
    // bus domain
    input  wire        bus_clk,
    input  wire        arst_n,
    // EXTS slave (CSR, from CPU)
    input  wire [31:0] s_haddr,
    input  wire [1:0]  s_htrans,
    input  wire        s_hwrite,
    input  wire        s_hsel,
    input  wire        s_hready_in,
    input  wire [31:0] s_hwdata,
    output wire [31:0] s_hrdata,
    output wire        s_hready,
    output wire        s_hresp,
    // EXTM master 0 (RX write)
    output wire [31:0] m0_haddr,  output wire [1:0] m0_htrans, output wire m0_hwrite,
    output wire [2:0]  m0_hsize,  output wire [2:0] m0_hburst, output wire [31:0] m0_hwdata,
    input  wire [31:0] m0_hrdata, input  wire m0_hready, input wire m0_hresp, output wire m0_busy,
    // EXTM master 1 (TX read)
    output wire [31:0] m1_haddr,  output wire [1:0] m1_htrans, output wire m1_hwrite,
    output wire [2:0]  m1_hsize,  output wire [2:0] m1_hburst, output wire [31:0] m1_hwdata,
    input  wire [31:0] m1_hrdata, input  wire m1_hready, input wire m1_hresp, output wire m1_busy,
    // MDIO to MAC management
    output wire [4:0]  miim_phyad, output wire [4:0] miim_regad, output wire [15:0] miim_wrdata,
    output wire        miim_wren,  output wire miim_rden,
    input  wire [15:0] miim_rddata, input wire miim_rddata_valid, input wire miim_busy,
    // status
    output wire        irq,
    output wire [2:0]  eth_mode
);
    wire bus_rstn;
    Reset_Synchronizer #(.EXTRA_DEPTH(0), .RESET_ACTIVE_STATE(0)) rs (
        .receiving_clock(bus_clk), .reset_in(arst_n), .reset_out(bus_rstn)
    );

    wire        rx_en, tx_en, rx_irq, tx_irq, rx_dbg_done, tx_dbg_done;
    wire [31:0] rx_base, tx_base;
    wire [15:0] rx_ring_len, rx_tail, tx_ring_len, tx_tail;
    wire [15:0] rx_head, rx_drop, tx_head, tx_fetch;

    csr u_csr (
        .hclk(bus_clk), .hresetn(bus_rstn),
        .haddr(s_haddr), .htrans(s_htrans), .hwrite(s_hwrite), .hsel(s_hsel),
        .hready_in(s_hready_in), .hwdata(s_hwdata),
        .hrdata(s_hrdata), .hready(s_hready), .hresp(s_hresp),
        .rx_en(rx_en), .rx_base(rx_base), .rx_ring_len(rx_ring_len), .rx_tail(rx_tail),
        .rx_head(rx_head), .rx_drop(rx_drop),
        .tx_en(tx_en), .tx_base(tx_base), .tx_ring_len(tx_ring_len), .tx_tail(tx_tail),
        .tx_head(tx_head), .tx_fetch(tx_fetch),
        .rx_irq_set(rx_irq), .tx_irq_set(tx_irq), .irq(irq),
        .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
        .miim_wren(miim_wren), .miim_rden(miim_rden), .miim_rddata(miim_rddata),
        .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy), .eth_mode(eth_mode),
        .rx_busy(m0_busy), .tx_busy(m1_busy), .rx_done(rx_dbg_done), .tx_done(tx_dbg_done)
    );

    rx_path u_rx (
        .rx_mac_clk(rx_mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .bus_clk(bus_clk), .arst_n(arst_n),
        .rx_en(rx_en), .buf_base(rx_base), .ring_len(rx_ring_len), .rx_tail(rx_tail),
        .rx_head(rx_head), .drop_cnt(rx_drop), .irq(rx_irq), .busy(m0_busy), .dbg_done(rx_dbg_done),
        .haddr(m0_haddr), .htrans(m0_htrans), .hwrite(m0_hwrite), .hsize(m0_hsize),
        .hburst(m0_hburst), .hwdata(m0_hwdata), .hrdata(m0_hrdata), .hready(m0_hready), .hresp(m0_hresp)
    );

    tx_path u_tx (
        .tx_mac_clk(tx_mac_clk), .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data),
        .tx_mac_last(tx_mac_last), .tx_mac_ready(tx_mac_ready),
        .bus_clk(bus_clk), .arst_n(arst_n),
        .tx_en(tx_en), .buf_base(tx_base), .ring_len(tx_ring_len), .tx_tail(tx_tail),
        .tx_head(tx_head), .tx_fetch(tx_fetch), .tx_irq(tx_irq), .busy(m1_busy), .dbg_done(tx_dbg_done),
        .haddr(m1_haddr), .htrans(m1_htrans), .hwrite(m1_hwrite), .hsize(m1_hsize),
        .hburst(m1_hburst), .hwdata(m1_hwdata), .hrdata(m1_hrdata), .hready(m1_hready), .hresp(m1_hresp)
    );
endmodule
`default_nettype wire
