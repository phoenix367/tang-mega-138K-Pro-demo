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
$CC -static -O2                                  -o cctl_probe    cctl_probe.c
# sanity: the atomic test really contains hardware atomics
$TC/bin/riscv32-buildroot-linux-musl-objdump -d atomic_test | grep -E 'amoadd|lr\.w|sc\.w'
```

## Run (copy to the board first)

```sh
scp -O atomic_test cctl_probe ae350@192.168.200.2:/tmp/
ssh ae350@192.168.200.2
  /tmp/cctl_probe              # CCTL register access (expects: "CCTL_SUEN OK ...")
  /tmp/memthroughput            # safe: read/write/copy bandwidth vs chunk size
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

Neither helps at any distance -> the DDR path **serializes misses** (no
memory-level parallelism), so the ~6 MB/s latency wall can't be hidden by
prefetch/pipelining. Corroborates the earlier (no-effect) hardware-prefetcher
result; only a gateware fix (multiple-outstanding / bursting DDR path) can move it.

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
