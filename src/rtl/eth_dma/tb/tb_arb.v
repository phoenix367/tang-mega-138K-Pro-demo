`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_arb.v -- simulate the REAL Gowin arbiter (.vo gate-level netlist) with our
// ahb_master driving master-port 1 (TX) into an AHB slave, to reproduce the HW
// "arbiter never forwards" hang and test the MHREADYS connection.
//   default            : MHREADYS = MHREADYOUTS (feedback, as on HW)  -> expect HANG
//   -DMREADY1          : MHREADYS = 1'b1                              -> expect PASS
//============================================================================
module tb_arb;
    reg clk = 0; always #10 clk = ~clk;        // 50 MHz (EXTS_HCLK)
    reg rstn = 0;

    GSR GSR (.GSRI(1'b1));                      // Gowin global set/reset (sim)

    // ahb_master (TX) command
    reg         cmd_valid = 0, cmd_wr = 0;
    reg  [31:0] cmd_addr = 0;
    reg  [15:0] cmd_len = 0;
    wire        cmd_ready, cmd_done, busy, w_req, r_valid;
    wire [31:0] r_data;
    reg  [31:0] w_data = 32'hA5A50001;

    // master 1 AHB (from ahb_master)
    wire [31:0] m1_haddr, m1_hwdata, m1_hrdata;
    wire [1:0]  m1_htrans;
    wire        m1_hwrite, m1_hready, m1_hresp;
    wire [2:0]  m1_hsize, m1_hburst;
    wire [1:0]  m1_hresp2;
    assign m1_hresp = m1_hresp2[0];

    // master 0 (RX) idle
    wire [31:0] m0_hrdata; wire m0_hready; wire [1:0] m0_hresp2;
    wire        m0_hready_w = m0_hready;

    // slave (SH*M0) side
    wire [31:0] sh_haddr, sh_hwdata, sh_hrdata;
    wire [1:0]  sh_htrans, sh_hresp;
    wire        sh_hwrite, sh_hsel, sh_hready_mux, sh_hreadyout;
    wire [2:0]  sh_hsize, sh_hburst;

`ifdef MREADY1
    wire mr0 = 1'b1, mr1 = 1'b1;
`else
    wire mr0 = m0_hready, mr1 = m1_hready;
`endif

    ahb_master m_tx (
        .hclk(clk), .hresetn(rstn), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done),
        .cmd_err(), .busy(busy), .w_req(w_req), .w_data(w_data), .r_valid(r_valid), .r_data(r_data),
        .haddr(m1_haddr), .htrans(m1_htrans), .hwrite(m1_hwrite), .hsize(m1_hsize),
        .hburst(m1_hburst), .hwdata(m1_hwdata), .hrdata(m1_hrdata), .hready(m1_hready), .hresp(m1_hresp)
    );

    Eth_AHB_Arbiter_Top arb (
        .HCLK(clk), .HRESETn(rstn),
        // master 0 (idle)
        .MHSELS0(1'b0), .MHADDRS0(32'b0), .MHTRANSS0(2'b00), .MHWRITES0(1'b0),
        .MHSIZES0(3'b0), .MHBURSTS0(3'b0), .MHPROTS0(4'b0011), .MHMASTERS0(4'b0),
        .MHWDATAS0(32'b0), .MHMASTLOCKS0(1'b0), .MHREADYS0(mr0),
        .MHRDATAS0(m0_hrdata), .MHREADYOUTS0(m0_hready), .MHRESPS0(m0_hresp2),
        // master 1 (TX)
        .MHSELS1(busy), .MHADDRS1(m1_haddr), .MHTRANSS1(m1_htrans), .MHWRITES1(m1_hwrite),
        .MHSIZES1(m1_hsize), .MHBURSTS1(m1_hburst), .MHPROTS1(4'b0011), .MHMASTERS1(4'b0),
        .MHWDATAS1(m1_hwdata), .MHMASTLOCKS1(1'b0), .MHREADYS1(mr1),
        .MHRDATAS1(m1_hrdata), .MHREADYOUTS1(m1_hready), .MHRESPS1(m1_hresp2),
        // shared slave
        .SHSELM0(sh_hsel), .SHADDRM0(sh_haddr), .SHTRANSM0(sh_htrans), .SHWRITEM0(sh_hwrite),
        .SHSIZEM0(sh_hsize), .SHBURSTM0(sh_hburst), .SHPROTM0(), .SHMASTERM0(),
        .SHWDATAM0(sh_hwdata), .SHMASTLOCKM0(), .SHREADYMUXM0(sh_hready_mux),
        .SHRDATAM0(sh_hrdata), .SHREADYOUTM0(sh_hreadyout), .SHRESPM0({1'b0, 1'b0})
    );

    ahb_slave_simple #(.AW(10)) slv (
        .hclk(clk), .hresetn(rstn), .haddr(sh_haddr), .htrans(sh_htrans), .hwrite(sh_hwrite),
        .hsize(sh_hsize), .hburst(sh_hburst), .hwdata(sh_hwdata), .hsel(sh_hsel),
        .hready_in(sh_hready_mux), .hrdata(sh_hrdata), .hready(sh_hreadyout), .hresp(sh_hresp)
    );

    integer seen_hsel = 0;
    reg [31:0] fwd_addr = 32'hDEADBEEF;
    always @(posedge clk) if (sh_hsel) begin seen_hsel = 1; fwd_addr = sh_haddr; end

    initial begin
        repeat (4) @(posedge clk); rstn = 1; repeat (3) @(posedge clk);
        @(negedge clk); cmd_valid = 1; cmd_addr = `TADDR; cmd_len = 16'd1; cmd_wr = 1'b0;
        @(posedge clk); @(negedge clk); cmd_valid = 0;
        // wait up to 200 cycles for the read to complete
        begin : wait_done integer k;
            for (k = 0; k < 200; k = k + 1) begin
                @(posedge clk);
                if (cmd_done) disable wait_done;
            end
        end
        repeat (2) @(posedge clk);
        $display("RESULT: cmd_done=%0d  SHSEL=%0d  SHADDRM0=%08x  (master addr was %08x)",
                 cmd_done_seen, seen_hsel, fwd_addr, cmd_addr);
        if (cmd_done_seen && seen_hsel) $display("RESULT: PASS (arbiter forwarded + completed the read)");
        else $display("RESULT: FAIL (arbiter wedged: forwarded=%0d done=%0d)", seen_hsel, cmd_done_seen);
        $finish;
    end
    reg cmd_done_seen = 0;
    always @(posedge clk) if (cmd_done) cmd_done_seen = 1;
    initial begin #50000; $display("RESULT: FAIL (timeout) forwarded=%0d", seen_hsel); $finish; end
endmodule
`default_nettype wire
