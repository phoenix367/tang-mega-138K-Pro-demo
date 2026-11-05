`default_nettype none
//============================================================================
// sdhost_core.v -- native SD host (1/4-bit SD bus) with DMA.
//
// AHB-lite slave on EXTS (CPU base 0xE8020000, HADDR[17]) + a 64-bit AHB
// master (ahb_master.v, through the EXTM arbiter) that moves data blocks
// between a 1 KB FIFO and DDR.  All logic runs on the 50 MHz bus clock; the
// SD clock is a divided copy driven from a register (SDCLK = 50 MHz /
// (2 * (DIV + 1)): DIV 0 = 25 MHz default speed, DIV 62 = 397 kHz for
// identification).  Host outputs change on the SDCLK falling edge; inputs
// are sampled one bus clock after the rising edge by default, or at the edge
// with CTRL[16] (see the register list below).
//
// Command engine: 48-bit command with CRC7, responses of 48 bits (R1/R1b/
// R3/R6/R7) or 136 bits (R2), optional CRC7 / index check, response
// timeout (80 clocks), R1b busy wait on DAT0.
// Data engine: BLKCNT blocks of BLKSIZE bytes (multiple of 8, <= 512) over
// 1 or 4 lanes with CRC16 per lane; reads capture start bit, data, CRC and
// end bit; writes send start bit, data, CRC, end bit, then check the card's
// CRC status token and wait for busy to clear.  Data goes through a
// 128 x 64-bit FIFO; the DMA master writes (read) or fetches (write) one
// block (BLKSIZE/8 beats) at a time from DMA_ADDR + n*BLKSIZE.
//
// Register map (byte offset, 32-bit accesses):
//   0x00 CTRL    rw  [0] SDCLK enable  [1] 4-bit bus  [2] soft reset (self-
//                    clearing: aborts engines, flushes FIFO)  [15:8] DIV
//                    [16] sample inputs AT the SD rising edge (reset 0 = one
//                    bus clock, 20 ns, after it: the card's output delay plus
//                    the Dock's 22 R and the FPGA I/O path exceed the 40 ns
//                    period budget at 25 MHz when sampled on the edge)
//   0x04 ARG     rw  command argument
//   0x08 CMD     rw  [5:0] index  [7:6] response: 0 none, 1 48-bit, 2 136-bit
//                    [8] check response CRC7  [9] check response index
//                    [10] R1b: wait busy after the response  [11] data present
//                    [12] data direction 1 = write  -- writing starts the command
//   0x0C..0x18 RESP0..3  ro  48-bit: RESP0 = payload bits [39:8]
//                    136-bit: RESP0 = bits [127:96] ... RESP3 = bits [31:0]
//   0x1C BLK     rw  [11:0] block size (bytes, multiple of 8)  [31:16] block count
//   0x20 DMA     rw  DMA buffer address (8-byte aligned)
//   0x24 STATUS  rw  [0] command busy  [1] data busy  [2] card inserted
//                    [3] DAT0 level  [4] CMD level  [7:5] 0
//                    sticky, write 1 to clear:
//                    [8] command done  [9] data done  [10] response timeout
//                    [11] response CRC error  [12] response index error
//                    [13] data timeout  [14] data CRC error  [15] data end-bit
//                    error  [16] write CRC-status error  [17] DMA bus error
//                    [18] FIFO overrun/underrun
//   0x28 INT_EN  rw  interrupt enable mask for STATUS[18:8]
//   0x2C TIMEOUT rw  [23:0] data start-bit / busy timeout in SD clocks
//   0x30 ID      ro  0x53444843 ("SDHC")
//   0x34 DBG     ro  engine states
//============================================================================
module sdhost_core #(
    parameter integer BUS_MHZ = 50
) (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB-lite slave
    input  wire [31:0] s_haddr,
    input  wire [1:0]  s_htrans,
    input  wire        s_hwrite,
    input  wire        s_hsel,
    input  wire        s_hready_in,
    input  wire [31:0] s_hwdata,
    output wire [31:0] s_hrdata,
    output wire        s_hready,
    output wire        s_hresp,
    // AHB-lite master (64-bit) for the DMA
    output wire        m_busy,
    output wire [31:0] m_haddr,
    output wire [1:0]  m_htrans,
    output wire        m_hwrite,
    output wire [2:0]  m_hsize,
    output wire [2:0]  m_hburst,
    output wire [63:0] m_hwdata,
    input  wire [63:0] m_hrdata,
    input  wire        m_hready,
    input  wire        m_hresp,
    // SD bus
    output reg         sd_clk,
    output reg         cmd_o,
    output reg         cmd_oe,
    input  wire        cmd_i,
    output reg  [3:0]  dat_o,
    output reg         dat_oe,          // DAT0
    output wire        dat_oe_hi,       // DAT3..1 (only in 4-bit mode)
    input  wire [3:0]  dat_i,
    input  wire        sd_det_n,        // 0 = card inserted
    output wire        irq
);
    assign s_hready = 1'b1;
    assign s_hresp  = 1'b0;
    assign dat_oe_hi = dat_oe & bus4;

    // ------------------------------------------------------------------
    // registers
    // ------------------------------------------------------------------
    reg        a_sel, a_wr;
    reg [5:0]  a_off;
    wire       a_active = s_hsel && s_hready_in && s_htrans[1];
    reg        clk_en, bus4, soft_rst, smp_early;
    reg [7:0]  div;
    reg [31:0] arg;
    reg [12:0] cmd_r;
    reg [31:0] resp [0:3];
    reg [11:0] blksize;
    reg [15:0] blkcnt;
    reg [31:0] dma_addr;
    reg [18:8] st_sticky;
    reg [18:8] int_en;
    reg [23:0] tmo;
    reg        cmd_start;
    reg [2:0]  det_sync;
    wire       card_in = ~det_sync[2];
    reg        cmd_busy, dat_busy;
    reg [31:0] rd_reg;
    wire [18:8] st_set;                 // pulses from the engines
    wire [2:0] cst, dst;                // engine states (DBG)
    reg  [7:0]  fifo_wp, fifo_rp;
    wire [7:0]  fifo_cnt = fifo_wp - fifo_rp;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_sel <= 1'b0; a_wr <= 1'b0; a_off <= 6'd0;
            clk_en <= 1'b0; bus4 <= 1'b0; soft_rst <= 1'b0; smp_early <= 1'b0; div <= 8'd62;
            arg <= 32'd0; cmd_r <= 13'd0; blksize <= 12'd512; blkcnt <= 16'd1; dma_addr <= 32'd0;
            st_sticky <= 11'd0; int_en <= 11'd0; tmo <= 24'hFFFFFF; cmd_start <= 1'b0;
            det_sync <= 3'b111; rd_reg <= 32'd0;
        end else begin
            det_sync <= {det_sync[1:0], sd_det_n};
            cmd_start <= 1'b0;
            soft_rst <= 1'b0;
            a_sel <= a_active; a_wr <= s_hwrite; a_off <= s_haddr[7:2];
            case (s_haddr[7:2])
                6'h00: rd_reg <= {15'd0, smp_early, div, 5'd0, 1'b0, bus4, clk_en};
                6'h01: rd_reg <= arg;
                6'h02: rd_reg <= {19'd0, cmd_r};
                6'h03: rd_reg <= resp[0];
                6'h04: rd_reg <= resp[1];
                6'h05: rd_reg <= resp[2];
                6'h06: rd_reg <= resp[3];
                6'h07: rd_reg <= {blkcnt, 4'd0, blksize};
                6'h08: rd_reg <= dma_addr;
                6'h09: rd_reg <= {13'd0, st_sticky, 3'd0, cmd_i, dat_i[0], card_in, dat_busy, cmd_busy};
                6'h0A: rd_reg <= {13'd0, int_en, 8'd0};
                6'h0B: rd_reg <= {8'd0, tmo};
                6'h0C: rd_reg <= 32'h5344_4843;
                6'h0D: rd_reg <= {16'd0, fifo_cnt, 2'd0, dst, 1'b0, cst};
                default: rd_reg <= 32'd0;
            endcase
            // sticky status: set by engines, cleared by writing 1
            st_sticky <= st_sticky | st_set;
            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00: begin clk_en <= s_hwdata[0]; bus4 <= s_hwdata[1]; soft_rst <= s_hwdata[2]; div <= s_hwdata[15:8]; smp_early <= s_hwdata[16]; end
                    6'h01: arg <= s_hwdata;
                    6'h02: begin cmd_r <= s_hwdata[12:0]; cmd_start <= ~cmd_busy & ~dat_busy; end
                    6'h07: begin blksize <= s_hwdata[11:0]; blkcnt <= s_hwdata[31:16]; end
                    6'h08: dma_addr <= s_hwdata;
                    6'h09: st_sticky <= (st_sticky | st_set) & ~s_hwdata[18:8];
                    6'h0A: int_en <= s_hwdata[18:8];
                    6'h0B: tmo <= s_hwdata[23:0];
                    default: ;
                endcase
            end
        end
    end
    assign s_hrdata = rd_reg;
    assign irq = |(st_sticky & int_en);

    wire [5:0] c_idx   = cmd_r[5:0];
    wire [1:0] c_rtype = cmd_r[7:6];
    wire       c_crc   = cmd_r[8];
    wire       c_ichk  = cmd_r[9];
    wire       c_busy  = cmd_r[10];
    wire       c_data  = cmd_r[11];
    wire       c_write = cmd_r[12];

    // ------------------------------------------------------------------
    // SD clock
    // ------------------------------------------------------------------
    reg [7:0] ccnt;
    wire tick = (ccnt == div);
    wire rise = clk_en && tick && !sd_clk;     // sd_clk goes high at the end of this cycle
    wire fall = clk_en && tick &&  sd_clk;
    reg  rise_d;
    wire samp = smp_early ? rise : rise_d;     // input sampling event
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin ccnt <= 8'd0; sd_clk <= 1'b0; rise_d <= 1'b0; end
        else begin
            rise_d <= rise;
            if (!clk_en) begin ccnt <= 8'd0; sd_clk <= 1'b0; end
            else if (tick) begin ccnt <= 8'd0; sd_clk <= ~sd_clk; end
            else ccnt <= ccnt + 8'd1;
        end
    end

    // ------------------------------------------------------------------
    // CRC helpers
    // ------------------------------------------------------------------
    function [6:0] crc7_bit(input [6:0] c, input b);
        reg x;
        begin
            x = c[6] ^ b;
            crc7_bit = {c[5:3], c[2] ^ x, c[1:0], x};
        end
    endfunction
    function [15:0] crc16_bit(input [15:0] c, input b);
        reg x;
        begin
            x = c[15] ^ b;
            crc16_bit = {c[14:12], c[11] ^ x, c[10:5], c[4] ^ x, c[3:0], x};
        end
    endfunction

    // ------------------------------------------------------------------
    // command engine
    // ------------------------------------------------------------------
    localparam [2:0] C_IDLE = 3'd0, C_SEND = 3'd1, C_WAIT = 3'd2, C_RECV = 3'd3, C_BUSY = 3'd4, C_END = 3'd5;
    reg [2:0]   cs;
    reg [39:0]  csh;            // command bits to send (after the CRC is appended)
    reg [6:0]   ccrc;
    reg [5:0]   cbit;           // bits sent / received
    reg [7:0]   cwait;
    reg [135:0] rsh;            // response shift register
    reg [7:0]   rlen;           // bits to receive after the start bit
    reg [6:0]   rcrc;
    reg [23:0]  bto;
    reg         c_done_p, c_tmo_p, c_crc_p, c_idx_p;
    assign cst = cs;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            cs <= C_IDLE; cmd_busy <= 1'b0; cmd_o <= 1'b1; cmd_oe <= 1'b0; csh <= 40'd0; ccrc <= 7'd0;
            cbit <= 6'd0; cwait <= 8'd0; rsh <= 136'd0; rlen <= 8'd0; rcrc <= 7'd0; bto <= 24'd0;
            c_done_p <= 1'b0; c_tmo_p <= 1'b0; c_crc_p <= 1'b0; c_idx_p <= 1'b0;
            resp[0] <= 32'd0; resp[1] <= 32'd0; resp[2] <= 32'd0; resp[3] <= 32'd0;
        end else begin
            c_done_p <= 1'b0; c_tmo_p <= 1'b0; c_crc_p <= 1'b0; c_idx_p <= 1'b0;
            if (soft_rst) begin
                cs <= C_IDLE; cmd_busy <= 1'b0; cmd_oe <= 1'b0; cmd_o <= 1'b1;
            end else case (cs)
                C_IDLE: begin
                    cmd_oe <= 1'b0; cmd_o <= 1'b1;
                    if (cmd_start) begin
                        cmd_busy <= 1'b1;
                        csh <= {2'b01, c_idx, arg};
                        ccrc <= 7'd0;
                        cbit <= 6'd0;
                        cs <= C_SEND;
                        rlen <= (c_rtype == 2'd2) ? 8'd135 : 8'd47;
                    end
                end
                // 48 bits out on falling edges: 40 bits from csh (CRC computed
                // on the fly), then the 7 CRC bits and the end bit
                C_SEND: if (fall) begin
                    cmd_oe <= 1'b1;
                    if (cbit < 6'd40) begin
                        cmd_o <= csh[39];
                        ccrc <= crc7_bit(ccrc, csh[39]);
                        csh <= {csh[38:0], 1'b0};
                    end else if (cbit < 6'd47) begin
                        cmd_o <= ccrc[6];
                        ccrc <= {ccrc[5:0], 1'b0};
                    end else
                        cmd_o <= 1'b1;                       // end bit
                    cbit <= cbit + 6'd1;
                    if (cbit == 6'd47) begin
                        cs <= (c_rtype == 2'd0) ? C_END : C_WAIT;
                        cwait <= 8'd0;
                    end
                end
                // release the line (one more falling edge), then wait for the
                // start bit on rising edges (Ncr <= 64 clocks)
                C_WAIT: begin
                    if (fall) cmd_oe <= 1'b0;
                    if (samp && !cmd_oe) begin
                        if (cmd_i == 1'b0) begin
                            cs <= C_RECV; cbit <= 6'd0; rsh <= 136'd0; rcrc <= 7'd0;
                            cwait <= 8'd0;
                        end else if (cwait == 8'd80) begin
                            c_tmo_p <= 1'b1; cs <= C_END;
                        end else
                            cwait <= cwait + 8'd1;
                    end
                end
                // remaining bits of the response (the start bit is not stored)
                C_RECV: if (samp) begin
                    rsh <= {rsh[134:0], cmd_i};
                    // CRC7 over transmission bit .. payload (48-bit: 39 bits after
                    // the start bit; 136-bit responses carry the CRC inside)
                    if (cwait < 8'd39) rcrc <= crc7_bit(rcrc, cmd_i);
                    cwait <= cwait + 8'd1;
                    if (cwait == rlen - 8'd1) cs <= C_END;   // bookkeeping below
                end
                C_BUSY: if (samp) begin
                    if (dat_i[0]) cs <= C_END;
                    else if (bto == 24'd0) begin c_tmo_p <= 1'b1; cs <= C_END; end
                    else bto <= bto - 24'd1;
                end
                C_END: begin
                    cmd_oe <= 1'b0;
                    cmd_busy <= 1'b0;
                    c_done_p <= 1'b1;
                    cs <= C_IDLE;
                end
                default: cs <= C_IDLE;
            endcase
            // response bookkeeping on the last received bit
            if (cs == C_RECV && samp && cwait == rlen - 8'd1) begin
                if (c_rtype == 2'd1) begin
                    // full 47 bits now = {rsh[45:0], cmd_i}: tx(1) idx(6) payload(32) crc(7) end(1)
                    resp[0] <= rsh[38:7];
                    if (c_crc && rcrc != rsh[6:0]) c_crc_p <= 1'b1;
                    if (c_ichk && rsh[44:39] != c_idx) c_idx_p <= 1'b1;
                    if (c_busy && !c_crc_p) begin cs <= C_BUSY; bto <= tmo; end
                end else begin
                    // 135 bits = {tx(1), 111111, cid/csd[127:1]} + end bit now
                    resp[0] <= rsh[126:95];
                    resp[1] <= rsh[94:63];
                    resp[2] <= rsh[62:31];
                    resp[3] <= {rsh[30:0], cmd_i};
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // FIFO (128 x 64) between the data engine and the DMA master
    // ------------------------------------------------------------------
    // Synchronous-read RAM (BSRAM) with the head always presented: the read
    // address is the pointer after this cycle's pop, so the next word is on
    // f_q in the cycle after the pop, exactly as the earlier flop array was.
    // (That array -- 8k flops behind a 128:1 mux on a 4099-fanout pointer --
    // was the second-longest path of the 50 MHz domain.)  A word written to
    // the location being read is taken from the bypass register instead.
    reg [63:0] fifo [0:127];
    reg        f_push, eng_pop;
    wire       f_pop;                   // combinational: the DMA pops as it consumes
    reg [63:0] f_wdata;
    wire [6:0] f_ra = f_pop ? fifo_rp[6:0] + 7'd1 : fifo_rp[6:0];
    reg [63:0] f_q, f_byp;
    reg        f_byp_v;
    always @(posedge hclk) begin
        if (f_push) fifo[fifo_wp[6:0]] <= f_wdata;
        f_q     <= fifo[f_ra];
        f_byp_v <= f_push && (fifo_wp[6:0] == f_ra);
        f_byp   <= f_wdata;
    end
    wire [63:0] f_rdata = f_byp_v ? f_byp : f_q;
    reg        f_err;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin fifo_wp <= 8'd0; fifo_rp <= 8'd0; f_err <= 1'b0; end
        else if (soft_rst || (cmd_start && c_data)) begin fifo_wp <= 8'd0; fifo_rp <= 8'd0; f_err <= 1'b0; end
        else begin
            f_err <= 1'b0;
            if (f_push) begin
                if (fifo_cnt == 8'd128) f_err <= 1'b1; else fifo_wp <= fifo_wp + 8'd1;
            end
            if (f_pop) begin
                if (fifo_cnt == 8'd0) f_err <= 1'b1; else fifo_rp <= fifo_rp + 8'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // DMA sequencing: one block per master command
    // ------------------------------------------------------------------
    wire        dm_ready, dm_done, dm_err, dm_busy, dm_wreq, dm_rvalid;
    wire [63:0] dm_rdata;
    reg         dm_valid;
    reg  [31:0] dm_addr;
    reg         dm_wr;
    reg  [15:0] dm_blk_done;      // blocks moved by the DMA
    reg  [15:0] dm_blk_fetch;     // blocks requested (writes: fetched from memory)
    wire [6:0]  blk_words = blksize[11:3];      // beats per block (blksize/8, 1..64)
    reg         d_active, d_write;
    reg  [15:0] blks_total;
    reg         dma_err_p;

    ahb_master #(.ADDR_W(32), .DATA_W(64), .MAX_BURST(16)) u_dma (
        .hclk(hclk), .hresetn(hresetn),
        .cmd_valid(dm_valid), .cmd_ready(dm_ready), .cmd_addr(dm_addr), .cmd_len({9'd0, blk_words}),
        .cmd_wr(dm_wr), .cmd_done(dm_done), .cmd_err(dm_err), .busy(dm_busy),
        .w_req(dm_wreq), .w_data(f_rdata), .r_valid(dm_rvalid), .r_data(dm_rdata),
        .haddr(m_haddr), .htrans(m_htrans), .hwrite(m_hwrite), .hsize(m_hsize), .hburst(m_hburst),
        .hwdata(m_hwdata), .hrdata(m_hrdata), .hready(m_hready), .hresp(m_hresp)
    );
    assign m_busy = dm_busy;

    // read side: the engine pushes words; when a block is complete in the FIFO
    // (fifo_cnt >= blk_words) the DMA writes it out.  Write side: the DMA
    // fetches a block whenever there is room and blocks remain.
    reg [15:0] eng_blk_done;      // blocks completed by the SD data engine
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            dm_valid <= 1'b0; dm_addr <= 32'd0; dm_wr <= 1'b0; dm_blk_done <= 16'd0; dm_blk_fetch <= 16'd0;
            dma_err_p <= 1'b0;
        end else begin
            dma_err_p <= 1'b0;
            if (soft_rst || (cmd_start && c_data)) begin
                dm_valid <= 1'b0; dm_blk_done <= 16'd0; dm_blk_fetch <= 16'd0;
                dm_addr <= dma_addr; dm_wr <= ~c_write;   // DMA writes memory on card reads
            end else begin
                if (dm_valid && dm_ready) dm_valid <= 1'b0;      // accepted
                if (dm_done) begin
                    dm_blk_done <= dm_blk_done + 16'd1;
                    dm_addr <= dm_addr + {20'd0, blksize};
                    if (dm_err) dma_err_p <= 1'b1;
                end
                if (d_active && !dm_valid && dm_ready && !dm_done) begin
                    if (!d_write) begin
                        // card read: a complete block waits in the FIFO
                        if (dm_blk_done < eng_blk_done && fifo_cnt >= {1'b0, blk_words})
                            dm_valid <= 1'b1;
                    end else begin
                        // card write: prefetch while there is room
                        if (dm_blk_fetch < blks_total && fifo_cnt + {1'b0, blk_words} <= 8'd128) begin
                            dm_valid <= 1'b1; dm_blk_fetch <= dm_blk_fetch + 16'd1;
                        end
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // data engine
    // ------------------------------------------------------------------
    localparam [2:0] D_IDLE = 3'd0, D_RWAIT = 3'd1, D_RDATA = 3'd2, D_RCRC = 3'd3,
                     D_WPREP = 3'd4, D_WDATA = 3'd5, D_WCRC = 3'd6, D_WSTAT = 3'd7;
    reg [2:0]   ds;
    assign dst = ds;
    reg [15:0]  blk_i;
    reg [12:0]  nib;            // nibble / bit counter within the block
    reg [15:0]  crc[0:3];       // per-lane CRC16
    reg [15:0]  rcrc16 [0:3];   // received CRC16
    reg [4:0]   ccnt16;
    reg [63:0]  wacc;           // word accumulator (reads) / word being sent (writes)
    reg [2:0]   bytei;          // byte within the word
    reg         hi;             // high nibble next
    reg [23:0]  dto;
    reg         d_done_p, d_tmo_p, d_crc_p, d_end_p, d_wst_p;
    reg [3:0]   wstat;
    reg [2:0]   wstat_n;
    reg         wait_resp;      // write: wait for the command response before data
    reg [2:0]   gap;
    // units per block: nibbles (4-bit) or bits (1-bit); blksize <= 512
    wire [12:0] nib_last  = bus4 ? ({1'b0, blksize} << 1) - 13'd1 : ({1'b0, blksize} << 3) - 13'd1;
    wire [3:0]  din = bus4 ? dat_i : {3'b000, dat_i[0]};

    // byte assembled from the data lanes (reads): 4-bit: two nibbles; 1-bit: eight bits
    reg [7:0]   rbyte;

    // the word to send (writes) comes from the FIFO head
    wire [63:0] wword = f_rdata;
    wire [7:0]  wbyte = wword[8 * bytei +: 8];
    wire [3:0]  wnib  = hi ? wbyte[7:4] : wbyte[3:0];
    wire        wbit  = wbyte[7 - nib[2:0]];

    integer l;
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            ds <= D_IDLE; dat_busy <= 1'b0; dat_o <= 4'hF; dat_oe <= 1'b0; blk_i <= 16'd0; nib <= 13'd0;
            for (l = 0; l < 4; l = l + 1) begin crc[l] <= 16'd0; rcrc16[l] <= 16'd0; end
            ccnt16 <= 5'd0; wacc <= 64'd0; bytei <= 3'd0; hi <= 1'b1; dto <= 24'd0;
            d_done_p <= 1'b0; d_tmo_p <= 1'b0; d_crc_p <= 1'b0; d_end_p <= 1'b0; d_wst_p <= 1'b0;
            wstat <= 4'd0; wstat_n <= 3'd0; wait_resp <= 1'b0; gap <= 3'd0;
            f_push <= 1'b0; eng_pop <= 1'b0; f_wdata <= 64'd0; rbyte <= 8'd0;
            d_active <= 1'b0; d_write <= 1'b0; blks_total <= 16'd0; eng_blk_done <= 16'd0;
        end else begin
            d_done_p <= 1'b0; d_tmo_p <= 1'b0; d_crc_p <= 1'b0; d_end_p <= 1'b0; d_wst_p <= 1'b0;
            f_push <= 1'b0; eng_pop <= 1'b0;
            // DMA read data (card writes) lands in the FIFO
            if (dm_rvalid) begin f_push <= 1'b1; f_wdata <= dm_rdata; end
            if (soft_rst) begin
                ds <= D_IDLE; dat_busy <= 1'b0; dat_oe <= 1'b0; d_active <= 1'b0;
            end else case (ds)
                D_IDLE: begin
                    dat_oe <= 1'b0; dat_o <= 4'hF;
                    if (cmd_start && c_data) begin
                        dat_busy <= 1'b1; d_active <= 1'b1; d_write <= c_write;
                        blks_total <= blkcnt; blk_i <= 16'd0; eng_blk_done <= 16'd0;
                        nib <= 13'd0; bytei <= 3'd0; hi <= 1'b1; dto <= tmo;
                        for (l = 0; l < 4; l = l + 1) crc[l] <= 16'd0;
                        wait_resp <= 1'b1; gap <= 3'd0;
                        ds <= c_write ? D_WPREP : D_RWAIT;
                    end else if (d_active && dm_blk_done == blks_total) begin
                        // all blocks moved by the DMA: transfer complete
                        d_active <= 1'b0; dat_busy <= 1'b0; d_done_p <= 1'b1;
                    end
                end
                // ---- read: start bit ----
                D_RWAIT: if (samp) begin
                    if (din[0] == 1'b0) begin
                        ds <= D_RDATA; nib <= 13'd0; bytei <= 3'd0; hi <= 1'b1;
                        for (l = 0; l < 4; l = l + 1) crc[l] <= 16'd0;
                    end else if (dto == 24'd0) begin
                        d_tmo_p <= 1'b1; ds <= D_IDLE; d_active <= 1'b0; dat_busy <= 1'b0;
                    end else dto <= dto - 24'd1;
                end
                // ---- read: data ----
                D_RDATA: if (samp) begin
                    for (l = 0; l < 4; l = l + 1) crc[l] <= crc16_bit(crc[l], din[l]);
                    if (bus4) begin
                        if (hi) begin rbyte[7:4] <= din; hi <= 1'b0; end
                        else begin
                            hi <= 1'b1;
                            wacc[8 * bytei +: 8] <= {rbyte[7:4], din};
                            if (bytei == 3'd7) begin
                                f_push <= 1'b1; f_wdata <= {{rbyte[7:4], din}, wacc[55:0]};
                            end
                            bytei <= bytei + 3'd1;
                        end
                    end else begin
                        rbyte <= {rbyte[6:0], din[0]};
                        if (nib[2:0] == 3'd7) begin
                            wacc[8 * bytei +: 8] <= {rbyte[6:0], din[0]};
                            if (bytei == 3'd7) begin
                                f_push <= 1'b1; f_wdata <= {{rbyte[6:0], din[0]}, wacc[55:0]};
                            end
                            bytei <= bytei + 3'd1;
                        end
                    end
                    nib <= nib + 13'd1;
                    if (nib == nib_last) begin ds <= D_RCRC; ccnt16 <= 5'd0; end
                end
                // ---- read: CRC16 (16 bits per lane) + end bit ----
                D_RCRC: if (samp) begin
                    if (ccnt16 < 5'd16) begin
                        for (l = 0; l < 4; l = l + 1) rcrc16[l] <= {rcrc16[l][14:0], din[l]};
                        ccnt16 <= ccnt16 + 5'd1;
                    end else begin
                        // end bit now; compare CRCs
                        if (bus4) begin
                            if (rcrc16[0] != crc[0] || rcrc16[1] != crc[1] || rcrc16[2] != crc[2] || rcrc16[3] != crc[3]) d_crc_p <= 1'b1;
                        end else if (rcrc16[0] != crc[0]) d_crc_p <= 1'b1;
                        if (din[0] != 1'b1) d_end_p <= 1'b1;
                        eng_blk_done <= eng_blk_done + 16'd1;
                        blk_i <= blk_i + 16'd1;
                        dto <= tmo;
                        if (blk_i + 16'd1 == blks_total) ds <= D_IDLE;   // wait for the DMA in IDLE
                        else ds <= D_RWAIT;
                    end
                end
                // ---- write: wait for the response, a block in the FIFO, Nwr gap ----
                D_WPREP: begin
                    if (c_done_p) wait_resp <= 1'b0;
                    if (fall) begin
                        if (!wait_resp && !cmd_busy && fifo_cnt >= {1'b0, blk_words}) begin
                            if (gap == 3'd3) begin
                                // start bit
                                dat_oe <= 1'b1; dat_o <= bus4 ? 4'h0 : 4'hE;
                                nib <= 13'd0; bytei <= 3'd0; hi <= 1'b1;
                                for (l = 0; l < 4; l = l + 1) crc[l] <= 16'd0;
                                ds <= D_WDATA;
                            end else gap <= gap + 3'd1;
                        end
                    end
                end
                // ---- write: data nibbles / bits ----
                D_WDATA: if (fall) begin
                    if (bus4) begin
                        dat_o <= wnib;
                        for (l = 0; l < 4; l = l + 1) crc[l] <= crc16_bit(crc[l], wnib[l]);
                        if (!hi) begin
                            if (bytei == 3'd7) eng_pop <= 1'b1;
                            bytei <= bytei + 3'd1;
                        end
                        hi <= ~hi;
                    end else begin
                        dat_o <= {3'b111, wbit};
                        crc[0] <= crc16_bit(crc[0], wbit);
                        if (nib[2:0] == 3'd7) begin
                            if (bytei == 3'd7) eng_pop <= 1'b1;
                            bytei <= bytei + 3'd1;
                        end
                    end
                    nib <= nib + 13'd1;
                    if (nib == nib_last) begin ds <= D_WCRC; ccnt16 <= 5'd0; end
                end
                // ---- write: CRC16 per lane, end bit, release ----
                D_WCRC: if (fall) begin
                    if (ccnt16 < 5'd16) begin
                        dat_o <= bus4 ? {crc[3][15], crc[2][15], crc[1][15], crc[0][15]} : {3'b111, crc[0][15]};
                        for (l = 0; l < 4; l = l + 1) crc[l] <= {crc[l][14:0], 1'b0};
                        ccnt16 <= ccnt16 + 5'd1;
                    end else if (ccnt16 == 5'd16) begin
                        dat_o <= 4'hF; ccnt16 <= ccnt16 + 5'd1;        // end bit
                    end else begin
                        dat_oe <= 1'b0; ds <= D_WSTAT; wstat_n <= 3'd0; dto <= tmo; wstat <= 4'd0;
                    end
                end
                // ---- write: CRC status token (start 0, 3 bits, end) then busy ----
                D_WSTAT: if (samp) begin
                    if (wstat_n == 3'd0) begin
                        if (din[0] == 1'b0) wstat_n <= 3'd1;
                        else if (dto == 24'd0) begin d_tmo_p <= 1'b1; ds <= D_IDLE; d_active <= 1'b0; dat_busy <= 1'b0; end
                        else dto <= dto - 24'd1;
                    end else if (wstat_n < 3'd4) begin
                        wstat <= {wstat[2:0], din[0]}; wstat_n <= wstat_n + 3'd1;
                    end else if (wstat_n == 3'd4) begin
                        // end bit of the token: status 010 = accepted
                        if (wstat[2:0] != 3'b010) d_wst_p <= 1'b1;
                        wstat_n <= 3'd5; dto <= tmo;
                    end else begin
                        // busy: DAT0 low until the card finishes programming
                        if (din[0] == 1'b1) begin
                            eng_blk_done <= eng_blk_done + 16'd1;
                            blk_i <= blk_i + 16'd1;
                            gap <= 3'd0;
                            if (blk_i + 16'd1 == blks_total) begin
                                ds <= D_IDLE; d_active <= 1'b0; dat_busy <= 1'b0; d_done_p <= 1'b1;
                            end else ds <= D_WPREP;
                        end else if (dto == 24'd0) begin
                            d_tmo_p <= 1'b1; ds <= D_IDLE; d_active <= 1'b0; dat_busy <= 1'b0;
                        end else dto <= dto - 24'd1;
                    end
                end
                default: ds <= D_IDLE;
            endcase
        end
    end

    assign f_pop = dm_wreq | eng_pop;

    assign st_set = {f_err, dma_err_p, d_wst_p, d_end_p, d_crc_p, d_tmo_p, c_idx_p, c_crc_p, c_tmo_p, d_done_p, c_done_p};
endmodule
`default_nettype wire
