/*
 * idct_hw.c -- the hardware IDCT core (gateware Build 69+, /dev/gowin-idct) as
 * the MJPEG decoder's block output.
 *
 * FFmpeg's idct_put(dest, linesize, block) is wrapped (idct_dsp.c); when a frame
 * was begun here (its planes are a scan-out buffer of gowin-lcdfb, so the core
 * can write them), every call becomes one record in the core's ring instead of a
 * transform: a header with the block's plane and position plus the coefficients,
 * four per 64-bit word, only up to the last nonzero one.  Records are handed to
 * the core (SUBMIT = cache write-back + TAIL) whenever a block starts a new
 * 16-line band -- the previous band is then complete -- and at the end of the
 * frame, after three flush-only records for the last bands; the core transforms
 * them and writes each band to DRAM as whole lines.
 * Showing the frame waits for the core (WAIT) and tells the LCD driver that the
 * CPU cache holds nothing of the buffer (NOSYNC).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include "gowin-lcdfb.h"
#include "gowin-idct.h"
#include "idct_hw.h"

int idct_hw_on;                         /* a frame is open: the wrapper hands blocks here */

static struct {
    int fd, fb_fd;
    uint64_t *ring;
    uint32_t size, wmask;               /* ring bytes; word-index mask */
    uint32_t tail, head;                /* byte offsets: ours / the core's (last known) */
    uint32_t submitted;                 /* tail last given to the core */
    int frame_open;
    int band_y0;                        /* band of the last luma block, -1 = none yet */
    struct { uint8_t *base; int stride, w, h; } pl[3];
    unsigned frames, records, submits, waits, fallbacks, bad;
    struct gowin_idct_status base;      /* the core's lifetime counters at open */
    double wait_s;
} hw = { .fd = -1 };

int idct_hw_open(int fb_fd)
{
    struct gowin_idct_info info;
    hw.fd = open("/dev/gowin-idct", O_RDWR);
    if (hw.fd < 0) return -1;
    if (ioctl(hw.fd, GOWIN_IDCT_IOC_INFO, &info)) { close(hw.fd); hw.fd = -1; return -1; }
    hw.ring = mmap(NULL, info.ring_size, PROT_READ | PROT_WRITE, MAP_SHARED, hw.fd, 0);
    if (hw.ring == MAP_FAILED) { perror("mmap idct ring"); close(hw.fd); hw.fd = -1; return -1; }
    hw.size = info.ring_size;
    /* VIDPLAY_RING_KB: a ring small enough to stay in the D-cache spares the
     * write-allocate miss per record line (the core reads DRAM after SUBMIT's write-back) */
    if (getenv("VIDPLAY_RING_KB")) {
        uint32_t n = atoi(getenv("VIDPLAY_RING_KB")) * 1024;
        if (n >= 4096 && n <= info.ring_size && !(n & (n - 1)) && !ioctl(hw.fd, GOWIN_IDCT_IOC_RING, &n)) hw.size = n;
        else perror("idct ring size");
    }
    hw.wmask = hw.size / 8 - 1;
    hw.fb_fd = fb_fd;
    hw.tail = hw.head = hw.submitted = 0;
    ioctl(hw.fd, GOWIN_IDCT_IOC_STATUS, &hw.base);
    fprintf(stderr, "vidplay: hardware IDCT (ring %u KB, id %08x)\n", hw.size / 1024, info.id);
    return 0;
}

int idct_hw_ready(void) { return hw.fd >= 0; }

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* hand the records written so far to the core; refreshes head */
static int submit(void)
{
    struct gowin_idct_submit sb = { .tail = hw.tail };
    if (ioctl(hw.fd, GOWIN_IDCT_IOC_SUBMIT, &sb)) { perror("idct submit"); return -1; }
    hw.head = sb.head;
    if (hw.tail != hw.submitted) hw.submits++;
    hw.submitted = hw.tail;
    return 0;
}

static int wait_idle(void)
{
    uint32_t ms = 2000;
    double t0 = now_s();
    if (ioctl(hw.fd, GOWIN_IDCT_IOC_WAIT, &ms)) { perror("idct wait"); return -1; }
    hw.wait_s += now_s() - t0;
    hw.waits++;
    hw.head = ms;
    return 0;
}

/* Begin a frame whose planes lie in LCD scan-out buffer `buf` (mapped at `base`).
 * cw x ch = the coded size (multiples of 16, what the decoder writes); w x h =
 * the picture (what the core writes out).  Returns 0 when the core takes the frame. */
int idct_hw_frame_begin(int buf, uint8_t *base, uint8_t *y, uint8_t *u, uint8_t *v,
                        int ys, int cs, int cw, int ch, int w, int h)
{
    if (hw.fd < 0 || cw & 15 || cw > 1024 || !w || !h || w > cw || h > ch) { hw.fallbacks++; return -1; }
    if (hw.frame_open) idct_hw_frame_end();
    struct gowin_lcd_yuv_dma d = { .buf = buf, .flags = GOWIN_LCD_YUV_DMA_INVALIDATE };
    if (wait_idle()) { hw.fallbacks++; return -1; }       /* before the invalidate: no flush in flight */
    if (ioctl(hw.fb_fd, GOWIN_LCD_IOC_YUV_DMA, &d)) { perror("yuv dma"); hw.fallbacks++; return -1; }
    struct gowin_idct_setup s = {
        .y_base = d.dma + (y - base), .u_base = d.dma + (u - base), .v_base = d.dma + (v - base),
        .y_stride = ys, .c_stride = cs, .width = cw, .height = h,
    };
    if (ioctl(hw.fd, GOWIN_IDCT_IOC_SETUP, &s)) { perror("idct setup"); hw.fallbacks++; return -1; }
    hw.pl[0] = (typeof(hw.pl[0])){ y, ys, cw, ch };
    hw.pl[1] = (typeof(hw.pl[0])){ u, cs, cw / 2, ch / 2 };
    hw.pl[2] = (typeof(hw.pl[0])){ v, cs, cw / 2, ch / 2 };
    hw.band_y0 = -1;
    hw.frame_open = 1;
    hw.frames++;
    idct_hw_on = 1;
    return 0;
}

/* ring space for a record of `need` bytes (the core must have consumed what we overwrite) */
static int ring_room(uint32_t need)
{
    if (hw.size - ((hw.tail - hw.head) & (hw.size - 1)) > need + 64) return 0;
    submit();
    while (hw.size - ((hw.tail - hw.head) & (hw.size - 1)) <= need + 64)
        if (wait_idle()) return -1;
    return 0;
}

/* the frame's last bands with flush-only records, everything to the core (it keeps
 * working; idct_hw_frame_done waits) */
void idct_hw_frame_end(void)
{
    if (!hw.frame_open) return;
    idct_hw_on = 0;
    hw.frame_open = 0;
    if (ring_room(3 * 8) == 0)
        for (int p = 0; p < 3; p++) {
            hw.ring[(hw.tail / 8) & hw.wmask] = GOWIN_IDCT_HDR_FLUSH(p, 0);
            hw.tail = (hw.tail + 8) & (hw.size - 1);
        }
    submit();
}

int idct_hw_frame_done(void)
{
    if (hw.fd < 0) return 0;
    if (hw.frame_open) idct_hw_frame_end();
    return wait_idle();
}

/* one block: a record in the ring (the wrapper's fast path, so no syscalls unless
 * the ring is full or a band is complete) */
int idct_hw_put(uint8_t *dest, ptrdiff_t line_size, int16_t *block)
{
    int p;
    for (p = 0; p < 3; p++)
        if (dest >= hw.pl[p].base && line_size == hw.pl[p].stride) {
            size_t off = dest - hw.pl[p].base;
            int y = off / hw.pl[p].stride, x = off % hw.pl[p].stride;
            if (y >= hw.pl[p].h || x >= hw.pl[p].w) continue;
            /* a luma block in a new 16-line band: the previous band is complete
             * (a small ring: every quarter of it instead) */
            if (p == 0 && (y & ~15) != hw.band_y0) {
                if (hw.band_y0 >= 0) submit();
                hw.band_y0 = y & ~15;
            } else if (hw.size < 65536 && ((hw.tail - hw.submitted) & (hw.size - 1)) >= hw.size / 4) {
                submit();
            }
            /* the last nonzero coefficient (32-bit pairs; the block is hot in L1) */
            const uint32_t *b32 = (const uint32_t *)block;
            int i = 31;
            while (i >= 0 && !b32[i]) i--;
            unsigned n = i < 0 ? 0 : (b32[i] >> 16) ? 2 * i + 2 : 2 * i + 1;
            unsigned nw = (n + 3) / 4;
            uint32_t need = (nw + 1) * 8;
            if (ring_room(need)) return 0;
            uint32_t wi = hw.tail / 8;
            hw.ring[wi & hw.wmask] = GOWIN_IDCT_HDR(n, 0, p, x, y, 0);
            for (unsigned k = 0; k < nw; k++)
                hw.ring[(wi + 1 + k) & hw.wmask] = ((uint64_t)b32[2 * k + 1] << 32) | b32[2 * k];
            hw.tail = (hw.tail + need) & (hw.size - 1);
            hw.records++;
            return 1;
        }
    hw.fallbacks++;
    return 0;
}

/* the core decodes JPEG records itself (gateware Build 70+) */
int idct_hw_jpeg_capable(void)
{
    struct gowin_idct_status st = { 0 };
    return hw.fd >= 0 && !ioctl(hw.fd, GOWIN_IDCT_IOC_STATUS, &st) && (st.status & GOWIN_IDCT_ST_JPEG);
}

/* one record: header, an optional parameter word, then `len` payload bytes padded to
 * a word (a JPEG table or scan); written in ring order, wrapping, submitted later */
int idct_hw_put_record(uint64_t hdr, const uint64_t *param, const void *payload, unsigned len)
{
    uint32_t need = 8 + (param ? 8 : 0) + ((len + 7) & ~7u);
    if (need + 64 > hw.size / 2 || ring_room(need)) return -1;
    uint8_t *ring = (uint8_t *)hw.ring;
    hw.ring[(hw.tail / 8) & hw.wmask] = hdr;
    hw.tail = (hw.tail + 8) & (hw.size - 1);
    if (param) {
        hw.ring[(hw.tail / 8) & hw.wmask] = *param;
        hw.tail = (hw.tail + 8) & (hw.size - 1);
    }
    if (len) {
        uint32_t first = hw.size - hw.tail < len ? hw.size - hw.tail : len;
        memcpy(ring + hw.tail, payload, first);
        if (first < len) memcpy(ring, (const uint8_t *)payload + first, len - first);
        uint32_t end = (hw.tail + len) & (hw.size - 1), pad = (8 - (len & 7)) & 7;
        if (pad) memset(ring + end, 0, pad);                 /* a word never straddles the wrap */
        hw.tail = (hw.tail + len + pad) & (hw.size - 1);
    }
    hw.records++;
    return 0;
}

void idct_hw_stats(FILE *f)
{
    if (hw.fd < 0) return;
    struct gowin_idct_status st = { 0 };
    ioctl(hw.fd, GOWIN_IDCT_IOC_STATUS, &st);
    fprintf(f, "hardware IDCT: %u frames, %u records, %u submits, %u waits (%.1f ms), %u fallbacks; "
            "core: %u blocks, %u bands, %u irqs%s\n", hw.frames, hw.records, hw.submits, hw.waits,
            hw.wait_s * 1e3, hw.fallbacks, st.blocks - hw.base.blocks, st.bands - hw.base.bands, st.irqs - hw.base.irqs,
            (st.status & 8) ? ", BAD RECORD" : "");
}

void idct_hw_close(void)
{
    if (hw.fd < 0) return;
    idct_hw_frame_done();
    munmap(hw.ring, hw.size);
    close(hw.fd);
    hw.fd = -1;
}
