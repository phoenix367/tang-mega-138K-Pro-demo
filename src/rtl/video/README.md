# video — LCD scan-out core + Linux framebuffer (software rendering)

Drives the Sipeed **5" 800×480 RGB LCD** of the Tang Mega 138K Pro kit from an
RGB565 framebuffer in DDR3. Linux renders everything in software (fbcon, `/dev/fb0`
via write() or mmap()); the gateware only scans the framebuffer out.

```
rtl/video_core.v    top: registers + fetch + line RAM + scan-out
rtl/video_csr.v     AHB-lite registers on EXTS @ 0xE8001000 (bus clock, 50 MHz)
rtl/video_fetch.v   line fetcher on the DDR bridge's video port (DDR3 user clock, 100 MHz)
rtl/video_out.v     timing, scaler, YUV -> RGB, OSD blend, RGB666, frame CRC (pixel clock, 33.3 MHz)
tb/tb_video.v       the core on the real ahb_ddr3_bridge + DDR3 user-port model
tb/run_tb.sh        15 runs: RGB / YUV, back-pressure, starved fetch, scaler, OSD (see below)
```

```
                  EXTS (regs)                       DDR3 IP user port
  CPU ──────────────► video_csr        ahb_ddr3_bridge ──video port──► video_fetch
                          │ config                (BL8 = 32 B reads)          │
                          ▼                                                   ▼
  panel ◄── video_out ◄── line RAMs, 2 lines each (write: DDR clock, read: pclk):
                          Y/RGB 64, U 32, V 32, OSD 128 words of 256 bit
```

## Panel and timing

DE mode, RGB666 on 18 pins plus `LCD_CLK` (H21) and `LCD_DE` (A24). Pins, drive and
timing come from Sipeed's `rgb_screen/800_480_screen` example (see `src/rtl/ae350_demo.cst`).
Timing: H 800 + 210 front / 182 back porch (1192 total), V 480 + 45 / 8 (533 total).
The pixel clock is the Ethernet PLL's CLKOUT2 (VCO 1000 MHz / 30 = 33.3 MHz), giving
~52 Hz (55 frames/s measured). The panel samples on the falling edge: `LCD_CLK` comes
from an ODDR in phase with the registered outputs. RGB565 is widened to RGB666 by
repeating the 5-bit channels' MSB.

## Registers (0xE8001000)

| offset | name | |
|---|---|---|
| 0x00 | CTRL | [0] enable scan-out, [1] test pattern (colour bars, no fetch), [2] YUV 4:2:0 planar framebuffer, [3] full-range (JPEG) YUV instead of BT.601 limited |
| 0x08 | FB_BASE | framebuffer (RGB565, or the Y plane) physical address, 32 B aligned |
| 0x0C | STRIDE | bytes per line (Y line in YUV mode), multiple of 32 |
| 0x10 | HTIM | [15:0] active pixels (multiple of 16, ≤ 1024), [31:16] total |
| 0x14 | HSTART | first active pixel (DE start) |
| 0x18 | VTIM | [15:0] active lines, [31:16] total |
| 0x1C | VSTART | first active line |
| 0x20 | FRAMES | frames scanned out |
| 0x24 | UNDERRUN | active lines whose fetch was late |
| 0x28 | CRC | zlib CRC-32 of the last frame's active pixels as sent (RGB565 LE, row by row) |
| 0x2C | ID | 0x56494430 ("VID0") |
| 0x30 | FB_BASE_U | U plane physical address, 32 B aligned (YUV mode) |
| 0x34 | FB_BASE_V | V plane physical address, 32 B aligned (YUV mode) |
| 0x38 | STRIDE_C | bytes per chroma line, multiple of 32 (YUV mode) |
| 0x3C | SRC_SIZE | scaler: [15:0] source width (YUV ≤ 2048, RGB ≤ 1024), [31:16] height |
| 0x40 | DST_POS | [15:0] x, [31:16] y of the picture window in the active area |
| 0x44 | DST_SIZE | [15:0] width, [31:16] height of the window |
| 0x48 | STEP_X | source pixels per window pixel, 16.16 (`src_w * 65536 / dst_w`, < 64.0) |
| 0x4C | STEP_Y | source lines per window line, 16.16 |
| 0x50 | BG | RGB565 colour around the window |
| 0x54 | OSD_BASE | first OSD pixel, ARGB8888 (little-endian `0xAARRGGBB` words), 32 B aligned |
| 0x58 | OSD_STRIDE | bytes per OSD line, multiple of 32 |
| 0x5C | OSD_POS | [15:0] x, [31:16] y of the OSD window |
| 0x60 | OSD_SIZE | [15:0] width (≤ 1024), [31:16] height |
| 0x64 | CAPS | [0] YUV, [1] scaler, [2] OSD (0 on cores before Build 71) |

CTRL also has [4] scaler on and [5] OSD on (Build 71+).

Change timing only while CTRL is 0. Enable/test/YUV mode take effect at the next frame start.

**YUV 4:2:0 mode (Build 68+).** The framebuffer is what video decoders produce: planar
Y (FB_BASE/STRIDE), U and V (FB_BASE_U/V, STRIDE_C, half width and height). The
fetcher reads the three planes of a line into three regions of the line RAM (the same
1600 bytes per line as RGB565, so the DDR port load is unchanged and the scan-out's DRAM
traffic actually drops from 2 to 1.5 bytes per pixel); the output stage picks the Y, U
and V words of each 16-pixel group in the group's first three cycles and converts
with fixed-point BT.601 (×256 coefficients 298/409/100/208/516, or 256/359/88/183/454
for full range), repeating chroma samples. The CRC register still covers the RGB565
pixels as sent, so `vidplay`'s expected-CRC check works in both modes. hactive must be
a multiple of 32. The mode exists so a software decoder can hand its frame to the
panel without a CPU conversion pass: on the A25 that pass cost as much as decoding.
The pixel-clock counters are 12 bits, so totals can be at most 4095, and htotal must be
at least 16.
The reset values are the panel above.

## Scaler and OSD (Build 71+)

**Line RAMs.** Up to Build 70 the three YUV planes of a line shared one 256-bit RAM,
read once per 16-pixel group, which only works 1:1. The line buffer is now four
double-buffered RAMs: Y/RGB (64 words per half: 2048 Y samples or 1024 RGB565
pixels), U and V (32 words, 1024 samples each) and OSD (128 words, 1024 ARGB pixels).
Each has its own read port, so every pixel reads the words that hold its own samples,
and any scale factor works. That is 32 block RAMs instead of 8.

**Scaler (CTRL[4]), nearest neighbour.** The source picture (SRC_SIZE, at FB_BASE…) is
shown in the window DST_POS/DST_SIZE; the rest of the active area gets BG. Window line k
shows source line `floor((k·STEP_Y + STEP_Y/2) / 65536)`, window pixel k source pixel
`floor((k·STEP_X + STEP_X/2) / 65536)`, both clamped to the source size. That is pixel
centres sampled, so a step of 1.0 is the identity. The vertical DDA runs in the
next-line pipeline and the source line goes out with the fetch request. Lines outside
the window, with no OSD on them, are not fetched at all. The horizontal DDA runs per
pixel. The fetch reads `src_w` pixels of the needed source line, so downscaling also
saves DDR bandwidth. With CTRL[4] = 0 the bus side sets the window to the whole active
area, the steps to 1.0 and the source to the active size: Build 68 behaviour, bit for bit.

**OSD (CTRL[5]).** An ARGB8888 layer in its own window, one OSD pixel per panel pixel,
fetched per line after the video planes. It is blended over the picture or background
in RGB888 as `out = (osd·a' + pic·(256 − a')) >> 8` with `a' = A + A[7]`, so A = 0 leaves
the picture bit-exact and A = 255 shows the OSD pixel. It works in RGB and YUV mode.

**Pipeline.** The pixel stages are: windows and DDA, then the four RAM addresses with
the sample index clamped, then RAM data, then sample selection. Next come the YUV
products, sums and the picture pixel, or RGB565 widened to RGB888, test bars or
background. The last stages are the blend, the RGB565 pack, then the outputs and the
CRC. The CRC is still taken over the RGB565 pixels as sent, so a test can check any
scene against a model (`src/apps/tests/scaletest.c`).

**Frame-exact changes.** Like the framebuffer bases, the scaler and OSD registers are
latched on the bus side at each frame end. The pixel clock takes them over at the end of
line 0, so with vstart ≥ 2 every frame is entirely old or entirely new. The testbench
moves the OSD in mid-frame and checks exactly that.

**Bandwidth.** A full-screen OSD adds 4 bytes per pixel, 100 BL8 reads a line on top
of the 50 of the picture. vidplay's 64-line bar adds 6400 reads per frame (~11 MB/s,
about 28 % on top of an 800×450 YUV picture's ~23 000). Measured on the board it costs
the CPU nothing noticeable: a frozen bar over playback left the load unchanged within
0.4 %.

**Results (Build 71, kernel #83+).** In simulation, `tb/run_tb.sh` runs 15
configurations pixel-exact against the model, including upscale, 2.5× downscale, odd
factors such as 150→61, RGB-mode scaling, windows with background, the OSD alone and
over scaled pictures, and the mid-frame OSD move. On the board, `scaletest` checks
seven scenes by frame CRC with no underruns: up to 800×450, down to a 400×240 window,
333×211→761×462, OSD over 1:1, the info bar over an upscaled picture, and a
full-screen OSD over a small window. Timing: lcd_pclk 95.8 MHz (needs 33.3), the DDR
clock domain 100.08 MHz, all clocks met. Cost: the core grew from 8 to 32 block RAMs,
about 1k LUTs and 3 multipliers.

## How a line is fetched

Early in each line period (at h = 11) `video_out` requests the line shown during the *next*
period (toggle handshake into the DDR clock). `video_fetch` reads it as `hactive/16`
BL8 reads (32 B = 16 pixels each on the 32-bit DDR3 bus; 16 B = 8 pixels before the 1 GB
change) into the free half of the line RAM and toggles back.
The answer tags that half with {frame parity, line}. If an active line's half does not
carry its tag at the first pixel, UNDERRUN counts it and the stale half is shown: a
late fetch costs one line, never the frame alignment.

**Why a DDR port and not EXTM.** The first version read the framebuffer as an EXTM
master, with 64-bit INCR16 bursts through the SoC into the data-memory bus.
`ddr_perf` showed each 128 B burst holding the CPU's data-memory bus for ~69 cycles at
100 MHz, because the SoC paces EXTM beats at 50 MHz and the bridge stalls mid-burst.
That is ~24 % of the bus at 40 MB/s of scan-out, and it cost:
- CPU memcpy: 62 → 38.6 MB/s;
- TCP RX: 65 → 24 Mbit/s;
- under TX load, a third of all lines underran, because an Ethernet TX frame
  (single-beat reads) held EXTM for ~150 µs, about 4 line periods.

The bridge now has a read-only video port next to its own DDR command stream (see
`src/rtl/ddr_bridge/README.md`). A line is 50 BL8 reads (100 on the old 16-bit bus), ~1 µs of
controller time per 35.8 µs line, and the CPU's bus and EXTM never see it. The bridge goes first, but a video
request that has waited 8 DDR clocks takes the next command slot, so a CPU write
stream cannot starve the scan-out.

## Linux

- **Driver.** `drivers/video/fbdev/gowin-lcdfb.c` (`CONFIG_FB_GOWIN_LCD`; patch
  `PATCHES/0006`, copy in `linux/driver/`), compatible `"gowin,ae350-lcd"`. DT
  properties `width`, `height`, `hfront-porch`, `hback-porch`, `vfront-porch`,
  `vback-porch`.
- **Framebuffer memory.** The framebuffer is ordinary kernel memory
  (`alloc_pages_exact`, physically contiguous) under a streaming DMA mapping. The A25
  has no coherence manager and rv32 has no uncached mapping, so the CPU draws through
  its D-cache and the driver writes changed bytes back before the core reads them:
  - the fb_sys drawing helpers (fbcon, write()) report the damaged area, which is
    written back at once;
  - pages written through mmap() are tracked by fbdev deferred I/O and written back
    20 ms later.
- **Console.** `CONFIG_FRAMEBUFFER_CONSOLE`: a 100×30 text console with the Tux logo
  at boot.

`src/apps/tests/fbtest.c` checks the display end to end. It draws a pattern (`bars`, `grad`,
`noise` via mmap, `write` via write(); `check` draws nothing), waits for the
write-back and two frames, and compares the CPU's CRC of the framebuffer with the
CRC register: equal means every pixel the panel received is what the CPU drew.
`echo 0 > /sys/class/graphics/fbcon/cursor_blink` keeps the cursor from changing
the CRC between the two reads.

## Results (hardware, Build 49 gateware + kernel #49, scan-out running)

| | video off | EXTM master (first version) | DDR video port + aging |
|---|---|---|---|
| fbtest (bars/grad/noise/write/fbcon) | – | MATCH | MATCH |
| underruns: idle / memtest / `dd` write stream / network | – | 0 / – / – / ~⅓ of lines | 0 / 0 / 0 / 0 |
| memcpy (`membench`) | 62 MB/s | 38.6 MB/s | 54.7 MB/s |
| `ddr_memtest`: seq read / miss latency | 148 MB/s / 1.34 µs | – | 146 MB/s / 1.33 µs |
| TCP RX / TX (Mbit/s) | 65–67 / 39.5 | 24 / 33.5 | 63–66 / 38.4 |

Without the aging rule, `dd if=/dev/zero of=/dev/null bs=1M` (a CPU write stream)
caused 1519 underrun lines in 2.9 s. The remaining memcpy cost is the scan-out's real
DDR bandwidth: the 40 MB/s video stream gets its share when the CPU streams.

## Pixel-clock logic depth

`video_out` keeps arithmetic out of the compare paths:
- **Events.** The timing values are copied into the pixel clock with their derived
  constants (`hstart+hactive`, `htotal−2`, `vstart+vactive`, `vtotal−1`). Every timing
  event is a registered 12-bit equality compare against one of them.
- **Counters.** Window flags, the pixel index and the line index are set, cleared and
  counted by those events.
- **Next-line state.** `v` changes once a line, so the next line's flags, index and frame
  parity are computed in a 4-stage pipeline during the current line and loaded at the wrap.
- **Pixel path.** Separate stages for RAM, lane select, the CRC data term and the CRC
  state update. The CRC is linear, `crc16(c,d) = F(c) ⊕ G(d)`, so `G` moves a stage earlier.

The first version had 11 logic levels on lcd_pclk (86.8 MHz after PnR, Build 49). Its
worst path was the 8:1 lane mux feeding the CRC XOR tree in one cycle, then the
`v → next_v → −vstart → <vactive → req_tgl` chain.
