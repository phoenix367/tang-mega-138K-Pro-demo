`default_nettype none
//============================================================================
// audio_core.v -- stereo audio output for the Tang Mega 138K Pro Dock's
// PT8211 DAC (16-bit, LSB-justified serial format; BCK / WS / DIN).
//
//   CPU --EXTS--> audio_csr (registers) --DATA writes--> frame FIFO
//                                           2048 x 32 bit BSRAM, one clock
//                                                        |
//   DAC <-- audio_out (NCO bit clock, serialiser, CRC) <-- head register
//
// No DMA: the CPU fills the FIFO one {R, L} frame per 32-bit write, and the
// level-type interrupt (level < THRESH) asks for more.  The whole core runs
// on the EXTS bus clock; the DAC bit clock is derived from it by a phase
// accumulator, so the sample rate is programmable and the outputs are
// ordinary registered I/O.  See audio/README.md.
//============================================================================
module audio_core (
    input  wire         hclk,
    input  wire         hresetn,
    // AHB-lite slave: registers
    input  wire [31:0]  s_haddr,
    input  wire [1:0]   s_htrans,
    input  wire         s_hwrite,
    input  wire         s_hsel,
    input  wire         s_hready_in,
    input  wire [31:0]  s_hwdata,
    output wire [31:0]  s_hrdata,
    output wire         s_hready,
    output wire         s_hresp,
    // interrupt (level)
    output reg          irq,
    // DAC
    output wire         i2s_bck,
    output wire         i2s_ws,
    output wire         i2s_din,
    // headphone amplifier enable (CTRL[5], resets to 1)
    output wire         pa_en
);
    localparam AW = 11;                       // 2048 frames

    wire        enable, irq_en, fifo_rst, lr_swap, stop_empty, enable_clr, data_wr;
    wire [15:0] thresh;
    wire [31:0] rate, data, underruns, frames, crc;
    reg  [31:0] overruns;

    // ---- FIFO: RAM + first-word-fall-through head register --------------
    reg  [AW:0] wr_ptr, rd_ptr;
    wire [AW:0] count    = wr_ptr - rd_ptr;       // frames in the RAM
    wire        ram_empty = (count == 0);
    reg         head_valid, rd_pending;
    // level = frames in the core: RAM + one in flight to the head + head
    wire [15:0] level    = {{(15-AW){1'b0}}, count} + {15'b0, head_valid} + {15'b0, rd_pending};
    wire        full     = level[AW];               // == 2048
    wire        wr_ok    = data_wr && !full;
    reg  [31:0] head;
    wire [31:0] ram_q;
    wire        pop;
    wire        rd_en = !head_valid && !rd_pending && !ram_empty && !fifo_rst;

    // simple dual-port RAM, synchronous read (BSRAM); no init loop, which
    // GowinSyn refuses above 2000 iterations
    reg [31:0] ram [0:(1 << AW) - 1];
    reg [31:0] ram_q_r;
    always @(posedge hclk) begin
        if (wr_ok) ram[wr_ptr[AW-1:0]] <= data;
        if (rd_en) ram_q_r <= ram[rd_ptr[AW-1:0]];
    end
    assign ram_q = ram_q_r;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            wr_ptr <= 0; rd_ptr <= 0; head_valid <= 0; rd_pending <= 0; head <= 0;
            overruns <= 0; irq <= 0;
        end else begin
            if (wr_ok) wr_ptr <= wr_ptr + 1'b1;
            if (data_wr && full) overruns <= overruns + 1;
            if (rd_en) begin rd_ptr <= rd_ptr + 1'b1; rd_pending <= 1'b1; end
            if (rd_pending) begin head <= ram_q; head_valid <= 1'b1; rd_pending <= 1'b0; end
            if (pop) head_valid <= 1'b0;
            if (fifo_rst) begin
                wr_ptr <= 0; rd_ptr <= 0; head_valid <= 0; rd_pending <= 0; overruns <= 0;
            end
            irq <= irq_en & irq_cond;
        end
    end

    wire        irq_cond = (level < thresh);

    audio_csr u_csr (
        .hclk(hclk), .hresetn(hresetn),
        .haddr(s_haddr), .htrans(s_htrans), .hwrite(s_hwrite), .hsel(s_hsel),
        .hready_in(s_hready_in), .hwdata(s_hwdata),
        .hrdata(s_hrdata), .hready(s_hready), .hresp(s_hresp),
        .enable(enable), .irq_en(irq_en), .fifo_rst(fifo_rst), .lr_swap(lr_swap),
        .stop_empty(stop_empty), .amp_en(pa_en), .enable_clr(enable_clr), .thresh(thresh), .rate(rate), .data_wr(data_wr), .data(data),
        .level(level), .irq_cond(irq_cond), .full(full), .depth(16'd1 << AW),
        .underruns(underruns), .overruns(overruns), .frames(frames), .crc(crc)
    );

    audio_out u_out (
        .clk(hclk), .rstn(hresetn),
        .enable(enable), .lr_swap(lr_swap), .stop_empty(stop_empty), .enable_clr(enable_clr),
        .rate(rate), .clear(fifo_rst),
        .head_valid(head_valid), .head(head), .pop(pop),
        .frames(frames), .underruns(underruns), .crc(crc),
        .bck(i2s_bck), .ws(i2s_ws), .din(i2s_din)
    );
endmodule
`default_nettype wire
