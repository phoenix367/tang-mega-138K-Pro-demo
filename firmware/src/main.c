/*
 * Test firmware for the AE350 SoC on the Tang Mega 138K Pro Dock.
 *
 * Exercises the two peripherals wired to the board's user IO:
 *   - UART2  (TX=W20, RX=Y20) : prints a banner + a periodic heartbeat.
 *   - GPIO   (LED[2:0] on GPIO 0..2, KEY[2:0] on GPIO 3..5) : runs a
 *     waterfall on the LEDs and reads back the key state.
 *
 * Build mode is XIP (see src/bsp/config/config.h): this image is burned
 * to SPI flash and executes in place from 0x80000000; .data/.bss/stack
 * live in DDR3. See firmware/README.md and the Makefile.
 */

#include "Driver_GPIO.h"
#include "ae350.h"
#include "uart.h"
#include "delay.h"
#include "config.h"
#include <stdio.h>
#include <stdint.h>

extern AE350_DRIVER_GPIO Driver_GPIO;

#define UART_BAUD        115200u	/* match OpenSBI/Linux console (DTB current-speed) */

#define LED_MASK         0x07u      /* GPIO 0..2  -> LED[2:0] */
#define KEY_MASK         0x38u      /* GPIO 3..5  -> KEY[2:0] */
#define KEY_SHIFT        3u
#define NUM_LED          3

/* No GPIO interrupts are used in this test. */
static void gpio_callback(uint32_t event)
{
	(void)event;
}

/* Read the misa CSR (0x301) and report the core's ISA, in particular whether
 * a hardware FPU (F/D extensions) is present. Proves rv32imac / soft-float. */
static void dump_misa(void)
{
	unsigned long misa;
	__asm__ volatile ("csrr %0, misa" : "=r"(misa));

	/* MXL = top 2 bits of the XLEN-wide register (ilp32 -> 32-bit here). */
	unsigned mxl = (unsigned)((misa >> (8 * sizeof(unsigned long) - 2)) & 0x3u);
	unsigned xlen = (mxl == 1) ? 32 : (mxl == 2) ? 64 : 128;

	/* Extension letters: bit i set => letter ('A' + i). */
	char exts[27];
	int n = 0;
	for (int i = 0; i < 26; i++)
		if (misa & (1u << i))
			exts[n++] = (char)('A' + i);
	exts[n] = '\0';

	unsigned has_f = (unsigned)((misa >> 5) & 1u);	/* F: single-precision */
	unsigned has_d = (unsigned)((misa >> 3) & 1u);	/* D: double-precision */

	unsigned has_v = (unsigned)((misa >> 21) & 1u);	/* V: vector */

	/* Named decode of each present misa extension bit. */
	static const struct { unsigned char bit; const char *name; } ext[] = {
		{ 8,  "I(base)"      }, { 12, "M(muldiv)"   }, { 0,  "A(atomic)" },
		{ 5,  "F(single-fp)" }, { 3,  "D(double-fp)" }, { 2,  "C(compressed)" },
		{ 1,  "B(bitmanip)"  }, { 21, "V(vector)"   }, { 13, "N(user-irq)" },
		{ 18, "S(supervisor)" }, { 20, "U(user)"    }, { 7,  "H(hypervisor)" },
		{ 4,  "E(embedded)"  }, { 23, "X(non-std/Andes)" },
	};
	unsigned i;

	printf(" misa = 0x%08x  -> RV%u%s\r\n", (unsigned)misa, xlen, exts);
	printf(" misa exts:");
	for (i = 0; i < sizeof(ext) / sizeof(ext[0]); i++)
		if (misa & (1u << ext[i].bit))
			printf(" %s", ext[i].name);
	printf("\r\n");
	printf(" FPU  : F=%u D=%u -> %s\r\n", has_f, has_d,
	       (has_f || has_d) ? "hardware FPU present" : "none (soft-float)");
	printf(" V    : %u (vector XAndes ext need V)\r\n", has_v);
}

/* Decode the mmsc_cfg feature bits (AndeStar V5 layout, per the AX45MP/UM248
 * datasheet) and report which Andes features + XAndes instruction extensions
 * this core implements. */
static void decode_mmsc(unsigned long m)
{
	static const struct { unsigned char bit; const char *name; } feat[] = {
		{ 0,  "ECC"        }, { 3,  "ECD(CoDense)" }, { 4,  "PFT(PowerBrake)" },
		{ 5,  "HSP(StackSafe)" }, { 12, "VPLIC"    }, { 13, "EV5PE(V5Perf)" },
		{ 14, "LMSLVP"     }, { 15, "PMNDS(PMU)"   }, { 16, "CCTLCSR"        },
		{ 17, "EFHW"       }, { 18, "VCCTL"        }, { 29, "EDSP(DSP/P)"    },
		{ 30, "PPMA"       },
	};
	unsigned i;

	printf(" mmsc features:");
	for (i = 0; i < sizeof(feat) / sizeof(feat[0]); i++)
		if (m & (1u << feat[i].bit))
			printf(" %s", feat[i].name);
	printf("\r\n");

	/* XAndes instruction-extension verdict (V5 ISA spec gating). */
	printf(" XAndes: Perf=%s CoDense/EXEC.IT=%s  (NewCoDense/BF16/vector: no)\r\n",
	       (m & (1u << 13)) ? "yes" : "no",	/* EV5PE  -> XAndesPerf     */
	       (m & (1u << 3))  ? "yes" : "no");	/* ECD    -> XAndesCoDense  */
}

/* Dump the Andes config CSRs that enumerate which XAndes extensions the core
 * implements. mmsc_cfg (0xFC2) / mmsc_cfg2 (0xFC3) hold the feature bits the
 * V5 ISA spec gates each extension on (ECD=CoDense/EXEC.IT, ECDV=NewCoDense,
 * BF16CVT, VDOT, VL4, VSIH, VPFH, ...). Raw values let us decode against the
 * AndeStar V5 Privileged spec. Readable here because we run in M-mode. */
static void dump_config(void)
{
	unsigned long marchid, mimpid, micm, mdcm, mmsc;
	__asm__ volatile ("csrr %0, marchid" : "=r"(marchid));
	__asm__ volatile ("csrr %0, mimpid"  : "=r"(mimpid));
	__asm__ volatile ("csrr %0, 0xfc0"   : "=r"(micm));	/* micm_cfg  */
	__asm__ volatile ("csrr %0, 0xfc1"   : "=r"(mdcm));	/* mdcm_cfg  */
	__asm__ volatile ("csrr %0, 0xfc2"   : "=r"(mmsc));	/* mmsc_cfg  */
	/* mmsc_cfg2 (0xfc3) is NOT implemented on this core (csrr -> illegal
	 * instruction), so the mmsc_cfg2-gated extensions (NewCoDense, BF16CVT,
	 * the RV32 vector gates) are absent. Don't read it - it hangs the BSP
	 * trap handler. */

	printf(" marchid=0x%08x mimpid=0x%08x\r\n", (unsigned)marchid, (unsigned)mimpid);
	printf(" micm_cfg=0x%08x mdcm_cfg=0x%08x\r\n", (unsigned)micm, (unsigned)mdcm);
	printf(" mmsc_cfg=0x%08x (mmsc_cfg2 absent)  <- XAndes feature bits\r\n",
	       (unsigned)mmsc);
	decode_mmsc(mmsc);
}

/* Run every RV32A atomic op + LR/SC at one DDR address. Each line prints
 * BEFORE issuing the next op, so a hang pinpoints exactly which op/addr fails. */
static void amo_at(unsigned long addr)
{
	volatile unsigned int *p = (volatile unsigned int *)addr;
	unsigned int old;

	printf(" --- AMO @ 0x%08x ---\r\n", (unsigned)addr);

	*p = 0x0000000a;
	__asm__ volatile ("amoswap.w %0,%2,(%1)" : "=r"(old) : "r"(p), "r"(0x100u) : "memory");
	printf("  amoswap old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x0000000a;
	__asm__ volatile ("amoadd.w %0,%2,(%1)"  : "=r"(old) : "r"(p), "r"(5u) : "memory");
	printf("  amoadd  old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x00000014;
	__asm__ volatile ("amoxor.w %0,%2,(%1)"  : "=r"(old) : "r"(p), "r"(0xffu) : "memory");
	printf("  amoxor  old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x22334455;
	__asm__ volatile ("amoand.w %0,%2,(%1)"  : "=r"(old) : "r"(p), "r"(0xffffff00u) : "memory");
	printf("  amoand  old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x22334455;
	__asm__ volatile ("amoor.w %0,%2,(%1)"   : "=r"(old) : "r"(p), "r"(0xffu) : "memory");
	printf("  amoor   old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x22334455;
	__asm__ volatile ("amomin.w %0,%2,(%1)"  : "=r"(old) : "r"(p), "r"(0x10u) : "memory");
	printf("  amomin  old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x0000000a;
	__asm__ volatile ("amomax.w %0,%2,(%1)"  : "=r"(old) : "r"(p), "r"(0x5u) : "memory");
	printf("  amomax  old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x0000000a;
	__asm__ volatile ("amominu.w %0,%2,(%1)" : "=r"(old) : "r"(p), "r"(0x5u) : "memory");
	printf("  amominu old=0x%08x now=0x%08x\r\n", old, *p);

	*p = 0x0000000a;
	__asm__ volatile ("amomaxu.w %0,%2,(%1)" : "=r"(old) : "r"(p), "r"(0x5u) : "memory");
	printf("  amomaxu old=0x%08x now=0x%08x\r\n", old, *p);

	/* LR/SC pair (sc result 0 = success) */
	*p = 0x12340000;
	{
		unsigned int v, sc;
		__asm__ volatile ("lr.w %0,(%1)"    : "=r"(v)  : "r"(p) : "memory");
		__asm__ volatile ("sc.w %0,%2,(%1)" : "=r"(sc) : "r"(p), "r"(0xabcd0000u) : "memory");
		printf("  lr/sc   lr=0x%08x sc=%u now=0x%08x\r\n", v, sc, *p);
	}
}

static void test_amo(void)
{
	unsigned long mcc, mmisc, marchid, mimpid;

	__asm__ volatile ("csrr %0, 0x7ca"   : "=r"(mcc));	/* mcache_ctl */
	__asm__ volatile ("csrr %0, 0x7d0"   : "=r"(mmisc));	/* mmisc_ctl  */
	__asm__ volatile ("csrr %0, marchid" : "=r"(marchid));
	__asm__ volatile ("csrr %0, mimpid"  : "=r"(mimpid));
	printf(" mcache_ctl=0x%08x mmisc_ctl=0x%08x marchid=0x%08x mimpid=0x%08x\r\n",
	       (unsigned)mcc, (unsigned)mmisc, (unsigned)marchid, (unsigned)mimpid);

	amo_at(0x00043000u);	/* OpenSBI coldboot_lottery addr (U-Boot hangs here) */
	amo_at(0x00100000u);	/* 1 MB   */
	amo_at(0x04000000u);	/* 64 MB  */
	amo_at(0x08000000u);	/* 128 MB (SDK atomic demo stack) */
	printf(" AMO TEST COMPLETE\r\n");
}

/*
 * Test AMO on a *cold* (cache-missing) line: store, flush the whole D-cache to
 * evict it, then AMO. If this hangs while the hot-line AMOs above pass, the A25
 * can only do AMO on cached lines on this gateware (AMO-on-miss escapes to the
 * DDR bus, which has no AMO support) - which is exactly OpenSBI's situation.
 */
extern void ae350_dcache_flush_all(void);

static void test_amo_cold(void)
{
	volatile unsigned int *p = (volatile unsigned int *)0x00200000u;
	unsigned int old = 0, tmp;

	/* [A] flush, then a normal LOAD to refill the line, then AMO (should hit).
	 * If [A] passes but [B] hangs, a plain read-allocate before the AMO is
	 * enough -> the Customized/AHB data-memory route (where the cache must
	 * read-allocate before the L1 AMO) should fix it. */
	*p = 0x000000aa;
	ae350_dcache_flush_all();
	tmp = *p;			/* volatile load -> refill line */
	(void)tmp;
	printf(" [A] flush+LOAD then amoswap (refilled, expect hit)...\r\n");
	__asm__ volatile ("amoswap.w %0,%2,(%1)" : "=r"(old) : "r"(p), "r"(0xb1u) : "memory");
	printf("     -> A OK old=0x%08x now=0x%08x\r\n", old, *p);

	/* [C] cold LR/SC (no preceding access): LR may read-allocate like a load,
	 * so LR/SC could survive a cold miss where AMO doesn't. If [C] passes,
	 * building OpenSBI+Linux with LR/SC-only atomics (no AMO) is a viable path. */
	{
		unsigned int v = 0, sc = 1;
		*p = 0x000000aa;
		ae350_dcache_flush_all();
		printf(" [C] cold LR/SC (no preceding load)...\r\n");
		__asm__ volatile ("lr.w %0,(%1)"    : "=r"(v)  : "r"(p) : "memory");
		__asm__ volatile ("sc.w %0,%2,(%1)" : "=r"(sc) : "r"(p), "r"(0xc3c3c3c3u) : "memory");
		printf("     -> C OK lr=0x%08x sc=%u now=0x%08x\r\n", v, sc, *p);
	}

	/* [D] cold LR/SC retry loop = the real atomic pattern. The first SC fails
	 * on the cold line; the retry (line now hot) succeeds. If this converges,
	 * OpenSBI/Linux built with LR/SC-only atomics (no AMO) will work here. */
	{
		unsigned int v = 0, sc = 1, tries = 0;
		*p = 0x000000aa;
		ae350_dcache_flush_all();
		printf(" [D] cold LR/SC retry loop...\r\n");
		do {
			__asm__ volatile ("lr.w %0,(%1)"    : "=r"(v)  : "r"(p) : "memory");
			__asm__ volatile ("sc.w %0,%2,(%1)" : "=r"(sc) : "r"(p), "r"(0xd4d4d4d4u) : "memory");
			tries++;
		} while (sc != 0 && tries < 20);
		printf("     -> D done tries=%u sc=%u now=0x%08x  (sc=0 & tries<20 = success)\r\n",
		       tries, sc, *p);
	}
	(void)old;
}

extern void ae350_dcache_flush_all(void);
extern void ae350_icache_invalidate_all(void);

/*
 * Use this firmware as the bootloader: copy the OpenSBI fw_payload from SPI
 * flash (0x800000 = XIP 0x80200000) down to DDR 0x0, flush caches so the
 * copied code is coherent, and jump (a0 = hartid 0, a1 = 0; OpenSBI uses its
 * embedded FDT). Runs in the bare-metal context where DDR atomics work.
 */
static void boot_opensbi(void)
{
	const volatile unsigned int *src = (const volatile unsigned int *)0x80200000u;
	volatile unsigned int *dst = (volatile unsigned int *)0x00000000u;
	unsigned int words = 0x410000u / 4u;	/* ~4.25 MB, covers the 4.2 MB payload */
	unsigned int i;
	void (*fw)(unsigned long, unsigned long);

	printf(" Loading OpenSBI 0x80200000 -> DDR 0x0 (%u KB)...\r\n",
	       (unsigned)((words * 4u) / 1024u));
	for (i = 0; i < words; i++)
		dst[i] = src[i];

	ae350_dcache_flush_all();		/* push copied code out to DDR  */
	ae350_icache_invalidate_all();		/* drop stale I-cache lines     */
	__asm__ volatile ("fence" ::: "memory");

	printf(" Jump -> OpenSBI @ 0x0 (a0=0, a1=0)\r\n\r\n");
	fw = (void (*)(unsigned long, unsigned long))0x0u;
	fw(0, 0);
	printf(" !! OpenSBI returned unexpectedly\r\n");
}

/* Re-apply the SDK __platform_init cache-enable sequence verbatim, printing
 * mcache_ctl before/after so we can see exactly which bits stick (and whether
 * the Coherence Manager bit 19 takes). NDS_MCACHE_CTL = 0x7ca. */
static void test_platform_init(void)
{
	unsigned long before, after, m;
	unsigned long setv = (1ul << 19) | (1ul << 13) | (1ul << 10) |
			     (1ul << 9)  | (1ul << 1)  | (1ul << 0);	/* 0x82603 */
	unsigned int spin = 0;

	__asm__ volatile ("csrr %0, 0x7ca" : "=r"(before));
	printf(" [INIT] mcache_ctl BEFORE         = 0x%08x\r\n", (unsigned)before);

	/* clear_csr(NDS_MCACHE_CTL, (3<<13)); set_csr(NDS_MCACHE_CTL, 0x82603); */
	__asm__ volatile ("csrc 0x7ca, %0" :: "r"(3ul << 13) : "memory");
	__asm__ volatile ("csrs 0x7ca, %0" :: "r"(setv)      : "memory");

	__asm__ volatile ("csrr %0, 0x7ca" : "=r"(after));
	printf(" [INIT] mcache_ctl AFTER 0x82603  = 0x%08x\r\n", (unsigned)after);
	printf(" [INIT] DC_COHEN(b19)=%u  DC_COHSTA(b20)=%u\r\n",
	       (unsigned)((after >> 19) & 1u), (unsigned)((after >> 20) & 1u));

	if (after & (1ul << 19)) {
		printf(" [INIT] CM reported present -> waiting for COHSTA...\r\n");
		do {
			__asm__ volatile ("csrr %0, 0x7ca" : "=r"(m));
		} while (((m >> 20) & 1u) == 0 && ++spin < 4000000u);
		printf(" [INIT] COHSTA wait done spin=%u mcache_ctl=0x%08x\r\n",
		       spin, (unsigned)m);
	} else {
		printf(" [INIT] no CM (bit19 reads 0) -> coherence not available\r\n");
	}
}

int main(void)
{
	AE350_DRIVER_GPIO *gpio = &Driver_GPIO;
	uint32_t step = 0;
	uint32_t beat = 0;

	uart_init(UART_BAUD);

	printf("\r\n");
	printf("==========================================\r\n");
	printf(" AE350 SoC test firmware - Tang Mega 138K \r\n");
	printf("==========================================\r\n");
	printf(" Core %d MHz, UART2 @ %u baud\r\n", (int)(CPUFREQ / MHz), (unsigned)UART_BAUD);
	printf(" LEDs = GPIO[2:0], KEYs = GPIO[5:3]\r\n");
	printf(" Build: %s %s\r\n", __DATE__, __TIME__);
	test_platform_init();
	dump_misa();
	dump_config();
	test_amo();
	test_amo_cold();
	printf("\r\n");
	boot_opensbi();		/* load OpenSBI (soft-atomics) from flash and jump */

	gpio->Initialize(gpio_callback);
	gpio->SetDir(LED_MASK, AE350_GPIO_DIR_OUTPUT);
	gpio->SetDir(KEY_MASK, AE350_GPIO_DIR_INPUT);

	while (1)
	{
		/* Waterfall: light exactly one LED at a time. */
		uint32_t led = (1u << (step % NUM_LED));
		gpio->Write(LED_MASK, 0);     /* all off */
		gpio->Write(led, 1);          /* this one on */

		/* Read the three keys (raw level on GPIO 3..5). */
		uint32_t keys = (gpio->Read() & KEY_MASK) >> KEY_SHIFT;

		printf("[%6u] LED%u on  KEY[2:0]=%u%u%u\r\n",
		       (unsigned)beat++,
		       (unsigned)(step % NUM_LED),
		       (unsigned)((keys >> 2) & 1u),
		       (unsigned)((keys >> 1) & 1u),
		       (unsigned)(keys & 1u));

		step++;

#ifdef CFG_CACHE_ENABLE
		simple_delay(2000);
#else
		simple_delay(20);
#endif
	}

	return 0;
}
