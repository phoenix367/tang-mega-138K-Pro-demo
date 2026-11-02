
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
    output [14:0] DDR3_ADDR,    // DRAM row address, 15 bits (4 Gbit x16 chips)
    output [3:0] DDR3_DM,       // 32-bit bus: both x16 chips (1 GB)
    inout [31:0] DDR3_DQ,
    inout [3:0] DDR3_DQS,
    inout [3:0] DDR3_DQS_N,
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
    // RGB LCD: Sipeed 5" 800x480 panel, DE mode, RGB666
    output LCD_CLK,
    output LCD_DE,
    output [5:0] LCD_R,
    output [5:0] LCD_G,
    output [5:0] LCD_B,
    // Audio: PT8211 stereo DAC (headphone jack / speaker), 16-bit LSB-justified
    output I2S_BCK,
    output I2S_LRCK,
    output I2S_DIN,
    output PA_EN,               // headphone amplifier (XPT4809) enable, active high
    // Fan header (Dock M1 Fan_CPU_4pin): PWM out, tacho in (10k pull-up on the Dock)
    output FAN_PWM,
    input  FAN_TACH,
    // microSD slot (Dock J19), native SD bus: CLK, CMD, DAT[3:0], card detect
    output SD_CLK,
    inout  SD_CMD,
    inout  [3:0] SD_DAT,
    input  SD_DET,
    // Board control lines (gpio_core @ 0xE8010000, Linux gpio-mmio + i2c-gpio):
    // the Dock's SYS_TWI bus, its 8-way TWI mux select, the EEPROM write protect
    inout  SYS_SCL,
    inout  SYS_SDA,
    inout  [2:0] TWI_SEL,
    inout  EEPROM_WP,
    output [1:0] DBG            // EXTM probe: {hreadyout, hsel} (W21/P21 are JTAG)
);


wire CORE_CLK;
// DDR_CLK (the SoC's data-memory bus clock) is the DDR3 IP's user clock
// (ddr_vclk, memory clock / 4 = 100 MHz) since Build 64, so the bridge's two
// sides are one clock and its FIFOs need no synchronizers.  The SoC comes out
// of reset only after DDR3 calibration, long after that clock is running.
// Since Build 65 the DDR3 IP's 50 MHz reference input is the board oscillator
// CLK itself (IPUG281: "generally PCB crystal input"), so PLL_DDR3 CLKOUT0 is
// unused. APB_CLK must keep its own PLL output (CLKOUT3), even though it is
// 1:1 with AHB_CLK: driving both SoC clock pins from the AHB_CLK net (tried
// first for Build 65, as Gowin's ae350_ahb_master example does) makes the
// PLIC drop interrupt completions for the audio core's level interrupt --
// the source stays claimed after a few interrupts until an explicit
// completion write, which a manual completion every 100 ms proved (then the
// stream plays bit-exact). See doc/06-key-findings.md.
wire AHB_CLK;
wire APB_CLK;
wire RTC_CLK;

wire DDR3_MEMORY_CLK;
wire DDR3_LOCK;
wire DDR3_STOP;


// Gowin_PLL_AE350 instantiation
Gowin_PLL_AE350 u_Gowin_PLL_AE350
(
    .clkout0(),                 // 100MHz (800/8), unused since Build 64: DDR_CLK is the DDR3 IP user clock
    .clkout1(CORE_CLK),         // 800MHz
    .clkout2(AHB_CLK),          // 50MHz AHB bus clock
    .clkout3(APB_CLK),          // 50MHz APB bus clock (its own output: see above)
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
    .clkout0(),                     // 50MHz, unused since Build 65: the DDR3 IP reference is CLK
    .clkout2(DDR3_MEMORY_CLK),      // 400MHz memory clock
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

// External APB slave port (SoC master) -> ddr_perf monitor @ 0xF8000000
wire [31:0] apb_paddr, apb_pwdata, apb_prdata;
wire        apb_psel, apb_penable, apb_pwrite, apb_pready, apb_pslverr;
wire        apb_pclk, apb_prstn;


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
wire ETH_PLL_LOCK;
wire VID_CLK;       // 33.3 MHz - LCD pixel clock

// DDR bridge video read port (DDR3 user clock) -> LCD video core
wire         ddr_vclk, ddr_vrstn, ddr_v_req, ddr_v_ack, ddr_v_rvalid;
wire [31:0]  ddr_v_addr;
wire [255:0] ddr_v_rdata;

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
wire [31:0] m0_haddr, m1_haddr, m1_hwdata, m1_hrdata;
wire [63:0] m0_hwdata, m0_hrdata;      // RX DMA master: 64-bit beats
wire [1:0]  m0_htrans, m1_htrans;
wire        m0_hwrite, m0_hready, m0_hresp, m0_busy, m1_hwrite, m1_hready, m1_hresp, m1_busy;
wire [2:0]  m0_hsize, m0_hburst, m1_hsize, m1_hburst;
wire [31:0] arb_haddr;
wire [63:0] arb_hwdata, arb_hrdata;
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

// EXTS register window: 0xE8000000 gw_eth_dma CSRs, 0xE8001000 LCD video core,
// 0xE8002000 audio core, 0xE8004000 temperature/voltage sensor core,
// 0xE8008000 fan PWM/tacho, 0xE8010000 board GPIO (SYS_TWI bit-bang, TWI mux,
// EEPROM WP), 0xE8020000 microSD host (native 4-bit, DMA).
// All slaves are zero-wait; the data phase is muxed by the select registered
// at the accepted address phase.
wire        exts_sd  = EXTS_HADDR[17];
wire        exts_gpo = EXTS_HADDR[16] & ~EXTS_HADDR[17];
wire        exts_fan = EXTS_HADDR[15] & ~EXTS_HADDR[16] & ~EXTS_HADDR[17];
wire        exts_sen = EXTS_HADDR[14] & ~EXTS_HADDR[15] & ~EXTS_HADDR[16] & ~EXTS_HADDR[17];
wire        exts_aud = EXTS_HADDR[13] & ~EXTS_HADDR[14] & ~EXTS_HADDR[15] & ~EXTS_HADDR[16] & ~EXTS_HADDR[17];
wire        exts_vid = EXTS_HADDR[12] & ~EXTS_HADDR[13] & ~EXTS_HADDR[14] & ~EXTS_HADDR[15] & ~EXTS_HADDR[16] & ~EXTS_HADDR[17];
reg         exts_vid_d, exts_aud_d, exts_sen_d, exts_fan_d, exts_gpo_d, exts_sd_d;
wire [31:0] eth_s_hrdata, vid_s_hrdata, aud_s_hrdata, sen_s_hrdata, fan_s_hrdata, gpo_s_hrdata, sd_s_hrdata;
wire        eth_s_hready, vid_s_hready, eth_s_hresp, vid_s_hresp;
wire        aud_s_hready, aud_s_hresp, intr_audio, sen_s_hready, sen_s_hresp;
wire        fan_s_hready, fan_s_hresp, gpo_s_hready, gpo_s_hresp, sd_s_hready, sd_s_hresp;
wire [5:0]  gpo_i, gpo_o, gpo_oe;
wire        sd_m_busy, sd_m_hwrite, sd_m_hready, sd_m_hresp;
wire [31:0] sd_m_haddr;
wire [1:0]  sd_m_htrans;
wire [2:0]  sd_m_hsize, sd_m_hburst;
wire [63:0] sd_m_hwdata, sd_m_hrdata;
wire        au_m_busy, au_m_hwrite, au_m_hready, au_m_hresp;   // audio DMA (arbiter master 3)
wire [31:0] au_m_haddr;
wire [1:0]  au_m_htrans;
wire [2:0]  au_m_hsize, au_m_hburst;
wire [63:0] au_m_hwdata, au_m_hrdata;
wire        sd_cmd_o, sd_cmd_oe, sd_dat_oe, sd_dat_oe_hi, intr_sd;
wire [3:0]  sd_dat_o;
always @(posedge EXTS_HCLK or negedge EXTS_HRSTN)
    if (!EXTS_HRSTN) begin
        exts_vid_d <= 1'b0; exts_aud_d <= 1'b0; exts_sen_d <= 1'b0; exts_fan_d <= 1'b0; exts_gpo_d <= 1'b0; exts_sd_d <= 1'b0;
    end else if (EXTS_HSEL && EXTS_HTRANS[1] && EXTS_HREADY) begin
        exts_vid_d <= exts_vid; exts_aud_d <= exts_aud; exts_sen_d <= exts_sen; exts_fan_d <= exts_fan; exts_gpo_d <= exts_gpo; exts_sd_d <= exts_sd;
    end
// Read data goes to the SoC through a register, with one wait state per read:
// the slaves' read muxes sit all over the die and the combinational route to
// the EXTS_HRDATA pins of the hard SoC was the 50 MHz domain's longest path
// (20.6 ns, mostly wire).  Writes keep their zero wait states.  The slaves
// hold their read data while HREADY is low (their address registers advance
// only on an accepted address phase), so the register captures it in the
// first data-phase cycle and presents it in the second.
wire [31:0] exts_hrdata_mux = exts_sd_d ? sd_s_hrdata : exts_gpo_d ? gpo_s_hrdata : exts_fan_d ? fan_s_hrdata : exts_sen_d ? sen_s_hrdata : exts_aud_d ? aud_s_hrdata : exts_vid_d ? vid_s_hrdata : eth_s_hrdata;
wire        exts_slv_hready = exts_sd_d ? sd_s_hready : exts_gpo_d ? gpo_s_hready : exts_fan_d ? fan_s_hready : exts_sen_d ? sen_s_hready : exts_aud_d ? aud_s_hready : exts_vid_d ? vid_s_hready : eth_s_hready;
reg  [31:0] exts_hrdata_q;
reg         exts_rd_wait;                       // first data-phase cycle of a read
always @(posedge EXTS_HCLK or negedge EXTS_HRSTN)
    if (!EXTS_HRSTN) begin
        exts_hrdata_q <= 32'd0; exts_rd_wait <= 1'b0;
    end else begin
        exts_hrdata_q <= exts_hrdata_mux;
        exts_rd_wait  <= EXTS_HSEL && EXTS_HTRANS[1] && EXTS_HREADY && !EXTS_HWRITE;
    end
assign EXTS_HRDATA  = exts_hrdata_q;
assign EXTS_HREADY  = exts_slv_hready & ~exts_rd_wait;
assign eth_hresp[0] = exts_sd_d ? sd_s_hresp  : exts_gpo_d ? gpo_s_hresp  : exts_fan_d ? fan_s_hresp  : exts_sen_d ? sen_s_hresp  : exts_aud_d ? aud_s_hresp  : exts_vid_d ? vid_s_hresp  : eth_s_hresp;

assign eth_rstn = EXTS_HRSTN;

// EXTM handshake probe -> debug pins (and CSR EXTM_DBG): is the SoC EXTM
// responding to the DMA's AHB read?  {hresp, hreadyout, htrans-active, hsel}
wire [3:0] dbg_extm = {extm_hresp, extm_hreadyout, extm_htrans[1], extm_hsel};
assign DBG = {extm_hreadyout, extm_hsel};   // U16=hsel, U15=hreadyout

// Dedicated Ethernet PLL: clkout1 = 125 MHz (GTX), clkout3 = 25 MHz (PHY ref),
// clkout2 = 33.3 MHz (1000/30) LCD pixel clock.  (Same Gowin_PLL IP as the SDK
// ae350_ext_ethernet example; VCO 1000 MHz.  clkout0 = 50 MHz is unused.)
Gowin_PLL u_Gowin_PLL_ETH
(
    .clkout0(),
    .clkout1(GTX_CLK),          // 125 MHz
    .clkout2(VID_CLK),          // 33.3 MHz
    .clkout3(ETH_CLK),          // 25 MHz
    .lock(ETH_PLL_LOCK),
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
    .EXT_INT({13'b0, intr_sd, intr_audio, intr_ethernet}),
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
    // External APB master -> ddr_perf (DDR AHB perf counters/trace @ CPU 0xF8000000)
    .APB_PRDATA(apb_prdata),
    .APB_PREADY(apb_pready),
    .APB_PSLVERR(apb_pslverr),
    .APB_PADDR(apb_paddr),
    .APB_PENABLE(apb_penable),
    .APB_PSEL(apb_psel),
    .APB_PWDATA(apb_pwdata),
    .APB_PWRITE(apb_pwrite),
    .APB_PPROT(),
    .APB_PSTRB(),
    .APB_PCLK(apb_pclk),
    .APB_PRSTN(apb_prstn),
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
    .DDR_CLK(ddr_vclk),                 // DDR3 IP user clock (see above)
    .AHB_CLK(AHB_CLK),
    .APB_CLK(APB_CLK),                  // 1:1 with AHB_CLK but its own PLL output (see above)
    .RTC_CLK(RTC_CLK),
    .POR_RSTN(ae350_rstn),              // AE350 CPU core power on reset, 0 is reset state
    .HW_RSTN(ae350_rstn)                // AE350 hardware reset, 0 is reset state
);


// AHB -> DDR3 (external DDR3 controller). ahb_ddr3_top = our line-buffered,
// burst-aware AHB slave (ddr_bridge/rtl/ahb_ddr3_bridge.v) in front of the Gowin
// DDR3 Memory Interface IP. It replaces Gowin's gw_ahb_ddr3, which spent a full
// DDR round trip on every 64-bit beat (~39 HCLK/beat, ~5 us per L1 line miss).
wire         ddr_perf_en, ddr_perf_clr;
wire [31:0]  ddr_bridge_mode;
wire [511:0] ddr_perf_cnt;

ahb_ddr3_top u_ahb_ddr3_top
(
    .DDR3_MEMORY_CLK(DDR3_MEMORY_CLK),
    .DDR3_CLK_IN(CLK),                  // IP reference clock = board 50 MHz (Build 65)
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
    .HPROT(DDR_HPROT),
    .HWDATA(DDR_HWDATA),
    .HREADY_O(DDR_HREADY),
    .HRESP(DDR_HRESP),
    .HRDATA(DDR_HRDATA),
    .MODE(ddr_bridge_mode),
    .PERF_EN(ddr_perf_en),
    .PERF_CLR(ddr_perf_clr),
    .PERF_CNT(ddr_perf_cnt),
    // read-only video port -> LCD video core
    .VCLK(ddr_vclk),
    .VRSTN(ddr_vrstn),
    .V_REQ(ddr_v_req),
    .V_ADDR(ddr_v_addr),
    .V_ACK(ddr_v_ack),
    .V_RVALID(ddr_v_rvalid),
    .V_RDATA(ddr_v_rdata)
);


// DDR data-memory bus performance monitor (passive tap on DDR_H*), read via
// the external APB at 0xF8000000. CONFIG = {8'h0, bridge id, DDR3 memory MHz}:
// bridge 1 = Gowin gw_ahb_ddr3 (encrypted v1.3), 2 = ahb_ddr3_bridge.
// MODE_RESET 0x10000: overlapping DDR reads, also across rows (full speed).
// Needs a kernel with PATCHES/0005 (A25 page-table writeback); for a kernel
// without it use 0x100 (one read in flight) -- see ddr_bridge/README.md.
ddr_perf #(
    .CONFIG(32'h0002_0190),
    .MODE_RESET(32'h0001_0000)
) u_ddr_perf (
    .hclk(DDR_HCLK),
    .hresetn(DDR_HRSTN),
    .haddr_i(DDR_HADDR),
    .htrans_i(DDR_HTRANS),
    .hwrite_i(DDR_HWRITE),
    .hsize_i(DDR_HSIZE),
    .hburst_i(DDR_HBURST),
    .hready_i(DDR_HREADY),
    .ext_cnt(ddr_perf_cnt),
    .en(ddr_perf_en),
    .clr(ddr_perf_clr),
    .mode(ddr_bridge_mode),
    .pclk(apb_pclk),
    .presetn(apb_prstn),
    .psel(apb_psel),
    .penable(apb_penable),
    .pwrite(apb_pwrite),
    .paddr(apb_paddr),
    .pwdata(apb_pwdata),
    .prdata(apb_prdata),
    .pready(apb_pready),
    .pslverr(apb_pslverr)
);


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
    .s_hsel(EXTS_HSEL & ~exts_vid & ~exts_aud & ~exts_sen & ~exts_fan & ~exts_gpo & ~exts_sd),
    .s_hready_in(EXTS_HREADY),
    .s_hwdata(EXTS_HWDATA),
    .s_hrdata(eth_s_hrdata),
    .s_hready(eth_s_hready),
    .s_hresp(eth_s_hresp),
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
ahb_arbiter4 u_eth_ahb_arbiter
(
    .clk(EXTS_HCLK), .rstn(EXTS_HRSTN),
    .m0_busy(m0_busy), .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite),
    .m0_hsize(m0_hsize), .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata),
    .m0_hrdata(m0_hrdata), .m0_hready(m0_hready), .m0_hresp(m0_hresp),
    .m1_busy(m1_busy), .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite),
    .m1_hsize(m1_hsize), .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata),
    .m1_hrdata(m1_hrdata), .m1_hready(m1_hready), .m1_hresp(m1_hresp),
    .m2_busy(sd_m_busy), .m2_haddr(sd_m_haddr), .m2_htrans(sd_m_htrans), .m2_hwrite(sd_m_hwrite),
    .m2_hsize(sd_m_hsize), .m2_hburst(sd_m_hburst), .m2_hwdata(sd_m_hwdata),
    .m2_hrdata(sd_m_hrdata), .m2_hready(sd_m_hready), .m2_hresp(sd_m_hresp),
    .m3_busy(au_m_busy), .m3_haddr(au_m_haddr), .m3_htrans(au_m_htrans), .m3_hwrite(au_m_hwrite),
    .m3_hsize(au_m_hsize), .m3_hburst(au_m_hburst), .m3_hwdata(au_m_hwdata),
    .m3_hrdata(au_m_hrdata), .m3_hready(au_m_hready), .m3_hresp(au_m_hresp),
    .active(arb_active), .haddr(arb_haddr), .htrans(arb_htrans), .hwrite(arb_hwrite),
    .hsize(arb_hsize), .hburst(arb_hburst), .hwdata(arb_hwdata),
    .hrdata(arb_hrdata), .hready(arb_hready), .hresp(arb_hresp)
);

// LCD video core: registers on EXTS @ 0xE8001000, framebuffer reads on the
// DDR bridge's video port (DDR3 user clock), RGB666 out on the panel in the
// VID_CLK domain.
video_core u_video_core
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .s_haddr(EXTS_HADDR), .s_htrans(EXTS_HTRANS), .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL & exts_vid), .s_hready_in(EXTS_HREADY), .s_hwdata(EXTS_HWDATA),
    .s_hrdata(vid_s_hrdata), .s_hready(vid_s_hready), .s_hresp(vid_s_hresp),
    .vclk(ddr_vclk), .vrstn(ddr_vrstn), .v_req(ddr_v_req), .v_addr(ddr_v_addr),
    .v_ack(ddr_v_ack), .v_rvalid(ddr_v_rvalid), .v_rdata(ddr_v_rdata),
    .pclk(VID_CLK), .lcd_de(LCD_DE), .lcd_r(LCD_R), .lcd_g(LCD_G), .lcd_b(LCD_B)
);
// Pixel clock to the panel, in phase with the registered outputs: data and DE
// change after the rising edge, the panel samples on the falling edge.
ODDR #(.TXCLK_POL(1'b0), .INIT(1'b0)) u_lcd_clk_oddr (
    .Q0(LCD_CLK), .Q1(), .D0(1'b1), .D1(1'b0), .TX(1'b0), .CLK(VID_CLK)
);

// Audio core: registers on EXTS @ 0xE8002000, sample FIFO filled by the CPU
// (EXT_INT[1] when it runs low), BCK/WS/DIN to the PT8211 DAC.
audio_core u_audio_core
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .s_haddr(EXTS_HADDR), .s_htrans(EXTS_HTRANS), .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL & exts_aud), .s_hready_in(EXTS_HREADY), .s_hwdata(EXTS_HWDATA),
    .s_hrdata(aud_s_hrdata), .s_hready(aud_s_hready), .s_hresp(aud_s_hresp),
    .irq(intr_audio), .i2s_bck(I2S_BCK), .i2s_ws(I2S_LRCK), .i2s_din(I2S_DIN),
    .pa_en(PA_EN),
    .m_busy(au_m_busy), .m_haddr(au_m_haddr), .m_htrans(au_m_htrans), .m_hwrite(au_m_hwrite),
    .m_hsize(au_m_hsize), .m_hburst(au_m_hburst), .m_hwdata(au_m_hwdata), .m_hrdata(au_m_hrdata),
    .m_hready(au_m_hready), .m_hresp(au_m_hresp)
);

// On-die temperature / supply-voltage monitor: registers on EXTS @ 0xE8004000,
// the FPGA's two hard ADC cores (ADCLRC temperature, ADCULC voltage) scanned
// continuously.  No pins; the cores run on their internal oscillator.
sensor_core #(.BUS_MHZ(50)) u_sensor_core
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .s_haddr(EXTS_HADDR), .s_htrans(EXTS_HTRANS), .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL & exts_sen), .s_hready_in(EXTS_HREADY), .s_hwdata(EXTS_HWDATA),
    .s_hrdata(sen_s_hrdata), .s_hready(sen_s_hready), .s_hresp(sen_s_hresp),
    .adc_clk(ETH_CLK)
);

// Fan PWM + tacho: registers on EXTS @ 0xE8008000, Dock fan header M1
// (T17 PWM, T18 tacho).  Reset state = 25 kHz, 100 % duty.
fan_core #(.BUS_MHZ(50)) u_fan_core
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .s_haddr(EXTS_HADDR), .s_htrans(EXTS_HTRANS), .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL & exts_fan), .s_hready_in(EXTS_HREADY), .s_hwdata(EXTS_HWDATA),
    .s_hrdata(fan_s_hrdata), .s_hready(fan_s_hready), .s_hresp(fan_s_hresp),
    .fan_pwm(FAN_PWM), .fan_tach(FAN_TACH)
);

// Board control GPIO: registers on EXTS @ 0xE8010000.  Six open-drain-capable
// lines for the Dock's SYS_TWI I2C bus (K25/K26, bit-banged by Linux
// i2c-gpio), the 74HC4051 TWI mux select (N19/P19/P26, i2c-mux-gpio; channel
// 2 = the 1 KB ZD24C08A EEPROM) and the EEPROM write protect (V14).  Reset:
// all inputs, so the I2C lines rest on the Dock's pull-ups.
gpio_core #(.N(6)) u_gpio_core
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .s_haddr(EXTS_HADDR), .s_htrans(EXTS_HTRANS), .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL & exts_gpo), .s_hready_in(EXTS_HREADY), .s_hwdata(EXTS_HWDATA),
    .s_hrdata(gpo_s_hrdata), .s_hready(gpo_s_hready), .s_hresp(gpo_s_hresp),
    .gpio_i(gpo_i), .gpio_o(gpo_o), .gpio_oe(gpo_oe)
);
assign gpo_i     = {EEPROM_WP, TWI_SEL, SYS_SDA, SYS_SCL};
assign SYS_SCL   = gpo_oe[0] ? gpo_o[0] : 1'bz;
assign SYS_SDA   = gpo_oe[1] ? gpo_o[1] : 1'bz;
assign TWI_SEL   = {gpo_oe[4] ? gpo_o[4] : 1'bz, gpo_oe[3] ? gpo_o[3] : 1'bz, gpo_oe[2] ? gpo_o[2] : 1'bz};
assign EEPROM_WP = gpo_oe[5] ? gpo_o[5] : 1'bz;

// microSD host: native SD bus (1/4-bit) with CRC engines and a 64-bit DMA
// master (arbiter master 2) on EXTS @ 0xE8020000, Dock slot J19.  Interrupt
// on EXT_INT[2] (PLIC source 12).  Linux: drivers/mmc/host/gowin-sdhost.c.
sdhost_core #(.BUS_MHZ(50)) u_sdhost_core
(
    .hclk(EXTS_HCLK), .hresetn(EXTS_HRSTN),
    .s_haddr(EXTS_HADDR), .s_htrans(EXTS_HTRANS), .s_hwrite(EXTS_HWRITE),
    .s_hsel(EXTS_HSEL & exts_sd), .s_hready_in(EXTS_HREADY), .s_hwdata(EXTS_HWDATA),
    .s_hrdata(sd_s_hrdata), .s_hready(sd_s_hready), .s_hresp(sd_s_hresp),
    .m_busy(sd_m_busy), .m_haddr(sd_m_haddr), .m_htrans(sd_m_htrans), .m_hwrite(sd_m_hwrite),
    .m_hsize(sd_m_hsize), .m_hburst(sd_m_hburst), .m_hwdata(sd_m_hwdata), .m_hrdata(sd_m_hrdata),
    .m_hready(sd_m_hready), .m_hresp(sd_m_hresp),
    .sd_clk(SD_CLK), .cmd_o(sd_cmd_o), .cmd_oe(sd_cmd_oe), .cmd_i(SD_CMD),
    .dat_o(sd_dat_o), .dat_oe(sd_dat_oe), .dat_oe_hi(sd_dat_oe_hi), .dat_i(SD_DAT),
    .sd_det_n(SD_DET), .irq(intr_sd)
);
assign SD_CMD      = sd_cmd_oe ? sd_cmd_o : 1'bz;
assign SD_DAT[0]   = sd_dat_oe ? sd_dat_o[0] : 1'bz;
assign SD_DAT[3:1] = sd_dat_oe_hi ? sd_dat_o[3:1] : 3'bzzz;

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
// PHY hardware reset.  A reload of the FPGA stops PHY_CLK under the running
// PHY, which can leave it unable to train gigabit (downshifts to 100M) until a
// hardware reset; so hold it in reset until its 25 MHz reference is back and
// locked, plus 2^19 cycles (21 ms, the RTL8211F needs >= 10 ms), and on S3.
wire       phy_rst_hold_n = RSTN & ETH_PLL_LOCK;
reg [19:0] phy_rst_cnt;
always @(posedge ETH_CLK or negedge phy_rst_hold_n)
    if (!phy_rst_hold_n)       phy_rst_cnt <= 20'd0;
    else if (!phy_rst_cnt[19]) phy_rst_cnt <= phy_rst_cnt + 20'd1;
assign PHY_RST_N = phy_rst_cnt[19];

endmodule