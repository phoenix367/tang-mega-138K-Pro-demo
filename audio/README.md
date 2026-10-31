# audio — PT8211 stereo output + ALSA driver (DMA ring or PIO)

Plays 16-bit stereo audio on the Tang Mega 138K Pro Dock's headphone jack /
speaker through the Dock's **PT8211-S** DAC (BCK `E22`, WS `F24`, DIN `G24`, then a
low-pass filter and the XPT4809 headphone amplifier, whose enable is `PA_EN` =
FPGA pin `H17`, active high, with a divider that leaves it roughly on when the pin
floats).  The core's own DMA engine keeps a sample FIFO filled from a ring buffer
in DDR (or the CPU fills it from an interrupt, the original PIO scheme); the core
serialises it for the DAC.  A WAV played through the standard ALSA PCM interface
comes out bit-exact, and the core proves it with a CRC.

```
rtl/audio_core.v   top: 2048-frame FIFO (BSRAM) + head register, DMA fetch engine, interrupt
rtl/audio_csr.v    AHB-lite registers on EXTS @ 0xE8002000 (bus clock, 50 MHz)
rtl/ahb_arbiter4.v EXTM arbiter with the audio master as 4th port (RX > SD > audio > TX)
rtl/audio_out.v    NCO bit clock, PT8211 serialiser, FRAMES / UNDERRUN / CRC
tb/tb_audio.v      AHB master model + PT8211 receiver model, self-checking
tb/run_tb.sh       iverilog run; prints RESULT: PASS|FAIL
```

```
  DDR ring ──64-bit AHB reads (EXTM, arbiter m3)──► FIFO 2048 × 32 ──► serialiser ──► BCK/WS/DIN ──► PT8211
  (ALSA buffer)   DMA_ADDR/SIZE, up to DMA_LIMIT        │ DMA_IRQ (period / error), level < THRESH
  CPU ──EXTS: DMA_LIMIT = bytes committed ───────────   └──────────── EXT_INT[1] ──► CPU
      (PIO mode: DATA writes, one {R,L} frame each)
```

**DMA.** The engine (CTRL[6]) reads the ALSA buffer as a ring with 64-bit INCR
bursts (two frames per beat, up to DMA_FILL[23:16] beats per command) whenever the
FIFO level plus the frames in flight is below DMA_FILL[15:0] frames, never past
DMA_LIMIT — the free-running count of bytes the application has committed, written
by the driver after it cleaned the cache over that range (the A25 has no coherence
manager; see `ddr_bridge/README.md`).  Odd frame counts are fine: a commit ending
mid-beat reads that beat for its first frame and, once more is committed, again for
the second.  DMA_IRQ[0] is set every DMA_PERIOD bytes fetched, DMA_IRQ[1] on an AHB
error; both are W1C and OR-ed into the FIFO-level interrupt.  The SoC's own DMAC
(ATCDMAC300) cannot be used: any descriptor touching the fabric (EXTS/APB) hangs the
bus (`doc/06-key-findings.md`), so the engine is a fabric master on the DDR arbiter,
like the SD host's.  PIO (DATA writes from the interrupt handler, ~3 % CPU at
48 kHz) is still there for cores without CAP[0] or with the driver's `pio=1`.

## Serial format (PT8211, LSB-justified "Japanese" 16-bit)

The timing is that of Sipeed's `audio/audio_music` example for this board: 32 BCK
periods per stereo frame, WS low for bits 0..15 = left MSB..LSB, WS high for bits
16..31 = right MSB..LSB, data MSB first.  The DAC latches DIN on BCK's rising edge
and takes the 16 bits clocked before each WS transition as that channel's sample.
In this core WS and DIN change together with BCK's falling edge, so the DAC samples
them half a bit period later (Sipeed's design changes them on the rising edge and
relies on clock-to-out delay).  CTRL[3] swaps the channels if the DAC's WS
polarity turns out to be the other way round.

**Bit clock.** A 32-bit phase accumulator in the 50 MHz bus clock advances by
RATE every clock; its MSB is BCK.  BCK = RATE / 2^32 × 50 MHz, so the sample
rate is fs = BCK / 32 and `RATE = fs × 2^37 / 50e6`.  The bit clock jitters by
one 20 ns bus clock (irrelevant for the PT8211's R-2R input), the average rate is
exact to the rounding of RATE (< 1 ppb):

| fs | RATE | actual fs |
|---|---|---|
| 8000 | 21990233 | 8000.00016 |
| 11025 | 30305289 | 11024.99991 |
| 16000 | 43980465 | 15999.99996 |
| 22050 | 60610578 | 22049.99982 |
| 32000 | 87960930 | 31999.99992 |
| 44100 | 121221157 | 44100.00001 |
| 48000 | 131941395 | 47999.99988 |
| 96000 | 263882791 | 96000.00012 |

## Registers (0xE8002000)

| offset | name | |
|---|---|---|
| 0x00 | CTRL | [0] enable, [1] irq enable, [2] FIFO reset (self-clearing), [3] swap channels, [4] stop when empty (a frame start that finds the FIFO empty clears [0] instead of counting an underrun), [5] amplifier enable = the `PA_EN` pin (resets to 1 = on, as Sipeed's example) |
| 0x04 | STATUS | [15:0] FIFO level (frames), [16] level < THRESH, [17] FIFO full |
| 0x08 | DATA | write-only: one frame `{R[15:0], L[15:0]}` (S16_LE interleaved as in memory); dropped and counted when full |
| 0x0C | THRESH | level-type interrupt while level < THRESH (and CTRL[1]) |
| 0x10 | RATE | NCO increment (reset: 48 kHz) |
| 0x14 | UNDERRUN | frames of zeros sent because the FIFO was empty while enabled |
| 0x18 | OVERRUN | DATA writes dropped because the FIFO was full |
| 0x1C | FRAMES | frames taken from the FIFO and sent, since FIFO reset |
| 0x20 | CRC | zlib CRC-32 of those frames' bytes (L lo, L hi, R lo, R hi), since FIFO reset |
| 0x24 | DEPTH | FIFO capacity in frames (2048) |
| 0x28 | CAP | [0] DMA engine present |
| 0x2C | ID | 0x41554430 ("AUD0") |
| 0x30 | DMA_ADDR | ring buffer bus address (8-byte aligned) |
| 0x34 | DMA_SIZE | ring size in bytes (multiple of 8) |
| 0x38 | DMA_PERIOD | DMA_IRQ[0] every this many bytes fetched (0 = never) |
| 0x3C | DMA_LIMIT | bytes committed by the driver, free running (the engine fetches while LIMIT − FETCH > 0, signed) |
| 0x40 | DMA_FETCH | bytes fetched so far, same free-running count (read-only; FIFO reset clears both and the ring offset) |
| 0x44 | DMA_IRQ | [0] period boundary fetched, [1] bus error; write 1 to clear |
| 0x48 | DMA_FILL | [15:0] keep level + in-flight ≥ this many frames (reset 512), [23:16] max beats per command (reset 32) |


CTRL[6] enables the engine (DATA writes are then ignored).

A FIFO reset empties the FIFO and clears FRAMES, UNDERRUN, OVERRUN and CRC.
CTRL[5] is a plain output bit: the driver sets it at probe and clears it at remove,
never per stream (toggling the amplifier pops).  With
enable off the serialiser keeps clocking zeros (no counting).  Underrun frames are
zeros and are *not* in FRAMES or CRC, so after a WAV has been played, FRAMES is its
frame count and CRC is the zlib CRC-32 of its data chunk, whatever the interrupt
latency was — the bit-exactness self-check.  Only 32-bit bus accesses are meaningful.

The core sits on the EXTS window of `src/ae350_demo.v`, decoded by `HADDR[13]`
(the LCD core is `HADDR[12] & ~HADDR[13]`), interrupt on `EXT_INT[1]`.

**EXT_INT to PLIC source numbers** (AE350 BSP `ae350.h`): `EXT_INT[0]` = GP0 =
source **4** (Ethernet), `EXT_INT[1]` = GP1 = source **11**, `EXT_INT[2..15]` =
GP2..GP15 = sources 12..25.  Sources 5..10 are the SoC's own SPI, I2C, GPIO, UART1,
UART2 and DMA.  So the audio node must say `interrupts = <11 4>`; a DTB with
`<5 4>` never sees the interrupt (the driver's `hwirq=11` module parameter
overrides the DT for testing).

## Testbench

`audio/tb/run_tb.sh` (iverilog) drives the core from an AHB-lite master model and
decodes BCK/WS/DIN with a PT8211 receiver model (16 bits before each WS
transition).  It checks the reset values, the frame period for RATE = 48 kHz and
44.1 kHz (within 0.1 %), 300 + 50 + 2248 + 20 + 40 random frames received in order,
FRAMES and CRC against a byte-wise model, underrun counting before and after data,
overrun counting and the full flag at 2048 frames, the level interrupt (assert,
refill, mask), the channel swap and a FIFO reset mid-stream.  The data tests use
RATE = 0x40000000 (BCK = 4 bus clocks, 390625 frames/s) to keep the run short.

## Linux

- **Driver.** `sound/drivers/gowin-pt8211.c` (`CONFIG_SND_GOWIN_PT8211`; patch
  `PATCHES/0007`, copy in `linux/driver/`), compatible `"gowin,ae350-pt8211"`,
  optional `clock-frequency` (bus clock, default 50000000).  One card "PT8211", one
  playback PCM: S16_LE, 2 channels, 8000/11025/16000/22050/32000/44100/48000/96000 Hz,
  buffer 64–256 KiB, period 4–64 KiB (DMA: both a multiple of 2 frames).
- **DMA mode** (cores with CAP[0], unless `pio=1`).  The ALSA buffer is physically
  contiguous (`SNDRV_DMA_TYPE_CONTINUOUS`), streaming-mapped in `hw_params`
  (`dma_map_single`, DMA_TO_DEVICE) and handed to the core as the ring.  Start: FIFO
  reset (clears the fetch counters), RATE, THRESH = 1 (level interrupt = FIFO empty),
  DMA_ADDR/SIZE/PERIOD, DMA_FILL = 256 frames / 32 beats, the first commit, enable
  with the interrupt masked until the first frames are in, then unmask.  `.ack`
  (the application advanced `appl_ptr`) cleans the cache over the newly committed
  range (`dma_sync_single_for_device`, a write-back without invalidate: the
  application may already be writing the next chunk) and writes DMA_LIMIT.  The
  handler clears DMA_IRQ and calls `snd_pcm_period_elapsed` on the period bit (the
  fetch leads playback by ≤ 256 frames, well under a period) or when FRAMES crosses a
  period; when DMA_FETCH has reached the committed count it sets CTRL[4] so the core
  stops itself at the last frame, and once the FIFO is empty (the level interrupt)
  it masks and disables until the next `.ack`.  A bus error stops the stream with
  an xrun.  The CPU's work per period is one cache clean of the period plus a few
  register accesses.
- **PIO mode interrupt scheme.**  Start: FIFO reset, RATE, THRESH = 1024, pre-fill, enable.
  The handler pushes frames from the ALSA buffer up to `appl_ptr` into the FIFO up
  to the top (`writesl` to DATA) and calls `snd_pcm_period_elapsed` when FRAMES
  crosses a period.  When nothing is left to push it sets THRESH = 1, so it runs once
  more when the FIFO is empty — that is when `hw_ptr` reaches `appl_ptr` and ALSA
  finishes a drain (or reports an xrun) — and masks the interrupt; it also sets
  CTRL[4] so the core stops itself at the first empty frame instead of counting the
  interrupt latency (4–7 frames) as underruns.  `.ack` (the application advanced
  `appl_ptr`) restores THRESH, clears CTRL[4] and unmasks.  `.pointer` is FRAMES
  modulo the buffer size.  Stop just disables the core: the statistics stay
  readable.  The handler's cost is one 32-bit bus write per frame: about 1 interrupt
  per 1030 frames and ~3 % of the CPU at 48 kHz (measured with `/proc/stat`, wavplay
  included).
- `/proc/asound/cardN/pt8211` shows the mode, the registers and interrupt/fill
  (= commit) counts; module parameters: `swap_lr` sets CTRL[3], `pio=1` forces
  PIO, `hwirq=N` overrides the PLIC source from the DT (test aid, see above).  The Dummy card (`CONFIG_SND_DUMMY`) is card 0
  on this kernel, so the PT8211 is card 1: `/dev/snd/pcmC1D0p`.

`tests/wavplay.c` plays a 16-bit stereo WAV through the raw ALSA ioctl API
(`HW_PARAMS` / `SW_PARAMS` / `PREPARE` / `WRITEI_FRAMES` / `DRAIN`, no alsa-lib) and
then compares FRAMES and CRC (via `/dev/mem`) with the file's frame count and
data-chunk CRC-32; `tests/wavgen.py <dir>` makes the test files and prints the
expected values.  Transfer by HTTP: `python3 -m http.server --bind 192.168.200.1
8000 --directory <dir>` on the host, `wget -q http://192.168.200.1:8000/<file> -O
/tmp/<file>` on the board.

## Results (DMA mode: Build 62, kernel #71)

Every file plays bit-exact with 0 underruns, including odd frame counts
(`odd48k_72001.wav`, `odd44k_24001.wav`: limits ending mid-beat) and a 16 kHz mono
file, with an LCD `fbtest check` MATCH during playback and under a concurrent
`dd` CPU hog + HTTP download + microSD read.  The 5 s / 48 kHz file, three runs each,
desktop stopped, `/proc/stat` ticks (USER_HZ 100) over the 5.0 s:

| | user | system | audio interrupts | `/proc/interrupts` per play |
|---|---|---|---|---|
| idle (no playback) | 12 | 25–28 | — | — |
| DMA (`pio=0`) | 13–17 | 37–50 | 59 (one per 16 KiB period + end) | 59 |
| PIO (`pio=1`, same kernel) | 16–19 | 38–42 | 232 (one per 1030 frames) | 232 |

So the CPU cost of either mode is within the measurement noise (both about 4 % of
one core including wavplay's own file read, CRC and `write()` copy; the audio part
is a fraction of that at 192 KB/s).  What DMA removes is the 240,000 posted bus
writes per 5 s and three quarters of the interrupts; the driver's remaining work per
period is one cache clean of 16 KiB and three register accesses.  The old "~3 %" PIO
figure in earlier notes was mostly wavplay itself.

Build notes: Gowin's router aborted with "PR0004: 0 unrouted nets" on the Build 62
netlist with Place_Option 2 / Route_Option 2, and Place_Option 0 or 1 missed the
100 MHz bridge domain by 1 ns; Place_Option 2 with Route_Option 0 met every clock
(`impl/mega_138K_test_process_config.json`), the 50 MHz domain by 0.098 ns.

### Build 63: the DMA issue logic was the 50 MHz domain's longest path

A per-path report for `ae350_ahb_clk` (now in the SDC) showed that the arbiter was
not the problem -- none of the 30 worst paths touched it.  All but two were the DMA
command sizing in `audio_core.v`: FIFO write pointer -> `level` -> `occ` -> the
`room` subtraction -> three chained 32-bit compares -> `dm_valid` and the `dm_addr`
enables, 23 logic levels and 19.8 ns of the 20 ns period.  The size is now computed in
two registered stages with 9-bit saturated terms (stage 1: the three differences;
stage 2: the minimum), and a 3-cycle `stale` hold after a completed command, a FIFO
reset or DMA disable keeps a half-updated size from being issued (in between, the
inputs only move the safe way: LIMIT grows, the FIFO drains).  Costs 3 idle cycles
per command (~70 cycles each).  The other two paths were the sdhost FIFO's 128:1 read
mux (see sdhost/README.md).  With those gone the domain's deepest path has 9 levels and
2.8 ns of slack (58 MHz); the bench and the hardware results are unchanged (all files
bit-exact, 0 underruns, DMA and PIO).

## Results (PIO mode: audio gateware + kernel #51 with the module, `hwirq=11`)

| file | rate | frames | CRC core / file | underruns | overruns | xruns |
|---|---|---|---|---|---|---|
| sine1k_48k_5s.wav | 48000 | 240000 / 240000 | D3BCE541 / D3BCE541 MATCH | 0 | 0 | 0 |
| lr440_880_48k_2s.wav | 48000 | 96000 / 96000 | FE8F12E4 / FE8F12E4 MATCH | 0 | 0 | 0 |
| sine1k_44k1_3s.wav | 44100 | 132300 / 132300 | B8A90687 / B8A90687 MATCH | 0 | 0 | 0 |
| sweep200_8k_48k_4s.wav | 48000 | 192000 / 192000 | 5F5615C5 / 5F5615C5 MATCH | 0 | 0 | 0 |

With the 5 s file playing, `fbtest check` is MATCH with 0 LCD underruns, a 768 KB
HTTP download arrives intact, and a `dd if=/dev/zero of=/dev/null bs=1M` load does
not cause audio underruns.  Nobody has listened to the output yet: the channel
assignment (WS low = left, as Sipeed's example) and the DAC's behaviour are verified
only against the receiver model and the Sipeed timing.
