`timescale 1ns/1ps
`default_nettype none
//============================================================================
// ahb_slave_ram64.v -- zero-wait 64-bit AHB-lite slave RAM (models the EXTM
// slave). 64-bit transfers (HSIZE=011) write the whole word; 32-bit transfers
// update only the active lane (HADDR[2]); reads return the full 64-bit word.
//============================================================================
module ahb_slave_ram64 #(parameter AW = 12)(   // AW = 64-bit-word address bits
    input  wire        hclk,
    input  wire        hresetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [2:0]  hburst,
    input  wire [63:0] hwdata,
    input  wire        hsel,
    input  wire        hready_in,
    output wire [63:0] hrdata,
    output wire        hready,
    output wire        hresp
);
    reg [63:0] mem [0:(1<<AW)-1];
    reg [AW-1:0] a_word;
    reg          a_lane, a_wr, a_sel, a_w64;
    wire         active = hsel && hready_in && htrans[1];

    always @(posedge hclk) begin
        if (active) begin
            a_word <= haddr[AW+2:3];
            a_lane <= haddr[2];
            a_w64  <= (hsize == 3'b011);
            a_wr   <= hwrite;
            a_sel  <= 1'b1;
        end else a_sel <= 1'b0;
        if (a_sel && a_wr && a_w64)  mem[a_word] <= hwdata;
        else if (a_sel && a_wr)      mem[a_word][a_lane*32 +: 32] <= hwdata[a_lane*32 +: 32];
    end
    assign hrdata = mem[a_word];
    assign hready = 1'b1;
    assign hresp  = 1'b0;
endmodule
`default_nettype wire
