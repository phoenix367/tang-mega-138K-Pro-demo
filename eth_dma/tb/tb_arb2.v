`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_arb2.v -- two ahb_masters contending on eth_ahb_arbiter, with master0 (RX
// write) starting WHILE master1 (TX read) is mid-transfer. Verifies the arbiter
// does not preempt the in-flight read (m1 reads correct data) and m0's writes
// land afterwards -- the registered-grant / no-preemption property.
//============================================================================
module tb_arb2;
    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;

    // master 0 (RX write)
    reg         c0_valid = 0, c0_wr = 0; reg [31:0] c0_addr = 0; reg [15:0] c0_len = 0;
    wire        c0_ready, c0_done, m0_busy, w0_req, r0_valid; wire [31:0] r0_data;
    reg  [31:0] w0_src [0:15]; integer wi0 = 0;
    wire [31:0] w0_data = w0_src[wi0];
    always @(posedge clk) if (w0_req) wi0 <= wi0 + 1;

    // master 1 (TX read)
    reg         c1_valid = 0, c1_wr = 0; reg [31:0] c1_addr = 0; reg [15:0] c1_len = 0;
    wire        c1_ready, c1_done, m1_busy, w1_req, r1_valid; wire [31:0] r1_data;
    integer     ri1 = 0, errors = 0;
    always @(posedge clk) if (r1_valid) begin
        if (r1_data !== 32'hBB000000 + ri1) begin errors=errors+1; $display("  m1 rd %0d got %08x exp %08x", ri1, r1_data, 32'hBB000000+ri1); end
        ri1 <= ri1 + 1;
    end

    // master AHB buses
    wire [31:0] a0h, a0wd, a0rd, a1h, a1wd, a1rd; wire [1:0] a0t, a1t, a0rs, a1rs;
    wire a0w, a0rdy, a1w, a1rdy; wire [2:0] a0sz, a0bt, a1sz, a1bt;
    // merged
    wire [31:0] mh, mwd, mrd; wire [1:0] mt; wire mw, mrdy, mrs2; wire [2:0] msz, mbt; wire mact, mrs;
    assign mrs = 1'b0;

    ahb_master m0 (.hclk(clk), .hresetn(rstn), .cmd_valid(c0_valid), .cmd_ready(c0_ready),
        .cmd_addr(c0_addr), .cmd_len(c0_len), .cmd_wr(c0_wr), .cmd_done(c0_done), .cmd_err(), .busy(m0_busy),
        .w_req(w0_req), .w_data(w0_data), .r_valid(r0_valid), .r_data(r0_data),
        .haddr(a0h), .htrans(a0t), .hwrite(a0w), .hsize(a0sz), .hburst(a0bt), .hwdata(a0wd),
        .hrdata(a0rd), .hready(a0rdy), .hresp(a0rs[0]));
    ahb_master m1 (.hclk(clk), .hresetn(rstn), .cmd_valid(c1_valid), .cmd_ready(c1_ready),
        .cmd_addr(c1_addr), .cmd_len(c1_len), .cmd_wr(c1_wr), .cmd_done(c1_done), .cmd_err(), .busy(m1_busy),
        .w_req(w1_req), .w_data(32'b0), .r_valid(r1_valid), .r_data(r1_data),
        .haddr(a1h), .htrans(a1t), .hwrite(a1w), .hsize(a1sz), .hburst(a1bt), .hwdata(a1wd),
        .hrdata(a1rd), .hready(a1rdy), .hresp(a1rs[0]));

    eth_ahb_arbiter arb (.clk(clk), .rstn(rstn),
        .m0_busy(m0_busy), .m0_haddr(a0h), .m0_htrans(a0t), .m0_hwrite(a0w), .m0_hsize(a0sz), .m0_hburst(a0bt),
        .m0_hwdata(a0wd), .m0_hrdata(a0rd), .m0_hready(a0rdy), .m0_hresp(a0rs[0]),
        .m1_busy(m1_busy), .m1_haddr(a1h), .m1_htrans(a1t), .m1_hwrite(a1w), .m1_hsize(a1sz), .m1_hburst(a1bt),
        .m1_hwdata(a1wd), .m1_hrdata(a1rd), .m1_hready(a1rdy), .m1_hresp(a1rs[0]),
        .active(mact), .haddr(mh), .htrans(mt), .hwrite(mw), .hsize(msz), .hburst(mbt), .hwdata(mwd),
        .hrdata(mrd), .hready(mrdy), .hresp(mrs));

    ahb_slave_simple #(.AW(12)) slv (.hclk(clk), .hresetn(rstn), .haddr(mh), .htrans(mt), .hwrite(mw),
        .hsize(msz), .hburst(mbt), .hwdata(mwd), .hsel(mact), .hready_in(mrdy), .hrdata(mrd), .hready(mrdy), .hresp());
    assign a0rs[1]=0; assign a1rs[1]=0;

    integer i;
    initial begin
        for (i=0;i<16;i=i+1) begin w0_src[i] = 32'hAA000000 + i; slv.mem[(32'h200>>2)+i] = 32'hBB000000 + i; end
        repeat (3) @(posedge clk); rstn = 1; @(negedge clk);
        // m1: read 8 words @ 0x200
        c1_valid=1; c1_addr=32'h200; c1_len=16'd8; c1_wr=0;
        @(posedge clk); @(negedge clk); c1_valid=0;
        // m0: write 8 words @ 0x100, started a few cycles into m1's read
        repeat (2) @(negedge clk);
        c0_valid=1; c0_addr=32'h100; c0_len=16'd8; c0_wr=1;
        @(posedge clk); @(negedge clk); c0_valid=0;
        // wait for both
        repeat (120) @(posedge clk);
        // check m0's writes landed
        for (i=0;i<8;i=i+1) if (slv.mem[(32'h100>>2)+i] !== 32'hAA000000+i) begin
            errors=errors+1; $display("  m0 wr %0d got %08x exp %08x", i, slv.mem[(32'h100>>2)+i], 32'hAA000000+i); end
        if (errors==0 && ri1==8) $display("RESULT: PASS (concurrent RX-write + TX-read; no preemption, data intact)");
        else $display("RESULT: FAIL (%0d errors, m1 reads=%0d)", errors, ri1);
        $finish;
    end
    initial begin #20000; $display("RESULT: FAIL (timeout, m1 reads=%0d)", ri1); $finish; end
endmodule
`default_nettype wire
