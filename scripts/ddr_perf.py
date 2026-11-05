#!/usr/bin/env python3
"""Measure the DDR data-memory AHB path with the ddr_perf block (0xF8000000).

Runs a shell command on the board (over the UART console, see uart_console.py)
and decodes what the hardware counters saw while it ran.  Since kernel #97 the
gowin-ddr-perf driver owns the block: the counters are 64-bit totals in
/sys/bus/platform/devices/f8000000.ddr-perf/counters (one sample per read),
read before and after the workload, and the trace is armed and read through the same directory.
Older kernels get the block directly with devmem (clear, enable, stop).

Usage:
  ddr_perf.py 'md5sum /tmp/r'          # counters around a workload
  ddr_perf.py --trace 64 'md5sum /tmp/r'   # also dump the first 64 trace entries
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uart_console as uc  # noqa: E402

BASE = 0xF8000000
SYSFS = "/sys/bus/platform/devices/f8000000.ddr-perf"
NAMES = ["cycles", "rd_bursts", "wr_bursts", "rd_beats", "wr_beats", "rd_wait",
         "wr_wait", "rd_first_wait", "rd_wait_max", "wr_wait_max", "busy",
         "bus_active"]
BURST = ["SINGLE", "INCR", "WRAP4", "INCR4", "WRAP8", "INCR8", "WRAP16", "INCR16"]
SIZE = ["8b", "16b", "32b", "64b"]
EXT = ["br_hit0", "br_demand", "br_prefetch", "br_wr_push",
       "mc_rd_cmds", "br_tag_mismatch", "mc_wr_cmds", "mc_rd_valid"]
# the driver's file names for counters 0..43, in hardware order
SYSFS_NAMES = (NAMES + ["%s_%s" % (d, b.lower()) for d in ("rd", "wr") for b in BURST]
               + ["%s_size%d" % (d, 8 << i) for d in ("rd", "wr") for i in range(4)] + EXT)
MAXIMA = (8, 9)


def last_hex(out):
    """Value of the last 0x... token in a console reply (skips echo/prompt)."""
    toks = [t for t in out.split() if t.startswith("0x")]
    return int(toks[-1], 16) if toks else 0


def read_counters(s, n=44):
    # one devmem per counter, printed space-separated in a single shell line
    cmd = ("for i in $(seq 0 %d); do printf '%%s ' $(devmem $((0x%X + 0x100 + 4*i)) 32); "
           "done; echo" % (n - 1, BASE))
    out, ok = uc.run(s, cmd, 60)
    vals = [int(t, 16) for t in out.split() if t.startswith("0x")]
    if len(vals) != n:
        raise RuntimeError("counter read failed: %r" % out)
    return vals


def parse_stats(text):
    """'rd_beats 123' lines (the driver's counters file) -> list in hardware order"""
    got = {}
    for line in text.splitlines():
        p = line.split()
        if len(p) == 2 and p[0] in SYSFS_NAMES and p[1].isdigit():
            got[p[0]] = int(p[1])
    if len(got) != len(SYSFS_NAMES):
        raise RuntimeError("counter read failed: %d of %d counters" % (len(got), len(SYSFS_NAMES)))
    return [got[n] for n in SYSFS_NAMES]


def between(out, a, b):
    """the lines between marker lines a and b (the console also echoes the command, markers and all)"""
    lines = [l.strip() for l in out.splitlines()]
    if a not in lines or b not in lines:
        return ""
    i = lines.index(a)
    return "\n".join(lines[i + 1:lines.index(b, i)])


def run_sysfs(s, a):
    """counters (and the trace) through the gowin-ddr-perf driver"""
    stats = "cat %s/counters" % SYSFS
    arm = "echo 1 > %s/trace_arm; " % SYSFS if a.trace else ""
    disarm = "; echo 0 > %s/trace_arm" % SYSFS if a.trace else ""
    out, ok = uc.run(s, "echo @@A; %s; echo @@B; %stime sh -c '%s'%s; echo @@C; %s; echo @@D"
                     % (stats, arm, a.cmd, disarm, stats), a.timeout)
    c0, c1 = parse_stats(between(out, "@@A", "@@B")), parse_stats(between(out, "@@C", "@@D"))
    c = [c1[i] if i in MAXIMA else c1[i] - c0[i] for i in range(len(c1))]
    trace = []
    if a.trace:
        cmd = "od -An -v -tx4 -N %d %s/trace" % (8 * a.trace, SYSFS)
        tout, _ = uc.run(s, cmd, 120)
        words = [int(t, 16) for t in tout.split() if len(t) == 8 and all(ch in "0123456789abcdef" for ch in t)]
        trace = [(words[i + 1], words[i]) for i in range(0, len(words) - 1, 2)]
    return between(out, "@@B", "@@C"), c, trace


def run_devmem(s, a):
    """counters (and the trace) straight from the block: kernels without the driver"""
    ctrl = 0x5 if a.trace else 0x1
    out, ok = uc.run(s, "devmem 0x%X 32 2; devmem 0x%X 32 %d; time sh -c '%s'; devmem 0x%X 32 0"
                     % (BASE + 4, BASE + 4, ctrl, a.cmd, BASE + 4), a.timeout)
    c = read_counters(s)
    trace = []
    if a.trace:
        st, _ = uc.run(s, "devmem 0x%X 32" % (BASE + 8), 10)
        n = min(a.trace, last_hex(st) & 0xFFFF)
        cmd = ("for i in $(seq 0 %d); do devmem 0x%X 32 $i; echo $(devmem 0x%X 32) $(devmem 0x%X 32); done"
               % (n - 1, BASE + 0xC, BASE + 0x14, BASE + 0x10))
        tout, _ = uc.run(s, cmd, 120)
        for line in tout.splitlines():
            p = line.split()
            if len(p) == 2 and p[0].startswith("0x"):
                trace.append((int(p[0], 16), int(p[1], 16)))
    return out, c, trace


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--trace", type=int, default=0, help="dump N trace entries")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--hclk", type=float, default=0, help="DDR_HCLK Hz (default: the driver's clock_hz, else 100 MHz)")
    a = ap.parse_args()

    s = uc.open_port()
    cfg, _ = uc.run(s, "devmem 0x%X 32" % (BASE + 0x18), 10)
    hz, _ = uc.run(s, "cat %s/clock_hz 2>/dev/null || echo none" % SYSFS, 10)
    driver = "none" not in hz.split()
    if not a.hclk:
        a.hclk = next((float(t) for t in hz.split() if t.isdigit()), 100e6)
    out, c, trace = (run_sysfs if driver else run_devmem)(s, a)
    print("== workload output ==")
    print(out)
    cyc = c[0] or 1
    print("== ddr_perf (CONFIG 0x%08X, %s) ==" % (last_hex(cfg), "gowin-ddr-perf sysfs" if driver else "devmem"))
    for i, n in enumerate(NAMES):
        print("  %-14s %12d" % (n, c[i]))
    t = cyc / a.hclk
    rb, wb = c[3], c[4]
    print("  window         %.3f s at %.0f MHz HCLK" % (t, a.hclk / 1e6))
    print("  read  : %d beats, %.1f wait cyc/beat, %.1f cyc to 1st beat, %.2f MB/s"
          % (rb, c[5] / max(rb, 1), c[7] / max(c[1], 1), rb * 8 / t / 1e6))
    print("  write : %d beats, %.1f wait cyc/beat, %.2f MB/s"
          % (wb, c[6] / max(wb, 1), wb * 8 / t / 1e6))
    print("  bus active %.1f %%" % (100.0 * c[11] / cyc))
    print("  read  bursts:", ", ".join("%s=%d" % (BURST[i], c[12 + i]) for i in range(8) if c[12 + i]))
    print("  write bursts:", ", ".join("%s=%d" % (BURST[i], c[20 + i]) for i in range(8) if c[20 + i]))
    print("  read  sizes :", ", ".join("%s=%d" % (SIZE[i], c[28 + i]) for i in range(4) if c[28 + i]))
    print("  write sizes :", ", ".join("%s=%d" % (SIZE[i], c[32 + i]) for i in range(4) if c[32 + i]))
    if any(c[36:44]):
        print("  bridge:", ", ".join("%s=%d" % (EXT[i], c[36 + i]) for i in range(8)))
        if c[40]:
            print("  rd cmds %d vs rd_data_valid %d (diff %d); tag mismatches %d"
                  % (c[40], c[43], c[40] - c[43], c[41]))

    if a.trace:
        trace = trace[:a.trace]
        print("== trace (%d entries) ==" % len(trace))
        print("  %6s %4s %-2s %-6s %-3s %-3s %10s" % ("dts", "wait", "rw", "burst", "sz", "seq", "haddr"))
        prev_ts = None
        for hi, lo in trace:
            ts = hi >> 16
            wait = (hi >> 8) & 0xFF
            wr = (hi >> 7) & 1
            hb = (hi >> 4) & 7
            sz = (hi >> 2) & 3
            seq = (hi >> 1) & 1
            dts = (ts - prev_ts) & 0xFFFF if prev_ts is not None else 0
            prev_ts = ts
            print("  %6d %4d %-2s %-6s %-3s %-3s 0x%08x" % (dts, wait, "W" if wr else "R", BURST[hb],
                                                          SIZE[sz], "S" if seq else "N", lo))


if __name__ == "__main__":
    main()
