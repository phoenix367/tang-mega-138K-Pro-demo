`default_nettype none
//============================================================================
// ddr_async_fifo.v -- small dual-clock FIFO (gray-coded pointers, 2-FF
// synchronizers), first-word-fall-through: rdata shows the head entry
// whenever !empty, `rd` pops it.
//
// Low latency is the point (it sits on the DDR read path): a word written at
// a wclk edge is visible on the read side after ~2 rclk edges.
//
// Both resets must be asserted together (they come from one common source,
// synchronized into each domain) so the pointers restart in step.
//
// WREG=1 registers the write port (data, slot, strobe) and publishes the write
// pointer to the read side one wclk later, together with the RAM write: the
// full-flag -> write-enable decode no longer reaches every RAM bit in one
// cycle (needed at 100 MHz with wide words).  Costs one wclk of latency.
//============================================================================
module ddr_async_fifo #(
    parameter W  = 32,          // data width
    parameter AW = 4,           // log2(depth)
    parameter WREG = 0          // 1: registered write port (see above)
) (
    input  wire         wclk,
    input  wire         wrst_n,
    input  wire         wr,
    input  wire [W-1:0] wdata,
    output wire         full,
    output wire [AW:0]  wlevel,  // entries in use as seen from the write side

    input  wire         rclk,
    input  wire         rrst_n,
    input  wire         rd,
    output wire [W-1:0] rdata,
    output wire         empty
);
    reg [W-1:0] mem [0:(1<<AW)-1];

    // ---------------- write side ----------------
    reg  [AW:0] wbin, wgray, wgray_pub;
    reg  [AW:0] rgray_w1, rgray_w2;
    reg         we_q;
    reg  [AW-1:0] wa_q;
    reg  [W-1:0]  wd_q;
    wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, (wr & ~full)};
    wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin     <= {(AW+1){1'b0}};
            wgray    <= {(AW+1){1'b0}};
            wgray_pub <= {(AW+1){1'b0}};
            we_q     <= 1'b0;
            wa_q     <= {AW{1'b0}};
            rgray_w1 <= {(AW+1){1'b0}};
            rgray_w2 <= {(AW+1){1'b0}};
        end else begin
            wbin     <= wbin_n;
            wgray    <= wgray_n;
            wgray_pub <= WREG ? wgray : wgray_n;   // WREG: publish with the RAM write
            we_q     <= wr & ~full;
            wa_q     <= wbin[AW-1:0];
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end
    always @(posedge wclk)
        if (wr & ~full) wd_q <= wdata;
    generate
        if (WREG) begin : g_wreg
            always @(posedge wclk)
                if (we_q) mem[wa_q] <= wd_q;
        end else begin : g_wdir
            always @(posedge wclk)
                if (wr & ~full) mem[wbin[AW-1:0]] <= wdata;
        end
    endgenerate

    // full: the gray read pointer equals the write pointer with the two MSBs inverted
    assign full = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    // write-side occupancy (conservative: read progress is seen late)
    function [AW:0] g2b(input [AW:0] g);
        integer k;
        begin
            g2b[AW] = g[AW];
            for (k = AW-1; k >= 0; k = k - 1) g2b[k] = g2b[k+1] ^ g[k];
        end
    endfunction
    assign wlevel = wbin - g2b(rgray_w2);

    // ---------------- read side ----------------
    reg  [AW:0] rbin, rgray;
    reg  [AW:0] wgray_r1, wgray_r2;
    wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, (rd & ~empty)};
    wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin     <= {(AW+1){1'b0}};
            rgray    <= {(AW+1){1'b0}};
            wgray_r1 <= {(AW+1){1'b0}};
            wgray_r2 <= {(AW+1){1'b0}};
        end else begin
            rbin     <= rbin_n;
            rgray    <= rgray_n;
            wgray_r1 <= wgray_pub;
            wgray_r2 <= wgray_r1;
        end
    end

    assign empty = (rgray == wgray_r2);
    assign rdata = mem[rbin[AW-1:0]];
endmodule
`default_nettype wire
