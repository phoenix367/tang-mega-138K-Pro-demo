/*
 * dsp_probe.c -- does this A25 actually execute Andes DSP / RISC-V P-extension
 * (packed-SIMD) instructions from userspace, and do they speed anything up?
 *
 * The core reports EDSP present (mmsc_cfg bit 29), but the buildroot toolchain
 * has NO P-extension support (no -march, no mnemonics), so we emit the raw
 * encodings with `.insn r opcode,func3,func7,rd,rs1,rs2` (the assembler places
 * registers; no -march needed). Encodings are the older Andes DSP draft that the
 * A25's EDSP implements (major opcode 0x77, same as RVV):
 *     ADD8   func7=0x24 func3=0   (verified vs MATCH_ADD8=0x48000077)
 *     ADD16  func7=0x20 func3=0   (reconstructed)
 *     SMAQA  func7=0x64 func3=0   (EXPERIMENTAL: signed 8x4 multiply-accumulate)
 *
 * Each instruction is run once under a SIGILL guard and self-checked against a C
 * reference, so the outcome is unambiguous: OK (executes + correct) / WRONG
 * (executes, bad encoding) / SIGILL (not implemented / not enabled / wrong op).
 * Only instructions that pass the self-check are benchmarked.
 *
 * Build:  see tests/Makefile (plain -march=rv32imafdc; .insn needs no P support)
 * Safe to run.
 */
#include <stdio.h>
#include <stdint.h>
#include <setjmp.h>
#include <signal.h>
#include <time.h>

#define CORE_HZ 800.0e6
static volatile uint32_t sink;
static sigjmp_buf jb;
static volatile sig_atomic_t trapped;
static void on_sigill(int s) { (void)s; trapped = 1; siglongjmp(jb, 1); }

static double now_s(void)
{
	struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

/* ---- raw Andes-DSP instruction wrappers (opcode 0x77) ---- */
static inline uint32_t i_add8(uint32_t a, uint32_t b)
{ uint32_t d; __asm__ volatile(".insn r 0x77,0x0,0x24,%0,%1,%2":"=r"(d):"r"(a),"r"(b)); return d; }
static inline uint32_t i_add16(uint32_t a, uint32_t b)
{ uint32_t d; __asm__ volatile(".insn r 0x77,0x0,0x20,%0,%1,%2":"=r"(d):"r"(a),"r"(b)); return d; }
static inline uint32_t i_smaqa(uint32_t acc, uint32_t a, uint32_t b)
{ __asm__ volatile(".insn r 0x77,0x0,0x64,%0,%1,%2":"+r"(acc):"r"(a),"r"(b)); return acc; }

/* ---- C references for self-check ---- */
static uint32_t ref_add8(uint32_t a, uint32_t b)
{
	uint32_t r = 0;
	for (int i = 0; i < 4; i++)
		r |= (((a >> (i*8)) + (b >> (i*8))) & 0xff) << (i*8);
	return r;
}
static uint32_t ref_add16(uint32_t a, uint32_t b)
{
	uint32_t lo = (a + b) & 0xffff;
	uint32_t hi = ((a >> 16) + (b >> 16)) & 0xffff;
	return (hi << 16) | lo;
}
static uint32_t ref_smaqa(uint32_t acc, uint32_t a, uint32_t b)
{
	int32_t s = (int32_t)acc;
	for (int i = 0; i < 4; i++)
		s += (int32_t)(int8_t)(a >> (i*8)) * (int32_t)(int8_t)(b >> (i*8));
	return (uint32_t)s;
}

static int probe_add8(void)
{
	trapped = 0;
	if (sigsetjmp(jb, 1) == 0) {
		uint32_t g = i_add8(0x7f010203u, 0x01010101u), e = ref_add8(0x7f010203u, 0x01010101u);
		if (g == e) { printf("  ADD8   OK    (7f010203 +8 01010101 = %08x)\n", g); return 1; }
		printf("  ADD8   WRONG (%08x, want %08x) -- encoding off\n", g, e); return 0;
	}
	printf("  ADD8   SIGILL -- not implemented / not enabled\n"); return 0;
}
static int probe_add16(void)
{
	trapped = 0;
	if (sigsetjmp(jb, 1) == 0) {
		uint32_t g = i_add16(0x7fff0001u, 0x00010002u), e = ref_add16(0x7fff0001u, 0x00010002u);
		if (g == e) { printf("  ADD16  OK    (= %08x)\n", g); return 1; }
		printf("  ADD16  WRONG (%08x, want %08x) -- encoding off\n", g, e); return 0;
	}
	printf("  ADD16  SIGILL -- not implemented / wrong encoding\n"); return 0;
}
static int probe_smaqa(void)
{
	trapped = 0;
	if (sigsetjmp(jb, 1) == 0) {
		uint32_t g = i_smaqa(0, 0x01020304u, 0x01010101u), e = ref_smaqa(0, 0x01020304u, 0x01010101u);
		if (g == e) { printf("  SMAQA  OK    (dot = %u, want %u)\n", g, e); return 1; }
		printf("  SMAQA  WRONG (%u, want %u) -- encoding unverified\n", g, e); return 0;
	}
	printf("  SMAQA  SIGILL -- not implemented / wrong encoding\n"); return 0;
}

/* throughput: 8 independent chains. ADD8 = 4 byte-lane adds/instr. */
static void bench_add8(void)
{
	uint32_t x0=1,x1=2,x2=3,x3=4,x4=5,x5=6,x6=7,x7=8, k=0x01010101u;
	long N = 50000000;
	double t = now_s();
	for (long i = 0; i < N; i++) {
		x0=i_add8(x0,k); x1=i_add8(x1,k); x2=i_add8(x2,k); x3=i_add8(x3,k);
		x4=i_add8(x4,k); x5=i_add8(x5,k); x6=i_add8(x6,k); x7=i_add8(x7,k);
	}
	t = now_s() - t; sink = x0^x1^x2^x3^x4^x5^x6^x7;
	double instr = (double)N * 8;
	printf("  ADD8     %7.1f Minstr/s  %5.2f /cyc  -> %7.1f Mlane-add/s\n",
	       instr/t/1e6, instr/t/CORE_HZ, instr*4/t/1e6);
}
/* scalar emulation of the same packed byte-add (what you'd do without the DSP) */
static void bench_add8_scalar(void)
{
	uint32_t x0=1,x1=2,x2=3,x3=4,x4=5,x5=6,x6=7,x7=8, k=0x01010101u;
	long N = 50000000;
	double t = now_s();
	for (long i = 0; i < N; i++) {
		x0=ref_add8(x0,k); x1=ref_add8(x1,k); x2=ref_add8(x2,k); x3=ref_add8(x3,k);
		x4=ref_add8(x4,k); x5=ref_add8(x5,k); x6=ref_add8(x6,k); x7=ref_add8(x7,k);
	}
	t = now_s() - t; sink = x0^x1^x2^x3^x4^x5^x6^x7;
	printf("  scalar   %7.1f Mpackadd/s (4-byte add emulated in plain RV32)\n",
	       (double)N*8/t/1e6);
}

/* Read the Andes DSP saturation CSR `ucode` (0x801). It exists iff the DSP
 * datapath is implemented -> distinguishes "wrong encoding" (ucode readable)
 * from "no DSP datapath" (ucode traps). It is NOT an enable bit. */
static int probe_ucode(void)
{
	trapped = 0;
	if (sigsetjmp(jb, 1) == 0) {
		unsigned long u;
		__asm__ volatile("csrr %0, 0x801" : "=r"(u));
		printf("  ucode(0x801) READABLE (=0x%lx) -> DSP state present; ADD8 SIGILL = encoding mismatch\n", u);
		return 1;
	}
	printf("  ucode(0x801) SIGILL -> no DSP datapath in this config (enable bit would not help)\n");
	return 0;
}

int main(void)
{
	signal(SIGILL, on_sigill);
	printf("A25 Andes-DSP / P-extension probe (raw .insn, opcode 0x77)\n");
	printf("[probe] DSP state CSR + execute/self-check each instruction:\n");
	probe_ucode();
	int a8 = probe_add8();
	probe_add16();
	probe_smaqa();

	if (a8) {
		printf("[bench] packed 8-bit add throughput vs scalar emulation:\n");
		bench_add8();
		bench_add8_scalar();
	} else {
		printf("[bench] skipped (ADD8 not usable)\n");
	}
	return 0;
}
