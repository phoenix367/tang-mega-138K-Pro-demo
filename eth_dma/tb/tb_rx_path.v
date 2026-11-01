`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_rx_path.v -- full RX path end-to-end. Drive MAC frames at 125 MHz; verify
// each lands in its DRAM ring buffer ([header {err,len}][data]) at 50 MHz,
// having crossed the CDC FIFOs.
//============================================================================
module tb_rx_path;
    parameter WAIT_PCT = 0;         // slave wait states (iverilog -P)
    localparam BUF_SHIFT = 11;

    reg rx_mac_clk = 0; always #4  rx_mac_clk = ~rx_mac_clk;   // 125 MHz
    reg bus_clk    = 0; always #10 bus_clk    = ~bus_clk;      //  50 MHz
    reg arst_n = 0;

    reg        rx_mac_valid = 0, rx_mac_last = 0, rx_mac_error = 0;
    reg  [7:0] rx_mac_data  = 0;

    reg        rx_en = 0;
    reg [31:0] buf_base = 32'h0;
    reg [15:0] ring_len = 16'd4;
    reg [15:0] rx_tail  = 16'd0;
    wire [15:0] rx_head, drop_cnt;
    wire        irq;

    wire [31:0] haddr;
    wire [63:0] hwdata, hrdata;
    wire [1:0]  htrans; wire hwrite, hready, hresp; wire [2:0] hsize, hburst;
    wire [31:0] stat_frames, stat_bad;

    rx_path #(.DATA_DEPTH(512), .META_DEPTH(8), .BUF_SHIFT(BUF_SHIFT)) dut (
        .rx_mac_clk(rx_mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .bus_clk(bus_clk), .arst_n(arst_n),
        .rx_en(rx_en), .buf_base(buf_base), .ring_len(ring_len), .rx_tail(rx_tail),
        .rx_head(rx_head), .drop_cnt(drop_cnt),
        .stat_frames(stat_frames), .stat_bad(stat_bad), .irq(irq),
        .haddr(haddr), .htrans(htrans), .hwrite(hwrite), .hsize(hsize), .hburst(hburst),
        .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
    );
    ahb_slave_ram #(.DATA_W(64), .AW(12), .WAIT_PCT(WAIT_PCT)) slv (
        .hclk(bus_clk), .hresetn(arst_n), .haddr(haddr), .htrans(htrans), .hwrite(hwrite),
        .hsize(hsize), .hburst(hburst), .hwdata(hwdata), .hrdata(hrdata),
        .hready(hready), .hresp(hresp)
    );

    // expected byte: frame f, byte i
    function [7:0] pat(input integer f, input integer i);
        pat = 8'h10 + (f << 6) + i;
    endfunction

    task send_frame(input integer f, input integer len, input err);
        integer i;
        begin
            for (i = 0; i < len; i = i + 1) begin
                @(negedge rx_mac_clk);
                rx_mac_valid = 1; rx_mac_data = pat(f, i);
                rx_mac_last  = (i == len-1);
                rx_mac_error = (i == len-1) ? err : 1'b0;
            end
            @(negedge rx_mac_clk); rx_mac_valid = 0; rx_mac_last = 0; rx_mac_error = 0;
            repeat (6) @(negedge rx_mac_clk);
        end
    endtask

    integer flen [0:2]; integer ferr_a [0:2];
    integer f, i, errors; integer widx; reg [7:0] got, exp; reg [31:0] base, hdr;
    initial begin
        errors = 0;
        flen[0]=14; ferr_a[0]=0;
        flen[1]=60; ferr_a[1]=1;
        flen[2]=4;  ferr_a[2]=0;

        arst_n = 0;
        #500 arst_n = 1;
        #2000 rx_en = 1;                       // after the CDC reset settles

        send_frame(0, flen[0], ferr_a[0]);
        send_frame(1, flen[1], ferr_a[1]);
        send_frame(2, flen[2], ferr_a[2]);

        wait (rx_head == 3);
        repeat (10) @(posedge bus_clk);

        for (f = 0; f < 3; f = f + 1) begin
            base = (f % ring_len) << BUF_SHIFT;
            hdr  = {15'b0, ferr_a[f][0], flen[f][15:0]};
            if (slv.mem[base >> 3][31:0] !== hdr) begin
                errors = errors + 1;
                $display("  frame %0d header got %08x exp %08x", f, slv.mem[base >> 3][31:0], hdr);
            end
            for (i = 0; i < flen[f]; i = i + 1) begin
                widx = base + 4 + i;                     // byte address
                got  = slv.mem[widx >> 3][(widx % 8)*8 +: 8];
                exp  = pat(f, i);
                if (got !== exp) begin
                    errors = errors + 1;
                    if (errors < 8) $display("  frame %0d byte %0d got %02x exp %02x", f, i, got, exp);
                end
            end
        end
        errors = errors + slv.proto_err;
        if (stat_frames !== 32'd3 || stat_bad !== 32'd1) begin
            errors = errors + 1;
            $display("  line-rate stats frames=%0d bad=%0d, exp 3/1", stat_frames, stat_bad);
        end
        if (errors == 0) $display("RESULT: PASS (3 frames crossed MAC->CDC->DMA->DRAM intact; drops=%0d; wait %0d%%)", drop_cnt, WAIT_PCT);
        else             $display("RESULT: FAIL (%0d errors, rx_head=%0d)", errors, rx_head);
        $finish;
    end
    initial begin #200000; $display("RESULT: FAIL (timeout rx_head=%0d)", rx_head); $finish; end
endmodule
`default_nettype wire
