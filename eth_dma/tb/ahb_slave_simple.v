`timescale 1ns/1ps
`default_nettype none
// Minimal zero-wait 32-bit AHB-lite slave with HSEL + HREADYIN (for arbiter sim).
module ahb_slave_simple #(parameter AW = 10)(
    input  wire        hclk,
    input  wire        hresetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [2:0]  hburst,
    input  wire [31:0] hwdata,
    input  wire        hsel,
    input  wire        hready_in,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp
);
    reg [31:0] mem [0:(1<<AW)-1];
    reg [AW-1:0] a_addr;
    reg          a_wr, a_sel;
    always @(posedge hclk) begin
        if (hsel && hready_in && htrans[1]) begin
            a_addr <= haddr[AW+1:2]; a_wr <= hwrite; a_sel <= 1'b1;
        end else a_sel <= 1'b0;
        if (a_sel && a_wr) mem[a_addr] <= hwdata;
    end
    assign hrdata = mem[a_addr];
    assign hready = 1'b1;
    assign hresp  = 1'b0;
endmodule
`default_nettype wire
