/*
 * idcttest -- hardware check of the IDCT core (gateware Build 69+, /dev/gowin-idct)
 * through one of gowin-lcdfb's YUV buffers, without FFmpeg:
 *
 *   idcttest [-n PASSES] [-s] [-x DX] [-y DY] [-f /dev/fb0]
 *   (-s: show the result on the panel; -x/-y: picture offset in the buffer, like a
 *    centred smaller video -- the planes then start at unaligned addresses)
 *
 * Every 8x8 block of a panel-sized 4:2:0 frame gets random coefficients (DC-only,
 * sparse, medium, dense, clamp-stress -- the testbench's mix), written as records
 * in MCU order, submitted per 16-line band with flush-only records at the end; the
 * three planes are then compared pixel by pixel with FFmpeg's integer IDCT in C
 * (the same model as src/rtl/idct/tb).  Prints the core's throughput.  Exit 0 =
 * every pass bit-exact.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include "../vidplay/gowin-lcdfb.h"
#include "../vidplay/gowin-idct.h"

/* ---- FFmpeg simple_idct (int16 in, 8-bit put), as libavcodec/simple_idct_template.c ---- */
enum { W1 = 22725, W2 = 21407, W3 = 19266, W4 = 16383, W5 = 12873, W6 = 8867, W7 = 4520 };
static inline int clip8(int v) { return v < 0 ? 0 : v > 255 ? 255 : v; }
static void model_idct_put(uint8_t *dst, int stride, const int16_t *blk, int rows)
{
    int16_t tmp[64];
    for (int r = 0; r < 8; r++) {
        const int16_t *x = blk + r * 8;
        if (!(x[1] | x[2] | x[3] | x[4] | x[5] | x[6] | x[7])) {
            int16_t v = (int16_t)(x[0] * 8);
            for (int c = 0; c < 8; c++) tmp[r * 8 + c] = v;
            continue;
        }
        int a0 = W4*x[0] + W2*x[2] + W4*x[4] + W6*x[6] + 1024, a1 = W4*x[0] + W6*x[2] - W4*x[4] - W2*x[6] + 1024;
        int a2 = W4*x[0] - W6*x[2] - W4*x[4] + W2*x[6] + 1024, a3 = W4*x[0] - W2*x[2] + W4*x[4] - W6*x[6] + 1024;
        int b0 = W1*x[1] + W3*x[3] + W5*x[5] + W7*x[7], b1 = W3*x[1] - W7*x[3] - W1*x[5] - W5*x[7];
        int b2 = W5*x[1] - W1*x[3] + W7*x[5] + W3*x[7], b3 = W7*x[1] - W5*x[3] + W3*x[5] - W1*x[7];
        tmp[r*8+0] = (int16_t)((a0 + b0) >> 11); tmp[r*8+1] = (int16_t)((a1 + b1) >> 11);
        tmp[r*8+2] = (int16_t)((a2 + b2) >> 11); tmp[r*8+3] = (int16_t)((a3 + b3) >> 11);
        tmp[r*8+4] = (int16_t)((a3 - b3) >> 11); tmp[r*8+5] = (int16_t)((a2 - b2) >> 11);
        tmp[r*8+6] = (int16_t)((a1 - b1) >> 11); tmp[r*8+7] = (int16_t)((a0 - b0) >> 11);
    }
    for (int c = 0; c < 8; c++) {
        int x0 = tmp[c], x1 = tmp[8+c], x2 = tmp[16+c], x3 = tmp[24+c], x4 = tmp[32+c], x5 = tmp[40+c], x6 = tmp[48+c], x7 = tmp[56+c];
        int a0 = W4*x0 + W2*x2 + W4*x4 + W6*x6 + 524256, a1 = W4*x0 + W6*x2 - W4*x4 - W2*x6 + 524256;
        int a2 = W4*x0 - W6*x2 - W4*x4 + W2*x6 + 524256, a3 = W4*x0 - W2*x2 + W4*x4 - W6*x6 + 524256;
        int b0 = W1*x1 + W3*x3 + W5*x5 + W7*x7, b1 = W3*x1 - W7*x3 - W1*x5 - W5*x7;
        int b2 = W5*x1 - W1*x3 + W7*x5 + W3*x7, b3 = W7*x1 - W5*x3 + W3*x5 - W1*x7;
        int v[8] = { (a0 + b0) >> 20, (a1 + b1) >> 20, (a2 + b2) >> 20, (a3 + b3) >> 20,
                     (a3 - b3) >> 20, (a2 - b2) >> 20, (a1 - b1) >> 20, (a0 - b0) >> 20 };
        for (int r = 0; r < rows; r++) dst[r * stride + c] = clip8(v[r]);   /* the core clips at the plane height */
    }
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t rnd_state = 12345;
static int rnd(void) { rnd_state = rnd_state * 1103515245u + 12345u; return (int)(rnd_state >> 8); }
static void random_block(int16_t *b, int kind)
{
    int lim = kind == 0 ? 1 : kind == 1 ? 6 : kind == 2 ? 20 : 64;
    for (int i = 0; i < 64; i++) b[i] = i < lim ? (int16_t)(rnd() % 2048 - 1024) : 0;
    if (kind == 4) for (int i = 0; i < 64; i++) b[i] = (rnd() & 1) ? 2047 : -2048;
}

/* ---- the ring ---- */
static struct { int fd; uint64_t *ring; uint32_t size, wmask, tail, head; unsigned submits; } rg;

static int submit(void)
{
    struct gowin_idct_submit sb = { .tail = rg.tail };
    if (ioctl(rg.fd, GOWIN_IDCT_IOC_SUBMIT, &sb)) { perror("submit"); return -1; }
    rg.head = sb.head; rg.submits++;
    return 0;
}
static int wait_idle(void)
{
    uint32_t ms = 3000;
    if (ioctl(rg.fd, GOWIN_IDCT_IOC_WAIT, &ms)) { perror("wait"); return -1; }
    rg.head = ms;
    return 0;
}
static int put_record(uint64_t hdr, const int16_t *blk, unsigned n)
{
    unsigned nw = (n + 3) / 4, need = (nw + 1) * 8;
    if (rg.size - ((rg.tail - rg.head) & (rg.size - 1)) <= need + 64) {
        if (submit()) return -1;
        while (rg.size - ((rg.tail - rg.head) & (rg.size - 1)) <= need + 64) if (wait_idle()) return -1;
    }
    uint32_t wi = rg.tail / 8;
    rg.ring[wi & rg.wmask] = hdr;
    const uint32_t *b32 = (const uint32_t *)blk;
    for (unsigned k = 0; k < nw; k++) rg.ring[(wi + 1 + k) & rg.wmask] = ((uint64_t)b32[2 * k + 1] << 32) | b32[2 * k];
    rg.tail = (rg.tail + need) & (rg.size - 1);
    return 0;
}

int main(int argc, char **argv)
{
    const char *fbdev = "/dev/fb0";
    int passes = 2, show = 0, dx = 0, dy = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-n") && i + 1 < argc) passes = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-s")) show = 1;
        else if (!strcmp(argv[i], "-x") && i + 1 < argc) dx = atoi(argv[++i]) & ~7;
        else if (!strcmp(argv[i], "-y") && i + 1 < argc) dy = atoi(argv[++i]) & ~1;
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) fbdev = argv[++i];
    }
    int fb = open(fbdev, O_RDWR);
    if (fb < 0) { perror(fbdev); return 1; }
    struct gowin_lcd_yuv_info yi;
    if (ioctl(fb, GOWIN_LCD_IOC_YUV_INFO, &yi) || !yi.nbuf) { fprintf(stderr, "no YUV buffers (gateware Build 68+, kernel #77+)\n"); return 1; }
    uint8_t *buf = mmap(NULL, yi.buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb, yi.mmap_off);
    if (buf == MAP_FAILED) { perror("mmap yuv"); return 1; }
    rg.fd = open("/dev/gowin-idct", O_RDWR);
    if (rg.fd < 0) { perror("/dev/gowin-idct (gateware Build 69+, kernel #78+)"); return 1; }
    struct gowin_idct_info ii;
    if (ioctl(rg.fd, GOWIN_IDCT_IOC_INFO, &ii)) { perror("INFO"); return 1; }
    rg.ring = mmap(NULL, ii.ring_size, PROT_READ | PROT_WRITE, MAP_SHARED, rg.fd, 0);
    if (rg.ring == MAP_FAILED) { perror("mmap ring"); return 1; }
    rg.size = ii.ring_size; rg.wmask = ii.ring_size / 8 - 1;
    unsigned W = (yi.width - dx) & ~15u, H = yi.height - dy, CW = W / 2, CH = H / 2;
    unsigned yoff = dy * yi.y_stride + dx, coff = (dy / 2) * yi.c_stride + dx / 2;
    printf("idcttest: core id %08x, ring %u KB; frame %ux%u at (%d,%d) in YUV buffer 0 (Y stride %u, C stride %u)\n",
           ii.id, ii.ring_size / 1024, W, H, dx, dy, yi.y_stride, yi.c_stride);

    uint8_t *model = malloc(yi.buf_size);
    int16_t blk[64];
    int fails = 0;
    for (int pass = 0; pass < passes; pass++) {
        /* the buffer: ours to write (the CPU cache dropped), the core's planes */
        struct gowin_lcd_yuv_dma d = { .buf = 0, .flags = GOWIN_LCD_YUV_DMA_INVALIDATE };
        if (ioctl(fb, GOWIN_LCD_IOC_YUV_DMA, &d)) { perror("YUV_DMA (kernel #78+?)"); return 1; }
        struct gowin_idct_setup st = { .y_base = d.dma + yoff, .u_base = d.dma + yi.u_off + coff, .v_base = d.dma + yi.v_off + coff,
                                       .y_stride = yi.y_stride, .c_stride = yi.c_stride, .width = W, .height = H };
        if (ioctl(rg.fd, GOWIN_IDCT_IOC_SETUP, &st)) { perror("SETUP"); return 1; }
        memset(model, 0, yi.buf_size);
        rnd_state = 12345 + pass * 777;
        unsigned nblk = 0, nmx = W / 16, nmy = (H + 15) / 16;
        struct gowin_idct_status s0 = { 0 };
        ioctl(rg.fd, GOWIN_IDCT_IOC_STATUS, &s0);        /* BLOCKS/BANDS count since boot */
        double t0 = now_s();
        for (unsigned my = 0; my < nmy; my++) {
            for (unsigned mx = 0; mx < nmx; mx++) {
                for (int k = 0; k < 4; k++) {
                    unsigned x = mx * 16 + (k % 2) * 8, y = my * 16 + (k / 2) * 8;
                    random_block(blk, (mx + my + k + pass) % 5);
                    unsigned n = 0;
                    for (int i = 0; i < 64; i++) if (blk[i]) n = i + 1;
                    if (put_record(GOWIN_IDCT_HDR(n, 0, 0, x, y, 0), blk, n)) return 1;
                    if (y < H) model_idct_put(model + yoff + y * yi.y_stride + x, yi.y_stride, blk, H - y < 8 ? H - y : 8);
                    nblk++;
                }
                for (int p = 1; p <= 2; p++) {
                    unsigned x = mx * 8, y = my * 8;
                    random_block(blk, (mx * 3 + my + p + pass) % 5);
                    unsigned n = 0;
                    for (int i = 0; i < 64; i++) if (blk[i]) n = i + 1;
                    if (put_record(GOWIN_IDCT_HDR(n, 0, p, x, y, 0), blk, n)) return 1;
                    if (y < CH) model_idct_put(model + (p == 1 ? yi.u_off : yi.v_off) + coff + y * yi.c_stride + x, yi.c_stride, blk, CH - y < 8 ? CH - y : 8);
                    nblk++;
                }
            }
            if (submit()) return 1;                        /* a band is complete */
        }
        for (int p = 0; p < 3; p++) put_record(GOWIN_IDCT_HDR_FLUSH(p, 0), blk, 0);
        if (submit() || wait_idle()) return 1;
        double t = now_s() - t0;
        /* compare: the CPU reads DRAM (its cache held nothing of the buffer) */
        unsigned long errs = 0; int fx = -1, fy = -1, fp = -1, fgot = 0, fexp = 0;
        for (int p = 0; p < 3; p++) {
            unsigned pw = p ? CW : W, ph = p ? CH : H, stride = p ? yi.c_stride : yi.y_stride;
            unsigned off = p == 0 ? yoff : (p == 1 ? yi.u_off : yi.v_off) + coff;
            for (unsigned y = 0; y < ph; y++)
                for (unsigned x = 0; x < pw; x++)
                    if (buf[off + y * stride + x] != model[off + y * stride + x]) {
                        if (!errs) { fx = x; fy = y; fp = p; fgot = buf[off + y * stride + x]; fexp = model[off + y * stride + x]; }
                        errs++;
                    }
        }
        /* the rows the core must not touch: the first Y line past the frame (if any) */
        unsigned long outside = 0;
        if (dy + H + 1 <= yi.height) for (unsigned x = 0; x < W; x++) outside += buf[yoff + H * yi.y_stride + x] != 0;
        struct gowin_idct_status s = { 0 };
        ioctl(rg.fd, GOWIN_IDCT_IOC_STATUS, &s);
        s.blocks -= s0.blocks; s.bands -= s0.bands; s.irqs -= s0.irqs;
        printf("pass %d: %u blocks in %.1f ms (%.2f us/block, %.1f Mblk/s), %u submits; %lu pixel errors%s; "
               "core: %u blocks %u bands %u irqs%s -> %s\n", pass, nblk, t * 1e3, t * 1e6 / nblk, nblk / t / 1e6,
               rg.submits, errs, outside ? " (and pixels written past the frame)" : "",
               s.blocks, s.bands, s.irqs, (s.status & 8) ? " BAD-RECORD" : "", errs || outside ? "FAIL" : "ok");
        if (errs) printf("  first: plane %d (%d,%d) got %d expected %d\n", fp, fx, fy, fgot, fexp);
        if (errs || outside) fails++;
        rg.submits = 0;
    }
    if (show) {
        struct gowin_lcd_yuv_show sh = { .buf = 0, .flags = GOWIN_LCD_YUV_FULL_RANGE | GOWIN_LCD_YUV_NOSYNC,
                                         .y_off = 0, .u_off = yi.u_off, .v_off = yi.v_off,
                                         .y_stride = yi.y_stride, .c_stride = yi.c_stride };
        if (ioctl(fb, GOWIN_LCD_IOC_YUV_SHOW, &sh)) perror("YUV_SHOW");
        else { printf("showing the last pass for 3 s\n"); sleep(3); ioctl(fb, GOWIN_LCD_IOC_RGB); }
    }
    printf("IDCTTEST %s\n", fails ? "FAILED" : "PASSED");
    return fails ? 1 : 0;
}
