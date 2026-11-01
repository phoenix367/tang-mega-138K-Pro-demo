`timescale 1ns/1ps
// Sanity test for src/ddr_perf.v: drive a few AHB transfers with known wait
// states and check the counters / trace through the APB port.
module tb_ddr_perf;
    reg hclk = 0, pclk = 0, rstn = 0;
    always #10 hclk = ~hclk;
    always #10 pclk = ~pclk;

    reg  [31:0] haddr = 0; reg [1:0] htrans = 0; reg hwrite = 0;
    reg  [2:0]  hsize = 3; reg [2:0] hburst = 0; reg hready = 1;
    reg  psel = 0, penable = 0, pwrite = 0; reg [31:0] paddr = 0, pwdata = 0;
    wire [31:0] prdata; wire pready, pslverr;

    ddr_perf #(.CONFIG(32'h0000_00C8)) dut (
        .hclk(hclk), .hresetn(rstn), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hburst_i(hburst), .hready_i(hready), .ext_cnt({256'd0, 32'd8,32'd7,32'd6,32'd5,32'd4, 32'd3, 32'd2, 32'd1}), .en(), .clr(), .mode(),
        .pclk(pclk), .presetn(rstn), .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata), .pready(pready), .pslverr(pslverr));

    task apb_w(input [31:0] a, input [31:0] d); begin
        @(posedge pclk); psel <= 1; pwrite <= 1; paddr <= a; pwdata <= d;
        @(posedge pclk); penable <= 1;
        @(posedge pclk); while (!pready) @(posedge pclk);
        psel <= 0; penable <= 0; pwrite <= 0;
    end endtask
    reg [31:0] rd;
    task apb_r(input [31:0] a); begin
        @(posedge pclk); psel <= 1; pwrite <= 0; paddr <= a;
        @(posedge pclk); penable <= 1;
        @(posedge pclk); while (!pready) @(posedge pclk);
        #1 rd = prdata;
        psel <= 0; penable <= 0;
    end endtask

    // AHB burst: n beats, each data phase stalls `w` cycles
    task burst(input wr, input [2:0] hb, input [31:0] a, input integer n, input integer w);
        integer b, k; begin
        for (b = 0; b < n; b = b + 1) begin
            @(posedge hclk); haddr <= a + 8*b; htrans <= (b == 0) ? 2'b10 : 2'b11;
            hwrite <= wr; hburst <= hb; hready <= 1;
            // data phase: w wait cycles
            for (k = 0; k < w; k = k + 1) begin @(posedge hclk); hready <= 0; end
        end
        @(posedge hclk); hready <= 1; htrans <= 0;   // completes the last data phase
        @(posedge hclk);
    end endtask

    integer errs = 0;
    task chk(input [31:0] a, input [31:0] exp); begin
        apb_r(a);
        if (rd !== exp) begin errs = errs + 1; $display("FAIL @%h: got %0d (0x%h) exp %0d", a, rd, rd, exp); end
        else $display("ok   @%h = %0d", a, rd);
    end endtask

    initial begin
        #55 rstn = 1;
        chk(32'h000, 32'hDD3B00C8);
        apb_w(32'h004, 32'h2);            // clear
        apb_w(32'h004, 32'h5);            // en + arm
        repeat (4) @(posedge hclk);
        burst(0, 3'd3, 32'h1000, 4, 5);   // INCR4 read, 5 waits/beat
        burst(1, 3'd2, 32'h2000, 4, 2);   // WRAP4 write, 2 waits/beat
        burst(0, 3'd0, 32'h3004, 1, 7);   // SINGLE read, 7 waits
        repeat (4) @(posedge hclk);
        apb_w(32'h004, 32'h0);            // stop
        repeat (4) @(posedge hclk);
        chk(32'h104, 2);   // rd_bursts
        chk(32'h108, 1);   // wr_bursts
        chk(32'h10C, 5);   // rd_beats
        chk(32'h110, 4);   // wr_beats
        chk(32'h114, 4*5+7);  // rd_wait
        chk(32'h118, 4*2);    // wr_wait
        chk(32'h11C, 5+7);    // rd_first_wait
        chk(32'h120, 7);      // rd_wait_max
        chk(32'h124, 2);      // wr_wait_max
        chk(32'h130+4*0, 1);  // read SINGLE
        chk(32'h130+4*3, 1);  // read INCR4
        chk(32'h150+4*2, 1);  // write WRAP4
        chk(32'h170+4*3, 2);  // read dword
        chk(32'h190, 32'h1);  // ext0
        chk(32'h19C, 32'h4);  // ext3
        chk(32'h1AC, 32'h8);  // ext7
        apb_r(32'h008); $display("trace status %h", rd);
        apb_w(32'h00C, 0); apb_r(32'h010); $display("trace[0] lo %h", rd); apb_r(32'h014); $display("trace[0] hi %h", rd);
        apb_w(32'h00C, 1); apb_r(32'h010); $display("trace[1] lo %h", rd); apb_r(32'h014); $display("trace[1] hi %h", rd);
        if (errs) $display("TEST FAILED (%0d errors)", errs); else $display("TEST PASSED");
        $finish;
    end
endmodule
