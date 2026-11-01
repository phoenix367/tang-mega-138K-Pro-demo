`timescale 1ns/1ps
//============================================================================
// tb_sdhost.v -- sdhost_core with its DMA master on a 64-bit AHB memory
// model and the behavioural SD card.  Drives the registers the way the Linux
// driver does.
//============================================================================
module tb_sdhost;
    reg hclk = 0;  always #10 hclk = ~hclk;       // 50 MHz
    reg hresetn = 0;

    // ---- AHB-lite slave port of the core ----
    reg  [31:0] haddr = 0, hwdata = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0, hsel = 0;
    wire [31:0] hrdata;
    wire        hready, hresp;
    // ---- DMA master port -> memory model ----
    wire        m_busy, m_hwrite, m_hready, m_hresp;
    wire [31:0] m_haddr;
    wire [1:0]  m_htrans;
    wire [2:0]  m_hsize, m_hburst;
    wire [63:0] m_hwdata, m_hrdata;
    // ---- SD bus ----
    wire        sd_clk, cmd_o, cmd_oe, dat_oe, dat_oe_hi, irq;
    wire [3:0]  dat_o;
    wire        cmd_w;
    wire [3:0]  dat_w;
    reg         det_n = 0;
    assign cmd_w    = cmd_oe ? cmd_o : 1'bz;
    assign dat_w[0] = dat_oe ? dat_o[0] : 1'bz;
    assign dat_w[3:1] = dat_oe_hi ? dat_o[3:1] : 3'bzzz;
    pullup (cmd_w); pullup (dat_w[0]); pullup (dat_w[1]); pullup (dat_w[2]); pullup (dat_w[3]);

    sdhost_core dut (
        .hclk(hclk), .hresetn(hresetn),
        .s_haddr(haddr), .s_htrans(htrans), .s_hwrite(hwrite), .s_hsel(hsel), .s_hready_in(1'b1), .s_hwdata(hwdata),
        .s_hrdata(hrdata), .s_hready(hready), .s_hresp(hresp),
        .m_busy(m_busy), .m_haddr(m_haddr), .m_htrans(m_htrans), .m_hwrite(m_hwrite), .m_hsize(m_hsize),
        .m_hburst(m_hburst), .m_hwdata(m_hwdata), .m_hrdata(m_hrdata), .m_hready(m_hready), .m_hresp(m_hresp),
        .sd_clk(sd_clk), .cmd_o(cmd_o), .cmd_oe(cmd_oe), .cmd_i(cmd_w), .dat_o(dat_o), .dat_oe(dat_oe),
        .dat_oe_hi(dat_oe_hi), .dat_i(dat_w), .sd_det_n(det_n), .irq(irq)
    );
    sd_card_model card (.clk(sd_clk), .cmd(cmd_w), .dat(dat_w));

    // ---- 64-bit AHB memory model (1 MB at 0x0010_0000), random wait states ----
    reg [63:0] ddr [0:131071];
    reg        dph = 0, dwr = 0; reg [16:0] didx; reg [63:0] rd_q;
    reg        wait_st = 0; integer ws = 0;
    assign m_hready = !wait_st;
    assign m_hresp  = 1'b0;
    assign m_hrdata = rd_q;
    always @(posedge hclk) begin
        if (m_hready) begin
            if (dph && dwr) ddr[didx] <= m_hwdata;
            dph <= m_htrans[1];
            dwr <= m_hwrite;
            didx <= m_haddr[19:3];
            if (m_htrans[1] && !m_hwrite) rd_q <= ddr[m_haddr[19:3]];
        end
        // occasional wait states on accepted transfers
        if (m_htrans[1] || dph) begin
            if (!wait_st && ($random % 7 == 0)) begin wait_st <= 1; ws <= 1 + ($random & 3); end
            else if (wait_st) begin if (ws == 0) wait_st <= 0; else ws <= ws - 1; end
        end else wait_st <= 0;
    end

    // ---- register access ----
    localparam BASE = 32'hE802_0000;
    localparam R_CTRL = 8'h00, R_ARG = 8'h04, R_CMD = 8'h08, R_RESP0 = 8'h0C, R_RESP1 = 8'h10, R_RESP2 = 8'h14,
               R_RESP3 = 8'h18, R_BLK = 8'h1C, R_DMA = 8'h20, R_STATUS = 8'h24, R_INTEN = 8'h28, R_TMO = 8'h2C,
               R_ID = 8'h30, R_DBG = 8'h34;
    task wr(input [7:0] off, input [31:0] d);
    begin
        @(posedge hclk); haddr <= BASE | off; htrans <= 2'b10; hwrite <= 1; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0; hwrite <= 0; hwdata <= d;
        @(posedge hclk); hwdata <= 0;
    end
    endtask
    task rd(input [7:0] off, output [31:0] d);
    begin
        @(posedge hclk); haddr <= BASE | off; htrans <= 2'b10; hwrite <= 0; hsel <= 1;
        @(posedge hclk); htrans <= 0; hsel <= 0; haddr <= 0;
        #1 d = hrdata;
        @(posedge hclk);
    end
    endtask
    integer errors = 0;
    task check(input [255:0] what, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %0s: got %08x expected %08x @%0t", what, got, exp, $time);
            errors = errors + 1;
        end
    endtask

    // CMD bits
    localparam R_NONE = 0, R48 = 1 << 6, R136 = 2 << 6, CRC = 1 << 8, ICHK = 1 << 9, BUSY = 1 << 10,
               DATA = 1 << 11, WRITE = 1 << 12;
    localparam ST_CDONE = 1 << 8, ST_DDONE = 1 << 9, ST_CTMO = 1 << 10, ST_CCRC = 1 << 11, ST_CIDX = 1 << 12,
               ST_DTMO = 1 << 13, ST_DCRC = 1 << 14, ST_DEND = 1 << 15, ST_WST = 1 << 16, ST_DMA = 1 << 17,
               ST_FIFO = 1 << 18;
    reg [31:0] st, d;
    // issue a command and wait for completion (command + data); returns STATUS sticky bits
    task cmd(input [5:0] ix, input [31:0] a, input [31:0] flags, output [31:0] status);
        integer n;
        begin
            wr(R_STATUS, 32'h0007FF00);     // clear sticky
            wr(R_ARG, a);
            wr(R_CMD, {26'd0, ix} | flags);
            n = 0;
            status = 0;
            while (1) begin
                rd(R_STATUS, status);
                if (status & (ST_CTMO | ST_CCRC | ST_DTMO | ST_DCRC | ST_DEND | ST_WST | ST_DMA | ST_FIFO)) begin
                    // error: wait for the engines to stop
                    while (status[1:0] != 0) rd(R_STATUS, status);
                    disable cmd;
                end
                if ((status & ST_CDONE) && (!(flags & DATA) || (status & ST_DDONE))) disable cmd;
                n = n + 1;
                if (n > 4000000) begin $display("FAIL cmd %0d: no completion (status %08x)", ix, status); errors = errors + 1; disable cmd; end
                #200;
            end
        end
    endtask
    task app_cmd(input [5:0] ix, input [31:0] a, input [31:0] flags, output [31:0] status);
        begin
            cmd(6'd55, {rca, 16'd0}, R48 | CRC | ICHK, status);
            cmd(ix, a, flags, status);
        end
    endtask
    reg [15:0] rca = 0;
    integer i, k;
    reg [63:0] w;

    initial begin
        $dumpfile("tb_sdhost.vcd"); $dumpvars(0, tb_sdhost);
        // memory patterns: buffer A at 0x100000 (pattern), B at 0x120000 (zero)
        for (i = 0; i < 131072; i = i + 1) ddr[i] = 64'd0;
        for (i = 0; i < 2048; i = i + 1) ddr[i] = {8'(i*8+7), 8'(i*8+6), 8'(i*8+5), 8'(i*8+4), 8'(i*8+3), 8'(i*8+2), 8'(i*8+1), 8'(i*8)} ^ 64'h5A5A_0000_0000_0000;
        for (i = 0; i < card.MEM_BYTES; i = i + 1) card.mem[i] = i[7:0] ^ 8'hA5;
        repeat (5) @(posedge hclk); hresetn = 1; repeat (3) @(posedge hclk);

        rd(R_ID, d); check("ID", d, 32'h53444843);
        rd(R_STATUS, d); check("card inserted", d[2], 1'b1);
        wr(R_TMO, 32'd200000);
        wr(R_CTRL, 32'h0000_0201);      // clock on, div 2 (8.3 MHz) for the identification
        repeat (400) @(posedge hclk);

        // ---- identification like the MMC core ----
        cmd(6'd0, 0, R_NONE, st); check("CMD0 done", st & 32'h7FF00, ST_CDONE);
        cmd(6'd8, 32'h1AA, R48 | CRC | ICHK, st); check("CMD8 done", st & 32'h7FF00, ST_CDONE);
        rd(R_RESP0, d); check("CMD8 echo", d, 32'h1AA);
        for (k = 0; k < 3; k = k + 1) begin
            app_cmd(6'd41, 32'h40FF8000, R48, st);
            rd(R_RESP0, d);
            if (d[31]) k = 10;
        end
        check("ACMD41 ready", d, 32'hC0FF8000);
        cmd(6'd2, 0, R136, st); check("CMD2 done", st & 32'h7FF00, ST_CDONE);
        rd(R_RESP0, d); check("CID[127:96]", d, card.cid[127:96]);
        rd(R_RESP1, d); check("CID[95:64]", d, card.cid[95:64]);
        rd(R_RESP2, d); check("CID[63:32]", d, card.cid[63:32]);
        rd(R_RESP3, d); check("CID[31:0] (crc+end from the card)", d[31:8], card.cid[31:8]);
        cmd(6'd3, 0, R48 | CRC, st); rd(R_RESP0, d); rca = d[31:16]; check("RCA", rca, card.rca);
        cmd(6'd9, {rca, 16'd0}, R136, st); rd(R_RESP0, d); check("CSD[127:96]", d, card.csd[127:96]);
        cmd(6'd7, {rca, 16'd0}, R48 | CRC | ICHK | BUSY, st); check("CMD7 R1b done", st & 32'h7FF00, ST_CDONE);
        // SCR: 8-byte block in 1-bit mode via DMA to B
        wr(R_BLK, {16'd1, 4'd0, 12'd8}); wr(R_DMA, 32'h0012_0000);
        app_cmd(6'd51, 0, R48 | CRC | ICHK | DATA, st); check("ACMD51 done", st & 32'h7FF00, ST_CDONE | ST_DDONE);
        check("SCR word", ddr[32'h20000 >> 3], {card.scr[7:0], card.scr[15:8], card.scr[23:16], card.scr[31:24],
                                                 card.scr[39:32], card.scr[47:40], card.scr[55:48], card.scr[63:56]});
        // 4-bit
        app_cmd(6'd6, 2, R48 | CRC | ICHK, st); check("ACMD6 done", st & 32'h7FF00, ST_CDONE);
        wr(R_CTRL, 32'h0000_0003);      // div 0 = 25 MHz, 4-bit
        cmd(6'd16, 512, R48 | CRC | ICHK, st);

        // ---- 4-block write from A to card block 100, then read back into B ----
        wr(R_BLK, {16'd4, 4'd0, 12'd512}); wr(R_DMA, 32'h0010_0000);
        cmd(6'd25, 100, R48 | CRC | ICHK | DATA | WRITE, st); check("CMD25 done", st & 32'h7FF00, ST_CDONE | ST_DDONE);
        cmd(6'd12, 0, R48 | CRC | ICHK | BUSY, st); check("CMD12 done", st & 32'h7FF00, ST_CDONE);
        check("card got 4 blocks", card.blocks_written, 4);
        check("card CRC ok", card.crc_fail, 0);
        for (i = 0; i < 2048; i = i + 1) begin
            w = ddr[i >> 3];
            if (card.mem[100*512 + i] !== w[8 * (i & 7) +: 8]) begin
                if (errors < 4) $display("FAIL write byte %0d: card %02x ddr %02x", i, card.mem[100*512 + i], w[8 * (i & 7) +: 8]);
                errors = errors + 1;
            end
        end
        wr(R_BLK, {16'd4, 4'd0, 12'd512}); wr(R_DMA, 32'h0012_0000);
        cmd(6'd18, 100, R48 | CRC | ICHK | DATA, st); check("CMD18 done", st & 32'h7FF00, ST_CDONE | ST_DDONE);
        cmd(6'd12, 0, R48 | CRC | ICHK | BUSY, st); check("CMD12 after read", st & 32'h7FF00, ST_CDONE);
        for (i = 0; i < 256; i = i + 1) if (ddr[(32'h20000 >> 3) + i] !== ddr[i]) begin
            if (errors < 4) $display("FAIL readback word %0d: %016x vs %016x", i, ddr[(32'h20000 >> 3) + i], ddr[i]);
            errors = errors + 1;
        end
        // single block read of card block 7 (pattern) into B+0x1000
        wr(R_BLK, {16'd1, 4'd0, 12'd512}); wr(R_DMA, 32'h0012_1000);
        cmd(6'd17, 7, R48 | CRC | ICHK | DATA, st); check("CMD17 done", st & 32'h7FF00, ST_CDONE | ST_DDONE);
        for (i = 0; i < 64; i = i + 1) begin
            w = ddr[(32'h21000 >> 3) + i];
            for (k = 0; k < 8; k = k + 1) if (w[8*k +: 8] !== card.mem[7*512 + 8*i + k]) begin
                if (errors < 4) $display("FAIL CMD17 byte %0d", 8*i+k); errors = errors + 1;
            end
        end
        // 1-bit mode round trip of 2 blocks
        app_cmd(6'd6, 0, R48 | CRC | ICHK, st);
        wr(R_CTRL, 32'h0000_0001);
        wr(R_BLK, {16'd2, 4'd0, 12'd512}); wr(R_DMA, 32'h0010_0800);   // A + 2 KB
        cmd(6'd25, 300, R48 | CRC | ICHK | DATA | WRITE, st); check("1-bit CMD25 done", st & 32'h7FF00, ST_CDONE | ST_DDONE);
        cmd(6'd12, 0, R48 | CRC | ICHK | BUSY, st);
        wr(R_BLK, {16'd2, 4'd0, 12'd512}); wr(R_DMA, 32'h0013_0000);
        cmd(6'd18, 300, R48 | CRC | ICHK | DATA, st); check("1-bit CMD18 done", st & 32'h7FF00, ST_CDONE | ST_DDONE);
        cmd(6'd12, 0, R48 | CRC | ICHK | BUSY, st);
        for (i = 0; i < 128; i = i + 1) if (ddr[(32'h30000 >> 3) + i] !== ddr[256 + i]) begin
            if (errors < 4) $display("FAIL 1-bit readback word %0d", i); errors = errors + 1;
        end
        // ---- error paths ----
        app_cmd(6'd6, 2, R48 | CRC | ICHK, st); wr(R_CTRL, 32'h0000_0003);
        card.inject_crc = 1;
        wr(R_BLK, {16'd1, 4'd0, 12'd512}); wr(R_DMA, 32'h0012_1000);
        cmd(6'd17, 7, R48 | CRC | ICHK | DATA, st); check("injected CRC error flagged", st & ST_DCRC, ST_DCRC);
        cmd(6'd50, 0, R48 | CRC, st); check("response timeout flagged", st & ST_CTMO, ST_CTMO);
        rd(R_STATUS, d); check("engines idle after timeout", d[1:0], 2'b00);
        // and the host still works afterwards
        cmd(6'd13, {rca, 16'd0}, R48 | CRC | ICHK, st); check("CMD13 after errors", st & 32'h7FF00, ST_CDONE);
        rd(R_RESP0, d); check("CMD13 status", d, card.card_status);
        // interrupt line follows INT_EN
        wr(R_INTEN, 32'h0000_0100); rd(R_INTEN, d); check("INT_EN readback", d, 32'h100);
        check("irq asserted (cdone pending)", irq, 1'b1);
        wr(R_STATUS, 32'h0007FF00); #50; check("irq clear", irq, 1'b0);
        check("card saw no bad command CRC", card.cmd_crc_bad, 0);

        if (errors == 0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errors);
        $finish;
    end
endmodule
