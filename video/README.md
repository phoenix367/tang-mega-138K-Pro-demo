# video — LCD scan-out core + Linux framebuffer (software rendering)

Drives the Sipeed **5" 800×480 RGB LCD** of the Tang Mega 138K Pro kit from an
RGB565 framebuffer in DDR3. Linux renders everything in software (fbcon, `/dev/fb0`
via write() or mmap()); the gateware only scans the framebuffer out.

```
rtl/video_core.v    top: registers + fetch + line RAM + scan-out
rtl/video_csr.v     AHB-lite registers on EXTS @ 0xE8001000 (bus clock, 50 MHz)
rtl/video_fetch.v   line fetcher on the DDR bridge's video port (DDR3 user clock, 100 MHz)
rtl/video_out.v     timing generator, RGB565 -> RGB666, frame CRC (pixel clock, 33.3 MHz)
tb/tb_video.v       the core on the real ahb_ddr3_bridge + DDR3 user-port model
tb/run_tb.sh        3 runs: no back-pressure, 50 %, starved (underruns must be counted)
```

```
                  EXTS (regs)                       DDR3 IP user port
  CPU ──────────────► video_csr        ahb_ddr3_bridge ──video port──► video_fetch
                          │ config                (BL8 = 32 B reads)          │
                          ▼                                                   ▼
  panel ◄── video_out ◄── line RAM: 2 lines × 64 × 256 bit (write: DDR clock, read: pclk)
```

## Panel and timing

DE mode, RGB666 on 18 pins plus `LCD_CLK` (H21) and `LCD_DE` (A24). Pins, drive and
timing come from Sipeed's `rgb_screen/800_480_screen` example (see `src/ae350_demo.cst`).
Timing: H 800 + 210 front / 182 back porch (1192 total), V 480 + 45 / 8 (533 total).
The pixel clock is the Ethernet PLL's CLKOUT2 (VCO 1000 MHz / 30 = 33.3 MHz), giving
~52 Hz (55 frames/s measured). The panel samples on the falling edge: `LCD_CLK` comes
from an ODDR in phase with the registered outputs. RGB565 is widened to RGB666 by
repeating the 5-bit channels' MSB.

## Registers (0xE8001000)

| offset | name | |
|---|---|---|
| 0x00 | CTRL | [0] enable scan-out, [1] test pattern (colour bars, no fetch) |
| 0x08 | FB_BASE | framebuffer physical address, 32 B aligned |
| 0x0C | STRIDE | bytes per line, multiple of 32 |
| 0x10 | HTIM | [15:0] active pixels (multiple of 16, ≤ 1024), [31:16] total |
| 0x14 | HSTART | first active pixel (DE start) |
| 0x18 | VTIM | [15:0] active lines, [31:16] total |
| 0x1C | VSTART | first active line |
| 0x20 | FRAMES | frames scanned out |
| 0x24 | UNDERRUN | active lines whose fetch was late |
| 0x28 | CRC | zlib CRC-32 of the last frame's active pixels as sent (RGB565 LE, row by row) |
| 0x2C | ID | 0x56494430 ("VID0") |

Change timing only while CTRL is 0. Enable/test take effect at the next frame start.
The pixel-clock counters are 12 bits, so totals can be at most 4095, and htotal must be
at least 16.
The reset values are the panel above.

## How a line is fetched

Early in each line period (at h = 7) `video_out` requests the line shown during the *next*
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
`ddr_bridge/README.md`). A line is 50 BL8 reads (100 on the old 16-bit bus), ~1 µs of
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

`tests/fbtest.c` checks the display end to end. It draws a pattern (`bars`, `grad`,
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
