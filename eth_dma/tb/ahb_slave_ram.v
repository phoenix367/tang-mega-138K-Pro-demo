`default_nettype none
//============================================================================
// ahb_slave_ram.v -- simple zero-wait AHB-lite slave memory (sim model).
//   Captures the address phase, then services the data phase one cycle later.
//   HREADY always high, HRESP always OKAY. WORDS words of DATA_W bits.
//============================================================================
module ahb_slave_ram #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter AW     = 12          // 2^AW words (default 4K words = 16KB)
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

    assign hready = 1'b1;          // zero wait state
    assign hresp  = 1'b0;          // always OKAY

    reg [AW-1:0] a_addr;
    reg          a_write;
    reg          a_valid;

    wire active = (htrans == HTRANS_NONSEQ) || (htrans == HTRANS_SEQ);

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_valid <= 1'b0;
            a_write <= 1'b0;
            a_addr  <= {AW{1'b0}};
        end else begin
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
endmodule
`default_nettype wire
