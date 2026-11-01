//********************************************************************
//
// <File>     : sd_top.v
// <Author>   : GOWIN EMB
// <Function> : SD controller top module
// <Version>  : 1.3
//
//********************************************************************

// apb_sd_top
module apb_sd_top
(
  pclk,
  presetn,
  psel,
  paddr,
  penable,
  pwrite,
  pwdata,
  prdata,
  pready,
  pslverr,

  spiSysClk,
  spiClkOut,
  spiDataIn,
  spiDataOut,
  spiCS_n
);

input wire          pclk;
input wire          presetn;
input wire          psel;
input wire  [11:0]  paddr;
input wire          penable;
input wire          pwrite;
input wire  [31:0]  pwdata;
output wire [31:0]  prdata;
output wire         pready;
output wire         pslverr;

input spiSysClk;
output spiClkOut;
input spiDataIn;
output spiDataOut;
output spiCS_n;


// apb_sd instantiation
apb_sd u_apb_sd
(
  .pclk(pclk),
  .presetn(presetn),
  .psel(psel),
  .paddr(paddr),
  .penable(penable),
  .pwrite(pwrite),
  .pwdata(pwdata),
  .prdata(prdata),
  .pready(pready),
  .pslverr(pslverr),
  .spiSysClk(spiSysClk),
  .spiClkOut(spiClkOut),
  .spiDataIn(spiDataIn),
  .spiDataOut(spiDataOut),
  .spiCS_n(spiCS_n)
);

endmodule