/*
 * osd_preview.c -- vidplay's playback bar (src/apps/vidplay/osd.c) drawn on the host: the
 * real drawing code with the driver's ioctl/mmap replaced, the bar's ARGB8888 strip
 * (800 x 64) written to stdout.  render_panel.py composites it the way the LCD core does.
 *   cc -O1 -I../../src/apps/vidplay -include osd_fake.h -o osd_preview osd_preview.c ../../src/apps/vidplay/osd.c
 *   ./osd_preview POS DUR TITLE > strip.raw
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include "gowin-lcdfb.h"
#include "osd.h"

static uint32_t *bufs[2];
static int nmap, shown = -1;
void *fake_mmap(void *a, size_t l, int p, int f, int fd, long o) { return bufs[nmap++] = calloc(1, l); }
int fake_munmap(void *a, size_t l) { return 0; }
int fake_ioctl(int fd, unsigned long req, ...)
{
    va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
    if (req == GOWIN_LCD_IOC_CAPS) {
        struct gowin_lcd_caps *c = arg; memset(c, 0, sizeof(*c));
        c->caps = 7; c->osd_nbuf = 2; c->osd_stride = 3200; c->osd_buf_size = 3200 * 480;
    } else if (req == GOWIN_LCD_IOC_OSD) shown = ((struct gowin_lcd_osd *)arg)->buf;
    return 0;
}
int main(int argc, char **argv)
{
    if (argc < 4 || osd_init(3, 800, 480)) return 1;
    double pos = atof(argv[1]), dur = atof(argv[2]);
    osd_update(1, argv[3], pos - 1, dur);       /* two updates: the incremental path too */
    osd_update(1, argv[3], pos, dur);
    fwrite(bufs[shown], 3200, 64, stdout);
    return 0;
}
