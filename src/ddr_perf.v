`default_nettype none
//============================================================================
// ddr_perf.v -- DDR data-memory AHB performance monitor + transaction trace,
// read out through the AE350 external APB slave (CPU 0xF800_0000).
//
// Passively watches the SoC's customized data-memory AHB bus (DDR_H*, the bus
// every L1 line fill / eviction / uncached DDR access goes through) and counts
// transfers, beats and HREADY wait states, so the DDR path latency can be
// measured on hardware with plain `devmem` from Linux:
//
//   devmem 0xF8000004 32 2     # clear
//   devmem 0xF8000004 32 1     # enable (add 4 = also arm the trace)
//   <workload>
//   devmem 0xF8000004 32 0     # stop -- counters are frozen, safe to read
//   devmem 0xF8000100 32 ...   # counters (see map below)
//
// APB timing: the SoC's APB outputs arrive late and its PRDATA input has deep
// logic behind it, so address/data are registered in the setup phase, writes
// and the read-data mux happen in the first access cycle, and PRDATA comes
// from a register with PREADY in the second (one wait state per access).
//
// Clocking: counters/trace live in the AHB clock (hclk) domain; the APB side
// (pclk) only writes CTRL (2-FF synchronized, CLR as a toggle) and reads the
// counters. Counter reads cross domains unsynchronized, so they are only
// coherent while EN=0 (frozen) -- the intended usage.
//
// APB register map (byte offsets, decoded on paddr[11:0]):
//   0x000 ID        {16'hDD3B, CONFIG[15:0]}
//   0x004 CTRL      [0] EN  [1] CLR (write-1 pulse)  [2] TRACE_ARM
//   0x008 STATUS    [15:0] trace entries captured, [16] trace full
//   0x00C TRACE_IDX trace entry to read
//   0x010 TRACE_LO  entry[31:0]  = HADDR
//   0x014 TRACE_HI  entry[63:32] = {ts[15:0], prev_wait[7:0], hwrite,
//                                   hburst[2:0], hsize[1:0], seq, prev_valid}
//   0x018 CONFIG    build-time CONFIG parameter (memory clock, bridge id ...)
//   0x020 MODE      bridge debug mode bits (see ahb_ddr3_bridge), reset MODE_RESET
//   0x100+4*i       counter i (32-bit):
//     0 cycles            1 rd_bursts (NONSEQ)   2 wr_bursts (NONSEQ)
//     3 rd_beats          4 wr_beats             5 rd_wait cycles
//     6 wr_wait cycles    7 rd_first_wait (sum of 1st-beat waits)
//     8 rd_wait_max       9 wr_wait_max          10 busy (HTRANS=BUSY) cycles
//     11 bus_active (data phase pending or burst open)
//     12..19 read  NONSEQ count by HBURST (SINGLE,INCR,WRAP4,INCR4,...)
//     20..27 write NONSEQ count by HBURST
//     28..31 read  NONSEQ count by HSIZE (byte,half,word,dword)
//     32..35 write NONSEQ count by HSIZE
//     36..43 EXT[0..7] -- counters supplied by the bridge (ext_cnt), frozen
//            by the bridge while EN=0 and cleared by CLR (en/clr outputs)
//     44..51 EXT[8..15] -- bridge read-BIST results (static once done)
//============================================================================
module ddr_perf #(
    parameter [31:0] CONFIG   = 32'h0,
    parameter [31:0] MODE_RESET = 32'h0,
    parameter        TRACE_AW = 10                 // 1024 trace entries
) (
    // monitored data-memory AHB bus (hclk domain)
    input  wire        hclk,
    input  wire        hresetn,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [2:0]  hburst_i,
    input  wire        hready_i,
    // bridge-internal counters; the bridge honours en/clr below
    input  wire [511:0] ext_cnt,
    output wire        en,
    output wire        clr,
    output reg  [31:0] mode,            // pclk domain, quasi-static
    // APB slave (pclk domain)
    input  wire        pclk,
    input  wire        presetn,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,          // registered
    output wire        pready,
    output wire        pslverr
);
    localparam NCNT = 52;

    assign pslverr = 1'b0;

    // ---------------- APB: registered setup phase, 1 wait state ----------------
    reg  [11:0] a_q;
    reg  [31:0] d_q;
    reg         w_q, acc_q;
    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            a_q <= 12'd0; d_q <= 32'd0; w_q <= 1'b0; acc_q <= 1'b0;
        end else begin
            if (psel & ~penable) begin a_q <= paddr[11:0]; d_q <= pwdata; w_q <= pwrite; end
            acc_q <= psel & penable & ~acc_q;     // high in the 2nd access cycle
        end
    end
    assign pready = acc_q;
    wire   apb_wr = psel & penable & ~acc_q & w_q;  // write in the 1st access cycle
    wire   apb_rd = psel & penable & ~acc_q & ~w_q;

    // ---------------- APB-side control registers ----------------
    reg                 ctl_en, ctl_arm, ctl_clr_tgl;
    reg  [TRACE_AW-1:0] trace_idx;

    always @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctl_en      <= 1'b0;
            ctl_arm     <= 1'b0;
            ctl_clr_tgl <= 1'b0;
            trace_idx   <= {TRACE_AW{1'b0}};
            mode        <= MODE_RESET;
        end else if (apb_wr) begin
            case (a_q)
                12'h004: begin
                    ctl_en  <= d_q[0];
                    ctl_arm <= d_q[2];
                    if (d_q[1]) ctl_clr_tgl <= ~ctl_clr_tgl;
                end
                12'h00C: trace_idx <= d_q[TRACE_AW-1:0];
                12'h020: mode      <= d_q;
                default: ;
            endcase
        end
    end

    // ---------------- sync control into hclk ----------------
    reg [1:0] en_s, arm_s;
    reg [2:0] clr_s;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            en_s  <= 2'b0;
            arm_s <= 2'b0;
            clr_s <= 3'b0;
        end else begin
            en_s  <= {en_s[0],  ctl_en};
            arm_s <= {arm_s[0], ctl_arm};
            clr_s <= {clr_s[1:0], ctl_clr_tgl};
        end
    end
    assign en  = en_s[1];
    wire   arm = arm_s[1];
    // The clear pulse fans out to every counter bit (~700 loads): register it
    // and let synthesis duplicate that register (syn_maxfan) so no single net
    // has to cross the die -- Build 55 failed ae350_ddr_clk on exactly this net.
    reg clr_q /* synthesis syn_maxfan = 100 */;
    always @(posedge hclk or negedge hresetn)
        if (!hresetn) clr_q <= 1'b0;
        else          clr_q <= clr_s[2] ^ clr_s[1];
    assign clr = clr_q;

    // ---------------- monitored bus, registered on entry ----------------
    // The SoC's DDR_H* outputs reach the fabric late (long route from the hard
    // AE350 macro), so the monitor works on a copy one hclk behind the bus.
    reg [31:0] haddr;
    reg [1:0]  htrans;
    reg        hwrite, hready;
    reg [2:0]  hsize, hburst;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            haddr <= 32'd0; htrans <= 2'b00; hwrite <= 1'b0; hready <= 1'b1;
            hsize <= 3'd0;  hburst <= 3'd0;
        end else begin
            haddr <= haddr_i; htrans <= htrans_i; hwrite <= hwrite_i; hready <= hready_i;
            hsize <= hsize_i; hburst <= hburst_i;
        end
    end

    // ---------------- AHB transfer tracking ----------------
    wire acc     = hready & htrans[1];             // address phase accepted
    wire acc_ns  = acc & ~htrans[0];               // NONSEQ
    wire is_busy = hready & (htrans == 2'b01);

    reg       dp_valid, dp_write, dp_first;        // data phase in flight
    reg [7:0] dp_wait;                             // saturating wait count
    reg [31:0] dp_wait_full;
    reg       burst_open;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            dp_valid     <= 1'b0;
            dp_write     <= 1'b0;
            dp_first     <= 1'b0;
            dp_wait      <= 8'd0;
            dp_wait_full <= 32'd0;
            burst_open   <= 1'b0;
        end else begin
            if (hready) begin
                dp_valid     <= htrans[1];
                dp_write     <= hwrite;
                dp_first     <= ~htrans[0];
                dp_wait      <= 8'd0;
                dp_wait_full <= 32'd0;
                // a burst stays "open" across BUSY/SEQ until an IDLE or NONSEQ
                burst_open   <= (htrans != 2'b00);
            end else if (dp_valid) begin
                dp_wait      <= (dp_wait == 8'hFF) ? dp_wait : dp_wait + 8'd1;
                dp_wait_full <= dp_wait_full + 32'd1;
            end
        end
    end

    // ---------------- counters ----------------
    reg [31:0] cnt [0:35];                         // 0..35 internal; 36..51 = ext
    integer i;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            for (i = 0; i < 36; i = i + 1) cnt[i] <= 32'd0;
        end else if (clr) begin
            for (i = 0; i < 36; i = i + 1) cnt[i] <= 32'd0;
        end else if (en) begin
            cnt[0] <= cnt[0] + 32'd1;
            if (acc_ns & ~hwrite) cnt[1] <= cnt[1] + 32'd1;
            if (acc_ns &  hwrite) cnt[2] <= cnt[2] + 32'd1;
            if (acc    & ~hwrite) cnt[3] <= cnt[3] + 32'd1;
            if (acc    &  hwrite) cnt[4] <= cnt[4] + 32'd1;
            if (!hready & dp_valid & ~dp_write) cnt[5] <= cnt[5] + 32'd1;
            if (!hready & dp_valid &  dp_write) cnt[6] <= cnt[6] + 32'd1;
            if (hready & dp_valid & dp_first & ~dp_write)
                cnt[7] <= cnt[7] + dp_wait_full;
            if (hready & dp_valid & ~dp_write & (dp_wait_full > cnt[8]))
                cnt[8] <= dp_wait_full;
            if (hready & dp_valid &  dp_write & (dp_wait_full > cnt[9]))
                cnt[9] <= dp_wait_full;
            if (is_busy) cnt[10] <= cnt[10] + 32'd1;
            if (dp_valid | burst_open) cnt[11] <= cnt[11] + 32'd1;
            for (i = 0; i < 8; i = i + 1) begin    // per HBURST (constant index)
                if (acc_ns & ~hwrite & (hburst == i)) cnt[12 + i] <= cnt[12 + i] + 32'd1;
                if (acc_ns &  hwrite & (hburst == i)) cnt[20 + i] <= cnt[20 + i] + 32'd1;
            end
            for (i = 0; i < 4; i = i + 1) begin    // per HSIZE[1:0]
                if (acc_ns & ~hwrite & (hsize[1:0] == i)) cnt[28 + i] <= cnt[28 + i] + 32'd1;
                if (acc_ns &  hwrite & (hsize[1:0] == i)) cnt[32 + i] <= cnt[32 + i] + 32'd1;
            end
        end
    end

    // ---------------- transaction trace (dual-clock RAM) ----------------
    reg  [63:0]       tmem [0:(1<<TRACE_AW)-1];
    reg  [TRACE_AW:0] twa;                         // entries written (MSB = full)
    reg  [15:0]       ts;
    wire              tfull = twa[TRACE_AW];
    wire              twe   = en & arm & acc & ~tfull;
    wire [63:0]       twd   = {ts, dp_wait, hwrite, hburst, hsize[1:0],
                               htrans[0], dp_valid, haddr};

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            twa <= {(TRACE_AW+1){1'b0}};
            ts  <= 16'd0;
        end else begin
            ts <= ts + 16'd1;
            if (clr)      twa <= {(TRACE_AW+1){1'b0}};
            else if (twe) twa <= twa + 1'b1;
        end
    end
    always @(posedge hclk)
        if (twe) tmem[twa[TRACE_AW-1:0]] <= twd;

    reg [63:0] trd;
    always @(posedge pclk)
        trd <= tmem[trace_idx];

    // ---------------- APB read mux (registered) ----------------
    wire [5:0] ci = a_q[7:2];                      // counter index for 0x100..0x1FC
    reg  [31:0] rmux;
    always @(posedge pclk or negedge presetn)
        if (!presetn)    prdata <= 32'd0;
        else if (apb_rd) prdata <= rmux;
    always @(*) begin
        rmux = 32'd0;
        if (a_q[11:8] == 4'h1) begin              // 0x100..0x1FF
            if (ci < 36)           rmux = cnt[ci];
            else if (ci < NCNT)    rmux = ext_cnt[(ci-36)*32 +: 32];
        end else begin
            case (a_q)
                12'h000: rmux = {16'hDD3B, CONFIG[15:0]};
                12'h004: rmux = {29'd0, ctl_arm, 1'b0, ctl_en};
                12'h008: rmux = {15'd0, tfull, {(16-TRACE_AW-1){1'b0}}, twa};
                12'h00C: rmux = {{(32-TRACE_AW){1'b0}}, trace_idx};
                12'h010: rmux = trd[31:0];
                12'h014: rmux = trd[63:32];
                12'h018: rmux = CONFIG;
                12'h020: rmux = mode;
                default: rmux = 32'd0;
            endcase
        end
    end
endmodule
`default_nettype wire
