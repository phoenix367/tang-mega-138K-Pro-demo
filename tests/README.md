# Userspace diagnostics (Gowin AE350 / A25, RV32 Linux)

Small static rv32 programs that probe SoC behaviour from Linux userspace. Both
bypass libc on purpose (inline asm) so they exercise the real hardware, not the
soft-atomic musl shims.

## Build

```sh
TC=~/projects/riscv32-ilp32d--musl--stable-2025.08-1
CC=$TC/bin/riscv32-buildroot-linux-musl-gcc
$CC -static -O0 -march=rv32imafdc -mabi=ilp32d -o atomic_test    atomic_test.c
$CC -static -O2 -march=rv32imafdc -mabi=ilp32d -o memthroughput memthroughput.c
$CC -static -O2 -march=rv32imafdc -mabi=ilp32d -fno-math-errno -ffp-contract=fast \
                                                 -o compute_bench compute_bench.c -lm
$CC -static -O2 -march=rv32imafdc -mabi=ilp32d -o dsp_probe     dsp_probe.c
$CC -static -O2                                  -o cctl_probe    cctl_probe.c
# (or just: make)
# sanity: the atomic test really contains hardware atomics
$TC/bin/riscv32-buildroot-linux-musl-objdump -d atomic_test | grep -E 'amoadd|lr\.w|sc\.w'
```

## Run (copy to the board first)

```sh
scp -O atomic_test cctl_probe ae350@192.168.200.2:/tmp/
ssh ae350@192.168.200.2
  /tmp/cctl_probe              # CCTL register access (expects: "CCTL_SUEN OK ...")
  /tmp/memthroughput            # safe: read/write/copy bandwidth vs chunk size
  /tmp/compute_bench            # safe: core int/FP throughput (register-resident)
  /tmp/dsp_probe                # safe: does the A25 run Andes DSP/P-ext? (SIGILL-guarded)
  /tmp/atomic_test hot          # amoadd.w on a cached line
  /tmp/atomic_test lrsc          # bounded lr.w/sc.w on a cold line
  /tmp/atomic_test amo           # amoadd.w on a cold line
```

> WARNING: `atomic_test` wedges its own process (see below) and the wedged task
> is **not killable** (`kill -9` fails) — clearing it needs a board reboot
> (`MODE=sram scripts/gw_program.sh`). Run it only when you can reboot.

## What they showed (2026-06-11)

### cctl_probe
`csrr 0x80b` returns `0x0` without trapping → `mcache_ctl.CCTL_SUEN` is set by
U-Boot, so the S-mode kernel CCTL cache-ops provider works. (Before the U-Boot
change this SIGILL'd.)

### memthroughput — the L1-vs-DDR cliff
Sweeps the working-set ("chunk") size and reports read/write/copy MB/s. Measured
on hardware (2026-06-11):

```
chunk    passes   read MB/s  write MB/s   copy MB/s
1K         4096        86.9       377.2       213.0
2K         2048       250.3       361.9       302.0
4K         1024       274.5       379.7       256.2
8K          512       166.3       271.4        80.1
16K         256       158.0       100.4         2.7   <- copy (2 bufs = 32K) hits the wall
24K         170        21.1         5.0         2.7   <- read/write cliff
32K         128         6.2         5.0         2.7
64K          64         6.1         5.0         2.7
256K         16         5.1         4.2         1.5
1M            4         4.7         5.1         2.7
4M            1         6.2         4.8         2.7
16M           1         6.2         5.0         2.8
```

- read/write fall off at ~24-32 KB = the 32 KB L1 D-cache; copy at ~16 KB (two buffers).
- Past the cache everything pins to ~6 MB/s read / ~5 MB/s write / ~2.7 MB/s copy and
  stays flat to 16 MB -> the DDR3-path ceiling, ~100x below L1-hot. Copy is ~half of
  read because it is read + write + write-allocate (~3x traffic per byte copied).
- This is the `ae350-ddr-bandwidth-bottleneck` finding made directly visible.

`memthroughput` also sweeps **software prefetch** on a DDR-bound 4 MB read — both
Zicbop `prefetch.r` (`__builtin_prefetch`, confirmed in the disassembly) and a
manual load-ahead, at distances 1-32 cache lines:

```
method        dist   read MB/s
baseline         0         6.0
builtin-pf    1..32      6.0-6.1     (Zicbop prefetch.r: no change)
load-ahead    1..32      6.0-5.8     (manual ahead-loads: no change, slightly worse)
```

Neither helps **for pure sequential streaming** -> back-to-back data-line misses
can't overlap (the DDR path fills one line at a time), so there is no window to
hide and prefetch can't raise streaming bandwidth. That ~6 MB/s ceiling is real
for bulk sequential access (corroborates the no-effect hardware-prefetcher result).

BUT prefetch *does* work when there is something to overlap with. A second sweep
inserts a tunable compute delay between consumptions and uses a **16 KB step**
(a new sv32 page each access -> TLB miss + page walk, ~20 us/line):

```
  delay W       nopf   builtin-pf   load-ahead     hidden   (us/line)
        0      20.82         8.51         6.61      14.21
      300      16.66         6.90         6.64      10.02
     1000      23.21        14.47        12.77      10.44
     3000      43.10        39.83        32.87      10.24
    30000     302.36       347.01       293.64       8.72
```

Prefetching one step ahead drops a strided cold access from ~21 to ~6-8 us/line --
it **hides ~10-14 us/line**. A third sweep uses a **64 B step over a 128 KB span**
(TLB-resident, so cold DATA misses but no per-access page walk) to isolate the
data-fill from the page walk:

```
                            nopf   prefetched   hidden  (us/line, W=0)
  16 KB step (walk+fill)   ~18        ~7         ~12
  64 B  step (fill only)   ~10        ~5          ~5
```

So **both latencies are hideable** given an overlap window:
- raw data-fill cold miss ~5 us, hidden ~5 us (matches the documented ~5 us/line);
- page walks add ~8 us/access (18 vs 10) and are *also* hidden (~7 us more).
- (the same-page nopf ~10 us > the ~5.3 us of pure *sequential* streaming because a
  64 B stride defeats the HW prefetcher -> closer to the true unaided miss latency.)

**Refined bottom line:** the memory system overlaps ONE outstanding prefetch (data
fill *and* page walk) with compute -- it is NOT one-transaction-serial. The ~6 MB/s
ceiling is specifically the **pure-streaming, zero-compute** case (a tight copy/scan
has nothing to overlap the single in-flight fill with). A workload that interleaves
real compute hides much of the latency; only a gateware fix (multiple-outstanding /
bursting DDR path) lifts the *streaming* ceiling itself.

### compute_bench — the core is NOT the bottleneck
Register/L1-resident int + FP rates (no DDR). Measured on hardware (2026-06-13):

```
int32 mul+add            426 Mop/s   (0.53/cyc; mul ~3 cyc throughput)
int32 divide              29 Mdiv/s  (~27 cyc, iterative)
float  mul+add           816 Mflop/s (1.02/cyc)
double mul+add           823 Mflop/s (1.03/cyc)   <- same as float: scalar FPU, no SIMD
double divide            11 Mdiv/s   (~71 cyc)
double sqrt              11 Msqrt/s   (~70 cyc)
double FMA latency       7.85 cyc/op  (pipeline depth ~8)
mandelbrot (branchy FP)  ~198 Mflop/s (~4x below peak: deps + branches)
```

The 800 MHz A25 sustains **~0.82 GFLOP/s / ~0.43 G int-op/s** register-resident, but
DDR delivers only **~1.5 M words/s** (~6 MB/s). The compute:memory ratio is **~500x**,
so a workload only escapes the memory wall if it does **~500 FLOP per DDR word** --
almost nothing does, which is why everything that touches DDR is memory-bound (the
target of the L2-cache analysis). Notes: single == double FP rate (no packed SIMD);
divide/sqrt are slow iterative units; integer multiply ~3 cyc.

### dsp_probe — the Andes DSP WORKS (~5x packed-SIMD)
The core reports `EDSP` present (`mmsc_cfg` bit 29). The toolchain has no P support,
so the instructions are emitted as raw `.word` with the **real Andes encodings**
(recovered from the Andes `riscv32-elf` toolchain): the P-draft v0.5 uses **major
opcode 0x7F** (not the RVV 0x77 -- using 0x77 made an earlier probe SIGILL). Each op
runs once under a `SIGILL` guard + self-check, then is benchmarked vs scalar. Result:

```
ucode(0x801) present          <- DSP state CSR exists
ADD8   OK   add8  a0,a0,a1 = 0x48b5057f   DSP 13.0 cyc/op   scalar 70.5  -> 5.4x
ADD16  OK   add16        = 0x40b5057f     DSP 14.3 cyc/op   scalar 24.7  -> 1.7x
SMAQA  OK   smaqa a0,a1,a2 = 0xc8c5857f   DSP  6.2 cyc/op (514 MMAC/s)   -> 4.9x
```

**The DSP is real and usable** -- ~5.4x on packed 4xint8 add and **4.9x on the int8
MAC (SMAQA, ~514 MMAC/s)**, the quantized-inference primitive. The earlier "SIGILL"
result was purely a wrong opcode (0x77 vs 0x7F); the datapath was always present
(`ucode` readable) and there is **no M-mode enable bit** (the Andes BSP sets none;
`trap.c` only context-saves `ucode`). These speedups are a conservative floor -- the
raw `.word` + register pinning penalises the DSP side; a kernel built with the real
Andes toolchain (`-mext-dsp` + `__nds__` intrinsics, as the SDK's INT8 MobileNet demo
is) would be faster. Caveat: this helps **compute-bound, L1-resident** kernels (DSP
filters, quantized NN); it does nothing for the memory-bound workloads (~500x
compute:DDR gap). RVV is still absent (`misa` has no V).

It's a **broad set** -- the Andes toolchain's `nds_intrinsic.h` exposes ~347 DSP/P
intrinsics (saturating `kadd`/`ksub`, unsigned `ukadd`, crossed `cras`/`crsa`, packed
multiply `smbb16`/`khm`/`kmmac`, min/max `smin8`/`smax8`/`umin8`/`umax8`, compare
`cmpeq8`, pack `pkbb16`, abs `kabs8`, unpack `sunpkd810`, shifts `ksll`, ...).
`dsp_probe` self-checks 9 more of these on hardware beyond add8/add16/smaqa --
**all 9/9 correct** (kadd8/ukadd8/sub8/ksub8/smin8/smax8/umin8/umax8/cmpeq8), so the
whole packed-SIMD family works, not just a couple of ops. (Encodings recovered from
the Andes `riscv32-elf` toolchain at `~/Downloads/nds32le-elf-newlib-v5/`.)

**No usable float intrinsics.** The DSP set is integer-only. The toolchain's Andes
float intrinsics are BF16/FP16: scalar BF16 conv `XAndesBFHCvt` (`fcvt.s.bf16`
=0x40657553 / `fcvt.bf16.s`=0x44857553) and vector `XAndesVBFHCvt`/`XAndesVPackFPH`.
dsp_probe round-trips the scalar BF16 conv on HW -> **SIGILL (XAndesBFHCvt absent)**;
the vector ones need RVV (absent). So the only FP path is the standard scalar F/D
FPU (compute_bench: ~0.82 GFLOP/s, single==double, no packed float). The Andes float
extensions are for the AI parts (NX27V-class), not this A25.

### atomic_test — the headline result
On this **no-coherence-manager** A25, userspace hardware atomics:

- **Do not SIGILL** — `misa = rv32imafdc`, so `amoadd.w`/`lr.w`/`sc.w` decode fine.
- **Wedge the process** — every mode prints the line *before* the atomic and
  never the line *after*; the atomic never retires. (Even the "hot" case wedges,
  unlike bare-metal M-mode where an owned line works.)
- **Become uninterruptible** — `kill -9` does not reap the task; it accumulates
  CPU time.
- **Do not crash the board** — the single hart keeps time-slicing other tasks, so
  `ping`/`uptime`/ssh stay responsive and `dmesg` logs no oops/trap/fault. The
  damage is contained to a dead-but-unkillable process; cleanup is a reboot.

This is the userspace-side reason the entire stack (kernel + OpenSBI + musl) is
built single-hart "soft-atomic". See `../CACHE_ISSUES.md` and the memory note
`ae350-amo-cache-miss-hang`.
