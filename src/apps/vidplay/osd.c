/*
 * osd.c -- vidplay's playback bar on the LCD core's OSD layer (gateware Build 71+):
 * a semi-transparent dark panel at the bottom of the screen with an opaque slider
 * (grey track, blue played part, white knob) and opaque white title and time.
 *
 * It is drawn in software into one of the driver's two ARGB8888 OSD buffers (only
 * the strip, ~200 KB) at most once a second and shown with GOWIN_LCD_IOC_OSD, which
 * writes it back from the cache.  After a buffer's first full draw only the slider
 * band and the time area are repainted: the strip is cold memory, and a full
 * redraw costs ~10 ms of misses.  The core blends the layer over the video in
 * hardware, so the picture path is not touched, and each update goes into the
 * other buffer, so it never tears.
 *
 * Pixels are straight-alpha ARGB.  Opaque shapes and glyphs are composited over
 * the panel with their anti-aliasing coverage, so their edges stay smooth while
 * their insides are fully opaque.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include "gowin-lcdfb.h"
#include "osd.h"
#include "osd_font.h"

#define BAR_H     64                    /* the strip */
#define PAD       16                    /* left / right margin */
#define SL_Y      16                    /* slider centre line */
#define SL_R      3                     /* track half-height (6 px track) */
#define KNOB_R    8                     /* knob radius */
#define SL_BAND0  (SL_Y - KNOB_R - 2)   /* rows repainted for the slider */
#define SL_BAND1  (SL_Y + KNOB_R + 2)
#define TEXT_Y    32                    /* top of the text row (font height 24) */

#define C_PANEL   0x9A0C0E12u           /* semi-transparent near-black (60 %) */
#define C_TRACK   0xFF5A5E66u           /* opaque grey */
#define C_PLAYED  0xFF3D9BFFu           /* opaque blue */
#define C_KNOB    0xFFFFFFFFu           /* opaque white */
#define C_TEXT    0xFFFFFFFFu

static struct {
    int fd, on, cur;
    unsigned w, h, stride;
    uint32_t *buf[2];
    size_t size;
    char key[160];                      /* what the shown buffer holds */
    char base[2][128];                  /* the title each buffer's static part was drawn for */
    unsigned tx;                        /* left edge of the time area */
    long last_sec;                      /* the second the shown bar was drawn for */
    const char *last_title;
} osd = { .fd = -1, .last_sec = -1 };

int osd_init(int fb_fd, unsigned panel_w, unsigned panel_h)
{
    struct gowin_lcd_caps caps;
    if (ioctl(fb_fd, GOWIN_LCD_IOC_CAPS, &caps) || !(caps.caps & GOWIN_LCD_CAP_OSD) || caps.osd_nbuf < 2) return -1;
    for (int i = 0; i < 2; i++) {
        osd.buf[i] = mmap(NULL, caps.osd_buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd,
                          (off_t)caps.osd_mmap_off + (off_t)i * caps.osd_buf_size);
        if (osd.buf[i] == MAP_FAILED) { perror("mmap osd"); return -1; }
    }
    osd.fd = fb_fd; osd.w = panel_w; osd.h = panel_h; osd.stride = caps.osd_stride / 4; osd.size = caps.osd_buf_size;
    return 0;
}

static void fill(uint32_t *b, unsigned x0, unsigned y0, unsigned w, unsigned h, uint32_t argb)
{
    for (unsigned y = y0; y < y0 + h && y < BAR_H; y++)
        for (unsigned x = x0; x < x0 + w && x < osd.w; x++) b[y * osd.stride + x] = argb;
}

/* an opaque colour with coverage cov (0..255) over a straight-alpha pixel */
static inline void blend(uint32_t *p, uint32_t c, unsigned cov)
{
    if (!cov) return;
    if (cov >= 255) { *p = c | 0xFF000000u; return; }
    unsigned pa = *p >> 24;
    unsigned na = cov + pa * (255 - cov) / 255;              /* resulting alpha */
    uint32_t out = na << 24;
    for (int s = 0; s < 24; s += 8) {
        unsigned src = (c >> s) & 255, dst = (*p >> s) & 255;
        unsigned v = (src * cov * 255 + dst * pa * (255 - cov)) / (na * 255);
        out |= (v > 255 ? 255 : v) << s;
    }
    *p = out;
}

/* a filled disc, anti-aliased (4x4 supersampling at the edge) */
static void disc(uint32_t *b, int cx, int cy, int r, uint32_t c)
{
    for (int y = cy - r - 1; y <= cy + r + 1; y++) {
        if (y < 0 || y >= BAR_H) continue;
        for (int x = cx - r - 1; x <= cx + r + 1; x++) {
            if (x < 0 || x >= (int)osd.w) continue;
            int in = 0;
            for (int sy = 0; sy < 4; sy++)
                for (int sx = 0; sx < 4; sx++) {
                    int dx = (x - cx) * 8 + sx * 2 - 3, dy = (y - cy) * 8 + sy * 2 - 3;   /* 1/8-px units */
                    in += dx * dx + dy * dy <= r * r * 64;
                }
            blend(&b[y * osd.stride + x], c, in * 255 / 16);
        }
    }
}

/* a horizontal bar with round ends from x0 to x1 (centre line SL_Y, half-height SL_R) */
static void pill(uint32_t *b, int x0, int x1, uint32_t c)
{
    if (x1 <= x0) return;
    disc(b, x0, SL_Y, SL_R, c);
    disc(b, x1, SL_Y, SL_R, c);
    for (int y = SL_Y - SL_R; y <= SL_Y + SL_R; y++)
        for (int x = x0; x <= x1; x++) blend(&b[y * osd.stride + x], c, 255);
}

static unsigned text_width(const char *s)
{
    unsigned w = 0;
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c < OSD_FONT_FIRST || c > OSD_FONT_LAST) c = '?';
        w += osd_glyph[c - OSD_FONT_FIRST].adv;
    }
    return w;
}

/* opaque white text, its anti-aliased edges composited over the panel */
static void text(uint32_t *b, unsigned x, unsigned y, const char *s, unsigned xmax)
{
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c < OSD_FONT_FIRST || c > OSD_FONT_LAST) c = '?';
        unsigned g = c - OSD_FONT_FIRST, gw = osd_glyph[g].w;
        if (x + osd_glyph[g].adv > xmax) break;
        const unsigned char *a = osd_font_alpha + osd_glyph[g].off;
        for (unsigned j = 0; j < OSD_FONT_H && y + j < BAR_H; j++)
            for (unsigned i = 0; i < gw && x + i < osd.w; i++)
                blend(&b[(y + j) * osd.stride + x + i], C_TEXT, a[j * gw + i]);
        x += osd_glyph[g].adv;
    }
}

static void hms(char *o, size_t n, double t)
{
    if (t < 0) t = 0;
    unsigned s = (unsigned)t;
    if (s >= 3600) snprintf(o, n, "%u:%02u:%02u", s / 3600, s / 60 % 60, s % 60);
    else snprintf(o, n, "%u:%02u", s / 60, s % 60);
}

void osd_update(int visible, const char *title, double pos, double dur)
{
    if (osd.fd < 0) return;
    if (!visible) {
        if (osd.on) {
            struct gowin_lcd_osd o = { .flags = 0 };
            ioctl(osd.fd, GOWIN_LCD_IOC_OSD, &o);
            osd.on = 0;
            osd.key[0] = 0;
            osd.last_sec = -1;
        }
        return;
    }
    /* called every loop iteration: nothing but a compare unless the second changed */
    if (osd.on && (long)pos == osd.last_sec && title == osd.last_title) return;
    osd.last_sec = (long)pos;
    osd.last_title = title;
    char tp[24], td[24], tm[64], key[sizeof(osd.key)];
    hms(tp, sizeof(tp), pos);
    hms(td, sizeof(td), dur);
    if (dur > 0) snprintf(tm, sizeof(tm), "%s / %s", tp, td);
    else snprintf(tm, sizeof(tm), "%s", tp);
    snprintf(key, sizeof(key), "%s|%s", title, tm);          /* at most one update a second */
    if (osd.on && !strcmp(key, osd.key)) return;

    int nb = osd.on ? !osd.cur : osd.cur;
    uint32_t *b = osd.buf[nb];
    if (strcmp(osd.base[nb], title)) {                       /* the static part, once per buffer */
        osd.tx = osd.w - PAD - text_width(dur >= 3600 ? "00:00:00 / 00:00:00" : "00:00 / 00:00");
        fill(b, 0, 0, osd.w, BAR_H, C_PANEL);
        text(b, PAD, TEXT_Y, title, osd.tx - 2 * PAD);
        snprintf(osd.base[nb], sizeof(osd.base[nb]), "%s", title);
    }
    /* the slider: track, played part, knob */
    int x0 = PAD + KNOB_R, x1 = osd.w - PAD - KNOB_R;
    double f = dur > 0 ? (pos < dur ? pos : dur) / dur : 0;
    int xk = x0 + (int)((x1 - x0) * f + 0.5);
    fill(b, 0, SL_BAND0, osd.w, SL_BAND1 - SL_BAND0 + 1, C_PANEL);
    pill(b, x0, x1, C_TRACK);
    pill(b, x0, xk, C_PLAYED);
    disc(b, xk, SL_Y, KNOB_R, C_KNOB);
    /* the time, right-aligned */
    fill(b, osd.tx, TEXT_Y, osd.w - osd.tx, OSD_FONT_H, C_PANEL);
    text(b, osd.w - PAD - text_width(tm), TEXT_Y, tm, osd.w);

    struct gowin_lcd_osd o = { .flags = GOWIN_LCD_OSD_ON, .buf = nb, .x = 0, .y = osd.h - BAR_H, .w = osd.w, .h = BAR_H };
    if (ioctl(osd.fd, GOWIN_LCD_IOC_OSD, &o)) { perror("osd"); osd.fd = -1; return; }
    osd.cur = nb;
    osd.on = 1;
    snprintf(osd.key, sizeof(osd.key), "%s", key);
}

void osd_close(void)
{
    if (osd.fd < 0) return;
    osd_update(0, NULL, 0, 0);
    for (int i = 0; i < 2; i++) munmap(osd.buf[i], osd.size);
    osd.fd = -1;
}
