//********************************************************************
//
// <File>     : gw_ahb_ddr3_top.v
// <Author>   : EMB
// <Function> : Gowin DDR3 memory AHB interface top module
// <Version>  : 1.3
//
//********************************************************************

// gw_ahb_ddr3_top
module gw_ahb_ddr3_top
(
    // DDR3 memory interface
    input   wire            DDR3_MEMORY_CLK,    // Memory clock
    input   wire            DDR3_CLK_IN,        // Clock in
    input   wire            DDR3_RSTN,          // Reset
    input   wire            DDR3_LOCK,          // PLL lock
    output  wire            DDR3_STOP,          // PLL stop
    output 	wire            DDR3_INIT,          // Initialized
    output  wire    [2:0]   DDR3_BANK,
    output  wire            DDR3_CS_N,
    output  wire            DDR3_RAS_N,
    output  wire            DDR3_CAS_N,
    output  wire            DDR3_WE_N,
    output  wire            DDR3_CK,
    output  wire            DDR3_CK_N,
    output  wire            DDR3_CKE,
    output  wire            DDR3_RESET_N,
    output  wire            DDR3_ODT,
    output  wire    [13:0]  DDR3_ADDR,
    output  wire    [1:0]   DDR3_DM,
    inout   wire    [15:0]  DDR3_DQ,
    inout   wire    [1:0]   DDR3_DQS,
    inout   wire    [1:0]   DDR3_DQS_N,
    // AHB bus interface
    input   wire            HCLK,
    input   wire            HRESETN,
    input   wire    [31:0]  HADDR,
    input   wire    [2:0]   HSIZE,
    input   wire            HWRITE,
    input   wire    [1:0]   HTRANS,
    input   wire    [2:0]   HBURST,
    input   wire    [63:0]  HWDATA,
    output  wire            HREADY_O,
    output  wire    [1:0]   HRESP,
    output  wire    [63:0]  HRDATA
);

// gw_ahb_ddr3 instantiation
gw_ahb_ddr3 u_gw_ahb_ddr3
(
    .DDR3_MEMORY_CLK(DDR3_MEMORY_CLK),
    .DDR3_CLK_IN(DDR3_CLK_IN),
    .DDR3_RSTN(DDR3_RSTN),
    .DDR3_LOCK(DDR3_LOCK),
    .DDR3_STOP(DDR3_STOP),
    .DDR3_INIT(DDR3_INIT),
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
    .HCLK(HCLK),
    .HRESETN(HRESETN),
    .HADDR(HADDR),
    .HSIZE(HSIZE),
    .HWRITE(HWRITE),
    .HTRANS(HTRANS),
    .HBURST(HBURST),
    .HWDATA(HWDATA),
    .HREADY_O(HREADY_O),
    .HRESP(HRESP),
    .HRDATA(HRDATA)
);

endmodule