//Copyright (C)2014-2025 GOWIN Semiconductor Corporation.
//All rights reserved.
//File Title: Timing Constraints file
//Tool Version: V1.9.11.01 (64-bit) 
//Created Time: 2025-02-27 17:19:06
create_clock -name ae350_ddr_clk -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_AE350/PLL_inst/CLKOUT0}]
create_clock -name ae350_ahb_clk -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_AE350/PLL_inst/CLKOUT2}]
create_clock -name ddr3_memory_clk -period 5 -waveform {0 2.5} [get_pins {u_Gowin_PLL_DDR3/PLL_inst/CLKOUT2}]
create_clock -name ddr3_clkin -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_DDR3/PLL_inst/CLKOUT0}]
create_clock -name ddr3_sysclk -period 20 -waveform {0 10} [get_pins {u_gw_ahb_ddr3_top/u_gw_ahb_ddr3/u_ddr3_memory_ahb_top/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
create_clock -name flash_sysclk -period 20 -waveform {0 10} [get_nets {u_RiscV_AE350_SOC_Top/FLASH_SPI_CLK_in}]
create_clock -name clk50m -period 20 -waveform {0 10} [get_ports {CLK}]
create_clock -name ae350_apb_clk -period 20 -waveform {0 10} [get_pins {u_Gowin_PLL_AE350/PLL_inst/CLKOUT3}]
create_clock -name flash_spi_clk_i -period 20 -waveform {0 10} [get_pins {u_RiscV_AE350_SOC_Top/FLASH_SPI_CLK_iobuf/I}]
create_clock -name flash_spi_clk -period 20 -waveform {0 10} [get_ports {FLASH_SPI_CLK}]
// Ethernet: GTX TX clock 125 MHz (eth PLL CLKOUT1) + RGMII RX clock from PHY.
// NOTE: rgmii_rxclk uses the example's 20 ns; for verified 1000BASE-T tighten to
// 8 ns (125 MHz) and confirm the RGMII RX delay (PHY RGMII-ID straps).
create_clock -name gtx_clk -period 8 -waveform {0 4} [get_pins {u_Gowin_PLL_ETH/PLL_inst/CLKOUT1}]
create_clock -name rgmii_rxclk -period 20 -waveform {0 10} [get_ports {RGMII_RXC}]
set_clock_groups -exclusive -group [get_clocks {flash_sysclk}] -group [get_clocks {ae350_ahb_clk}] -group [get_clocks {ae350_apb_clk}] -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {gtx_clk}] -group [get_clocks {rgmii_rxclk}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_clkin}] -group [get_clocks {ddr3_sysclk}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_sysclk}] -group [get_clocks {ddr3_memory_clk}]
set_clock_groups -exclusive -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {ddr3_clkin}]
set_clock_groups -exclusive -group [get_clocks {clk50m}] -group [get_clocks {ddr3_sysclk}]
