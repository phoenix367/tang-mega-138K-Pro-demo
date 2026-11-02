`timescale 1ns/1ps
// gpio_core testbench: register access, direction/tri-state behaviour on
// pulled-up pins, input synchroniser, and a bit-banged I2C start + address
// byte against a one-byte ACK model to show the open-drain pattern works.
module tb_gpio;
    reg clk = 0, rstn = 0;
    always #10 clk = ~clk;                       // 50 MHz

    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0;
    wire [31:0] hrdata;
    wire        hready, hresp;
    wire [5:0]  gpio_i, gpio_o, gpio_oe;
    tri1 [5:0]  pin;                             // board pull-ups
    genvar g;
    generate for (g = 0; g < 6; g = g + 1) begin : pins
        assign pin[g] = gpio_oe[g] ? gpio_o[g] : 1'bz;
    end endgenerate
    assign gpio_i = pin;

    gpio_core #(.N(6)) dut (
        .hclk(clk), .hresetn(rstn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel),
        .s_hready_in(1'b1), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_oe(gpio_oe));

    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            errors = errors + 1;
            $display("FAIL %0s: got %h expected %h @%0t", what, got, exp, $time);
        end
    endtask

    // AHB-lite single transfers: address phase, then data phase next cycle
    task ahb_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); haddr = a; htrans = 2'b10; hwrite = 1; hsel = 1;
            @(negedge clk); htrans = 2'b00; hsel = 0; hwdata = d;
            @(negedge clk);
        end
    endtask
    task ahb_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); haddr = a; htrans = 2'b10; hwrite = 0; hsel = 1;
            @(negedge clk); htrans = 2'b00; hsel = 0;
            #1 d = hrdata;                       // data phase, zero wait
            @(negedge clk);
        end
    endtask

    // ---- a trivial I2C slave model on pin[1:0]: ACKs address 0x50 write ----
    localparam SCL = 0, SDA = 1;
    reg [7:0] sh = 0; integer nb = 0; reg started = 0, acked = 0;
    always @(negedge pin[SDA]) if (pin[SCL]) begin started = 1; nb = 0; end
    always @(posedge pin[SCL]) if (started && nb < 8) begin sh = {sh[6:0], pin[SDA]}; nb = nb + 1; end
    reg ack_drive = 0;
    always @(negedge pin[SCL]) if (started && nb == 8) begin
        ack_drive = (sh == 8'hA0); acked = ack_drive; nb = 9;
    end else if (nb == 9) ack_drive = 0;
    assign pin[SDA] = ack_drive ? 1'b0 : 1'bz;

    // bit-bang helpers through the registers (open drain: drive low = output 0,
    // release = input), as i2c-gpio does
    reg [5:0] dat = 0, dir = 0;
    task set_line(input integer b, input v);
        begin
            if (v) dir[b] = 0; else begin dat[b] = 0; dir[b] = 1; end
            ahb_write(32'h0, {26'd0, dat}); ahb_write(32'h4, {26'd0, dir});
        end
    endtask

    reg [31:0] r; integer i;
    initial begin
        #55 rstn = 1;
        repeat (4) @(negedge clk);
        ahb_read(32'h8, r);  check("ID", r, 32'h4750494F);
        ahb_read(32'hC, r);  check("NGPIO", r, 32'd6);
        ahb_read(32'h4, r);  check("DIROUT reset", r, 32'd0);
        ahb_read(32'h0, r);  check("DAT reset (pull-ups)", r, 32'h3F);
        check("all pins high-Z/pulled", pin, 6'h3F);

        // drive WP low, SEL = 010: only outputs change the pins
        ahb_write(32'h0, 32'h08);                // dat: SEL1=1, others 0
        ahb_write(32'h4, 32'h3C);                // dir: bits 2..5 outputs
        repeat (3) @(negedge clk);
        check("pins after drive", pin, 6'b001011);  // WP=0 SEL=010 SDA/SCL pulled up
        ahb_read(32'h0, r);  check("DAT reads pins", r, 32'h0B);
        ahb_read(32'h4, r);  check("DIROUT readback", r, 32'h3C);

        // I2C start + 0xA0 (0x50 write), expect ACK from the model
        dat = 6'h08; dir = 6'h3C;
        set_line(SDA, 0); #2000;                 // start
        set_line(SCL, 0); #2000;
        for (i = 7; i >= 0; i = i - 1) begin
            set_line(SDA, (8'hA0 >> i) & 1); #1000;
            set_line(SCL, 1); #2000;
            set_line(SCL, 0); #1000;
        end
        set_line(SDA, 1); #1000;                 // release for ACK
        set_line(SCL, 1); #1000;
        ahb_read(32'h0, r);
        check("ACK seen on SDA", r[SDA], 1'b0);
        check("slave decoded address", acked, 1'b1);
        set_line(SCL, 0); #1000;
        set_line(SDA, 1); set_line(SCL, 1); #2000;   // stop
        ahb_read(32'h0, r);  check("bus idle after stop", r[1:0], 2'b11);

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
