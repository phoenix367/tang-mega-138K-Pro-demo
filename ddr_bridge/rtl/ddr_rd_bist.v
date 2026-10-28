`default_nettype none
//============================================================================
// ddr_rd_bist.v -- non-destructive read-ordering self-test for the Gowin DDR3
// Memory Interface IP user port (runs in the IP's clk_out domain).
//
// Question it answers: when several BL8 reads are in flight, does the MC
// return exactly the data of each read, in command order?
//
// Per iteration: pick 4 addresses (pattern), read them one at a time, each
// waiting for its data (ground truth -- DDR is not written meanwhile, the
// bridge is held off while the BIST owns the port), then read the same 4
// back to back with all 4 in flight, and compare arrival j with truth j (one
// per cycle).  A mismatch whose data equals truth k (k != j) is a reorder.
//
// Patterns: 0 random (any bank/row)   1 same row, 4 columns
//           2 line pairs (A, A+16 B)  3 descending line pairs (A+16 B, A)
//
// Only reads are issued, so the BIST can run under a live OS; the bridge
// stalls for the duration (a few ms).
//============================================================================
module ddr_rd_bist (
    input  wire         clk,
    input  wire         rst_n,
    // control (quasi-static, synchronized by the caller)
    input  wire         start,          // one-cycle pulse
    input  wire [1:0]   pattern,
    input  wire [3:0]   iter_log2,      // iterations = 2**(iter_log2 + 8)
    input  wire         port_idle,      // bridge has no read in flight
    // DDR3 IP user port (read side only)
    output wire         hold,           // bridge must not issue (BIST requested)
    output wire         own,            // BIST owns the command port
    input  wire         cmd_ok,         // command may be issued this cycle
    output wire         cmd_en,
    output wire [26:0]  addr,
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid,
    // results (static once done)
    output reg  [31:0]  r_status,       // {running, done, 2'b0, iterations[27:0]}
    output reg  [31:0]  r_err,          // mismatching reads
    output reg  [31:0]  r_reorder,      // mismatches explained by another read's data
    output reg  [31:0]  r_first,        // first mismatch: {pattern, j, 0, k (7 = none), iter[23:0]}
    output reg  [31:0]  r_first_addr,   // its word address
    output reg  [31:0]  r_first_got,    // got[31:0]
    output reg  [31:0]  r_first_exp,    // expected[31:0]
    output wire [31:0]  r_extra         // rd_data_valid without a BIST read in flight
);
    localparam S_IDLE = 3'd0, S_WAIT = 3'd1, S_GEN = 3'd2, S_SER = 3'd3,
               S_SERW = 3'd4, S_OVL = 3'd5, S_OVLW = 3'd6, S_CMP = 3'd7;

    reg  [2:0]   st;
    reg  [31:0]  lfsr;
    reg  [26:0]  a [0:3];
    reg  [127:0] truth [0:3];
    reg  [127:0] got   [0:3];
    reg  [1:0]   i, n_ret;
    reg  [2:0]   n_iss;
    reg  [27:0]  iter, iters;
    reg  [1:0]   pat;
    reg  [16:0]  base;                  // bank+row of the iteration (pattern 1)
    reg          first_n;               // first mismatch of this run captured
    reg  [1:0]   cph;                   // S_CMP phase: 0 select, 1 partial compares, 2 verdict
    reg  [127:0] g_sel;                 // got[i], registered
    reg  [15:0]  eqp;                   // eqp[4k+q]: got[i] word q == truth[k] word q
    reg  [31:0]  g_lo, t_lo;            // got[i] / truth[i] bits [31:0]
    reg          extra_q;               // stray rd_data_valid last cycle
    reg  [15:0]  n_extra;               // 16 bits: any count is a fault (timing: short +1)
    assign r_extra = {16'd0, n_extra};

    assign hold   = (st != S_IDLE);
    assign own    = (st != S_IDLE) && (st != S_WAIT);
    assign cmd_en = own && cmd_ok && ((st == S_SER) || (st == S_OVL && n_iss < 3'd4));
    assign addr   = (st == S_SER) ? a[i] : a[n_iss[1:0]];

    wire [31:0] lfsr_n = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    integer k;
    reg [2:0] km;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; lfsr <= 32'h1BADF00D; i <= 2'd0; n_iss <= 3'd0; n_ret <= 2'd0;
            iter <= 28'd0; iters <= 28'd0; pat <= 2'd0; base <= 17'd0; first_n <= 1'b0;
            cph <= 2'd0; eqp <= 16'd0; g_lo <= 32'd0; t_lo <= 32'd0; extra_q <= 1'b0;
            g_sel <= 128'd0;
            r_status <= 32'd0; r_err <= 32'd0; r_reorder <= 32'd0; r_first <= 32'd0;
            r_first_addr <= 32'd0; r_first_got <= 32'd0; r_first_exp <= 32'd0; n_extra <= 16'd0;
        end else begin
            extra_q <= rd_data_valid && !(st == S_SERW || st == S_OVL || st == S_OVLW) && own;
            if (extra_q) n_extra <= n_extra + 16'd1;   // counted a cycle late (timing)
            case (st)
                S_IDLE: if (start) begin
                    st <= S_WAIT; pat <= pattern; iters <= 28'd1 << (iter_log2 + 4'd8);
                    iter <= 28'd0; r_err <= 32'd0; r_reorder <= 32'd0; r_first <= 32'd0;
                    n_extra <= 16'd0; r_status <= 32'h8000_0000; first_n <= 1'b0;
                end
                S_WAIT: if (port_idle) begin st <= S_GEN; i <= 2'd0; end
                S_GEN: begin
                    // 16 B aligned x16 word address {bank[2:0], row[13:0], col[9:0]}
                    lfsr <= lfsr_n;
                    if (i == 2'd0) base <= lfsr[26:10];
                    case (pat)
                        2'd0: a[i] <= {lfsr[26:3], 3'b000};                       // anywhere
                        2'd1: a[i] <= {(i == 2'd0) ? lfsr[26:10] : base,           // same row
                                       lfsr[9:3], 3'b000};
                        2'd2: a[i] <= i[0] ? {a[i-2'd1][26:4], 4'b1000}           // line pairs
                                           : {lfsr[26:4], 4'b0000};
                        2'd3: a[i] <= i[0] ? {a[i-2'd1][26:4], 4'b0000}           // descending
                                           : {lfsr[26:4], 4'b1000};                //  line pairs
                    endcase
                    i <= i + 2'd1;
                    if (i == 2'd3) st <= S_SER;
                end
                S_SER:  if (cmd_ok) st <= S_SERW;
                S_SERW: if (rd_data_valid) begin
                    truth[i] <= rd_data;
                    if (i == 2'd3) begin st <= S_OVL; n_iss <= 3'd0; n_ret <= 2'd0; end
                    else begin i <= i + 2'd1; st <= S_SER; end
                end
                S_OVL: begin
                    if (cmd_en) n_iss <= n_iss + 3'd1;
                    if (rd_data_valid) begin got[n_ret] <= rd_data; n_ret <= n_ret + 2'd1; end
                    if ((n_iss == 3'd3 && cmd_en) || n_iss == 3'd4) st <= S_OVLW;
                end
                S_OVLW: if (rd_data_valid) begin
                    got[n_ret] <= rd_data; n_ret <= n_ret + 2'd1;
                    if (n_ret == 2'd3) begin st <= S_CMP; i <= 2'd0; cph <= 2'd0; end
                end
                S_CMP: if (cph == 2'd0) begin
                    // phase 0: select arrival i; phase 1: 32-bit partial compares
                    // against every truth k -- keeps the 4:1 select, 128-bit
                    // compares and the reorder search out of one 100 MHz cycle
                    g_sel <= got[i];
                    t_lo  <= truth[i][31:0];
                    cph   <= 2'd1;
                end else if (cph == 2'd1) begin
                    for (k = 0; k < 16; k = k + 1)
                        eqp[k] <= (g_sel[(k % 4)*32 +: 32] == truth[k / 4][(k % 4)*32 +: 32]);
                    g_lo <= g_sel[31:0];
                    cph  <= 2'd2;
                end else begin
                    // phase 2: arrival j = i vs truth i; else which truth k it holds
                    cph <= 2'd0;
                    if (!(&eqp[i*4 +: 4])) begin
                        km = 3'd7;
                        for (k = 3; k >= 0; k = k - 1)
                            if (k != i && (&eqp[k*4 +: 4])) km = k[2:0];
                        r_err <= r_err + 32'd1;
                        if (km != 3'd7) r_reorder <= r_reorder + 32'd1;
                        if (!first_n) begin
                            first_n      <= 1'b1;
                            r_first      <= {pat, i, 1'b0, km, iter[23:0]};
                            r_first_addr <= {5'd0, a[i]};
                            r_first_got  <= g_lo;
                            r_first_exp  <= t_lo;
                        end
                    end
                    i <= i + 2'd1;
                    if (i == 2'd3) begin
                        iter     <= iter + 28'd1;
                        r_status <= {2'b10, 2'b00, iter + 28'd1};
                        if (iter + 28'd1 == iters) begin
                            st <= S_IDLE; r_status <= {2'b01, 2'b00, iter + 28'd1};
                        end else st <= S_WAIT;
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire
