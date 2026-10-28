`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_ahb_master.v -- self-checking testbench: ahb_master writes patterns to
// the AHB slave RAM over many lengths/alignments (bursts up to INCR16, some
// meeting a 1 KB boundary), reads each back and verifies it; the slave checks
// the burst protocol.  WAIT_PCT (iverilog -P) adds random slave wait states.
// On a zero-wait slave a long write must take ~1 cycle per beat (pipelined).
//============================================================================
module tb_ahb_master;
    parameter WAIT_PCT  = 0;
    parameter MAX_BURST = 16;      // ahb_master write bursts (0 = INCR to 1 KB)

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
    reg  [31:0] wsrc [0:511];
    reg  [31:0] rdst [0:511];
    integer     widx, ridx;

    wire [31:0] w_data = wsrc[widx];

    ahb_master #(.MAX_BURST(MAX_BURST)) dut (
        .hclk(hclk), .hresetn(hresetn),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_addr(cmd_addr),
        .cmd_len(cmd_len), .cmd_wr(cmd_wr), .cmd_done(cmd_done), .cmd_err(cmd_err),
        .w_req(w_req), .w_data(w_data), .r_valid(r_valid), .r_data(r_data),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize),
        .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    ahb_slave_ram #(.AW(12), .WAIT_PCT(WAIT_PCT)) slv (
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

    integer cycles;
    task run_cmd(input [31:0] a, input [15:0] n, input w);
        begin
            @(posedge hclk);
            while (!cmd_ready) @(posedge hclk);
            cmd_addr <= a; cmd_len <= n; cmd_wr <= w; cmd_valid <= 1'b1;
            @(posedge hclk);                 // accepted here (cmd_ready was 1)
            cmd_valid <= 1'b0;
            cycles = 1;
            while (!cmd_done) begin @(posedge hclk); cycles = cycles + 1; end
        end
    endtask

    // (start address, words): odd lengths, unaligned starts, 1 KB crossings
    integer t, i, errors, n;
    reg [31:0] a;
    reg [31:0] addrs [0:9];
    integer    lens  [0:9];
    initial begin
        addrs[0] = 32'h0000_0040; lens[0] = 16;
        addrs[1] = 32'h0000_0104; lens[1] = 1;
        addrs[2] = 32'h0000_0200; lens[2] = 3;
        addrs[3] = 32'h0000_0304; lens[3] = 37;
        addrs[4] = 32'h0000_03F8; lens[4] = 9;     // crosses 0x400
        addrs[5] = 32'h0000_07C4; lens[5] = 100;   // crosses 0x800
        addrs[6] = 32'h0000_0A00; lens[6] = 256;
        addrs[7] = 32'h0000_0E0C; lens[7] = 381;   // ~ a max frame, crosses 0x1000
        addrs[8] = 32'h0000_1FF0; lens[8] = 5;     // crosses 0x2000
        addrs[9] = 32'h0000_2004; lens[9] = 2;
    end

    initial begin
        errors = 0;
        repeat (4) @(posedge hclk);
        hresetn = 1'b1;
        repeat (2) @(posedge hclk);

        for (t = 0; t < 10; t = t + 1) begin
            a = addrs[t]; n = lens[t];
            for (i = 0; i < n; i = i + 1) wsrc[i] = {a[15:0], 16'd0} ^ (i * 32'h9E3779B1) ^ t;
            run_cmd(a, n, 1'b1);
            if (WAIT_PCT == 0 && n >= 100 && cycles > n + n / 8 + 8) begin
                errors = errors + 1;
                $display("  write of %0d words took %0d cycles (not pipelined)", n, cycles);
            end
            run_cmd(a, n, 1'b0);
            repeat (2) @(posedge hclk);
            for (i = 0; i < n; i = i + 1) begin
                if (rdst[i] !== wsrc[i]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("  MISMATCH t%0d word %0d: wrote %08x read %08x", t, i, wsrc[i], rdst[i]);
                end
            end
        end
        errors = errors + slv.proto_err;
        if (errors == 0) $display("RESULT: PASS (10 transfers round-tripped, bursts clean, wait %0d%%, max burst %0d)", WAIT_PCT, MAX_BURST);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("RESULT: FAIL (timeout)");
        $finish;
    end
endmodule
