# ddr_bridge — AHB → DDR3 bridge for the AE350 data memory

Replaces Gowin's `gw_ahb_ddr3` (src/gw_ahb_ddr3*.v, now disabled in the .gprj) between
the AE350 SoC's customized data-memory AHB bus (`DDR_H*`, 64-bit, **100 MHz**) and the
Gowin DDR3 Memory Interface IP (`DDR3_Memory_Interface_Top`, 1:4, x16, BL8, **DDR3-800**).
`ADDR_BITS` (ahb_ddr3_top) is the DDR size: 29 = **512 MB** since 2026-10-29 (15 row bits,
`src/ddr3_memory_interface_512/`); it was 28 = 256 MB, a quarter of the board's 1 GB. The
AE350 forwards its whole 2 GB data window (0x00000000–0x7FFFFFFF) to `DDR_H*`; addresses
beyond the DDR size alias. The other half of the board's memory is the second x16 chip of a
32-bit bus: reaching it means `DQ_WIDTH = 32` in the IP, a 256-bit bridge datapath (one BL8 per
32 B line instead of two halves) and 20 more pins — not done.

```
rtl/ahb_ddr3_top.v      drop-in for gw_ahb_ddr3_top: bridge + DDR3 IP (+HPROT, perf hookup)
rtl/ahb_ddr3_bridge.v   the bridge (AHB slave, line buffers, prefetch, posted writes, CDC)
rtl/ddr_async_fifo.v    gray-code dual-clock FIFO (FWFT, optional registered write port)
rtl/ddr_rd_bist.v       non-destructive read-ordering self-test of the DDR3 MC
tb/tb_ahb_ddr3_bridge.v randomized self-checking testbench (A25-like AHB master: WRAP4
                        critical-word-first, SINGLE of all sizes, INCR, BUSY, RMW)
tb/ddr3_ui_model.v      DDR3 IP user-port model (back-pressure, latency, optional reorder,
                        +max_rd in-flight check, +rdy_pct back-pressure)
tb/tb_ddr_perf.v        test of src/ddr_perf.v (the APB perf/trace block)
tb/run_all.sh           everything below; tb/run_regress.sh / run_directed.sh / run_mutants.sh
formal/                 safety properties of the AHB side: run_formal.sh (ABC), bridge_ahb.sby
```

## Why the stock path was slow

Measured with `src/ddr_perf.v` (AHB monitor on `DDR_H*`, read via APB @ `0xF8000000`):
the A25 fetches L1 lines as **WRAP4 64-bit bursts, critical word first**, and Gowin's
bridge turns **every 64-bit beat into its own DDR3 command** with a full clock-domain
round trip: **~39 HCLK (0.8 µs) of wait per beat**, ~160 HCLK per 32 B line, bus busy 93 %
during `md5sum`. The DDR3 MC's own read latency is ~28 user clocks.

## What the bridge does

* **Reads** — 8 line buffers of 32 B (the A25 L1 line). A miss fetches the whole line as
  two BL8 reads (critical half first, per-half valid). The line being read is copied into
  `cl_data` (the *current line*), and the remaining beats of its WRAP4 (or line-aligned
  INCR4) burst are **predicted**: each is staged from the copy and answered with zero wait
  states.
* **Prefetch** — a 4-slot stream table detects ascending line streams and keeps
  `PF_DIST` (2) lines in flight ahead.
* **Writes** — posted with zero wait states. A 4-entry queue feeds a 16 B merge block with
  a byte mask, written as one masked BL8 write. Every write invalidates buffered copies of
  its line (line buffers and the current line); a generation tag drops data still in
  flight for an invalidated entry.
* **Ordering** — reads and writes share one command FIFO into the DDR clock. A read waits
  until queued writes are processed, and a DDR read is pushed only after every earlier
  write. The bridge is the only path to DDR (CPU and EXTM DMA both arrive on this bus), so
  its buffers stay coherent.
* **Video port** — a read-only second client in the DDR clock domain for the LCD
  scan-out (`../video/`). Its BL8 reads go out in cycles where the bridge's issue slot
  is empty, so the bridge goes first. A request that has waited 8 uclk goes ahead of the
  bridge's next command. Without that aging rule, a CPU write stream keeps the slot full
  and starves the port: on hardware `dd if=/dev/zero` caused 1500 underrun lines in 3 s.
  At most 8 video reads are in flight, and none during the BIST. A 1-bit issue-order FIFO
  routes each return: the MC answers in order, which the overlapped-read default already
  relies on. Video reads bypass the line buffers and see DDR only, so a pixel can lag a
  posted CPU write by one frame.

  In simulation, a video request waits at most 21–97 uclk under a write stream (949 to
  14,201 without aging), and a saturated port slows random AHB traffic by ~3 %.
* **DDR side** — registered command head plus an issue slot, `cmd_ready`/`wr_data_rdy`
  required high in two consecutive cycles (safe for both readings of the MC handshake), a
  tag queue and return FIFO with an end-to-end line address check (`pc_tagmis`).

## AHB side at 100 MHz

The AE350 is a hard macro at a fixed place on the die: its `DDR_H*` outputs take ~5.5 ns
of routing to reach fabric logic, and `HRDATA`/`HREADY` take a similar route back. At
10 ns there is no room for logic on either side of that boundary, so:

* the AHB address phase is only **registered** (`aq_*`); just `HTRANS`/`HWRITE` feed one
  small decision into the `HREADY` flop (zero-wait for IDLE/BUSY, posted writes and
  predicted beats);
* `HREADY`/`HRDATA` are **flops** (`hready_q`/`hrdata_q`);
* first beats and anything not predicted take the slow path: **1 wait state** on a
  current-line hit, **2** on a line-buffer hit, a DDR round trip on a miss. A line fill is
  6 cycles of 10 ns (it was 5 cycles of 20 ns at 50 MHz);
* deep logic is pipelined: registered victim (with at most one allocation every other
  cycle; found by a flat per-entry "older than every other non-pending entry" test, the
  LRU ages being a permutation), registered command-FIFO "almost full", a fabric stage plus a one-hot target for
  returning data, a registered write-merge flag, a 3-stage prefetch pipeline, and stream
  table updates applied a cycle after the compare.

Timing closes at 100 MHz with a 0.3 ns setup uncertainty in the SDC (real margin; the
placer stops at the constraint otherwise). The DDR side runs at 100 MHz too (DDR3-800 /
4) and closed with: a 3-phase BIST compare, the tag queue written the cycle after the
issue, and the issue slot (the FIFO head sits in a BSRAM output register with 1.8 ns
clock-to-out, so the row/line compare happens once, on load). The slot loads only while
empty, a cycle after it issues. That keeps the MC's late `cmd_ready` off the ~340 load
enables of the head and slot registers; adding the video port pushed that path 5 ps
negative. The bubble costs 1–4 % in simulation and less at the real command rate.

With the video port, Build 49 had the AHB side at −0.12 ns against the padded constraint
(its margin moved ±0.3 ns between builds with placement). The decision-term cleanup that
followed (flat victim select, redundant qualifiers dropped, one allocation path) took the
AHB side from 12 to 8 synthesis logic levels; Build 51 closes every clock, ae350_ddr_clk at
100.19 MHz against the padded constraint and ddr3_sysclk at 104.9 MHz, with the same
hardware results (memtest, display CRCs, network, zero underruns).

## Debug MODE register (`0xF8000020`, ddr_perf, reset `MODE_RESET`)

| bit | effect |
|---|---|
| 0 | no prefetch |
| 1 | same as 0 (was "no retention") |
| 2 | no write merging |
| 5 | no read within G uclk of a write |
| 6 | one DDR command at a time (stock spacing) |
| 7 | no write within G of a write |
| 8 | one DDR read in flight (needed for a kernel without PATCHES/0005 at 200 MHz) |
| 9 | no write while a read is in flight |
| 10 / 11 | no read / write within G of a read |
| 15:12 | G = n*4 uclk (0 → 32) |
| **16** | **allow overlapping reads to different rows** (otherwise same-row only); **default `0x10000`** |
| 17 | same-cycle ready handshake (~15% more memcpy; also runs clean on hardware) |
| 18 | release a read beat only when its whole line is in |
| 19 | no predicted beats (every read beat ≥ 1 wait) |
| 20 | overlapping reads only within one line |
| 21 | fetch half 0 first (no critical-half-first) |
| 24 | read BIST start (toggle), 26:25 pattern, 31:28 iterations = 2^(n+8) |

BIST results: ddr_perf counters 44..51 (`0xF80001B0..`): status, errors, reorders, first
mismatch {pattern, j, k, iteration}, its word address, got, expected, stray valids.

## Results (hardware, Linux userspace `tests/ddr_memtest`, MODE 0x10000)

| | stock gw_ahb_ddr3 | DDR3-400 / bus 50 | DDR3-800 / bus 50 | **DDR3-800 / bus 100 (default)** |
|---|---|---|---|---|
| sequential read | 6.3 MB/s | 76.3 MB/s | 110.9 MB/s | **148.0 MB/s** |
| memset | 5.0 MB/s | 61.2 MB/s | 83.5 MB/s | **119.7 MB/s** |
| memcpy | 2.2 MB/s | 17–20 MB/s | 26.4 MB/s | **36.6–37.0 MB/s** |
| random dependent miss | 7980 ns | 2.4–2.6 µs | 1.6–1.7 µs | **1.34–1.42 µs** |
| kernel boot to /init | 33.5 s | 4.9 s | 3.4 s | **2.83 s** |

The stock column is DDR3-400 with a 50 MHz bus. With the PATCHES/0005 kernel (#46), the
default build (Build 33) passes memtest, 3000 fork + 500 exec rounds with 0 oopses, and
the read BIST on hardware (4 patterns × 4096 iterations: 0 errors, reorders or stray
returns). Gigabit Ethernet DMA through the bridge stays intact: md5-exact in both
directions, ~13.5 Mbit/s into the board and ~30 Mbit/s out (CPU-bound).

**Ethernet RX caveat:** some builds show ~2e-5 MAC-rejected RX frames (Builds 22/23/30:
2–5 per 140k), others 0 (Builds 26/33). The CRC check catches every one, so data is never
corrupted (TCP `InCsumErrors` 0) and TCP resends them. It varies with placement:
`RGMII_RXC` (C23) is not a clock-capable pin, and the RGMII input timing is not
constrained.

## SoC data-memory bus clock (`DDR_CLK` = `DDR_HCLK`)

Per Gowin MUG1031-1.3.1E (Table 4-1), the AE350 hard macro takes the core clock (up to
800 MHz) and the DDR (data memory), AHB and APB clocks, each **below 200 MHz**. They are
mutually asynchronous, except that AHB:APB must be 1:1. `DDR_HCLK` is `DDR_CLK` buffered
out of the macro, and it is the only clock on the CPU↔DDR path; AHB/APB serve only
peripherals, flash XIP and the Ethernet DMA/CSR port, and stay at 50 MHz.
`DDR_CLK` is **100 MHz** (PLL CLKOUT0 = 800/8). Going from 50 to 100 MHz bought +34%
sequential read, +43% memset, +39% memcpy and −16% miss latency: much of each line
transfer is fixed time on the core side of the macro.

## Verification

`tb/run_all.sh` runs everything:

* **random regression** (`run_regress.sh`): 3 buffer/prefetch configs × 4 clock ratios ×
  4 seeds, A25-like traffic against a reference memory, plus one seed per combination with
  a video-port client (`+video=P`). The client reads a second window that AHB never
  writes, and every return is checked.
* **directed** (`run_directed.sh`): BUSY-free and BUSY-heavy traffic, every debug mode,
  heavy DDR back-pressure, the row rule against a reordering DDR model, the
  one-read-in-flight mode against the model's `+max_rd=1` check, the legacy handshake
  against the look-ahead check, and the BIST (clean on all patterns, reorders detected).
  It also runs the video port at 50/100 %, under back-pressure, with a slow BUSY-heavy
  bus, during a BIST, and against a write stream with a bound on the video wait
  (`+wrheavy +vmaxwait=200`).
* **mutants** (`run_mutants.sh`): 13 deliberately broken copies of the RTL, one per rule
  the bridge relies on, including the video port's return routing, its issue-slot rule
  and its aging. Each must be caught (data errors, protocol errors or the deadlock watchdog).
* **ddr_perf** unit test.
* **formal** (`formal/run_formal.sh`, properties under `ifdef FORMAL` in the bridge): no
  lost DDR command, no FIFO or write-queue overflow, reads queued only after earlier
  writes, AHB OKAY / zero-wait IDLE-BUSY / HREADY low only in a data phase, no allocation
  of an in-flight entry, no line in two entries, read data only from valid halves of the
  right line, and the invariants the decision terms are simplified with (the slow path
  leaves IDLE only inside a held read data phase, a prefetch candidate never meets a
  stream-table update, the LRU ages are a permutation, nothing to flush while an
  allocation is possible). The clock-crossing FIFOs are free stubs and unused data is cut. ABC proves
  the small configuration (12-bit, 4 buffers) **for all reachable states**; the full size
  is checked to 16 cycles. Z3 (`bridge_ahb.sby`) did not finish step 0 of this model with
  yosys-smtbmc 0.33 / Z3 4.8.12.

## Solved: overlapping DDR reads broke Linux fork/exec (A25 page-table walker)

With two or more DDR reads in flight, Linux used to oops during fork/exec. Page walks of a
freshly built page directory saw bad kernel entries (`Unable to handle kernel paging
request` at kernel text/stack). Data-only workloads, the read BIST, the end-to-end tag
check and the simulation were all clean. The same thing happened with DDR3 at 400 MHz
even with one read in flight. The faster the memory, the more often it failed.

**Root cause:** the A25's hardware page-table walker reads page tables with its own
bus reads (seen in the ddr_perf trace as SINGLE reads: root PTE, then leaf PTE). Those
reads are not coherent with dirty lines in the L1 D-cache, and the AE350 has no coherence
manager. Linux builds a new pgd with `memset`/`memcpy` and writes PTEs through the
cache, so the walker can read stale DRAM. The slow stock bridge hid the race.

**Fix (kernel, PATCHES/0005):** every page-table store is followed by a CCTL
L1D_VA_WB of its line, and whole pages are written back for a new pgd and for freshly
zeroed PTE tables. Proof on the same kernel: `a25_ptwb=1` at MODE 0 is clean through
3000 forks, and `echo 0 > /sys/module/kernel/parameters/a25_ptwb` makes MODE 0 oops
within seconds.

## Tools

`scripts/ddr_perf.py 'cmd'` (counters around a workload, `--trace N`),
`scripts/boot_mode.py BIT.fs MODE` (load SRAM, set MODE in U-Boot, boot, count oopses),
`scripts/uboot_cmd.py BIT.fs 'cmd'...`, `scripts/uart_console.py login|run|push|listen`
(external USB-UART `/dev/ttyUSB0` on UART2 B19/A17), `scripts/timing_summary.py`,
`tests/ddr_memtest.c` (correctness + per-miss latency + bandwidth).
