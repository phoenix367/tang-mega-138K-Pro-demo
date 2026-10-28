`default_nettype none
//============================================================================
// ahb_ddr3_bridge.v -- AHB-lite (64-bit) slave -> Gowin DDR3 Memory Interface
// IP user port (1:4 clock ratio, x16 DRAM, BL8 = 128 bits per command).
//
// Replaces Gowin's gw_ahb_ddr3, which turns EVERY 64-bit AHB beat into its
// own DDR3 command with a full clock-domain round trip (~1 us per beat, so a
// 32 B L1 line fill = 4 round trips ~ 5 us).  This bridge works in cache
// lines instead:
//
//  * Read: NBUF line buffers (32 B each, the A25 L1 line).  A miss fetches
//    the whole line as two BL8 reads (critical 16 B half first; per-half
//    valid bits release the stalled beat as soon as its half lands), so the 4
//    beats of a WRAP4/INCR4 line fill cost ONE DDR round trip.  The line being
//    read is copied (cl_data) and its remaining beats are predicted and
//    answered with zero wait states.
//  * AHB side built for a 100 MHz DDR_HCLK: AHB inputs are only registered
//    and HREADY / HRDATA come straight from flops (long routes to and from
//    the hard AE350 macro); see the "AHB side" section below.
//  * Prefetch: a small stream table (NS slots) spots ascending line streams
//    (memcpy src + dst + the instruction stream interleave fine) and keeps
//    lines L+1..L+PF_DIST in flight, so streaming overlaps PF_DIST+1 DDR
//    round trips instead of paying one per line.
//  * Write: posted.  Beats are merged into a 16 B block (byte mask) and
//    pushed as one masked BL8 write; HREADY stays high unless the command
//    FIFO is full.  Every accepted write invalidates any buffered copy of its
//    line (a generation tag drops data still in flight for it).
//  * Ordering: reads and writes share ONE command FIFO into the DDR clock
//    domain, and a read is never queued while a merged write is still held
//    back, so DDR sees accesses in program order.  The bridge is the only
//    path to DDR (CPU and the EXTM DMA both arrive on this bus), so the line
//    buffers stay coherent.
//  * Gowin MC handshake: IPUG281 describes a same-cycle cmd_en & cmd_ready
//    handshake, while Sipeed's known-good DDR test drives cmd_en from a
//    register (cmd_en(t) = cmd_ready(t-1)).  A command is issued here only when
//    cmd_ready (and wr_data_rdy for writes) was high in BOTH the previous and
//    the current cycle, which is safe under either reading (mode[17] = the
//    same-cycle handshake; it also runs clean on hardware, ~15% more memcpy).
//  * Read overlap: by default (mode[16]) reads to different DRAM rows overlap.
//    With mode[16] clear, a read to another row waits until all in-flight
//    reads have returned.  That rule came from an early theory that the MC
//    returns reads out of order across rows; the read BIST disproved it (the
//    Linux oopses were the A25 page-table walker, see PATCHES/0005).
//  * Video port: a read-only second DDR client in the uclk domain (LCD
//    scan-out, video/rtl).  Its BL8 reads go out in cycles where the issue
//    slot is empty (the bridge goes first) or, once a request has waited
//    VAGE uclk, ahead of the bridge's next command -- a CPU write stream
//    keeps the slot full and would starve it otherwise.  At most VMAX in
//    flight, never during the BIST.  Returns are routed by issue order: a 1-bit FIFO
//    records which client each read in flight belongs to (the MC answers in
//    order).  Video reads bypass the line buffers -- they only see DDR, so a
//    pixel can lag a posted CPU write by a frame, which scan-out tolerates.
//
// Clocks: hclk = SoC DDR_HCLK (AHB side), uclk = DDR3 IP clk_out (memory
// clock / 4).  The two are asynchronous; ddr_async_fifo crosses both ways.
//
// DDR address: byte address [ADDR_BITS-1:0] -> IP word address (x16) = byte>>1
// in the IP's {bank,row,column} order.
//============================================================================
module ahb_ddr3_bridge #(
    parameter ADDR_BITS = 28,        // DDR bytes = 2**ADDR_BITS (256 MB)
    parameter NBUF      = 8,         // read line buffers (2, 4 or 8)
    parameter PREFETCH  = 1,         // stream prefetch on/off
    parameter PF_DIST   = 2,         // lines kept in flight ahead of a stream (1..3)
    parameter NS        = 4          // stream table slots
) (
    // ---------------- AHB-lite slave (hclk) ----------------
    input  wire         hclk,
    input  wire         hresetn,
    input  wire [31:0]  haddr,
    input  wire [1:0]   htrans,
    input  wire         hwrite,
    input  wire [2:0]   hsize,
    input  wire [2:0]   hburst,
    input  wire [3:0]   hprot,           // unused (kept for the bus contract)
    input  wire [63:0]  hwdata,
    output wire         hready,
    output wire [1:0]   hresp,
    output wire [63:0]  hrdata,
    // debug mode bits (any domain, quasi-static; synchronized here):
    //   [0] no prefetch  [1] same as [0] (was "no retention")
    //   [2] no write merging: one DDR write per AHB beat
    //   DDR-side command spacing (G = mode[15:12]*4 uclk, 0 -> 32):
    //   [5] no read within G of a write     [6] one command at a time (read:
    //       until its data returns; write: G) -- stock gw_ahb_ddr3 spacing
    //   [7] no write within G of a write    [8] one read in flight at a time
    //   [9] no write while a read is in flight
    //   [10] no read within G of a read     [11] no write within G of a read
    //   [16] let reads to different rows overlap (the default, MODE 0x10000)
    //   [17] UNSAFE: same-cycle-only cmd_ready/wr_data_rdy handshake (pre-fix)
    //   [18] no early release: a read beat waits until its WHOLE line is in
    //   [19] no predicted beats: every read beat takes >= 1 wait state
    //   [20] reads overlap only within one line (another line waits)
    //   [21] fetch a line's half 0 first (no critical-half-first)
    //   read BIST (ddr_rd_bist): [24] start (toggle)  [26:25] pattern
    //   [31:28] iterations = 2**(n+8); results in perf_cnt[511:256]
    input  wire [31:0]  mode,
    // perf control from ddr_perf (hclk domain)
    input  wire         perf_en,
    input  wire         perf_clr,
    output wire [511:0] perf_cnt,

    // ---------------- DDR3 IP user interface (uclk) ----------------
    input  wire         uclk,
    input  wire         calib_done,      // init_calib_complete
    input  wire         cmd_ready,
    output wire [2:0]   cmd,
    output wire         cmd_en,
    output wire [27:0]  addr,
    input  wire         wr_data_rdy,
    output wire [127:0] wr_data,
    output wire         wr_data_en,
    output wire         wr_data_end,
    output wire [15:0]  wr_data_mask,
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid,

    // ---------------- video read port (uclk, read-only) ----------------
    output wire         v_rstn,          // uclk-domain reset (released after calibration)
    input  wire         v_req,           // a BL8 read of v_addr is wanted
    input  wire [ADDR_BITS-1:0] v_addr,  // byte address, 16 B aligned
    output wire         v_ack,           // ... issued this cycle
    output wire         v_rvalid,        // data of the oldest video read in flight
    output wire [127:0] v_rdata
);
    localparam LB = ADDR_BITS - 5;           // line address bits
    localparam BB = ADDR_BITS - 4;           // 16 B block address bits
    localparam EB = (NBUF > 4) ? 3 : (NBUF > 2) ? 2 : 1;   // entry index bits
    localparam GB = 4;                       // generation tag bits

    // command FIFO entry: {is_read, blk[BB-1:0], data[127:0], mask[15:0]}
    //   read:  blk = {line, crit_half}, mask = {.., gen, entry}
    localparam CW = 1 + BB + 128 + 16;
    // return FIFO entry: {line, entry, gen, half, data} (line: integrity check)
    localparam RW = LB + EB + GB + 1 + 128;

    assign hresp = 2'b00;

    //========================================================================
    // Resets: one common source, the SoC's DDR_HRSTN (released only after DDR
    // calibration, synchronous to hclk).  The AHB side uses it directly -- a
    // re-synchronized copy would leave cycles where HREADY is high but the
    // bridge is still in reset and would drop a transfer -- and the DDR side
    // gets a synchronized copy, so both FIFO sides restart together.
    //========================================================================
    wire hrst_n = hresetn;

    reg [31:0] mode_s1, mode_s2;
    always @(posedge hclk or negedge hrst_n)
        if (!hrst_n) begin mode_s1 <= 32'd0; mode_s2 <= 32'd0; end
        else         begin mode_s1 <= mode; mode_s2 <= mode_s1; end
    wire m_nopf   = mode_s2[0] | mode_s2[1];
    wire m_noret  = mode_s2[1];
    wire m_nomrg  = mode_s2[2];
    wire m_wline  = mode_s2[18];
    wire m_nofast = mode_s2[19];

    reg [1:0] urst_s;
    wire      urst_src = hresetn & calib_done;
    always @(posedge uclk or negedge urst_src)
        if (!urst_src) urst_s <= 2'b00; else urst_s <= {urst_s[0], 1'b1};
    wire urst_n = urst_s[1];

    //========================================================================
    // AHB side -- built for a 100 MHz DDR_HCLK.  The SoC's DDR_H* outputs
    // reach the fabric late (long route from the hard AE350 macro) and
    // HREADY / HRDATA have a long route back into it, so:
    //  * address-phase signals are only registered (aq_*); just HTRANS and
    //    HWRITE feed one small decision into the HREADY flop;
    //  * HREADY / HRDATA are flops (hready_q / hrdata_q), nothing after them.
    // Read data phases:
    //  * predicted beats: after the first beat of a WRAP4 (or line-aligned
    //    INCR4) 64-bit read, the next beats are staged from cl_data, a copy of
    //    the current line, so every SEQ beat is answered with zero wait states;
    //  * anything else waits: 1 wait state on a current-line hit, 2 on a line
    //    buffer hit, a DDR round trip on a miss (slow path, sp_*).
    // Writes are posted: beats go into a 4-entry queue (wq) and a head register
    // (wh), then merge into the 16 B block buffer (wb).  A read data phase waits
    // until queued writes are processed: they invalidate stale line-buffer and
    // current-line copies and must reach DDR first.
    //========================================================================
    localparam [2:0] HB_WRAP4 = 3'b010, HB_INCR4 = 3'b011;

    reg                 hready_q;
    reg  [63:0]         hrdata_q;
    assign hready = hready_q;
    assign hrdata = hrdata_q;

    // the transfer in its data phase, captured when the bus samples (hready_q)
    reg                 aq_v, aq_wr, aq_seq;
    reg [ADDR_BITS-1:0] aq_addr;
    reg [2:0]           aq_size, aq_burst;
    wire [LB-1:0] aq_line = aq_addr[ADDR_BITS-1:5];
    wire          aq_half = aq_addr[4];
    wire [1:0]    aq_beat = aq_addr[4:3];
    wire          rd_wait = aq_v & ~aq_wr & ~hready_q;   // read data phase being held
    wire          wr_dph  = aq_v &  aq_wr;               // write data phase this cycle
    wire          wr_take = hready_q & wr_dph;           // ... completes: HWDATA -> wq

    // line buffer entries
    reg [LB-1:0]  ent_tag  [0:NBUF-1];
    reg           ent_alloc[0:NBUF-1];       // tag valid (data may be in flight)
    reg [1:0]     ent_hv   [0:NBUF-1];       // per-16 B-half data valid
    reg [GB-1:0]  ent_gen  [0:NBUF-1];
    reg [EB-1:0]  ent_age  [0:NBUF-1];       // LRU age, 0 = most recent
    reg [255:0]   ent_data [0:NBUF-1];

    // command FIFO (hclk -> uclk).  Pushes are decided combinationally but
    // written one cycle later from a register (cfq_*), keeping the decision
    // logic off the FIFO write port.  cf_afull is registered too: computed
    // from a level one cycle old, it can miss up to 3 pushes (decided 2, 1
    // and 0 cycles ago), so 13 leaves room in the 16-entry FIFO.
    wire          cf_full, cf_empty;
    wire [CW-1:0] cf_rdata;
    reg           cf_push;
    reg  [CW-1:0] cf_wdata;
    wire [4:0]    cf_wlevel;
    reg           cfq_push;
    reg  [CW-1:0] cfq_data;
    reg           cf_afull;

    // return FIFO (uclk -> hclk)
    wire          rf_empty;
    wire [RW-1:0] rf_rdata;

    function pending_f(input alloc, input [1:0] hv);
        pending_f = alloc & ~(&hv);
    endfunction

    // ---- current line: a copy of the line the read bursts are served from ----
    reg           cl_v;
    reg [EB-1:0]  cl_idx;                    // its line buffer entry + generation:
    reg [GB-1:0]  cl_gen;                    //   returning halves update the copy too
    reg [LB-1:0]  cl_line;
    reg [1:0]     cl_hv;
    reg [255:0]   cl_data;

    // ---- predicted burst beats (served from cl_data) ----
    reg           nb_v;
    reg [1:0]     nb_left, nb_beat;          // beats still to come / next beat in the line
    wire          nb_ok   = nb_v & (nb_left != 2'd0) & cl_v & cl_hv[nb_beat[1]]
                          & (~m_wline | (&cl_hv)) & ~m_nofast;
    wire [63:0]   nb_data = cl_data[nb_beat*64 +: 64];

    // ---- posted writes: queue -> head register -> 16 B merge buffer ----
    localparam WQW = ADDR_BITS + 3 + 64;
    reg  [WQW-1:0]      wq_mem [0:3];
    reg  [1:0]          wq_wp, wq_rp;
    reg  [2:0]          wq_n;
    reg                 wh_v;
    reg [ADDR_BITS-1:0] wh_addr;
    reg  [2:0]          wh_size;
    reg  [63:0]         wh_data;
    wire                wq_busy = (wq_n != 3'd0) | wh_v;
    // room for a write data phase completing at the end of NEXT cycle
    wire                wspace  = ({1'b0, wq_n} + {3'd0, wr_take}) <= 4'd2;

    reg           wb_valid;
    reg [BB-1:0]  wb_blk;
    reg [127:0]   wb_data;
    reg [15:0]    wb_mask;                     // 1 = byte written

    wire [BB-1:0] wh_blk  = wh_addr[ADDR_BITS-1:4];
    wire [LB-1:0] wh_line = wh_addr[ADDR_BITS-1:5];
    reg [7:0] be8;
    always @(*) begin
        case (wh_size)
            3'd0:    be8 = 8'h01 << wh_addr[2:0];
            3'd1:    be8 = 8'h03 << {wh_addr[2:1], 1'b0};
            3'd2:    be8 = 8'h0F << {wh_addr[2], 2'b00};
            default: be8 = 8'hFF;
        endcase
    end
    wire [15:0] be16 = wh_addr[3] ? {be8, 8'h00} : {8'h00, be8};

    // wh_sb: wh's 16 B block is the (valid) merge block -- compared when the
    // head is loaded, against wb as it is after that edge (wb only changes
    // when wh is consumed, or by an idle flush while wh is empty)
    reg  wh_sb;
    wire same_blk   = wh_sb & ~m_nomrg;
    wire flush_wr   = wh_v & wb_valid & ~same_blk;              // push the old block first
    wire flush_idle = wb_valid & ~wh_v & (wq_n == 3'd0) & ~wr_dph; // write burst over
    wire wh_cons    = wh_v & (~flush_wr | ~cf_afull);
    wire push_wr    = (flush_wr | flush_idle) & ~cf_afull;
    wire wh_load    = (wq_n != 3'd0) & (~wh_v | wh_cons);

    // ---- victim: computed every cycle into registers; allocations at most
    //      every other cycle (alloc_cool) so a registered victim is never one
    //      just allocated ----
    reg            vic_ok, pvic_ok_c;
    reg [EB-1:0]   vic;
    integer e, a;
    always @(*) begin
        vic_ok = 1'b0; vic = {EB{1'b0}};
        for (e = NBUF-1; e >= 0; e = e - 1)          // free entry first
            if (!ent_alloc[e]) begin vic_ok = 1'b1; vic = e[EB-1:0]; end
        if (!vic_ok)                                  // else the oldest non-pending one
            for (a = 0; a < NBUF; a = a + 1)
                for (e = NBUF-1; e >= 0; e = e - 1)
                    if (ent_age[e] == a[EB-1:0] && !pending_f(ent_alloc[e], ent_hv[e])) begin
                        vic_ok = 1'b1; vic = e[EB-1:0];
                    end
        // prefetch victim: only the older half of the LRU order -- the same
        // as "vic is free or old" without waiting for vic.  The current line
        // needs no protection: its reads are served from the cl_data copy.
        pvic_ok_c = 1'b0;
        for (e = 0; e < NBUF; e = e + 1)
            if (!ent_alloc[e] || (ent_age[e] >= NBUF/2 && !pending_f(ent_alloc[e], ent_hv[e])))
                pvic_ok_c = 1'b1;
    end
    reg            vic_ok_q, pvic_ok_q, alloc_cool;
    reg [EB-1:0]   vic_q;

    // ---- read slow path ----
    localparam [1:0] SP_IDLE = 2'd0, SP_LOOK = 2'd1, SP_WAIT = 2'd2;
    reg  [1:0]     sp_st;
    reg            lk_tag, lk_data;          // registered lookup result
    reg  [EB-1:0]  lk_idx;
    reg  [NBUF-1:0] lk_oh;                   // one-hot lk_idx (AND-OR data mux)

    // A line is never in two entries (demand allocates only on a lookup miss,
    // prefetch only when the line is absent; formal: no duplicate tags), so
    // tag_hit is one-hot or zero and serves directly as the lookup select.
    reg [NBUF-1:0] tag_hit, data_hit;
    reg [EB-1:0]   tag_idx;
    always @(*) begin
        tag_idx = {EB{1'b0}};
        for (e = 0; e < NBUF; e = e + 1) begin
            tag_hit[e]  = ent_alloc[e] && (ent_tag[e] == aq_line);
            data_hit[e] = tag_hit[e] && (m_wline ? (&ent_hv[e]) : ent_hv[e][aq_half]);
            if (tag_hit[e]) tag_idx = tag_idx | e[EB-1:0];   // one-hot -> binary (OR)
        end
    end

    wire sp_go    = rd_wait & (sp_st == SP_IDLE) & ~wq_busy;
    wire cl_match = cl_v & (cl_line == aq_line);
    wire cl_rdy   = cl_hv[aq_half] & (~m_wline | (&cl_hv));
    wire lk_go    = sp_go & ~cl_match;                       // full lookup this cycle
    // deliveries at the end of this cycle (HREADY high next cycle)
    wire dl_cl    = rd_wait & cl_v & cl_rdy & ((sp_go & cl_match) | (sp_st == SP_WAIT));
    wire dl_ent   = rd_wait & (sp_st == SP_LOOK) & lk_data;
    wire sp_dlv   = dl_cl | dl_ent;
    wire cl_ld_ent = rd_wait & (sp_st == SP_LOOK) & lk_tag;   // current line <- that entry
    reg  [255:0] lk_line_d;                  // the hit line (current-line load)
    reg  [63:0]  lk_beat_d;                  // its beat aq_beat (delivery)
    always @(*) begin
        lk_line_d = 256'd0;
        lk_beat_d = 64'd0;
        for (e = 0; e < NBUF; e = e + 1)
            if (lk_oh[e]) begin
                lk_line_d = lk_line_d | ent_data[e];
                lk_beat_d = lk_beat_d | ent_data[e][aq_beat*64 +: 64];
            end
    end

    // ---- stream table: ascending line streams -> prefetch ahead ----
    // Invariant per active slot: st_next = st_last + 1 + st_cnt, i.e. st_cnt
    // lines past the stream head are already requested (st_cnt <= PF_DIST).
    reg [LB-1:0]  st_last [0:NS-1];            // last line touched by the stream
    reg [LB-1:0]  st_seql [0:NS-1];            // st_last + 1 (precomputed)
    reg [LB-1:0]  st_next [0:NS-1];            // next line to prefetch
    reg [1:0]     st_cnt  [0:NS-1];            // lines in flight ahead of the head
    reg           st_act  [0:NS-1];
    reg [1:0]     st_age  [0:NS-1];            // LRU (NS <= 4)
    reg [LB-1:0]  g_last;                      // last line looked up

    // new-line event: a lookup of a line other than the last one.  The table
    // is compared now and updated next cycle from registers (ev_q / evq_*);
    // prefetch is held off meanwhile, so nothing else changes the table.
    wire          ev = lk_go & (aq_line != g_last);
    reg           ev_q, evq_hit, evq_seq;
    reg  [1:0]    evq_idx, evq_lru;
    reg  [LB-1:0] evq_line, evq_lp1;
    reg  [NS-1:0] st_seq, st_same;
    reg           st_hit;
    reg  [1:0]    st_idx, st_lru;
    integer q;
    always @(*) begin
        st_hit = 1'b0; st_idx = 2'd0; st_lru = 2'd0;
        for (q = 0; q < NS; q = q + 1) begin
            st_seq[q]  = (aq_line == st_seql[q]);
            st_same[q] = (aq_line == st_last[q]);
            if (st_age[q] == NS-1) st_lru = q[1:0];
        end
        for (q = NS-1; q >= 0; q = q - 1)
            if (st_seq[q] | st_same[q]) begin st_hit = 1'b1; st_idx = q[1:0]; end
    end

    // stage 1: an active stream still short of PF_DIST lines ahead
    reg           pf_have;
    reg  [1:0]    pf_slot;
    always @(*) begin
        pf_have = 1'b0; pf_slot = 2'd0;
        for (q = NS-1; q >= 0; q = q - 1)
            if (st_act[q] && st_cnt[q] < PF_DIST) begin
                pf_have = 1'b1; pf_slot = q[1:0];
            end
    end
    // stage 2: a registered candidate (pfc_*) is checked against the line
    // buffers; stage 3 (pf2_*) issues it.  Every stage is recomputed each
    // cycle and dropped when the table changed under it (ev, ev_q, pf_adv)
    // or an entry was allocated meanwhile (pf2_here could be stale).
    reg           pfc_valid;
    reg  [1:0]    pfc_slot;
    reg  [LB-1:0] pfc_line;
    reg [NBUF-1:0] pf_tag_hit;
    always @(*)
        for (e = 0; e < NBUF; e = e + 1)
            pf_tag_hit[e] = ent_alloc[e] && (ent_tag[e] == pfc_line);
    reg           pf2_valid, pf2_here;
    reg  [1:0]    pf2_slot;
    reg  [LB-1:0] pf2_line, pf2_lp1;

    // ---- DDR read requests: demand miss first, then prefetch ----
    // A lookup's result must stay true until used, so no prefetch allocation
    // while one is in progress (lk_go / SP_LOOK); writes (queued or held in
    // wb) must reach the command FIFO before any read of possibly the same line.
    wire can_alloc = vic_ok_q & ~alloc_cool & ~cf_afull & ~wb_valid & ~wq_busy & ~push_wr;
    wire push_dem  = rd_wait & (sp_st == SP_LOOK) & ~lk_tag & can_alloc;
    // (a slow-path read's first cycle may start a lookup: held off whether or
    //  not it does, which keeps the current-line compare off this path)
    wire pf_try    = (PREFETCH != 0) & ~m_nopf & pf2_valid & ~push_dem & ~wr_dph
                   & ~(rd_wait & (sp_st == SP_IDLE)) & (sp_st != SP_LOOK) & ~ev_q;
    wire push_pf   = pf_try & ~pf2_here & pvic_ok_q & can_alloc;
    wire pf_adv    = pf_try & (pf2_here | push_pf);  // line issued or already present

    // ---- the late decision: HREADY for the transfer the bus samples now ----
    wire t_seq     = (htrans == 2'b11);
    wire hr_samp   = ~htrans[1] | (hwrite ? wspace : (t_seq & nb_ok));
    wire hr_wait   = aq_wr ? wspace : sp_dlv;
    wire pred_take = hready_q & t_seq & ~hwrite & nb_ok;    // zero-wait predicted beat

    // ---- command FIFO write mux ----
    always @(*) begin
        cf_push  = 1'b0;
        cf_wdata = {CW{1'b0}};
        if (push_wr) begin
            cf_push  = 1'b1;
            cf_wdata = {1'b0, wb_blk, wb_data, wb_mask};
        end else if (push_dem) begin
            cf_push  = 1'b1;
            cf_wdata = {1'b1, aq_line, aq_half, 128'd0,
                        {(16-GB-EB){1'b0}}, ent_gen[vic_q] + 1'b1, vic_q};
        end else if (push_pf) begin
            cf_push  = 1'b1;
            cf_wdata = {1'b1, pf2_line, 1'b0, 128'd0,
                        {(16-GB-EB){1'b0}}, ent_gen[vic_q] + 1'b1, vic_q};
        end
    end

    // ---- return data: popped every cycle and applied two cycles later.
    //      rfq_* may land in the FIFO's BSRAM output register (slow clock-to-
    //      out), so rf_* is a fabric copy with the target entry pre-decoded
    //      (rf_oh): each entry checks only its own alloc / gen.  The gen check
    //      drops data for an entry invalidated or reallocated meanwhile. ----
    wire          rf_pop  = ~rf_empty;
    reg           rfq_v;
    reg  [RW-1:0] rfq_d;
    reg           rf_v, rf_half;
    reg  [LB-1:0] rf_line;
    reg  [EB-1:0] rf_ent;
    reg  [GB-1:0] rf_gen;
    reg  [127:0]  rf_data;
    reg  [NBUF-1:0] rf_oh;
    always @(posedge hclk or negedge hrst_n)
        if (!hrst_n) begin
            rfq_v <= 1'b0; rfq_d <= {RW{1'b0}};
            rf_v <= 1'b0; rf_half <= 1'b0; rf_line <= {LB{1'b0}}; rf_ent <= {EB{1'b0}};
            rf_gen <= {GB{1'b0}}; rf_data <= 128'd0; rf_oh <= {NBUF{1'b0}};
        end else begin
            rfq_v   <= rf_pop;
            rfq_d   <= rf_rdata;
            rf_v    <= rfq_v;
            rf_line <= rfq_d[RW-1 -: LB];
            rf_ent  <= rfq_d[RW-LB-1 -: EB];
            rf_gen  <= rfq_d[RW-LB-EB-1 -: GB];
            rf_half <= rfq_d[128];
            rf_data <= rfq_d[127:0];
            rf_oh   <= rfq_v ? ({{(NBUF-1){1'b0}}, 1'b1} << rfq_d[RW-LB-1 -: EB]) : {NBUF{1'b0}};
        end
    reg [NBUF-1:0] rf_hit;                   // return lands in entry e
    always @(*)
        for (e = 0; e < NBUF; e = e + 1)
            rf_hit[e] = rf_oh[e] && ent_alloc[e] && (ent_gen[e] == rf_gen);

    // a returning half also updates the current line copy -- including the
    // one loaded from line buffer lk_idx this cycle (it would otherwise copy
    // the entry just before the half lands).  A fresh allocation (push_dem)
    // cannot receive data in its first cycle.
    wire          rf_cl   = rf_v & ~push_dem &
                            (cl_ld_ent ? (rf_ent == lk_idx) && (rf_gen == ent_gen[lk_idx])
                                       : cl_v && (rf_ent == cl_idx) && (rf_gen == cl_gen));

    // ---- LRU touch (applied one cycle later from lru_* registers) ----
    reg           touch;
    reg [EB-1:0]  touch_idx;
    reg           lru_v;
    reg [EB-1:0]  lru_idx;
    always @(*) begin
        touch = 1'b0; touch_idx = {EB{1'b0}};
        if (push_dem | push_pf) begin touch = 1'b1; touch_idx = vic_q;  end
        else if (dl_ent)        begin touch = 1'b1; touch_idx = lk_idx; end
    end

    // perf counters (hclk); pc_tagmis: returns whose line address disagrees
    // with the entry they land in (end-to-end check of the tag/CDC path)
    reg [31:0] pc_hit0, pc_dem, pc_pf, pc_wr, pc_tagmis;
    reg        pred_q, tagmis_q;

    integer k;
    always @(posedge hclk or negedge hrst_n) begin
        if (!hrst_n) begin
            hready_q <= 1'b1; hrdata_q <= 64'd0;
            aq_v <= 1'b0; aq_wr <= 1'b0; aq_seq <= 1'b0;
            aq_addr <= {ADDR_BITS{1'b0}}; aq_size <= 3'd0; aq_burst <= 3'd0;
            cl_v <= 1'b0; cl_idx <= {EB{1'b0}}; cl_gen <= {GB{1'b0}}; cl_line <= {LB{1'b0}};
            cl_hv <= 2'b00; cl_data <= 256'd0;
            nb_v <= 1'b0; nb_left <= 2'd0; nb_beat <= 2'd0;
            wq_wp <= 2'd0; wq_rp <= 2'd0; wq_n <= 3'd0;
            wh_v <= 1'b0; wh_addr <= {ADDR_BITS{1'b0}}; wh_size <= 3'd0; wh_data <= 64'd0;
            wb_valid <= 1'b0; wb_blk <= {BB{1'b0}}; wb_data <= 128'd0; wb_mask <= 16'd0;
            vic_ok_q <= 1'b0; pvic_ok_q <= 1'b0; vic_q <= {EB{1'b0}}; alloc_cool <= 1'b0;
            sp_st <= SP_IDLE; lk_tag <= 1'b0; lk_data <= 1'b0; lk_idx <= {EB{1'b0}};
            lk_oh <= {NBUF{1'b0}}; wh_sb <= 1'b0;
            ev_q <= 1'b0; evq_line <= {LB{1'b0}}; evq_lp1 <= {LB{1'b0}};
            evq_hit <= 1'b0; evq_seq <= 1'b0; evq_idx <= 2'd0; evq_lru <= 2'd0;
            pf2_valid <= 1'b0; pf2_slot <= 2'd0; pf2_line <= {LB{1'b0}};
            pf2_lp1 <= {LB{1'b0}}; pf2_here <= 1'b0;
            g_last   <= {LB{1'b1}};
            for (k = 0; k < NS; k = k + 1) begin
                st_last[k] <= {LB{1'b1}}; st_seql[k] <= {LB{1'b0}}; st_next[k] <= {LB{1'b0}};
                st_cnt[k]  <= 2'd0;       st_act[k]  <= 1'b0;       st_age[k]  <= k[1:0];
            end
            pfc_valid <= 1'b0; pfc_slot <= 2'd0; pfc_line <= {LB{1'b0}};
            cfq_push  <= 1'b0; cfq_data <= {CW{1'b0}};
            for (k = 0; k < NBUF; k = k + 1) begin
                ent_tag[k] <= {LB{1'b0}}; ent_alloc[k] <= 1'b0; ent_hv[k] <= 2'b00;
                ent_gen[k] <= {GB{1'b0}}; ent_age[k] <= k[EB-1:0];
                ent_data[k] <= 256'd0;
            end
            lru_v <= 1'b0; lru_idx <= {EB{1'b0}};
            pc_hit0 <= 32'd0; pc_dem <= 32'd0; pc_pf <= 32'd0; pc_wr <= 32'd0;
            pc_tagmis <= 32'd0; pred_q <= 1'b0; tagmis_q <= 1'b0; cf_afull <= 1'b0;
        end else begin
            tagmis_q <= 1'b0;
            for (k = 0; k < NBUF; k = k + 1)
                if (rf_hit[k] && ent_tag[k] != rf_line) tagmis_q <= 1'b1;
            if (tagmis_q) pc_tagmis <= pc_tagmis + 32'd1;   // never cleared: sticky evidence
            cf_afull <= (cf_wlevel >= 5'd13);

            // ---- AHB handshake ----
            hready_q <= hready_q ? hr_samp : hr_wait;
            if (hready_q) begin                  // the bus samples an address phase
                aq_v     <= htrans[1];
                aq_wr    <= hwrite;
                aq_seq   <= t_seq;
                aq_addr  <= haddr[ADDR_BITS-1:0];
                aq_size  <= hsize;
                aq_burst <= hburst;
                hrdata_q <= nb_data;             // used only if it is a predicted beat
            end else if (sp_dlv) begin
                hrdata_q <= dl_ent ? lk_beat_d : cl_data[aq_beat*64 +: 64];
            end

            // ---- predicted beats ----
            if (pred_take) begin
                nb_left <= nb_left - 2'd1;
                nb_beat <= nb_beat + 2'd1;
            end else if (sp_dlv) begin
                if (!aq_seq) begin               // first beat: set up the rest of the burst
                    nb_v    <= (aq_size == 3'd3) &&
                               (aq_burst == HB_WRAP4 || (aq_burst == HB_INCR4 && aq_beat == 2'd0));
                    nb_left <= 2'd3;
                    nb_beat <= aq_beat + 2'd1;
                end else if (nb_v) begin         // a SEQ beat that took the slow path
                    nb_left <= nb_left - 2'd1;
                    nb_beat <= nb_beat + 2'd1;
                end
            end

            // ---- read slow path ----
            case (sp_st)
                SP_IDLE: if (sp_go) begin
                    if (cl_match) begin
                        if (!cl_rdy) sp_st <= SP_WAIT;   // else delivered now (dl_cl)
                    end else begin
                        sp_st   <= SP_LOOK;
                        lk_tag  <= |tag_hit;
                        lk_data <= |data_hit;
                        lk_idx  <= tag_idx;
                        lk_oh   <= tag_hit;
                    end
                end
                SP_LOOK: begin
                    if (lk_data)      sp_st <= SP_IDLE;  // delivered now (dl_ent)
                    else if (lk_tag)  sp_st <= SP_WAIT;  // its line is in flight
                    else if (push_dem) sp_st <= SP_WAIT; // DDR read issued
                end
                default: if (dl_cl) sp_st <= SP_IDLE;
            endcase

            // ---- current line copy ----
            if (push_dem) begin
                cl_v <= 1'b1; cl_idx <= vic_q; cl_gen <= ent_gen[vic_q] + 1'b1;
                cl_line <= aq_line; cl_hv <= 2'b00;
            end else if (cl_ld_ent) begin
                cl_v <= 1'b1; cl_idx <= lk_idx; cl_gen <= ent_gen[lk_idx];
                cl_line <= aq_line; cl_hv <= ent_hv[lk_idx]; cl_data <= lk_line_d;
            end
            if (rf_cl) begin                     // a half of the current line returns
                if (rf_half) cl_data[255:128] <= rf_data;
                else         cl_data[127:0]   <= rf_data;
                cl_hv[rf_half] <= 1'b1;
            end

            // ---- return data into line buffers ----
            for (k = 0; k < NBUF; k = k + 1)
                if (rf_hit[k]) begin
                    if (rf_half) ent_data[k][255:128] <= rf_data;
                    else         ent_data[k][127:0]   <= rf_data;
                    ent_hv[k][rf_half] <= 1'b1;
                end

            // ---- LRU ----
            lru_v <= touch; lru_idx <= touch_idx;
            if (lru_v) begin
                for (k = 0; k < NBUF; k = k + 1)
                    if (ent_age[k] < ent_age[lru_idx]) ent_age[k] <= ent_age[k] + 1'b1;
                ent_age[lru_idx] <= {EB{1'b0}};
            end

            // ---- victim (registered) and allocation ----
            vic_q      <= vic;
            vic_ok_q   <= vic_ok;
            pvic_ok_q  <= pvic_ok_c;
            alloc_cool <= push_dem | push_pf;
            if (push_dem) begin
                ent_alloc[vic_q] <= 1'b1; ent_tag[vic_q] <= aq_line; ent_hv[vic_q] <= 2'b00;
                ent_gen[vic_q]   <= ent_gen[vic_q] + 1'b1;
            end
            if (push_pf) begin
                ent_alloc[vic_q] <= 1'b1; ent_tag[vic_q] <= pf2_line; ent_hv[vic_q] <= 2'b00;
                ent_gen[vic_q]   <= ent_gen[vic_q] + 1'b1;
            end
            if (pf_adv) begin
                st_next[pf2_slot] <= pf2_lp1;    // = st_next + 1 (pf2_line was st_next)
                st_cnt[pf2_slot]  <= st_cnt[pf2_slot] + 2'd1;
            end
            pfc_valid <= pf_have & ~ev & ~ev_q & ~pf_adv;
            pfc_slot  <= pf_slot;
            pfc_line  <= st_next[pf_slot];
            pf2_valid <= pfc_valid & ~ev & ~ev_q & ~pf_adv & ~push_dem & ~push_pf;
            pf2_slot  <= pfc_slot;
            pf2_line  <= pfc_line;
            pf2_lp1   <= pfc_line + 1'b1;
            pf2_here  <= |pf_tag_hit;

            // registered command-FIFO push
            cfq_push <= cf_push;
            cfq_data <= cf_wdata;

            // ---- stream table update on a new-line lookup (compared at ev,
            //      applied next cycle from evq_*) ----
            ev_q <= ev;
            if (ev) begin
                g_last   <= aq_line;
                evq_line <= aq_line;
                evq_lp1  <= aq_line + 1'b1;
                evq_hit  <= st_hit;
                evq_seq  <= st_seq[st_idx];
                evq_idx  <= st_idx;
                evq_lru  <= st_lru;
            end
            if (ev_q) begin
                if (evq_hit) begin
                    if (evq_seq) begin
                        st_last[evq_idx] <= evq_line;
                        st_seql[evq_idx] <= evq_lp1;
                        st_act[evq_idx]  <= 1'b1;
                        // keep st_next = st_last + 1 + st_cnt
                        if (st_cnt[evq_idx] == 2'd0)
                            st_next[evq_idx] <= evq_lp1;
                        else
                            st_cnt[evq_idx]  <= st_cnt[evq_idx] - 2'd1;
                    end
                    for (k = 0; k < NS; k = k + 1)
                        if (st_age[k] < st_age[evq_idx]) st_age[k] <= st_age[k] + 2'd1;
                    st_age[evq_idx] <= 2'd0;
                end else begin
                    st_last[evq_lru] <= evq_line;
                    st_seql[evq_lru] <= evq_lp1;
                    st_next[evq_lru] <= evq_lp1;
                    st_cnt[evq_lru]  <= 2'd0;
                    st_act[evq_lru]  <= 1'b0;
                    for (k = 0; k < NS; k = k + 1)
                        if (st_age[k] < st_age[evq_lru]) st_age[k] <= st_age[k] + 2'd1;
                    st_age[evq_lru] <= 2'd0;
                end
            end

            // ---- posted writes: queue, head, merge / flush, invalidate ----
            if (wr_take) begin
                wq_mem[wq_wp] <= {aq_addr, aq_size, hwdata};
                wq_wp <= wq_wp + 2'd1;
            end
            if (wh_load) begin
                {wh_addr, wh_size, wh_data} <= wq_mem[wq_rp];
                wq_rp <= wq_rp + 2'd1;
                // against wb after this edge: a consumed head becomes the block
                wh_sb <= (wh_cons | wb_valid) &&
                         (wq_mem[wq_rp][WQW-1 -: BB] == (wh_cons ? wh_blk : wb_blk));
            end
            wq_n <= wq_n + {2'd0, wr_take} - {2'd0, wh_load};
            if (wh_load)      wh_v <= 1'b1;
            else if (wh_cons) wh_v <= 1'b0;

            if (wh_cons) begin
                if (same_blk) begin
                    for (k = 0; k < 16; k = k + 1)
                        if (be16[k]) wb_data[k*8 +: 8] <= wh_data[(k%8)*8 +: 8];
                    wb_mask <= wb_mask | be16;
                end else begin
                    wb_valid <= 1'b1;
                    wb_blk   <= wh_blk;
                    wb_data  <= {wh_data, wh_data};
                    wb_mask  <= be16;
                end
                for (k = 0; k < NBUF; k = k + 1)
                    if (ent_alloc[k] && ent_tag[k] == wh_line) begin
                        ent_alloc[k] <= 1'b0;
                        ent_hv[k]    <= 2'b00;
                        ent_gen[k]   <= ent_gen[k] + 1'b1;
                    end
                if (cl_v && cl_line == wh_line) begin
                    cl_v <= 1'b0;
                    nb_v <= 1'b0;
                end
            end else if (push_wr) begin
                wb_valid <= 1'b0;                               // idle flush
            end

            // ---- perf ----
            pred_q <= pred_take;
            if (perf_clr) begin
                pc_hit0 <= 32'd0; pc_dem <= 32'd0; pc_pf <= 32'd0; pc_wr <= 32'd0;
            end else if (perf_en) begin
                if (pred_q)          pc_hit0 <= pc_hit0 + 32'd1;
                if (push_dem)        pc_dem  <= pc_dem  + 32'd1;
                if (push_pf)         pc_pf   <= pc_pf   + 32'd1;
                if (push_wr)         pc_wr   <= pc_wr   + 32'd1;
            end
        end
    end

    ddr_async_fifo #(.W(CW), .AW(4)) u_cmd_fifo (
        .wclk(hclk), .wrst_n(hrst_n), .wr(cfq_push), .wdata(cfq_data),
        .full(cf_full), .wlevel(cf_wlevel),
        .rclk(uclk), .rrst_n(urst_n), .rd(hq_load), .rdata(cf_rdata), .empty(cf_empty)
    );

    //========================================================================
    // DDR (uclk) side
    //========================================================================
    // registered command head: the FIFO's 16:1 read mux ends in hq_d, so the
    // issue logic, tag queue and IP inputs start from flops (100 MHz uclk)
    reg           hq_v;
    reg  [CW-1:0] hq_d;
    wire          hq_done;                   // head consumed this cycle
    wire          hq_load = ~cf_empty & (~hq_v | hq_done);
    always @(posedge uclk or negedge urst_n)
        if (!urst_n)      begin hq_v <= 1'b0; hq_d <= {CW{1'b0}}; end
        else if (hq_load) begin hq_v <= 1'b1; hq_d <= cf_rdata; end
        else if (hq_done)       hq_v <= 1'b0;

    // issue slot: the command being issued, in fabric flops -- hq_d lands in
    // the BSRAM output register (~1.8 ns clock-to-out), too slow to feed the
    // issue decision at a 100 MHz uclk.  Whether its row / line differs from
    // the reads in flight is compared once, on load (row_ne_q / line_ne_q):
    // rd_row / rd_line only change when this slot issues a read.  The slot
    // loads only while empty (a cycle after it issues), so cmd_ready -- a late
    // IP output -- never reaches the load enables of is_d / hq_d (~340 flops);
    // the bubble costs ~1-4 % of throughput in simulation, less at the real
    // command rate.
    reg           is_v;
    reg  [CW-1:0] is_d;
    reg           row_ne_q, line_ne_q;
    wire          is_done;                   // slot consumed this cycle
    wire          is_load = hq_v & ~is_v;
    assign        hq_done = is_load;

    wire          c_read = is_d[CW-1];
    wire [BB-1:0] c_blk  = is_d[CW-2 -: BB];
    wire [127:0]  c_data = is_d[16 +: 128];
    wire [15:0]   c_mask = is_d[15:0];
    wire [BB-1:0] h_blk  = hq_d[CW-2 -: BB];

    // tag FIFO: one entry per issued BL8 read, popped by rd_data_valid.  The
    // entry is written the cycle after the issue (tq_push_q / tq_wd_q), so
    // issue_rd does not drive the write enable of every entry; the MC answers
    // ~28 uclk later, and "in flight" / "full" count the pending write.
    localparam TW = LB + EB + GB + 1 + 16;   // {line, entry, gen, half, issue timestamp}
    reg  [TW-1:0] tq [0:15];
    reg  [4:0]    tq_w, tq_r;
    reg           tq_push_q;
    reg  [TW-1:0] tq_wd_q;
    reg  [4:0]    tq_n;                      // entries written (= tq_w - tq_r), a register
    wire          tq_full  = tq_push_q ? (tq_n >= 5'd14) : (tq_n >= 5'd15);

    reg           rd_second;                 // issuing the 2nd half of a line read
    reg  [15:0]   ucnt;                      // free-running uclk timestamp

    // debug command spacing (mode[11:5], gap mode[15:12]; synchronized into uclk)
    reg  [31:0]   umode_s1, umode_s2;
    // row of the reads in flight (all in-flight reads share one row)
    localparam    RB = BB - 7;               // bank+row bits = byte addr [27:11]
    reg  [RB-1:0] rd_row;
    wire [RB-1:0] c_row    = c_blk[BB-1:7];
    reg  [5:0]    wgap, rgap;                // uclk since the last write / read command
    wire [5:0]    gap       = (umode_s2[15:12] == 4'd0) ? 6'd32 : {umode_s2[15:12], 2'b00};
    wire          wr_recent = (wgap < gap);
    wire          rd_recent = (rgap < gap);
    wire          rd_out    = (tq_n != 5'd0) | tq_push_q;
    wire          row_blk   = rd_out & row_ne_q & ~umode_s2[16];
    reg  [BB-2:0] rd_line;                   // line of the last read issued
    wire          line_blk  = umode_s2[20] & rd_out & line_ne_q;
    wire          blk_rd    = row_blk | line_blk
                            | (umode_s2[5] & wr_recent) | (umode_s2[6] & (wr_recent | rd_out))
                            | (umode_s2[8] & rd_out)    | (umode_s2[10] & rd_recent);
    wire          blk_wr    = (umode_s2[6] & (wr_recent | rd_out)) | (umode_s2[7] & wr_recent)
                            | (umode_s2[9] & rd_out)    | (umode_s2[11] & rd_recent);

    // handshake: ready must have been high last cycle too (see header)
    reg           cmd_ready_q, wr_rdy_q;
    wire          u_hs_old = umode_s2[17];
    wire          cmd_ok   = cmd_ready   & (cmd_ready_q | u_hs_old);
    wire          wdat_ok  = wr_data_rdy & (wr_rdy_q    | u_hs_old);

    wire          c_valid  = is_v;
    wire          c_first  = c_blk[0] & ~umode_s2[21];            // crit half first
    wire          c_half   = rd_second ? ~c_first : c_first;
    // read BIST: holds the bridge off, then owns the port (read-only)
    wire          bist_hold, bist_own, bist_cmd_en;
    wire [26:0]   bist_addr;
    reg           bist_tgl_q;
    wire          bist_start = umode_s2[24] ^ bist_tgl_q;
    wire [255:0]  bist_res;

    // video port: the command port is the video's while the issue slot is
    // empty, or (v_pri) once its request has waited VAGE uclk -- then the
    // bridge's command waits a cycle.  v_pri is a flop, set a cycle ahead;
    // it is only set with < VMAX-1 reads in flight, so the port has room
    // when it applies.
    localparam    VMAX = 8;                  // video reads in flight
    localparam    VAGE = 8;                  // uclk a request waits before it goes first
    reg  [3:0]    v_n;
    reg  [3:0]    v_age;                     // uclk the current request has waited (saturates)
    reg           v_pri;
    wire          v_room   = (v_n < VMAX);
    wire          v_slot   = ~is_v | v_pri;

    wire          issue_wr = c_valid & ~c_read & cmd_ok & wdat_ok & ~blk_wr & ~bist_hold & ~v_pri;
    wire          issue_rd = c_valid &  c_read & cmd_ok & ~tq_full & ~blk_rd & ~bist_hold & ~v_pri;
    assign        is_done  = issue_wr | (issue_rd & rd_second);

    wire          issue_v  = v_req & v_slot & cmd_ok & ~bist_hold & ~bist_own & v_room;
    // issue order of the reads in flight, 1 = video (bridge <= 15 + video <= 8
    // fit in 32).  who_hd is the head entry as a flop: it is reloaded every
    // cycle with the head after this cycle's return, which is correct for any
    // read issued at least 2 uclk before its data returns (the MC takes ~28).
    reg  [31:0]   who;
    reg  [4:0]    who_w, who_r;
    reg           who_hd;
    wire          rv_any   = rd_data_valid & ~bist_own;
    assign        v_ack    = issue_v;
    assign        v_rvalid = rv_any & who_hd;
    assign        v_rdata  = rd_data;
    assign        v_rstn   = urst_n;

    always @(posedge uclk or negedge urst_n)
        if (!urst_n) begin
            is_v <= 1'b0; is_d <= {CW{1'b0}}; row_ne_q <= 1'b0; line_ne_q <= 1'b0;
        end else if (is_load) begin
            is_v      <= 1'b1;
            is_d      <= hq_d;
            row_ne_q  <= (h_blk[BB-1:7] != rd_row);      // (no issue while empty)
            line_ne_q <= (h_blk[BB-1:1] != rd_line);
        end else begin
            if (is_done)  is_v <= 1'b0;
            if (issue_rd) begin row_ne_q <= 1'b0; line_ne_q <= 1'b0; end
        end
    wire          br_valid = rv_any & ~who_hd;            // returns for the bridge

    // (v_slot: the port belongs to the video read this cycle)
    assign cmd_en       = bist_own ? bist_cmd_en : (issue_wr | issue_rd | issue_v);
    assign cmd          = (bist_own | c_read | v_slot) ? 3'b001 : 3'b000;
    assign addr         = bist_own ? {1'b0, bist_addr}
                        : v_slot ? {{(28-ADDR_BITS+1){1'b0}}, v_addr[ADDR_BITS-1:4], 3'b000}
                        : c_read ? {{(28-ADDR_BITS+1){1'b0}}, c_blk[BB-1:1], c_half, 3'b000}
                                 : {{(28-ADDR_BITS+1){1'b0}}, c_blk, 3'b000};

    ddr_rd_bist u_bist (
        .clk(uclk), .rst_n(urst_n),
        .start(bist_start), .pattern(umode_s2[26:25]), .iter_log2(umode_s2[31:28]),
        .port_idle(!rd_out && v_n == 4'd0),
        .hold(bist_hold), .own(bist_own), .cmd_ok(cmd_ok), .cmd_en(bist_cmd_en), .addr(bist_addr),
        .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .r_status(bist_res[31:0]),     .r_err(bist_res[63:32]),        .r_reorder(bist_res[95:64]),
        .r_first(bist_res[127:96]),    .r_first_addr(bist_res[159:128]),
        .r_first_got(bist_res[191:160]), .r_first_exp(bist_res[223:192]), .r_extra(bist_res[255:224])
    );
    assign wr_data      = c_data;
    assign wr_data_en   = issue_wr;
    assign wr_data_end  = issue_wr;
    assign wr_data_mask = ~c_mask;           // IP: 1 = byte masked

    // perf control into uclk
    reg  [1:0] pen_s;
    reg        pclr_t;
    reg  [2:0] pclr_s;
    always @(posedge hclk or negedge hrst_n)
        if (!hrst_n) pclr_t <= 1'b0; else if (perf_clr) pclr_t <= ~pclr_t;
    always @(posedge uclk or negedge urst_n)
        if (!urst_n) begin pen_s <= 2'b0; pclr_s <= 3'b0; end
        else begin pen_s <= {pen_s[0], perf_en}; pclr_s <= {pclr_s[1:0], pclr_t}; end
    wire u_en  = pen_s[1];
    wire u_clr = pclr_s[2] ^ pclr_s[1];

    reg [31:0] uc_rdcmd, uc_latsum, uc_wrcmd, uc_rdval;
    wire [TW-1:0] tq_head = tq[tq_r[3:0]];
    wire [15:0]   lat     = ucnt - tq_head[15:0];

    always @(posedge uclk or negedge urst_n) begin
        if (!urst_n) begin
            rd_second <= 1'b0;
            tq_w <= 5'd0; tq_r <= 5'd0; tq_push_q <= 1'b0; tq_wd_q <= {TW{1'b0}}; tq_n <= 5'd0;
            umode_s1 <= 32'd0; umode_s2 <= 32'd0; wgap <= 6'd63; rgap <= 6'd63;
            rd_row   <= {RB{1'b0}};
            rd_line  <= {(BB-1){1'b0}};
            cmd_ready_q <= 1'b0; wr_rdy_q <= 1'b0; bist_tgl_q <= 1'b0;
            v_n <= 4'd0; v_age <= 4'd0; v_pri <= 1'b0; who <= 32'd0; who_w <= 5'd0; who_r <= 5'd0; who_hd <= 1'b0;
            ucnt <= 16'd0;
            uc_rdcmd <= 32'd0; uc_latsum <= 32'd0; uc_wrcmd <= 32'd0; uc_rdval <= 32'd0;
        end else begin
            ucnt <= ucnt + 16'd1;
            cmd_ready_q <= cmd_ready;
            wr_rdy_q    <= wr_data_rdy;
            bist_tgl_q  <= umode_s2[24];
            umode_s1 <= mode; umode_s2 <= umode_s1;
            if (issue_wr)                wgap <= 6'd0;
            else if (wgap != 6'd63)      wgap <= wgap + 6'd1;
            if (issue_rd)                rd_row <= c_row;
            if (issue_rd)                rd_line <= c_blk[BB-1:1];
            if (issue_rd)                rgap <= 6'd0;
            else if (rgap != 6'd63)      rgap <= rgap + 6'd1;
            tq_push_q <= issue_rd;
            if (issue_rd) begin
                rd_second <= ~rd_second;
                tq_wd_q   <= {c_blk[BB-1:1], c_mask[EB-1:0], c_mask[EB +: GB], c_half, ucnt};
            end
            if (tq_push_q) tq_w <= tq_w + 5'd1;
            if (br_valid) tq_r <= tq_r + 5'd1;
            tq_n <= tq_n + {4'd0, tq_push_q} - {4'd0, br_valid};

            // video reads in flight and the issue-order FIFO
            v_n <= v_n + {3'd0, issue_v} - {3'd0, v_rvalid};
            if (!v_req || issue_v)  v_age <= 4'd0;
            else if (v_age != VAGE) v_age <= v_age + 4'd1;
            v_pri <= v_req & ~issue_v & (v_age >= VAGE - 1) & (v_n < VMAX - 1);
            if (issue_rd | issue_v) begin
                who[who_w] <= issue_v;
                who_w      <= who_w + 5'd1;
            end
            if (rv_any) who_r <= who_r + 5'd1;
            who_hd <= who[who_r + {4'd0, rv_any}];

            if (u_clr) begin
                uc_rdcmd <= 32'd0; uc_latsum <= 32'd0; uc_wrcmd <= 32'd0; uc_rdval <= 32'd0;
            end else if (u_en) begin
                if (issue_rd) uc_rdcmd <= uc_rdcmd + 32'd1;
                if (issue_wr) uc_wrcmd <= uc_wrcmd + 32'd1;
                if (br_valid) begin
                    uc_rdval  <= uc_rdval + 32'd1;
                    uc_latsum <= uc_latsum + {16'd0, lat};
                end
            end
        end
    end

    // tag FIFO entries: no reset (tq_push_q is low in reset), which keeps the
    // high-fanout urst_n off their write enables
    always @(posedge uclk)
        if (tq_push_q) tq[tq_w[3:0]] <= tq_wd_q;

    // return FIFO: data + the tag of the read it answers (MC returns in order)
    wire rf_full;
    ddr_async_fifo #(.W(RW), .AW(4), .WREG(1)) u_ret_fifo (
        .wclk(uclk), .wrst_n(urst_n), .wr(br_valid),
        .wdata({tq_head[TW-1 -: LB+EB+GB+1], rd_data}), .full(rf_full), .wlevel(),
        .rclk(hclk), .rrst_n(hrst_n), .rd(rf_pop), .rdata(rf_rdata), .empty(rf_empty)
    );

    assign perf_cnt = {bist_res, uc_rdval, uc_wrcmd, pc_tagmis, uc_rdcmd,
                       pc_wr, pc_pf, pc_dem, pc_hit0};

`ifdef FORMAL
    // ---- safety properties of the AHB (hclk) side: formal/bridge_ahb.sby ----
    // The clock-crossing FIFOs and the BIST are stubbed (formal/stubs.v): FIFO
    // outputs are free, so these hold for any DDR-side behaviour; the command
    // FIFO stub reports its true occupancy as cf_wlevel (the real level can
    // only be higher).  The AHB inputs are unconstrained.
    reg f_past = 1'b0;
    integer f_i, f_j;
    initial assume(!hresetn);
    always @(posedge hclk) begin
        f_past <= 1'b1;
        if (f_past) assume(hresetn);
    end
    always @(posedge hclk) if (f_past && hresetn) begin
        // one DDR command source per cycle (the FIFO write mux has priorities)
        assert(!(push_wr && push_dem));
        assert(!(push_wr && push_pf));
        assert(!(push_dem && push_pf));
        // no command FIFO overflow (cfq_push writes the entry pushed last cycle)
        assert(!(cfq_push && cf_wlevel == 5'd16));     // stub: level = occupancy
        // posted writes: the queue never overflows
        assert(wq_n <= 3'd4);
        assert(!(wr_take && wq_n == 3'd4));
        // ordering: a DDR read is queued only after every earlier write
        if (push_dem || push_pf) assert(!wb_valid && wq_n == 3'd0 && !wh_v);
        // ~wb_valid in can_alloc is redundant (the equivalent mutant)
        assert(!(rd_wait && sp_st == SP_LOOK && !lk_tag && vic_ok_q && !alloc_cool
                 && !cf_afull && !wq_busy && !push_wr && wb_valid));
        // AHB: OKAY only; HREADY low only inside a data phase
        assert(hresp == 2'b00);
        if (!hready_q) assert(aq_v);
        // AHB: IDLE / BUSY sampled -> zero-wait OKAY data phase
        if ($past(hready_q) && !$past(htrans[1])) assert(hready_q);
        // a line is never in two entries (lookups rely on a one-hot tag_hit)
        for (f_i = 0; f_i < NBUF; f_i = f_i + 1)
            for (f_j = f_i + 1; f_j < NBUF; f_j = f_j + 1)
                assert(!(ent_alloc[f_i] && ent_alloc[f_j] && ent_tag[f_i] == ent_tag[f_j]));
        // allocations never take an entry whose data is still in flight
        if (push_dem || push_pf) assert(!pending_f(ent_alloc[vic_q], ent_hv[vic_q]));
        // read data comes only from valid halves of the right line
        if (pred_take) assert(cl_v && cl_hv[nb_beat[1]]);
        if (dl_cl)     assert(cl_v && cl_line == aq_line && cl_hv[aq_half]);
        if (dl_ent)    assert(ent_alloc[lk_idx] && ent_tag[lk_idx] == aq_line
                              && ent_hv[lk_idx][aq_half]);
    end
`endif
endmodule
`default_nettype wire
