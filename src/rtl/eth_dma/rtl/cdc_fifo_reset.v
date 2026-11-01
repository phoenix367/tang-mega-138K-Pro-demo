`default_nettype none
//============================================================================
// cdc_fifo_reset.v -- safe reset generator for a dual-clock (CDC) FIFO,
// built on the FPGADesignElements Reset_Synchronizer.
//
// The CDC_FIFO_Buffer needs BOTH clears asserted together, held long enough to
// flush its cross-domain pointer handshake, and de-asserted ~together (a
// staggered release leaves it with data going in but never coming out).
//
// Approach: extend the async reset by HOLD in_clk cycles into a single
// `ext_arst_n` (async assert via arst_n, in_clk-synchronous release).  Feed
// that one common signal into a Reset_Synchronizer per clock domain, so both
// clears assert immediately, stay asserted for the full hold, and release
// within a couple cycles of each other in their own domains.
//============================================================================
module cdc_fifo_reset #(
    parameter HOLD = 64              // combined-clear hold, in_clk cycles
)(
    input  wire arst_n,              // async, active-low system reset
    input  wire in_clk,
    input  wire out_clk,
    output wire in_clear,            // active-high, in_clk domain
    output wire out_clear            // active-high, out_clk domain
);
    function integer clog2(input integer v); integer i;
        begin clog2 = 0; for (i = v-1; i > 0; i = i >> 1) clog2 = clog2 + 1; end
    endfunction
    localparam CW = clog2(HOLD+1) + 1;

    // Extend the reset: low during arst_n and for HOLD in_clk cycles after.
    reg [CW-1:0] cnt;
    always @(posedge in_clk or negedge arst_n)
        if (!arst_n)                       cnt <= {CW{1'b0}};
        else if (cnt != HOLD[CW-1:0])      cnt <= cnt + 1'b1;
    wire ext_arst_n = arst_n & (cnt == HOLD[CW-1:0]);   // async assert, sync release

    // One common extended reset -> a Reset_Synchronizer per domain.
    wire in_rst_n, out_rst_n;
    Reset_Synchronizer #(.EXTRA_DEPTH(0), .RESET_ACTIVE_STATE(0)) rs_in (
        .receiving_clock(in_clk),  .reset_in(ext_arst_n), .reset_out(in_rst_n)
    );
    Reset_Synchronizer #(.EXTRA_DEPTH(0), .RESET_ACTIVE_STATE(0)) rs_out (
        .receiving_clock(out_clk), .reset_in(ext_arst_n), .reset_out(out_rst_n)
    );

    assign in_clear  = ~in_rst_n;
    assign out_clear = ~out_rst_n;
endmodule
`default_nettype wire
