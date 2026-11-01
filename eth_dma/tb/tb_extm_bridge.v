`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_extm_bridge.v -- 32-bit ahb_master -> extm_bridge -> 64-bit RAM.
// Write then read 16 words at consecutive addresses (HADDR[2] alternates 0/1);
// verify the readback, proving the 32<->64 lane handling is correct.
//============================================================================
module tb_extm_bridge;
    reg clk = 0; always #5 clk = ~clk;
    reg rstn = 0;

    // ahb_master command + data
    reg         cmd_valid = 0, cmd_wr = 0;
    reg  [31:0] cmd_addr = 0;
    reg  [15:0] cmd_len = 0;
    wire        cmd_ready, cmd_done, busy, w_req, r_valid;
    wire [31:0] r_data;

    // write source / read sink
    reg  [31:0] src [0:15];
    integer     wi = 0, ri = 0, errors = 0;
    wire [31:0] w_data = src[wi];
    always @(posedge clk) if (w_req) wi <= wi + 1;
    always @(posedge clk) if (r_valid) begin
        if (r_data !== src[ri]) begin errors = errors + 1; $display("  word %0d got %08x exp %08x", ri, r_data, src[ri]); end
        ri <= ri + 1;
    end

    // 32-bit master AHB
    wire [31:0] a_haddr, a_hwdata, a_hrdata;
    wire [1:0]  a_htrans; wire a_hwrite, a_hready, a_hresp; wire [2:0] a_hsize, a_hburst;
    // 64-bit EXTM AHB
    wire [31:0] e_haddr; wire [1:0] e_htrans; wire e_hwrite; wire [2:0] e_hsize, e_hburst;
    wire [3:0]  e_hprot; wire [63:0] e_hwdata, e_hrdata; wire e_hsel, e_hready, e_hreadyout, e_hresp;

    ahb_master m (
        .hclk(clk), .hresetn(rstn), .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_addr(cmd_addr), .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done),
        .cmd_err(), .busy(busy), .w_req(w_req), .w_data(w_data), .r_valid(r_valid), .r_data(r_data),
        .haddr(a_haddr), .htrans(a_htrans), .hwrite(a_hwrite), .hsize(a_hsize),
        .hburst(a_hburst), .hwdata(a_hwdata), .hrdata(a_hrdata), .hready(a_hready), .hresp(a_hresp)
    );
    extm_bridge br (
        .hclk(clk), .hresetn(rstn),
        .a_haddr(a_haddr), .a_htrans(a_htrans), .a_hwrite(a_hwrite), .a_hsize(a_hsize),
        .a_hburst(a_hburst), .a_hwdata(a_hwdata), .a_active(busy), .a_hready_in(e_hreadyout),
        .a_hrdata(a_hrdata), .a_hready(a_hready), .a_hresp(a_hresp),
        .extm_haddr(e_haddr), .extm_htrans(e_htrans), .extm_hwrite(e_hwrite), .extm_hsize(e_hsize),
        .extm_hburst(e_hburst), .extm_hprot(e_hprot), .extm_hwdata(e_hwdata), .extm_hsel(e_hsel),
        .extm_hready(e_hready), .extm_hrdata(e_hrdata), .extm_hreadyout(e_hreadyout), .extm_hresp(e_hresp)
    );
    ahb_slave_ram64 #(.AW(12)) ram (
        .hclk(clk), .hresetn(rstn), .haddr(e_haddr), .htrans(e_htrans), .hwrite(e_hwrite),
        .hsize(e_hsize), .hburst(e_hburst), .hwdata(e_hwdata), .hsel(e_hsel), .hready_in(e_hready),
        .hrdata(e_hrdata), .hready(e_hreadyout), .hresp(e_hresp)
    );

    integer i;
    task do_cmd(input [31:0] addr, input [15:0] len, input wr);
        begin
            @(negedge clk); cmd_valid=1; cmd_addr=addr; cmd_len=len; cmd_wr=wr;
            @(posedge clk);                  // master (idle) accepts here
            @(negedge clk); cmd_valid=0;
            @(posedge cmd_done);
        end
    endtask

    initial begin
        for (i = 0; i < 16; i = i + 1) src[i] = 32'hE0000000 + i*32'h11111 + 1;
        repeat (3) @(posedge clk); rstn = 1; @(negedge clk);
        do_cmd(32'h0, 16'd16, 1'b1);     // write 16 words @ 0,4,8,... (HADDR[2] alternates)
        repeat (2) @(posedge clk);
        do_cmd(32'h0, 16'd16, 1'b0);     // read them back
        repeat (4) @(posedge clk);
        if (errors == 0 && ri == 16) $display("RESULT: PASS (16 words 32<->64 lane-bridged through EXTM, read back intact)");
        else $display("RESULT: FAIL (%0d errors, ri=%0d)", errors, ri);
        $finish;
    end
    initial begin #20000; $display("RESULT: FAIL (timeout ri=%0d)", ri); $finish; end
endmodule
`default_nettype wire
