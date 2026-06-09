`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_cdc_fifo.v -- validate the FPGADesignElements CDC_FIFO_Buffer as our
// 125 MHz (MAC) -> 50 MHz (bus) crossing: stream N words in, read them out,
// verify order/integrity across the asynchronous clocks. ready/valid handshake.
//============================================================================
module tb_cdc_fifo;
    localparam W = 32, DEPTH = 512, N = 1000;

    integer cyc = 0;
    always @(posedge iclk) begin
        cyc <= cyc + 1;
        if (cyc % 99999 == 0)
            $display("t=%0t wc=%0d rc=%0d iclr=%b oclr=%b ivld=%b irdy=%b ovld=%b ordy=%b idata=%08x odata=%08x",
                     $time, wc, rc, iclr, oclr, ivalid, iready, ovalid, oready, idata, odata);
    end

    reg iclk = 0; always #4  iclk = ~iclk;   // 125 MHz (input/MAC domain)
    reg oclk = 0; always #10 oclk = ~oclk;   // 50 MHz  (output/bus domain)
    reg iclr = 1, oclr = 1;

    reg          ivalid = 0;
    wire         iready;
    reg  [W-1:0] idata = 32'h1000_0000;
    wire         ovalid;
    wire         oready = ~oclr;             // always ready to drain
    wire [W-1:0] odata;

    CDC_FIFO_Buffer #(
        .WORD_WIDTH(W), .DEPTH(DEPTH), .RAMSTYLE(""),
        .CIRCULAR_BUFFER(0), .CDC_EXTRA_STAGES(0)
    ) dut (
        .input_clock(iclk),  .input_clear(iclr),
        .input_valid(ivalid), .input_ready(iready), .input_data(idata),
        .output_clock(oclk), .output_clear(oclr),
        .output_valid(ovalid), .output_ready(oready), .output_data(odata)
    );

    // producer (125 MHz): present base+wc; advance when accepted
    integer wc = 0;
    always @(posedge iclk) begin
        if (iclr) begin ivalid <= 0; wc <= 0; idata <= 32'h1000_0000; end
        else if (!ivalid || iready) begin
            if (wc < N) begin idata <= 32'h1000_0000 + wc; ivalid <= 1; wc <= wc + 1; end
            else ivalid <= 0;
        end
    end

    // consumer/checker (50 MHz): a transfer happens on ovalid && oready
    integer rc = 0, errors = 0;
    always @(posedge oclk) begin
        if (!oclr && ovalid && oready) begin
            if (odata !== (32'h1000_0000 + rc)) begin
                errors = errors + 1;
                if (errors < 6) $display("  MISMATCH #%0d got %08x exp %08x", rc, odata, 32'h1000_0000+rc);
            end
            rc = rc + 1;
        end
    end

    initial begin
        iclr = 1; oclr = 1;            // hold both clears together long enough
        #300;                          // for the cross-domain handshake to reset
        @(posedge iclk) iclr = 0;
        @(posedge oclk) oclr = 0;
        wait (rc == N);
        repeat (5) @(posedge oclk);
        if (errors == 0) $display("RESULT: PASS (%0d words via CDC_FIFO_Buffer 125->50MHz)", N);
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #3000000; $display("RESULT: FAIL (timeout rc=%0d)", rc); $finish; end
endmodule
`default_nettype wire
