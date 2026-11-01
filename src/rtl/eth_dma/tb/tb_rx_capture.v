`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_rx_capture.v -- drive MAC RX frames of various lengths; verify the packed
// words reconstruct the byte stream little-endian and the trailer length/error.
//============================================================================
module tb_rx_capture;
    reg clk = 0; always #4 clk = ~clk;        // 125 MHz
    reg rstn = 0;

    reg        rx_mac_valid = 0, rx_mac_last = 0, rx_mac_error = 0;
    reg  [7:0] rx_mac_data  = 0;
    wire       word_valid, frame_valid, frame_err;
    wire [31:0] word_data;
    wire [15:0] frame_len;

    rx_capture dut (
        .rx_mac_clk(clk), .rstn(rstn),
        .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .word_valid(word_valid), .word_data(word_data),
        .frame_valid(frame_valid), .frame_len(frame_len), .frame_err(frame_err)
    );

    // collect emitted words; flatten to a byte array for checking
    reg [31:0] wbuf [0:511];
    integer    widx = 0;
    always @(posedge clk) if (word_valid) begin wbuf[widx] = word_data; widx = widx + 1; end

    // frame-done capture
    reg        fv = 0; reg [15:0] flen; reg ferr;
    always @(posedge clk) if (frame_valid) begin fv = 1; flen = frame_len; ferr = frame_err; end

    integer errors = 0;

    task send_frame(input [15:0] len, input err);
        integer i;
        begin
            widx = 0; fv = 0;
            for (i = 0; i < len; i = i + 1) begin
                @(negedge clk);
                rx_mac_valid = 1;
                rx_mac_data  = 8'h10 + i[7:0];
                rx_mac_last  = (i == len-1);
                rx_mac_error = (i == len-1) ? err : 1'b0;
            end
            @(negedge clk); rx_mac_valid = 0; rx_mac_last = 0; rx_mac_error = 0;
            @(posedge clk);                 // trailer cycle
            check_frame(len, err);
        end
    endtask

    task check_frame(input [15:0] len, input err);
        integer i; reg [7:0] got, exp; integer bad;
        begin
            bad = 0;
            if (!fv)            begin bad=bad+1; $display("  no frame_valid for len %0d", len); end
            if (flen !== len)   begin bad=bad+1; $display("  len got %0d exp %0d", flen, len); end
            if (ferr !== err)   begin bad=bad+1; $display("  err got %b exp %b", ferr, err); end
            for (i = 0; i < len; i = i + 1) begin
                got = wbuf[i/4][(i%4)*8 +: 8];
                exp = 8'h10 + i[7:0];
                if (got !== exp) begin bad=bad+1; if (bad<4) $display("  byte %0d got %02x exp %02x", i, got, exp); end
            end
            if (bad == 0) $display("  frame len=%0d err=%b OK", len, err);
            errors = errors + bad;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); rstn = 1; @(negedge clk);
        send_frame(16'd1,  1'b0);     // 1 byte
        send_frame(16'd4,  1'b0);     // exactly one word
        send_frame(16'd14, 1'b0);     // 3 full + 1 partial (2 bytes)
        send_frame(16'd60, 1'b1);     // min payload, with error flag
        send_frame(16'd64, 1'b0);
        repeat (3) @(posedge clk);
        if (errors == 0) $display("RESULT: PASS (rx_capture packs + frames correctly)");
        else             $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
    initial begin #50000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
