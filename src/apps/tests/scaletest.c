/*
 * scaletest -- hardware check of the LCD core's scaler and OSD layer (gateware
 * Build 71+, gowin-lcdfb GOWIN_LCD_IOC_SCALE / _OSD) without looking at the panel:
 *
 *   scaletest [-f /dev/fb0] [-k]       (-k: keep the last scene on the panel for 5 s)
 *
 * A YUV 4:2:0 test pattern in YUV buffer 0 and an ARGB8888 pattern (alpha 0,
 * 255 and values in between) in OSD buffer 0 are shown in several scenes --
 * upscaled, downscaled, odd factors, windows with a background colour, the OSD
 * over a 1:1 picture and over a scaled one -- and for each the core's frame CRC
 * (CRC-32 of the RGB565 pixels as sent) is compared with the same arithmetic done
 * here: nearest neighbour sample k = floor((k*step + step/2) / 65536) with the
 * driver's step = src * 65536 / dst, fixed-point BT.601 / full-range conversion
 * to RGB888, blend (osd*a' + pic*(256-a')) >> 8 with a' = A + A[7], RGB565.
 * Exit 0 = every scene matches.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/fb.h>
#include "../vidplay/gowin-lcdfb.h"

#define LCD_BASE   0xE8001000u
#define LCD_FRAMES 8
#define LCD_UNDERRUN 9
#define LCD_CRC    10

static uint32_t crc_table[256];
static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
        crc_table[i] = c;
    }
}
static inline uint32_t crc_u16(uint32_t c, uint16_t v)
{
    c = crc_table[(c ^ (v & 0xff)) & 0xff] ^ (c >> 8);
    return crc_table[(c ^ (v >> 8)) & 0xff] ^ (c >> 8);
}

/* the patterns */
static inline uint8_t ys_(unsigned x, unsigned y) { return (x * 3 + y * 5) & 255; }
static inline uint8_t us(unsigned cx, unsigned cy) { return (cx * 7 + cy * 11 + 40) & 255; }
static inline uint8_t vs(unsigned cx, unsigned cy) { return (200 - cx * 5 + cy * 3) & 255; }
static uint32_t osdpix(unsigned x, unsigned y)
{
    unsigned a = (x % 4 == 0) ? 0 : (x % 4 == 1) ? 255 : (x % 4 == 2) ? ((x * 13 + y * 7) & 255) : 128;
    unsigned r = (x * 9 + y) & 255, g = (255 - x * 5) & 255, b = (y * 20 + x) & 255;
    return a << 24 | r << 16 | g << 8 | b;
}

static inline int clamp8(int v) { v >>= 8; return v < 0 ? 0 : v > 255 ? 255 : v; }
static uint32_t yuv888(int Y, int U, int V, int full)
{
    int ky = full ? 256 : 298, ko = full ? 128 : -4640;
    int krv = full ? 359 : 409, kgu = full ? 88 : 100, kgv = full ? 183 : 208, kbu = full ? 454 : 516;
    U -= 128; V -= 128;
    return (uint32_t)clamp8(ky * Y + ko + krv * V) << 16 | (uint32_t)clamp8(ky * Y + ko - kgu * U - kgv * V) << 8 |
           (uint32_t)clamp8(ky * Y + ko + kbu * U);
}
static uint32_t rgb888(uint16_t p)
{
    unsigned r = p >> 11, g = (p >> 5) & 63, b = p & 31;
    return (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8 | (b << 3 | b >> 2);
}

struct scene {
    const char *name;
    int full;
    int scale; unsigned sw, sh, dx, dy, dw, dh; uint16_t bg;
    int osd; unsigned ox, oy, ow, oh;
};

static uint32_t model_crc(const struct scene *s, unsigned W, unsigned H)
{
    uint32_t crc = 0xFFFFFFFFu;
    unsigned sw = s->scale ? s->sw : W, sh = s->scale ? s->sh : H;
    unsigned dx = s->scale ? s->dx : 0, dy = s->scale ? s->dy : 0, dw = s->scale ? s->dw : W, dh = s->scale ? s->dh : H;
    uint64_t stx = s->scale ? ((uint64_t)sw << 16) / dw : 65536, sty = s->scale ? ((uint64_t)sh << 16) / dh : 65536;
    uint32_t bg = rgb888(s->scale ? s->bg : 0);
    for (unsigned y = 0; y < H; y++) {
        int vin = y >= dy && y < dy + dh;
        unsigned sy = vin ? (unsigned)(((y - dy) * sty + sty / 2) >> 16) : 0;
        if (sy > sh - 1) sy = sh - 1;
        for (unsigned x = 0; x < W; x++) {
            uint32_t pic = bg;
            if (vin && x >= dx && x < dx + dw) {
                unsigned sx = (unsigned)(((x - dx) * stx + stx / 2) >> 16);
                if (sx > sw - 1) sx = sw - 1;
                pic = yuv888(ys_(sx, sy), us(sx / 2, sy / 2), vs(sx / 2, sy / 2), s->full);
            }
            uint32_t o = 0, a = 0;
            if (s->osd && x >= s->ox && x < s->ox + s->ow && y >= s->oy && y < s->oy + s->oh) {
                o = osdpix(x - s->ox, y - s->oy);
                a = (o >> 24) + (o >> 31);
            }
            unsigned c[3];
            for (int i = 0; i < 3; i++)
                c[i] = ((o >> (8 * i)) & 255) * a + ((pic >> (8 * i)) & 255) * (256 - a);
            crc = crc_u16(crc, (uint16_t)((c[2] >> 11) << 11 | (c[1] >> 10) << 5 | (c[0] >> 11)));
        }
    }
    return ~crc;
}

static uint32_t wait_frames(volatile uint32_t *regs, int n)
{
    uint32_t f0 = regs[LCD_FRAMES];
    while ((uint32_t)(regs[LCD_FRAMES] - f0) < (uint32_t)n) usleep(1000);
    return regs[LCD_CRC];
}

int main(int argc, char **argv)
{
    const char *fbdev = "/dev/fb0";
    int keep = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-f") && i + 1 < argc) fbdev = argv[++i];
        else if (!strcmp(argv[i], "-k")) keep = 1;
    }
    int fd = open(fbdev, O_RDWR);
    if (fd < 0) { perror(fbdev); return 1; }
    struct gowin_lcd_yuv_info yi;
    struct gowin_lcd_caps caps;
    if (ioctl(fd, GOWIN_LCD_IOC_YUV_INFO, &yi) || !yi.nbuf) { fprintf(stderr, "no YUV buffers\n"); return 1; }
    if (ioctl(fd, GOWIN_LCD_IOC_CAPS, &caps)) { perror("CAPS (kernel with the scaler/OSD ioctls needed)"); return 1; }
    if ((caps.caps & 7) != 7 || !caps.osd_nbuf) {
        fprintf(stderr, "the gateware has no scaler/OSD (caps %x, Build 71+ needed)\n", caps.caps);
        return 1;
    }
    unsigned W = yi.width, H = yi.height;
    uint8_t *b = mmap(NULL, yi.buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, yi.mmap_off);
    uint8_t *ob = mmap(NULL, caps.osd_buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, caps.osd_mmap_off);
    if (b == MAP_FAILED || ob == MAP_FAILED) { perror("mmap"); return 1; }
    int mfd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *regs = mfd < 0 ? NULL : mmap(NULL, 4096, PROT_READ, MAP_SHARED, mfd, LCD_BASE);
    if (!regs || regs == MAP_FAILED) { perror("/dev/mem"); return 1; }
    printf("scaletest: panel %ux%u, caps %x, %u OSD buffers (stride %u)\n", W, H, caps.caps, caps.osd_nbuf, caps.osd_stride);

    /* the source pattern (up to the panel size; the buffer's default layout) and the OSD pattern */
    for (unsigned y = 0; y < H; y++)
        for (unsigned x = 0; x < W; x++) b[y * yi.y_stride + x] = ys_(x, y);
    for (unsigned cy = 0; cy < H / 2; cy++)
        for (unsigned cx = 0; cx < W / 2; cx++) {
            b[yi.u_off + cy * yi.c_stride + cx] = us(cx, cy);
            b[yi.v_off + cy * yi.c_stride + cx] = vs(cx, cy);
        }
    for (unsigned y = 0; y < H; y++)
        for (unsigned x = 0; x < W; x++) ((uint32_t *)(ob + y * caps.osd_stride))[x] = osdpix(x, y);
    crc_init();

    const struct scene scenes[] = {
        { "1:1, no OSD (as Build 68)",     1, 0, 0, 0, 0, 0, 0, 0, 0,      0, 0, 0, 0, 0 },
        { "upscale 320x180 -> 800x450",    1, 1, 320, 180, 0, 15, 800, 450, 0x0000, 0, 0, 0, 0, 0 },
        { "downscale 800x480 -> 400x240",  0, 1, 800, 480, 200, 120, 400, 240, 0x18E3, 0, 0, 0, 0, 0 },
        { "odd 333x211 -> 761x462",        1, 1, 333, 211, 17, 9, 761, 462, 0x7BEF, 0, 0, 0, 0, 0 },
        { "OSD 300x120 over 1:1",          1, 0, 0, 0, 0, 0, 0, 0, 0,      1, 250, 180, 300, 120 },
        { "upscale 480x270 + OSD bar",     1, 1, 480, 270, 0, 15, 800, 450, 0x0000, 1, 0, 424, 800, 56 },
        { "1/4 window + full-screen OSD",  0, 1, 640, 360, 500, 300, 200, 112, 0xF800, 1, 0, 0, 800, 480 },
    };
    int fails = 0;
    for (unsigned i = 0; i < sizeof(scenes) / sizeof(scenes[0]); i++) {
        const struct scene *s = &scenes[i];
        struct gowin_lcd_yuv_show sh = { .buf = 0, .flags = s->full ? GOWIN_LCD_YUV_FULL_RANGE : 0,
                                         .y_off = 0, .u_off = yi.u_off, .v_off = yi.v_off,
                                         .y_stride = yi.y_stride, .c_stride = yi.c_stride };
        struct gowin_lcd_scale sc = { .flags = s->scale ? GOWIN_LCD_SCALE_ON : 0, .src_w = s->sw, .src_h = s->sh,
                                      .dst_x = s->dx, .dst_y = s->dy, .dst_w = s->dw, .dst_h = s->dh, .bg = s->bg };
        struct gowin_lcd_osd o = { .flags = s->osd ? GOWIN_LCD_OSD_ON : 0, .buf = 0,
                                   .x = s->ox, .y = s->oy, .w = s->ow, .h = s->oh };
        if (ioctl(fd, GOWIN_LCD_IOC_YUV_SHOW, &sh) || ioctl(fd, GOWIN_LCD_IOC_SCALE, &sc) ||
            ioctl(fd, GOWIN_LCD_IOC_OSD, &o)) { perror("ioctl"); return 1; }
        uint32_t ur0 = regs[LCD_UNDERRUN];
        uint32_t hw = wait_frames(regs, 3);
        uint32_t model = model_crc(s, W, H);
        uint32_t ur = regs[LCD_UNDERRUN] - ur0;
        printf("  %-32s hw %08X model %08X -> %s, underruns %u\n", s->name, hw, model, hw == model ? "MATCH" : "MISMATCH", ur);
        if (hw != model) fails++;
    }
    /* a source wider than the panel: 852x480 in its own layout
     * (the buffers hold up to 1024x768 with the scaler), fitted to 800x450 */
    unsigned SW = 852, SH = 480, ys = (SW + 31) & ~31u, cs = (SW / 2 + 31) & ~31u;
    unsigned uo = ys * SH, vo = uo + cs * (SH / 2);
    if (vo + cs * (SH / 2) <= yi.buf_size) {
        for (unsigned y = 0; y < SH; y++)
            for (unsigned x = 0; x < SW; x++) b[y * ys + x] = ys_(x, y);
        for (unsigned cy = 0; cy < SH / 2; cy++)
            for (unsigned cx = 0; cx < SW / 2; cx++) { b[uo + cy * cs + cx] = us(cx, cy); b[vo + cy * cs + cx] = vs(cx, cy); }
        const struct scene s = { "852x480 own layout -> 800x450", 1, 1, SW, SH, 0, 15, 800, 450, 0x0000, 1, 0, 424, 800, 56 };
        struct gowin_lcd_scale sc = { .flags = GOWIN_LCD_SCALE_ON, .src_w = SW, .src_h = SH,
                                      .dst_x = 0, .dst_y = 15, .dst_w = 800, .dst_h = 450 };
        struct gowin_lcd_yuv_show sh = { .buf = 0, .flags = GOWIN_LCD_YUV_FULL_RANGE, .y_off = 0, .u_off = uo, .v_off = vo,
                                         .y_stride = ys, .c_stride = cs };
        struct gowin_lcd_osd o = { .flags = GOWIN_LCD_OSD_ON, .buf = 0, .x = 0, .y = 424, .w = 800, .h = 56 };
        if (ioctl(fd, GOWIN_LCD_IOC_SCALE, &sc) || ioctl(fd, GOWIN_LCD_IOC_YUV_SHOW, &sh) ||
            ioctl(fd, GOWIN_LCD_IOC_OSD, &o)) { perror("ioctl (852x480)"); return 1; }
        uint32_t ur0 = regs[LCD_UNDERRUN];
        uint32_t hw = wait_frames(regs, 3);
        uint32_t model = model_crc(&s, W, H);
        printf("  %-32s hw %08X model %08X -> %s, underruns %u\n", s.name, hw, model, hw == model ? "MATCH" : "MISMATCH",
               regs[LCD_UNDERRUN] - ur0);
        if (hw != model) fails++;
    } else printf("  852x480 scene skipped: buffers of %u bytes (kernel #85+ holds larger sources)\n", yi.buf_size);
    if (keep) sleep(5);
    if (ioctl(fd, GOWIN_LCD_IOC_RGB)) perror("RGB");
    printf("SCALETEST %s\n", fails ? "FAILED" : "PASSED");
    return fails ? 1 : 0;
}
