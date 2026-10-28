//Copyright (C)2014-2025 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.11.01 (64-bit) 
//Created Time: 2025-02-27 17:19:06
create_clock -name ae350_ddr_clk -period 10 -waveform {0 5} [get_pins {u_Gowin_PLL_AE350/PLL_inst/CLKOUT0}]
create_clock -name ae350_ahb_clk -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_AE350/PLL_inst/CLKOUT2}]
create_clock -name ddr3_memory_clk -period 2.5 -waveform {0 1.25} [get_pins {u_Gowin_PLL_DDR3/PLL_inst/CLKOUT2}]
create_clock -name ddr3_clkin -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_DDR3/PLL_inst/CLKOUT0}]
create_clock -name ddr3_sysclk -period 10 -waveform {0 5} [get_pins {u_ahb_ddr3_top/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
create_clock -name flash_sysclk -period 20 -waveform {0 10} [get_nets {u_RiscV_AE350_SOC_Top/FLASH_SPI_CLK_in}]
create_clock -name clk50m -period 20 -waveform {0 10} [get_ports {CLK}]
create_clock -name ae350_apb_clk -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_AE350/PLL_inst/CLKOUT3}]
create_clock -name flash_spi_clk_i -period 20 -waveform {0 10} [get_pins {u_RiscV_AE350_SOC_Top/FLASH_SPI_CLK_iobuf/I}]
create_clock -name flash_spi_clk -period 20 -waveform {0 10} [get_ports {FLASH_SPI_CLK}]
// Ethernet: GTX TX clock 125 MHz (eth PLL CLKOUT1) + RGMII RX clock from PHY.
// rgmii_rxclk = 8 ns (125 MHz), the 1000BASE-T RGMII RX clock from the PHY. The
// RX/TX clock-to-data skew is supplied by the PHY (RGMII-ID mode, internal
// delay), so no fabric IODELAY is needed; this constraint just makes PnR time
// the RGMII RX capture path at the real 125 MHz instead of the example's 50 MHz.
create_clock -name gtx_clk -period 8 -waveform {0 4} [get_pins {u_Gowin_PLL_ETH/PLL_inst/CLKOUT1}]
create_clock -name rgmii_rxclk -period 8 -waveform {0 4} [get_ports {RGMII_RXC}]
set_clock_groups -exclusive -group [get_clocks {flash_sysclk}] -group [get_clocks {ae350_ahb_clk}] -group [get_clocks {ae350_apb_clk}] -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {gtx_clk}] -group [get_clocks {rgmii_rxclk}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_clkin}] -group [get_clocks {ddr3_sysclk}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_sysclk}] -group [get_clocks {ddr3_memory_clk}]
set_clock_groups -exclusive -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {ddr3_clkin}]
set_clock_groups -exclusive -group [get_clocks {clk50m}] -group [get_clocks {ddr3_sysclk}]
// ahb_ddr3_bridge: SoC DDR_HCLK (ae350_ddr_clk) <-> DDR3 IP user clock cross only
// through gray-coded async FIFOs and 2-FF synchronizers.
set_clock_groups -asynchronous -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {ddr3_sysclk}]
// ddr_perf: the APB side reads the bridge's DDR-clock counters only while they
// are frozen (EN=0), and the debug MODE bits are quasi-static.
set_clock_groups -asynchronous -group [get_clocks {ae350_apb_clk}] -group [get_clocks {ddr3_sysclk}]
// ahb_ddr3_bridge AHB side at 100 MHz: closed with 0.3 ns of setup margin (the
// placer stops at the constraint, so ask for more than the clock needs).
set_clock_uncertainty 0.3 -setup -from [get_clocks {ae350_ddr_clk}] -to [get_clocks {ae350_ddr_clk}]
// RGMII RX input timing.  RTL8211F with RX internal delay (RGMII-ID): at its
// pins RXD/RX_CTL are valid >= 1.2 ns before and >= 1.2 ns after each RXC edge
// (datasheet TsetupT/TholdT).  Data is captured on both edges, so relative to
// each edge: max = T/2 - 1.2 = 2.8 ns, min = 1.2 ns.
set_input_delay -clock rgmii_rxclk 2.8 -max [get_ports {RGMII_RXD[*]}]
set_input_delay -clock rgmii_rxclk 1.2 -min [get_ports {RGMII_RXD[*]}]
set_input_delay -clock rgmii_rxclk 2.8 -max -clock_fall -add_delay [get_ports {RGMII_RXD[*]}]
set_input_delay -clock rgmii_rxclk 1.2 -min -clock_fall -add_delay [get_ports {RGMII_RXD[*]}]
set_input_delay -clock rgmii_rxclk 2.8 -max [get_ports {RGMII_RX_CTL}]
set_input_delay -clock rgmii_rxclk 1.2 -min [get_ports {RGMII_RX_CTL}]
set_input_delay -clock rgmii_rxclk 2.8 -max -clock_fall -add_delay [get_ports {RGMII_RX_CTL}]
set_input_delay -clock rgmii_rxclk 1.2 -min -clock_fall -add_delay [get_ports {RGMII_RX_CTL}]
report_timing -setup -from [get_ports {RGMII_RXD[*]}] -max_paths 10
report_timing -hold -from [get_ports {RGMII_RXD[*]}] -max_paths 10
report_timing -setup -from [get_ports {RGMII_RX_CTL}] -max_paths 4
report_timing -hold -from [get_ports {RGMII_RX_CTL}] -max_paths 4
// LCD video core: pixel clock (Ethernet PLL CLKOUT2, 1000/30 = 33.3 MHz).  The
// core spans three clocks -- registers on EXTS (ae350_ahb_clk), line fetch on
// the DDR bridge's video port (ddr3_sysclk), scan-out (lcd_pclk) -- that talk
// only through the dual-clock line RAM, toggle handshakes and configuration
// that is static while scan-out runs.
create_clock -name lcd_pclk -period 30 -waveform {0 15} [get_pins {u_Gowin_PLL_ETH/PLL_inst/CLKOUT2}]
set_clock_groups -exclusive -group [get_clocks {lcd_pclk}] -group [get_clocks {ae350_ahb_clk}]
set_clock_groups -asynchronous -group [get_clocks {lcd_pclk}] -group [get_clocks {ddr3_sysclk}]
set_clock_groups -asynchronous -group [get_clocks {ae350_ahb_clk}] -group [get_clocks {ddr3_sysclk}]
