/*
 * dsp_probe.c -- does this A25 execute Andes DSP / P-extension packed-SIMD, and
 * does it speed up a compute-bound kernel?
 *
 * The buildroot toolchain has no P support, so the instructions are emitted as
 * raw `.word` with the REAL Andes encodings (recovered from the Andes
 * riscv32-elf toolchain: the P draft v0.5 uses MAJOR OPCODE 0x7F, not the RVV
 * 0x77 -- using 0x77 is why an earlier probe SIGILL'd):
 *     add8  a0,a0,a1 = 0x48b5057f   (func7 0x24)   packed 4x int8 add
 *     add16 a0,a0,a1 = 0x40b5057f   (func7 0x20)   packed 2x int16 add
 *     smaqa a0,a1,a2 = 0xc8c5857f   (func7 0x64)   acc += signed 8x4 dot product
 * 0x7F is the >=80-bit length marker so `.insn r` can't emit it; .word + pinned
 * registers (a0/a1/a2) is required.
 *
 * Each op is run once under a SIGILL guard and self-checked vs a C reference,
 * then (if correct) benchmarked against the scalar equivalent. Also reads the
 * DSP `ucode` CSR (0x801) to confirm the datapath is present.
 *
 * Build: see tests/Makefile (plain -march=rv32imafdc).  Safe to run.
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
{ struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec*1e-9; }

/* ---- real Andes DSP ops via .word (pinned regs match the encoded rd/rs1/rs2) ---- */
static inline uint32_t i_add8(uint32_t a, uint32_t b)
{ register uint32_t x asm("a0")=a; register uint32_t y asm("a1")=b;
  __asm__ volatile(".word 0x48b5057f":"+r"(x):"r"(y)); return x; }
static inline uint32_t i_add16(uint32_t a, uint32_t b)
{ register uint32_t x asm("a0")=a; register uint32_t y asm("a1")=b;
  __asm__ volatile(".word 0x40b5057f":"+r"(x):"r"(y)); return x; }
static inline uint32_t i_smaqa(uint32_t acc, uint32_t a, uint32_t b)
{ register uint32_t r0 asm("a0")=acc; register uint32_t r1 asm("a1")=a; register uint32_t r2 asm("a2")=b;
  __asm__ volatile(".word 0xc8c5857f":"+r"(r0):"r"(r1),"r"(r2)); return r0; }

/* ---- C references ---- */
static uint32_t ref_add8(uint32_t a, uint32_t b)
{ uint32_t r=0; for(int i=0;i<4;i++) r|=(((a>>(i*8))+(b>>(i*8)))&0xff)<<(i*8); return r; }
static uint32_t ref_add16(uint32_t a, uint32_t b)
{ return (((( a>>16)+(b>>16))&0xffff)<<16) | (((a+b))&0xffff); }
static uint32_t ref_smaqa(uint32_t acc, uint32_t a, uint32_t b)
{ int32_t s=(int32_t)acc; for(int i=0;i<4;i++) s+=(int32_t)(int8_t)(a>>(i*8))*(int32_t)(int8_t)(b>>(i*8)); return (uint32_t)s; }

/* ---- extended op set: more real Andes DSP encodings (rd=a0,rs1=a0,rs2=a1) ---- */
#define DSPOP(nm, word) \
  static inline uint32_t i_##nm(uint32_t a, uint32_t b){ \
    register uint32_t x asm("a0")=a; register uint32_t y asm("a1")=b; \
    __asm__ volatile(".word " #word : "+r"(x) : "r"(y)); return x; }
DSPOP(kadd8, 0x18b5057f)  DSPOP(ukadd8,0x38b5057f)  DSPOP(sub8,  0x4ab5057f)
DSPOP(ksub8, 0x1ab5057f)  DSPOP(smin8, 0x88b5057f)  DSPOP(smax8, 0x8ab5057f)
DSPOP(umin8, 0x98b5057f)  DSPOP(umax8, 0x9ab5057f)  DSPOP(cmpeq8,0x4eb5057f)

#define B(v,i) ((v)>>((i)*8))
static uint32_t ref_kadd8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){int v=(int8_t)B(a,i)+(int8_t)B(b,i); v=v>127?127:v<-128?-128:v; r|=(uint8_t)v<<(i*8);} return r; }
static uint32_t ref_ukadd8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){int v=(uint8_t)B(a,i)+(uint8_t)B(b,i); v=v>255?255:v; r|=(uint32_t)v<<(i*8);} return r; }
static uint32_t ref_sub8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++) r|=((uint8_t)(B(a,i)-B(b,i)))<<(i*8); return r; }
static uint32_t ref_ksub8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){int v=(int8_t)B(a,i)-(int8_t)B(b,i); v=v>127?127:v<-128?-128:v; r|=(uint8_t)v<<(i*8);} return r; }
static uint32_t ref_smin8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){int8_t x=B(a,i),y=B(b,i); r|=(uint8_t)(x<y?x:y)<<(i*8);} return r; }
static uint32_t ref_smax8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){int8_t x=B(a,i),y=B(b,i); r|=(uint8_t)(x>y?x:y)<<(i*8);} return r; }
static uint32_t ref_umin8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){uint8_t x=B(a,i),y=B(b,i); r|=(uint32_t)(x<y?x:y)<<(i*8);} return r; }
static uint32_t ref_umax8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++){uint8_t x=B(a,i),y=B(b,i); r|=(uint32_t)(x>y?x:y)<<(i*8);} return r; }
static uint32_t ref_cmpeq8(uint32_t a,uint32_t b){ uint32_t r=0; for(int i=0;i<4;i++) r|=((uint8_t)B(a,i)==(uint8_t)B(b,i)?0xffu:0u)<<(i*8); return r; }

static int probe(const char *nm, uint32_t got_ok, uint32_t got, uint32_t exp)
{
	if (trapped)        { printf("  %-6s SIGILL\n", nm); return 0; }
	if (got != exp)     { printf("  %-6s WRONG (%08x, want %08x)\n", nm, got, exp); return 0; }
	(void)got_ok; printf("  %-6s OK   (got %08x)\n", nm, got); return 1;
}

static int probe_ucode(void)
{
	trapped = 0;
	if (sigsetjmp(jb,1)==0) { unsigned long u; __asm__ volatile("csrr %0,0x801":"=r"(u));
		printf("  ucode  present (0x801=0x%lx)\n", u); return 1; }
	printf("  ucode  SIGILL (no DSP datapath)\n"); return 0;
}

/* dependent-chain latency benchmarks (4 lanes / instruction) */
static void bench(const char *nm, int lanes,
                  uint32_t (*dsp)(uint32_t,uint32_t), uint32_t (*ref)(uint32_t,uint32_t))
{
	uint32_t x=0x01010101u, k=0x01010101u; long N=100000000;
	double t=now_s(); for(long i=0;i<N;i++) x=dsp(x,k); t=now_s()-t; sink^=x;
	double dcyc=t*CORE_HZ/N, dlane=(double)N*lanes/t/1e6;
	uint32_t y=0x01010101u; double t2=now_s(); for(long i=0;i<N;i++) y=ref(y,k); t2=now_s()-t2; sink^=y;
	double scyc=t2*CORE_HZ/N, slane=(double)N*lanes/t2/1e6;
	printf("  %-6s DSP %5.2f cyc/op (%6.1f Mlane/s)  scalar %5.2f cyc/op (%6.1f Mlane/s)  -> %.1fx\n",
	       nm, dcyc, dlane, scyc, slane, scyc/dcyc);
}
static void bench_smaqa(void)
{
	uint32_t a=0x01020304u, base=0x7f01ff02u; long N=100000000;
	/* vary b per-iter so the scalar dot can't be constant-folded to a closed form */
	uint32_t acc=0; double t=now_s(); for(long i=0;i<N;i++) acc=i_smaqa(acc,a,base^(uint32_t)i); t=now_s()-t; sink^=acc;
	uint32_t s=0;  double t2=now_s(); for(long i=0;i<N;i++) s=ref_smaqa(s,a,base^(uint32_t)i);  t2=now_s()-t2; sink^=s;
	printf("  SMAQA  DSP %5.2f cyc/op (%6.1f MMAC/s)  scalar %5.2f cyc/op (%6.1f MMAC/s)  -> %.1fx\n",
	       t*CORE_HZ/N, (double)N*4/t/1e6, t2*CORE_HZ/N, (double)N*4/t2/1e6, t2/t);
}

int main(void)
{
	signal(SIGILL, on_sigill);
	printf("A25 Andes-DSP / P-extension (real encodings, opcode 0x7F)\n");
	printf("[probe]\n");
	probe_ucode();
	uint32_t g;
	trapped=0; g = (sigsetjmp(jb,1)==0) ? i_add8 (0x7f010203u,0x01010101u) : 0;
	int a8  = probe("ADD8",  1, g, ref_add8 (0x7f010203u,0x01010101u));
	trapped=0; g = (sigsetjmp(jb,1)==0) ? i_add16(0x7fff0001u,0x00010002u) : 0;
	int a16 = probe("ADD16", 1, g, ref_add16(0x7fff0001u,0x00010002u));
	trapped=0; g = (sigsetjmp(jb,1)==0) ? i_smaqa(0,0x01020304u,0x01010101u) : 0;
	int sm  = probe("SMAQA", 1, g, ref_smaqa(0,0x01020304u,0x01010101u));

	printf("[bench] dependent-chain, 4 lanes/instr:\n");
	if (a8)  bench("ADD8",  4, i_add8,  ref_add8);
	if (a16) bench("ADD16", 2, i_add16, ref_add16);
	if (sm)  bench_smaqa();
	if (!(a8|a16|sm)) printf("  (no usable DSP op)\n");

	printf("[verify] more DSP ops (execute + self-check):\n");
	int ep=0, et=0;
#define EP(nm,A,B) do{ trapped=0; uint32_t g=(sigsetjmp(jb,1)==0)?i_##nm(A,B):0; \
	uint32_t e=ref_##nm(A,B); et++; \
	if(trapped)      printf("  %-7s SIGILL\n", #nm); \
	else if(g!=e)    printf("  %-7s WRONG (%08x != %08x)\n", #nm, g, e); \
	else { ep++;     printf("  %-7s OK (%08x)\n", #nm, g); } }while(0)
	EP(kadd8, 0x7f010203u, 0x7f01ff80u);   /* signed saturating add */
	EP(ukadd8,0xff010203u, 0x02ffff80u);   /* unsigned saturating add */
	EP(sub8,  0x05010203u, 0x0302ff04u);   /* packed subtract */
	EP(ksub8, 0x80010203u, 0x7fffff04u);   /* signed saturating sub */
	EP(smin8, 0x7f80017fu, 0x017f8000u);   /* signed min */
	EP(smax8, 0x7f80017fu, 0x017f8000u);   /* signed max */
	EP(umin8, 0xff000180u, 0x017fff00u);   /* unsigned min */
	EP(umax8, 0xff000180u, 0x017fff00u);   /* unsigned max */
	EP(cmpeq8,0x01ff0380u, 0x01000380u);   /* packed equal */
#undef EP
	printf("  -> %d/%d extended ops correct\n", ep, et);
	return 0;
}
