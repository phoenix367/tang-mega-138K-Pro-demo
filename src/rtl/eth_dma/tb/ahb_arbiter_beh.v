`default_nettype none
//============================================================================
// ahb_arbiter_beh.v -- BEHAVIORAL 2-master AHB-lite arbiter (SIMULATION ONLY).
//
// Stand-in for the Gowin AHBBusArbiter IP (16 masters, fixed priority, encrypted
// -> not iverilog-simulable). Models the same function for our 2 masters:
//   master 0 (RX write) has priority over master 1 (TX read).
// Grants per-command using each master's `busy` (high for a whole command, so no
// mid-command switching with the single-beat masters). The real build wires the
// two masters to Gowin_AHB_Arbiter_Top instead.
//============================================================================
module ahb_arbiter_beh (
    // master 0 (priority)
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
    // master 1
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
    // shared slave (EXTM)
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

    assign haddr  = g0 ? m0_haddr  : m1_haddr;
    assign htrans = g0 ? m0_htrans : (g1 ? m1_htrans : 2'b00);
    assign hwrite = g0 ? m0_hwrite : m1_hwrite;
    assign hsize  = g0 ? m0_hsize  : m1_hsize;
    assign hburst = g0 ? m0_hburst : m1_hburst;
    assign hwdata = g0 ? m0_hwdata : m1_hwdata;

    assign m0_hready = g0 ? hready : 1'b0;     // non-granted master is stalled
    assign m1_hready = g1 ? hready : 1'b0;
    assign m0_hrdata = hrdata;
    assign m1_hrdata = hrdata;
    assign m0_hresp  = g0 ? hresp : 1'b0;
    assign m1_hresp  = g1 ? hresp : 1'b0;
endmodule
`default_nettype wire
