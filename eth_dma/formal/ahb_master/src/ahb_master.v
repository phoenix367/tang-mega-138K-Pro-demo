`default_nettype none
//============================================================================
// ahb_master.v  -- AHB-lite master "DMA mover" for gw_eth_dma (EXTM side).
//
// v1: non-pipelined single-beat transfers (2 cycles/word, zero-wait slave).
//     Moves cmd_len 32-bit words to (cmd_wr=1) or from (cmd_wr=0) cmd_addr.
//     Write data is pulled one word per beat via w_req/w_data; read data is
//     pushed via r_valid/r_data.  Bursts (INCR) are a later optimization.
//
// AHB beat = address phase (HTRANS=NONSEQ, HADDR) then data phase (HTRANS=IDLE,
// HWDATA for writes / HRDATA for reads), each extended while HREADY is low.
//============================================================================
module ahb_master #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32
)(
    input  wire              hclk,
    input  wire              hresetn,
    // command interface
    input  wire              cmd_valid,
    output wire              cmd_ready,    // high when idle (accepts a command)
    input  wire [ADDR_W-1:0] cmd_addr,     // byte address, word-aligned
    input  wire [15:0]       cmd_len,      // number of 32-bit words (>= 1)
    input  wire              cmd_wr,       // 1 = write to memory, 0 = read
    output reg               cmd_done,     // 1-cycle pulse when transfer ends
    output reg               cmd_err,      // sampled with cmd_done: HRESP error
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
    output wire [2:0]        hburst,
    output wire [DATA_W-1:0] hwdata,
    input  wire [DATA_W-1:0] hrdata,
    input  wire              hready,
    input  wire              hresp
);
    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2;

    reg [1:0]        state;
    reg [ADDR_W-1:0] base;
    reg [15:0]       len;
    reg [15:0]       beat;
    reg              wr;
    reg              errflag;

    assign hsize     = 3'b010;                 // 32-bit transfers
    assign hburst    = 3'b000;                 // SINGLE
    assign cmd_ready = (state == S_IDLE);
    assign hwdata    = w_data;                 // valid during a write data phase
    assign w_req     = (state == S_DATA) && wr && hready;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            state    <= S_IDLE;
            htrans   <= HTRANS_IDLE;
            hwrite   <= 1'b0;
            haddr    <= {ADDR_W{1'b0}};
            base     <= {ADDR_W{1'b0}};
            len      <= 16'd0;
            beat     <= 16'd0;
            wr       <= 1'b0;
            errflag  <= 1'b0;
            cmd_done <= 1'b0;
            cmd_err  <= 1'b0;
            r_valid  <= 1'b0;
            r_data   <= {DATA_W{1'b0}};
        end else begin
            cmd_done <= 1'b0;
            r_valid  <= 1'b0;
            case (state)
                S_IDLE: begin
                    htrans <= HTRANS_IDLE;
                    if (cmd_valid) begin
                        base    <= cmd_addr;
                        len     <= cmd_len;
                        wr      <= cmd_wr;
                        beat    <= 16'd0;
                        errflag <= 1'b0;
                        haddr   <= cmd_addr;       // issue first address phase
                        hwrite  <= cmd_wr;
                        htrans  <= HTRANS_NONSEQ;
                        state   <= S_ADDR;
                    end
                end
                S_ADDR: begin
                    if (hready) begin              // address accepted
                        htrans <= HTRANS_IDLE;     // data phase next cycle
                        state  <= S_DATA;
                    end
                    // else hold address phase (htrans stays NONSEQ)
                end
                S_DATA: begin
                    htrans <= HTRANS_IDLE;
                    if (hready) begin              // data phase complete
                        if (hresp) errflag <= 1'b1;
                        if (!wr) begin
                            r_data  <= hrdata;
                            r_valid <= 1'b1;
                        end
                        if (beat + 16'd1 == len) begin
                            cmd_done <= 1'b1;
                            cmd_err  <= errflag | hresp;
                            state    <= S_IDLE;
                        end else begin
                            beat   <= beat + 16'd1;
                            haddr  <= base + ((beat + 16'd1) << 2);
                            hwrite <= wr;
                            htrans <= HTRANS_NONSEQ;
                            state  <= S_ADDR;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef FORMAL
    // Safety properties (BMC via yosys/sby/z3).
    initial assume(!hresetn);
    always @(posedge hclk) if (hresetn) begin
        // driver contract: command addresses are word-aligned.
        assume(cmd_addr[1:0] == 2'b00);
        // v1 only ever drives IDLE or NONSEQ (never BUSY/SEQ).
        assert(htrans == HTRANS_IDLE || htrans == HTRANS_NONSEQ);
        // addresses stay word-aligned.
        assert(haddr[1:0] == 2'b00);
        // never request write data unless mid-write.
        if (w_req) assert(wr);
        // read data is only produced during a read.
        if (r_valid) assert(!wr);
    end
`endif
endmodule
`default_nettype wire
