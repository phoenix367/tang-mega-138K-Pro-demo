/*
 * atomic_test.c -- userspace hardware-atomic experiment for the Gowin AE350 (A25).
 *
 * The A25 has NO coherence manager, so a hardware atomic RMW that cannot gain
 * exclusive ownership of its line cannot complete. This probes what that does
 * to a *userspace* process under Linux (vs the bare-metal whole-hart freeze).
 *
 * Inline asm is used on purpose so the binary contains REAL hardware atomics
 * (amoadd.w / lr.w / sc.w) -- the soft-atomic musl libc would otherwise hide
 * them. Verify with:  objdump -d atomic_test | grep -E 'amoadd|lr\.w|sc\.w'
 *
 * Build (static, against the soft-atomic musl toolchain):
 *   TC=~/projects/riscv32-ilp32d--musl--stable-2025.08-1
 *   $TC/bin/riscv32-buildroot-linux-musl-gcc -static -O0 \
 *       -march=rv32imafdc -mabi=ilp32d -o atomic_test atomic_test.c
 *
 * Run on the board (scp over dropbear, then):
 *   ./atomic_test hot     # amoadd.w on a freshly-written ("hot") line
 *   ./atomic_test lrsc     # bounded lr.w/sc.w loop on a cold line
 *   ./atomic_test amo      # amoadd.w on a cold (evicted) line
 *
 * OBSERVED on hardware (2026-06-11), see tests/README.md:
 *   - No SIGILL (misa = rv32imafdc, the A extension decodes).
 *   - Every mode WEDGES the process: it prints the line *before* the atomic and
 *     never the line after -- the atomic never retires. The task becomes
 *     uninterruptible (kill -9 does not reap it) and burns CPU, BUT the board
 *     stays alive (the single hart still time-slices other tasks; dmesg is
 *     clean). Cleanup needs a reboot. This is why the whole stack is soft-atomic.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define BUFSZ (256 * 1024)	/* 8x the 32 KB L1D -> a full walk evicts everything */

/* atomic add, returns the old value */
static inline uint32_t amoadd_w(volatile uint32_t *p, uint32_t v)
{
	uint32_t old;
	__asm__ volatile ("amoadd.w %0, %2, %1"
			  : "=r"(old), "+A"(*p) : "r"(v) : "memory");
	return old;
}

/* one lr.w/sc.w increment attempt; returns the sc result: 0 = stored, nonzero = failed */
static inline uint32_t lrsc_inc_try(volatile uint32_t *p)
{
	uint32_t val, sc;
	__asm__ volatile ("lr.w  %0, %1\n\t"
			  "addi  %0, %0, 1\n\t"
			  "sc.w  %2, %0, %1\n\t"
			  : "=&r"(val), "+A"(*p), "=&r"(sc) :: "memory");
	return sc;
}

/* walk a buffer much larger than L1D to flush it (no atomics here) */
static void evict(volatile uint32_t *b)
{
	for (size_t i = 0; i < BUFSZ / 4; i++)
		b[i] += 1;
}

int main(int argc, char **argv)
{
	const char *m = argc > 1 ? argv[1] : "hot";

	setvbuf(stdout, NULL, _IONBF, 0);	/* unbuffered: see prints before a wedge */

	if (!strcmp(m, "hot")) {
		volatile uint32_t hot = 100;
		printf("[hot] amoadd.w on a just-written (cached) line ... ");
		uint32_t o = amoadd_w(&hot, 1);
		printf("returned old=%u new=%u  -> completed\n", o, hot);
		return 0;
	}

	uint32_t *buf = aligned_alloc(64, BUFSZ);
	memset(buf, 0, BUFSZ);

	if (!strcmp(m, "lrsc")) {
		printf("[lrsc] 100000 lr.w/sc.w on an evicted (cold) line ...\n");
		evict(buf);
		uint32_t ok = 0, fail = 0;
		for (int t = 0; t < 100000; t++) {
			if ((t & 0x3ff) == 0)
				evict(buf);	/* keep re-cooling the line */
			if (lrsc_inc_try(&buf[0]) == 0)
				ok++;
			else
				fail++;
		}
		printf("       sc_ok=%u sc_fail=%u  -> %s\n", ok, fail,
		       ok ? "converged" : "NEVER converged (cold LR/SC failure signature)");
		return 0;
	}

	if (!strcmp(m, "amo")) {
		printf("[amo] amoadd.w on an evicted (cold) DRAM line.\n");
		evict(buf);			/* buf[0] is now cold */
		printf("      issuing cold amoadd.w NOW ...\n");
		uint32_t o = amoadd_w(&buf[0], 1);
		printf("      returned old=%u  -> completed (did NOT wedge)\n", o);
		return 0;
	}

	fprintf(stderr, "usage: %s {hot|lrsc|amo}\n", argv[0]);
	return 2;
}
