`default_nettype none
//============================================================================
// eth_ahb_arbiter.v -- 2-master AHB-lite arbiter for the gw_eth_dma EXTM port.
//
// Replaces the Gowin AHBBusArbiter IP, which is a peripheral-register
// interconnect: it only forwards a fixed ~1 MB window at 0x80000000 and passes
// the address through unchanged -- unusable as a DMA fabric.  This arbiter
// forwards the FULL 32-bit address space, so the DMA masters reach DRAM at 0x0
// directly (no window, no address remap).
//
// Fixed priority: master 0 (RX write) > master 1 (TX read) -- RX wins because
// the MAC cannot be back-pressured.  Grant is REGISTERED and held for the whole
// of a master's command (its `busy`), so an in-flight transfer is never
// preempted (AMBA AHB requires a started transfer to complete).  Re-arbitration
// happens only when the granted master goes idle.  The slave's HREADY paces the
// granted master; non-granted masters are stalled (HREADY=0) and hold their
// address phase.  Single-slave: the address is forwarded verbatim.
//
// The merged bus is 64-bit (EXTM).  Master 0 is 64-bit; master 1 is 32-bit: its
// write data goes out on both lanes and its read data comes from the lane its
// address selects (HADDR[2], captured with the accepted address phase).
//============================================================================
module eth_ahb_arbiter (
    input  wire        clk,
    input  wire        rstn,
    // master 0 (RX write, priority)
    input  wire        m0_busy,
    input  wire [31:0] m0_haddr,
    input  wire [1:0]  m0_htrans,
    input  wire        m0_hwrite,
    input  wire [2:0]  m0_hsize,
    input  wire [2:0]  m0_hburst,
    input  wire [63:0] m0_hwdata,
    output wire [63:0] m0_hrdata,
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
    // merged master -> extm_bridge -> EXTM
    output wire        active,
    output wire [31:0] haddr,
    output wire [1:0]  htrans,
    output wire        hwrite,
    output wire [2:0]  hsize,
    output wire [2:0]  hburst,
    output wire [63:0] hwdata,
    input  wire [63:0] hrdata,
    input  wire        hready,
    input  wire        hresp
);
    localparam [1:0] NONE = 2'd0, M0 = 2'd1, M1 = 2'd2;

    reg  [1:0] grant;
    wire holding = (grant == M0 && m0_busy) || (grant == M1 && m1_busy);

    always @(posedge clk or negedge rstn)
        if (!rstn)        grant <= NONE;
        else if (!holding) grant <= m0_busy ? M0 : (m1_busy ? M1 : NONE);
        // else hold the grant: never preempt an in-flight transfer

    wire g0 = (grant == M0);
    wire g1 = (grant == M1);

    assign active = (grant != NONE);
    assign haddr  = g0 ? m0_haddr  : m1_haddr;
    assign htrans = g0 ? m0_htrans : (g1 ? m1_htrans : 2'b00);
    assign hwrite = g0 ? m0_hwrite : m1_hwrite;
    assign hsize  = g0 ? m0_hsize  : m1_hsize;
    assign hburst = g0 ? m0_hburst : m1_hburst;
    assign hwdata = g0 ? m0_hwdata : {m1_hwdata, m1_hwdata};

    assign m0_hready = g0 ? hready : 1'b0;   // stall non-granted master
    assign m1_hready = g1 ? hready : 1'b0;
    assign m0_hrdata = hrdata;
    reg m1_lane;                              // HADDR[2] of master 1's data phase
    always @(posedge clk or negedge rstn)
        if (!rstn)                          m1_lane <= 1'b0;
        else if (g1 && m1_htrans[1] && hready) m1_lane <= m1_haddr[2];
    assign m1_hrdata = m1_lane ? hrdata[63:32] : hrdata[31:0];
    assign m0_hresp  = g0 ? hresp : 1'b0;
    assign m1_hresp  = g1 ? hresp : 1'b0;
endmodule
`default_nettype wire
