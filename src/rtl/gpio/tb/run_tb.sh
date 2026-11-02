#!/usr/bin/env bash
# gpio_core simulation (iverilog): registers, direction/tri-state on pulled-up
# pins, and a bit-banged I2C address byte ACKed by a slave model.
# Usage: src/rtl/gpio/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
iverilog -g2012 -Wall -Wno-timescale -o "$OUT/tb_gpio" gpio/tb/tb_gpio.v gpio/rtl/gpio_core.v || exit 1
(cd "$OUT" && timeout 120 vvp -n tb_gpio) | tee "$OUT/tb_gpio.log" | grep -vE "^\s*$"
grep -q "^RESULT: PASS" "$OUT/tb_gpio.log" && { echo "GPIO TB PASSED"; exit 0; }
echo "GPIO TB FAILED"; exit 1
