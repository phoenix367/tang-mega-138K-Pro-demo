/*
 * vidplay -- MP4/MKV/MP3 player for the Tang Mega 138K Pro Dock: H.264 (and whatever
 * else the trimmed FFmpeg build decodes) to the LCD framebuffer, AAC/MP3 to the PT8211
 * through ALSA's raw ioctl interface (as wavplay does).  Single-threaded, no atomics,
 * built against the static libav* from scripts/rootfs/build_ffmpeg.sh.
 *
 *   vidplay [-D /dev/snd/pcmCxD0p] [-f /dev/fb0] [-n] [-b] [-v] [-L] [-F] file
 *     -n   no audio (video paced by the wall clock)
 *     -b   benchmark: decode everything as fast as possible, no display, no audio
 *     -v   verbose per-second statistics
 *     -L   skip the in-loop deblocking filter (faster, slightly blockier)
 *     -F   allow non-compliant speedups (AV_CODEC_FLAG2_FAST)
 *     -P FILE  sample the program counter every millisecond (SIGPROF) into FILE for
 *              a poor man's profile: resolve with `nm -n vidplay.prof` on the host
 *
 * Sync: the audio clock (frames handed to ALSA minus what is still queued, DELAY ioctl)
 * is the master.  A video frame is shown when its pts is due; a frame more than one
 * frame period late is dropped (not converted), and while behind, non-reference frames
 * are skipped in the decoder.  Without an audio stream the wall clock paces.
 *
 * The picture is drawn 1:1, centred, black bars around it (no scaling: the CPU budget
 * goes to the decoder); frames larger than the panel are centre-cropped.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <ucontext.h>
#include <linux/fb.h>
#include "gowin-lcdfb.h"             /* YUV scan-out buffers of gowin-lcdfb (gateware Build 68+) */
#include "idct_hw.h"                 /* the hardware IDCT core (gateware Build 69+, /dev/gowin-idct) */
#include "jpeg_hw.h"                 /* ... and its JPEG entropy decoder (Build 70+) */
#include "osd.h"                     /* info bar on the LCD core's OSD layer (Build 71+) */
#include <sound/asound.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>

static volatile sig_atomic_t g_stop;
static void on_term(int sig) { (void)sig; g_stop = 1; }

/* ---- the DSP IDCT (idct_dsp.c) against FFmpeg's: VIDPLAY_IDCTTEST=1 ----------- */
static double now_s(void);
void __real_ff_simple_idct_put_int16_8bit(uint8_t *dest, ptrdiff_t line_size, int16_t *block);
void __wrap_ff_simple_idct_put_int16_8bit(uint8_t *dest, ptrdiff_t line_size, int16_t *block);
extern int idct_use_c, idct_no_stage;
void idct_stage_setup(uint8_t *y, uint8_t *u, uint8_t *v, int ys, int cs, int w, int h);
void idct_stage_flush(void);

static void idct_selftest(void)
{
    enum { NB = 256, ITER = 40000 };
    static int16_t blocks[NB][64];
    int16_t b1[64], b2[64];
    uint8_t d1[64], d2[64];
    unsigned seed = 12345, bad = 0, dconly = 0, sparse_n = 0;
    for (unsigned t = 0; t < NB; t++) {                 /* a cache-resident set of typical blocks */
        int sparse = t & 3;
        for (int i = 0; i < 64; i++) {
            seed = seed * 1103515245u + 12345u;
            int v = (int)(seed >> 16) % 2048 - 1024;
            if (sparse && i > (int)((seed >> 8) % 12) && (seed & 7)) v = 0;
            if (t % 16 == 0 && i) v = 0;
            blocks[t][i] = v;
        }
        if (t % 16 == 0) dconly++; else if (sparse) sparse_n++;
    }
    for (unsigned t = 0; t < NB; t++) {                 /* equivalence */
        memcpy(b1, blocks[t], 128); memcpy(b2, blocks[t], 128);
        __real_ff_simple_idct_put_int16_8bit(d1, 8, b1);
        __wrap_ff_simple_idct_put_int16_8bit(d2, 8, b2);
        if (memcmp(d1, d2, 64)) { bad++; if (bad < 4) fprintf(stderr, "idct mismatch in block %u\n", t); }
    }
    double t0 = now_s();                                /* compute cost, everything in L1 */
    for (unsigned t = 0; t < ITER; t++) { memcpy(b1, blocks[t % NB], 128); __real_ff_simple_idct_put_int16_8bit(d1, 8, b1); }
    double tc = now_s() - t0; t0 = now_s();
    for (unsigned t = 0; t < ITER; t++) { memcpy(b2, blocks[t % NB], 128); __wrap_ff_simple_idct_put_int16_8bit(d2, 8, b2); }
    double td = now_s() - t0;
    fprintf(stderr, "IDCTTEST: %u blocks (%u DC-only, %u sparse), %u mismatches; hot-cache cost C %.2f us/block, DSP %.2f us/block (%.2fx)\n",
            NB, dconly, sparse_n, bad, tc * 1e6 / ITER, td * 1e6 / ITER, td > 0 ? tc / td : 0);
    /* the same blocks written into a cold 800x480 luma plane in decoder order
     * (8x8 blocks left to right, 8 lines at a time): the memory side of the cost */
    enum { FW = 800, FH = 480, NBX = FW / 8, NBY = FH / 8 };
    uint8_t *frame = malloc(FW * FH);
    for (int pass = 0; pass < 2; pass++) {
        double tcc = 0, tdc = 0;
        for (int rep = 0; rep < 3; rep++) {
            t0 = now_s();
            for (unsigned t = 0; t < NBX * NBY; t++) {
                memcpy(b1, blocks[t % NB], 128);
                if (pass) __wrap_ff_simple_idct_put_int16_8bit(frame + (t / NBX) * 8 * FW + (t % NBX) * 8, FW, b1);
                else      __real_ff_simple_idct_put_int16_8bit(frame + (t / NBX) * 8 * FW + (t % NBX) * 8, FW, b1);
            }
            if (pass) tdc += now_s() - t0; else tcc += now_s() - t0;
        }
        fprintf(stderr, "IDCTTEST: cold 800x480 plane, %s: %.2f us/block (%.1f ms per luma plane)\n",
                pass ? "DSP" : "C", (pass ? tdc : tcc) * 1e6 / (3.0 * NBX * NBY), (pass ? tdc : tcc) * 1e3 / 3);
    }
    {   /* the same cold plane written through the band staging (sequential flushes) */
        double ts = 0;
        for (int rep = 0; rep < 3; rep++) {
            idct_stage_setup(frame, NULL, NULL, FW, 0, FW, FH);
            t0 = now_s();
            for (unsigned t = 0; t < NBX * NBY; t++) {
                memcpy(b1, blocks[t % NB], 128);
                __wrap_ff_simple_idct_put_int16_8bit(frame + (t / NBX) * 8 * FW + (t % NBX) * 8, FW, b1);
            }
            idct_stage_flush();
            ts += now_s() - t0;
        }
        fprintf(stderr, "IDCTTEST: cold 800x480 plane, DSP + band staging: %.2f us/block (%.1f ms per luma plane)\n",
                ts * 1e6 / (3.0 * NBX * NBY), ts * 1e3 / 3);
        idct_stage_setup(NULL, NULL, NULL, 0, 0, 0, 0);
    }
    free(frame);
}

/* ---- PC sampling profiler (-P): one 32-bit PC per SIGPROF tick ------------- */
#define PROF_MAX (1 << 18)
static uint32_t *prof_buf;
static volatile unsigned prof_n;
static void on_prof(int sig, siginfo_t *si, void *uc)
{
    (void)sig; (void)si;
    if (prof_n < PROF_MAX) prof_buf[prof_n++] = (uint32_t)((ucontext_t *)uc)->uc_mcontext.__gregs[REG_PC];
}
static void prof_start(void)
{
    prof_buf = malloc(PROF_MAX * sizeof(uint32_t));
    struct sigaction sa = { .sa_sigaction = on_prof, .sa_flags = SA_SIGINFO | SA_RESTART };
    sigaction(SIGPROF, &sa, NULL);
    struct itimerval it = { { 0, 1000 }, { 0, 1000 } };
    setitimer(ITIMER_PROF, &it, NULL);
}
static void prof_stop(const char *path)
{
    struct itimerval it = { { 0, 0 }, { 0, 0 } };
    setitimer(ITIMER_PROF, &it, NULL);
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(prof_buf, sizeof(uint32_t), prof_n, f); fclose(f); }
    fprintf(stderr, "profile: %u samples -> %s\n", prof_n, path);
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---- framebuffer ------------------------------------------------------- */
static struct { int fd, w, h, ll; uint8_t *mem; size_t len; } fb = { .fd = -1 };

static int fb_open(const char *path)
{
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    fb.fd = open(path, O_RDWR);
    if (fb.fd < 0 || ioctl(fb.fd, FBIOGET_VSCREENINFO, &var) || ioctl(fb.fd, FBIOGET_FSCREENINFO, &fix)) {
        perror(path);
        return -1;
    }
    if (var.bits_per_pixel != 16) { fprintf(stderr, "%s: %u bpp, need RGB565\n", path, var.bits_per_pixel); return -1; }
    fb.w = var.xres; fb.h = var.yres; fb.ll = fix.line_length; fb.len = fix.smem_len;
    fb.mem = mmap(NULL, fb.len, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd, 0);
    if (fb.mem == MAP_FAILED) { perror("mmap fb"); return -1; }
    /* not cleared here: on the YUV scan-out path the RGB framebuffer is never drawn into
     * and the desktop's screen is still in it when the driver switches back on exit */
    return 0;
}
static int fb_drawn;          /* the RGB path drew into the framebuffer (clear it at exit) */

/* ---- YUV420 -> RGB565 (BT.601 limited range, integer, table driven) ----- */
static int32_t tY[256], tRV[256], tGU[256], tGV[256], tBU[256];
static uint8_t clampt[1024 + 256];      /* index = value + 256 */

static void yuv_tables(void)
{
    for (int i = 0; i < 256; i++) {
        tY[i] = 298 * (i - 16) + 128;
        tRV[i] = 409 * (i - 128);
        tGU[i] = -100 * (i - 128);
        tGV[i] = -208 * (i - 128);
        tBU[i] = 516 * (i - 128);
    }
    for (int i = 0; i < (int)sizeof(clampt); i++) {
        int v = i - 256;
        clampt[i] = v < 0 ? 0 : v > 255 ? 255 : v;
    }
}

#define CLAMP8(v) clampt[((v) >> 8) + 256]

/* convert one pair of rows (2 luma rows share one chroma row) into two RGB565 rows */
static void yuv_rows(const uint8_t *y0, const uint8_t *y1, const uint8_t *u, const uint8_t *v,
                     uint16_t *d0, uint16_t *d1, int w)
{
    for (int x = 0; x < w; x += 2) {
        int cu = u[x >> 1], cv = v[x >> 1];
        int rv = tRV[cv], gu = tGU[cu] + tGV[cv], bu = tBU[cu];
        for (int k = 0; k < 2; k++) {
            int c = tY[y0[x + k]];
            d0[x + k] = (CLAMP8(c + rv) >> 3) << 11 | (CLAMP8(c + gu) >> 2) << 5 | (CLAMP8(c + bu) >> 3);
            c = tY[y1[x + k]];
            d1[x + k] = (CLAMP8(c + rv) >> 3) << 11 | (CLAMP8(c + gu) >> 2) << 5 | (CLAMP8(c + bu) >> 3);
        }
    }
}

/* ---- YUV 4:2:0 scan-out: the decoder writes into the driver's buffers ----- */
/* With a Build 68+ gateware the LCD core scans planar YUV 4:2:0 itself.  The
 * driver owns a few buffers; we hand them to FFmpeg through get_buffer2() so a
 * decoded frame already sits in scan-out memory, and showing it is one ioctl
 * (cache write-back + a flip the core applies at the next frame boundary).
 * No conversion, no copy.  The two most recently shown buffers are not handed
 * out again (the core may still scan the previous one for a frame). */
static struct {
    int on;
    struct gowin_lcd_yuv_info info;
    uint8_t *buf[8];
    int free[8];
    int hw[8];                 /* the buffer's picture was written by the IDCT core (CPU cache clean) */
    int shown, prev;
    unsigned nobuf;            /* frames that got no scan-out buffer (decoded elsewhere, not shown) */
    int scale;                 /* the core's scaler fits the picture to the panel (Build 71+): */
    int scaled;                /*   the picture sits at the buffer's origin; window set */
    /* the planes' layout in a buffer: the driver's panel layout, or (scaler) the stream's own,
     * which lets a picture larger than the panel in (the driver's buffers hold up to 1024x768) */
    struct { unsigned y_stride, c_stride, u_off, v_off, max_w, max_h; } lay;
} yuvo = { .shown = -1, .prev = -1 };
static int opt_scale = 1, opt_osd = 1;     /* -1: 1:1; -O: no playback bar */

/* where the picture goes in a panel-sized buffer: its origin when the core scales,
 * else centred (Y start 32-byte aligned, even row) */
static void yuv_place(int w, int h, int *dx, int *dy)
{
    int W = yuvo.info.width, H = yuvo.info.height;
    *dx = yuvo.scale ? 0 : (W - w) / 2 & ~31;
    *dy = yuvo.scale ? 0 : (H - h) / 2 & ~1;
}

/* the scaler window: the picture fitted to the panel, aspect kept, centred */
static void yuv_scale(int w, int h)
{
    unsigned W = yuvo.info.width, H = yuvo.info.height, dw, dh;
    if ((uint64_t)W * h <= (uint64_t)H * w) { dw = W; dh = (unsigned)(((uint64_t)h * W + w / 2) / w) & ~1u; }
    else { dh = H; dw = (unsigned)(((uint64_t)w * H + h / 2) / h) & ~1u; }
    if (dw < 2) dw = 2;
    if (dh < 2) dh = 2;
    struct gowin_lcd_scale sc = { .flags = GOWIN_LCD_SCALE_ON, .src_w = w, .src_h = h,
                                  .dst_x = (W - dw) / 2, .dst_y = (H - dh) / 2, .dst_w = dw, .dst_h = dh, .bg = 0 };
    if (ioctl(fb.fd, GOWIN_LCD_IOC_SCALE, &sc)) { perror("scale"); yuvo.scale = 0; return; }
    fprintf(stderr, "  scaled by the LCD core: %dx%d -> %ux%u at (%u,%u)\n", w, h, dw, dh, sc.dst_x, sc.dst_y);
}

static struct { int on; unsigned frames; } jhw;   /* MJPEG through the core's entropy decoder */
static double now_s(void);

static void yuv_release(void *opaque, uint8_t *data) { (void)data; yuvo.free[(int)(intptr_t)opaque] = 1; }

static int yuv_get_buffer(AVCodecContext *s, AVFrame *f, int flags)
{
    int i, w = f->width, h = f->height;
    for (i = 0; i < (int)yuvo.info.nbuf; i++)
        if (yuvo.free[i] && i != yuvo.shown && i != yuvo.prev) break;
    if (i == (int)yuvo.info.nbuf || w > (int)yuvo.lay.max_w || h > (int)yuvo.lay.max_h) {
        yuvo.nobuf++;
        f->opaque = NULL;
        return avcodec_default_get_buffer2(s, f, flags);
    }
    /* the picture centred in the panel-sized buffer: Y start 32-byte aligned, even row */
    int dx, dy;
    yuv_place(w, h, &dx, &dy);
    uint8_t *b = yuvo.buf[i];
    f->buf[0] = av_buffer_create(b, yuvo.info.buf_size, yuv_release, (void *)(intptr_t)i, 0);
    if (!f->buf[0]) return AVERROR(ENOMEM);
    yuvo.free[i] = 0;
    f->data[0] = b + dy * yuvo.lay.y_stride + dx;
    f->data[1] = b + yuvo.lay.u_off + (dy / 2) * yuvo.lay.c_stride + dx / 2;
    f->data[2] = b + yuvo.lay.v_off + (dy / 2) * yuvo.lay.c_stride + dx / 2;
    f->linesize[0] = yuvo.lay.y_stride;
    f->linesize[1] = f->linesize[2] = yuvo.lay.c_stride;
    f->extended_data = f->data;
    f->opaque = (void *)(intptr_t)(i + 1);
    /* the hardware IDCT writes the planes itself (coded size: whole MCUs), else the CPU */
    int cw = s->coded_width > 0 ? (s->coded_width + 15) & ~15 : (w + 15) & ~15;
    int ch = s->coded_height > 0 ? (s->coded_height + 15) & ~15 : (h + 15) & ~15;
    yuvo.hw[i] = dx + cw <= (int)yuvo.lay.max_w && dy + ch <= (int)yuvo.lay.max_h &&
                 idct_hw_frame_begin(i, b, f->data[0], f->data[1], f->data[2], f->linesize[0], f->linesize[1],
                                     cw, ch, w, h) == 0;
    if (!yuvo.hw[i])
        idct_stage_setup(f->data[0], f->data[1], f->data[2], f->linesize[0], f->linesize[1], w, h);
    return 0;
}

/* enable the YUV path for this decoder if the driver and the format allow it */
static void yuv_setup(AVCodecContext *vc, const AVCodecParameters *par)
{
    if (fb.fd < 0 || ioctl(fb.fd, GOWIN_LCD_IOC_YUV_INFO, &yuvo.info) || yuvo.info.nbuf < 3) return;
    if (par->format != AV_PIX_FMT_YUV420P && par->format != AV_PIX_FMT_YUVJ420P) return;
    if (yuvo.info.nbuf > 8) yuvo.info.nbuf = 8;
    /* the layout: the driver's (panel) one, or with the scaler the stream's own (whole
     * 16-line MCU rows, 32-byte strides) if it fits a buffer */
    yuvo.lay.y_stride = yuvo.info.y_stride; yuvo.lay.c_stride = yuvo.info.c_stride;
    yuvo.lay.u_off = yuvo.info.u_off; yuvo.lay.v_off = yuvo.info.v_off;
    yuvo.lay.max_w = yuvo.info.width; yuvo.lay.max_h = yuvo.info.height;
    struct gowin_lcd_caps caps;
    if (opt_scale && par->width > 0 && par->height > 0 &&
        !ioctl(fb.fd, GOWIN_LCD_IOC_CAPS, &caps) && (caps.caps & GOWIN_LCD_CAP_SCALE)) {
        unsigned cw = (par->width + 15) & ~15u, ch = (par->height + 15) & ~15u;
        unsigned ys = (cw + 31) & ~31u, cs = (cw / 2 + 31) & ~31u;
        if ((size_t)ys * ch + 2 * (size_t)cs * (ch / 2) <= yuvo.info.buf_size) {
            yuvo.scale = 1;
            yuvo.lay.y_stride = ys; yuvo.lay.c_stride = cs;
            yuvo.lay.u_off = ys * ch; yuvo.lay.v_off = ys * ch + cs * (ch / 2);
            yuvo.lay.max_w = ys; yuvo.lay.max_h = ch;
        }
    }
    for (unsigned i = 0; i < yuvo.info.nbuf; i++) {
        yuvo.buf[i] = mmap(NULL, yuvo.info.buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb.fd,
                           (off_t)yuvo.info.mmap_off + (off_t)i * yuvo.info.buf_size);
        if (yuvo.buf[i] == MAP_FAILED) { perror("mmap yuv buffer"); yuvo.info.nbuf = i; break; }
        yuvo.free[i] = 1;
        /* black bars around the picture (the whole buffer is scanned out): Y 0, U/V 128, in DRAM */
        memset(yuvo.buf[i], 0, yuvo.lay.u_off);
        memset(yuvo.buf[i] + yuvo.lay.u_off, 128, yuvo.info.buf_size - yuvo.lay.u_off);
        struct gowin_lcd_yuv_dma d = { .buf = i, .flags = GOWIN_LCD_YUV_DMA_WRITEBACK };
        ioctl(fb.fd, GOWIN_LCD_IOC_YUV_DMA, &d);       /* an old kernel: YUV_SHOW writes it back anyway */
    }
    if (yuvo.info.nbuf < 3) return;
    vc->get_buffer2 = yuv_get_buffer;
    yuvo.on = 1;
    if (!getenv("VIDPLAY_NOHWIDCT") && par->codec_id == AV_CODEC_ID_MJPEG && idct_hw_open(fb.fd) == 0 &&
        !getenv("VIDPLAY_NOHWJPEG") && idct_hw_jpeg_capable()) {
        jhw.on = 1;
        jpeg_hw_reset();
    }
}

/* ---- MJPEG decoded entirely by the gateware (Build 70+) ------------------ */
/* The packet's headers are parsed here and its tables and raw scan go to the IDCT
 * core's entropy decoder; the frame lands in a scan-out buffer like a decoded one
 * (yuv_show() waits for the core).  FFmpeg is not involved: a packet the core
 * cannot take (-1) switches the stream over to FFmpeg's decoder for good. */
static int jhw_decode(AVCodecContext *vc, const AVPacket *pk, AVFrame *f)
{
    jpeg_frame_t jf;
    if (jpeg_hw_parse(pk->data, pk->size, &jf) || (int)jf.w != vc->width || (int)jf.h != vc->height) return -1;
    int i, w = jf.w, h = jf.h;
    int W = yuvo.lay.max_w, H = yuvo.lay.max_h;       /* the buffer's room for the picture */
    for (i = 0; i < (int)yuvo.info.nbuf; i++)
        if (yuvo.free[i] && i != yuvo.shown && i != yuvo.prev) break;
    if (i == (int)yuvo.info.nbuf || w > W || h > H) return -1;
    int dx, dy;
    yuv_place(w, h, &dx, &dy);
    int cw = (w + 15) & ~15, ch = (h + 15) & ~15;
    if (dx + cw > W || dy + ch > H) return -1;
    uint8_t *b = yuvo.buf[i];
    f->buf[0] = av_buffer_create(b, yuvo.info.buf_size, yuv_release, (void *)(intptr_t)i, 0);
    if (!f->buf[0]) return -1;
    yuvo.free[i] = 0;
    f->data[0] = b + dy * yuvo.lay.y_stride + dx;
    f->data[1] = b + yuvo.lay.u_off + (dy / 2) * yuvo.lay.c_stride + dx / 2;
    f->data[2] = b + yuvo.lay.v_off + (dy / 2) * yuvo.lay.c_stride + dx / 2;
    f->linesize[0] = yuvo.lay.y_stride;
    f->linesize[1] = f->linesize[2] = yuvo.lay.c_stride;
    f->extended_data = f->data;
    f->width = w; f->height = h;
    f->format = AV_PIX_FMT_YUVJ420P;
    f->color_range = AVCOL_RANGE_JPEG;
    f->pts = pk->pts != AV_NOPTS_VALUE ? pk->pts : pk->dts;
    f->opaque = (void *)(intptr_t)(i + 1);
    if (idct_hw_frame_begin(i, b, f->data[0], f->data[1], f->data[2], f->linesize[0], f->linesize[1], cw, ch, w, h) ||
        jpeg_hw_submit(&jf)) {
        idct_hw_frame_end();
        av_frame_unref(f);
        return -1;
    }
    idct_hw_frame_end();                    /* flush records + submit: the core works on, we go on */
    yuvo.hw[i] = 1;
    jhw.frames++;
    return 0;
}

/* vidplay -C N file: the first N video frames decoded both ways -- FFmpeg's own C
 * code on the CPU, and the gateware -- and compared inside the picture.  Exit 0 =
 * every frame bit-exact.  Also reports what each path costs per frame. */
static int jhw_check(AVFormatContext *ic, int vi, AVCodecContext *vc, int n)
{
    if (!jhw.on) { fprintf(stderr, "check: no hardware JPEG path (gateware Build 70+, MJPEG, YUV buffers needed)\n"); return 1; }
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_MJPEG);
    AVCodecContext *sc = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(sc, ic->streams[vi]->codecpar);
    sc->thread_count = 1;
    if (avcodec_open2(sc, codec, NULL) < 0) return 1;
    idct_use_c = 1;                         /* FFmpeg's ff_simple_idct_put_int16_8bit itself */
    idct_no_stage = 1;
    AVPacket *pk = av_packet_alloc();
    AVFrame *hf = av_frame_alloc(), *sf = av_frame_alloc();
    int frames = 0, badframes = 0;
    double t_hw = 0, t_sw = 0;
    while (frames < n && av_read_frame(ic, pk) >= 0) {
        if (pk->stream_index != vi) { av_packet_unref(pk); continue; }
        double t0 = now_s();
        if (jhw_decode(vc, pk, hf)) { fprintf(stderr, "check: frame %d not for the hardware path\n", frames); return 1; }
        if (idct_hw_frame_done()) return 1;
        t_hw += now_s() - t0;
        t0 = now_s();
        if (avcodec_send_packet(sc, pk) < 0 || avcodec_receive_frame(sc, sf) < 0) { fprintf(stderr, "check: FFmpeg failed\n"); return 1; }
        t_sw += now_s() - t0;
        long bad = 0;
        int fx = -1, fy = -1, fp = -1;
        for (int p = 0; p < 3; p++) {
            int pw = p ? (hf->width + 1) / 2 : hf->width, ph = p ? (hf->height + 1) / 2 : hf->height;
            for (int y = 0; y < ph; y++) {
                const uint8_t *a = hf->data[p] + y * hf->linesize[p], *c = sf->data[p] + y * sf->linesize[p];
                if (memcmp(a, c, pw))
                    for (int x = 0; x < pw; x++)
                        if (a[x] != c[x]) { if (!bad) { fx = x; fy = y; fp = p; } bad++; }
            }
        }
        if (bad) {
            badframes++;
            fprintf(stderr, "check: frame %d: %ld pixels differ, first plane %d (%d,%d)\n", frames, bad, fp, fx, fy);
        }
        av_frame_unref(hf);
        av_frame_unref(sf);
        av_packet_unref(pk);
        frames++;
    }
    fprintf(stderr, "JPEGCHECK %d frames %dx%d: %d differ; per frame: gateware %.1f ms (CPU parse + copy + wait), FFmpeg on the CPU %.1f ms\n",
            frames, vc->width, vc->height, badframes, frames ? t_hw * 1e3 / frames : 0, frames ? t_sw * 1e3 / frames : 0);
    idct_hw_stats(stderr);
    return badframes || !frames;
}

static int yuv_show(const AVFrame *f)
{
    int i = (int)(intptr_t)f->opaque - 1;
    if (yuvo.hw[i] && idct_hw_frame_done()) return -1;      /* the core's last band must have landed */
    if (yuvo.scale && !yuvo.scaled) { yuv_scale(f->width, f->height); yuvo.scaled = 1; }
    /* the core scans the whole panel-sized buffer; the picture sits inside it at (dx, dy) */
    struct gowin_lcd_yuv_show sh = {
        .buf = i, .flags = (f->color_range == AVCOL_RANGE_JPEG ? GOWIN_LCD_YUV_FULL_RANGE : 0) |
                           (yuvo.hw[i] ? GOWIN_LCD_YUV_NOSYNC : 0),
        .y_off = 0, .u_off = yuvo.lay.u_off, .v_off = yuvo.lay.v_off,
        .y_stride = yuvo.lay.y_stride, .c_stride = yuvo.lay.c_stride,
    };
    static int dbg = -1;
    if (dbg < 0) dbg = getenv("VIDPLAY_SHOWDBG") ? 12 : 0;
    if (dbg > 0) { dbg--; fprintf(stderr, "show buf %u y_off %u u_off %u v_off %u hw %d\n", sh.buf, sh.y_off, sh.u_off, sh.v_off, yuvo.hw[i]); }
    if (ioctl(fb.fd, GOWIN_LCD_IOC_YUV_SHOW, &sh)) {
        fprintf(stderr, "yuv show: %s (buf %u y_off %u u_off %u v_off %u strides %u/%u, frame %dx%d)\n", strerror(errno),
                sh.buf, sh.y_off, sh.u_off, sh.v_off, sh.y_stride, sh.c_stride, f->width, f->height);
        return -1;
    }
    yuvo.prev = yuvo.shown;
    yuvo.shown = i;
    return 0;
}

static uint8_t *rowbuf;       /* ROWS full-width panel rows (black bars included), cached memory */
#define ROWS 8

/* The mmap of gowin-lcdfb is deferred I/O: its pages are write-protected again after
 * every flush, so a full frame through the mapping costs a page fault per page.
 * write() instead copies into the kernel's cached buffer and flushes the range at
 * once, so the picture goes out as ROWS-row pwrite()s of full panel rows. */
static void show_frame(const AVFrame *f)
{
    int w = f->width & ~1, h = f->height & ~1;
    int cw = w < fb.w ? w : fb.w, ch = h < fb.h ? h : fb.h;       /* drawn size */
    int sx = (w - cw) / 2 & ~1, sy = (h - ch) / 2 & ~1;             /* crop offset */
    int dx = (fb.w - cw) / 2, dy = (fb.h - ch) / 2;                 /* panel offset */
    static int nofb = -1, noconv;
    if (!fb_drawn && fb.mem) { memset(fb.mem, 0, fb.len); fb_drawn = 1; }   /* black bars */
    if (nofb < 0) { nofb = getenv("VIDPLAY_NOFB") != NULL; noconv = getenv("VIDPLAY_NOCONV") != NULL; }   /* profiling switches */
    for (int y = 0; y < ch; y += ROWS) {
        int n = ch - y < ROWS ? ch - y : ROWS;
        for (int r = 0; r < n; r += 2) {
            const uint8_t *y0 = f->data[0] + (sy + y + r) * f->linesize[0] + sx;
            const uint8_t *y1 = y0 + f->linesize[0];
            const uint8_t *u = f->data[1] + ((sy + y + r) >> 1) * f->linesize[1] + (sx >> 1);
            const uint8_t *v = f->data[2] + ((sy + y + r) >> 1) * f->linesize[2] + (sx >> 1);
            uint16_t *d0 = (uint16_t *)(rowbuf + r * fb.ll) + dx, *d1 = (uint16_t *)(rowbuf + (r + 1) * fb.ll) + dx;
            if (!noconv) yuv_rows(y0, y1, u, v, d0, d1, cw);
        }
        if (nofb) continue;
        if (pwrite(fb.fd, rowbuf, n * fb.ll, (off_t)(dy + y) * fb.ll) < 0) { perror("fb write"); nofb = 1; }
    }
}

/* ---- ALSA raw ioctl output --------------------------------------------- */
static struct { int fd; unsigned rate, period, bufsz; uint64_t written; unsigned xruns; double t0, last_write; long last_avail; } pcm = { .fd = -1 };

static struct snd_mask *hw_mask(struct snd_pcm_hw_params *p, int var) { return &p->masks[var - SNDRV_PCM_HW_PARAM_FIRST_MASK]; }
static struct snd_interval *hw_ival(struct snd_pcm_hw_params *p, int var) { return &p->intervals[var - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL]; }

static int pcm_find(char *buf, size_t n)
{
    FILE *f = fopen("/proc/asound/cards", "r");
    char line[256];
    int idx;
    if (!f) return -1;
    while (fgets(line, sizeof(line), f))
        if (sscanf(line, " %d [", &idx) == 1 && strstr(line, "PT8211")) {
            snprintf(buf, n, "/dev/snd/pcmC%dD0p", idx);
            fclose(f);
            return 0;
        }
    fclose(f);
    return -1;
}

static int pcm_open(const char *dev, unsigned rate)
{
    struct snd_pcm_hw_params hp;
    struct snd_pcm_sw_params sw;
    pcm.fd = open(dev, O_RDWR);
    if (pcm.fd < 0) { perror(dev); return -1; }
    memset(&hp, 0, sizeof(hp));
    for (int i = SNDRV_PCM_HW_PARAM_FIRST_MASK; i <= SNDRV_PCM_HW_PARAM_LAST_MASK; i++)
        memset(hw_mask(&hp, i)->bits, 0xff, sizeof(hw_mask(&hp, i)->bits));
    for (int i = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; i++) {
        hw_ival(&hp, i)->min = 0; hw_ival(&hp, i)->max = ~0u;
    }
    hp.rmask = ~0u; hp.cmask = 0; hp.info = ~0u;
#define MASK1(var, bit) do { memset(hw_mask(&hp, var)->bits, 0, sizeof(hw_mask(&hp, var)->bits)); hw_mask(&hp, var)->bits[(bit) >> 5] = 1u << ((bit) & 31); } while (0)
#define IVAL(var, v) do { hw_ival(&hp, var)->min = hw_ival(&hp, var)->max = (v); hw_ival(&hp, var)->integer = 1; } while (0)
    MASK1(SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    MASK1(SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    MASK1(SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    IVAL(SNDRV_PCM_HW_PARAM_CHANNELS, 2);
    IVAL(SNDRV_PCM_HW_PARAM_RATE, rate);
    IVAL(SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 2048);
    IVAL(SNDRV_PCM_HW_PARAM_BUFFER_SIZE, getenv("VIDPLAY_RING") ? (unsigned)atoi(getenv("VIDPLAY_RING")) : 16384);
    if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hp) < 0) { perror("HW_PARAMS"); return -1; }
    pcm.rate = rate;
    pcm.period = hw_ival(&hp, SNDRV_PCM_HW_PARAM_PERIOD_SIZE)->min;
    pcm.bufsz = hw_ival(&hp, SNDRV_PCM_HW_PARAM_BUFFER_SIZE)->min;
    memset(&sw, 0, sizeof(sw));
    sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
    sw.period_step = 1;
    sw.avail_min = pcm.period;
    sw.start_threshold = pcm.bufsz / 2;     /* start once half a buffer is queued */
    sw.stop_threshold = pcm.bufsz;
    sw.boundary = pcm.bufsz;                /* the usual power-of-two multiple of the buffer */
    while (sw.boundary * 2 <= 0x7fffffffUL - pcm.bufsz) sw.boundary *= 2;
    if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw) < 0) { perror("SW_PARAMS"); return -1; }
    if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_PREPARE) < 0) { perror("PREPARE"); return -1; }
    pcm.t0 = now_s();
    return 0;
}

/* frames of room in the ring */
static long pcm_avail(void)
{
    struct snd_pcm_status st;
    if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_STATUS, &st) < 0) return pcm.bufsz;
    pcm.last_avail = st.avail;
    return st.avail;
}

/* write interleaved s16 stereo frames; blocks only if the ring is full */
static int pcm_write(const int16_t *buf, unsigned frames)
{
    unsigned off = 0;
    while (off < frames) {
        struct snd_xferi x = { .result = 0, .buf = (void *)(buf + off * 2), .frames = frames - off };
        if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &x) < 0) {
            if (errno == EPIPE) {           /* underrun: restart */
                pcm.xruns++;
                if (getenv("VIDPLAY_XRUNLOG")) fprintf(stderr, "xrun: t=%.2f, %.0f ms since the last write, avail before %ld\n", now_s() - pcm.t0, (now_s() - pcm.last_write) * 1000, pcm.last_avail);
                if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_PREPARE) < 0) return -1;
                continue;
            }
            return -1;
        }
        off += x.result;
    }
    pcm.written += frames;
    pcm.last_write = now_s();
    return 0;
}

/* seconds of audio actually played so far */
static double pcm_clock(void)
{
    snd_pcm_sframes_t delay = 0;
    if (ioctl(pcm.fd, SNDRV_PCM_IOCTL_DELAY, &delay) < 0 || delay < 0) delay = 0;
    if ((uint64_t)delay > pcm.written) delay = pcm.written;
    return (double)(pcm.written - delay) / pcm.rate;
}

/* ---- packet queues ------------------------------------------------------ */
#define PQ_N 512
typedef struct { AVPacket *p[PQ_N]; int head, n; } pq_t;

static int pq_push(pq_t *q, AVPacket *pkt)
{
    if (q->n == PQ_N) return -1;
    AVPacket *c = av_packet_alloc();
    av_packet_move_ref(c, pkt);
    q->p[(q->head + q->n) % PQ_N] = c;
    q->n++;
    return 0;
}
static AVPacket *pq_peek(pq_t *q) { return q->n ? q->p[q->head] : NULL; }
static void pq_pop(pq_t *q) { av_packet_free(&q->p[q->head]); q->head = (q->head + 1) % PQ_N; q->n--; }

/* ---- main --------------------------------------------------------------- */
int main(int argc, char **argv)
{
    const char *file = NULL, *fbdev = "/dev/fb0";
    char pcmdev[64] = "";
    int no_audio = 0, bench = 0, verbose = 0, skip_lf = 0, fast = 0, check = 0;
    const char *prof = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-D") && i + 1 < argc) snprintf(pcmdev, sizeof(pcmdev), "%s", argv[++i]);
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) fbdev = argv[++i];
        else if (!strcmp(argv[i], "-n")) no_audio = 1;
        else if (!strcmp(argv[i], "-b")) bench = 1;
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "-L")) skip_lf = 1;
        else if (!strcmp(argv[i], "-F")) fast = 1;
        else if (!strcmp(argv[i], "-P") && i + 1 < argc) prof = argv[++i];
        else if (!strcmp(argv[i], "-C") && i + 1 < argc) check = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-1")) opt_scale = 0;
        else if (!strcmp(argv[i], "-o")) opt_osd = 1;          /* (the bar is on by default) */
        else if (!strcmp(argv[i], "-O")) opt_osd = 0;
        else file = argv[i];
    }
    if (!file && !getenv("VIDPLAY_IDCTTEST")) { fprintf(stderr, "usage: vidplay [-D pcm] [-f /dev/fbN] [-n] [-b] [-v] [-1] [-O] [-L] [-F] [-P prof] [-C frames] file\n"); return 2; }
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    if (prof) prof_start();
    if (getenv("VIDPLAY_IDCTTEST")) { idct_selftest(); if (!file) return 0; }
    if (getenv("VIDPLAY_CIDCT")) idct_use_c = 1;
    if (getenv("VIDPLAY_NOSTAGE")) idct_no_stage = 1;
    av_log_set_level(verbose ? AV_LOG_INFO : AV_LOG_FATAL);

    AVFormatContext *ic = NULL;
    if (avformat_open_input(&ic, file, NULL, NULL) < 0) { fprintf(stderr, "%s: cannot open\n", file); return 1; }
    if (avformat_find_stream_info(ic, NULL) < 0) { fprintf(stderr, "%s: no stream info\n", file); return 1; }
    int vi = av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int ai = no_audio ? -1 : av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (vi < 0 && ai < 0) { fprintf(stderr, "%s: no video or audio stream\n", file); return 1; }

    AVCodecContext *vc = NULL, *ac = NULL;
    int intra_only = 0;                     /* MJPEG etc.: a packet can be skipped without harming later frames */
    if (vi >= 0) {
        const AVCodec *codec = avcodec_find_decoder(ic->streams[vi]->codecpar->codec_id);
        if (!codec) { fprintf(stderr, "no decoder for video codec %d\n", ic->streams[vi]->codecpar->codec_id); vi = -1; }
        else {
            const AVCodecDescriptor *cd = avcodec_descriptor_get(codec->id);
            intra_only = cd && (cd->props & AV_CODEC_PROP_INTRA_ONLY);
            vc = avcodec_alloc_context3(codec);
            avcodec_parameters_to_context(vc, ic->streams[vi]->codecpar);
            vc->thread_count = 1;
            if (skip_lf) vc->skip_loop_filter = AVDISCARD_ALL;
            if (fast) vc->flags2 |= AV_CODEC_FLAG2_FAST;
            if (getenv("VIDPLAY_IDCT")) vc->idct_algo = atoi(getenv("VIDPLAY_IDCT"));     /* 1 = FF_IDCT_INT, 2 = SIMPLE (experiments) */
            if (getenv("VIDPLAY_LOWRES")) vc->lowres = atoi(getenv("VIDPLAY_LOWRES"));
            if (!bench && !getenv("VIDPLAY_NOYUV") && fb_open(fbdev) == 0) yuv_setup(vc, ic->streams[vi]->codecpar);
            if (avcodec_open2(vc, codec, NULL) < 0) { fprintf(stderr, "cannot open video decoder\n"); return 1; }
        }
    }
    if (check) return vi >= 0 ? jhw_check(ic, vi, vc, check) : 1;
    SwrContext *swr = NULL;
    if (ai >= 0) {
        const AVCodec *codec = avcodec_find_decoder(ic->streams[ai]->codecpar->codec_id);
        if (!codec) { fprintf(stderr, "no decoder for audio codec %d\n", ic->streams[ai]->codecpar->codec_id); ai = -1; }
        else {
            ac = avcodec_alloc_context3(codec);
            avcodec_parameters_to_context(ac, ic->streams[ai]->codecpar);
            if (avcodec_open2(ac, codec, NULL) < 0) { fprintf(stderr, "cannot open audio decoder\n"); return 1; }
        }
    }
    if (vi < 0 && ai < 0) return 1;

    if (!bench && vi >= 0 && fb.fd < 0 && fb_open(fbdev)) return 1;
    rowbuf = calloc(ROWS, fb.fd >= 0 ? fb.ll : 1600 * 2);      /* bars stay black */
    yuv_tables();
    unsigned arate = 0;
    if (!bench && ai >= 0) {
        arate = ac->sample_rate;
        if (!pcmdev[0] && pcm_find(pcmdev, sizeof(pcmdev))) { fprintf(stderr, "no PT8211 card, playing without audio\n"); ai = -1; }
        else if (pcm_open(pcmdev, arate)) ai = -1;
    }
    if (ai >= 0 && !bench) {
        AVChannelLayout st = AV_CHANNEL_LAYOUT_STEREO;
        swr_alloc_set_opts2(&swr, &st, AV_SAMPLE_FMT_S16, arate, &ac->ch_layout, ac->sample_fmt, ac->sample_rate, 0, NULL);
        if (!swr || swr_init(swr) < 0) { fprintf(stderr, "swresample init failed\n"); return 1; }
    }

    fprintf(stderr, "vidplay: %s: %s%s%s\n", file,
            vi >= 0 ? avcodec_get_name(vc->codec_id) : "no video",
            ai >= 0 ? ", audio " : "", ai >= 0 ? avcodec_get_name(ac->codec_id) : "");
    if (vi >= 0)
        fprintf(stderr, "  video %dx%d, %.3f fps%s\n", vc->width, vc->height, av_q2d(ic->streams[vi]->avg_frame_rate),
                bench ? " (benchmark: decode only)" : jhw.on ? " -> decoded by the gateware (JPEG entropy decoder + IDCT) into YUV scan-out buffers" :
                yuvo.on ? " -> YUV scan-out buffers (no conversion)" : " -> RGB565 conversion");
    if (ai >= 0)
        fprintf(stderr, "  audio %d Hz, %d ch -> %s\n", ac->sample_rate, ac->ch_layout.nb_channels, bench ? "discarded" : pcmdev);

    AVPacket *pkt = av_packet_alloc();
    AVFrame *af = av_frame_alloc(), *pending = av_frame_alloc();
    pq_t vq = { 0 }, aq = { 0 };
    int have_pending = 0, eof = 0, held = 0, veof_sent = 0, aeof_sent = 0, late_streak = 0, skip_pkts = 0;
    unsigned skipped = 0;                    /* packets skipped undecoded (intra-only catch-up) */
    int16_t *abuf = malloc(8192 * 2 * sizeof(int16_t));
    double t_start = now_s(), vtb = vi >= 0 ? av_q2d(ic->streams[vi]->time_base) : 0;
    /* the info bar: title (file name without directory and extension), position, duration */
    int osd_ok = !bench && vi >= 0 && fb.fd >= 0 && opt_osd && osd_init(fb.fd, fb.w, fb.h) == 0;
    char title[128];
    {
        const char *bn = strrchr(file, '/');
        snprintf(title, sizeof(title), "%s", bn ? bn + 1 : file);
        char *dot = strrchr(title, '.');
        if (dot && dot != title) *dot = 0;
    }
    double duration = ic->duration > 0 ? ic->duration / (double)AV_TIME_BASE : 0, shown_pts = 0;
    int osd_frozen = 0;
    double frame_dur = vi >= 0 && ic->streams[vi]->avg_frame_rate.num ? 1.0 / av_q2d(ic->streams[vi]->avg_frame_rate) : 0.04;
    unsigned decoded = 0, shown = 0, dropped = 0, aframes = 0;
    double dec_time = 0, conv_time = 0, last_report = t_start;
    double aclock_base = -1;                 /* video pts at audio time 0 */

    /* Demux ahead into one packet queue per stream, so the audio decoder can run on
     * (and the audio clock advance) while a decoded video frame waits for its time,
     * and a packet the video decoder refuses (EAGAIN: drain first) is simply retried. */
    while (!g_stop) {
        int progress = 0;
        double clock = (!bench && ai >= 0) ? pcm_clock() : now_s() - t_start;

        /* audio: fill the ALSA ring as far as it goes (a video frame costs ~60 ms of
         * decoding, the ring holds ~340 ms, so top it up completely each time round) */
        int astop = 0;
        while (ac && !astop && (bench || pcm_avail() >= 2048)) {
            int r = avcodec_receive_frame(ac, af);
            if (r == 0) {
                if (!bench && swr) {
                    int n = swr_convert(swr, (uint8_t **)&abuf, 8192, (const uint8_t **)af->data, af->nb_samples);
                    if (n > 0 && pcm_write(abuf, n)) { perror("pcm write"); g_stop = 1; break; }
                    aframes += n > 0 ? n : 0;
                }
                av_frame_unref(af);
                progress = 1;
                if (bench) astop = 1;
            } else if (r == AVERROR(EAGAIN)) {
                AVPacket *pk = pq_peek(&aq);
                if (pk) { if (avcodec_send_packet(ac, pk) != AVERROR(EAGAIN)) pq_pop(&aq); progress = 1; }
                else if (eof && !aeof_sent) { avcodec_send_packet(ac, NULL); aeof_sent = 1; progress = 1; }
                else astop = 1;                      /* no audio packet yet: demux below */
            } else if (r == AVERROR_EOF) {
                ac = NULL; progress = 1;
            } else {
                astop = 1;
            }
        }

        /* video, MJPEG on the gateware: one packet = one frame handed to the core */
        if (vc && !have_pending && jhw.on) {
            AVPacket *pk = pq_peek(&vq);
            while (pk && skip_pkts > 0) {            /* intra-only: catch up without decoding */
                pq_pop(&vq); skip_pkts--; skipped++;
                pk = pq_peek(&vq);
            }
            if (pk) {
                double t0 = now_s();
                int r = jhw_decode(vc, pk, pending);
                dec_time += now_s() - t0;
                if (r == 0) { pq_pop(&vq); have_pending = 1; decoded++; }
                else {
                    jhw.on = 0;
                    fprintf(stderr, "vidplay: frame %u is not for the gateware JPEG decoder, FFmpeg decodes from here on\n", decoded);
                }
                progress = 1;
            } else if (eof) { vc = NULL; progress = 1; }
        }
        /* video: pull the next frame, feeding packets as the decoder asks for them */
        else if (vc && !have_pending) {
            double t0 = now_s();
            int r = avcodec_receive_frame(vc, pending);
            if (r == 0) { idct_stage_flush(); idct_hw_frame_end(); }   /* the last band of the frame */
            dec_time += now_s() - t0;
            if (r == 0) { have_pending = 1; decoded++; progress = 1; }
            else if (r == AVERROR(EAGAIN)) {
                AVPacket *pk = pq_peek(&vq);
                while (pk && skip_pkts > 0) {        /* intra-only: catch up without decoding */
                    pq_pop(&vq); skip_pkts--; skipped++;
                    pk = pq_peek(&vq);
                }
                if (pk) {
                    t0 = now_s();
                    r = avcodec_send_packet(vc, pk);
                    dec_time += now_s() - t0;
                    if (r != AVERROR(EAGAIN)) pq_pop(&vq);
                    progress = 1;
                } else if (eof && !veof_sent) { avcodec_send_packet(vc, NULL); veof_sent = 1; progress = 1; }
            } else if (r == AVERROR_EOF) {
                vc = NULL; progress = 1;
            }
        }

        /* show the decoded frame when its time has come */
        if (have_pending) {
            double pts = pending->pts == AV_NOPTS_VALUE ? decoded * frame_dur : pending->pts * vtb;
            if (aclock_base < 0) aclock_base = pts;
            double due = pts - aclock_base;
            if (bench || clock >= due) {
                /* late frames are dropped to catch up, but never more than two in a
                 * row: when the decoder simply cannot keep up, the viewer still gets
                 * every third frame instead of a frozen picture */
                /* (intra-only streams catch up by skipping packets, so their decoded
                 * frames are shown even when late: dropping them would save nothing) */
                if (!bench && !intra_only && clock - due > frame_dur && late_streak < 2) {
                    dropped++;
                    late_streak++;
                } else if (!bench) {
                    double t0 = now_s();
                    if (yuvo.on && pending->opaque) yuv_show(pending);
                    else if (!yuvo.on) show_frame(pending);
                    shown_pts = pts;
                    conv_time += now_s() - t0;
                    shown++;
                    late_streak = 0;
                }
                av_frame_unref(pending);
                have_pending = 0;
                progress = 1;
                /* behind by more than two frames: let the decoder skip non-reference
                 * frames until we have caught up again (hysteresis, not per frame) */
                /* behind by more than two frames: let the decoder skip non-reference
                 * frames until we have caught up (hysteresis).  AVDISCARD_BIDIR would
                 * skip more but corrupts the picture with x264's B-pyramid streams.
                 * Intra-only codecs skip whole packets instead (below): decoding a
                 * frame only to drop it is the one thing that cannot catch up. */
                if (vc && !bench && !getenv("VIDPLAY_NOSKIP")) {
                    double late = clock - due;
                    if (intra_only) skip_pkts = late > 1.5 * frame_dur ? (int)(late / frame_dur) : 0;
                    else if (late > 2 * frame_dur) vc->skip_frame = AVDISCARD_NONREF;
                    else if (late <= 0) vc->skip_frame = AVDISCARD_DEFAULT;
                }
            }
        }

        /* demux: keep both queues topped up -- all the way, not one packet per
         * iteration (an iteration carries a ~60 ms video decode, and the audio
         * stage above must find enough packets to refill the ALSA ring) */
        while (!eof && (vq.n < PQ_N / 2 || aq.n < PQ_N / 2)) {
            if (!held) {
                if (av_read_frame(ic, pkt) < 0) { eof = 1; break; }
                held = 1;
            }
            int ok = 1;
            if (pkt->stream_index == vi && vc) ok = pq_push(&vq, pkt) == 0;
            else if (pkt->stream_index == ai && ac) ok = pq_push(&aq, pkt) == 0;
            else av_packet_unref(pkt);
            if (!ok) break;                          /* that queue is full: keep the packet */
            held = 0; progress = 1;
        }

        if (!vc && !ac) break;
        if (!progress) usleep(2000);

        if (osd_ok && !osd_frozen) {
            osd_update(1, title, shown_pts, duration);
            if (getenv("VIDPLAY_OSDFREEZE")) osd_frozen = 1;   /* profiling: the layer on, no redraws */
        }

        if (verbose && now_s() - last_report >= 1.0) {
            last_report = now_s();
            fprintf(stderr, "  t=%.1f clock=%.2f decoded %u shown %u dropped %u, decode %.1f ms/frame, queues v%d a%d\n",
                    last_report - t_start, clock, decoded, shown, dropped, decoded ? dec_time * 1000 / decoded : 0, vq.n, aq.n);
        }
    }
    double total = now_s() - t_start;
    if (prof) prof_stop(prof);
    if (pcm.fd >= 0) { if (!g_stop) ioctl(pcm.fd, SNDRV_PCM_IOCTL_DRAIN); else ioctl(pcm.fd, SNDRV_PCM_IOCTL_DROP); close(pcm.fd); }
    if (osd_ok) osd_close();
    if (yuvo.on || osd_ok) ioctl(fb.fd, GOWIN_LCD_IOC_RGB);
    if (fb.mem) { if (fb_drawn) memset(fb.mem, 0, fb.len); munmap(fb.mem, fb.len); }
    if (fb.fd >= 0) close(fb.fd);
    fprintf(stderr, "VIDPLAY %s: %u frames decoded in %.2f s (%.1f fps, decode %.1f ms/frame, %s %.1f ms/frame), shown %u, dropped %u%s, audio %u frames, %u xruns%s\n",
            file, decoded, total, total > 0 ? decoded / total : 0, decoded ? dec_time * 1000 / decoded : 0,
            yuvo.on ? "show" : "convert", shown ? conv_time * 1000 / shown : 0, shown, dropped,
            yuvo.nobuf ? " (+no scan-out buffer)" : "", aframes, pcm.xruns, g_stop ? " (stopped)" : "");
    if (jhw.frames) fprintf(stderr, "  %u frames decoded by the gateware JPEG decoder\n", jhw.frames);
    idct_hw_stats(stderr);
    idct_hw_close();
    if (skipped) fprintf(stderr, "  %u packets skipped undecoded to keep up with the audio clock\n", skipped);
    return 0;
}
