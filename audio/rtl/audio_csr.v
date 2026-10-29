`default_nettype none
//============================================================================
// audio_csr.v -- AHB-lite slave register block of the PT8211 audio core
// (EXTS port, CPU base 0xE8002000).  Zero-wait: capture the address phase,
// service the data phase next cycle (same scheme as video/rtl/video_csr.v).
//
// Register map (byte offset):
//   0x00 CTRL      rw  [0] enable (serialiser pops frames; an empty FIFO
//                          outputs zeros and counts underruns)
//                      [1] irq enable
//                      [2] FIFO reset (self-clearing, reads 0): empties the
//                          FIFO and clears FRAMES / UNDERRUN / OVERRUN / CRC
//                      [3] swap channels (DATA's low half goes out second)
//                      [4] stop when empty: a frame start that finds the FIFO
//                          empty clears [0] instead of counting an underrun
//                          (the driver sets it once it has pushed the last
//                          frame of a stream, so UNDERRUN only counts gaps
//                          inside a stream)
//                      [5] headphone amplifier enable (PA_EN pin, XPT4809 EN;
//                          resets to 1 = on, as Sipeed's example; the driver
//                          keeps it set, it is not toggled per stream)
//   0x04 STATUS    ro  [15:0] FIFO level in frames  [16] level < THRESH
//                      [17] FIFO full
//   0x08 DATA      wo  one stereo frame {R[15:0], L[15:0]} per 32-bit write
//                      (S16_LE interleaved as in memory); dropped + counted in
//                      OVERRUN when the FIFO is full
//   0x0C THRESH    rw  [15:0] irq (level type) while level < THRESH
//   0x10 RATE      rw  NCO increment: BCK = RATE / 2^32 * bus clock,
//                      frame rate = BCK / 32   (48 kHz @ 50 MHz: 131941395)
//   0x14 UNDERRUN  ro  frames of zeros sent because the FIFO was empty
//   0x18 OVERRUN   ro  DATA writes dropped because the FIFO was full
//   0x1C FRAMES    ro  frames taken from the FIFO and sent (since FIFO reset)
//   0x20 CRC       ro  zlib CRC-32 of those frames' bytes (L lo, L hi, R lo,
//                      R hi -- the bytes of a WAV data chunk), since FIFO reset
//   0x24 DEPTH     ro  FIFO capacity in frames
//   0x2C ID        ro  0x41554430 ("AUD0")
// Only 32-bit accesses are meaningful (HSIZE is ignored).
//============================================================================
module audio_csr (
    input  wire        hclk,
    input  wire        hresetn,
    // AHB-lite slave
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire        hsel,
    input  wire        hready_in,
    input  wire [31:0] hwdata,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,
    // control
    output reg         enable,
    output reg         irq_en,
    output reg         fifo_rst,      // one-cycle pulse
    output reg         lr_swap,
    output reg         stop_empty,
    output reg         amp_en,
    input  wire        enable_clr,    // from the serialiser: stop_empty hit
    output reg  [15:0] thresh,
    output reg  [31:0] rate,
    output wire        data_wr,       // one-cycle pulse, frame on data
    output wire [31:0] data,
    // status
    input  wire [15:0] level,
    input  wire        irq_cond,
    input  wire        full,
    input  wire [15:0] depth,
    input  wire [31:0] underruns,
    input  wire [31:0] overruns,
    input  wire [31:0] frames,
    input  wire [31:0] crc
);
    assign hready = 1'b1;
    assign hresp  = 1'b0;

    reg  [5:0] a_off;
    reg        a_wr, a_sel;
    wire       a_active = hsel && hready_in && htrans[1];

    assign data_wr = a_sel && a_wr && (a_off == 6'h02);
    assign data    = hwdata;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            a_off <= 0; a_wr <= 0; a_sel <= 0;
            enable <= 0; irq_en <= 0; fifo_rst <= 0; lr_swap <= 0; stop_empty <= 0;
            amp_en <= 1'b1; thresh <= 0; rate <= 32'd131941395;
        end else begin
            a_off <= haddr[7:2]; a_wr <= hwrite; a_sel <= a_active;
            fifo_rst <= 1'b0;
            if (enable_clr) enable <= 1'b0;
            if (a_sel && a_wr) begin
                case (a_off)
                    6'h00: begin
                        enable   <= hwdata[0];
                        irq_en   <= hwdata[1];
                        fifo_rst <= hwdata[2];
                        lr_swap  <= hwdata[3];
                        stop_empty <= hwdata[4];
                        amp_en   <= hwdata[5];
                    end
                    6'h03: thresh <= hwdata[15:0];
                    6'h04: rate   <= hwdata;
                    default: ;
                endcase
            end
        end
    end

    reg [31:0] rd;
    always @(*) begin
        case (a_off)
            6'h00: rd = {26'b0, amp_en, stop_empty, lr_swap, 1'b0, irq_en, enable};
            6'h01: rd = {14'b0, full, irq_cond, level};
            6'h03: rd = {16'b0, thresh};
            6'h04: rd = rate;
            6'h05: rd = underruns;
            6'h06: rd = overruns;
            6'h07: rd = frames;
            6'h08: rd = crc;
            6'h09: rd = {16'b0, depth};
            6'h0B: rd = 32'h4155_4430;
            default: rd = 32'h0;
        endcase
    end
    assign hrdata = rd;
endmodule
`default_nettype wire
