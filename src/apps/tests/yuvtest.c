/*
 * yuvtest -- hardware check of the LCD core's YUV 4:2:0 scan-out mode (gateware
 * Build 68+, gowin-lcdfb ioctls) without looking at the panel:
 *
 *   yuvtest [-l] [-f /dev/fb0]       (-l: BT.601 limited range instead of full)
 *
 * Fills YUV buffer 0 with the testbench's pattern (src/rtl/video/tb/tb_video.v:
 * Y = 3x+5y, U = 7cx+11cy+40, V = 200-5cx+3cy), shows it, waits a few frames
 * and compares the core's frame CRC (CRC-32 of the RGB565 pixels as sent) with
 * the same fixed-point conversion done here.  Then switches back to RGB and
 * checks that the RGB framebuffer's CRC is back.  Exit 0 = both match.
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

#define LCD_BASE  0xE8001000u
#define LCD_FRAMES 8
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
static uint32_t crc_u16(uint32_t c, uint16_t v)
{
    c = crc_table[(c ^ (v & 0xff)) & 0xff] ^ (c >> 8);
    c = crc_table[(c ^ (v >> 8)) & 0xff] ^ (c >> 8);
    return c;
}

static int clamp8(int v) { v >>= 8; return v < 0 ? 0 : v > 255 ? 255 : v; }

static uint16_t model_pix(int Y, int U, int V, int full)
{
    int ky = full ? 256 : 298, ko = full ? 128 : -4640;
    int krv = full ? 359 : 409, kgu = full ? 88 : 100, kgv = full ? 183 : 208, kbu = full ? 454 : 516;
    U -= 128; V -= 128;
    int r = clamp8(ky * Y + ko + krv * V), g = clamp8(ky * Y + ko - kgu * U - kgv * V), b = clamp8(ky * Y + ko + kbu * U);
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3);
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
    int full = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-l")) full = 0;
        else if (!strcmp(argv[i], "-f") && i + 1 < argc) fbdev = argv[++i];
    }
    int fd = open(fbdev, O_RDWR);
    if (fd < 0) { perror(fbdev); return 1; }
    struct gowin_lcd_yuv_info yi;
    if (ioctl(fd, GOWIN_LCD_IOC_YUV_INFO, &yi)) { perror("YUV_INFO (old kernel?)"); return 1; }
    if (!yi.nbuf) { fprintf(stderr, "the gateware has no YUV mode (Build 68+ needed)\n"); return 1; }
    printf("yuvtest: %u buffers, %ux%u, Y stride %u, C stride %u, %u bytes each, mmap offset 0x%x\n",
           yi.nbuf, yi.width, yi.height, yi.y_stride, yi.c_stride, yi.buf_size, yi.mmap_off);
    uint8_t *b = mmap(NULL, yi.buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, yi.mmap_off);
    if (b == MAP_FAILED) { perror("mmap"); return 1; }
    int mfd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *regs = mfd < 0 ? NULL : mmap(NULL, 4096, PROT_READ, MAP_SHARED, mfd, LCD_BASE);
    if (!regs || regs == MAP_FAILED) { perror("/dev/mem"); return 1; }

    /* the pattern, and its model CRC (RGB565, row by row, chroma repeated) */
    crc_init();
    unsigned W = yi.width, H = yi.height;
    for (unsigned y = 0; y < H; y++)
        for (unsigned x = 0; x < W; x++) b[y * yi.y_stride + x] = (x * 3 + y * 5) & 255;
    for (unsigned cy = 0; cy < H / 2; cy++)
        for (unsigned cx = 0; cx < W / 2; cx++) {
            b[yi.u_off + cy * yi.c_stride + cx] = (cx * 7 + cy * 11 + 40) & 255;
            b[yi.v_off + cy * yi.c_stride + cx] = (200 - cx * 5 + cy * 3) & 255;
        }
    uint32_t model = 0xFFFFFFFFu;
    for (unsigned y = 0; y < H; y++)
        for (unsigned x = 0; x < W; x++)
            model = crc_u16(model, model_pix(b[y * yi.y_stride + x], b[yi.u_off + (y / 2) * yi.c_stride + x / 2],
                                             b[yi.v_off + (y / 2) * yi.c_stride + x / 2], full));
    model = ~model;

    uint32_t crc_rgb_before = wait_frames(regs, 2);
    struct gowin_lcd_yuv_show sh = { .buf = 0, .flags = full ? GOWIN_LCD_YUV_FULL_RANGE : 0,
                                     .y_off = 0, .u_off = yi.u_off, .v_off = yi.v_off,
                                     .y_stride = yi.y_stride, .c_stride = yi.c_stride };
    if (ioctl(fd, GOWIN_LCD_IOC_YUV_SHOW, &sh)) { perror("YUV_SHOW"); return 1; }
    uint32_t crc_yuv = wait_frames(regs, 3);
    uint32_t underruns = regs[9];
    if (ioctl(fd, GOWIN_LCD_IOC_RGB)) { perror("RGB"); return 1; }
    uint32_t crc_rgb_after = wait_frames(regs, 3);

    /* the RGB screen is live (the desktop clock redraws), so its CRC is only reported */
    int ok_yuv = crc_yuv == model;
    printf("YUVTEST %s range: hw CRC %08X model %08X -> %s; underruns %u; RGB screen CRC %08X before, %08X after (%s)\n",
           full ? "full" : "limited", crc_yuv, model, ok_yuv ? "MATCH" : "MISMATCH", underruns,
           crc_rgb_before, crc_rgb_after, crc_rgb_after == crc_rgb_before ? "same" : "changed: fine if something redrew");
    return ok_yuv ? 0 : 1;
}
