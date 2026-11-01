/*
 * ddr_memtest.c -- DDR3 path correctness + latency/bandwidth test (Linux userspace).
 *
 * Written to validate the AHB->DDR3 bridge (ddr_bridge/rtl/ahb_ddr3_bridge.v):
 * its line buffers, stream prefetch, write merging and write-invalidate must
 * be invisible to software, and it should cut the ~5 us L1-miss cost.
 *
 * Correctness (any mismatch is printed and counted):
 *   addr    -- every 32-bit word = its own address ^ pass seed, over the buffer,
 *              written and read back in ascending, descending and strided order
 *   mixed   -- random 8/16/32/64-bit stores and loads against a shadow copy in a
 *              region much larger than L1 (so lines are evicted / refetched /
 *              prefetched constantly while being modified)
 *   copy    -- memcpy ping-pong between two big buffers, checksummed
 * Performance:
 *   chase   -- random pointer chase over 32 B lines in a 16 MB region: ns per
 *              dependent L1 miss (the real per-transaction DDR latency)
 *   seq     -- sequential read / write / copy MB/s on a 16 MB buffer
 *
 * Usage: ddr_memtest [MB=32] [passes=1]
 * Build (static, soft-atomic musl toolchain): see tests/Makefile.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static uint32_t rng = 0x12345678u;
static uint32_t xr(void)
{
	rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
	return rng;
}

static unsigned long errors;
static void bad(const char *t, const volatile void *p, uint64_t got, uint64_t exp)
{
	if (errors < 30)
		printf("  MISMATCH %-5s @%p: got %08llx exp %08llx\n", t, (const void *)p,
		       (unsigned long long)got, (unsigned long long)exp);
	errors++;
}

static void test_addr(volatile uint32_t *b, size_t words, uint32_t seed)
{
	size_t i, s;
	for (i = 0; i < words; i++) b[i] = (uint32_t)(uintptr_t)&b[i] ^ seed;
	for (i = 0; i < words; i++)
		if (b[i] != ((uint32_t)(uintptr_t)&b[i] ^ seed)) bad("asc", &b[i], b[i], (uint32_t)(uintptr_t)&b[i] ^ seed);
	seed = ~seed;
	for (i = words; i-- > 0;) b[i] = (uint32_t)(uintptr_t)&b[i] ^ seed;
	for (i = words; i-- > 0;)
		if (b[i] != ((uint32_t)(uintptr_t)&b[i] ^ seed)) bad("desc", &b[i], b[i], (uint32_t)(uintptr_t)&b[i] ^ seed);
	/* strided: touch one word per line, many lines apart, then fill the rest */
	seed ^= 0x5a5a5a5au;
	for (s = 0; s < 8; s++)
		for (i = s; i < words; i += 8) b[i] = (uint32_t)(uintptr_t)&b[i] ^ seed;
	for (s = 8; s-- > 0;)
		for (i = s; i < words; i += 8)
			if (b[i] != ((uint32_t)(uintptr_t)&b[i] ^ seed)) bad("strd", &b[i], b[i], (uint32_t)(uintptr_t)&b[i] ^ seed);
}

static void test_mixed(volatile uint8_t *m, uint8_t *sh, size_t len, unsigned long ops)
{
	unsigned long n;
	memcpy(sh, (const void *)m, len);
	for (n = 0; n < ops; n++) {
		uint32_t r = xr();
		size_t off = (xr() % len);
		unsigned sz = 1u << (r & 3);
		off &= ~(size_t)(sz - 1);
		if (off + sz > len) continue;
		if (r & 4) {			/* store */
			uint64_t v = ((uint64_t)xr() << 32) | xr();
			switch (sz) {
			case 1: *(volatile uint8_t *)(m + off) = (uint8_t)v; break;
			case 2: *(volatile uint16_t *)(m + off) = (uint16_t)v; break;
			case 4: *(volatile uint32_t *)(m + off) = (uint32_t)v; break;
			default: *(volatile uint64_t *)(m + off) = v; break;
			}
			memcpy(sh + off, &v, sz);
		} else {			/* load + compare */
			uint64_t got = 0, exp = 0;
			switch (sz) {
			case 1: got = *(volatile uint8_t *)(m + off); break;
			case 2: got = *(volatile uint16_t *)(m + off); break;
			case 4: got = *(volatile uint32_t *)(m + off); break;
			default: got = *(volatile uint64_t *)(m + off); break;
			}
			memcpy(&exp, sh + off, sz);
			if (got != exp) bad("mixed", m + off, got, exp);
		}
	}
	for (n = 0; n < len; n++)
		if (m[n] != sh[n]) bad("mixfin", m + n, m[n], sh[n]);
}

static uint32_t csum(const uint32_t *p, size_t words)
{
	uint32_t c = 0;
	size_t i;
	for (i = 0; i < words; i++) c = (c << 5 | c >> 27) ^ p[i];
	return c;
}

static void test_copy(uint32_t *a, uint32_t *b, size_t words, int rounds)
{
	size_t i;
	uint32_t c0;
	int r;
	for (i = 0; i < words; i++) a[i] = xr();
	c0 = csum(a, words);
	for (r = 0; r < rounds; r++) {
		memcpy(b, a, words * 4);
		memset(a, 0xa5, words * 4);
		memcpy(a, b, words * 4);
		if (csum(a, words) != c0 || csum(b, words) != c0) {
			bad("copy", a, csum(a, words), c0);
			for (i = 0; i < words && errors < 30; i++)
				if (a[i] != b[i]) bad("copyw", &a[i], a[i], b[i]);
			return;
		}
	}
}

static double test_chase(uint32_t *buf, size_t lines, unsigned long steps)
{
	/* random cyclic permutation of lines; each node = first word of a 32 B line */
	uint32_t *perm = malloc(lines * sizeof(uint32_t));
	size_t i, j;
	volatile uint32_t *p;
	double t;
	unsigned long n;
	for (i = 0; i < lines; i++) perm[i] = i;
	for (i = lines - 1; i > 0; i--) {
		uint32_t t2;
		j = xr() % (i + 1);
		t2 = perm[i]; perm[i] = perm[j]; perm[j] = t2;
	}
	for (i = 0; i < lines; i++)
		buf[perm[i] * 8] = (uint32_t)(uintptr_t)&buf[perm[(i + 1) % lines] * 8];
	free(perm);
	p = (volatile uint32_t *)&buf[0];
	for (n = 0; n < 10000; n++) p = (volatile uint32_t *)(uintptr_t)*p;	/* warm TLB-ish */
	t = now_s();
	for (n = 0; n < steps; n++) p = (volatile uint32_t *)(uintptr_t)*p;
	t = now_s() - t;
	if (p == 0) printf("?");
	return t / steps * 1e9;
}

static void perf_seq(uint32_t *a, uint32_t *b, size_t bytes)
{
	size_t words = bytes / 4, i;
	volatile uint32_t *va = a;
	uint32_t s = 0;
	double t;

	t = now_s();
	for (i = 0; i < words; i += 8) s += va[i] + va[i + 4];
	t = now_s() - t;
	printf("  seq read   %7.1f MB/s  (1 load per 16 B)\n", bytes / t / 1e6);
	t = now_s();
	for (i = 0; i < words; i++) s += va[i];
	t = now_s() - t;
	printf("  seq read   %7.1f MB/s  (every word)\n", bytes / t / 1e6);
	t = now_s();
	memset(a, (int)s, bytes);
	t = now_s() - t;
	printf("  memset     %7.1f MB/s\n", bytes / t / 1e6);
	t = now_s();
	memcpy(b, a, bytes);
	t = now_s() - t;
	printf("  memcpy     %7.1f MB/s\n", bytes / t / 1e6);
}

int main(int argc, char **argv)
{
	size_t mb = argc > 1 ? strtoul(argv[1], 0, 0) : 32;
	int passes = argc > 2 ? atoi(argv[2]) : 1;
	size_t bytes = mb << 20;
	uint32_t *a = malloc(bytes), *b = malloc(bytes);
	uint8_t *sh = malloc(4 << 20);
	int p;
	double t0 = now_s();

	if (!a || !b || !sh) { printf("malloc failed\n"); return 2; }
	printf("ddr_memtest: %zu MB x2, %d pass(es)\n", mb, passes);
	for (p = 0; p < passes; p++) {
		rng = 0x9e3779b9u * (p + 1);
		printf("pass %d: addr...", p); fflush(stdout);
		test_addr(a, bytes / 4, 0x13579bdfu + p);
		printf(" mixed..."); fflush(stdout);
		test_mixed((volatile uint8_t *)b, sh, 4 << 20, 2000000);
		printf(" copy..."); fflush(stdout);
		test_copy(a, b, bytes / 4 / 2, 2);
		printf(" errors so far: %lu\n", errors);
	}
	printf("perf:\n");
	printf("  chase      %7.1f ns per dependent L1 miss (16 MB, random lines)\n",
	       test_chase(a, (16 << 20) / 32, 200000));
	printf("  chase      %7.1f ns per access (16 KB, L1-resident)\n",
	       test_chase(a, (16 << 10) / 32, 2000000));
	perf_seq(a, b, 16 << 20);
	printf("RESULT: %s (%lu errors) in %.1f s\n", errors ? "FAIL" : "PASS", errors, now_s() - t0);
	return errors ? 1 : 0;
}
