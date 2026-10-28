`default_nettype none
//============================================================================
// extm_bridge.v -- arbiter master  ->  64-bit SoC EXTM slave port.
//
// The AE350 EXTM external-master port is 32-bit address / 64-bit data, and so
// is the arbiter's merged bus (it places 32-bit transfers on the lane HADDR[2]
// selects).  Address/control/data pass through; HSEL is driven from `active`
// (a master busy), and EXTM is single-slave so HREADY feeds back from
// HREADYOUT.
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
    input  wire [63:0] a_hwdata,
    input  wire        a_active,          // a master is busy -> drive HSEL
    input  wire        a_hready_in,       // bus HREADY from the arbiter (SHREADYMUX)
    output wire [63:0] a_hrdata,
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
    assign extm_haddr   = a_haddr;   // custom arbiter forwards the full DRAM address
    assign extm_htrans  = a_htrans;
    assign extm_hwrite  = a_hwrite;
    assign extm_hsize   = a_hsize;
    assign extm_hburst  = a_hburst;
    assign extm_hprot   = 4'b0011;                  // data, privileged, non-cache, non-buf
    assign extm_hsel    = a_active;
    assign extm_hwdata  = a_hwdata;
    assign extm_hready  = a_hready_in;              // bus HREADYIN from the arbiter

    assign a_hrdata = extm_hrdata;
    assign a_hready = extm_hreadyout;
    assign a_hresp  = extm_hresp;
endmodule
`default_nettype wire
