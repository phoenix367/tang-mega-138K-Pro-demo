# `idct/` — hardware JPEG decoder (entropy decoding, IDCT, frame assembly) for MJPEG

The A25 decodes MJPEG at 800×480 in ~40 ms per frame, 55 % of it in FFmpeg's
`ff_simple_idct_put` — not the arithmetic (a DSP-intrinsic version of the transform
was bit-exact and no faster in the real decode) but the output: every 8×8 block
writes 8 scattered 8-byte rows into a cold frame, one write-allocate miss per row
(~1.4 µs dependent miss latency, no L2), about 18 ms of the 40. Staging bands in
software only moved the misses. This core takes the IDCT and, more importantly, the
block writes off the CPU: blocks arrive as coefficient records in a DRAM ring, the
core transforms them, assembles whole 16-line (luma) / 8-line (chroma) bands in BSRAM
and writes each band to the YUV 4:2:0 planes as full lines in 128-byte bursts.

```
CPU (Huffman + dequant) --records--> DRAM ring --EXTM read--> parser -> 2-D IDCT
                                                               (idct_1d x2, transpose)
    EXTS registers @ 0xE8040000  (HADDR[18])                        |
                                                                    v
    YUV planes in DRAM  <--EXTM write, whole lines--  flush engine <- band RAMs (Y/U/V)
```

Since Build 70 the core also decodes the entropy-coded data itself (`rtl/jpeg_entropy.v`):
the CPU parses a frame's headers, sends the Huffman and quantisation tables and copies
the scan's raw bytes into the ring; the core does Huffman decoding, dequantisation,
the IDCT and the frame assembly. See "JPEG records" below.

Gateware Build 69+ (JPEG records: Build 70+); EXTM arbiter master 4 (`audio/rtl/ahb_arbiter5.v`, priority
0 > 2 > 3 > 4 > 1), interrupt `EXT_INT[3]` = PLIC source 13. Linux driver
`drivers/misc/gowin-idct.c` (`PATCHES/0013`, `/dev/gowin-idct`), kernel #78+; the
player's side is `src/apps/vidplay/idct_hw.c`.

## Files

| File | What |
|---|---|
| `rtl/idct_1d.v` | Pipelined 8-point 1-D IDCT, FFmpeg's `simple_idct` integer algorithm (W1..W7, row pass shift 11 with the DC shortcut, column pass shift 20 + clamp), 22 multipliers, one transform per clock, latency 4. |
| `rtl/idct_core.v` | Registers, ring reader (shared `ahb_master`, 32-word FIFO), record parser, 2-D engine (rows → transpose buffer → columns), the three band RAMs, flush engine with a prefetch FIFO, status/interrupts. |
| `rtl/jpeg_entropy.v` | Baseline JPEG entropy decoder: table loads, byte unstuffing and RST markers, canonical Huffman decoding (one symbol per four clocks), DC prediction, dequantisation, zigzag; writes each block into the core's block buffer and hands it to the IDCT path. |
| `rtl/idct_ram.v` | Simple dual-port 64-bit RAM for the bands (inferred BSRAM; the shared `RAM_Simple_Dual_Port_Dual_Clock` has an init loop GowinSyn refuses at depth 2048). |
| `tb/tb_jpeg.v`, `tb/run_jpeg_tb.sh`, `tb/jpeg_ref.py` | JPEG regression: real files (libjpeg standard and optimised tables, restart markers, dense q 100, q 5 with sizes not multiples of 16, an ffmpeg MJPEG frame, damaged frames followed by a good one) as records through the core; every pixel compared with `jpeg_ref.py`, a literal port of FFmpeg's unescaping, restart handling, `decode_block` and simple IDCT, which is itself checked against the host's FFmpeg (C code, `-idct simple`) on every image. |
| `tb/tb_idct.v`, `tb/run_tb.sh` | iverilog regression: small 4:2:0 frames of random blocks (DC-only, sparse, dense, clamp stress) in MCU order through a 64-bit AHB RAM model, every pixel compared with a model of FFmpeg's IDCT; per-block flush flags, automatic flushes, flush-only records, a height that is not a multiple of 16, a wrapping ring, the done interrupt exactly once. |

## Records

64-bit little-endian words in a ring of `RING_MASK + 1` bytes (a power of two, ≥ 64 B);
a record may wrap around the end.

| Word | Bits | |
|---|---|---|
| 0 | `[6:0]` | `n` = coefficients that follow, natural (raster) order, 0..64; the rest of the block is zero |
| | `[7]` | flush this plane's band after the block |
| | `[9:8]` | plane: 0 Y, 1 U, 2 V |
| | `[21:10]`, `[33:22]` | x, y of the block in the plane (pixels, multiples of 8) |
| | `[34]` | raise the band interrupt after that flush |
| | `[35]` | flush-only: flush the plane's band if it is dirty, no block (`n` must be 0) |
| | `[39:36]` | record type: 0 = this block record; 1..3 = JPEG records, below; 4..15 = bad record, skipped |
| 1.. | | `ceil(n/4)` words of four int16 coefficients, the lowest index in the low half |

The coefficients are what FFmpeg hands `idct_put`: dequantised, with the level shift
(+1024) in the DC. Output = `clamp(0..255)` of the transform, bit-exact with
`ff_simple_idct_put_int16_8bit` (the C version; `tb/` and `src/apps/tests/idcttest.c`
check that, the DSP version in `idct_dsp.c` was verified against the same).

A block whose band (y / 16 for Y, y / 8 for U and V) differs from the band the plane
holds flushes that band first, so any MCU order decodes correctly; the flags only
decide when the last band of a frame lands. A frame ends with three flush-only
records (one per plane). The flush writes `width` (or `width/2`) pixels per line and
stops at `height` (`height/2`); blocks at x ≥ `width` are not allowed.

## JPEG records (Build 70+, STATUS[8] = 1)

Header `[39:36]` type, `[9:8]` id, `[63:40]` payload bytes; the payload follows, eight
bytes per word, the first in bits `[7:0]` (macros in `include/uapi/linux/gowin-idct.h`).

| Type | id | Payload |
|---|---|---|
| 1 Huffman table | slot: 0 DC 0, 1 DC 1, 2 AC 0, 3 AC 1 | the DHT's 16 code counts, then its symbol values |
| 2 quantisation table | table 0..3 | 64 bytes in zigzag order, as in the DQT (8-bit precision) |
| 3 scan | — | one parameter word, then the entropy-coded bytes exactly as in the file, from after the SOS header to the EOI marker |

Scan parameter word: `[7:0]` MCU columns, `[15:8]` MCU rows, `[31:16]` restart interval
in MCUs (0 = none), `[32]`/`[33]` Y DC/AC table, `[34]`/`[35]` Cb, `[36]`/`[37]` Cr,
`[39:38]` Y quantisation table, `[41:40]` Cb, `[43:42]` Cr. The scan is interleaved
4:2:0: per MCU the blocks Y0 Y1 Y2 Y3 Cb Cr, each going through the same band and
flush logic as a block record. Tables persist in the core across frames and resets; a
frame needs only the tables that changed. A frame ends with the three flush-only records.

Semantics are FFmpeg's `mjpegdec.c`, so the output is bit-exact with the CPU decoder.
The DC predictor works in dequantised units and starts at 1024 at the scan start and
after each restart marker. A DC result is clipped to 16 bits, an AC product truncated
to 16 bits. FF 00 is a data byte, FF D0..D7 a restart, FF FF fill; any other marker ends
the data and the decoder reads zeros past the end. Corrupt data sets STATUS[3] and
skips the rest of the scan record: no code matches, a DC size above 16, or a
coefficient past position 63. Every block ends within 64 symbols, so no stream can hang
the core.

Throughput: one Huffman symbol per four clocks, overlapped with the IDCT of the
previous block. At the bit rates of MJPEG video, around 20 bits per block, the IDCT's
~40 clocks per block dominate: a full 800×450 frame takes 49–53 clocks per block in the
testbench, and about 12 ms per 800×480 frame on the board.

On the board (Build 70, `vidplay -C`): 150 frames each of 800×480, 640×360 and 480×270
MJPEG and 1500 frames of an 800×450 music video are identical to FFmpeg's CPU decode;
the player's CPU time per 800×480 frame went from 29.5 ms to 1.2 ms. Build 70 timing:
all clocks met, ahb_clk 53.1 MHz (constraint 50). The entropy decoder is 2.8k LUT/ALU,
2.1k registers, 2 BSRAM, 1 DSP; with the block buffer's second write port the whole core
grew from 5.9k to 11.9k LUT/ALU (device logic 25 % to 30 %).

## Registers (EXTS, CPU base `0xE8040000`, 32-bit)

| Offset | | |
|---|---|---|
| `0x00` | CTRL | `[0]` enable, `[1]` reset (self-clearing: pointers, parser, engine, bands), `[2]` done irq enable, `[3]` band irq enable |
| `0x04` | STATUS | `[0]` busy, `[1]` done irq, `[2]` band irq, `[3]` bad record (n > 64, plane 3, unknown type, corrupt JPEG data); write 1 to clear; `[8]` read-only 1: JPEG records supported |
| `0x08` | RING_BASE | byte address, 8-byte aligned |
| `0x0C` | RING_MASK | ring size − 1 |
| `0x10` | TAIL | byte offset past the last record (8-aligned); the core consumes up to it |
| `0x14` | HEAD | byte offset consumed so far (read-only) |
| `0x18`/`0x1C`/`0x20` | Y/U/V_BASE | plane addresses, 8-byte aligned |
| `0x24` | STRIDES | `[15:0]` luma, `[31:16]` chroma, bytes (multiples of 8) |
| `0x28` | SIZE | `[15:0]` width (multiple of 16, ≤ 1024), `[31:16]` height (luma pixels) |
| `0x2C` | BLOCKS | blocks transformed (read-only) |
| `0x30` | BANDS | bands flushed (read-only) |
| `0x34` | ID | `0x49444354` "IDCT" |

Busy = records pending or a band in flight; it stays set until everything up to
TAIL is in DRAM, and drops in the same cycle the done flag rises (a poller never sees
idle without done). The done interrupt fires once per TAIL write that was followed by
the core going idle. EXTS reads take the top level's one wait state.

## Timing

The core runs on the 50 MHz EXTS bus clock. The engine takes ~35 clocks per block (rows
8 + pipeline 4 + columns 8 + pipeline 4 + band write 8) plus ~5 for parsing a sparse
record, so 800×480 4:2:0 = 9000 blocks ≈ 7–8 ms per frame, against the ~22 ms the CPU
spent on the same blocks. (The testbench's 62–66 clocks per block are bound by its slow
one-word-at-a-time ring writer.) On the board (`idcttest`, Build 69) every
block of random full frames, also with the picture at unaligned offsets in the buffer,
is bit-exact; vidplay's 800×480 MJPEG decode went from 42.6 to 26.4 ms per frame (full
25 fps with audio), 640×360 from 29.3 to 19.1 ms. Build 69 timing: all clocks met,
ahb_clk 52.4 MHz (constraint 50), ddr3_sysclk 100.03. Band flushes are 128-byte bursts on the
EXTM arbiter at the lowest DMA priority but above the Ethernet TX read.

## Software

`gowin-idct` (misc): the ring (`ring_kb`, default 2048) is kernel pages mapped cached
into the user process; `SUBMIT` writes the new range back from the D-cache and sets
TAIL, `WAIT` sleeps on the done interrupt until idle, `SETUP` (plane DMA addresses
from `GOWIN_LCD_IOC_YUV_DMA`, which also drops the buffer from the CPU cache) waits
for idle first. `vidplay` wraps FFmpeg's `idct_put`: a record per block, a SUBMIT
whenever a luma block starts a new band, flush-only records + SUBMIT after
`avcodec_receive_frame`, WAIT right before the frame is shown (`YUV_SHOW` with
`NOSYNC`: the CPU cache holds nothing of a hardware-written buffer).
`VIDPLAY_NOHWIDCT=1` keeps the CPU path for A/B.
