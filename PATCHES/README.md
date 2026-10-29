# Patches — RISC-V Linux on the Gowin AE350 (no-coherence A25)

These are `git diff` patches against the pristine upstream trees that make a full
Linux stack boot on the Gowin AE350, whose A25 has **no coherence manager** so
hardware atomics hang on a DRAM cache-miss. See `../CACHE_ISSUES.md` (root cause)
and `../BOOT.md` (build/flash/run + config settings).

Apply each from the root of the corresponding tree:
```
git apply 0001-opensbi-ae350-soft-atomics-and-priv110.patch     # in opensbi/
git apply 0002-linux-riscv-ae350-soft-atomics.patch             # in linux/
git apply 0003-uboot-ae350-sd-boot-and-cache.patch              # in u-boot/
git apply 0004-linux-a25-cctl-cmo.patch                         # in linux/ (after 0002; needs 0003's CCTL_SUEN)
git apply 0005-linux-a25-ptw-pagetable-writeback.patch         # in linux/ (after 0004)
git apply 0006-linux-gowin-lcdfb.patch                         # in linux/ (needs 0004's CCTL ops)
git apply 0007-linux-gowin-pt8211.patch                        # in linux/ (independent)
git apply 0008-linux-gowin-adc-hwmon.patch                     # in linux/ (independent)
```
(or `patch -p1 < <file>`). Base versions used: OpenSBI v1.8, Linux 6.12, U-Boot 2026.07-rc3.

## 0001 — OpenSBI (PLATFORM=generic)
- `lib/sbi/riscv_atomic.c`, `riscv_locks.c`, `sbi_ipi.c`: **single-hart soft atomics** —
  every RMW becomes `csrrc sstatus,SIE` → plain load/store → restore; spinlocks become
  barrier-only; the IPI `__atomic_fetch_or` becomes a soft RMW.
- `firmware/fw_base.S`: A25 priv-1.10 fixes — `CLEAR_MDT` no-op (no `mstatush`),
  skip the `.bss` boot-hart lottery (its hardware `amoswap` would hang), and a trap
  handler that doesn't touch `mstatush`/H-ext CSRs the A25 lacks.

## 0002 — Linux (rv32, kernel 6.12)
- New `arch/riscv/include/asm/soft_atomic.h` + rewrites of `cmpxchg.h`, `atomic.h`,
  `bitops.h`, `futex.h`: **single-hart soft atomics** (same SIE-disable scheme).
- **Not in the patch** (set via Kconfig — see BOOT.md): `CONFIG_SMP=n` (UP — avoids
  qspinlock), disable `RISCV_ISA_{ZAWRS,ZACAS,ZABHA}` and heavy debug
  (`DEBUG_VM_PGTABLE`/`DEBUG_SPINLOCK`/lockdep/RCU-debug), and add the static
  `/dev/console` node via a 2nd `CONFIG_INITRAMFS_SOURCE` entry
  (`linux/initramfs_nodes.list`).

## 0003 — U-Boot (ae350 rv32 XIP; loader only, uses no DRAM atomics)
- `board/andestech/ae350/sdread.c` (new) + `Makefile`: `sdinit`/`sdread`/`sdboot`/`amotest`
  commands for the `apb_sd_top` SD-SPI controller and to jump to OpenSBI (a0=0,a1=0,
  cache-flush).
- `arch/riscv/cpu/andes/cpu.c`: set `mcache_ctl` with cache **ECC/prefetch/write-around
  off** (ECC breaks DDR AMO on this gateware) but **`CCTL_SUEN` on** — the latter exposes
  the AndeStar V5 CCTL cache-control CSRs (`ucctlbeginaddr` 0x80b / `ucctlcommand` 0x80c)
  to S/U mode so the kernel can do explicit L1 cache maintenance (non-coherent DMA
  wb/inval); without it an S-mode `csrw 0x80b` traps. (Unrelated to the AMO hang, which is
  `DC_COHEN`/no-coherence-manager.) Verified on hardware: a U-mode `csrr 0x80b` no longer
  SIGILLs.
- `arch/riscv/dts/ae350_32.dts`, `ae350-u-boot.dtsi`, `include/configs/ae350.h`: DT/console/
  env adaptation (ns16550 @0xf0300020, `ENV_IS_NOWHERE`, drop the unusable atcspi200 SD node).
- **Not in the patch** (Kconfig): `CONFIG_BOOTCOMMAND="unzip 0x80200000 0 0x2000000; sdboot 0"`,
  `CONFIG_BOOTDELAY=2`.

## 0004 — Linux A25 L1 CCTL non-coherent cache ops (depends on 0003)
- `arch/riscv/mm/cmo-andes-a25.c` (new) + `Makefile`: registers
  `riscv_nonstd_cache_ops` (wback / inv / wback_inv) for the A25 via the AndeStar
  V5 **user CCTL CSRs** `ucctlbeginaddr` 0x80b / `ucctlcommand` 0x80c (commands
  L1D_VA_WB=1 / _INVAL=0 / _WBINVAL=2, 32 B line), gated on
  `of_machine_is_compatible("andestech,a25")` at `early_initcall`. Gives the
  no-coherence-manager A25 explicit L1 D-cache maintenance for **non-coherent
  streaming DMA**.
- **Requires 0003's `CCTL_SUEN`**: without it the S-mode `csrw 0x80b` traps. The
  provider does a one-shot self-check at registration (a `wback_inv` on a kmalloc
  buffer); reaching its `pr_info` proves the CCTL path works. Verified on hardware:
  `AE350 A25: registered L1 CCTL non-coherent cache ops (line=32 B, self-check OK)`.
- Build gates (already set): `CONFIG_RISCV_DMA_NONCOHERENT=y`,
  `CONFIG_RISCV_NONSTANDARD_CACHE_OPS=y`, errata/Zicbom CMO off. Note: this only
  takes effect for drivers that use **streaming DMA** (`dma_map_*`); a driver on
  `dma_alloc_coherent` (uncached) never calls these ops.

## 0005 — Linux A25 page-table writeback (needed for fast DDR; after 0004)
- New `arch/riscv/include/asm/a25-ptwb.h`; hooks in `asm/pgtable.h` (`set_pte`,
  `set_pmd`, `ptep_get_and_clear`, `ptep_set_wrprotect`), `mm/pgtable.c`
  (`ptep_test_and_clear_young`) and `asm/pgalloc.h` (`pgd_alloc`, `pmd_populate*`).
  These write every page-table store back to DRAM with a CCTL L1D_VA_WB (plus fences).
  For whole pages, the new pgd and freshly zeroed PTE tables, every line is written back.
- **Why:** the A25 hardware page-table walker reads page tables from the bus, not
  through the L1 D-cache, and nothing makes it coherent with dirty lines. The slow
  stock DDR bridge hid this. With the line-buffered `ddr_bridge/`, fork/exec
  oopsed: a new pgd was walked with stale kernel entries.
- Runtime switch `/sys/module/kernel/parameters/a25_ptwb` (default 1, boot
  `a25_ptwb=0`). Verified on HW (kernel #46): bridge MODE 0 / 0x10000 at 200 MHz and
  400 MHz run memtest + 3000 fork / 500 exec with 0 oopses. With the same kernel and
  `a25_ptwb=0`, MODE 0 oopses within seconds.

## 0006 — Linux LCD framebuffer for the gateware's video core (after 0004)
- `drivers/video/fbdev/gowin-lcdfb.c` (new) + Kconfig `FB_GOWIN_LCD` + Makefile: fbdev
  driver for the scan-out core in `../video/`, registers at 0xE8001000, DT compatible
  `"gowin,ae350-lcd"`. It sets up an RGB565 framebuffer with software rendering only,
  and runs fbcon on it. See `../video/README.md`.
- The framebuffer is `alloc_pages_exact` memory with a streaming `DMA_TO_DEVICE`
  mapping, and the driver turns the device's default `dma_coherent` off. Every change
  is written back with 0004's CCTL ops before the core reads DDR:
  - damage callbacks for fbcon / write();
  - deferred I/O for mmap() writers.
- **Not in the patch** (Kconfig): `CONFIG_FB=y`, `CONFIG_FB_GOWIN_LCD=y`,
  `CONFIG_FRAMEBUFFER_CONSOLE=y`, `CONFIG_LOGO=y` (+ `LOGO_LINUX_CLUT224`), and the
  `lcd@e8001000` node in `linux/ae350-linux.dts`.

## 0007 — Linux ALSA driver for the gateware's PT8211 audio core
- `sound/drivers/gowin-pt8211.c` (new) + Kconfig `SND_GOWIN_PT8211` + Makefile: ALSA
  platform driver for the sample-FIFO audio core in `../audio/`, registers at
  0xE8002000, DT compatible `"gowin,ae350-pt8211"`, optional `clock-frequency`.
  One playback PCM (S16_LE, stereo, 8–96 kHz).  No DMA: the interrupt handler copies
  frames from the vmalloc ALSA buffer into the core's FIFO (level-type interrupt,
  threshold), so the SoC's missing cache coherence does not matter.  See
  `../audio/README.md`.
- **Not in the patch** (Kconfig): `CONFIG_SND=y`, `CONFIG_SND_PCM=y`,
  `CONFIG_SND_GOWIN_PT8211=y`, and the `audio@e8002000` node (PLIC source 11 =
  EXT_INT[1]) in `linux/ae350-linux.dts`.

## 0008 — Linux hwmon driver for the gateware's temperature / voltage sensor core
- `drivers/hwmon/gowin-adc.c` (new) + Kconfig `SENSORS_GOWIN_ADC` + Makefile: hwmon
  driver for the sensor core in `../sensor/` (registers at 0xE8004000, DT compatible
  `"gowin,ae350-adc"`, no interrupt).  The core scans the FPGA's hard ADC blocks by
  itself; the driver exposes `temp1_input` (die temperature, m°C), `in0..in7_input`
  (ADCULC voltage buses, mV, with `_label` naming the rail and its divider) and
  `_fault` (last conversion timed out).  See `../sensor/README.md`.
- **Not in the patch** (Kconfig): `CONFIG_HWMON=y`, `CONFIG_SENSORS_GOWIN_ADC=y`, and
  the `sensor@e8004000` node in `linux/ae350-linux.dts`.

## Note on correctness
The soft atomics are correct **only because the system is single-hart** (the only
concurrency is traps, which SIE-disable blocks). They are NOT SMP-safe. This is a
workaround for a SoC that cannot do atomics on DRAM; the proper fix is gateware/IP
with a coherence manager (or AXI exclusive-access support).
