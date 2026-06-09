`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_ahb_master.v -- self-checking testbench: ahb_master writes a pattern to
// the AHB slave RAM, reads it back, and verifies it matches.
//============================================================================
module tb_ahb_master;
    localparam N = 16;             // words per transfer

    reg hclk = 1'b0;
    reg hresetn = 1'b0;
    always #5 hclk = ~hclk;        // 100 MHz

    // AHB bus master<->slave
    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;

    // command
    reg         cmd_valid = 1'b0, cmd_wr = 1'b0;
    reg  [31:0] cmd_addr  = 32'd0;
    reg  [15:0] cmd_len   = 16'd0;
    wire        cmd_ready, cmd_done, cmd_err;

    // write source / read sink
    wire        w_req;
    wire        r_valid;
    wire [31:0] r_data;
    reg  [31:0] wsrc [0:255];
    reg  [31:0] rdst [0:255];
    integer     widx, ridx;

    wire [31:0] w_data = wsrc[widx];

    ahb_master dut (
        .hclk(hclk), .hresetn(hresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr),
        .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done), .cmd_err(cmd_err),
        .w_req(w_req), .w_data(w_data), .r_valid(r_valid), .r_data(r_data),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    ahb_slave_ram #(.AW(12)) slv (
        .hclk(hclk), .hresetn(hresetn),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    // write index: reset on a write command being accepted, advance per beat
    always @(posedge hclk) begin
        if (!hresetn)                                widx <= 0;
        else if (cmd_valid && cmd_ready && cmd_wr)   widx <= 0;
        else if (w_req)                              widx <= widx + 1;
    end
    // read index: reset on a read command, capture each pushed word
    always @(posedge hclk) begin
        if (!hresetn)                                ridx <= 0;
        else if (cmd_valid && cmd_ready && !cmd_wr)  ridx <= 0;
        else if (r_valid) begin rdst[ridx] <= r_data; ridx <= ridx + 1; end
    end

    task run_cmd(input [31:0] a, input [15:0] n, input w);
        begin
            @(posedge hclk);
            while (!cmd_ready) @(posedge hclk);
            cmd_addr <= a; cmd_len <= n; cmd_wr <= w; cmd_valid <= 1'b1;
            @(posedge hclk);                 // accepted here (cmd_ready was 1)
            cmd_valid <= 1'b0;
            while (!cmd_done) @(posedge hclk);
        end
    endtask

    integer i, errors;
    initial begin
        errors = 0;
        for (i = 0; i < N; i = i + 1) wsrc[i] = 32'hDEAD0000 + i*4 + 1;
        repeat (4) @(posedge hclk);
        hresetn = 1'b1;
        repeat (2) @(posedge hclk);

        run_cmd(32'h0000_0040, N, 1'b1);     // write N words at byte addr 0x40
        run_cmd(32'h0000_0040, N, 1'b0);     // read them back
        repeat (3) @(posedge hclk);

        for (i = 0; i < N; i = i + 1) begin
            if (rdst[i] !== wsrc[i]) begin
                errors = errors + 1;
                $display("  MISMATCH word %0d: wrote %08x read %08x", i, wsrc[i], rdst[i]);
            end
        end
        if (errors == 0) $display("RESULT: PASS (%0d words round-tripped through AHB)", N);
        else             $display("RESULT: FAIL (%0d mismatches)", errors);
        $finish;
    end

    initial begin
        #20000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
`default_nettype wire
