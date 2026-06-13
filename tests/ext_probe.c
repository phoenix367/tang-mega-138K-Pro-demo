/*
 * ext_probe.c -- probe three more extensions on the A25: Andes Performance Ext
 * (ffb/ffmism/flmism string search), Zbb (bit-manip), Zicbop (prefetch.r).
 *
 * The buildroot toolchain doesn't support them, so each is emitted as raw
 * `.word` with the real encodings (from the Andes riscv32-elf toolchain) under a
 * SIGILL guard. Zbb ops are self-checked vs C references; XAndesPerf ops are run
 * on known inputs and their results printed (to confirm execution + semantics);
 * prefetch.r is a hint (can't trap-detect) so we just confirm it runs.
 *
 *   XAndesPerf (opcode 0x5B):  nds.ffb=0x20b5055b nds.ffmism=0x24b5055b nds.flmism=0x26b5055b
 *   Zbb: clz=0x60051513 ctz=0x60151513 cpop=0x60251513 orc.b=0x28755513 rev8=0x69855513
 *        min=0x0ab54533 max=0x0ab56533 minu=0x0ab55533 maxu=0x0ab57533 andn=0x40b57533 ror=0x60b55533
 *   Zicbop: prefetch.r 0(a0)=0x00156013
 *
 * Build: see tests/Makefile (plain -march=rv32imafdc).  Safe to run.
 */
#include <stdio.h>
#include <stdint.h>
#include <setjmp.h>
#include <signal.h>

static sigjmp_buf jb;
static volatile sig_atomic_t trapped;
static void on_sigill(int s) { (void)s; trapped = 1; siglongjmp(jb, 1); }
static volatile uint32_t sink;

#define UN(nm,word)  static inline uint32_t i_##nm(uint32_t a){ \
	register uint32_t x asm("a0")=a; __asm__ volatile(".word " #word:"+r"(x)); return x; }
#define BIN(nm,word) static inline uint32_t i_##nm(uint32_t a,uint32_t b){ \
	register uint32_t x asm("a0")=a; register uint32_t y asm("a1")=b; \
	__asm__ volatile(".word " #word:"+r"(x):"r"(y)); return x; }

/* Zbb */
UN(clz,0x60051513) UN(ctz,0x60151513) UN(cpop,0x60251513) UN(orcb,0x28755513) UN(rev8,0x69855513)
BIN(min,0x0ab54533) BIN(max,0x0ab56533) BIN(minu,0x0ab55533) BIN(maxu,0x0ab57533)
BIN(andn,0x40b57533) BIN(ror,0x60b55533)
/* XAndesPerf */
BIN(ffb,0x20b5055b) BIN(ffmism,0x24b5055b) BIN(flmism,0x26b5055b)

/* Zbb references */
static uint32_t r_clz(uint32_t a){ int n=0; if(!a)return 32; while(!(a&0x80000000u)){a<<=1;n++;} return n; }
static uint32_t r_ctz(uint32_t a){ int n=0; if(!a)return 32; while(!(a&1)){a>>=1;n++;} return n; }
static uint32_t r_cpop(uint32_t a){ int n=0; while(a){n+=a&1;a>>=1;} return n; }
static uint32_t r_orcb(uint32_t a){ uint32_t r=0; for(int i=0;i<4;i++) if((a>>(i*8))&0xff) r|=0xffu<<(i*8); return r; }
static uint32_t r_rev8(uint32_t a){ return (a<<24)|((a&0xff00)<<8)|((a>>8)&0xff00)|(a>>24); }
static uint32_t r_min(uint32_t a,uint32_t b){ return (int32_t)a<(int32_t)b?a:b; }
static uint32_t r_max(uint32_t a,uint32_t b){ return (int32_t)a>(int32_t)b?a:b; }
static uint32_t r_minu(uint32_t a,uint32_t b){ return a<b?a:b; }
static uint32_t r_maxu(uint32_t a,uint32_t b){ return a>b?a:b; }
static uint32_t r_andn(uint32_t a,uint32_t b){ return a&~b; }
static uint32_t r_ror(uint32_t a,uint32_t b){ b&=31; return b?((a>>b)|(a<<(32-b))):a; }

/* XAndesPerf references (deduced from HW): result = (byte_index - 4), i.e. -4..-1
 * as a negative offset from the end of the word; 0 if equal / not found.
 * ffb searches rs1 for the byte (rs2 & 0xff); ffmism/flmism = first/last differing byte. */
static uint32_t r_ffb(uint32_t a,uint32_t b){ uint8_t k=b&0xff; for(int i=0;i<4;i++) if(((a>>(i*8))&0xff)==k) return (uint32_t)(i-4); return 0; }
static uint32_t r_ffmism(uint32_t a,uint32_t b){ for(int i=0;i<4;i++) if(((a>>(i*8))&0xff)!=((b>>(i*8))&0xff)) return (uint32_t)(i-4); return 0; }
static uint32_t r_flmism(uint32_t a,uint32_t b){ for(int i=3;i>=0;i--) if(((a>>(i*8))&0xff)!=((b>>(i*8))&0xff)) return (uint32_t)(i-4); return 0; }

int main(void)
{
	signal(SIGILL, on_sigill);
	int pass=0, tot=0;

	printf("[Zbb] (self-checked)\n");
#define ZP1(nm,A) do{ trapped=0; uint32_t g=(sigsetjmp(jb,1)==0)?i_##nm(A):0; uint32_t e=r_##nm(A); tot++; \
	if(trapped) printf("  %-5s SIGILL\n",#nm); else if(g!=e) printf("  %-5s WRONG %08x!=%08x\n",#nm,g,e); \
	else {pass++; printf("  %-5s OK (%08x)\n",#nm,g);} }while(0)
#define ZP2(nm,A,B) do{ trapped=0; uint32_t g=(sigsetjmp(jb,1)==0)?i_##nm(A,B):0; uint32_t e=r_##nm(A,B); tot++; \
	if(trapped) printf("  %-5s SIGILL\n",#nm); else if(g!=e) printf("  %-5s WRONG %08x!=%08x\n",#nm,g,e); \
	else {pass++; printf("  %-5s OK (%08x)\n",#nm,g);} }while(0)
	ZP1(clz, 0x00080000u); ZP1(ctz, 0x00080000u); ZP1(cpop, 0xf0f0f0f0u);
	ZP1(orcb,0x0010ff00u); ZP1(rev8, 0x11223344u);
	ZP2(min, 0xffffffffu, 0x00000001u); ZP2(max, 0xffffffffu, 0x00000001u);
	ZP2(minu,0xffffffffu, 0x00000001u); ZP2(maxu,0xffffffffu, 0x00000001u);
	ZP2(andn,0xff00ff00u, 0x0f0f0f0fu); ZP2(ror, 0x00000123u, 4);
	printf("  -> Zbb %d/%d correct\n", pass, tot);

	printf("[XAndesPerf] (self-checked; result = byte_index-4, 0 if none)\n");
	int xp=0, xt=0;
#define XP(nm,A,B) do{ trapped=0; uint32_t g=(sigsetjmp(jb,1)==0)?i_##nm(A,B):0; uint32_t e=r_##nm(A,B); xt++; \
	if(trapped) printf("  %-8s SIGILL\n",#nm); else if(g!=e) printf("  %-8s WRONG %08x!=%08x\n",#nm,g,e); \
	else {xp++; printf("  %-8s OK (%08x)\n",#nm,g);} }while(0)
	XP(ffmism,0x11223344u,0x112233ffu);   /* differ at byte0 -> -4 */
	XP(ffmism,0x11223344u,0xff223344u);   /* differ at byte3 -> -1 */
	XP(ffmism,0xaabbccddu,0xaabbccddu);   /* equal -> 0 */
	XP(flmism,0x11223344u,0xff2233ffu);   /* last differ byte3 -> -1 */
	XP(ffb,   0x11223344u,0x00000022u);   /* find 0x22 at byte2 -> -2 */
	XP(ffb,   0x11223344u,0x00000099u);   /* not present -> 0 */
	printf("  -> XAndesPerf %d/%d correct\n", xp, xt);

	printf("[Zicbop] prefetch.r (hint -- can't trap-detect)\n");
	trapped=0; static uint32_t buf[16];
	if(sigsetjmp(jb,1)==0){ register uint32_t *p asm("a0")=buf; __asm__ volatile(".word 0x00156013"::"r"(p):"memory");
		printf("  prefetch.r ran (no fault); effect shown by memthroughput delay test\n"); }
	else printf("  prefetch.r SIGILL (unexpected for a hint)\n");
	sink ^= buf[0];
	return 0;
}
