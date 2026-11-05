#!/usr/bin/env python3
"""Summarise a Gowin PnR run of mega_138K_test: per-clock Fmax against its constraint,
failing endpoints, the resources that matter, and whether the bitstream fits its flash
region.

Usage: pnr_summary.py [IMPL_PNR_DIR]     (default: impl/pnr of the repo)
Exit status 1 if any clock fails or a report is missing.
"""
import html
import os
import re
import sys
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "impl", "pnr")
TR = os.path.join(D, "mega_138K_test_tr_content.html")
RPT = os.path.join(D, "mega_138K_test.rpt.txt")
BIN = os.path.join(D, "mega_138K_test.bin")
FLASH_LIMIT = 0x600000            # U-Boot starts at flash 0x600000


def table(text, title):
    """Rows (lists of cell strings) of the first HTML table after `title`."""
    i = text.find(title)
    if i < 0:
        return []
    seg = text[i:]
    j = seg.find("<h2", 10)
    seg = seg[:j] if j > 0 else seg
    rows = []
    for r in re.findall(r"<tr>(.*?)</tr>", seg, re.S):
        cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip()
                 for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, re.S)]
        if cells:
            rows.append(cells)
    return rows


def mhz(s):
    m = re.match(r"([\d.]+)", s)
    return float(m.group(1)) if m else None


def main():
    for f in (TR, RPT):
        if not os.path.exists(f):
            print("missing %s (run STAGE=all scripts/gw_run.sh)" % f)
            return 1
    ok = True
    tr = open(TR, encoding="utf-8", errors="replace").read()
    print("reports from %s" % time.strftime("%Y-%m-%d %H:%M", time.localtime(os.path.getmtime(TR))))

    print("\nclock                                   constraint      Fmax   margin")
    for r in table(tr, "Max Frequency Summary"):
        if len(r) < 4 or r[0] == "NO.":
            continue
        c, f = mhz(r[2]), mhz(r[3])
        if c is None or f is None:
            continue
        flag = "" if f >= c else "   FAIL"
        ok &= f >= c
        print("%-38s %8.3f %9.3f %7.1f %%%s" % (r[1][:38], c, f, 100 * (f - c) / c, flag))

    bad = [r for r in table(tr, "Total Negative Slack Summary")
           if len(r) >= 4 and r[0] != "Clock Name" and r[3].isdigit() and int(r[3]) > 0]
    if bad:
        ok = False
        print("\nfailing endpoints:")
        for r in bad:
            print("  %s %s: TNS %s ns, %s endpoints" % (r[0], r[1], r[2], r[3]))
    else:
        print("\nfailing endpoints: none (setup and hold)")

    print("\nresources:")
    keep = ("Logic ", "Register ", "CLS ", "I/O Port", "BSRAM ", "DSP ", "PLL ", "PRIMARY ", "LW ")
    for line in open(RPT, encoding="utf-8", errors="replace"):
        s = line.strip()
        if s.startswith(keep) and "|" in s:
            print("  " + re.sub(r"\s*\|\s*", " | ", s))

    if os.path.exists(BIN):
        sz = os.path.getsize(BIN)
        fits = sz <= FLASH_LIMIT
        ok &= fits
        print("\nbitstream %s: %d bytes, ends at flash 0x%X%s"
              % (os.path.basename(BIN), sz, sz, "" if fits else "  -- OVER the 0x600000 U-Boot region"))
    print("\n" + ("all clocks met" if ok else "NOT OK -- see above"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
