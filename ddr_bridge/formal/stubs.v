// Formal stand-ins for the clock-crossing FIFOs and the read BIST
// (formal/bridge_ahb.sby): every output the bridge reads is free, except
// that the FIFO tracks its occupancy (f_cnt) so the write side can be
// checked for overflow; wlevel reports exactly that occupancy, the most
// optimistic value the real gray-pointer level could show.
module ddr_async_fifo #(
    parameter W = 8, parameter AW = 4, parameter WREG = 0
) (
    input  wire          wclk, wrst_n, wr,
    input  wire [W-1:0]  wdata,
    output wire          full,
    output wire [AW:0]   wlevel,
    input  wire          rclk, rrst_n, rd,
    output wire [W-1:0]  rdata,
    output wire          empty
);
    (* anyseq *) wire          f_pop;
    (* anyseq *) wire [W-1:0]  f_rdata;
    (* anyseq *) wire          f_empty;
    reg [AW:0] f_cnt = 0;
    always @(posedge wclk)
        if (!wrst_n) f_cnt <= 0;
        else f_cnt <= f_cnt + (wr ? 1'b1 : 1'b0) - ((f_pop && f_cnt != 0) ? 1'b1 : 1'b0);
    assign full   = (f_cnt == (1 << AW));
    assign wlevel = f_cnt;
    assign rdata  = f_rdata;
    assign empty  = f_empty;
endmodule

module ddr_rd_bist #(parameter AW = 28) (
    input  wire clk, rst_n, start, input wire [1:0] pattern, input wire [3:0] iter_log2,
    input  wire port_idle,
    output wire hold, own, input wire cmd_ok, output wire cmd_en, output wire [AW-1:0] addr,
    input  wire [255:0] rd_data, input wire rd_data_valid,
    output wire [31:0] r_status, r_err, r_reorder, r_first, r_first_addr,
                       r_first_got, r_first_exp, r_extra
);
    assign hold = 1'b0; assign own = 1'b0; assign cmd_en = 1'b0; assign addr = {AW{1'b0}};
    assign r_status = 0; assign r_err = 0; assign r_reorder = 0; assign r_first = 0;
    assign r_first_addr = 0; assign r_first_got = 0; assign r_first_exp = 0; assign r_extra = 0;
endmodule
