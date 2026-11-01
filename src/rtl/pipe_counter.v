`default_nettype none
//============================================================================
// pipe_counter.v -- event counter built from SLICE-bit slices with registered
// carries.
//
// GowinSyn turns a plain `cnt <= cnt + 1` into a LUT chain whose depth grows
// with the width (a 32-bit incrementer came out as 12 levels and was the
// longest path of the 100 MHz domains).  Here each slice is a short
// incrementer and the carry into the next slice is a register, so the logic
// depth is that of one slice whatever the width.  The price is that a wrap
// of slice k shows up in slice k+1 one cycle later -- the value read is
// exact only once `inc` has been low for W/SLICE cycles, which is how the
// statistics counters in this design are read (stopped, then read).
//============================================================================
module pipe_counter #(
    parameter W     = 32,
    parameter SLICE = 8
) (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clr,          // synchronous clear (has priority)
    input  wire         inc,          // count this cycle
    output wire [W-1:0] q
);
    localparam N = (W + SLICE - 1) / SLICE;
    wire [N:0] c;                      // c[k] = carry into slice k
    assign c[0] = inc;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : sl
            localparam LO = g * SLICE;
            localparam HI = (LO + SLICE > W) ? W - 1 : LO + SLICE - 1;
            localparam SW = HI - LO + 1;
            reg [SW-1:0] s;
            reg          co;
            always @(posedge clk or negedge rstn) begin
                if (!rstn)    begin s <= {SW{1'b0}}; co <= 1'b0; end
                else if (clr) begin s <= {SW{1'b0}}; co <= 1'b0; end
                else begin
                    s  <= s + {{(SW-1){1'b0}}, c[g]};
                    co <= c[g] & (&s);          // this slice wraps now -> next slice +1 next cycle
                end
            end
            assign q[HI:LO] = s;
            assign c[g+1]   = co;
        end
    endgenerate
endmodule
`default_nettype wire
