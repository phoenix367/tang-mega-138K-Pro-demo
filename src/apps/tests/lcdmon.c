/* lcdmon [-t max_s] [-f fps] [-w wait_s] -- which picture every LCD refresh scanned out
 * while a video plays in YUV mode (as root: /dev/mem and SCHED_FIFO).
 *
 * The LCD core (0xE8001000) increments FRAMES in the same bus cycle that takes over
 * FB_BASE for the next refresh, so FB_BASE read just before and just after a FRAMES
 * change is the buffer that refresh shows.  lcdmon sleeps until ~2 ms before the
 * expected frame end and busy-polls across it (about 2 ms of CPU per 19 ms refresh).
 * A picture = a run of refreshes with the same FB_BASE; its hold = run length.
 * Pictures the player flipped but no refresh latched = player "shown" - pictures here.
 * It waits up to wait_s for the YUV mode, stops when the player switches back to RGB
 * (or after max_s), and with -f (the stream's frame rate) lists the holds longer than
 * a frame's refreshes + 1: there the next picture came late or never came. */
#include <fcntl.h>
#include <errno.h>
#include <sched.h>
#include <sys/syscall.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define LCD_BASE 0xE8001000u
#define R_CTRL 0x00
#define R_FB 0x08
#define R_HTIM 0x10
#define R_VTIM 0x18
#define R_FRAMES 0x20
#define R_UNDER 0x24
#define PCLK_HZ 33333333.0

static volatile uint32_t *regs;
static volatile int stop;
static uint32_t rd(unsigned off) { return regs[off / 4]; }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void sleep_until(double t)
{
    struct timespec ts = { (time_t)t, (long)((t - (time_t)t) * 1e9) };
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
}
static void on_sig(int s) { (void)s; stop = 1; }

#define MAXLONG 60
int main(int argc, char **argv)
{
    double tmax = 600, fps = 0, wait_s = 60;
    int c;
    while ((c = getopt(argc, argv, "t:f:w:")) != -1) {
        if (c == 't') tmax = atof(optarg);
        else if (c == 'f') fps = atof(optarg);
        else if (c == 'w') wait_s = atof(optarg);
        else { fprintf(stderr, "usage: lcdmon [-t max_s] [-f fps] [-w wait_s]\n"); return 2; }
    }
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    regs = fd < 0 ? MAP_FAILED : mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, LCD_BASE);
    if (regs == MAP_FAILED) { perror("/dev/mem"); return 1; }
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    struct sched_param sp = { .sched_priority = 10 };
    /* musl's sched_setscheduler() is a stub (ENOSYS): the raw syscall sets this thread */
    int rt = syscall(SYS_sched_setscheduler, 0, SCHED_FIFO, &sp) == 0;
    if (!rt) fprintf(stderr, "lcdmon: SCHED_FIFO: %s\n", strerror(errno));

    uint32_t ht = rd(R_HTIM), vt = rd(R_VTIM);
    double period = (double)(ht >> 16) * (vt >> 16) / PCLK_HZ;
    /* wait for the YUV mode (the player started) */
    double t0 = now();
    while (!(rd(R_CTRL) & 4) && !stop) {
        if (now() - t0 > wait_s) { fprintf(stderr, "lcdmon: no YUV scan-out within %.0f s\n", wait_s); return 1; }
        usleep(5000);
    }
    /* sync to a frame end with a busy poll */
    uint32_t f = rd(R_FRAMES), f0, u0 = rd(R_UNDER);
    while (rd(R_FRAMES) == f && !stop) ;
    double tf = now(), tstart = tf;
    f = f0 = rd(R_FRAMES);
    uint32_t cur = rd(R_FB);                 /* the picture being shown */
    unsigned long refreshes = 1, pictures = 1, ambiguous = 0, unbracketed = 0, skipped_ref = 0;
    unsigned hold = 1, hist[8] = { 0 }, longest = 0;
    double longest_t = 0;
    struct { double t; unsigned n; } lng[MAXLONG]; unsigned nlong = 0, nlong_all = 0;
    unsigned nominal = fps > 0 ? (unsigned)(1.0 / (fps * period) + 0.999) : 0;   /* ceil(refreshes per frame) */

    while (!stop && now() - tstart < tmax) {
        sleep_until(tf + period - 0.002);
        uint32_t pre = rd(R_FB), fn = rd(R_FRAMES), post;
        int bracketed = fn == f;
        double deadline = now() + 0.006;
        while (fn == f && now() < deadline) { pre = rd(R_FB); fn = rd(R_FRAMES); }
        if (fn == f) {                       /* no frame end: the scan-out stopped */
            if (!(rd(R_CTRL) & 4)) break;
            tf = now(); continue;
        }
        post = rd(R_FB);
        tf = now();
        if (!(rd(R_CTRL) & 4)) break;        /* the player switched back to RGB */
        uint32_t d = fn - f;
        f = fn;
        if (!bracketed) unbracketed++;
        else if (pre != post) ambiguous++;
        if (d > 1) skipped_ref += d - 1;     /* refreshes we slept through: assume the same picture */
        refreshes += d;
        uint32_t b = post;
        if (b == cur) { hold += d; continue; }
        /* a new picture: book the old one's hold */
        hist[hold < 7 ? hold : 7]++;
        if (hold > longest) { longest = hold; longest_t = tf - tstart - hold * period; }
        if (nominal && hold > nominal + 1) {
            if (nlong < MAXLONG) { lng[nlong].t = tf - tstart - hold * period; lng[nlong].n = hold; nlong++; }
            nlong_all++;
        }
        hold = d; cur = b; pictures++;
    }
    hist[hold < 7 ? hold : 7]++;
    double el = tf - tstart;
    printf("LCDMON refresh %.2f ms (%.2f Hz)%s, watched %.1f s: %lu refreshes, %lu pictures (%.2f/s), underrun lines +%u\n",
           period * 1e3, 1 / period, rt ? "" : " [no SCHED_FIFO]", el, refreshes, pictures, el > 0 ? pictures / el : 0,
           rd(R_UNDER) - u0);
    printf("  hold (refreshes per picture):");
    for (int i = 1; i < 8; i++) if (hist[i]) printf(" %s%d:%u", i == 7 ? ">=" : "", i, hist[i]);
    printf("\n  longest hold %u refreshes (%.0f ms) at t=%.1f s; ambiguous %lu, unbracketed %lu, slept-through refreshes %lu\n",
           longest, longest * period * 1e3, longest_t, ambiguous, unbracketed, skipped_ref);
    if (nominal) {
        printf("  holds longer than %u refreshes (a picture late or missing after it): %u", nominal + 1, nlong_all);
        for (unsigned i = 0; i < nlong; i++) printf("%s t=%.1f:%u", i ? "," : "", lng[i].t, lng[i].n);
        printf("%s\n", nlong_all > nlong ? " ..." : "");
    }
    return 0;
}
