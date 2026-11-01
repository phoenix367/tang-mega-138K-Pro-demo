`timescale 1ns/1ps
//============================================================================
// tb_fan.v -- fan_core on an AHB-lite master model: register defaults and
// ID, PWM period/duty (measured on the pin), inversion and enable, the
// tacho counter / one-second rate with a modelled fan and glitches.
// BUS_MHZ=1 keeps the one-second window at 1e6 cycles.
//============================================================================
module tb_fan;
    reg hclk = 0;  always #10 hclk = ~hclk;       // "50 MHz" period, BUS_MHZ param = 1
    reg hresetn = 0;

    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0;
    wire [31:0] hrdata;
    wire        hready, hresp;
    wire        pwm;
    reg         tach = 1;

    fan_core #(.BUS_MHZ(1)) dut (
        .hclk(hclk), .hresetn(hresetn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel),
        .s_hready_in(1'b1), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .fan_pwm(pwm), .fan_tach(tach)
    );

    task bus_wr(input [7:0] off, input [31:0] d);
    begin
        @(posedge hclk); haddr <= 32'hE800_8000 | off; htrans <= 2'b10; hwrite <= 1; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0; hwrite <= 0; hwdata <= d;
        @(posedge hclk); hwdata <= 0;
    end
    endtask
    task bus_rd(input [7:0] off, output [31:0] d);
    begin
        @(posedge hclk); haddr <= 32'hE800_8000 | off; htrans <= 2'b10; hwrite <= 0; hsel <= 1;
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

    // measure the pin: high cycles and period over one full PWM period
    task measure(input integer period, output integer hi);
        integer i;
        begin
            hi = 0;
            @(posedge hclk); while (dut.pwm_cnt != 0) @(posedge hclk);
            for (i = 0; i < period; i = i + 1) begin
                @(posedge hclk); #1 if (pwm) hi = hi + 1;
            end
        end
    endtask

    // fan model: `edges` tach pulses, low for 10 cycles each, spaced `gap` cycles
    task fan_pulses(input integer edges, input integer gap);
        integer i;
        begin
            for (i = 0; i < edges; i = i + 1) begin
                repeat (gap) @(posedge hclk); tach <= 0;
                repeat (60) @(posedge hclk); tach <= 1;
            end
        end
    endtask

    reg [31:0] d;
    integer hi;
    initial begin
        $dumpfile("tb_fan.vcd"); $dumpvars(0, tb_fan);
        repeat (5) @(posedge hclk); hresetn = 1; repeat (3) @(posedge hclk);

        // defaults
        bus_rd(8'h14, d); check("ID", d, 32'h46414E20);
        bus_rd(8'h00, d); check("CTRL reset", d, 32'h1);
        bus_rd(8'h04, d); check("PERIOD reset", d, 40);
        bus_rd(8'h08, d); check("DUTY reset", d, 40);
        measure(40, hi); check("100% duty high cycles", hi, 40);

        // 25 % duty of a 40-cycle period
        bus_wr(8'h08, 10); measure(40, hi); check("25% duty", hi, 10);
        bus_wr(8'h08, 0);  measure(40, hi); check("0% duty", hi, 0);
        bus_wr(8'h08, 100); measure(40, hi); check("duty > period = always on", hi, 40);
        // new period 100, duty 30
        bus_wr(8'h04, 100); bus_wr(8'h08, 30); measure(100, hi); check("30/100", hi, 30);
        // inverted
        bus_wr(8'h00, 32'h3); measure(100, hi); check("inverted 30/100 -> 70 high", hi, 70);
        // disabled: off level, inverted => pin high
        bus_wr(8'h00, 32'h2); measure(100, hi); check("disabled inverted = high", hi, 100);
        bus_wr(8'h00, 32'h0); measure(100, hi); check("disabled = low", hi, 0);
        bus_wr(8'h00, 32'h1);
        bus_wr(8'h04, 0); bus_rd(8'h04, d); check("PERIOD 0 clamps to 1", d, 1);
        bus_wr(8'h04, 40);

        // tacho: a glitch shorter than the filter must not count
        bus_rd(8'h10, d); check("CNT 0", d, 0);
        @(posedge hclk); tach <= 0; repeat (5) @(posedge hclk); tach <= 1; repeat (50) @(posedge hclk);
        bus_rd(8'h10, d); check("glitch ignored", d, 0);
        // 7 real pulses
        fan_pulses(7, 200);
        repeat (50) @(posedge hclk);
        bus_rd(8'h10, d); check("CNT 7", d, 7);
        bus_rd(8'h0C, d); check("RATE before the window ends", d[15:0], 0);
        check("tach level high", d[31], 1);
        // run to the end of the one-second window (1e6 cycles): 7 edges so far,
        // add 3 more inside the window
        fan_pulses(3, 300);
        while (dut.sec_cnt != 0) @(posedge hclk);
        repeat (3) @(posedge hclk);
        bus_rd(8'h0C, d); check("RATE = 10 in the first second", d[15:0], 10);
        bus_rd(8'h10, d); check("CNT 10", d, 10);
        // second window: 4 pulses
        fan_pulses(4, 1000);
        while (dut.sec_cnt != 0) @(posedge hclk);
        repeat (3) @(posedge hclk);
        bus_rd(8'h0C, d); check("RATE = 4 in the second second", d[15:0], 4);

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
