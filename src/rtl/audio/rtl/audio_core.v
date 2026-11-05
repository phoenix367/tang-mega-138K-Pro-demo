`default_nettype none
//============================================================================
// audio_core.v -- stereo audio output for the Tang Mega 138K Pro Dock's
// PT8211 DAC (16-bit, LSB-justified serial format; BCK / WS / DIN).
//
//   CPU --EXTS--> audio_csr (registers) --DATA writes--> frame FIFO
//                                           2048 x 32 bit BSRAM, one clock
//                                                        |
//   DAC <-- audio_out (NCO bit clock, serialiser, CRC) <-- head register
//
// The FIFO is filled by the CPU, one {R, L} frame per 32-bit DATA write with the
// level-type interrupt (level < THRESH) asking for more, or by the DMA fetch
// engine (CTRL[6]) from a ring in DRAM.  The whole core runs
// on the EXTS bus clock; the DAC bit clock is derived from it by a phase
// accumulator, so the sample rate is programmable and the outputs are
// ordinary registered I/O.  See audio/README.md.
//============================================================================
module audio_core (
    input  wire         hclk,
    input  wire         hresetn,
    // AHB-lite slave: registers
    input  wire [31:0]  s_haddr,
    input  wire [1:0]   s_htrans,
    input  wire         s_hwrite,
    input  wire         s_hsel,
    input  wire         s_hready_in,
    input  wire [31:0]  s_hwdata,
    output wire [31:0]  s_hrdata,
    output wire         s_hready,
    output wire         s_hresp,
    // interrupt (level)
    output reg          irq,
    // DAC
    output wire         i2s_bck,
    output wire         i2s_ws,
    output wire         i2s_din,
    // headphone amplifier enable (CTRL[5], resets to 1)
    output wire         pa_en,
    // AHB-lite master (64-bit, read only): DMA fetch from the ring buffer
    output wire         m_busy,
    output wire [31:0]  m_haddr,
    output wire [1:0]   m_htrans,
    output wire         m_hwrite,
    output wire [2:0]   m_hsize,
    output wire [2:0]   m_hburst,
    output wire [63:0]  m_hwdata,
    input  wire [63:0]  m_hrdata,
    input  wire         m_hready,
    input  wire         m_hresp
);
    localparam AW = 11;                       // 2048 frames

    wire        enable, irq_en, fifo_rst, lr_swap, stop_empty, enable_clr, data_wr, dma_en;
    wire [15:0] thresh, dma_fill;
    wire [7:0]  dma_maxbeats;
    wire [31:0] rate, data, underruns, frames, crc;
    wire [31:0] dma_addr, dma_size, dma_period, dma_limit;
    wire [1:0]  dma_irq_clr;
    reg  [31:0] overruns;
    // DMA engine state (declared early: the FIFO write mux uses dma_push)
    reg         dma_push;
    reg  [31:0] dma_frame;
    reg  [31:0] dma_fetch;          // bytes fetched (free running)
    reg  [1:0]  dma_irq_st;

    // ---- FIFO: RAM + first-word-fall-through head register --------------
    reg  [AW:0] wr_ptr, rd_ptr;
    wire [AW:0] count    = wr_ptr - rd_ptr;       // frames in the RAM
    wire        ram_empty = (count == 0);
    reg         head_valid, rd_pending;
    // level = frames in the core: RAM + one in flight to the head + head
    wire [15:0] level    = {{(15-AW){1'b0}}, count} + {15'b0, head_valid} + {15'b0, rd_pending};
    wire        full     = level[AW];               // == 2048
    // frames come from the CPU (DATA register) in PIO mode, from the DMA engine in DMA mode
    wire        fifo_wr  = dma_en ? dma_push : data_wr;
    wire [31:0] fifo_d   = dma_en ? dma_frame : data;
    wire        wr_ok    = fifo_wr && !full;
    reg  [31:0] head;
    wire [31:0] ram_q;
    wire        pop;
    wire        rd_en = !head_valid && !rd_pending && !ram_empty && !fifo_rst;

    // simple dual-port RAM, synchronous read (BSRAM); no init loop, which
    // GowinSyn refuses above 2000 iterations
    reg [31:0] ram [0:(1 << AW) - 1];
    reg [31:0] ram_q_r;
    always @(posedge hclk) begin
        if (wr_ok) ram[wr_ptr[AW-1:0]] <= fifo_d;
        if (rd_en) ram_q_r <= ram[rd_ptr[AW-1:0]];
    end
    assign ram_q = ram_q_r;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            wr_ptr <= 0; rd_ptr <= 0; head_valid <= 0; rd_pending <= 0; head <= 0;
            overruns <= 0; irq <= 0;
        end else begin
            if (wr_ok) wr_ptr <= wr_ptr + 1'b1;
            if (fifo_wr && full) overruns <= overruns + 1;
            if (rd_en) begin rd_ptr <= rd_ptr + 1'b1; rd_pending <= 1'b1; end
            if (rd_pending) begin head <= ram_q; head_valid <= 1'b1; rd_pending <= 1'b0; end
            if (pop) head_valid <= 1'b0;
            if (fifo_rst) begin
                wr_ptr <= 0; rd_ptr <= 0; head_valid <= 0; rd_pending <= 0; overruns <= 0;
            end
            irq <= irq_en & (irq_cond | (dma_en & |dma_irq_st));   // DMA: period/error + FIFO level (THRESH=1 -> empty)
        end
    end

    wire        irq_cond = (level < thresh);

    // ---- DMA fetch engine --------------------------------------------------
    // Keeps the FIFO above DMA_FILL frames with 64-bit reads (2 frames per
    // beat) from the ring, never past DMA_LIMIT (bytes committed by the
    // driver) and never across the ring end; a command is at most
    // DMA_MAXBEATS beats.  Every beat delivers two frames: the first is pushed
    // when it arrives, the second one cycle later (reads are >= 2 cycles apart).
    wire        dm_ready, dm_done, dm_err, dm_wreq, dm_rvalid;
    wire [63:0] dm_rdata;
    reg         dm_valid;
    reg  [31:0] dm_addr;
    reg  [15:0] dm_len;             // beats of the current command
    reg  [31:0] dma_off;            // ring offset of the next fetch (bytes)
    reg  [31:0] period_acc;
    reg  [12:0] inflight;           // frames of the command in progress
    reg         hold_v;
    reg  [31:0] hold_frame;
    // odd frame counts: DMA_LIMIT is a multiple of 4, so a commit can end in
    // the middle of a beat.  Then the beat is read once for its first frame
    // (half_pend set, ring offset kept) and again, when more is committed,
    // for its second frame.  cmd_mode: 0 full beats, 1 first frame only,
    // 2 second frame only.
    reg  [1:0]  cmd_mode;
    reg         half_pend;
    // The command size is computed in two registered stages (the single-cycle
    // version was the design's longest path: FIFO pointers -> level -> room ->
    // three 32-bit compares -> dm_valid, 23 logic levels at 50 MHz).  The
    // staged values lag their inputs by two cycles, so `stale` blocks the
    // issue for three cycles after anything that moves them abruptly (a
    // completed command, a FIFO reset, DMA disabled); in between, the inputs
    // only drift the safe way (LIMIT grows, the FIFO drains).
    // stage 1: differences
    reg  [31:0] avail_r;            // dma_limit - dma_fetch: committed, not yet fetched (signed)
    reg  [31:0] to_end_r;           // dma_size - dma_off: bytes to the ring end
    reg  [15:0] room_r;             // dma_fill - (level + inflight), floored at 0
    wire [15:0] occ    = level + {3'b0, inflight};          // frames present or arriving
    // stage 2: beats = min(maxbeats, avail/8, to_end/8, room/2), each term saturated at 256
    wire [8:0]  b_avail = (avail_r[31] || half_pend) ? 9'd0 : (|avail_r[30:11]) ? 9'd256 : {1'b0, avail_r[10:3]};
    wire [8:0]  b_end   = (|to_end_r[31:11]) ? 9'd256 : {1'b0, to_end_r[10:3]};
    wire [8:0]  b_room  = (|room_r[15:9])    ? 9'd256 : {1'b0, room_r[8:1]};
    wire [8:0]  b_min1  = (b_avail < b_end)  ? b_avail : b_end;
    wire [8:0]  b_min2  = (b_min1 < b_room)  ? b_min1  : b_room;
    wire [8:0]  b_min3  = (b_min2 < {1'b0, dma_maxbeats}) ? b_min2 : {1'b0, dma_maxbeats};
    reg  [7:0]  b_beats;            // registered stage-2 result
    reg         one_frame;          // exactly one frame committed
    reg         half_more;          // something committed (second half of a split beat)
    reg         room_nz;
    reg  [1:0]  stale;
    always @(posedge hclk) begin
        avail_r   <= dma_limit - dma_fetch;
        to_end_r  <= dma_size - dma_off;
        room_r    <= (occ < dma_fill) ? (dma_fill - occ) : 16'd0;
        b_beats   <= b_min3[7:0];
        one_frame <= (avail_r == 32'd4);
        half_more <= !avail_r[31] && (avail_r != 32'd0);
        room_nz   <= (room_r != 16'd0);
    end
    wire [31:0] cons = (cmd_mode == 2'd0) ? {dm_len, 3'b000} : 32'd4;   // bytes consumed by the command
    wire [31:0] adv  = (cmd_mode == 2'd0) ? {dm_len, 3'b000} : 32'd8;   // ring advance when the beat is finished

    ahb_master #(.ADDR_W(32), .DATA_W(64), .MAX_BURST(16)) u_dma (
        .hclk(hclk), .hresetn(hresetn),
        .cmd_valid(dm_valid), .cmd_ready(dm_ready), .cmd_addr(dm_addr), .cmd_len(dm_len),
        .cmd_wr(1'b0), .cmd_done(dm_done), .cmd_err(dm_err), .busy(m_busy),
        .w_req(dm_wreq), .w_data(64'd0), .r_valid(dm_rvalid), .r_data(dm_rdata),
        .haddr(m_haddr), .htrans(m_htrans), .hwrite(m_hwrite), .hsize(m_hsize), .hburst(m_hburst),
        .hwdata(m_hwdata), .hrdata(m_hrdata), .hready(m_hready), .hresp(m_hresp)
    );

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            dm_valid <= 1'b0; dm_addr <= 32'd0; dm_len <= 16'd0; dma_off <= 32'd0; dma_fetch <= 32'd0;
            period_acc <= 32'd0; inflight <= 13'd0; hold_v <= 1'b0; hold_frame <= 32'd0;
            dma_push <= 1'b0; dma_frame <= 32'd0; dma_irq_st <= 2'b00; cmd_mode <= 2'd0; half_pend <= 1'b0;
            stale <= 2'd3;
        end else begin
            dma_push <= 1'b0;
            if (dm_done || fifo_rst || !dma_en) stale <= 2'd3;
            else if (stale != 2'd0)             stale <= stale - 2'd1;
            dma_irq_st <= dma_irq_st & ~dma_irq_clr;        // W1C
            // data: two frames per beat
            if (hold_v) begin hold_v <= 1'b0; dma_push <= dma_en; dma_frame <= hold_frame; end
            if (dm_rvalid) begin
                dma_push  <= dma_en;
                dma_frame <= (cmd_mode == 2'd2) ? dm_rdata[63:32] : dm_rdata[31:0];
                if (cmd_mode == 2'd0) begin hold_v <= 1'b1; hold_frame <= dm_rdata[63:32]; end
            end
            // command issue / completion
            if (dm_valid && dm_ready) dm_valid <= 1'b0;
            if (dm_done) begin
                inflight <= 13'd0;
                dma_fetch <= dma_fetch + cons;
                if (cmd_mode == 2'd1) half_pend <= 1'b1;
                else begin
                    half_pend <= 1'b0;
                    dma_off <= (dma_off + adv == dma_size) ? 32'd0 : dma_off + adv;
                end
                if (dm_err) dma_irq_st[1] <= 1'b1;
                if (dma_period != 32'd0) begin
                    if (period_acc + cons >= dma_period) begin
                        period_acc <= period_acc + cons - dma_period;
                        dma_irq_st[0] <= 1'b1;
                    end else
                        period_acc <= period_acc + cons;
                end
            end else if (dma_en && !dm_valid && dm_ready && !m_busy && dma_size != 32'd0 && stale == 2'd0) begin
                if (half_pend ? (half_more && room_nz) : (b_beats != 8'd0 || (one_frame && room_nz))) begin
                    dm_valid <= 1'b1;
                    dm_addr  <= dma_addr + dma_off;
                    if (half_pend || b_beats == 8'd0) begin       // single-frame command
                        cmd_mode <= half_pend ? 2'd2 : 2'd1;
                        dm_len   <= 16'd1;
                        inflight <= 13'd1;
                    end else begin
                        cmd_mode <= 2'd0;
                        dm_len   <= {8'd0, b_beats};
                        inflight <= {4'd0, b_beats, 1'b0};
                    end
                end
            end
            if (fifo_rst) begin
                dma_fetch <= 32'd0; dma_off <= 32'd0; period_acc <= 32'd0; dma_irq_st <= 2'b00; half_pend <= 1'b0;
            end
        end
    end

    audio_csr u_csr (
        .hclk(hclk), .hresetn(hresetn),
        .haddr(s_haddr), .htrans(s_htrans), .hwrite(s_hwrite), .hsel(s_hsel),
        .hready_in(s_hready_in), .hwdata(s_hwdata),
        .hrdata(s_hrdata), .hready(s_hready), .hresp(s_hresp),
        .enable(enable), .irq_en(irq_en), .fifo_rst(fifo_rst), .lr_swap(lr_swap),
        .stop_empty(stop_empty), .amp_en(pa_en), .enable_clr(enable_clr), .thresh(thresh), .rate(rate), .data_wr(data_wr), .data(data),
        .dma_en(dma_en), .dma_addr(dma_addr), .dma_size(dma_size), .dma_period(dma_period), .dma_limit(dma_limit),
        .dma_fill(dma_fill), .dma_maxbeats(dma_maxbeats), .dma_fetch(dma_fetch), .dma_irq_st(dma_irq_st), .dma_irq_clr(dma_irq_clr),
        .level(level), .irq_cond(irq_cond), .full(full), .depth(16'd1 << AW),
        .underruns(underruns), .overruns(overruns), .frames(frames), .crc(crc)
    );

    audio_out u_out (
        .clk(hclk), .rstn(hresetn),
        .enable(enable), .lr_swap(lr_swap), .stop_empty(stop_empty), .enable_clr(enable_clr),
        .rate(rate), .clear(fifo_rst),
        .head_valid(head_valid), .head(head), .pop(pop),
        .frames(frames), .underruns(underruns), .crc(crc),
        .bck(i2s_bck), .ws(i2s_ws), .din(i2s_din)
    );
endmodule
`default_nettype wire
