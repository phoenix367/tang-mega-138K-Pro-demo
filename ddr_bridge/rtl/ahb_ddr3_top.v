`default_nettype none
//============================================================================
// ahb_ddr3_top.v -- SoC data-memory AHB (DDR_H*) -> DDR3 SDRAM.
//
// ahb_ddr3_bridge (line-buffered, burst-aware AHB slave) in front of the
// Gowin DDR3 Memory Interface IP (DDR3_Memory_Interface_Top, 1:4, x16).
// Drop-in replacement for Gowin's gw_ahb_ddr3_top (same DDR3/AHB ports), plus
// HPROT, the ddr_perf counter hookup and the bridge's read-only video port
// (in the DDR3 IP user clock, exported as VCLK).
//============================================================================
module ahb_ddr3_top #(
    parameter ADDR_BITS = 29,          // DDR bytes = 2**ADDR_BITS: 512 MB (x16, 15 row bits)
    parameter NBUF     = 8,
    parameter PREFETCH = 1,
    parameter PF_DIST  = 2
) (
    // DDR3 memory interface
    input  wire         DDR3_MEMORY_CLK,    // memory clock (4x user clock)
    input  wire         DDR3_CLK_IN,        // 50 MHz IP reference clock
    input  wire         DDR3_RSTN,          // reset, 0 = reset
    input  wire         DDR3_LOCK,          // DDR3 PLL lock
    output wire         DDR3_STOP,          // DDR3 PLL clock-output enable
    output wire         DDR3_INIT,          // calibration complete
    output wire [2:0]   DDR3_BANK,
    output wire         DDR3_CS_N,
    output wire         DDR3_RAS_N,
    output wire         DDR3_CAS_N,
    output wire         DDR3_WE_N,
    output wire         DDR3_CK,
    output wire         DDR3_CK_N,
    output wire         DDR3_CKE,
    output wire         DDR3_RESET_N,
    output wire         DDR3_ODT,
    output wire [ADDR_BITS-15:0] DDR3_ADDR,   // row address: ADDR_BITS-14 bits
    output wire [1:0]   DDR3_DM,
    inout  wire [15:0]  DDR3_DQ,
    inout  wire [1:0]   DDR3_DQS,
    inout  wire [1:0]   DDR3_DQS_N,
    // AHB bus interface (SoC customized data memory)
    input  wire         HCLK,
    input  wire         HRESETN,
    input  wire [31:0]  HADDR,
    input  wire [2:0]   HSIZE,
    input  wire         HWRITE,
    input  wire [1:0]   HTRANS,
    input  wire [2:0]   HBURST,
    input  wire [3:0]   HPROT,
    input  wire [63:0]  HWDATA,
    output wire         HREADY_O,
    output wire [1:0]   HRESP,
    output wire [63:0]  HRDATA,
    // ddr_perf hookup (HCLK domain) + debug mode bits (quasi-static)
    input  wire [31:0]  MODE,
    input  wire         PERF_EN,
    input  wire         PERF_CLR,
    output wire [511:0] PERF_CNT,
    // video read port (VCLK domain, see ahb_ddr3_bridge): BL8 = 16 B reads
    output wire         VCLK,               // DDR3 IP user clock (100 MHz)
    output wire         VRSTN,              // VCLK reset, released after calibration
    input  wire         V_REQ,
    input  wire [31:0]  V_ADDR,             // byte address, 16 B aligned (bits above ADDR_BITS ignored)
    output wire         V_ACK,
    output wire         V_RVALID,
    output wire [127:0] V_RDATA
);
    // IP reset: synchronous release in the IP's clk domain (IPUG281 4.4.3)
    reg [1:0] rst_s;
    always @(posedge DDR3_CLK_IN or negedge DDR3_RSTN)
        if (!DDR3_RSTN) rst_s <= 2'b00; else rst_s <= {rst_s[0], 1'b1};

    wire         uclk;
    wire         calib_done;
    wire         cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid;
    wire [2:0]   cmd;
    wire [ADDR_BITS-1:0] addr;
    wire [127:0] wr_data, rd_data;
    wire [15:0]  wr_data_mask;

    assign DDR3_INIT = calib_done;
    assign VCLK      = uclk;

    DDR3_Memory_Interface_Top u_ddr3 (
        .clk                 (DDR3_CLK_IN),
        .pll_stop            (DDR3_STOP),
        .memory_clk          (DDR3_MEMORY_CLK),
        .pll_lock            (DDR3_LOCK),
        .rst_n               (rst_s[1]),
        .clk_out             (uclk),
        .ddr_rst             (),
        .init_calib_complete (calib_done),
        .cmd_ready           (cmd_ready),
        .cmd                 (cmd),
        .cmd_en              (cmd_en),
        .addr                (addr),
        .wr_data_rdy         (wr_data_rdy),
        .wr_data             (wr_data),
        .wr_data_en          (wr_data_en),
        .wr_data_end         (wr_data_end),
        .wr_data_mask        (wr_data_mask),
        .rd_data             (rd_data),
        .rd_data_valid       (rd_data_valid),
        .rd_data_end         (),
        .sr_req              (1'b0),
        .ref_req             (1'b0),
        .sr_ack              (),
        .ref_ack             (),
        .burst               (1'b1),
        .O_ddr_addr          (DDR3_ADDR),
        .O_ddr_ba            (DDR3_BANK),
        .O_ddr_cs_n          (DDR3_CS_N),
        .O_ddr_ras_n         (DDR3_RAS_N),
        .O_ddr_cas_n         (DDR3_CAS_N),
        .O_ddr_we_n          (DDR3_WE_N),
        .O_ddr_clk           (DDR3_CK),
        .O_ddr_clk_n         (DDR3_CK_N),
        .O_ddr_cke           (DDR3_CKE),
        .O_ddr_odt           (DDR3_ODT),
        .O_ddr_reset_n       (DDR3_RESET_N),
        .O_ddr_dqm           (DDR3_DM),
        .IO_ddr_dq           (DDR3_DQ),
        .IO_ddr_dqs          (DDR3_DQS),
        .IO_ddr_dqs_n        (DDR3_DQS_N)
    );

    ahb_ddr3_bridge #(
        .ADDR_BITS (ADDR_BITS),
        .NBUF      (NBUF),
        .PREFETCH  (PREFETCH),
        .PF_DIST   (PF_DIST)
    ) u_bridge (
        .hclk          (HCLK),
        .hresetn       (HRESETN),
        .haddr         (HADDR),
        .htrans        (HTRANS),
        .hwrite        (HWRITE),
        .hsize         (HSIZE),
        .hburst        (HBURST),
        .hprot         (HPROT),
        .hwdata        (HWDATA),
        .hready        (HREADY_O),
        .hresp         (HRESP),
        .hrdata        (HRDATA),
        .mode          (MODE),
        .perf_en       (PERF_EN),
        .perf_clr      (PERF_CLR),
        .perf_cnt      (PERF_CNT),
        .uclk          (uclk),
        .calib_done    (calib_done),
        .cmd_ready     (cmd_ready),
        .cmd           (cmd),
        .cmd_en        (cmd_en),
        .addr          (addr),
        .wr_data_rdy   (wr_data_rdy),
        .wr_data       (wr_data),
        .wr_data_en    (wr_data_en),
        .wr_data_end   (wr_data_end),
        .wr_data_mask  (wr_data_mask),
        .rd_data       (rd_data),
        .rd_data_valid (rd_data_valid),
        .v_rstn        (VRSTN),
        .v_req         (V_REQ),
        .v_addr        (V_ADDR[ADDR_BITS-1:0]),
        .v_ack         (V_ACK),
        .v_rvalid      (V_RVALID),
        .v_rdata       (V_RDATA)
    );
endmodule
`default_nettype wire
