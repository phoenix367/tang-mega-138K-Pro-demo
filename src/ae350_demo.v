
// ae350_demo_top
module ae350_demo_top
(
    input CLK,
    input RSTN,
    // GPIO
    inout [2:0] LED,     // 2:0
    inout [2:0] KEY,     // 5:3
    // UART2
    output UART2_TXD,
    input  UART2_RXD,
    // SPI Flash Memory
    inout FLASH_SPI_CSN,
    inout FLASH_SPI_MISO,
    inout FLASH_SPI_MOSI,
    inout FLASH_SPI_CLK,
    inout FLASH_SPI_HOLDN,
    inout FLASH_SPI_WPN,
    // DDR3 Memory
    output DDR3_INIT,
    output [2:0] DDR3_BANK,
    output DDR3_CS_N,
    output DDR3_RAS_N,
    output DDR3_CAS_N,
    output DDR3_WE_N,
    output DDR3_CK,
    output DDR3_CK_N,
    output DDR3_CKE,
    output DDR3_RESET_N,
    output DDR3_ODT,
    output [13:0] DDR3_ADDR,
    output [1:0] DDR3_DM,
    inout [15:0] DDR3_DQ,
    inout [1:0] DDR3_DQS,
    inout [1:0] DDR3_DQS_N,
    // JTAG
    input TCK_IN,
    input TMS_IN,
    input TRST_IN,
    input TDI_IN,
    output TDO_OUT,
    // Ethernet RGMII (Gowin Triple-Speed MAC -> board RTL8211-class PHY)
    output PHY_CLK,             // 25 MHz reference clock to the PHY
    output PHY_RST_N,
    output RGMII_TXC,
    output RGMII_TX_CTL,
    output [3:0] RGMII_TXD,
    input  RGMII_RXC,
    input  RGMII_RX_CTL,
    input  [3:0] RGMII_RXD,
    output MDC,
    inout  MDIO,
    output [1:0] DBG            // EXTM probe: {hreadyout, hsel} (W21/P21 are JTAG)
);


wire CORE_CLK;
wire DDR_CLK;
wire AHB_CLK;
wire APB_CLK;
wire RTC_CLK;

wire DDR3_MEMORY_CLK;
wire DDR3_CLK_IN;
wire DDR3_LOCK;
wire DDR3_STOP;


// Gowin_PLL_AE350 instantiation
Gowin_PLL_AE350 u_Gowin_PLL_AE350
(
    .clkout0(DDR_CLK),          // 50MHz    - for test
    .clkout1(CORE_CLK),         // 800MHz
    .clkout2(AHB_CLK),          // 50MHz    - for test
    .clkout3(APB_CLK),          // 50MHz    - for test
    .clkout4(RTC_CLK),          // 10MHz
    .clkin(CLK),
    .enclk0(1'b1),
    .enclk1(1'b1),
    .enclk2(1'b1),
    .enclk3(1'b1),
    .enclk4(1'b1)
);


// Gowin_PLL_DDR3 instantiation
Gowin_PLL_DDR3 u_Gowin_PLL_DDR3
(
    .lock(DDR3_LOCK),
    .clkout0(DDR3_CLK_IN),          // 50MHz
    .clkout2(DDR3_MEMORY_CLK),      // 200MHz   - for test
    .clkin(CLK),
    .reset(1'b0),                   // Enforce
    .enclk0(1'b1),
    .enclk2(DDR3_STOP)
);


// (SD support removed -- no SD PLL / external APB peripheral.)

// Customized data-memory AHB bus: AE350 SoC master -> gw_ahb_ddr3_top slave.
// (DDR3 controller is now external to the SoC; see gw_ahb_ddr3_top below.)
wire [63:0] DDR_HRDATA, DDR_HWDATA;
wire [31:0] DDR_HADDR;
wire [3:0]  DDR_HPROT;
wire [2:0]  DDR_HBURST, DDR_HSIZE;
wire [1:0]  DDR_HTRANS;
wire        DDR_HREADY, DDR_HRESP, DDR_HWRITE, DDR_HCLK, DDR_HRSTN;


// ---------------------------------------------------------------------------
// Ethernet: Gowin Triple-Speed MAC + gw_ahb_ethernet bridge on the SoC's
// external AHB *slave* port (EXTS_*, SoC-mastered). Register window at the
// SoC's AHB_EXT base. Clocks: GTX_CLK 125 MHz (RGMII TX) + ETH_CLK 25 MHz
// (PHY reference) from a DEDICATED PLL -- the AE350 core PLL is untouched.
// RGMII RX clock comes from the PHY; AHB register access runs in EXTS_HCLK
// (= AHB_CLK 50 MHz) domain.
// ---------------------------------------------------------------------------
wire GTX_CLK;       // 125 MHz - RGMII TX
wire ETH_CLK;       // 25 MHz  - PHY reference

// SoC external-AHB-slave bus (SoC masters; the MAC bridge is the slave)
wire [31:0] EXTS_HRDATA, EXTS_HADDR, EXTS_HWDATA;
wire [3:0]  EXTS_HPROT;
wire [2:0]  EXTS_HBURST, EXTS_HSIZE;
wire [1:0]  EXTS_HTRANS, eth_hresp;
wire        EXTS_HREADY, EXTS_HSEL, EXTS_HWRITE, EXTS_HCLK, EXTS_HRSTN;

// MAC <-> bridge stream + MIIM interconnect
wire eth_rstn, intr_ethernet, speedis1000, speedis10, duplex_status;
wire tx_mac_clk, tx_mac_valid, tx_mac_last, tx_mac_error, tx_mac_ready;
wire [7:0] tx_mac_data;
wire tx_collision, tx_retransmit, tx_pause_req, tx_statistics_valid;
wire [15:0] tx_pause_val;
wire [47:0] tx_pause_source_addr;
wire [28:0] tx_statistics_vector;
wire rx_mac_clk, rx_mac_valid, rx_mac_last, rx_mac_error;
wire rx_statistics_valid, rx_pause_req;
wire [7:0] rx_mac_data;
wire [26:0] rx_statistics_vector;
wire [15:0] rx_pause_val;
wire [4:0] miim_phyad, miim_regad;
wire [15:0] miim_wrdata, miim_rddata;
wire miim_wren, miim_rden, miim_rddata_valid, miim_busy;
wire mdio_in, mdio_out, mdio_oen;

// gw_eth_dma: CSR on EXTS; two AHB masters -> arbiter -> extm_bridge -> EXTM(64-bit).
wire [2:0]  eth_mode;
wire [31:0] m0_haddr, m0_hwdata, m0_hrdata, m1_haddr, m1_hwdata, m1_hrdata;
wire [1:0]  m0_htrans, m1_htrans;
wire        m0_hwrite, m0_hready, m0_hresp, m0_busy, m1_hwrite, m1_hready, m1_hresp, m1_busy;
wire [2:0]  m0_hsize, m0_hburst, m1_hsize, m1_hburst;
wire [31:0] arb_haddr, arb_hwdata, arb_hrdata;
wire [1:0]  arb_htrans;
wire        arb_hwrite, arb_hready, arb_hresp, arb_active;
wire [2:0]  arb_hsize, arb_hburst;
wire [31:0] extm_haddr;   wire [1:0] extm_htrans;  wire extm_hwrite;
wire [2:0]  extm_hsize, extm_hburst;   wire [3:0] extm_hprot;
wire [63:0] extm_hwdata, extm_hrdata;
wire        extm_hsel, extm_hready, extm_hreadyout, extm_hresp;

// MAC speed/duplex from the CSR eth_mode (00=10M, 01=100M, 10=1000M; [2]=full-duplex)
assign speedis1000   = (eth_mode[1:0] == 2'b10);
assign speedis10     = (eth_mode[1:0] == 2'b00);
assign duplex_status = eth_mode[2];
// MAC TX-side inputs the DMA engine does not drive
assign tx_mac_error         = 1'b0;
assign tx_pause_req         = 1'b0;
assign tx_pause_val         = 16'b0;
assign tx_pause_source_addr = 48'b0;
assign eth_hresp[1]         = 1'b0;

assign eth_rstn = EXTS_HRSTN;

// EXTM handshake probe -> debug pins (and CSR EXTM_DBG): is the SoC EXTM
// responding to the DMA's AHB read?  {hresp, hreadyout, htrans-active, hsel}
wire [3:0] dbg_extm = {extm_hresp, extm_hreadyout, extm_htrans[1], extm_hsel};
assign DBG = {extm_hreadyout, extm_hsel};   // U16=hsel, U15=hreadyout

// Dedicated Ethernet PLL: clkout1 = 125 MHz (GTX), clkout3 = 25 MHz (PHY ref).
// (Same Gowin_PLL IP as the SDK ae350_ext_ethernet example; VCO 1000 MHz.
//  clkout0/2 = 50/250 MHz are left unused here.)
Gowin_PLL u_Gowin_PLL_ETH
(
    .clkout0(),
    .clkout1(GTX_CLK),          // 125 MHz
    .clkout2(),
    .clkout3(ETH_CLK),          // 25 MHz
    .clkin(CLK),
    .reset(1'b0),
    .enclk0(1'b1),
    .enclk1(1'b1),
    .enclk2(1'b1),
    .enclk3(1'b1)
);


wire ae350_rstn;                    // AE350 power on and hardware reset in
wire ddr3_rstn;                     // DDR3 memory reset in
wire ddr3_init_completed;           // DDR3 memory initialized completed

assign DDR3_INIT = ~ddr3_init_completed;


// key_debounce instantiation
// DDR3 memory reset in key debounce
key_debounce u_key_debounce_ddr3
(
    .out(ddr3_rstn),
    .in(RSTN),
    .clk(CLK),      // 50MHz
    .rstn(1'b1)
);


// key_debounce instantiation
// AE350 power on and hardware reset in key debounce
key_debounce u_key_debounce_ae350
(
    .out(ae350_rstn),
    .in(ddr3_init_completed),
    .clk(CLK),      // 50MHz
    .rstn(1'b1)
);


// RiscV_AE350_SOC_Top instantiation
// Regenerated SoC adds many optional interfaces (external APB/AHB, DMA, EXT_INT,
// I2C, ATCSPI200 SPI master, DDR3 PL read/write lanes). For this MINIMAL-BOOT
// build they are all tied off / left open; SD wiring (SPI master -> card) and
// the external APB come in the next step.
RiscV_AE350_SOC_Top u_RiscV_AE350_SOC_Top
(
    .FLASH_SPI_CSN(FLASH_SPI_CSN),
    .FLASH_SPI_MISO(FLASH_SPI_MISO),
    .FLASH_SPI_MOSI(FLASH_SPI_MOSI),
    .FLASH_SPI_CLK(FLASH_SPI_CLK),
    .FLASH_SPI_HOLDN(FLASH_SPI_HOLDN),
    .FLASH_SPI_WPN(FLASH_SPI_WPN),
    // Customized data memory: the CPU data port now exits as a standard AHB
    // bus (DDR_H*); the gw_ahb_ddr3_top bridge below converts it to DDR3.
    // This forces AMO-on-miss through a normal cache read-allocate, which
    // fixes the embedded-DDR3 AMO-miss hang (atomics now work on DDR).
    .DDR_HRDATA(DDR_HRDATA),
    .DDR_HREADY(DDR_HREADY),
    .DDR_HRESP(DDR_HRESP),
    .DDR_HADDR(DDR_HADDR),
    .DDR_HBURST(DDR_HBURST),
    .DDR_HPROT(DDR_HPROT),
    .DDR_HSIZE(DDR_HSIZE),
    .DDR_HTRANS(DDR_HTRANS),
    .DDR_HWDATA(DDR_HWDATA),
    .DDR_HWRITE(DDR_HWRITE),
    .DDR_HCLK(DDR_HCLK),
    .DDR_HRSTN(DDR_HRSTN),
    .TCK_IN(TCK_IN),
    .TMS_IN(TMS_IN),
    .TRST_IN(TRST_IN),
    .TDI_IN(TDI_IN),
    .TDO_OUT(TDO_OUT),
    .TDO_OE(),
    // External interrupts - Ethernet MAC IRQ on bit 0
    .EXT_INT({15'b0, intr_ethernet}),
    // External AHB slave port -> Ethernet MAC bridge (gw_ahb_ethernet_top)
    .EXTS_HRDATA(EXTS_HRDATA),
    .EXTS_HREADYIN(EXTS_HREADY),
    .EXTS_HRESP(eth_hresp[0]),
    .EXTS_HADDR(EXTS_HADDR),
    .EXTS_HBURST(EXTS_HBURST),
    .EXTS_HPROT(EXTS_HPROT),
    .EXTS_HSEL(EXTS_HSEL),
    .EXTS_HSIZE(EXTS_HSIZE),
    .EXTS_HTRANS(EXTS_HTRANS),
    .EXTS_HWDATA(EXTS_HWDATA),
    .EXTS_HWRITE(EXTS_HWRITE),
    .EXTS_HCLK(EXTS_HCLK),
    .EXTS_HRSTN(EXTS_HRSTN),
    // External AHB master port -> gw_eth_dma DMA (via extm_bridge 32->64)
    .EXTM_HADDR(extm_haddr),
    .EXTM_HBURST(extm_hburst),
    .EXTM_HPROT(extm_hprot),
    .EXTM_HREADY(extm_hready),
    .EXTM_HSEL(extm_hsel),
    .EXTM_HSIZE(extm_hsize),
    .EXTM_HTRANS(extm_htrans),
    .EXTM_HWDATA(extm_hwdata),
    .EXTM_HWRITE(extm_hwrite),
    .EXTM_HRDATA(extm_hrdata),
    .EXTM_HREADYOUT(extm_hreadyout),
    .EXTM_HRESP(extm_hresp),
    // External APB master -> apb_sd_top (SD-SPI HW controller @ CPU 0xF8000000)
    // External APB master - unused (SD removed)
    .APB_PRDATA(32'b0),
    .APB_PREADY(1'b1),
    .APB_PSLVERR(1'b0),
    .APB_PADDR(),
    .APB_PENABLE(),
    .APB_PSEL(),
    .APB_PWDATA(),
    .APB_PWRITE(),
    .APB_PPROT(),
    .APB_PSTRB(),
    .APB_PCLK(),
    .APB_PRSTN(),
    // DMA - unused
    .DMA_REQ(8'b0),
    .DMA_ACK(),
    // On-SoC ATCSPI200 SPI master IOPORT - unused (SD driven by apb_sd_top)
    .SPI_HOLDN(),
    .SPI_WPN(),
    .SPI_CLK(),
    .SPI_CSN(),
    .SPI_MISO(),
    .SPI_MOSI(),
    // I2C - unused
    .I2C_SCL(),
    .I2C_SDA(),
    .UART2_TXD(UART2_TXD),
    .UART2_RTSN(),
    .UART2_RXD(UART2_RXD),
    .UART2_CTSN(1'b0),
    .UART2_DCDN(1'b0),
    .UART2_DSRN(1'b0),
    .UART2_RIN(1'b0),
    .UART2_DTRN(),
    .UART2_OUT1N(),
    .UART2_OUT2N(),
    .GPIO({KEY, LED}),
    .CORE_CLK(CORE_CLK),
    .DDR_CLK(DDR_CLK),
    .AHB_CLK(AHB_CLK),
    .APB_CLK(APB_CLK),
    .RTC_CLK(RTC_CLK),
    .POR_RSTN(ae350_rstn),              // AE350 CPU core power on reset, 0 is reset state
    .HW_RSTN(ae350_rstn)                // AE350 hardware reset, 0 is reset state
);


// AHB -> DDR3 bridge (external DDR3 controller). Turns the SoC's customized
// data-memory AHB bus into DDR3 PHY. Uses our Gowin_PLL_DDR3 clocks and the
// same DDR3 reset/init nets the embedded controller used.
gw_ahb_ddr3_top u_gw_ahb_ddr3_top
(
    .DDR3_MEMORY_CLK(DDR3_MEMORY_CLK),
    .DDR3_CLK_IN(DDR3_CLK_IN),
    .DDR3_RSTN(ddr3_rstn),              // 0 = reset
    .DDR3_LOCK(DDR3_LOCK),
    .DDR3_STOP(DDR3_STOP),
    .DDR3_INIT(ddr3_init_completed),    // initialized completed
    .DDR3_BANK(DDR3_BANK),
    .DDR3_CS_N(DDR3_CS_N),
    .DDR3_RAS_N(DDR3_RAS_N),
    .DDR3_CAS_N(DDR3_CAS_N),
    .DDR3_WE_N(DDR3_WE_N),
    .DDR3_CK(DDR3_CK),
    .DDR3_CK_N(DDR3_CK_N),
    .DDR3_CKE(DDR3_CKE),
    .DDR3_RESET_N(DDR3_RESET_N),
    .DDR3_ODT(DDR3_ODT),
    .DDR3_ADDR(DDR3_ADDR),
    .DDR3_DM(DDR3_DM),
    .DDR3_DQ(DDR3_DQ),
    .DDR3_DQS(DDR3_DQS),
    .DDR3_DQS_N(DDR3_DQS_N),
    // AHB slave <- SoC customized data-memory master
    .HCLK(DDR_HCLK),
    .HRESETN(DDR_HRSTN),
    .HADDR(DDR_HADDR),
    .HSIZE(DDR_HSIZE),
    .HWRITE(DDR_HWRITE),
    .HTRANS(DDR_HTRANS),
    .HBURST(DDR_HBURST),
    .HWDATA(DDR_HWDATA),
    .HREADY_O(DDR_HREADY),
    .HRESP(DDR_HRESP),
    .HRDATA(DDR_HRDATA)
);


// (SD host core removed -- the AE350 external APB is tied off above.)


// ---------------------------------------------------------------------------
// Ethernet MAC (Gowin Triple-Speed) + AHB register/stream bridge.
// EXTS_* (SoC AHB master) <-> gw_ahb_ethernet_top <-> Triple_Speed MAC <-> RGMII.
// ---------------------------------------------------------------------------
gw_eth_dma_core u_gw_eth_dma_core
(
    // MAC RX stream (from the TSE MAC)
    .rx_mac_clk(rx_mac_clk),
    .rx_mac_valid(rx_mac_valid),
    .rx_mac_data(rx_mac_data),
    .rx_mac_last(rx_mac_last),
    .rx_mac_error(rx_mac_error),
    // MAC TX stream (to the TSE MAC)
    .tx_mac_clk(tx_mac_clk),
    .tx_mac_valid(tx_mac_valid),
    .tx_mac_data(tx_mac_data),
    .tx_mac_last(tx_mac_last),
    .tx_mac_ready(tx_mac_ready),
    // bus domain (EXTS register clock)
    .bus_clk(EXTS_HCLK),
    .arst_n(EXTS_HRSTN),
    // EXTS slave: CSR register block @ 0xE8000000
    .s_haddr(EXTS_HADDR),
    .s_htrans(EXTS_HTRANS),
    .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL),
    .s_hready_in(EXTS_HREADY),
    .s_hwdata(EXTS_HWDATA),
    .s_hrdata(EXTS_HRDATA),
    .s_hready(EXTS_HREADY),
    .s_hresp(eth_hresp[0]),
    // EXTM master 0 (RX write)
    .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite), .m0_hsize(m0_hsize),
    .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata), .m0_hrdata(m0_hrdata), .m0_hready(m0_hready),
    .m0_hresp(m0_hresp), .m0_busy(m0_busy),
    // EXTM master 1 (TX read)
    .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite), .m1_hsize(m1_hsize),
    .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata), .m1_hrdata(m1_hrdata), .m1_hready(m1_hready),
    .m1_hresp(m1_hresp), .m1_busy(m1_busy),
    // MDIO management -> TSE MAC
    .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
    .miim_wren(miim_wren), .miim_rden(miim_rden), .miim_rddata(miim_rddata),
    .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy),
    // status
    .irq(intr_ethernet),
    .eth_mode(eth_mode),
    .dbg_extm(dbg_extm)
);

// Custom 2-master AHB arbiter: full 32-bit address space, fixed priority RX>TX.
// (The Gowin AHBBusArbiter only forwards a 0x80000000 register window -- not a
//  DMA fabric; see eth_dma/rtl/eth_ahb_arbiter.v.)
eth_ahb_arbiter u_eth_ahb_arbiter
(
    .clk(EXTS_HCLK), .rstn(EXTS_HRSTN),
    .m0_busy(m0_busy), .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite),
    .m0_hsize(m0_hsize), .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata),
    .m0_hrdata(m0_hrdata), .m0_hready(m0_hready), .m0_hresp(m0_hresp),
    .m1_busy(m1_busy), .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite),
    .m1_hsize(m1_hsize), .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata),
    .m1_hrdata(m1_hrdata), .m1_hready(m1_hready), .m1_hresp(m1_hresp),
    .active(arb_active), .haddr(arb_haddr), .htrans(arb_htrans), .hwrite(arb_hwrite),
    .hsize(arb_hsize), .hburst(arb_hburst), .hwdata(arb_hwdata),
    .hrdata(arb_hrdata), .hready(arb_hready), .hresp(arb_hresp)
);

// 32-bit arbiter master -> 64-bit SoC EXTM slave port
extm_bridge u_extm_bridge
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .a_haddr(arb_haddr), .a_htrans(arb_htrans), .a_hwrite(arb_hwrite), .a_hsize(arb_hsize),
    .a_hburst(arb_hburst), .a_hwdata(arb_hwdata), .a_active(arb_active), .a_hready_in(extm_hreadyout),
    .a_hrdata(arb_hrdata), .a_hready(arb_hready), .a_hresp(arb_hresp),
    .extm_haddr(extm_haddr), .extm_htrans(extm_htrans), .extm_hwrite(extm_hwrite),
    .extm_hsize(extm_hsize), .extm_hburst(extm_hburst), .extm_hprot(extm_hprot),
    .extm_hwdata(extm_hwdata), .extm_hsel(extm_hsel), .extm_hready(extm_hready),
    .extm_hrdata(extm_hrdata), .extm_hreadyout(extm_hreadyout), .extm_hresp(extm_hresp)
);

Triple_Speed_Ethernet_MAC_Top u_Triple_Speed_Ethernet_MAC_Top
(
    .rgmii_rxc(RGMII_RXC),
    .rgmii_rx_ctl(RGMII_RX_CTL),
    .rgmii_rxd(RGMII_RXD),
    .gtx_clk(GTX_CLK),
    .rgmii_txc(RGMII_TXC),
    .rgmii_tx_ctl(RGMII_TX_CTL),
    .rgmii_txd(RGMII_TXD),
    .speedis1000(speedis1000),
    .speedis10(speedis10),
    .duplex_status(duplex_status),
    .rstn(eth_rstn),
    .rx_mac_clk(rx_mac_clk),
    .rx_mac_valid(rx_mac_valid),
    .rx_mac_data(rx_mac_data),
    .rx_mac_last(rx_mac_last),
    .rx_mac_error(rx_mac_error),
    .rx_statistics_valid(rx_statistics_valid),
    .rx_statistics_vector(rx_statistics_vector),
    .rx_pause_req(rx_pause_req),
    .rx_pause_val(rx_pause_val),
    .tx_mac_clk(tx_mac_clk),
    .tx_mac_valid(tx_mac_valid),
    .tx_mac_data(tx_mac_data),
    .tx_mac_last(tx_mac_last),
    .tx_mac_error(tx_mac_error),
    .tx_mac_ready(tx_mac_ready),
    .tx_collision(tx_collision),
    .tx_retransmit(tx_retransmit),
    .tx_pause_req(tx_pause_req),
    .tx_pause_val(tx_pause_val),
    .tx_pause_source_addr(tx_pause_source_addr),
    .tx_statistics_valid(tx_statistics_valid),
    .tx_statistics_vector(tx_statistics_vector),
    .rx_fcs_fwd_ena(1'b0),
    .rx_jumbo_ena(1'b0),
    .tx_fcs_fwd_ena(1'b0),
    .tx_ifg_delay_ena(1'b0),
    .tx_ifg_delay(8'b0),
    .clk(EXTS_HCLK),
    .miim_phyad(miim_phyad),
    .miim_regad(miim_regad),
    .miim_wrdata(miim_wrdata),
    .miim_wren(miim_wren),
    .miim_rden(miim_rden),
    .miim_rddata(miim_rddata),
    .miim_rddata_valid(miim_rddata_valid),
    .miim_busy(miim_busy),
    .mdc(MDC),
    .mdio_in(mdio_in),
    .mdio_out(mdio_out),
    .mdio_oen(mdio_oen)
);

assign mdio_in   = MDIO;
assign MDIO      = (!mdio_oen) ? mdio_out : 1'bz;
assign PHY_CLK   = ETH_CLK;
assign PHY_RST_N = RSTN;

endmodule