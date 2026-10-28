`default_nettype none
//============================================================================
// ahb_slave_ram.v -- AHB-lite slave memory (sim model).
//   Captures the address phase, then services the data phase one cycle later.
//   WAIT_PCT > 0 inserts random wait states (HREADY low) into data phases;
//   0 = zero-wait (the original behaviour).  HRESP always OKAY.
//   Protocol checks (count in `proto_err`): a SEQ beat must follow the previous
//   beat at +4 bytes with the same HWRITE/HBURST, fixed-length INCR bursts must
//   complete before the next NONSEQ, and no burst may cross a 1 KB boundary.
//============================================================================
module ahb_slave_ram #(
    parameter ADDR_W   = 32,
    parameter DATA_W   = 32,
    parameter AW       = 12,       // 2^AW words (default 4K words = 16KB)
    parameter WAIT_PCT = 0,        // % of data-phase cycles with HREADY low
    parameter SEED     = 1
)(
    input  wire              hclk,
    input  wire              hresetn,
    input  wire [ADDR_W-1:0] haddr,
    input  wire [1:0]        htrans,
    input  wire              hwrite,
    input  wire [2:0]        hsize,
    input  wire [2:0]        hburst,
    input  wire [DATA_W-1:0] hwdata,
    output wire [DATA_W-1:0] hrdata,
    output wire              hready,
    output wire              hresp
);
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] HTRANS_SEQ    = 2'b11;

    reg [DATA_W-1:0] mem [0:(1<<AW)-1];

    reg [AW-1:0] a_addr;
    reg          a_write;
    reg          a_valid;          // a data phase is pending

    // wait states only extend a pending data phase
    integer seed = SEED;
    reg     stall = 1'b0;
    always @(posedge hclk) stall <= (WAIT_PCT > 0) && ({$random(seed)} % 100 < WAIT_PCT);
    assign hready = !(a_valid && stall);
    assign hresp  = 1'b0;          // always OKAY

    wire active = (htrans == HTRANS_NONSEQ) || (htrans == HTRANS_SEQ);

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_valid <= 1'b0;
            a_write <= 1'b0;
            a_addr  <= {AW{1'b0}};
        end else if (hready) begin
            // data phase of the previously-captured address (write commits here)
            if (a_valid && a_write)
                mem[a_addr] <= hwdata;
            // capture this cycle's address phase
            a_valid <= active;
            a_write <= hwrite;
            a_addr  <= haddr[AW+1:2];
        end
    end

    // read data presented during the data phase (combinational from captured addr)
    assign hrdata = mem[a_addr];

    // ---- burst protocol checks (on accepted address phases) ----
    integer      proto_err = 0;
    reg [ADDR_W-1:0] p_addr;
    reg          p_write;
    reg [2:0]    p_burst;
    reg [ADDR_W-1:0] b_start;
    integer      b_left = 0;       // beats still owed by a fixed-length burst
    function integer fixed_len(input [2:0] hb);
        case (hb)
            3'b011, 3'b010: fixed_len = 4;     // INCR4 / WRAP4
            3'b101, 3'b100: fixed_len = 8;
            3'b111, 3'b110: fixed_len = 16;
            default:        fixed_len = 0;     // SINGLE / INCR
        endcase
    endfunction
    always @(posedge hclk) if (hresetn && active && hready) begin
        if (htrans == HTRANS_SEQ) begin
            if (haddr != p_addr + 4 || hwrite != p_write || hburst != p_burst) begin
                proto_err = proto_err + 1;
                $display("  AHB: bad SEQ beat @%08x (prev %08x)", haddr, p_addr);
            end
            if (haddr[ADDR_W-1:10] != b_start[ADDR_W-1:10]) begin
                proto_err = proto_err + 1;
                $display("  AHB: burst from %08x crosses 1 KB at %08x", b_start, haddr);
            end
            if (b_left > 0) b_left = b_left - 1;
        end else begin
            if (b_left > 0) begin
                proto_err = proto_err + 1;
                $display("  AHB: NONSEQ @%08x while %0d burst beats outstanding", haddr, b_left);
            end
            b_start = haddr;
            b_left  = fixed_len(hburst) > 0 ? fixed_len(hburst) - 1 : 0;
        end
        p_addr = haddr; p_write = hwrite; p_burst = hburst;
    end
endmodule
`default_nettype wire
