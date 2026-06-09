//Copyright (C)2014-2026 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12.02_SP2
//IP Version: 1.0
//Part Number: GW5AST-LV138FPG676AC1/I0
//Device: GW5AST-138
//Device Version: B
//Created Time: Tue Jun  9 16:21:14 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	SPI_Flash_Interface_Top your_instance_name(
		.I_hclk(I_hclk), //input I_hclk
		.I_hresetn(I_hresetn), //input I_hresetn
		.I_haddr_reg(I_haddr_reg), //input [31:0] I_haddr_reg
		.O_hrdata_reg(O_hrdata_reg), //output [31:0] O_hrdata_reg
		.I_hreadyin_reg(I_hreadyin_reg), //input I_hreadyin_reg
		.O_hreadyout_reg(O_hreadyout_reg), //output O_hreadyout_reg
		.O_hresp_reg(O_hresp_reg), //output [1:0] O_hresp_reg
		.I_hsel_reg(I_hsel_reg), //input I_hsel_reg
		.I_htrans_reg(I_htrans_reg), //input [1:0] I_htrans_reg
		.I_hwdata_reg(I_hwdata_reg), //input [31:0] I_hwdata_reg
		.I_hwrite_reg(I_hwrite_reg), //input I_hwrite_reg
		.I_spi_clock(I_spi_clock), //input I_spi_clock
		.I_spi_rstn(I_spi_rstn), //input I_spi_rstn
		.O_flash_ck(O_flash_ck), //output O_flash_ck
		.O_flash_cs_n(O_flash_cs_n), //output O_flash_cs_n
		.IO_flash_hold_n(IO_flash_hold_n), //inout IO_flash_hold_n
		.IO_flash_wp_n(IO_flash_wp_n), //inout IO_flash_wp_n
		.IO_flash_do(IO_flash_do), //inout IO_flash_do
		.IO_flash_di(IO_flash_di) //inout IO_flash_di
	);

//--------Copy end-------------------
