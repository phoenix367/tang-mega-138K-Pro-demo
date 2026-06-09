`default_nettype none
//============================================================================
// extm_bridge.v -- 32-bit AHB master  ->  64-bit SoC EXTM slave port.
//
// The AE350 EXTM external-master port is 32-bit address / 64-bit data; our DMA
// masters (via the arbiter) are 32-bit data.  For a 32-bit transfer (HSIZE=010)
// on a 64-bit bus the active data lane is selected by HADDR[2]:
//   HADDR[2]=0 -> lane [31:0],  HADDR[2]=1 -> lane [63:32].
// Writes replicate the word to both lanes (the slave uses the active one);
// reads select the lane using HADDR[2] registered from the address phase.
// Address/control pass through; HSEL is driven from `active` (a master busy),
// and EXTM is single-slave so HREADY feeds back from HREADYOUT.
//============================================================================
module extm_bridge (
    input  wire        hclk,
    input  wire        hresetn,
    // 32-bit side (arbiter master output)
    input  wire [31:0] a_haddr,
    input  wire [1:0]  a_htrans,
    input  wire        a_hwrite,
    input  wire [2:0]  a_hsize,
    input  wire [2:0]  a_hburst,
    input  wire [31:0] a_hwdata,
    input  wire        a_active,          // a master is busy -> drive HSEL
    output wire [31:0] a_hrdata,
    output wire        a_hready,
    output wire        a_hresp,
    // 64-bit EXTM side (to the SoC)
    output wire [31:0] extm_haddr,
    output wire [1:0]  extm_htrans,
    output wire        extm_hwrite,
    output wire [2:0]  extm_hsize,
    output wire [2:0]  extm_hburst,
    output wire [3:0]  extm_hprot,
    output wire [63:0] extm_hwdata,
    output wire        extm_hsel,
    output wire        extm_hready,       // HREADY input of the EXTM slave
    input  wire [63:0] extm_hrdata,
    input  wire        extm_hreadyout,
    input  wire        extm_hresp
);
    assign extm_haddr   = a_haddr;
    assign extm_htrans  = a_htrans;
    assign extm_hwrite  = a_hwrite;
    assign extm_hsize   = a_hsize;
    assign extm_hburst  = a_hburst;
    assign extm_hprot   = 4'b0011;                  // data, privileged, non-cache, non-buf
    assign extm_hsel    = a_active;
    assign extm_hwdata  = {a_hwdata, a_hwdata};     // replicate to both 32-bit lanes
    assign extm_hready  = extm_hreadyout;           // single slave: feed ready back

    // register HADDR[2] at the accepted address phase for the data-phase read mux
    reg addr2_d;
    always @(posedge hclk or negedge hresetn)
        if (!hresetn)                                        addr2_d <= 1'b0;
        else if (extm_hsel && a_htrans[1] && extm_hreadyout) addr2_d <= a_haddr[2];

    assign a_hrdata = addr2_d ? extm_hrdata[63:32] : extm_hrdata[31:0];
    assign a_hready = extm_hreadyout;
    assign a_hresp  = extm_hresp;
endmodule
`default_nettype wire
