#!/usr/bin/env python3
"""Compare two boardtest runs: status changes, tests present in only one run, and
numeric metrics that moved by more than a threshold.

Usage:
  compare_runs.py [NEW [OLD]] [--min-change PCT]

NEW defaults to the latest run under /mnt/data/build/boardtest/. OLD defaults to the
latest earlier run that covers every test of NEW (so a full run is compared with a
full run, and a `-g kernel` run with the last run that had the kernel group).
"""
import argparse
import json
import os
import sys

ROOT = "/mnt/data/build/boardtest"
NOISE = {"uptime_s"}                 # metrics that change on every run


def runs():
    out = []
    for d in sorted(os.listdir(ROOT)) if os.path.isdir(ROOT) else []:
        p = os.path.join(ROOT, d, "report.json")
        if os.path.isfile(p):
            out.append(os.path.join(ROOT, d))
    return out


def load(d):
    with open(os.path.join(d, "report.json")) as f:
        r = json.load(f)
    return r.get("meta", {}), {t["id"]: t for t in r.get("results", [])}


def num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("new", nargs="?")
    ap.add_argument("old", nargs="?")
    ap.add_argument("--min-change", type=float, default=10.0, help="metric change to report, %% (default 10)")
    a = ap.parse_args()

    all_runs = runs()
    new = a.new or (all_runs[-1] if all_runs else None)
    if not new:
        print("no runs under %s" % ROOT)
        return 2
    mnew, tnew = load(new)
    old = a.old
    if not old:
        earlier = [d for d in all_runs if os.path.basename(d) < os.path.basename(new.rstrip("/"))]
        for d in reversed(earlier):
            if set(tnew) <= set(load(d)[1]):
                old = d
                break
    if not old:
        print("no earlier run covers the tests of %s" % new)
        return 2
    mold, told = load(old)

    for tag, d, m in (("new", new, mnew), ("old", old, mold)):
        print("%s: %s  kernel %s  git %s%s" % (tag, os.path.basename(d.rstrip("/")), m.get("kernel", "?"),
                                              m.get("git", "?"), "  (quick)" if m.get("quick") else ""))

    changed = [(i, told[i]["status"], tnew[i]["status"]) for i in tnew if i in told and told[i]["status"] != tnew[i]["status"]]
    print("\nstatus changes:" if changed else "\nstatus changes: none")
    for i, s0, s1 in changed:
        print("  %-24s %s -> %s   %s" % (i, s0, s1, tnew[i].get("summary", "")))
        for p in tnew[i].get("problems", []) + tnew[i].get("warnings", []):
            print("  %-24s   ~ %s" % ("", p))

    only_new = sorted(set(tnew) - set(told))
    only_old = sorted(set(told) - set(tnew))
    if only_new:
        print("\nonly in new: " + ", ".join(only_new))
    if only_old and a.old:
        print("only in old: " + ", ".join(only_old))

    moved = []
    for i in tnew:
        if i not in told:
            continue
        m1, m0 = tnew[i].get("metrics", {}), told[i].get("metrics", {})
        for k, v in m1.items():
            if k in NOISE:
                continue
            v0 = m0.get(k)
            if num(v) and num(v0) and v0 != 0:
                pct = 100.0 * (v - v0) / abs(v0)
                if abs(pct) >= a.min_change:
                    moved.append((i, k, v0, v, pct))
            elif isinstance(v, str) and isinstance(v0, str) and v != v0 and max(len(v), len(v0)) <= 48:
                moved.append((i, k, v0, v, None))       # short labels: link speed, release, MODE
    print("\nmetrics that moved (>= %g %%):" % a.min_change if moved else "\nmetrics that moved: none")
    for i, k, v0, v, pct in moved:
        tail = "%+.1f %%" % pct if pct is not None else ""
        print("  %-24s %-22s %s -> %s  %s" % (i, k, v0, v, tail))

    bad = [i for i, t in tnew.items() if t["status"] in ("FAIL", "ERROR")]
    print("\nnew run: %d tests, %s" % (len(tnew), "FAIL/ERROR in " + ", ".join(bad) if bad else "no FAIL or ERROR"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
