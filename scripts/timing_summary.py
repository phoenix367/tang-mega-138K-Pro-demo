#!/usr/bin/env python3
"""Summarize a Gowin PnR <proj>.timing_paths file: worst slack per
(check, source top-level instance, destination top-level instance).

Usage: timing_summary.py [impl/pnr/mega_138K_test.timing_paths]
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "impl/pnr/mega_138K_test.timing_paths"
blocks = [b.strip().split("\n") for b in open(path).read().split("=====") if b.strip()]
worst, neg = {}, {}
for b in blocks:
    kind, slack = b[0], float(b[1])
    key = (kind, b[4].split("/")[0], b[-2].split("/")[0] if len(b) > 5 else "")
    worst[key] = min(worst.get(key, 1e9), slack)
    neg[key] = neg.get(key, 0) + (slack < 0)
for key, sl in sorted(worst.items(), key=lambda kv: kv[1]):
    print("%-6s %8.3f ns  %3d neg  %s -> %s" % (key[0], sl, neg[key], key[1], key[2]))
