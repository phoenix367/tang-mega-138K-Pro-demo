/*
 * fbtest -- check the LCD framebuffer end to end on the board.
 *
 *   fbtest bars|grad|noise   draw through mmap() of /dev/fb0
 *   fbtest write             draw a pattern with write() on /dev/fb0
 *   fbtest check             draw nothing (e.g. after printing on fbcon)
 *
 * Then it waits for the driver's write-backs and two frames, and compares the
 * zlib CRC-32 of the framebuffer as the CPU sees it (RGB565 rows) with the CRC
 * the video core computed over the pixels it actually sent to the panel
 * (register 0xE8001028).  Equal CRCs mean every displayed pixel is what the CPU
 * drew -- including that the driver wrote its cached writes back to DRAM.
 */
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define LCD_BASE  0xE8001000u
#define R_FRAMES  (0x20 / 4)
#define R_UNDER   (0x24 / 4)
#define R_CRC     (0x28 / 4)

static uint32_t crc_tab[256];

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ ((c & 1) ? 0xEDB88320u : 0);
        crc_tab[i] = c;
    }
}

static uint32_t crc_update(uint32_t c, const uint8_t *p, size_t n)
{
    while (n--) c = crc_tab[(c ^ *p++) & 0xff] ^ (c >> 8);
    return c;
}

static uint16_t rgb(int r, int g, int b)          /* 8-bit components -> RGB565 */
{
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

static uint16_t pattern(const char *mode, int x, int y, int w, int h)
{
    static const uint16_t bars[8] = { 0xFFFF, 0xFFE0, 0x07FF, 0x07E0, 0xF81F, 0xF800, 0x001F, 0x0000 };
    if (!strcmp(mode, "bars"))
        return bars[x * 8 / w];
    if (!strcmp(mode, "grad"))
        return rgb(x * 255 / (w - 1), y * 255 / (h - 1), 255 - x * 255 / (w - 1));
    /* noise / write: deterministic per-pixel hash */
    uint32_t v = (uint32_t)(x * 2654435761u) ^ (uint32_t)(y * 40503u) ^ 0x5bd1e995u;
    v ^= v >> 13; v *= 0x85ebca6bu; v ^= v >> 16;
    return (uint16_t)v;
}

static void sleep_ms(int ms)
{
    struct timespec t = { ms / 1000, (ms % 1000) * 1000000L };
    nanosleep(&t, NULL);
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "bars";
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0 || ioctl(fd, FBIOGET_VSCREENINFO, &var) || ioctl(fd, FBIOGET_FSCREENINFO, &fix)) {
        perror("/dev/fb0");
        return 1;
    }
    int w = var.xres, h = var.yres, ll = fix.line_length;
    uint8_t *fb = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    int mfd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *regs = mmap(NULL, 4096, PROT_READ, MAP_SHARED, mfd, LCD_BASE);
    if (fb == MAP_FAILED || regs == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    crc_init();

    if (!strcmp(mode, "write")) {
        uint16_t *line = malloc(ll);
        lseek(fd, 0, SEEK_SET);
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) line[x] = pattern(mode, x, y, w, h);
            if (write(fd, line, ll) != ll) { perror("write"); return 1; }
        }
        free(line);
    } else if (strcmp(mode, "check")) {
        for (int y = 0; y < h; y++) {
            uint16_t *row = (uint16_t *)(fb + y * ll);
            for (int x = 0; x < w; x++) row[x] = pattern(mode, x, y, w, h);
        }
    }

    sleep_ms(100);                              /* deferred I/O write-back (20 ms) */
    uint32_t f0 = regs[R_FRAMES];
    while (regs[R_FRAMES] < f0 + 2) sleep_ms(5);  /* a whole frame after the write-back */
    uint32_t hw = regs[R_CRC];

    uint32_t c = 0xFFFFFFFFu;
    for (int y = 0; y < h; y++) c = crc_update(c, fb + y * ll, w * 2);
    c = ~c;
    printf("FBTEST %s %dx%d: cpu crc %08x, panel crc %08x -> %s (frames %u, underruns %u)\n",
           mode, w, h, c, hw, c == hw ? "MATCH" : "MISMATCH", regs[R_FRAMES], regs[R_UNDER]);
    return c != hw;
}
