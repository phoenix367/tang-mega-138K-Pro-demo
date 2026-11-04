# vidplay — video playback on the AE350

`vidplay file` plays an MJPEG video (AVI or MP4/MKV container, AAC or MP3 audio) or a
bare MP3 on the Dock's 5" LCD and PT8211 DAC. It is the measurement vehicle for "can
this SoC decode video" as much as a player: single-threaded, no atomics, static musl,
built against the trimmed FFmpeg 7.1.1 from `scripts/rootfs/build_ffmpeg.sh` (decoders
mjpeg/aac/mp3, demuxers avi/mov/mp3/matroska/wav, swresample; no threads, no asm, dummy
atomics). H.264 was in until 2026-11-04 (the measurements are kept below); it is
memory-latency bound on this SoC and was dropped once MJPEG + the YUV scan-out + the
hardware IDCT gave full-rate playback.

Encoding for the panel (800×480; 16:9 sources become 800×450):
```
ffmpeg -i in.mp4 -vf scale=800:450 -c:v mjpeg -q:v 8 -pix_fmt yuvj420p -r 25 -c:a aac -b:a 128k out.mp4
```

```
vidplay [-D /dev/snd/pcmCxD0p] [-f /dev/fb0] [-n] [-b] [-v] [-1] [-o|-O] [-P prof] [-C frames] file
   -1   no scaling: the picture 1:1, centred (default with gateware Build 71+: fit to the panel)
   -O   no playback bar (default with Build 71+: the bar is always shown)
   -n   no audio (video paced by the wall clock)
   -b   benchmark: decode everything as fast as possible, no display, no audio
   -v   per-second statistics on stderr
   -P   PC-sampling profile into a file (resolve with nm on vidplay.prof)
   -C   check: decode the first N video frames with the gateware and with FFmpeg's C
        code, compare them inside the picture, report the cost per frame; exit 0 = exact
```

- **Video path:** libavcodec decodes to YUV420P; `yuv_rows()` converts two rows at a time
  to RGB565 with integer BT.601 tables into a cached row buffer that is `memcpy`'d into the
  mmap'd `/dev/fb0`. The picture is drawn 1:1 and centred (black bars); frames larger than
  800×480 are centre-cropped. No scaling: the CPU budget belongs to the decoder.
- **Audio path:** libswresample to S16 stereo at the stream rate, written with the raw
  ALSA ioctls (`HW_PARAMS`/`WRITEI_FRAMES`, period 2048, buffer 16384 frames) like
  `wavplay`; the PT8211 core's NCO takes any rate.
- **Sync:** the audio clock (frames written minus `SNDRV_PCM_IOCTL_DELAY`) is the master.
  A video frame is shown when its pts is due, dropped (not converted) when more than one
  frame period late, and while behind the decoder skips non-reference frames
  (`AVDISCARD_NONREF`). Without audio the wall clock paces.
- **Loop:** one packet queue per stream, filled ahead (512 packets each); the audio
  stage tops the ALSA ring up completely every iteration (a video decode costs ~60 ms,
  the ring holds 340 ms); a packet the video decoder refuses (`EAGAIN`) is retried, not
  dropped (dropping it loses slices and smears the following frames).
- **Profiling switches (environment):** `VIDPLAY_NOFB` (convert only), `VIDPLAY_NOCONV`
  (framebuffer write only), `VIDPLAY_NOSKIP` (no decoder-side skipping), `VIDPLAY_XRUNLOG`
  (log each ALSA underrun), `VIDPLAY_RING=frames` (ALSA buffer size, default 16384).
- **Exit:** `SIGTERM`/`SIGINT` stop cleanly (ALSA drop, framebuffer cleared); the final
  `VIDPLAY ...` line gives frames decoded/shown/dropped and the decode and convert cost
  per frame.

The desktop's Files panel launches it for `.mp4`/`.mkv`/`.mp3` files and pauses its own
rendering until it exits (any key or click stops the playback).

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
larger than the panel shrink. The driver's buffers hold sources up to 1024×768
(kernel #85+), and the IDCT core takes MJPEG up to 1024 wide. No CPU time goes into
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
