`default_nettype none
//============================================================================
// idct_ram.v -- simple dual-port RAM (one write port, one registered read
// port, same clock) for the IDCT band buffers: 64-bit words, inferred as
// BSRAM.  No initialisation (GowinSyn refuses init loops deeper than 2000).
//============================================================================
module idct_ram #(
    parameter ADDR_WIDTH = 11,
    parameter WORD_WIDTH = 64
) (
    input  wire                  clk,
    input  wire                  wren,
    input  wire [ADDR_WIDTH-1:0] write_addr,
    input  wire [WORD_WIDTH-1:0] write_data,
    input  wire [ADDR_WIDTH-1:0] read_addr,
    output reg  [WORD_WIDTH-1:0] read_data
);
    reg [WORD_WIDTH-1:0] ram [0:(1 << ADDR_WIDTH) - 1];
    always @(posedge clk) begin
        if (wren) ram[write_addr] <= write_data;
        read_data <= ram[read_addr];
    end
endmodule
`default_nettype wire
