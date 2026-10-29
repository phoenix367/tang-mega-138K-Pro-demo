#!/usr/bin/env bash
# fan_core simulation (iverilog): registers, PWM duty/period/inversion on the
# pin, tacho glitch filter, edge count and one-second rate.
# Usage: fan/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
iverilog -g2012 -Wall -Wno-timescale -o "$OUT/tb_fan" fan/tb/tb_fan.v fan/rtl/fan_core.v || exit 1
(cd "$OUT" && timeout 600 vvp -n tb_fan) | tee "$OUT/tb_fan.log" | grep -vE "^\s*$"
grep -q "^RESULT: PASS" "$OUT/tb_fan.log" && { echo "FAN TB PASSED"; exit 0; }
echo "FAN TB FAILED"; exit 1
