#!/usr/bin/env bash
# sensor_core simulation (iverilog): the core on an AHB-lite master model with
# behavioural ADCULC/ADCLRC models (adc_model.v -- the Gowin simlib only
# declares the hard cores' ports).  Checks the scan sequencer, result
# registers, run/stop, timeout flagging and the calibration registers.
# Usage: src/rtl/sensor/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
SRC="sensor/tb/tb_sensor.v sensor/tb/adc_model.v sensor/rtl/sensor_core.v sensor/rtl/sensor_adc.v"
iverilog -g2012 -Wall -Wno-timescale -o "$OUT/tb_sensor" $SRC || exit 1
timeout 600 vvp -n "$OUT/tb_sensor" | tee "$OUT/tb_sensor.log" | grep -vE "^\s*$"
grep -q "^RESULT: PASS" "$OUT/tb_sensor.log" && { echo "SENSOR TB PASSED"; exit 0; }
echo "SENSOR TB FAILED"; exit 1
