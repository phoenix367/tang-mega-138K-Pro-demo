`timescale 1ns/1ps
`default_nettype none
//============================================================================
// tb_eth_core_multi.v -- sophisticated multi-frame tests on the full Ethernet
// core with the REAL Gowin TSE MAC (ref .vo + prim_sim) and RGMII wire-loopback.
// Same DUT wiring as tb_eth_core.v; the test sequence exercises:
//   PHASE 1/2 : stream NF frames of varied + odd (non-word-aligned) sizes through
//               4-deep rings, consuming NAPI-style -> ring WRAPAROUND + order +
//               byte-exact integrity under TX/RX arbiter contention.
//   PHASE 3   : overflow the RX ring without consuming -> ring-full DROP counting,
//               with the kept frames still intact.
//   PHASE 4   : after drops, consume + send more -> stream stays ALIGNED (the drop
//               path drained the data FIFO correctly).
//============================================================================
module tb_eth_core_multi;
    reg bus_clk = 0; always #10 bus_clk = ~bus_clk;   // 50 MHz
    reg gtx_clk = 0; always #4  gtx_clk = ~gtx_clk;   // 125 MHz (1000M)
    reg arst_n = 1;

    GSR GSR (.GSRI(1'b1));

    wire        rx_mac_clk, rx_mac_valid, rx_mac_last, rx_mac_error;
    wire [7:0]  rx_mac_data;
    wire        tx_mac_clk, tx_mac_valid, tx_mac_last, tx_mac_ready;
    wire [7:0]  tx_mac_data;
    wire [4:0]  miim_phyad, miim_regad;
    wire [15:0] miim_wrdata, miim_rddata;
    wire        miim_wren, miim_rden, miim_rddata_valid, miim_busy;
    wire [2:0]  eth_mode;
    wire        irq;

    wire        rgmii_txc, rgmii_tx_ctl;  wire [3:0] rgmii_txd;
    wire        rgmii_rxc;  assign #4 rgmii_rxc = rgmii_txc;   // RGMII-ID half-period RXC delay
    wire        rgmii_rx_ctl = rgmii_tx_ctl;
    wire [3:0]  rgmii_rxd  = rgmii_txd;
    integer txctl = 0, rxval = 0;
    always @(posedge rgmii_txc)  if (rgmii_tx_ctl === 1'b1) txctl = txctl + 1;
    always @(posedge rx_mac_clk) if (rx_mac_valid === 1'b1) rxval = rxval + 1;

    wire        speedis1000 = (eth_mode[1:0] == 2'b10);
    wire        speedis10   = (eth_mode[1:0] == 2'b00);
    wire        duplex_status = eth_mode[2];

    reg  [31:0] s_haddr = 0, s_hwdata = 0;  reg [1:0] s_htrans = 0;  reg s_hwrite = 0, s_hsel = 0;
    wire [31:0] s_hrdata;  wire s_hready, s_hresp;

    wire [31:0] m0_haddr, m1_haddr, m1_hwdata, m1_hrdata;
    wire [63:0] m0_hwdata, m0_hrdata;
    wire [1:0]  m0_htrans, m1_htrans;
    wire        m0_hwrite, m0_hready, m0_hresp, m0_busy, m1_hwrite, m1_hready, m1_hresp, m1_busy;
    wire [2:0]  m0_hsize, m0_hburst, m1_hsize, m1_hburst;
    wire [31:0] ah;
    wire [63:0] awd, ard;    // merged arbiter bus is 64-bit
     wire [1:0] at;  wire aw, ardy, ars, aact;  wire [2:0] asz, abt;
    wire [31:0] eh, ewd;  wire [63:0] e64wd, e64rd;  wire [1:0] et;  wire ew, ehsel, ehrdy_in, ehrdyout, ehresp;
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
    localparam RXB = 32'h00001000, TXB = 32'h00004000, RINGLEN = 4, NF = 8;

    // varied + odd (non-word-aligned) frame sizes, all >= 60 (no MAC padding)
    function integer fsize(input integer f);
        case (f) 0:fsize=64; 1:fsize=60; 2:fsize=96; 3:fsize=128;
                 4:fsize=100; 5:fsize=66; 6:fsize=144; 7:fsize=99; default:fsize=64; endcase
    endfunction
    // byte i of frame f: broadcast dst (0..5 = 0xFF) so the MAC RX accepts it, then a per-frame pattern
    function [7:0] fbyte(input integer f, input integer i);
        fbyte = (i < 6) ? 8'hFF : ((f*8'h25 + i*8'h07 + 8'h11) & 8'hFF);
    endfunction

    task ram_w32(input [31:0] a, input [31:0] v); dram.mem[a[15:3]][a[2]*32 +: 32] = v; endtask
    function [31:0] ram_r32(input [31:0] a); ram_r32 = dram.mem[a[15:3]][a[2]*32 +: 32]; endfunction

    task csr_w(input [31:0] addr, input [31:0] data);
        begin @(negedge bus_clk); s_haddr=addr; s_htrans=2'b10; s_hwrite=1; s_hsel=1;
              @(negedge bus_clk); s_haddr=0; s_htrans=0; s_hwrite=0; s_hsel=0; s_hwdata=data;
              @(negedge bus_clk); s_hwdata=0; end
    endtask

    // write frame f into its TX ring slot (f % RINGLEN)
    task tx_queue(input integer f);
        integer sz, w, j; reg [31:0] base, word;
        begin
            sz = fsize(f); base = TXB + (f % RINGLEN)*2048;
            ram_w32(base, sz);
            for (w=0; w*4 < sz; w=w+1) begin
                word = 0; for (j=0;j<4;j=j+1) if (w*4+j < sz) word[j*8 +: 8] = fbyte(f, w*4+j);
                ram_w32(base + 4 + w*4, word);
            end
        end
    endtask

    // check the RX ring slot (f % RINGLEN) holds frame f; returns mismatch count
    task rx_check(input integer f, output integer bad);
        integer sz, i; reg [31:0] base, hdr; reg [7:0] g;
        begin
            sz = fsize(f); base = RXB + (f % RINGLEN)*2048; bad = 0;
            hdr = ram_r32(base);
            if ((hdr & 32'hFFFF) != sz)  bad = bad + 1;
            if (hdr[16] !== 1'b0)         bad = bad + 1;   // err flag must be clear
            for (i=0;i<sz;i=i+1) begin
                g = ram_r32(base + 4 + (i/4)*4) >> ((i%4)*8);
                if (g !== fbyte(f,i)) bad = bad + 1;
            end
        end
    endtask

    task wait_rxhead(input integer target, output integer ok);
        integer k; begin ok=0; k=0;
            while (!ok && k<30000) begin @(posedge bus_clk); k=k+1;
                if (u_core.u_rx.rx_head >= target) ok=1; end end
    endtask
    task wait_txhead(input integer target, output integer ok);
        integer k; begin ok=0; k=0;
            while (!ok && k<30000) begin @(posedge bus_clk); k=k+1;
                if (u_core.u_tx.tx_head >= target) ok=1; end end
    endtask

    //------------------------------------------------------------------ tests
    integer sent, batch, b, bad, ok, total_bad, fails;
    integer h0, d0, dropn, kept_bad;
    initial begin
        total_bad = 0; fails = 0;
        #20 arst_n = 0; #600 arst_n = 1; repeat (40) @(posedge bus_clk);
        csr_w(32'h60, 32'd6);                                            // ETH_MODE = 1000M FD
        csr_w(32'h10, RXB); csr_w(32'h14, RINGLEN); csr_w(32'h18, 0);    // RX ring
        csr_w(32'h30, TXB); csr_w(32'h34, RINGLEN);                      // TX ring
        csr_w(32'h00, 32'h3);                                            // rx_en | tx_en

        // ===== PHASE 1/2: stream NF frames in RINGLEN batches, NAPI-consume (wrap) =====
        $display("== PHASE 1/2: stream %0d varied/odd-size frames with ring wrap ==", NF);
        sent = 0;
        while (sent < NF) begin
            batch = (NF - sent > RINGLEN) ? RINGLEN : (NF - sent);
            for (b=0;b<batch;b=b+1) tx_queue(sent+b);
            csr_w(32'h38, sent+batch);                                   // TX_TAIL (cumulative)
            wait_rxhead(sent+batch, ok);
            if (!ok) begin $display("   TIMEOUT waiting rx_head=%0d (got %0d)", sent+batch, u_core.u_rx.rx_head); fails=fails+1; end
            for (b=0;b<batch;b=b+1) begin
                rx_check(sent+b, bad); total_bad = total_bad + bad;
                $display("   frame %0d size %0d : %s", sent+b, fsize(sent+b), bad ? "FAIL" : "ok");
            end
            csr_w(32'h18, sent+batch);                                   // RX_TAIL = consume
            sent = sent + batch;
        end
        if (total_bad != 0) fails = fails + 1;
        $display("== PHASE 1/2 %s (mismatches=%0d, drop=%0d) ==\n", total_bad?"FAIL":"PASS", total_bad, u_core.u_rx.drop_cnt);

        // ===== PHASE 3: ring-full DROP (fill ring, send RINGLEN more without consuming) =====
        $display("== PHASE 3: ring-full drop ==");
        h0 = u_core.u_rx.rx_head; d0 = u_core.u_rx.drop_cnt;
        for (b=0;b<RINGLEN;b=b+1) tx_queue(sent+b);                      // batch A: fills the ring
        csr_w(32'h38, sent+RINGLEN);
        wait_rxhead(h0+RINGLEN, ok);
        wait_txhead(sent+RINGLEN, ok);                                   // TX slots free again
        for (b=0;b<RINGLEN;b=b+1) tx_queue(sent+RINGLEN+b);             // batch B: must all drop
        csr_w(32'h38, sent+2*RINGLEN);
        repeat (12000) @(posedge bus_clk);                              // let batch B arrive + drop
        dropn = u_core.u_rx.drop_cnt - d0;
        kept_bad = 0;
        for (b=0;b<RINGLEN;b=b+1) begin rx_check(sent+b, bad); kept_bad = kept_bad + bad; end
        $display("   rx_head=%0d (exp %0d)  drops=%0d (exp %0d)  kept-frames-intact=%s",
                 u_core.u_rx.rx_head, h0+RINGLEN, dropn, RINGLEN, kept_bad?"NO":"yes");
        if (u_core.u_rx.rx_head != h0+RINGLEN || dropn != RINGLEN || kept_bad != 0) fails = fails + 1;
        $display("== PHASE 3 %s ==\n", (u_core.u_rx.rx_head==h0+RINGLEN && dropn==RINGLEN && kept_bad==0)?"PASS":"FAIL");
        csr_w(32'h18, h0+RINGLEN);                                       // consume the kept frames
        sent = sent + 2*RINGLEN;

        // ===== PHASE 4: stream stayed ALIGNED after drops -> 2 more frames must be exact =====
        $display("== PHASE 4: alignment recovery after drops ==");
        h0 = u_core.u_rx.rx_head; bad = 0;
        for (b=0;b<2;b=b+1) tx_queue(sent+b);
        csr_w(32'h38, sent+2);
        wait_rxhead(h0+2, ok);
        if (!ok) begin $display("   TIMEOUT"); fails=fails+1; end
        for (b=0;b<2;b=b+1) begin rx_check(sent+b, bad); total_bad=total_bad+bad;
            if (bad) fails=fails+1; $display("   recovery frame %0d : %s", sent+b, bad?"FAIL":"ok"); end
        $display("== PHASE 4 %s ==\n", bad?"FAIL":"PASS");

        $display("RESULT: %s (txctl=%0d rxval=%0d total_mismatch=%0d phase_fails=%0d)",
                 fails ? "FAIL" : "PASS", txctl, rxval, total_bad, fails);
        $finish;
    end
    initial begin #20000000; $display("RESULT: FAIL (global timeout)"); $finish; end
endmodule
`default_nettype wire
