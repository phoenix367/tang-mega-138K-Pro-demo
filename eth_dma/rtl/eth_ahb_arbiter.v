`default_nettype none
//============================================================================
// eth_ahb_arbiter.v -- synthesizable 2-master AHB-lite arbiter, fixed priority
// (master 0 = RX write wins over master 1 = TX read).
//
// Drop-in for the Gowin AHBBusArbiter IP (Gowin_AHB_Arbiter_Top, 16 masters):
// to use the vendor IP instead, generate it (fixed priority, 32-bit, 2 masters)
// and replace this instance -- the function is identical for our two masters.
//
// Grants per-command using each master's `busy` (high for a whole command, so
// no mid-command switching with the single-beat masters), exactly as verified
// in the full-core loopback.  Combinational; the AHB runs at the 50 MHz bus
// clock so the mux delay is comfortably met.
//============================================================================
module eth_ahb_arbiter (
    // master 0 (priority -- RX write)
    input  wire        m0_busy,
    input  wire [31:0] m0_haddr,
    input  wire [1:0]  m0_htrans,
    input  wire        m0_hwrite,
    input  wire [2:0]  m0_hsize,
    input  wire [2:0]  m0_hburst,
    input  wire [31:0] m0_hwdata,
    output wire [31:0] m0_hrdata,
    output wire        m0_hready,
    output wire        m0_hresp,
    // master 1 (TX read)
    input  wire        m1_busy,
    input  wire [31:0] m1_haddr,
    input  wire [1:0]  m1_htrans,
    input  wire        m1_hwrite,
    input  wire [2:0]  m1_hsize,
    input  wire [2:0]  m1_hburst,
    input  wire [31:0] m1_hwdata,
    output wire [31:0] m1_hrdata,
    output wire        m1_hready,
    output wire        m1_hresp,
    // merged master (-> extm_bridge -> EXTM)
    output wire        active,
    output wire [31:0] haddr,
    output wire [1:0]  htrans,
    output wire        hwrite,
    output wire [2:0]  hsize,
    output wire [2:0]  hburst,
    output wire [31:0] hwdata,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp
);
    wire g0 = m0_busy;
    wire g1 = ~m0_busy & m1_busy;

    assign active = m0_busy | m1_busy;
    assign haddr  = g0 ? m0_haddr  : m1_haddr;
    assign htrans = g0 ? m0_htrans : (g1 ? m1_htrans : 2'b00);
    assign hwrite = g0 ? m0_hwrite : m1_hwrite;
    assign hsize  = g0 ? m0_hsize  : m1_hsize;
    assign hburst = g0 ? m0_hburst : m1_hburst;
    assign hwdata = g0 ? m0_hwdata : m1_hwdata;

    assign m0_hready = g0 ? hready : 1'b0;
    assign m1_hready = g1 ? hready : 1'b0;
    assign m0_hrdata = hrdata;
    assign m1_hrdata = hrdata;
    assign m0_hresp  = g0 ? hresp : 1'b0;
    assign m1_hresp  = g1 ? hresp : 1'b0;
endmodule
`default_nettype wire
