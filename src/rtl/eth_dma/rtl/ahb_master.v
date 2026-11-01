`default_nettype none
//============================================================================
// ahb_master.v  -- AHB-lite master "DMA mover" for gw_eth_dma (EXTM side).
//
// Moves cmd_len DATA_W-bit beats (32 or 64 bits) to (cmd_wr=1) or from
// (cmd_wr=0) cmd_addr.  Write data is pulled one beat at a time via
// w_req/w_data; read data is pushed via r_valid/r_data.
//
// v2: writes go out as pipelined incrementing bursts -- the next beat's address
//     phase overlaps the current beat's data phase (1 beat/cycle on a zero-wait
//     slave).  Each burst is the longest of INCR16/INCR8/INCR4/SINGLE (capped by
//     MAX_BURST) that fits the remaining words without crossing a 1 KB boundary.
//     The SoC's EXTM port charges ~16 cycles per burst start and streams fixed-
//     length bursts; MAX_BURST = 0 (undefined-length INCR to the 1 KB boundary)
//     is supported but the EXTM port breaks INCR into single transfers.
//     The write-data source must hold every word of the command (rx_ring_writer
//     only starts a frame once all of it is buffered), so a burst never stalls.
//     Reads stay non-pipelined single beats (2 cycles/beat, zero-wait slave),
//     as in v1.  64-bit beats halve the burst starts per frame.
//============================================================================
module ahb_master #(
    parameter ADDR_W    = 32,
    parameter DATA_W    = 32,
    parameter MAX_BURST = 16           // write bursts: 1/4/8/16 beats, 0 = INCR to 1 KB
)(
    input  wire              hclk,
    input  wire              hresetn,
    // command interface
    input  wire              cmd_valid,
    output wire              cmd_ready,    // high when idle (accepts a command)
    input  wire [ADDR_W-1:0] cmd_addr,     // byte address, beat-aligned
    input  wire [15:0]       cmd_len,      // number of beats (>= 1)
    input  wire              cmd_wr,       // 1 = write to memory, 0 = read
    output reg               cmd_done,     // 1-cycle pulse when transfer ends
    output reg               cmd_err,      // sampled with cmd_done: HRESP error
    output wire              busy,         // high while a command is in progress
    // write-data source (master consumes one word per beat)
    output wire              w_req,        // pulse: this beat's w_data consumed
    input  wire [DATA_W-1:0] w_data,
    // read-data sink (master produces)
    output reg               r_valid,
    output reg  [DATA_W-1:0] r_data,
    // AHB-lite master port
    output reg  [ADDR_W-1:0] haddr,
    output reg  [1:0]        htrans,
    output reg               hwrite,
    output wire [2:0]        hsize,
    output reg  [2:0]        hburst,
    output wire [DATA_W-1:0] hwdata,
    input  wire [DATA_W-1:0] hrdata,
    input  wire              hready,
    input  wire              hresp
);
    localparam [1:0] HTRANS_IDLE = 2'b00, HTRANS_NONSEQ = 2'b10, HTRANS_SEQ = 2'b11;
    localparam [2:0] HB_SINGLE = 3'b000, HB_INCR = 3'b001, HB_INCR4 = 3'b011,
                     HB_INCR8  = 3'b101, HB_INCR16 = 3'b111;

    reg        act;           // a command is in progress
    reg        wr;
    reg        dph;           // a data phase is in progress
    reg [15:0] a_left;        // beats not yet accepted in an address phase
    reg [15:0] d_left;        // beats whose data phase has not completed
    reg [7:0]  b_left;        // beats left in this burst after the current address
    reg        errflag;

    localparam BB = DATA_W / 8;            // bytes per beat: 4 or 8
    localparam LB = (DATA_W == 64) ? 3 : 2;

    wire a_take = htrans[1] && hready;     // address phase accepted this cycle
    wire d_take = dph && hready;           // data phase completes this cycle

    assign hsize     = (DATA_W == 64) ? 3'b011 : 3'b010;
    assign cmd_ready = !act;
    assign busy      = act;
    assign hwdata    = w_data;             // held through the data phase
    assign w_req     = d_take && wr;

    // Longest burst (beats) starting at byte address a with n beats to go: it
    // must fit n and stay below the next 1 KB boundary.
    function [8:0] blen(input [ADDR_W-1:0] a, input [15:0] n);
        reg [15:0] m;
        begin
            m = (16'd1024 - {6'd0, a[9:0]}) >> LB;   // beats to the 1 KB boundary
            if (n < m) m = n;
            if      (MAX_BURST == 0)             blen = m[8:0];
            else if (MAX_BURST >= 16 && m >= 16) blen = 9'd16;
            else if (MAX_BURST >= 8  && m >= 8)  blen = 9'd8;
            else if (MAX_BURST >= 4  && m >= 4)  blen = 9'd4;
            else                                 blen = 9'd1;
        end
    endfunction

    function [2:0] bcode(input [8:0] n);
        if (n == 9'd1)          bcode = HB_SINGLE;
        else if (MAX_BURST == 0) bcode = HB_INCR;
        else case (n)
            9'd16:   bcode = HB_INCR16;
            9'd8:    bcode = HB_INCR8;
            default: bcode = HB_INCR4;
        endcase
    endfunction

    // the next write beat after the one accepted this cycle
    wire [ADDR_W-1:0] next_addr = haddr + BB;
    wire [8:0]        next_blen = blen(next_addr, a_left - 16'd1);
    wire [8:0]        first_len = cmd_wr ? blen(cmd_addr, cmd_len) : 9'd1;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            act <= 1'b0; wr <= 1'b0; dph <= 1'b0; errflag <= 1'b0;
            a_left <= 16'd0; d_left <= 16'd0; b_left <= 8'd0;
            haddr <= {ADDR_W{1'b0}}; htrans <= HTRANS_IDLE; hwrite <= 1'b0;
            hburst <= HB_SINGLE;
            cmd_done <= 1'b0; cmd_err <= 1'b0;
            r_valid <= 1'b0; r_data <= {DATA_W{1'b0}};
        end else begin
            cmd_done <= 1'b0;
            r_valid  <= 1'b0;
            if (!act) begin
                if (cmd_valid) begin                // first address phase
                    act     <= 1'b1;
                    wr      <= cmd_wr;
                    errflag <= 1'b0;
                    a_left  <= cmd_len;
                    d_left  <= cmd_len;
                    haddr   <= cmd_addr;
                    hwrite  <= cmd_wr;
                    htrans  <= HTRANS_NONSEQ;
                    hburst  <= bcode(first_len);
                    b_left  <= first_len[7:0] - 8'd1;
                end
            end else begin
                if (hready) dph <= htrans[1];       // accepted address -> data phase
                if (d_take) begin
                    if (hresp) errflag <= 1'b1;
                    if (!wr) begin
                        r_data  <= hrdata;
                        r_valid <= 1'b1;
                    end
                    d_left <= d_left - 16'd1;
                    if (d_left == 16'd1) begin      // last beat done
                        act      <= 1'b0;
                        cmd_done <= 1'b1;
                        cmd_err  <= errflag | hresp;
                    end
                end
                if (a_take) begin
                    a_left <= a_left - 16'd1;
                    if (a_left == 16'd1 || !wr) begin
                        htrans <= HTRANS_IDLE;      // last beat, or a read
                    end else if (b_left != 8'd0) begin
                        haddr  <= next_addr;        // next beat of this burst
                        htrans <= HTRANS_SEQ;
                        b_left <= b_left - 8'd1;
                    end else begin
                        haddr  <= next_addr;        // next burst
                        htrans <= HTRANS_NONSEQ;
                        hburst <= bcode(next_blen);
                        b_left <= next_blen[7:0] - 8'd1;
                    end
                end else if (d_take && !wr && a_left != 16'd0) begin
                    haddr  <= next_addr;            // read: next single beat
                    htrans <= HTRANS_NONSEQ;
                    hburst <= HB_SINGLE;
                end
            end
        end
    end

`ifdef FORMAL
    // Safety properties (BMC via yosys/sby/z3).
    initial assume(!hresetn);
    always @(posedge hclk) if (hresetn) begin
        // driver contract: command addresses are beat-aligned.
        assume(cmd_addr[LB-1:0] == 0);
        // never BUSY.
        assert(htrans != 2'b01);
        // addresses stay beat-aligned.
        assert(haddr[LB-1:0] == 0);
        // reads are single beats.
        if (!wr && act && htrans[1]) assert(htrans == HTRANS_NONSEQ && hburst == HB_SINGLE);
        // never request write data unless mid-write.
        if (w_req) assert(wr);
        // read data is only produced during a read.
        if (r_valid) assert(!wr);
    end
`endif
endmodule
`default_nettype wire
