`default_nettype none
//============================================================================
// ahb_arbiter3.v -- 3-master AHB-lite arbiter for the EXTM port.
//
// Same scheme as eth_dma/rtl/eth_ahb_arbiter.v (registered grant held for the
// whole command of a master, full 32-bit address, 64-bit merged bus) with a
// third master for the SD host DMA.  Fixed priority: master 0 (Ethernet RX
// write, cannot be back-pressured) > master 2 (SD host, 64-bit, 1 KB FIFO)
// > master 1 (Ethernet TX read, 32-bit).
//============================================================================
module ahb_arbiter3 (
    input  wire        clk,
    input  wire        rstn,
    // master 0 (RX write, priority, 64-bit)
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
    // master 1 (TX read, 32-bit)
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
    // master 2 (SD host DMA, 64-bit)
    input  wire        m2_busy,
    input  wire [31:0] m2_haddr,
    input  wire [1:0]  m2_htrans,
    input  wire        m2_hwrite,
    input  wire [2:0]  m2_hsize,
    input  wire [2:0]  m2_hburst,
    input  wire [63:0] m2_hwdata,
    output wire [63:0] m2_hrdata,
    output wire        m2_hready,
    output wire        m2_hresp,
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
    localparam [1:0] NONE = 2'd0, M0 = 2'd1, M1 = 2'd2, M2 = 2'd3;

    reg  [1:0] grant;
    wire holding = (grant == M0 && m0_busy) || (grant == M1 && m1_busy) || (grant == M2 && m2_busy);

    always @(posedge clk or negedge rstn)
        if (!rstn)         grant <= NONE;
        else if (!holding) grant <= m0_busy ? M0 : (m2_busy ? M2 : (m1_busy ? M1 : NONE));

    wire g0 = (grant == M0);
    wire g1 = (grant == M1);
    wire g2 = (grant == M2);

    assign active = (grant != NONE);
    assign haddr  = g0 ? m0_haddr  : g2 ? m2_haddr  : m1_haddr;
    assign htrans = g0 ? m0_htrans : g2 ? m2_htrans : (g1 ? m1_htrans : 2'b00);
    assign hwrite = g0 ? m0_hwrite : g2 ? m2_hwrite : m1_hwrite;
    assign hsize  = g0 ? m0_hsize  : g2 ? m2_hsize  : m1_hsize;
    assign hburst = g0 ? m0_hburst : g2 ? m2_hburst : m1_hburst;
    assign hwdata = g0 ? m0_hwdata : g2 ? m2_hwdata : {m1_hwdata, m1_hwdata};

    assign m0_hready = g0 ? hready : 1'b0;
    assign m1_hready = g1 ? hready : 1'b0;
    assign m2_hready = g2 ? hready : 1'b0;
    assign m0_hrdata = hrdata;
    assign m2_hrdata = hrdata;
    reg m1_lane;
    always @(posedge clk or negedge rstn)
        if (!rstn)                             m1_lane <= 1'b0;
        else if (g1 && m1_htrans[1] && hready) m1_lane <= m1_haddr[2];
    assign m1_hrdata = m1_lane ? hrdata[63:32] : hrdata[31:0];
    assign m0_hresp  = g0 ? hresp : 1'b0;
    assign m1_hresp  = g1 ? hresp : 1'b0;
    assign m2_hresp  = g2 ? hresp : 1'b0;
endmodule
`default_nettype wire
