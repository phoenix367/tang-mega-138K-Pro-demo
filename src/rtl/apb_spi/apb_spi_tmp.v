//Copyright (C)2014-2026 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12.02_SP2
//IP Version: 1.0
//Part Number: GW5AST-LV138FPG676AC1/I0
//Device: GW5AST-138
//Device Version: B
//Created Time: Mon Jun  8 16:44:30 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	APB_SPI_Top your_instance_name(
		.pclk(pclk), //input pclk
		.presetn(presetn), //input presetn
		.paddr(paddr), //input [31:0] paddr
		.penable(penable), //input penable
		.prdata(prdata), //output [31:0] prdata
		.pready(pready), //output pready
		.psel(psel), //input psel
		.pwdata(pwdata), //input [31:0] pwdata
		.pwrite(pwrite), //input pwrite
		.spi_default_as_slave(spi_default_as_slave), //input spi_default_as_slave
		.spi_cs_n_in(spi_cs_n_in), //input spi_cs_n_in
		.spi_hold_n_in(spi_hold_n_in), //input spi_hold_n_in
		.spi_hold_n_oe(spi_hold_n_oe), //output spi_hold_n_oe
		.spi_hold_n_out(spi_hold_n_out), //output spi_hold_n_out
		.spi_wp_n_in(spi_wp_n_in), //input spi_wp_n_in
		.spi_wp_n_oe(spi_wp_n_oe), //output spi_wp_n_oe
		.spi_wp_n_out(spi_wp_n_out), //output spi_wp_n_out
		.spi_clock(spi_clock), //input spi_clock
		.spi_rstn(spi_rstn), //input spi_rstn
		.spi_boot_intr(spi_boot_intr), //output spi_boot_intr
		.spi_default_mode3(spi_default_mode3), //input spi_default_mode3
		.scan_enable(scan_enable), //input scan_enable
		.scan_test(scan_test), //input scan_test
		.spi_clk_in(spi_clk_in), //input spi_clk_in
		.spi_clk_oe(spi_clk_oe), //output spi_clk_oe
		.spi_clk_out(spi_clk_out), //output spi_clk_out
		.spi_cs_n_oe(spi_cs_n_oe), //output spi_cs_n_oe
		.spi_cs_n_out(spi_cs_n_out), //output spi_cs_n_out
		.spi_miso_in(spi_miso_in), //input spi_miso_in
		.spi_miso_oe(spi_miso_oe), //output spi_miso_oe
		.spi_miso_out(spi_miso_out), //output spi_miso_out
		.spi_mosi_in(spi_mosi_in), //input spi_mosi_in
		.spi_mosi_oe(spi_mosi_oe), //output spi_mosi_oe
		.spi_mosi_out(spi_mosi_out) //output spi_mosi_out
	);

//--------Copy end-------------------
