`default_nettype none
//============================================================================
// csr.v -- AHB-lite slave register block (EXTS port, CPU base 0xE8000000).
//
// Zero-wait slave: capture the address phase, service the data phase next cycle.
// Register map (byte offset):
//   0x00 CTRL      rw  [0]rx_en [1]tx_en
//   0x04 IRQ_STAT  w1c [0]rx_done [1]tx_done   (write 1 to clear)
//   0x08 IRQ_EN    rw
//   0x10 RX_BASE   rw  physical base of the RX ring buffers
//   0x14 RX_LEN    rw  [15:0] number of buffers (power of two)
//   0x18 RX_TAIL   rw  [15:0] frames consumed by the CPU
//   0x1C RX_HEAD   ro  [15:0] frames written by the DMA
//   0x20 RX_DROP   ro  [15:0]
//   0x30 TX_BASE   rw
//   0x34 TX_LEN    rw  [15:0]
//   0x38 TX_TAIL   rw  [15:0] frames queued by the CPU
//   0x3C TX_HEAD   ro  [15:0] frames transmitted
//   0x40 TX_FETCH  ro  [15:0]
//   0x50 MDIO_ADDR rw  [4:0]phyad [9:5]regad
//   0x54 MDIO_WD   rw  [15:0] write data
//   0x58 MDIO_CTRL w   [0]->read pulse  [1]->write pulse
//   0x5C MDIO_ST   ro  [15:0]rddata [16]rd_valid [17]busy
//   0x60 ETH_MODE  rw  [2:0] speed/duplex (driven to the MAC)
//============================================================================
module csr (
    // AHB-lite slave (EXTS)
    input  wire        hclk,
    input  wire        hresetn,
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire        hsel,
    input  wire        hready_in,
    input  wire [31:0] hwdata,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,
    // RX config / status
    output reg         rx_en,
    output reg  [31:0] rx_base,
    output reg  [15:0] rx_ring_len,
    output reg  [15:0] rx_tail,
    input  wire [15:0] rx_head,
    input  wire [15:0] rx_drop,
    // TX config / status
    output reg         tx_en,
    output reg  [31:0] tx_base,
    output reg  [15:0] tx_ring_len,
    output reg  [15:0] tx_tail,
    input  wire [15:0] tx_head,
    input  wire [15:0] tx_fetch,
    // IRQ
    input  wire        rx_irq_set,      // 1-cycle pulse per RX frame
    input  wire        tx_irq_set,      // 1-cycle pulse per TX frame
    output wire        irq,
    // MDIO (to the MAC management block)
    output reg  [4:0]  miim_phyad,
    output reg  [4:0]  miim_regad,
    output reg  [15:0] miim_wrdata,
    output reg         miim_wren,
    output reg         miim_rden,
    input  wire [15:0] miim_rddata,
    input  wire        miim_rddata_valid,
    input  wire        miim_busy,
    // MAC mode
    output reg  [2:0]  eth_mode,
    // debug: per-direction AHB master activity (EXTM bring-up)
    input  wire        rx_busy,
    input  wire        tx_busy,
    input  wire        rx_done,         // ahb_master cmd_done pulse (RX)
    input  wire        tx_done,         // ahb_master cmd_done pulse (TX)
    input  wire [3:0]  dbg_extm         // EXTM handshake {hresp,hreadyout,htrans1,hsel}
);
    assign hready = 1'b1;
    assign hresp  = 1'b0;

    reg [15:0] rx_done_cnt, tx_done_cnt;

    // address-phase capture
    reg [5:0] a_off;
    reg       a_wr, a_sel;
    wire      a_active = hsel && hready_in && htrans[1];

    reg [1:0]  irq_stat, irq_en;
    reg [15:0] mdio_rdata;
    reg        mdio_rvalid;

    // write decode + status capture
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off<=0; a_wr<=0; a_sel<=0;
            rx_en<=0; rx_base<=0; rx_ring_len<=0; rx_tail<=0;
            tx_en<=0; tx_base<=0; tx_ring_len<=0; tx_tail<=0;
            irq_stat<=0; irq_en<=0; eth_mode<=0;
            miim_phyad<=0; miim_regad<=0; miim_wrdata<=0; miim_wren<=0; miim_rden<=0;
            mdio_rdata<=0; mdio_rvalid<=0;
            rx_done_cnt<=0; tx_done_cnt<=0;
        end else begin
            a_off <= haddr[7:2]; a_wr <= hwrite; a_sel <= a_active;
            miim_wren <= 1'b0; miim_rden <= 1'b0;     // pulses

            // debug: count completed AHB master transactions per direction
            if (rx_done) rx_done_cnt <= rx_done_cnt + 16'd1;
            if (tx_done) tx_done_cnt <= tx_done_cnt + 16'd1;

            // latch IRQ sources
            if (rx_irq_set) irq_stat[0] <= 1'b1;
            if (tx_irq_set) irq_stat[1] <= 1'b1;
            // capture MDIO read result
            if (miim_rddata_valid) begin mdio_rdata <= miim_rddata; mdio_rvalid <= 1'b1; end

            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00:    begin rx_en <= hwdata[0]; tx_en <= hwdata[1]; end          // 0x00
                    6'h01:    irq_stat <= irq_stat & ~hwdata[1:0];                        // 0x04 W1C
                    6'h02:    irq_en <= hwdata[1:0];                                      // 0x08
                    6'h04:    rx_base <= hwdata;                                          // 0x10
                    6'h05:    rx_ring_len <= hwdata[15:0];                                // 0x14
                    6'h06:    rx_tail <= hwdata[15:0];                                    // 0x18
                    6'h0C:    tx_base <= hwdata;                                          // 0x30
                    6'h0D:    tx_ring_len <= hwdata[15:0];                                // 0x34
                    6'h0E:    tx_tail <= hwdata[15:0];                                    // 0x38
                    6'h14:    { miim_regad, miim_phyad } <= hwdata[9:0];                  // 0x50
                    6'h15:    miim_wrdata <= hwdata[15:0];                                // 0x54
                    6'h16:    begin miim_rden <= hwdata[0]; miim_wren <= hwdata[1];       // 0x58
                              if (hwdata[0]) mdio_rvalid <= 1'b0; end
                    6'h18:    eth_mode <= hwdata[2:0];                                    // 0x60
                    default:  ;
                endcase
            end
        end
    end

    // read mux (combinational from the captured offset)
    reg [31:0] rd;
    always @(*) begin
        case (a_off)
            6'h00: rd = {30'b0, tx_en, rx_en};
            6'h01: rd = {30'b0, irq_stat};
            6'h02: rd = {30'b0, irq_en};
            6'h04: rd = rx_base;
            6'h05: rd = {16'b0, rx_ring_len};
            6'h06: rd = {16'b0, rx_tail};
            6'h07: rd = {16'b0, rx_head};
            6'h08: rd = {16'b0, rx_drop};
            6'h0C: rd = tx_base;
            6'h0D: rd = {16'b0, tx_ring_len};
            6'h0E: rd = {16'b0, tx_tail};
            6'h0F: rd = {16'b0, tx_head};
            6'h10: rd = {16'b0, tx_fetch};
            6'h14: rd = {22'b0, miim_regad, miim_phyad};
            6'h15: rd = {16'b0, miim_wrdata};
            6'h17: rd = {14'b0, miim_busy, mdio_rvalid, mdio_rdata};
            6'h18: rd = {29'b0, eth_mode};
            6'h1C: rd = {tx_done_cnt, 15'b0, tx_busy};   // 0x70 TX_DBG
            6'h1D: rd = {rx_done_cnt, 15'b0, rx_busy};   // 0x74 RX_DBG
            6'h1E: rd = {28'b0, dbg_extm};               // 0x78 EXTM_DBG
            default: rd = 32'h0;
        endcase
    end
    assign hrdata = rd;

    assign irq = |(irq_stat & irq_en);
endmodule
`default_nettype wire
