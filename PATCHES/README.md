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
git apply 0009-linux-gowin-fan-hwmon.patch                     # in linux/ (independent)
git apply 0010-linux-gowin-spi-mmc.patch                      # in linux/ (independent; enable CONFIG_MMC_SPI)
git apply 0011-linux-gowin-sdhost.patch                       # in linux/ (independent; native SD host, supersedes 0010 for the card)
git apply 0013-linux-gowin-idct.patch                         # in linux/ (independent)
git apply 0014-linux-a25-isa-extensions.patch                 # in linux/ (independent; needs 0015 for the names)
git apply 0015-opensbi-a25-isa-extensions.patch               # in opensbi/ (after 0001)
git apply 0016-linux-gowin-ddr-perf.patch                     # in linux/ (independent)
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
  stock DDR bridge hid this. With the line-buffered `src/rtl/ddr_bridge/`, fork/exec
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
- YUV 4:2:0 scan-out (gateware Build 68+): `include/uapi/linux/gowin-lcdfb.h` defines
  ioctls on `/dev/fb0` -- `GOWIN_LCD_IOC_YUV_INFO` (how many planar buffers the driver
  allocated, their layout and mmap offset; `yuv_buffers=` module parameter, default 6),
  `GOWIN_LCD_IOC_YUV_SHOW` (write a buffer back from the cache and point the core at it;
  the core flips at the next frame boundary), `GOWIN_LCD_IOC_RGB` (back to the RGB565
  screen, also done when the file is closed) and `GOWIN_LCD_IOC_FRAMES`. The buffers are
  mmap()ed past the RGB framebuffer as plain cached memory, so a decoder (`src/apps/vidplay`
  through FFmpeg's `get_buffer2`) writes frames straight into scan-out memory. The driver
  probes for the mode by writing the core's U-base register. Kernel #78 adds
  `GOWIN_LCD_IOC_YUV_DMA` (a buffer's DMA address for another master -- the IDCT core of
  0013 -- with flags to write the CPU's copy back and/or drop the buffer from the cache) and the `YUV_SHOW` flag
  `GOWIN_LCD_YUV_NOSYNC` (no write-back: a DMA master wrote the buffer).
- Scaler and OSD (gateware Build 71+, kernel #83): `GOWIN_LCD_IOC_CAPS` (the core's CAPS
  register: YUV / scaler / OSD; the OSD buffers' layout and mmap offset),
  `GOWIN_LCD_IOC_SCALE` (source size and window; the driver computes the 16.16 steps),
  `GOWIN_LCD_IOC_OSD` (show one of `osd_buffers`, default 2, panel-sized ARGB8888
  buffers mmap()ed after the YUV buffers, written back from the cache, in a window).
  RGB mode, and closing the file, turn both off. With the scaler the YUV buffers hold
  sources up to `yuv_max_w` x `yuv_max_h` (default 1280x768 since kernel #93 for 720p,
  1024x768 from #85): the caller lays
  out its planes and YUV_SHOW checks them for the scaler's source height.
- **Not in the patch** (Kconfig): `CONFIG_FB=y`, `CONFIG_FB_GOWIN_LCD=y`,
  `CONFIG_FRAMEBUFFER_CONSOLE=y`, `CONFIG_LOGO=y` (+ `LOGO_LINUX_CLUT224`), and the
  `lcd@e8001000` node in `linux/ae350-linux.dts`.

## 0007 — Linux ALSA driver for the gateware's PT8211 audio core
- `sound/drivers/gowin-pt8211.c` (new) + Kconfig `SND_GOWIN_PT8211` + Makefile: ALSA
  platform driver for the sample-FIFO audio core in `../audio/`, registers at
  0xE8002000, DT compatible `"gowin,ae350-pt8211"`, optional `clock-frequency`.
  One playback PCM (S16_LE, stereo, 8–96 kHz).  DMA mode (cores with CAP[0], Build 62+):
  the ALSA buffer is physically contiguous, streaming-mapped memory that the core's own
  AHB master reads as a ring; `.ack` cleans the cache over the newly committed range and
  advances DMA_LIMIT, the core interrupts per DMA_PERIOD fetched and on "FIFO empty"
  (end of stream).  PIO fallback (`pio=1`, or older cores): the interrupt handler copies
  frames from a vmalloc buffer into the FIFO.  See `../audio/README.md`.
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

## 0009 — Linux hwmon driver for the gateware's fan PWM / tachometer core
- New `drivers/hwmon/gowin-fan.c` (`SENSORS_GOWIN_FAN`, DT `"gowin,ae350-fan"`, node
  `fan0: fan@e8008000`): hwmon `gowin_fan` with `pwm1`/`pwm1_enable` (manual duty,
  0..255 over the core's PERIOD) and `fan1_input` (RPM from the one-second edge count,
  `gowin,pulses-per-rev`), `fan1_fault`. DT `gowin,pwm-inverted` for Dock rev 4071f
  (P-MOSFET supply switch), `gowin,pwm-frequency` to change the 25 kHz default.
  Gateware: `src/rtl/fan/` (Build 57+). Kernel #60.

## 0010 — Linux SPI master driver for the gateware's microSD SPI core
- New `drivers/spi/spi-gowin.c` (`SPI_GOWIN`, DT `"gowin,ae350-spi"`, node
  `spi0: spi@e8010000`): buffered, polled `spi_controller` (2 KB TX/RX buffers, CS as a
  register bit, SCK = 50 MHz / (2·(DIV+1))). The card itself is driven by the mainline
  `mmc_spi` host (`CONFIG_MMC_SPI`, DT child `mmc-spi-slot`, 25 MHz, 3.3 V, polled card
  detect) → `/dev/mmcblk0`. Gateware: the `sdspi/` core (Build 58–60; removed from the tree
  on 2026-11-01, superseded by 0011 + `src/rtl/sdhost/`). Kernel #62.

## 0011 — Linux MMC host driver for the gateware's native SD host core
- New `drivers/mmc/host/gowin-sdhost.c` (`MMC_GOWIN_SDHOST`, DT `"gowin,ae350-sdhost"`,
  node `sdhost0: mmc@e8020000`, PLIC source 12): a plain `mmc_host` — commands with
  48/136-bit responses, data via the core's 64-bit DMA through a 64 KB bounce buffer
  (streaming DMA mapping, cache ops from 0004), completion by interrupt, driver-issued
  CMD12. On the first fast read the driver tunes the clock/sampling phase (fastest of 25 MHz late, 25 MHz on-edge, 12.5 MHz, ... that passes four clean reads of block 0). Gateware: `src/rtl/sdhost/` (Build 61+). Kernel #66. The SPI route
  (0010) stays available but its core is no longer in the gateware.


## 0013 — Linux misc driver for the gateware's hardware IDCT core
- New `drivers/misc/gowin-idct.c` (`GOWIN_IDCT`, DT `"gowin,ae350-idct"`, node
  `idct0: idct@e8040000`, PLIC source 13) + `include/uapi/linux/gowin-idct.h`: `/dev/gowin-idct`,
  one opener. The driver owns the coefficient record ring (`ring_kb=`, default 2048, kernel
  pages mmap()ed cached at offset 0); `SUBMIT` writes the new ring range back from the
  D-cache (0004's ops) and sets the core's TAIL, `SETUP` programs the YUV plane addresses /
  strides / size after waiting for the core to go idle, `WAIT` sleeps on the done interrupt
  until everything submitted is in DRAM, `STATUS`/`RESET`/`INFO`. Users: `src/apps/vidplay`
  (`idct_hw.c`, FFmpeg's `idct_put` wrapped into records) and `src/apps/tests/idcttest.c`.
  Gateware: `src/rtl/idct/` (Build 69+). Kernel #78 (final form #81). The uapi header also
  defines the JPEG record macros (`GOWIN_IDCT_HDR_JPEG`, `GOWIN_IDCT_SCAN_PARAM`,
  `GOWIN_IDCT_ST_JPEG`) for the core's entropy decoder (Build 70+); the driver itself is
  unchanged by them. Since kernel #93 `INFO.max_width` (and the `SETUP` width check) is
  2048 when the core sets STATUS[9] (Build 72: 2048-pixel band lines, 720p), else 1024.

## 0014 — Linux: the A25's instruction extensions in /proc/cpuinfo, their user CSRs per task
- `asm/hwcap.h` + `kernel/cpufeature.c`: `RISCV_ISA_EXT_p` (the P packed-SIMD / DSP draft;
  Linux 6.12 has no entry for it). `asm/vendor_extensions/andes.h` + `vendor_extensions/andes.c`:
  Andes vendor extensions `xandesperf` (V5 performance: `nds.ffb`/`ffmism`/`flmism`, ...) and
  `xandescodense` (`exec.it`) next to the existing `xandespmu`; DT binding text in
  `extensions.yaml`. The kernel takes draft and vendor names only from a CPU node's
  `riscv,isa-extensions` list (not from the `riscv,isa` string), which 0015 fills in from
  `mmsc_cfg`, so `/proc/cpuinfo` reads `rv32imafdcp_zicntr_zicsr_zifencei_zihpm_zca_zcd_zcf_xandesperf_xandescodense`.
- `asm/processor.h`, `asm/switch_to.h`, `kernel/process.c`: the extensions' user CSRs become
  task state, like the FPU registers: `ucode` (0x801, the DSP overflow flag) when P is
  present on an Andes core (`riscv_andes_dsp`, decided once at boot), `uitb` (0x800, the
  `exec.it` table base) when `xandescodense` is (an alternatives-patched test). Saved and
  restored in `switch_to()`, inherited by a fork, cleared by exec. Before this, one
  process saw another's values (`src/apps/tests/ucsr_test`: 31–86 % of reads wrong).
- Needs `CONFIG_RISCV_ISA_VENDOR_EXT_ANDES=y` (set). Kernel #96.

## 0015 — OpenSBI: A25 override that reports the core's extensions
- `platform/generic/andes/a25.c` (new) + Kconfig `PLATFORM_ANDES_A25` (on in the generic
  defconfig) + `objects.mk`: a platform override for root compatible `"andestech,a25"`.
  After the generic FDT fixups it reads the M-mode `mmsc_cfg` CSR and appends `p` (EDSP,
  bit 29), `xandesperf` (EV5PE, bit 13) and `xandescodense` (ECD, bit 3) to every enabled CPU
  node's `riscv,isa-extensions` (nodes without that list are left alone), and prints
  `Andes A25 mmsc_cfg : 0x2007f039 -> p xandesperf xandescodense`. It deliberately does not
  take over the stock `andestech,ae350` override's PMU/PMA/suspend hooks (that one resets
  this SoC). The CPU node in `linux/ae350-linux.dts` lists its standard extensions in
  `riscv,isa-extensions` for this.

## 0016 — Linux sysfs driver for the gateware's DDR bus counters
- New `drivers/misc/gowin-ddr-perf.c` (`GOWIN_DDR_PERF`, DT `"gowin,ae350-ddr-perf"`, node
  `ddr-perf@f8000000`, optional `clock-frequency` = the bus clock, default 100 MHz) for
  `src/rtl/ddr_perf.v`: transfers, beats, wait states and burst/size mix of the SoC's
  data-memory AHB bus plus the DDR3 bridge's counters (prefetch, demand, MC commands).
- The 32-bit counters read consistently only while stopped, so the driver samples them
  (stop, read all 44, start; a few µs) every `interval_ms` (1 s) and on reads, and adds the
  differences into 64-bit totals (the cycle counter wraps every 43 s). It never clears the
  block on probe (a trace from before a watchdog reset survives) and notices a clear done
  behind its back (more cycles than the elapsed time allows).
- sysfs in `/sys/bus/platform/devices/f8000000.ddr-perf/`: `counters` (all, one sample,
  `name value` lines), `statistics/<name>` (one each; files read one after another are
  different samples), `clear`, `interval_ms`, `clock_hz`, `config`, `mode` (read only),
  `trace_arm`, `trace_count`, `trace` (binary, 8 bytes per bus transfer). Kernel #97.

## 0012 — musl 1.2.5 soft atomics (the rootfs toolchain's `libc.a`)
- `arch/riscv32/atomic_arch.h`: `a_cas` becomes a plain compare-and-store (no `lr.w`/`sc.w`).
  musl derives every other atomic from `a_cas`, so the whole static libc ends up with
  **0 lr/sc/amo** (246 in the stock build). Not signal-safe or SMP-safe; valid only on this
  single-hart, coherency-manager-less SoC.
- Applied to the Bootlin `riscv32-ilp32d--musl--stable-2025.08-1` toolchain: only its
  `sysroot/lib/libc.a` is replaced (stock copy kept as `libc.a.orig`; `libc.so` untouched,
  every rootfs binary is static). `scripts/build_musl_toolchain.sh` downloads the stock
  toolchain and musl, verifies checksums, applies this patch and installs a deterministic
  `libc.a` byte-identical to the one the rootfs was built with. See doc/02-build.md.
