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
#include "cache.h"
#include "gw_eth_dma.h"
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

/* ---- gw_eth_dma bare-metal self-test ------------------------------------ *
 * Validates the DMA gateware (CSR, MDIO, and the full TX->MAC->PHY-loopback->RX
 * datapath) plus the non-coherent cache recipe, before handing off to Linux.   */
/* DMA rings at a high, unambiguous DRAM address (the linker's low .bss address
 * 0x800 may not map to DRAM through the EXTM master). DRAM is >=128 MB here
 * (the firmware stack lives at 0x08000000), so 0x04000000 is valid + free. */
#define ETH_DMA_PHYS 0x04000000u   /* DMA buffers in DRAM (64 MB in); the custom arbiter
                                    * forwards the full address, so no 0x80000000 alias */

#define ETH_PHY_ADDR 0

static void eth_busy_wait(volatile uint32_t n) { while (n--) __asm__ volatile(""); }

static uint32_t eth_mdio_read(int phy, int reg)
{
	ETH_REG(ETH_MDIO_ADDR) = ((reg & 0x1F) << 5) | (phy & 0x1F);
	ETH_REG(ETH_MDIO_CTRL) = ETH_MDIO_READ;
	uint32_t st, to = 2000000;
	do { st = ETH_REG(ETH_MDIO_ST); } while (!(st & ETH_MDIO_RVALID) && --to);
	return st & 0xFFFF;
}

static void eth_mdio_write(int phy, int reg, uint16_t val)
{
	ETH_REG(ETH_MDIO_ADDR) = ((reg & 0x1F) << 5) | (phy & 0x1F);
	ETH_REG(ETH_MDIO_WD)   = val;
	ETH_REG(ETH_MDIO_CTRL) = ETH_MDIO_WRITE;
	uint32_t to = 2000000;
	while ((ETH_REG(ETH_MDIO_ST) & ETH_MDIO_BUSY) && --to) ;
}

/* ---- frame helpers for the DMA loopback tests (real cache ops each call) ---- */
static uint32_t s_txb, s_rxb;               /* TX/RX ring pool bases (phys) */

static uint8_t eth_fbyte(unsigned seed, unsigned i)
{
	return (i < 6) ? 0xFF : (uint8_t)(seed * 5u + i * 3u + 0x11u);  /* broadcast dst + per-frame body */
}

/* build frame for cumulative index `idx` into its TX ring slot, flush to DRAM */
static void eth_tx_put(unsigned idx, unsigned len)
{
	uint32_t base = s_txb + (idx & (ETH_RING_LEN - 1)) * ETH_BUF_SIZE;
	volatile uint32_t *h = (volatile uint32_t *)(uintptr_t)base;
	uint8_t *d = (uint8_t *)(uintptr_t)(base + 4);
	unsigned i;
	h[0] = len;
	for (i = 0; i < len; i++) d[i] = eth_fbyte(idx, i);
	ae350_dma_writeback_range((unsigned long)base, ETH_BUF_SIZE);
}

/* invalidate + verify the RX frame for index `idx`: `exp_len` total bytes,
 * `data_len` checked against the seed, the remainder must be zero pad. */
static int eth_rx_get(unsigned idx, unsigned exp_len, unsigned data_len)
{
	uint32_t base = s_rxb + (idx & (ETH_RING_LEN - 1)) * ETH_BUF_SIZE;
	volatile uint32_t *h;
	uint8_t *d;
	unsigned rlen, i;
	int bad;
	ae350_dma_invalidate_range((unsigned long)base, ETH_BUF_SIZE);
	h = (volatile uint32_t *)(uintptr_t)base;
	d = (uint8_t *)(uintptr_t)(base + 4);
	rlen = h[0] & 0xFFFF;
	bad = (rlen != exp_len);
	for (i = 0; i < data_len; i++)        if (d[i] != eth_fbyte(idx, i)) bad++;
	for (i = data_len; i < exp_len; i++)  if (d[i] != 0)                 bad++;
	return bad;
}

static int eth_wait_rxhead(unsigned target)
{
	uint32_t spins = 20000000u;
	while (spins--) if ((ETH_REG(ETH_RX_HEAD) & 0xFFFF) >= target) return 1;
	return 0;
}
static void eth_wait_txhead(unsigned target)
{
	uint32_t spins = 20000000u;
	while (spins-- && (ETH_REG(ETH_TX_HEAD) & 0xFFFF) < target) ;
}
static uint64_t eth_rdcycle(void)
{
	uint32_t lo, hi, hi2;
	do { __asm__ volatile ("rdcycleh %0" : "=r"(hi));
	     __asm__ volatile ("rdcycle  %0" : "=r"(lo));
	     __asm__ volatile ("rdcycleh %0" : "=r"(hi2)); } while (hi != hi2);
	return ((uint64_t)hi << 32) | lo;
}

static int dma_selftest(void)
{
	unsigned txq = 0;
	int fail = 0, bad;
	static const unsigned vsz[8] = { 64, 60, 96, 128, 100, 72, 256, 88 };

	printf("\r\n=== gw_eth_dma self-test (CSR @ 0x%08x) ===\r\n", (unsigned)ETH_DMA_BASE);

	/* [1] CSR read/write-back: proves the EXTS slave + register block are alive. */
	ETH_REG(ETH_RX_BASE) = 0xCAFE0000u;
	ETH_REG(ETH_TX_BASE) = 0xBEEF1000u;
	{
		uint32_t a = ETH_REG(ETH_RX_BASE), b = ETH_REG(ETH_TX_BASE);
		printf(" [1] CSR  RX_BASE=%08x TX_BASE=%08x : %s\r\n", (unsigned)a, (unsigned)b,
		       (a == 0xCAFE0000u && b == 0xBEEF1000u) ? "OK" : (fail++, "FAIL"));
	}

	/* [2] MDIO: read PHY identifier registers (2,3). */
	{
		uint32_t id2 = eth_mdio_read(ETH_PHY_ADDR, 2);
		uint32_t id3 = eth_mdio_read(ETH_PHY_ADDR, 3);
		printf(" [2] MDIO PHY id = %04x.%04x : %s\r\n", (unsigned)id2, (unsigned)id3,
		       (id2 != 0 && id2 != 0xFFFF) ? "OK" : (fail++, "FAIL (no PHY?)"));
	}

	/* ring + PHY-loopback setup (shared by all loopback tests below) */
	s_rxb = ETH_DMA_PHYS;
	s_txb = ETH_DMA_PHYS + 0x10000u;
	ETH_REG(ETH_RX_BASE) = s_rxb; ETH_REG(ETH_RX_LEN) = ETH_RING_LEN; ETH_REG(ETH_RX_TAIL) = 0;
	ETH_REG(ETH_TX_BASE) = s_txb; ETH_REG(ETH_TX_LEN) = ETH_RING_LEN;
	eth_mdio_write(ETH_PHY_ADDR, 0, 0x4140);           /* BMCR: loopback + 1000M/FD, AN off */
	ETH_REG(ETH_MODE) = ETH_MODE_1000_FD;
	eth_busy_wait(8000000);                            /* let the PHY loopback settle */
	{ uint32_t bmsr = eth_mdio_read(ETH_PHY_ADDR, 1);
	  bmsr = eth_mdio_read(ETH_PHY_ADDR, 1);           /* read twice: link bit is latch-low */
	  printf(" [.] PHY BMSR=%04x link=%u\r\n", (unsigned)bmsr, (unsigned)((bmsr >> 2) & 1)); }
	ETH_REG(ETH_CTRL) = ETH_CTRL_RX_EN | ETH_CTRL_TX_EN;

	/* [3] single 64B frame: CPU -> TX ring -> MAC -> PHY loopback -> RX ring -> CPU */
	eth_tx_put(txq, 64); ETH_REG(ETH_TX_TAIL) = txq + 1;
	if (!eth_wait_rxhead(txq + 1)) {
		printf(" [3] no RX frame (PHY loopback / link down) : FAIL\r\n");
		fail++; goto cleanup;
	}
	bad = eth_rx_get(txq, 64, 64);
	printf(" [3] single 64B loopback         : %s\r\n", bad ? (fail++, "FAIL") : "PASS");
	txq++; ETH_REG(ETH_RX_TAIL) = txq;

	/* [4] stream 8 varied-size frames through the 4-deep ring -> wrap + NAPI consume */
	{ unsigned sent = 0, b; int tb = 0;
	  while (sent < 8) {
		unsigned batch = (8 - sent > ETH_RING_LEN) ? ETH_RING_LEN : (8 - sent);
		for (b = 0; b < batch; b++) eth_tx_put(txq + b, vsz[sent + b]);
		ETH_REG(ETH_TX_TAIL) = txq + batch;
		if (!eth_wait_rxhead(txq + batch)) tb++;
		for (b = 0; b < batch; b++) tb += eth_rx_get(txq + b, vsz[sent + b], vsz[sent + b]);
		ETH_REG(ETH_RX_TAIL) = txq + batch;
		txq += batch; sent += batch;
	  }
	  printf(" [4] 8 varied frames + ring wrap : %s (drop=%u)\r\n",
	         tb ? (fail++, "FAIL") : "PASS", (unsigned)(ETH_REG(ETH_RX_DROP) & 0xFFFF)); }

	/* [5] corner cases: sub-60 payload (MAC pads to 60) + full 1500B MTU */
	eth_tx_put(txq, 20); ETH_REG(ETH_TX_TAIL) = txq + 1; eth_wait_rxhead(txq + 1);
	bad = eth_rx_get(txq, 60, 20);
	printf(" [5a] 20B payload -> padded to 60: %s\r\n", bad ? (fail++, "FAIL") : "PASS");
	txq++; ETH_REG(ETH_RX_TAIL) = txq;

	eth_tx_put(txq, 1500); ETH_REG(ETH_TX_TAIL) = txq + 1;
	bad = !eth_wait_rxhead(txq + 1);
	bad += eth_rx_get(txq, 1500, 1500);
	printf(" [5b] full 1500B MTU frame        : %s\r\n", bad ? (fail++, "FAIL") : "PASS");
	txq++; ETH_REG(ETH_RX_TAIL) = txq;

	/* [6] ring-full drop: fill the ring, send RING_LEN more without consuming */
	{ unsigned h0 = ETH_REG(ETH_RX_HEAD) & 0xFFFF, d0 = ETH_REG(ETH_RX_DROP) & 0xFFFF, b, dropn;
	  int kb = 0;
	  for (b = 0; b < ETH_RING_LEN; b++) eth_tx_put(txq + b, 64);
	  ETH_REG(ETH_TX_TAIL) = txq + ETH_RING_LEN;
	  eth_wait_rxhead(h0 + ETH_RING_LEN); eth_wait_txhead(txq + ETH_RING_LEN);
	  for (b = 0; b < ETH_RING_LEN; b++) eth_tx_put(txq + ETH_RING_LEN + b, 64);
	  ETH_REG(ETH_TX_TAIL) = txq + 2 * ETH_RING_LEN;
	  eth_busy_wait(8000000);
	  dropn = (ETH_REG(ETH_RX_DROP) & 0xFFFF) - d0;
	  for (b = 0; b < ETH_RING_LEN; b++) kb += eth_rx_get(txq + b, 64, 64);
	  printf(" [6] ring-full drop              : drops=%u (exp %u) kept=%s : %s\r\n",
	         dropn, (unsigned)ETH_RING_LEN, kb ? "CORRUPT" : "intact",
	         (dropn == ETH_RING_LEN && kb == 0) ? "PASS" : (fail++, "FAIL"));
	  ETH_REG(ETH_RX_TAIL) = h0 + ETH_RING_LEN;
	  txq += 2 * ETH_RING_LEN; }

	/* [7] loopback round-trip throughput (informational; ring-depth + poll bound) */
	{ unsigned NB = 64, n, b; uint64_t c0, c1, cyc; uint32_t mbps;
	  c0 = eth_rdcycle();
	  for (n = 0; n < NB; n += ETH_RING_LEN) {
		unsigned batch = (NB - n > ETH_RING_LEN) ? ETH_RING_LEN : (NB - n);
		for (b = 0; b < batch; b++) eth_tx_put(txq + n + b, 256);
		ETH_REG(ETH_TX_TAIL) = txq + n + batch;
		eth_wait_rxhead(txq + n + batch);
		ETH_REG(ETH_RX_TAIL) = txq + n + batch;
	  }
	  c1 = eth_rdcycle(); cyc = c1 - c0;
	  mbps = cyc ? (uint32_t)(((uint64_t)NB * 256u * 8u * 800u) / cyc) : 0;
	  printf(" [7] throughput: %u x 256B in %u kcyc ~ %u Mbps (loopback+poll bound)\r\n",
	         NB, (unsigned)(cyc / 1000u), (unsigned)mbps);
	  txq += NB; }

cleanup:
	/* stop the DMA and take the PHY out of loopback so Linux boots clean */
	ETH_REG(ETH_CTRL) = 0;
	eth_mdio_write(ETH_PHY_ADDR, 0, 0x8000);           /* PHY soft reset */
	eth_busy_wait(2000000);

	printf("=== gw_eth_dma self-test %s ===\r\n\r\n", fail ? "FAILED" : "PASSED");
	return fail;
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
	dma_selftest();		/* validate the gw_eth_dma gateware before handing off */
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
