`default_nettype none
//============================================================================
// gpio_core.v -- a plain data/direction register pair for board-control pins.
//
// AHB-lite slave on EXTS (CPU base 0xE8010000, zero-wait, same scheme as
// fan_core.v).  Linux drives it with the generic gpio-mmio driver
// ("wd,mbl-gpio": one "dat" and one "dirout" register), so there is no
// board-specific kernel driver; i2c-gpio bit-bangs the Dock's SYS_TWI bus on
// two of the lines, i2c-mux-gpio steers the Dock's 8-way TWI mux with three
// more, and the at24 EEPROM driver holds the write-protect line.
//
// Pin assignment on the Tang Mega 138K Pro Dock (see ae350_demo.cst):
//   bit 0  SYS_TWI SCL        K25   (2.2k pull-up on the Dock)
//   bit 1  SYS_TWI SDA        K26   (2.2k pull-up on the Dock)
//   bit 2  TWI mux SEL0       N19   74HC4051 x2; channel 2 = the ZD24C08A
//   bit 3  TWI mux SEL1       P19   EEPROM (1 KB, I2C 0x50..0x53), 3 = DVI-A
//   bit 4  TWI mux SEL2       P26   DDC, 4 = DVI-B DDC, 0/1 SFP, 5 camera,
//                                   6/7 MIPI RX; mux idles on channel 2
//   bit 5  EEPROM WP          V14   high = write protected
//
// Register map (byte offset, 32-bit accesses):
//   0x00 DAT     rw  write: output latch; read: pin levels (2-FF synchronised)
//   0x04 DIROUT  rw  1 = drive the pin from DAT, 0 = high-Z (reset 0: all inputs,
//                    so SCL/SDA rest on their pull-ups and the EEPROM's WP floats)
//   0x08 ID      ro  0x4750494F ("GPIO")
//   0x0C NGPIO   ro  number of lines
//============================================================================
module gpio_core #(
    parameter integer N = 6
) (
    input  wire         hclk,
    input  wire         hresetn,
    // AHB-lite slave
    input  wire [31:0]  s_haddr,
    input  wire [1:0]   s_htrans,
    input  wire         s_hwrite,
    input  wire         s_hsel,
    input  wire         s_hready_in,
    input  wire [31:0]  s_hwdata,
    output wire [31:0]  s_hrdata,
    output wire         s_hready,
    output wire         s_hresp,
    // pins (tri-stated at the top level: pin = oe ? o : 1'bz)
    input  wire [N-1:0] gpio_i,
    output reg  [N-1:0] gpio_o,
    output reg  [N-1:0] gpio_oe
);
    assign s_hready = 1'b1;
    assign s_hresp  = 1'b0;

    reg  [3:0]   a_off;
    reg          a_wr, a_sel;
    wire         a_active = s_hsel && s_hready_in && s_htrans[1];
    reg  [N-1:0] in_meta, in_sync;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off <= 4'd0; a_wr <= 1'b0; a_sel <= 1'b0;
            gpio_o <= {N{1'b0}}; gpio_oe <= {N{1'b0}};
            in_meta <= {N{1'b1}}; in_sync <= {N{1'b1}};
        end else begin
            in_meta <= gpio_i;
            in_sync <= in_meta;
            a_off <= s_haddr[5:2]; a_wr <= s_hwrite; a_sel <= a_active;
            if (a_sel && a_wr) begin
                case (a_off)
                    4'h0: gpio_o  <= s_hwdata[N-1:0];
                    4'h1: gpio_oe <= s_hwdata[N-1:0];
                    default: ;
                endcase
            end
        end
    end

    reg [31:0] rd;
    always @(*) begin
        rd = 32'd0;
        case (a_off)
            4'h0: rd[N-1:0] = in_sync;
            4'h1: rd[N-1:0] = gpio_oe;
            4'h2: rd = 32'h4750494F;
            4'h3: rd = N;
            default: rd = 32'd0;
        endcase
    end
    assign s_hrdata = rd;
endmodule
`default_nettype wire
