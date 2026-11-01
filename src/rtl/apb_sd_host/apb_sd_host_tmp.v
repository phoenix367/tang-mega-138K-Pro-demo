//Copyright (C)2014-2026 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: Template file for instantiation
//Tool Version: V1.9.12.02_SP2
//IP Version: 1.0
//Part Number: GW5AST-LV138FPG676AC1/I0
//Device: GW5AST-138
//Device Version: B
//Created Time: Mon Jun  8 16:22:33 2026

//Change the instance name and port connections to the signal names
//--------Copy here to design--------

	APB_SD_Host_Top your_instance_name(
		.pclk(pclk), //input pclk
		.presetn(presetn), //input presetn
		.psel(psel), //input psel
		.penable(penable), //input penable
		.pwrite(pwrite), //input pwrite
		.paddr(paddr), //input [7:0] paddr
		.pstrb(pstrb), //input [3:0] pstrb
		.pwdata(pwdata), //input [31:0] pwdata
		.prdata(prdata), //output [31:0] prdata
		.pready(pready), //output pready
		.pslverr(pslverr), //output pslverr
		.sd_cmd_dat_i(sd_cmd_dat_i), //input sd_cmd_dat_i
		.sd_cmd_out_o(sd_cmd_out_o), //output sd_cmd_out_o
		.sd_cmd_oe_o(sd_cmd_oe_o), //output sd_cmd_oe_o
		.sd_dat_dat_i(sd_dat_dat_i), //input [3:0] sd_dat_dat_i
		.sd_dat_out_o(sd_dat_out_o), //output [3:0] sd_dat_out_o
		.sd_dat_oe_o(sd_dat_oe_o), //output sd_dat_oe_o
		.sd_clk_o_pad(sd_clk_o_pad), //output sd_clk_o_pad
		.sd_clk_i_pad(sd_clk_i_pad), //input sd_clk_i_pad
		.int_cmd(int_cmd), //output int_cmd
		.int_data(int_data) //output int_data
	);

//--------Copy end-------------------
