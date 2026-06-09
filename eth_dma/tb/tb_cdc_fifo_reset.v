`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_cdc_fifo_reset.v -- cdc_fifo_reset drives CDC_FIFO_Buffer's clears from a
// single async reset; verify the FIFO comes up clean and passes data in order.
//============================================================================
module tb_cdc_fifo_reset;
    localparam W = 32, DEPTH = 512, N = 500;

    reg iclk = 0; always #4  iclk = ~iclk;   // 125 MHz
    reg oclk = 0; always #10 oclk = ~oclk;   // 50 MHz
    reg arst_n = 0;

    wire in_clear, out_clear;
    cdc_fifo_reset #(.HOLD(16)) rstgen (
        .arst_n(arst_n), .in_clk(iclk), .out_clk(oclk),
        .in_clear(in_clear), .out_clear(out_clear)
    );

    reg          ivalid = 0;
    wire         iready;
    reg  [W-1:0] idata = 32'h2000_0000;
    wire         ovalid;
    wire         oready = ~out_clear;
    wire [W-1:0] odata;

    CDC_FIFO_Buffer #(.WORD_WIDTH(W), .DEPTH(DEPTH), .RAMSTYLE(""),
                      .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)) dut (
        .input_clock(iclk),  .input_clear(in_clear),
        .input_valid(ivalid), .input_ready(iready), .input_data(idata),
        .output_clock(oclk), .output_clear(out_clear),
        .output_valid(ovalid), .output_ready(oready), .output_data(odata)
    );

    integer wc = 0;
    always @(posedge iclk) begin
        if (in_clear) begin ivalid <= 0; wc <= 0; end
        else if (!ivalid || iready) begin
            if (wc < N) begin idata <= 32'h2000_0000 + wc; ivalid <= 1; wc <= wc + 1; end
            else ivalid <= 0;
        end
    end

    integer rc = 0, errors = 0;
    always @(posedge oclk) begin
        if (!out_clear && ovalid && oready) begin
            if (odata !== (32'h2000_0000 + rc)) errors = errors + 1;
            rc = rc + 1;
        end
    end

    initial begin
        arst_n = 0;
        #200 arst_n = 1;                 // release async reset; rstgen handles the rest
        wait (rc == N);
        repeat (5) @(posedge oclk);
        if (errors == 0) $display("RESULT: PASS (%0d words; cdc_fifo_reset brought FIFO up clean)", N);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #3000000; $display("RESULT: FAIL (timeout rc=%0d)", rc); $finish; end
endmodule
`default_nettype wire
