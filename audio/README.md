# audio — PT8211 stereo output + ALSA driver (no DMA)

Plays 16-bit stereo audio on the Tang Mega 138K Pro Dock's headphone jack /
speaker through the Dock's **PT8211-S** DAC (BCK `E22`, WS `F24`, DIN `G24`, then a
low-pass filter and the XPT4809 headphone amplifier, whose enable is `PA_EN` =
FPGA pin `H17`, active high, with a divider that leaves it roughly on when the pin
floats).  The CPU fills a sample FIFO from an
interrupt; the core serialises it for the DAC.  A WAV played through the standard
ALSA PCM interface comes out bit-exact, and the core proves it with a CRC.

```
rtl/audio_core.v   top: 2048-frame FIFO (BSRAM) + head register, interrupt
rtl/audio_csr.v    AHB-lite registers on EXTS @ 0xE8002000 (bus clock, 50 MHz)
rtl/audio_out.v    NCO bit clock, PT8211 serialiser, FRAMES / UNDERRUN / CRC
tb/tb_audio.v      AHB master model + PT8211 receiver model, self-checking
tb/run_tb.sh       iverilog run; prints RESULT: PASS|FAIL
```

```
  CPU ──EXTS writes, one {R,L} frame each──► FIFO 2048 × 32 ──► serialiser ──► BCK/WS/DIN ──► PT8211
         ▲                                     │ level < THRESH
         └──────────── EXT_INT[1] ◄────────────┘
```

**Why no DMA.** Audio is 192 KB/s at 48 kHz.  A DMA engine would read the sample
buffer from DDR, and on this SoC (no coherence manager) every buffer write would
need an explicit cache write-back first.  Filling a FIFO from the interrupt handler
costs about 1 % of the CPU and keeps the ALSA buffer in ordinary kernel memory.

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
| 0x2C | ID | 0x41554430 ("AUD0") |

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
  vmalloc buffer 64–256 KiB, period 4–64 KiB.
- **Interrupt scheme.**  Start: FIFO reset, RATE, THRESH = 1024, pre-fill, enable.
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
- `/proc/asound/cardN/pt8211` shows the registers and interrupt/fill counts;
  module parameters: `swap_lr` sets CTRL[3], `hwirq=N` overrides the PLIC source
  from the DT (test aid, see above).  The Dummy card (`CONFIG_SND_DUMMY`) is card 0
  on this kernel, so the PT8211 is card 1: `/dev/snd/pcmC1D0p`.

`tests/wavplay.c` plays a 16-bit stereo WAV through the raw ALSA ioctl API
(`HW_PARAMS` / `SW_PARAMS` / `PREPARE` / `WRITEI_FRAMES` / `DRAIN`, no alsa-lib) and
then compares FRAMES and CRC (via `/dev/mem`) with the file's frame count and
data-chunk CRC-32; `tests/wavgen.py <dir>` makes the test files and prints the
expected values.  Transfer by HTTP: `python3 -m http.server --bind 192.168.200.1
8000 --directory <dir>` on the host, `wget -q http://192.168.200.1:8000/<file> -O
/tmp/<file>` on the board.

## Results (hardware, audio gateware + kernel #51 with the module, `hwirq=11`)

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
