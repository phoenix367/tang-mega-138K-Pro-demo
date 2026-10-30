/* amotrace -- bus trace around a cold-line LR/SC or AMO on the AE350.
 *   amotrace lrsc   : evict the target line, LR/SC x3 under the trace, dump
 *   amotrace amo    : arm the watchdog (SoC reset), trace, amoswap on a cold line
 *   amotrace dump   : dump the whole trace RAM (after the reboot)
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#define PERF 0xF8000000u
#define WDT  0xF0500000u
static volatile uint32_t *perf, *wdt;
static uint64_t phys_of(void *p) {
    int fd = open("/proc/self/pagemap", O_RDONLY); uint64_t e = 0;
    pread(fd, &e, 8, ((uintptr_t)p >> 12) * 8); close(fd);
    return ((e & ((1ULL << 55) - 1)) << 12) | ((uintptr_t)p & 0xFFF);
}
static volatile uint32_t *evictbuf;
static void evict(void) { volatile uint32_t s = 0; for (int i = 0; i < (2 << 20) / 4; i += 8) s += evictbuf[i]; (void)s; }
static void dump(int n) {
    for (int i = 0; i < n; i++) {
        perf[3] = i; (void)perf[3];
        uint32_t lo = perf[4], hi = perf[5];
        printf("%4d %08x ts=%04x wait=%3u %s burst=%u size=%u seq=%u pv=%u\n", i, lo, hi >> 16, (hi >> 8) & 0xFF,
               (hi >> 7) & 1 ? "W" : "R", (hi >> 4) & 7, (hi >> 2) & 3, (hi >> 1) & 1, hi & 1);
    }
}
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "lrsc";
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    perf = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, PERF);
    wdt  = mmap(0, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, WDT);
    if (!strcmp(mode, "dump")) { printf("STATUS %08x\n", perf[2]); dump(1024); return 0; }
    uint32_t *buf = mmap(0, 1 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
    evictbuf = mmap(0, 2 << 20, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
    mlock(buf, 1 << 20); mlock((void *)evictbuf, 2 << 20);
    volatile uint32_t *tgt = buf + 4096;        /* some page inside, offset 0 of a line */
    *tgt = 0x1234;
    printf("target virt %p phys %08llx (line %08llx)\n", (void *)tgt, (unsigned long long)phys_of((void *)tgt),
           (unsigned long long)(phys_of((void *)tgt) & ~0x1FULL));
    perf[1] = 2; perf[1] = 0;                   /* clear counters + trace */
    fflush(stdout);
    if (!strcmp(mode, "lrsc")) {
        uint32_t v, sc[3];
        evict();
        perf[1] = 5;                            /* EN + TRACE_ARM */
        for (int k = 0; k < 3; k++) {
            asm volatile("lr.w %0, (%2)\n\tsc.w %1, %3, (%2)" : "=&r"(v), "=&r"(sc[k]) : "r"(tgt), "r"(0x5555u + k) : "memory");
        }
        perf[1] = 0;
        printf("lr/sc results: sc=%u %u %u (0 = success), value now %08x\n", sc[0], sc[1], sc[2], *tgt);
        /* hot-line control: store then lr/sc immediately */
        *tgt = 7;
        asm volatile("lr.w %0, (%2)\n\tsc.w %1, %3, (%2)" : "=&r"(v), "=&r"(sc[0]) : "r"(tgt), "r"(9u) : "memory");
        printf("hot-line sc=%u value %08x\n", sc[0], *tgt);
        int n = perf[2] & 0xFFFF;
        printf("trace entries %d\n", n);
        dump(n);
    } else if (!strcmp(mode, "amo")) {
        uint32_t old = 0;
        printf("arming watchdog, then amoswap on the cold line\n"); fflush(stdout);
        usleep(200000);
        evict();
        perf[1] = 5;
        /* ATCWDT200: unlock, then enable with reset, longest interval */
        *(volatile uint16_t *)((char *)wdt + 0x18) = 0x5AA5;
        wdt[0x10 / 4] = (7 << 4) | (1 << 2) | (0 << 8) | (1 << 3) | (1 << 0);
        asm volatile("amoswap.w %0, %2, (%1)" : "=&r"(old) : "r"(tgt), "r"(0xABCDu) : "memory");
        perf[1] = 0;
        printf("amoswap completed?! old=%08x now=%08x\n", old, *tgt);
        int n = perf[2] & 0xFFFF;
        dump(n);
    }
    return 0;
}
