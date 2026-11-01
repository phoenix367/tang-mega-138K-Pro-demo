// Sample top module: blink an LED from a free-running counter.
//
// Target: Gowin GW5AST-138B (Arora V), part gw5ast138b-007.
//
// CLK_FREQ_HZ is the input clock frequency in Hz; BLINK_HZ is the LED
// toggle rate. The counter divides the clock so the LED toggles every
// CLK_FREQ_HZ / (2*BLINK_HZ) cycles. Override CLK_FREQ_HZ to match your
// board's oscillator (see src/led_blink.cst / .sdc).
module led_blink #(
    parameter integer CLK_FREQ_HZ = 50_000_000,
    parameter integer BLINK_HZ    = 1
) (
    input  wire clk,    // board oscillator
    input  wire rst_n,  // active-low reset
    output reg  led     // drive an on-board LED
);
    localparam integer HALF_PERIOD = CLK_FREQ_HZ / (2 * BLINK_HZ);

    // Width needed to count up to HALF_PERIOD - 1.
    localparam integer CW = $clog2(HALF_PERIOD);

    reg [CW-1:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= {CW{1'b0}};
            led     <= 1'b0;
        end else if (counter == HALF_PERIOD[CW-1:0] - 1'b1) begin
            counter <= {CW{1'b0}};
            led     <= ~led;
        end else begin
            counter <= counter + 1'b1;
        end
    end
endmodule
