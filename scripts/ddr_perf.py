#!/usr/bin/env python3
"""Measure the DDR data-memory AHB path with the ddr_perf block (0xF8000000).

Runs a shell command on the board (over the UART console, see uart_console.py)
between clear/enable and stop of the hardware counters, then decodes them.

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
NAMES = ["cycles", "rd_bursts", "wr_bursts", "rd_beats", "wr_beats", "rd_wait",
         "wr_wait", "rd_first_wait", "rd_wait_max", "wr_wait_max", "busy",
         "bus_active"]
BURST = ["SINGLE", "INCR", "WRAP4", "INCR4", "WRAP8", "INCR8", "WRAP16", "INCR16"]
SIZE = ["8b", "16b", "32b", "64b"]
EXT = ["br_hit0", "br_demand", "br_prefetch", "br_wr_push",
       "mc_rd_cmds", "br_tag_mismatch", "mc_wr_cmds", "mc_rd_valid"]


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--trace", type=int, default=0, help="dump N trace entries")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--hclk", type=float, default=50e6, help="DDR_HCLK Hz")
    a = ap.parse_args()

    s = uc.open_port()
    cfg, _ = uc.run(s, "devmem 0x%X 32" % (BASE + 0x18), 10)
    ctrl = 0x5 if a.trace else 0x1
    out, ok = uc.run(s, "devmem 0x%X 32 2; devmem 0x%X 32 %d; time sh -c '%s'; devmem 0x%X 32 0"
                     % (BASE + 4, BASE + 4, ctrl, a.cmd, BASE + 4), a.timeout)
    print("== workload output ==")
    print(out)
    c = read_counters(s)
    cyc = c[0] or 1
    print("== ddr_perf (CONFIG 0x%08X) ==" % last_hex(cfg))
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
        st, _ = uc.run(s, "devmem 0x%X 32" % (BASE + 8), 10)
        n = min(a.trace, last_hex(st) & 0xFFFF)
        cmd = ("for i in $(seq 0 %d); do devmem 0x%X 32 $i; echo $(devmem 0x%X 32) $(devmem 0x%X 32); done"
               % (n - 1, BASE + 0xC, BASE + 0x14, BASE + 0x10))
        out, _ = uc.run(s, cmd, 120)
        print("== trace (%d entries) ==" % n)
        print("  %6s %4s %-2s %-6s %-3s %-3s %10s" % ("dts", "wait", "rw", "burst", "sz", "seq", "haddr"))
        prev_ts = None
        for line in out.splitlines():
            p = line.split()
            if len(p) != 2 or not p[0].startswith("0x"):
                continue
            hi, lo = int(p[0], 16), int(p[1], 16)
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
