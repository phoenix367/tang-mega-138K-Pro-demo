# vidplay — video playback on the AE350

`vidplay file` plays an MJPEG video (AVI or MP4/MKV container, AAC or MP3 audio) or a
bare MP3 on the Dock's 5" LCD and PT8211 DAC. It is the measurement vehicle for "can
this SoC decode video" as much as a player: single-threaded, no atomics, static musl,
built against the trimmed FFmpeg 7.1.1 from `scripts/rootfs/build_ffmpeg.sh` (decoders
mjpeg/aac/mp3, demuxers avi/mov/mp3/matroska/wav, swresample; no threads, no asm, dummy
atomics). H.264 was in until 2026-11-04 (the measurements are kept below); it is
memory-latency bound on this SoC and was dropped once MJPEG + the YUV scan-out + the
gateware JPEG decoder gave full-rate playback. `doc/08-applications.md` has the user's view
with pictures, `doc/07-cores.md` the gateware side.

Encoding for the panel (800×480; 16:9 sources become 800×450):
```
ffmpeg -i in.mp4 -vf scale=800:450 -c:v mjpeg -q:v 8 -pix_fmt yuvj420p -r 25 -c:a aac -b:a 128k out.mp4
```

```
vidplay [-D /dev/snd/pcmCxD0p] [-f /dev/fb0] [-n] [-b] [-v] [-1] [-O] [-P prof] [-C frames] file
   -1   no scaling: the picture 1:1, centred (default with gateware Build 71+: fit to the panel)
   -O   no playback bar (default with Build 71+: the bar is always shown)
   -n   no audio (video paced by the wall clock)
   -b   benchmark: decode everything as fast as possible, no display, no audio
   -v   per-second statistics on stderr
   -P   PC-sampling profile into a file (resolve with nm on vidplay.prof)
   -C   check: decode the first N video frames with the gateware and with FFmpeg's C
        code, compare them inside the picture, report the cost per frame; exit 0 = exact
```

- **Video path.** vidplay uses the fastest path the gateware and the kernel offer:
  - **Gateware JPEG decode** (Build 70, `jpeg_hw.c`): the headers are parsed here, and
    the tables and raw scan go to the IDCT core, which writes the frame into a scan-out
    buffer.
  - **FFmpeg's MJPEG decoder with the hardware IDCT** (Build 69, `idct_hw.c`).
  - **FFmpeg alone** (`idct_dsp.c`: an Andes-DSP IDCT, bit-exact).

  With gowin-lcdfb's YUV buffers (Build 68) the frame is decoded straight into scan-out
  memory, so nothing is converted or copied. The core's scaler (Build 71) fits it to the
  panel; `-1` gives 1:1, centred. Without YUV buffers the frame is converted to RGB565
  with integer BT.601 tables and written to `/dev/fb0` with `pwrite()`, centred and
  cropped.
- **Audio path:** libswresample to S16 stereo at the stream rate, written with the raw
  ALSA ioctls (`HW_PARAMS`/`WRITEI_FRAMES`, period 2048, buffer 16384 frames) like
  `wavplay`; the PT8211 core's NCO takes any rate.
- **Sync:** the audio clock (frames written minus `SNDRV_PCM_IOCTL_DELAY`) is the master.
  A video frame is shown when its pts is due. While behind, an intra-only stream (MJPEG)
  skips whole packets without decoding them; other codecs drop late frames (at most two
  in a row) and skip non-reference frames (`AVDISCARD_NONREF`). Without audio the wall
  clock paces.
- **Loop:** one packet queue per stream, filled ahead (512 packets each); the audio
  stage tops the ALSA ring up completely every iteration (a video decode costs ~60 ms,
  the ring holds 340 ms); a packet the video decoder refuses (`EAGAIN`) is retried, not
  dropped (dropping it loses slices and smears the following frames).
- **Switches (environment), for A/B tests and profiling:**
  - `VIDPLAY_NOHWJPEG`, `VIDPLAY_NOHWIDCT`, `VIDPLAY_NOYUV`: turn off the gateware JPEG
    path, the hardware IDCT, or the YUV buffers;
  - `VIDPLAY_OSDFREEZE`: draw the playback bar once and never update it;
  - `VIDPLAY_NOFB` (convert only) and `VIDPLAY_NOCONV` (framebuffer write only), for the
    RGB path;
  - `VIDPLAY_NOSKIP` (no catch-up skipping), `VIDPLAY_XRUNLOG` (log each ALSA underrun),
    `VIDPLAY_RING=frames` (ALSA buffer size, default 16384), `VIDPLAY_RING_KB` (IDCT
    record ring size).
- **Exit:** `SIGTERM`/`SIGINT` stop cleanly: ALSA drop, the panel back to the RGB
  desktop with the scaler and OSD off. The final `VIDPLAY ...` line gives the frames
  decoded / shown / dropped and the decode and show cost per frame. The hardware paths
  add their own counters.

The desktop's Files panel launches it for `.avi`/`.mp4`/`.mkv`/`.mp3`/`.m4a` files and
pauses its own rendering until it exits (any key or click stops the playback).

## Build

```sh
scripts/rootfs/build_ffmpeg.sh        # once: static libav* into ~/projects/ae350_linux_user_level/staging
make -C src/apps/vidplay && make -C src/apps/vidplay install
```

The Makefile checks the binary for `lr`/`sc`/`amo` instructions like the rootfs recipes do.

## YUV scan-out: no conversion at all (Build 68 + kernel #77)

With the gateware's YUV 4:2:0 scan-out mode, gowin-lcdfb owns six panel-sized planar
buffers (`include/uapi/linux/gowin-lcdfb.h`). vidplay mmap()s them and installs a
`get_buffer2` callback, so FFmpeg's decoders write every frame straight into one of them
(picture centred, black bars already there); showing a frame is `GOWIN_LCD_IOC_YUV_SHOW`,
which writes the buffer back from the CPU cache and points the core at it (the core flips
at the next frame boundary, so no tearing). The two most recently shown buffers are kept
out of the decoder's hands. The RGB565 conversion path below remains for streams that are
not yuv420p/yuvj420p, for older kernels or gateware, and under `VIDPLAY_NOYUV=1`.

Measured with audio, desktop running (2026-11-04):

| Clip, 25 fps | Decode | Shown | Note |
|---|---|---|---|
| MJPEG 480×270 | 16 ms/frame | 25 fps, 0 dropped | show = 2 ms (cache write-back) |
| MJPEG 640×360 | 26 ms | 25 fps, 0 dropped | |
| MJPEG 800×480 | 40 ms | 19.6 fps, 0 dropped | decode-bound; ~1 packet in 5 skipped undecoded to stay in sync |
| H.264 480×270 | 64 ms | ~7 frames/s | memory-latency bound, as before |

Intra-only streams catch up by skipping *packets* (never decoding them); decoding a frame
only to drop it would save nothing. For comparison the RGB path showed 800×480 MJPEG at
~5 frames/s (50 ms of conversion per frame on top of the decode).

(The 640×360 row above was measured before a geometry bug was found: the show ioctl was
given the centred picture's offsets as the scan-out base, so its chroma window ran past the
buffer and the driver refused every frame of a picture smaller than the panel. Since kernel
#78 the whole buffer is the scan-out window with the picture inside it, and the bars are
cleared once at start-up.)

## Hardware IDCT (Build 69 + kernel #78)

At 800×480 the profile said 55 % of the frame was `ff_simple_idct_put`, and most of that
was not arithmetic but the 8 scattered 8-byte row writes per block into a cold frame (a
write-allocate miss each, ~18 ms of the 40). `src/rtl/idct/` takes both: FFmpeg's `idct_put`
is wrapped (`idct_hw.c`) into a record per block -- header + the coefficients up to the
last nonzero one, four per 64-bit word -- in a ring the `gowin-idct` driver owns
(`/dev/gowin-idct`, mmap()ed cached); a `SUBMIT` (cache write-back + TAIL) whenever a luma
block starts a new 16-line band, three flush-only records + SUBMIT after
`avcodec_receive_frame`, `WAIT` right before the frame is shown, and `YUV_SHOW` with
`NOSYNC` (the CPU cache holds nothing of a buffer the core wrote; the buffer was dropped
from the cache by `YUV_DMA` when the frame began). The core transforms bit-exactly and
writes each band to the YUV planes as whole lines.

Measured with audio, desktop stopped (2026-11-04):

| Clip, 25 fps | CPU IDCT | Hardware IDCT | Shown |
|---|---|---|---|
| MJPEG 800×480 (q 8, MP3) | 42.6 ms/frame, 94 packets skipped in 20 s | 26.4 ms/frame | 25 fps, 1 packet skipped in 20 s |
| MJPEG 640×360 | 29.3 ms | 19.1 ms | 25 fps, 0 dropped |
| MJPEG 800×450 + AAC (a music video) | — | 20.8 ms | 25 fps, 0 dropped |

Where the remaining 26 ms at 800×480 go (PC-sample profile, `-P`): 33 % Huffman decoding
(`ff_mjpeg_decode_sos`), 24 % writing the records (the ring is cold memory too, ~1.5 lines
per record), 10 % the ioctls (cache write-back of the records, ~0.2 µs per line), 9 %
`memset`/`memcpy` in FFmpeg. A ring small enough to stay in L1 was tried (`VIDPLAY_RING_KB`,
`GOWIN_IDCT_IOC_RING`): 64 KB equals the 2 MB default, 16 KB and 8 KB are slower (more
ioctls, the core waits), so the default stays. The next lever would be an uncached mapping
for the ring (Andes PMA, set up in M-mode), which would remove the write-allocate misses and
the write-back. `VIDPLAY_NOHWIDCT=1` keeps the CPU path; `src/apps/tests/idcttest`
checks the core against a C model of FFmpeg's IDCT through a YUV buffer (`-x/-y` for an
offset picture, `-s` shows it).

## The gateware decodes the JPEG (Build 70)

Since Build 70 the IDCT core also does the entropy decoding (`src/rtl/idct/rtl/jpeg_entropy.v`),
so FFmpeg's MJPEG decoder is out of the video path altogether. For each video packet
`jpeg_hw.c` parses the JPEG headers (DQT, DHT, SOF0/1, DRI, SOS), sends the quantisation and
Huffman tables that changed since the last frame, and copies the scan's raw entropy-coded
bytes into the ring as one record; `idct_hw.c` adds the flush-only records and submits.
The core does Huffman decoding, dequantisation, the IDCT and the frame assembly, and the
frame is shown the same way as before. The CPU's share of a frame is the header parse,
copying ~10–20 KB into the ring and one cache write-back.

The subset is baseline/extended sequential Huffman JPEG, 8-bit, Y 2×2 + Cb 1×1 + Cr 1×1 in
one scan, 8-bit quantisation tables, two DC and two AC tables, any restart interval: what
ffmpeg's encoder and most MJPEG cameras produce. The first packet outside it, or with a
size other than the stream's, hands the stream to FFmpeg's decoder (with the hardware
IDCT) for the rest of the file. Tables start as FFmpeg's defaults (JPEG Annex K) and
persist across frames, as in FFmpeg. `VIDPLAY_NOHWJPEG=1` keeps FFmpeg's decoder.

Bit-exactness, `vidplay -C`, all frames identical to FFmpeg's C decoder:

| Clip | Frames checked | Gateware, per frame | FFmpeg on the CPU, per frame |
|---|---|---|---|
| MJPEG 800×480, q 8 | 150 | 13.7 ms | 38.8 ms |
| MJPEG 640×360 | 150 | 9.0 ms | 24.8 ms |
| MJPEG 480×270 | 150 | 6.1 ms | 15.5 ms |
| Music video, 800×450 + AAC | 1500, one minute | 11.9 ms | 32.9 ms |

The gateware column is CPU work plus waiting for the core. The core itself needs about
12 ms per 800×480 frame on the real bus, so it could keep up with ~80 fps.

Playback with audio, desktop stopped, 20 s per clip (2026-11-04):

| Clip | Decode CPU per frame: FFmpeg + hardware IDCT | Gateware JPEG | Shown | System CPU load |
|---|---|---|---|---|
| MJPEG 800×480 + MP3 | 29.5 ms, 32 packets skipped | 1.2 ms | 25 fps, nothing skipped | 85 % before, 31 % now |
| MJPEG 640×360 + MP3 | 21.0 ms, 6 packets skipped | 1.1 ms | 25 fps | |
| Music video, 800×450 + AAC | 21.1 ms | 1.1 ms | 25 fps | 79 % before, 37 % now |

What is left of the CPU load is the audio decoder, resampling and the player loop.

## Scaling and the info bar (Build 71)

With gateware Build 71 the LCD core has a nearest-neighbour scaler and an ARGB8888 OSD
layer (`src/rtl/video/README.md`). vidplay decodes the picture at its own size at the
origin of the scan-out buffer, in a plane layout made for the stream (32-byte strides,
whole MCU rows). `GOWIN_LCD_IOC_SCALE` then fits the picture to the panel with the
aspect kept: 480×270 and 640×360 fill 800×450, centred with black bars, and pictures
larger than the panel shrink. The driver's buffers hold sources up to 1280×768
(kernel #93+; 1024×768 from #85), and the IDCT core takes MJPEG up to 2048 wide (Build
72+; 1024 before). 720p therefore plays on the gateware path; see "720p" below. No CPU time goes into
scaling, and a small clip decodes as fast as before.

Checked with the music video re-encoded at 852×480, wider than the panel. `vidplay -C 300`
found every frame identical to FFmpeg's decode, with the gateware at 13.6 ms per frame
against 35.5 ms for the CPU. It plays at 25 fps, decode CPU 1.6 ms per frame, and the
core scales it to 800×450. `scaletest` has the same 852×480 → 800×450 factor as a scene
checked by frame CRC.

The playback bar is `osd.c`: a 64-line strip at the bottom of the panel, always shown.
The panel is semi-transparent near-black at 60 % alpha. On it sit an opaque slider
(a grey track, the played part in blue, a white knob) and the title and
`position / duration` in opaque white. Every shape is anti-aliased, and only the edges
blend into the panel.

It is drawn in software into one of the driver's two OSD buffers, at most once a second,
and flipped with `GOWIN_LCD_IOC_OSD`. After a buffer's first full draw only the slider
band and the time are repainted. The core blends the layer in hardware, so the video
path is untouched and updates never tear. The font is DejaVu Sans at 20 px,
anti-aliased, generated by `mkfont.py` into `osd_font.h` (`make font`).

Measured on the board with the music video (800×450 MJPEG + AAC, gateware JPEG path),
system CPU load over 15 s:

| Info bar | CPU load |
|---|---|
| off (`-O`) | 37.5 % |
| on, the first design (`-o`) | 38.8–39.8 % |
| on, frozen after its first draw (`VIDPLAY_OSDFREEZE=1`) | 37.7–37.9 % |

So the layer's DDR traffic costs nothing measurable, and the once-a-second repaint of
the progress line and the time, with its cache write-back, costs ~1.5 %. The first
version cost ~4 %: it formatted the time strings on every loop iteration, about 500
times a second, and redrew the whole strip, ~10 ms of cache misses, whenever the
progress line moved a pixel.
Fit-to-panel scaling costs no CPU: 480×270 MJPEG decodes in 1.1–1.2 ms per frame on the
gateware path either way.

## 720p (Build 72 + kernel #93, 2026-11-05)

Before Build 72, 1280-wide video fell back to FFmpeg's C decoder: 84 ms per frame, so
~9 fps were shown and the rest skipped. 1280×720 did not fit a scan-out buffer at all and
played sound only. Three changes fixed that:
- **Gateware:** the IDCT core's band RAMs hold 2048-pixel luma / 1024-pixel chroma lines.
  STATUS[9] says so, and `gowin-idct` reports `max_width` 2048 from it.
- **Kernel:** gowin-lcdfb's YUV buffers default to 1280×768 (`yuv_max_w`), 1440 KB each.
- **vidplay:** takes the width limit from the driver, and decodes one frame ahead
  (below).

`vidplay -C 300` on 1280×720 clips is bit-exact with FFmpeg's C decoder. Per frame the
gateware path costs 27 ms against 84 ms on the CPU. `VIDPLAY_CHECKLOG=1` prints each
frame's size, the CPU's parse and copy (2–4 ms), and the wait for the core. The core
time fits **23.4 ms + 0.083 ms per KB** of JPEG data: the IDCT of 21 600 blocks
dominates, and even a 140 KB frame takes 34 ms of the 40–42 ms a frame may last.

**Decode ahead.** Until now the next frame went to the core only after the pending one
was shown. With 34 ms frames that left a few milliseconds per period, and the audio
stage and the loop's sleep ate them: the densest clip skipped 11 % of its frames. Now
the loop asks the core whether it is idle (`idct_hw_idle()`, a STATUS ioctl, no wait),
and if it is, the next frame starts while the decoded one waits for its time.
`yuv_show()` waits only for the buffer still in flight. 720p music videos, full length
from the SD card, `lcdmon` watching the panel:

| Clip (MJPEG q 8 + AAC) | Frames | Largest frame | Skipped | Holds ≥ 95 ms | Longest hold |
|---|---|---|---|---|---|
| Tora – "Eat The Sun", 1280×720, 25 fps | 5619 | 71 KB | 0 | 0 | 57 ms |
| Ensiferum – "Andromeda", 1280×720, 24 fps | 6134 | 72 KB | 0 | 0 | 57 ms |
| Cavetown – "Green", 1280×524, 30 fps | 8116 | 45 KB | 0 | 0 | 57 ms |
| S. Mergenthaler – "Sound Asleep", 1280×720, 24 fps, before decode ahead | 7608 | 148 KB | 873 | 217 | 191 ms |
| the same with decode ahead | 7608 | 148 KB | 57 | 0 | 76 ms |

The rest of "Sound Asleep" (a frame in 130 skipped) is in its densest scenes, where
the 3 ms parse plus the core's ~34 ms leave no margin. Hiding the parse as well would
take frame setup as a ring record, so that the next frame's records could go in
while the core is still busy. CPU load at 720p is 56–60 %.

## Frame timing on the panel: no hitches (2026-11-04)

The panel refreshes at 52.47 Hz (19.06 ms: the 33.3 MHz pixel clock over the panel's
total line and frame lengths). `YUV_SHOW` only points the core at a buffer; the core
takes it over at the next frame end. So a 25 fps picture normally stays up for 2
refreshes and every tenth one for 3, 24 fps for 2 or 3, and 30 fps for 1 or 2. A flip
that lands within a ms or two of a frame end can move by one refresh (19 ms) either
way. A hitch is a picture held well beyond that: the next one came late, or the
player skipped a packet to catch up.

`src/apps/tests/lcdmon` measures this at the panel. It records the buffer every
refresh scanned out, which works because FRAMES and the FB_BASE latch change in the same
bus cycle. With 852×480 music videos (MJPEG + AAC, gateware JPEG path) started from a
shell while the desktop ran, there was a picture held 5–9 refreshes (95–172 ms) about
every 10 s, often in pairs ~1.9 s apart, plus 3–10 skipped packets per clip. The
desktop was the cause, not the decoder (the core needs 10–20 ms even for the largest
frames). Until now lvdesk kept running LVGL while its vidplay child played: it sampled
and rendered the status bar every second and only skipped the flush. Tora – "Eat The
Sun", 852×480 at 25 fps, 120 s each run:

| Run | Holds ≥ 5 refreshes | Longest hold | Packets skipped |
|---|---|---|---|
| from a shell, desktop running | 13 | 133 ms | 6 |
| from a shell, desktop running, no playback bar (`-O`) | 14 | 152 ms | 9 |
| from a shell, desktop stopped | 2 | 95 ms | 0 |
| from the Files panel, before the fix | 8 | 152 ms | 1 |
| from the Files panel, now | **0** | **57 ms** | **0** |

The playback bar is not involved. The desktop now does no LVGL work while vidplay
runs: its main loop only sleeps in `poll()` on the input devices (`video_wait()` in
`panels.c`), so a key or click still stops the video. vidplay also raises itself to
nice -10 when allowed, which it is as root, as the desktop starts it. Other
background work then waits for it, for example `inputd` answering `netinput.py --view`
frame requests (a 768 KB compare each), and the shell daemons. vidplay does not use
SCHED_FIFO: a CPU-bound decode has to leave `inputd` room to deliver the stop key.

## MJPEG: the codec that fits this SoC

Intra-only video has no reference frames, so the decoder walks memory sequentially
instead of chasing motion vectors through a cold cache. With FFmpeg's `mjpeg` decoder
and the `avi` demuxer (both in the trimmed build), the same player measures:

| MJPEG clip (q 8, MP3 audio) | Decode only | Playback with audio |
|---|---|---|
| 480×270 25 fps | 59 fps (16 ms/frame) | ~21 frames/s shown (289 of 334), no underruns |
| 640×360 25 fps | 36 fps (26 ms) | ~7 frames/s shown: conversion + write now dominate (35 ms) |
| 800×480 25 fps | 23 fps (40 ms) | ~5 frames/s shown (52 ms conversion + write) |

So MJPEG gives smooth 480×270 playback today, and the full panel is within reach of the
decoder; what remains is the YUV→RGB565 pass plus the framebuffer write. A JPEG decoder
that emits RGB565 blocks straight into the row buffer (ChaN's TJpgDec, as used by
vadrov/stm32f4_fast_optimized_avi_player_osd on an 84 MHz Cortex-M4) would remove the
intermediate YUV frame and its 1.1 MB of DRAM traffic per 800×480 frame; a cached
framebuffer mapping with an explicit flush ioctl in gowin-lcdfb would remove the kernel
copy. Encode with
`ffmpeg -i in.mp4 -c:v mjpeg -q:v 8 -pix_fmt yuvj420p -s 480x270 -r 25 -c:a libmp3lame -b:a 128k out.avi`.

## H.264 measurements (A25 @ 800 MHz, desktop running, 2026-11-04)

Decode only (`-b`), 20 s synthetic clips (testsrc2, x264 crf 23, 761 kbit/s at 360p):

| Clip | Default | Loop filter off (`-L`) |
|---|---|---|
| 480×270 main | 15.5 fps (59 ms/frame) | 20.3 fps (47 ms) |
| 640×360 main | 9.6 fps (98 ms) | — |
| 640×360 baseline | 12.0 fps (78 ms) | 17.4 fps (56 ms) |

`AV_CODEC_FLAG2_FAST` changes nothing; AAC decoding costs about 5 %. Display of a
480×270 frame: 12 ms conversion + 5 ms `pwrite()` (34 ms before the switch from the
deferred-I/O mmap). So a 480×270 frame costs ~80 ms all in: **~12 fps** decode
throughput. Real playback with audio, measured on the same clips: the 12-fps demo shows
~7.5 frames/s (100 of 109 decoded), the 25-fps clip ~5 frames/s (the decoder skips
non-reference frames while behind, late frames are dropped at most two in a row, audio
stays in sync, no underruns). `AVDISCARD_BIDIR` would decode fewer frames still but
corrupts the picture with x264's B-pyramid streams, so only `AVDISCARD_NONREF` is used.
`-L` is **not** usable on normal streams: skipping the in-loop filter makes every
predicted frame drift from the encoder's (filtered) references and the picture smears
until the next keyframe; it only helps for streams encoded without deblocking.

Why so slow for an 800 MHz core: this AE350 has no L2 cache and a dependent cache-miss
latency of ~1.4 µs (src/rtl/ddr_bridge/README.md), and H.264 decoding (motion
compensation, reference frames) misses the 32 KB L1 constantly, as does reading the
decoded frame back for conversion. The decoder is latency bound, not arithmetic bound,
which is also why the Andes DSP instructions (present on this part, see CLAUDE.md) are
not the lever. For smooth playback encode at ≤ 480×270 and ≤ 12 fps, or ≤ 360×200 at 25 fps.
