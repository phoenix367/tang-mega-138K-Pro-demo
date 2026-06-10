`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_eth_core_corner.v -- corner-case tests on the full Ethernet core with the
// REAL Gowin TSE MAC + RGMII loopback (same DUT as tb_eth_core).
//   TEST A : sub-60B payload -> MAC pads to the 60B min, RX length reflects it.
//   TEST B : full 1500B MTU frame -> byte-exact (whole frame must fit the RX data
//            FIFO before the writer drains it -- 375 words < 512-deep FIFO).
//   TEST C : FCS-error injection (corrupt a few RGMII nibbles mid-frame) -> the
//            corrupt frame must be flagged err=1 or dropped, never accepted clean,
//            and must NOT wedge the engine.
//============================================================================
module tb_eth_core_corner;
    reg bus_clk = 0; always #10 bus_clk = ~bus_clk;
    reg gtx_clk = 0; always #4  gtx_clk = ~gtx_clk;
    reg arst_n = 1;
    GSR GSR (.GSRI(1'b1));

    wire        rx_mac_clk, rx_mac_valid, rx_mac_last, rx_mac_error;
    wire [7:0]  rx_mac_data;
    wire        tx_mac_clk, tx_mac_valid, tx_mac_last, tx_mac_ready;
    wire [7:0]  tx_mac_data;
    wire [4:0]  miim_phyad, miim_regad;
    wire [15:0] miim_wrdata, miim_rddata;
    wire        miim_wren, miim_rden, miim_rddata_valid, miim_busy;
    wire [2:0]  eth_mode;  wire irq;

    // ---- RGMII loopback with mid-frame corruption injector (TEST C) ----
    wire        rgmii_txc, rgmii_tx_ctl;  wire [3:0] rgmii_txd;
    wire        rgmii_rxc;  assign #4 rgmii_rxc = rgmii_txc;
    wire        rgmii_rx_ctl = rgmii_tx_ctl;
    reg         corrupt_en = 0;  integer fpos = 0;  reg in_f = 0;
    always @(posedge rgmii_txc) begin
        if (rgmii_tx_ctl) begin if (!in_f) begin in_f<=1; fpos<=0; end else fpos<=fpos+1; end
        else in_f<=0;
    end
    wire        corrupt_now = corrupt_en && in_f && (fpos > 16) && (fpos < 21);
    wire [3:0]  rgmii_rxd = corrupt_now ? (rgmii_txd ^ 4'hF) : rgmii_txd;

    integer txctl = 0, rxval = 0;
    always @(posedge rgmii_txc)  if (rgmii_tx_ctl === 1'b1) txctl = txctl + 1;
    always @(posedge rx_mac_clk) if (rx_mac_valid === 1'b1) rxval = rxval + 1;

    wire speedis1000 = (eth_mode[1:0]==2'b10), speedis10 = (eth_mode[1:0]==2'b00), duplex_status = eth_mode[2];

    reg  [31:0] s_haddr=0, s_hwdata=0;  reg [1:0] s_htrans=0;  reg s_hwrite=0, s_hsel=0;
    wire [31:0] s_hrdata;  wire s_hready, s_hresp;

    wire [31:0] m0_haddr, m0_hwdata, m0_hrdata, m1_haddr, m1_hwdata, m1_hrdata;
    wire [1:0]  m0_htrans, m1_htrans;
    wire        m0_hwrite, m0_hready, m0_hresp, m0_busy, m1_hwrite, m1_hready, m1_hresp, m1_busy;
    wire [2:0]  m0_hsize, m0_hburst, m1_hsize, m1_hburst;
    wire [31:0] ah, awd, ard;  wire [1:0] at;  wire aw, ardy, ars, aact;  wire [2:0] asz, abt;
    wire [31:0] eh;  wire [63:0] e64wd, e64rd;  wire [1:0] et;  wire ew, ehsel, ehrdy_in, ehrdyout, ehresp;
    wire [2:0]  esz, ebt;  wire [3:0] eprot;
    wire [3:0]  dbg_extm = {ehresp, ehrdyout, et[1], ehsel};

    gw_eth_dma_core u_core (
        .rx_mac_clk(rx_mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .tx_mac_clk(tx_mac_clk), .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data),
        .tx_mac_last(tx_mac_last), .tx_mac_ready(tx_mac_ready),
        .bus_clk(bus_clk), .arst_n(arst_n),
        .s_haddr(s_haddr), .s_htrans(s_htrans), .s_hwrite(s_hwrite), .s_hsel(s_hsel),
        .s_hready_in(1'b1), .s_hwdata(s_hwdata), .s_hrdata(s_hrdata), .s_hready(s_hready), .s_hresp(s_hresp),
        .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite), .m0_hsize(m0_hsize),
        .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata), .m0_hrdata(m0_hrdata), .m0_hready(m0_hready),
        .m0_hresp(m0_hresp), .m0_busy(m0_busy),
        .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite), .m1_hsize(m1_hsize),
        .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata), .m1_hrdata(m1_hrdata), .m1_hready(m1_hready),
        .m1_hresp(m1_hresp), .m1_busy(m1_busy),
        .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
        .miim_wren(miim_wren), .miim_rden(miim_rden), .miim_rddata(miim_rddata),
        .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy),
        .irq(irq), .eth_mode(eth_mode), .dbg_extm(dbg_extm));

    mac u_mac (
        .rgmii_rxc(rgmii_rxc), .rgmii_rx_ctl(rgmii_rx_ctl), .rgmii_rxd(rgmii_rxd),
        .gtx_clk(gtx_clk), .speedis1000(speedis1000), .speedis10(speedis10), .duplex_status(duplex_status),
        .rstn(arst_n),
        .tx_mac_valid(tx_mac_valid), .tx_mac_data(tx_mac_data), .tx_mac_last(tx_mac_last), .tx_mac_error(1'b0),
        .rx_fcs_fwd_ena(1'b0), .rx_jumbo_ena(1'b0), .tx_fcs_fwd_ena(1'b0),
        .tx_ifg_delay_ena(1'b0), .tx_ifg_delay(8'b0),
        .tx_pause_req(1'b0), .tx_pause_val(16'b0), .tx_pause_source_addr(48'b0),
        .clk(bus_clk), .miim_phyad(miim_phyad), .miim_regad(miim_regad), .miim_wrdata(miim_wrdata),
        .miim_wren(miim_wren), .miim_rden(miim_rden), .mdio_in(1'b1),
        .rgmii_txc(rgmii_txc), .rgmii_tx_ctl(rgmii_tx_ctl), .rgmii_txd(rgmii_txd),
        .rx_mac_clk(rx_mac_clk), .rx_mac_valid(rx_mac_valid), .rx_mac_data(rx_mac_data),
        .rx_mac_last(rx_mac_last), .rx_mac_error(rx_mac_error),
        .rx_statistics_valid(), .rx_statistics_vector(),
        .tx_mac_clk(tx_mac_clk), .tx_mac_ready(tx_mac_ready), .tx_collision(), .tx_retransmit(),
        .tx_statistics_valid(), .tx_statistics_vector(), .rx_pause_req(), .rx_pause_val(),
        .miim_rddata(miim_rddata), .miim_rddata_valid(miim_rddata_valid), .miim_busy(miim_busy),
        .mdc(), .mdio_out(), .mdio_oen());

    eth_ahb_arbiter u_arb (.clk(bus_clk), .rstn(arst_n),
        .m0_busy(m0_busy), .m0_haddr(m0_haddr), .m0_htrans(m0_htrans), .m0_hwrite(m0_hwrite),
        .m0_hsize(m0_hsize), .m0_hburst(m0_hburst), .m0_hwdata(m0_hwdata),
        .m0_hrdata(m0_hrdata), .m0_hready(m0_hready), .m0_hresp(m0_hresp),
        .m1_busy(m1_busy), .m1_haddr(m1_haddr), .m1_htrans(m1_htrans), .m1_hwrite(m1_hwrite),
        .m1_hsize(m1_hsize), .m1_hburst(m1_hburst), .m1_hwdata(m1_hwdata),
        .m1_hrdata(m1_hrdata), .m1_hready(m1_hready), .m1_hresp(m1_hresp),
        .active(aact), .haddr(ah), .htrans(at), .hwrite(aw), .hsize(asz), .hburst(abt), .hwdata(awd),
        .hrdata(ard), .hready(ardy), .hresp(ars));

    extm_bridge u_br (.hclk(bus_clk), .hresetn(arst_n),
        .a_haddr(ah), .a_htrans(at), .a_hwrite(aw), .a_hsize(asz), .a_hburst(abt), .a_hwdata(awd),
        .a_active(aact), .a_hready_in(ehrdyout), .a_hrdata(ard), .a_hready(ardy), .a_hresp(ars),
        .extm_haddr(eh), .extm_htrans(et), .extm_hwrite(ew), .extm_hsize(esz), .extm_hburst(ebt),
        .extm_hprot(eprot), .extm_hwdata(e64wd), .extm_hsel(ehsel), .extm_hready(ehrdy_in),
        .extm_hrdata(e64rd), .extm_hreadyout(ehrdyout), .extm_hresp(ehresp));

    ahb_slave_ram64 #(.AW(13)) dram (.hclk(bus_clk), .hresetn(arst_n), .haddr(eh), .htrans(et),
        .hwrite(ew), .hsize(esz), .hburst(ebt), .hwdata(e64wd), .hsel(ehsel), .hready_in(ehrdy_in),
        .hrdata(e64rd), .hready(ehrdyout), .hresp(ehresp));

    //------------------------------------------------------------------ helpers
    localparam RXB = 32'h00001000, TXB = 32'h00004000, RINGLEN = 4;
    function [7:0] gen(input [7:0] seed, input integer i);
        gen = (i < 6) ? 8'hFF : ((seed + i*8'h03) & 8'hFF);   // broadcast dst, then pattern
    endfunction
    task ram_w32(input [31:0] a, input [31:0] v); dram.mem[a[15:3]][a[2]*32 +: 32] = v; endtask
    function [31:0] ram_r32(input [31:0] a); ram_r32 = dram.mem[a[15:3]][a[2]*32 +: 32]; endfunction
    function [31:0] rx_hdr(input integer slot);  rx_hdr = ram_r32(RXB + slot*2048); endfunction
    function [7:0]  rx_byte(input integer slot, input integer i);
        rx_byte = ram_r32(RXB + slot*2048 + 4 + (i/4)*4) >> ((i%4)*8); endfunction

    task csr_w(input [31:0] addr, input [31:0] data);
        begin @(negedge bus_clk); s_haddr=addr; s_htrans=2'b10; s_hwrite=1; s_hsel=1;
              @(negedge bus_clk); s_haddr=0; s_htrans=0; s_hwrite=0; s_hsel=0; s_hwdata=data;
              @(negedge bus_clk); s_hwdata=0; end
    endtask
    task tx_write(input integer slot, input integer sz, input [7:0] seed);
        integer w,j; reg [31:0] base, word;
        begin base = TXB + slot*2048; ram_w32(base, sz);
            for (w=0; w*4<sz; w=w+1) begin word=0;
                for (j=0;j<4;j=j+1) if (w*4+j<sz) word[j*8 +: 8]=gen(seed,w*4+j);
                ram_w32(base+4+w*4, word); end
        end
    endtask
    task wait_rxhead(input integer target, output integer ok);
        integer k; begin ok=0; k=0;
            while (!ok && k<40000) begin @(posedge bus_clk); k=k+1;
                if (u_core.u_rx.rx_head >= target) ok=1; end end
    endtask

    integer i, ok, len, bad, fails, tq;  reg errflag;
    initial begin
        fails = 0; tq = 0;
        #20 arst_n=0; #600 arst_n=1; repeat (40) @(posedge bus_clk);
        csr_w(32'h60, 32'd6);
        csr_w(32'h10, RXB); csr_w(32'h14, RINGLEN); csr_w(32'h18, 0);
        csr_w(32'h30, TXB); csr_w(32'h34, RINGLEN);
        csr_w(32'h00, 32'h3);

        // ===== TEST A: sub-60 payload -> padded to 60 =====
        $display("== TEST A: 20B payload -> MAC pads to 60 ==");
        tx_write(0, 20, 8'hA0); tq=tq+1; csr_w(32'h38, tq);
        wait_rxhead(tq, ok);
        len = rx_hdr(0) & 32'hFFFF; bad = 0;
        if (!ok)        begin bad=bad+1; $display("   TIMEOUT"); end
        if (len != 60)  bad=bad+1;
        for (i=0;i<20;i=i+1) if (rx_byte(0,i) !== gen(8'hA0,i)) bad=bad+1;     // my 20 bytes
        for (i=20;i<60;i=i+1) if (rx_byte(0,i) !== 8'h00) bad=bad+1;           // zero pad
        $display("   RX len=%0d (exp 60), payload+pad %s", len, bad?"MISMATCH":"ok");
        if (bad) fails=fails+1;
        $display("== TEST A %s ==\n", bad?"FAIL":"PASS");
        csr_w(32'h18, tq);

        // ===== TEST B: full 1500B MTU frame, byte-exact =====
        $display("== TEST B: 1500B MTU frame ==");
        tx_write(1, 1500, 8'hB7); tq=tq+1; csr_w(32'h38, tq);
        wait_rxhead(tq, ok);
        len = rx_hdr(1) & 32'hFFFF; bad = 0;
        if (!ok)         begin bad=bad+1; $display("   TIMEOUT (FIFO too small? rx_head=%0d)", u_core.u_rx.rx_head); end
        if (len != 1500) bad=bad+1;
        for (i=0;i<1500;i=i+1) if (rx_byte(1,i) !== gen(8'hB7,i)) bad=bad+1;
        $display("   RX len=%0d (exp 1500), data %s", len, bad?"MISMATCH":"byte-exact");
        if (bad) fails=fails+1;
        $display("== TEST B %s ==\n", bad?"FAIL":"PASS");
        csr_w(32'h18, tq);

        // ===== TEST C: FCS-error injection =====
        $display("== TEST C: corrupt a frame's RGMII data mid-flight ==");
        corrupt_en = 1;
        tx_write(2, 64, 8'hC5); tq=tq+1; csr_w(32'h38, tq);
        wait_rxhead(tq, ok);
        corrupt_en = 0;
        if (!ok) begin
            $display("   corrupt frame DROPPED by MAC (rx_head stayed %0d) -> PASS (not accepted, no wedge)",
                     u_core.u_rx.rx_head);
        end else begin
            errflag = rx_hdr(2) >> 16;
            $display("   corrupt frame delivered: err=%b -> %s", errflag,
                     errflag ? "PASS (flagged)" : "FAIL (bad FCS accepted as good!)");
            if (!errflag) fails=fails+1;
        end
        // prove no wedge: a clean frame after the corrupt one must still work
        csr_w(32'h18, u_core.u_rx.rx_head);     // consume whatever landed
        tx_write(3, 64, 8'hD9); tq=tq+1; csr_w(32'h38, tq);
        wait_rxhead(u_core.u_rx.rx_head+1, ok); bad = (!ok);
        for (i=0;i<64;i=i+1) if (rx_byte(3,i) !== gen(8'hD9,i)) bad=bad+1;
        $display("   post-corrupt clean frame: %s", bad?"FAIL (engine wedged/garbled)":"ok");
        if (bad) fails=fails+1;
        $display("== TEST C %s ==\n", bad?"FAIL":"PASS");

        $display("RESULT: %s (phase_fails=%0d txctl=%0d rxval=%0d)", fails?"FAIL":"PASS", fails, txctl, rxval);
        $finish;
    end
    initial begin #30000000; $display("RESULT: FAIL (global timeout)"); $finish; end
endmodule
`default_nettype wire
