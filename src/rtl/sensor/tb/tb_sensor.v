`timescale 1ns/1ps
//============================================================================
// tb_sensor.v -- sensor_core on an AHB-lite master model with the behavioural
// ADC models (adc_model.v): ID, scan of all 9 slots, values + valid flags,
// SCANS counting, value update on the next scan, run = 0 stops the scan,
// timeout flagging (ADCEN = 0 -> no conversion) and recovery, calibration
// register read-back.
//============================================================================
module tb_sensor;
    reg hclk = 0;  always #10 hclk = ~hclk;       // 50 MHz
    reg aclk = 0;  always #20 aclk = ~aclk;       // 25 MHz
    reg hresetn = 0;

    // values the ADC models return
    reg signed [13:0] temp_q = 14'd170;           // 42.5 C
    reg [13:0] volt_q [0:7];
    integer k;
    initial for (k = 0; k < 8; k = k + 1) volt_q[k] = 14'd900 + 100 * k;

    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0;
    wire [31:0] hrdata;
    wire        hready, hresp;

    sensor_core #(.BUS_MHZ(50), .SETTLE_CYC(24'd200), .CONV_CYC(24'd100000)) dut (
        .hclk(hclk), .hresetn(hresetn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel),
        .s_hready_in(1'b1), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .adc_clk(aclk)
    );

    task bus_wr(input [7:0] off, input [31:0] d);
    begin
        @(posedge hclk); haddr <= 32'hE800_4000 | off; htrans <= 2'b10; hwrite <= 1; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0; hwrite <= 0; hwdata <= d;
        @(posedge hclk); hwdata <= 0;
    end
    endtask
    task bus_rd(input [7:0] off, output [31:0] d);
    begin
        @(posedge hclk); haddr <= 32'hE800_4000 | off; htrans <= 2'b10; hwrite <= 0; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0;
        #1 d = hrdata;
        @(posedge hclk);
    end
    endtask

    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %08x expected %08x @%0t", what, got, exp, $time);
            errors = errors + 1;
        end
    endtask

    task wait_scans(input integer n);
        reg [31:0] s0, s;
        begin
            bus_rd(8'h08, s0);
            s = s0;
            while (s < s0 + n) begin #10000; bus_rd(8'h08, s); end
        end
    endtask

    reg [31:0] d;
    integer n;
    initial begin
        #100 hresetn = 1;
        bus_rd(8'h1C, d); check("ID", d, 32'h5345_4E53);
        bus_rd(8'h00, d); check("CTRL reset", d, 32'h3);
        bus_rd(8'h14, d); check("TCAL reset", d, {4'b0, -12'd1180, 6'b0, 10'd730});
        bus_rd(8'h18, d); check("VCAL reset", d, {4'b0, 12'd0, 6'b0, 10'd653});
        bus_rd(8'h04, d); check("STATUS bus MHz", d[31:16], 16'd50);

        // first full scan
        wait_scans(1);
        bus_rd(8'h10, d); check("TEMP", d, {2'b01, 16'b0, 14'd170});
        for (n = 0; n < 8; n = n + 1) begin
            bus_rd(8'h20 + 4 * n, d); check("VOLT", d, {2'b01, 16'b0, volt_q[n]});
        end
        bus_rd(8'h0C, d); check("TIMEOUTS 0", d, 0);

        // the value follows on the next scan
        temp_q = -14'd40;  volt_q[5] = 14'd1843;   // -10 C, 0.9 V
        wait_scans(2);
        bus_rd(8'h10, d); check("TEMP update", d, {2'b01, 16'b0, 14'h3FD8});
        bus_rd(8'h34, d); check("VOLT5 update", d, {2'b01, 16'b0, 14'd1843});

        // run = 0 stops the scan
        bus_wr(8'h00, 32'h2);
        #2500000;                               // a conversion in flight completes first
        bus_rd(8'h08, d); n = d;
        bus_rd(8'h04, d); check("STATUS idle", d[8], 1'b0);
        #3000000;
        bus_rd(8'h08, d); check("SCANS frozen", d, n);

        // ADC disabled -> every conversion times out, old values kept, flagged
        bus_wr(8'h00, 32'h1);
        wait_scans(1);
        bus_rd(8'h10, d); check("TEMP timeout", d, {2'b11, 16'b0, 14'h3FD8});
        bus_rd(8'h34, d); check("VOLT5 timeout", d, {2'b11, 16'b0, 14'd1843});
        bus_rd(8'h0C, d); if (d < 9) check("TIMEOUTS >= 9", d, 9);

        // recovery
        bus_wr(8'h00, 32'h3);
        wait_scans(2);
        bus_rd(8'h10, d); check("TEMP recovered", d, {2'b01, 16'b0, 14'h3FD8});
        bus_rd(8'h0C, d); n = d;
        wait_scans(1);
        bus_rd(8'h0C, d); check("TIMEOUTS stable", d, n);

        // calibration registers
        bus_wr(8'h14, {4'b0, -12'd900, 6'b0, 10'd800});
        bus_rd(8'h14, d); check("TCAL rw", d, {4'b0, -12'd900, 6'b0, 10'd800});
        check("TCAL -> core", {dut.t_offset, dut.t_fscal}, {-12'd900, 10'd800});

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
    initial begin #200000000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
