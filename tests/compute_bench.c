/*
 * compute_bench.c -- A25 core compute throughput (register/L1-resident, no DDR).
 *
 * Characterizes the 800 MHz Andes A25 (RV32IMAFDC) integer ALU + FPU rates
 * INDEPENDENT of the ~6 MB/s memory bottleneck: every loop works on registers,
 * so it measures the core. Uses 8 independent dependency chains where useful so
 * a single-issue in-order core stays busy (latency hidden -> shows throughput);
 * one test keeps a single chain to expose FMA latency.
 *
 * Build (static, soft-atomic musl toolchain):
 *   TC=~/projects/riscv32-ilp32d--musl--stable-2025.08-1
 *   $TC/bin/riscv32-buildroot-linux-musl-gcc -static -O2 -march=rv32imafdc \
 *       -mabi=ilp32d -fno-math-errno -ffp-contract=fast -o compute_bench compute_bench.c -lm
 *
 * Safe to run (no atomics, no large memory): ./compute_bench
 */
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <math.h>

#define CORE_HZ 800.0e6

static volatile uint32_t isink;
static volatile double   dsink;
static volatile float    fsink;

/* runtime-seeded coefficients (volatile) so the optimizer can't constant-fold or
 * close-form the recurrences. Read once into registers before each loop. */
static volatile uint32_t g_iC = 1664525u, g_iK = 1013904223u;
static volatile double   g_dC = 1.00000001, g_dK = 0.00000003;
static volatile double   g_dCl = 0.9999999, g_dKl = 1e-9;	/* latency chain (converges) */
static volatile float    g_fC = 0.9999f,    g_fK = 0.5f;	/* C<1 -> bounded */

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void rpt(const char *name, double ops, double s, const char *unit)
{
	printf("%-26s %9.1f M%-4s/s  %6.2f /cyc  (%.2fs)\n",
	       name, ops / s / 1e6, unit, ops / s / CORE_HZ, s);
}

static void int_muladd(void)
{
	uint32_t x0=1,x1=2,x2=3,x3=4,x4=5,x5=6,x6=7,x7=8;
	const uint32_t C = g_iC, K = g_iK;
	long N = 50000000;
	double t = now_s();
	for (long i = 0; i < N; i++) {
		x0=x0*C+K; x1=x1*C+K; x2=x2*C+K; x3=x3*C+K;
		x4=x4*C+K; x5=x5*C+K; x6=x6*C+K; x7=x7*C+K;
	}
	t = now_s() - t; isink = x0^x1^x2^x3^x4^x5^x6^x7;
	rpt("int32 mul+add", (double)N * 16, t, "op");
}

static void int_div(void)
{
	uint32_t a = 0; long N = 20000000;
	double t = now_s();
	for (long i = 0; i < N; i++) a += 0xDEADBEEFu / ((uint32_t)i | 1u);
	t = now_s() - t; isink = a;
	rpt("int32 divide", (double)N, t, "div");
}

static void dbl_muladd(void)
{
	double x0=1,x1=2,x2=3,x3=4,x4=5,x5=6,x6=7,x7=8;
	const double C = g_dC, K = g_dK;
	long N = 50000000;
	double t = now_s();
	for (long i = 0; i < N; i++) {
		x0=x0*C+K; x1=x1*C+K; x2=x2*C+K; x3=x3*C+K;
		x4=x4*C+K; x5=x5*C+K; x6=x6*C+K; x7=x7*C+K;
	}
	t = now_s() - t; dsink = x0+x1+x2+x3+x4+x5+x6+x7;
	rpt("double mul+add (FLOP)", (double)N * 16, t, "flop");
}

static void flt_muladd(void)
{
	float x0=1,x1=2,x2=3,x3=4,x4=5,x5=6,x6=7,x7=8;
	const float C = g_fC, K = g_fK;
	long N = 50000000;
	double t = now_s();
	for (long i = 0; i < N; i++) {
		x0=x0*C+K; x1=x1*C+K; x2=x2*C+K; x3=x3*C+K;
		x4=x4*C+K; x5=x5*C+K; x6=x6*C+K; x7=x7*C+K;
	}
	t = now_s() - t; fsink = x0+x1+x2+x3+x4+x5+x6+x7;
	rpt("float  mul+add (FLOP)", (double)N * 16, t, "flop");
}

static void dbl_div(void)
{
	double a = 0; long N = 10000000;
	double t = now_s();
	for (long i = 0; i < N; i++) a += 1.0 / ((double)i + 1.0);
	t = now_s() - t; dsink = a;
	rpt("double divide", (double)N, t, "div");
}

static void dbl_sqrt(void)
{
	double a = 0; long N = 10000000;
	double t = now_s();
	for (long i = 0; i < N; i++) a += sqrt((double)i + 1.0);
	t = now_s() - t; dsink = a;
	rpt("double sqrt", (double)N, t, "sqrt");
}

static void dbl_fma_latency(void)
{
	double x = 1.0; const double C = g_dCl, K = g_dKl;
	long N = 50000000;
	double t = now_s();
	for (long i = 0; i < N; i++) x = x * C + K;	/* dependent: 1 result per latency */
	t = now_s() - t; dsink = x;
	printf("%-26s %6.2f cyc/op  (dependent fmadd latency)\n",
	       "double FMA latency", t * CORE_HZ / N);
}

/* realistic branchy FP kernel: Mandelbrot escape iterations, register-resident */
static void mandelbrot(void)
{
	int W = 256, H = 256, maxit = 256;
	long it_total = 0;
	double t = now_s();
	for (int py = 0; py < H; py++)
		for (int px = 0; px < W; px++) {
			double x0 = (px / (double)W) * 3.0 - 2.0;
			double y0 = (py / (double)H) * 2.0 - 1.0;
			double x = 0, y = 0; int it = 0;
			while (x*x + y*y <= 4.0 && it < maxit) {
				double xt = x*x - y*y + x0;
				y = 2.0*x*y + y0;
				x = xt;
				it++;
			}
			it_total += it;
		}
	t = now_s() - t; isink = (uint32_t)it_total;
	rpt("mandelbrot 256x256x256", (double)it_total, t, "iter");
	printf("   (~%.0f MFLOP/s at ~10 flop/iter)\n", (double)it_total * 10 / t / 1e6);
}

int main(void)
{
	printf("A25 compute benchmarks (RV32IMAFDC @ %.0f MHz, register-resident)\n",
	       CORE_HZ / 1e6);
	int_muladd();
	int_div();
	flt_muladd();
	dbl_muladd();
	dbl_div();
	dbl_sqrt();
	dbl_fma_latency();
	mandelbrot();
	return 0;
}
