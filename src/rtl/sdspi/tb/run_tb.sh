#!/usr/bin/env bash
# sdspi_core simulation (iverilog): registers, SPI mode-0 byte stream against
# a slave model, clock divider, 2 KB transfer, discard mode, card detect.
# Usage: src/rtl/sdspi/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
iverilog -g2012 -Wall -Wno-timescale -o "$OUT/tb_sdspi" sdspi/tb/tb_sdspi.v sdspi/rtl/sdspi_core.v || exit 1
(cd "$OUT" && timeout 600 vvp -n tb_sdspi) | tee "$OUT/tb_sdspi.log" | grep -vE "^\s*$"
grep -q "^RESULT: PASS" "$OUT/tb_sdspi.log" && { echo "SDSPI TB PASSED"; exit 0; }
echo "SDSPI TB FAILED"; exit 1
