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

## Note on correctness
The soft atomics are correct **only because the system is single-hart** (the only
concurrency is traps, which SIE-disable blocks). They are NOT SMP-safe. This is a
workaround for a SoC that cannot do atomics on DRAM; the proper fix is gateware/IP
with a coherence manager (or AXI exclusive-access support).
