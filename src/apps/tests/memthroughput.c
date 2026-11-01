/*
 * memthroughput.c -- memory read/write/copy bandwidth vs working-set ("chunk") size.
 *
 * Reveals the Gowin AE350 A25 cache cliff: chunks that fit the 32 KB L1 D-cache
 * stay "hot" (hundreds of MB/s), larger chunks fall to the DDR3-path ceiling
 * (~6 MB/s, ~5 us per 32 B line). Note the copy test uses TWO buffers, so its
 * cliff appears at ~half the chunk size of read/write.
 *
 * Loads/stores go through volatile pointers so the compiler can't hoist or
 * elide them -- every access is real memory traffic. Timed with CLOCK_MONOTONIC
 * (backed by the 50 MHz PLMT mtime, 20 ns granularity).
 *
 * Build (static, soft-atomic musl toolchain):
 *   TC=~/projects/riscv32-ilp32d--musl--stable-2025.08-1
 *   $TC/bin/riscv32-buildroot-linux-musl-gcc -static -O2 \
 *       -march=rv32imafdc_zicbop -mabi=ilp32d -o memthroughput memthroughput.c
 *   (zicbop makes __builtin_prefetch emit prefetch.r; harmless hint if HW lacks it)
 *
 * Safe to run (no atomics): ./memthroughput
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static volatile uint32_t sink, sink2;

#define LINE 32u		/* L1 cache line */
#define PFW  (LINE / 4)		/* uint32 words per line = 8 */

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static const char *human(size_t b)
{
	static char s[16];
	if (b >= (1u << 20)) snprintf(s, sizeof s, "%zuM", b >> 20);
	else                 snprintf(s, sizeof s, "%zuK", b >> 10);
	return s;
}

/* baseline sequential read-sum */
static uint32_t rd_base(volatile uint32_t *a, size_t n, size_t passes)
{
	uint32_t acc = 0;
	for (size_t p = 0; p < passes; p++)
		for (size_t i = 0; i < n; i++) acc += a[i];
	return acc;
}

/* read-sum with software prefetch `dist` cache lines ahead (Zicbop prefetch.r
 * via __builtin_prefetch; a no-op hint on hardware without Zicbop) */
static uint32_t rd_builtin(volatile uint32_t *a, size_t n, size_t passes, size_t dist)
{
	uint32_t acc = 0;
	size_t pf = dist * PFW;
	for (size_t p = 0; p < passes; p++)
		for (size_t i = 0; i < n; i++) {
			if (i + pf < n) __builtin_prefetch((const void *)&a[i + pf], 0, 0);
			acc += a[i];
		}
	return acc;
}

/* read-sum with a manual "prefetch" = a real dummy load `dist` lines ahead
 * (works on any hardware; tests whether ahead-loads overlap in the cache) */
static uint32_t rd_loadahead(volatile uint32_t *a, size_t n, size_t passes, size_t dist)
{
	uint32_t acc = 0, pf = 0;
	size_t d = dist * PFW;
	for (size_t p = 0; p < passes; p++)
		for (size_t i = 0; i < n; i++) {
			if (i + d < n) pf += a[i + d];
			acc += a[i];
		}
	sink2 = pf;
	return acc;
}

static void bench_prefetch(void)
{
	size_t sz = 4u << 20, n = sz / 4, passes = 2;	/* 4 MB: DDR-bound */
	volatile uint32_t *a = malloc(sz);
	if (!a) return;
	for (size_t i = 0; i < n; i++) a[i] = (uint32_t)i;
	double tot = (double)passes * sz, t0, t;
	static const size_t dists[] = { 1, 2, 4, 8, 16, 32 };

	printf("\nsoftware prefetch (%s buffer, DDR-bound, sequential read):\n", human(sz));
	printf("%-12s %5s %11s\n", "method", "dist", "read MB/s");

	t0 = now_s(); sink = rd_base(a, n, passes); t = now_s() - t0;
	printf("%-12s %5d %11.1f\n", "baseline", 0, tot / t / 1e6);

	for (unsigned j = 0; j < sizeof dists / sizeof dists[0]; j++) {
		t0 = now_s(); sink = rd_builtin(a, n, passes, dists[j]); t = now_s() - t0;
		printf("%-12s %5zu %11.1f\n", "builtin-pf", dists[j], tot / t / 1e6);
	}
	for (unsigned j = 0; j < sizeof dists / sizeof dists[0]; j++) {
		t0 = now_s(); sink = rd_loadahead(a, n, passes, dists[j]); t = now_s() - t0;
		printf("%-12s %5zu %11.1f\n", "load-ahead", dists[j], tot / t / 1e6);
	}
	free((void *)a);
}

/* pure-compute, memory-free busy delay (LCG); `w` iters ~ a few cycles each */
static uint32_t busyW(uint32_t x, int w)
{
	while (w-- > 0) x = x * 1664525u + 1013904223u;
	return x;
}

/* One delay-loop run. mode: 0 = no prefetch, 1 = builtin prefetch.r 1 step
 * ahead, 2 = manual load-ahead 1 step ahead. Each consumed line is a cold miss
 * (16 KB step -> set conflict); the busy delay between consumptions is the
 * window a prefetch can fill in. Returns the number of line-accesses. */
static double run_delay(volatile uint32_t *a, size_t step_w, size_t lines,
			int passes, int W, int mode)
{
	uint32_t acc = 0, j = 0x9e3779b9u, pf = 0;
	for (int p = 0; p < passes; p++)
		for (size_t i = 0; i < lines; i++) {
			if (mode == 1 && i + 1 < lines)
				__builtin_prefetch((const void *)&a[(i + 1) * step_w], 0, 0);
			else if (mode == 2 && i + 1 < lines)
				pf += a[(i + 1) * step_w];
			j = busyW(j, W);		/* overlap window */
			acc += a[i * step_w];		/* consume (was it prefetched in time?) */
		}
	sink = acc; sink2 = j + pf;
	return (double)passes * lines;
}

/* Sweep the delay so the prefetch has time to fill: if prefetch works at all,
 * the cold-miss latency gets hidden behind the compute delay (pf < nopf).
 *   step_b large (e.g. 16 KB) -> a new page each access -> TLB miss + page walk.
 *   step_b small + span <= TLB coverage -> same-page, cold DATA misses only.
 * Comparing the two isolates the page-walk component from the raw data-fill. */
static void prefetch_delay_sweep(const char *label, size_t step_b, size_t lines, int passes)
{
	size_t step_w = step_b / 4;
	size_t sz = (lines + 2) * step_w * 4;
	volatile uint32_t *a = malloc(sz);
	if (!a) { printf("%s: alloc failed\n", label); return; }
	for (size_t i = 0; i < sz / 4; i++) a[i] = (uint32_t)i;
	static const int Ws[] = { 0, 300, 1000, 3000, 10000 };

	printf("\n%s\n  (step=%zuB, span=%s, %zu lines x %d passes) -- us per line:\n",
	       label, step_b, human(sz), lines, passes);
	printf("%9s %10s %12s %12s %10s\n", "delay W", "nopf", "builtin-pf", "load-ahead", "hidden");
	for (unsigned k = 0; k < sizeof Ws / sizeof Ws[0]; k++) {
		int W = Ws[k];
		double t0, n;
		t0 = now_s(); n = run_delay(a, step_w, lines, passes, W, 0); double tn = (now_s() - t0) / n * 1e6;
		t0 = now_s();     run_delay(a, step_w, lines, passes, W, 1); double tb = (now_s() - t0) / n * 1e6;
		t0 = now_s();     run_delay(a, step_w, lines, passes, W, 2); double tl = (now_s() - t0) / n * 1e6;
		printf("%9d %10.2f %12.2f %12.2f %10.2f\n", W, tn, tb, tl, tn - (tb < tl ? tb : tl));
	}
	free((void *)a);
}

static void bench_prefetch_delay(void)
{
	/* page-walk + data-fill: 16 KB step crosses a page every access */
	prefetch_delay_sweep("prefetch+delay, 16 KB step (TLB miss + page walk each access)",
			     16u << 10, 128, 32);
	/* data-fill only: 64 B step over a 128 KB span (32 pages, TLB-resident) ->
	 * cold cache-line misses but no per-access page walk */
	prefetch_delay_sweep("prefetch+delay, 64 B step, same-page (data-fill only, no page walk)",
			     64, 2048, 4);
}

int main(void)
{
	static const size_t sizes[] = {
		1u<<10, 2u<<10, 4u<<10, 8u<<10, 16u<<10, 24u<<10, 32u<<10,
		48u<<10, 64u<<10, 128u<<10, 256u<<10, 512u<<10, 1u<<20, 4u<<20, 16u<<20
	};
	const size_t MIN_TOTAL = 4u << 20;	/* touch >= 4 MB per measurement */

	setvbuf(stdout, NULL, _IONBF, 0);
	printf("AE350 A25 memory throughput (L1D = 32 KB, DDR3 path)\n");
	printf("%-7s %7s %11s %11s %11s\n", "chunk", "passes", "read MB/s", "write MB/s", "copy MB/s");

	for (unsigned k = 0; k < sizeof sizes / sizeof sizes[0]; k++) {
		size_t sz = sizes[k], n = sz / 4;
		size_t passes = MIN_TOTAL / sz;
		if (!passes) passes = 1;

		volatile uint32_t *a = malloc(sz);
		volatile uint32_t *b = malloc(sz);
		if (!a || !b) { printf("%-7s alloc failed\n", human(sz)); break; }
		for (size_t i = 0; i < n; i++) { a[i] = (uint32_t)i; b[i] = 0; }	/* fault in */

		double t0 = now_s();
		uint32_t acc = 0;
		for (size_t p = 0; p < passes; p++)
			for (size_t i = 0; i < n; i++) acc += a[i];
		double tr = now_s() - t0; sink = acc;

		t0 = now_s();
		for (size_t p = 0; p < passes; p++)
			for (size_t i = 0; i < n; i++) a[i] = (uint32_t)(i + p);
		double tw = now_s() - t0;

		t0 = now_s();
		for (size_t p = 0; p < passes; p++)
			for (size_t i = 0; i < n; i++) b[i] = a[i];
		double tc = now_s() - t0; sink += b[n - 1];

		double tot = (double)passes * sz;
		printf("%-7s %7zu %11.1f %11.1f %11.1f\n", human(sz), passes,
		       tot / tr / 1e6, tot / tw / 1e6, tot / tc / 1e6);
		free((void *)a);
		free((void *)b);
	}
	printf("(copy MB/s = bytes copied/s; bus traffic ~2x. all accesses volatile.)\n");

	bench_prefetch();
	bench_prefetch_delay();
	return 0;
}
