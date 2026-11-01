`default_nettype none
//============================================================================
// sdspi_core.v -- SPI master for the microSD slot (card in SPI mode).
//
// AHB-lite slave on EXTS (CPU base 0xE8010000, HADDR[16], 8 KB window),
// zero-wait: the address is sampled in the address phase and data (register
// or buffer RAM) is presented in the data phase.  Linux drives it with a
// generic spi_controller driver (spi-gowin) under the mainline mmc_spi host,
// so the SD protocol itself lives in the kernel's MMC stack.
//
// Transfer model: the CPU fills the 2 KB TX buffer, writes the byte count to
// LEN; the engine clocks that many bytes out of the TX buffer (MOSI) while
// capturing MISO into the 2 KB RX buffer; STATUS.busy drops when done.  SPI
// mode 0 (CPOL 0, CPHA 0), MSB first; SCK = bus clock / (2 * (DIV + 1)):
// DIV 0 = 25 MHz, DIV 62 = 397 kHz (card initialisation).  Chip select is a
// plain register bit so the host can hold it across several transfers.
//
// Pins (Dock J19, sheet FPGA_STORAGE): SCK = SDIO.CLK D23, MOSI = SDIO.CMD
// D24, MISO = SDIO.DAT0 H23, CS_N = SDIO.DAT3 B25, card detect SDIO.DET J15
// (0 = card inserted); DAT1/DAT2 unused, pulled up on the Dock.
//
// Register map (byte offset, 32-bit accesses):
//   0x0000 CTRL    rw  [0] CS_N level (reset 1 = deasserted)  [15:8] DIV
//                      [16] discard RX (block writes: do not fill RX buffer)
//                      [17] sample MISO on the rising SCK edge (reset 0 = on
//                      the falling edge, i.e. a full period after the card
//                      drove the bit: the card's 14 ns output delay plus the
//                      board exceeds the 20 ns half period at 25 MHz)
//   0x0004 STATUS  ro  [0] busy  [1] card inserted  [27:16] bytes of last LEN
//   0x0008 LEN     wo  byte count 1..2048, writing starts the transfer
//   0x000C ID      ro  0x53445350 ("SDSP")
//   0x0800-0x0FFF  TX buffer (2 KB, little-endian words: byte 0 goes first)
//   0x1000-0x17FF  RX buffer (2 KB, same layout)
//============================================================================
module sdspi_core #(
    parameter integer BUS_MHZ = 50
) (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB-lite slave
    input  wire [31:0] s_haddr,
    input  wire [1:0]  s_htrans,
    input  wire        s_hwrite,
    input  wire        s_hsel,
    input  wire        s_hready_in,
    input  wire [31:0] s_hwdata,
    output wire [31:0] s_hrdata,
    output wire        s_hready,
    output wire        s_hresp,
    // SPI / card
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,
    input  wire        sd_det_n
);
    assign s_hready = 1'b1;
    assign s_hresp  = 1'b0;

    // ---- buffers ----------------------------------------------------------
    reg [31:0] tx_mem [0:511];          // 2 KB, CPU writes / engine reads
    reg [7:0]  rx_mem0 [0:511];         // 2 KB as four byte lanes, engine
    reg [7:0]  rx_mem1 [0:511];         //   writes one lane at a time, CPU
    reg [7:0]  rx_mem2 [0:511];         //   reads a word
    reg [7:0]  rx_mem3 [0:511];

    // ---- registers / AHB --------------------------------------------------
    reg        a_sel, a_wr;
    reg [1:0]  a_region;                 // 0 regs, 1 tx, 2 rx
    reg [8:0]  a_word;
    reg [3:0]  a_off;
    wire       a_active = s_hsel && s_hready_in && s_htrans[1];
    reg        cs_n, rx_discard, smp_rise;
    reg [7:0]  div;
    reg [11:0] len_q;
    reg        busy, start;
    reg [2:0]  det_sync;
    wire       card_in = ~det_sync[2];
    assign spi_cs_n = cs_n;

    reg [31:0] rd_reg;                   // register value, data phase
    reg [31:0] rx_rd;                    // RX buffer word, data phase
    reg [7:0]  rx_q0, rx_q1, rx_q2, rx_q3;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_sel <= 1'b0; a_wr <= 1'b0; a_region <= 2'd0; a_word <= 9'd0; a_off <= 4'd0;
            cs_n <= 1'b1; rx_discard <= 1'b0; smp_rise <= 1'b0; div <= 8'd62; len_q <= 12'd0; start <= 1'b0;
            rd_reg <= 32'd0; det_sync <= 3'b111;
        end else begin
            det_sync <= {det_sync[1:0], sd_det_n};
            start <= 1'b0;
            // address phase: sample address, read registers / RX RAM
            a_sel <= a_active; a_wr <= s_hwrite;
            a_region <= s_haddr[12:11]; a_word <= s_haddr[10:2]; a_off <= s_haddr[5:2];
            case (s_haddr[5:2])
                4'h0: rd_reg <= {14'd0, smp_rise, rx_discard, div, 7'd0, cs_n};
                4'h1: rd_reg <= {4'd0, len_q, 14'd0, card_in, busy};
                4'h2: rd_reg <= {20'd0, len_q};
                4'h3: rd_reg <= 32'h5344_5350;
                default: rd_reg <= 32'd0;
            endcase
            rx_q0 <= rx_mem0[s_haddr[10:2]];
            rx_q1 <= rx_mem1[s_haddr[10:2]];
            rx_q2 <= rx_mem2[s_haddr[10:2]];
            rx_q3 <= rx_mem3[s_haddr[10:2]];
            // data phase: writes
            if (a_sel && a_wr) begin
                if (a_region == 2'd0) begin
                    case (a_off)
                        4'h0: begin cs_n <= s_hwdata[0]; div <= s_hwdata[15:8]; rx_discard <= s_hwdata[16]; smp_rise <= s_hwdata[17]; end
                        4'h2: if (!busy && s_hwdata[11:0] != 12'd0) begin
                                  len_q <= s_hwdata[11:0]; start <= 1'b1;
                              end
                        default: ;
                    endcase
                end
            end
        end
    end
    always @(posedge hclk)
        if (a_sel && a_wr && a_region == 2'd1) tx_mem[a_word] <= s_hwdata;

    always @(*) begin
        case (a_region)
            2'd0:    rx_rd = rd_reg;
            2'd2:    rx_rd = {rx_q3, rx_q2, rx_q1, rx_q0};
            default: rx_rd = 32'd0;      // TX buffer is write-only
        endcase
    end
    assign s_hrdata = rx_rd;

    // ---- SPI engine -------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_LOAD2 = 3'd2, S_BIT = 3'd3, S_DONE = 3'd4;
    reg [2:0]  st;
    reg [11:0] idx;                      // byte index
    reg [2:0]  bit_n;
    reg [7:0]  div_cnt;
    reg [31:0] tx_word;
    reg [7:0]  sh_out, sh_in;
    reg        miso_s;
    wire       tick = (div_cnt == div);
    wire [8:0] tx_addr = idx[10:2];
    reg  [31:0] tx_q;
    always @(posedge hclk) tx_q <= tx_mem[tx_addr];

    // byte lane select for the current byte
    wire [7:0] cur_byte = idx[1:0] == 2'd0 ? tx_word[7:0]  : idx[1:0] == 2'd1 ? tx_word[15:8] :
                          idx[1:0] == 2'd2 ? tx_word[23:16] : tx_word[31:24];

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            st <= S_IDLE; busy <= 1'b0; idx <= 12'd0; bit_n <= 3'd7; div_cnt <= 8'd0;
            spi_sck <= 1'b0; spi_mosi <= 1'b1; sh_out <= 8'hFF; sh_in <= 8'd0; tx_word <= 32'd0; miso_s <= 1'b1;
        end else begin
            miso_s <= spi_miso;
            case (st)
                S_IDLE: begin
                    spi_sck <= 1'b0;
                    if (start) begin busy <= 1'b1; idx <= 12'd0; st <= S_LOAD; end
                end
                S_LOAD:  st <= S_LOAD2;                        // tx_q <= tx_mem[idx]
                S_LOAD2: begin
                    tx_word <= tx_q;
                    // present bit 7 of the byte (MOSI changes while SCK is low)
                    sh_out <= idx[1:0] == 2'd0 ? tx_q[7:0]  : idx[1:0] == 2'd1 ? tx_q[15:8] :
                              idx[1:0] == 2'd2 ? tx_q[23:16] : tx_q[31:24];
                    spi_mosi <= idx[1:0] == 2'd0 ? tx_q[7] : idx[1:0] == 2'd1 ? tx_q[15] :
                                idx[1:0] == 2'd2 ? tx_q[23] : tx_q[31];
                    bit_n <= 3'd7; div_cnt <= 8'd0; st <= S_BIT;
                end
                S_BIT: begin
                    if (tick) begin
                        div_cnt <= 8'd0;
                        if (!spi_sck) begin
                            spi_sck <= 1'b1;                   // rising edge
                            if (smp_rise) sh_in <= {sh_in[6:0], spi_miso};
                        end else begin
                            spi_sck <= 1'b0;                   // falling edge: sample (late), next bit out
                            if (!smp_rise) sh_in <= {sh_in[6:0], spi_miso};
                            if (bit_n == 3'd0) begin
                                st <= S_DONE;
                            end else begin
                                bit_n <= bit_n - 3'd1;
                                sh_out <= {sh_out[6:0], 1'b1};
                                spi_mosi <= sh_out[6];
                            end
                        end
                    end else
                        div_cnt <= div_cnt + 8'd1;
                end
                S_DONE: begin
                    // byte complete: store, advance
                    if (idx + 12'd1 == len_q) begin
                        st <= S_IDLE; busy <= 1'b0; spi_mosi <= 1'b1;
                    end else begin
                        idx <= idx + 12'd1;
                        st <= S_LOAD;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // RX byte store (one lane per byte)
    wire rx_we = (st == S_DONE) && !rx_discard;
    always @(posedge hclk) begin
        if (rx_we && idx[1:0] == 2'd0) rx_mem0[idx[10:2]] <= sh_in;
        if (rx_we && idx[1:0] == 2'd1) rx_mem1[idx[10:2]] <= sh_in;
        if (rx_we && idx[1:0] == 2'd2) rx_mem2[idx[10:2]] <= sh_in;
        if (rx_we && idx[1:0] == 2'd3) rx_mem3[idx[10:2]] <= sh_in;
    end
endmodule
`default_nettype wire
