#!/usr/bin/env bash
# audio_core simulation (iverilog): the core on an AHB-lite master model and a
# PT8211 receiver model -- frame rate, every frame in order, FRAMES/CRC model,
# underrun/overrun counting, level interrupt, channel swap, FIFO reset.
# Usage: src/rtl/audio/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
SRC="audio/tb/tb_audio.v eth_dma/rtl/ahb_master.v audio/rtl/audio_core.v audio/rtl/audio_csr.v audio/rtl/audio_out.v"
iverilog -g2012 -Wall -Wno-timescale -o "$OUT/tb_audio" $SRC || exit 1
timeout 600 vvp -n "$OUT/tb_audio" | tee "$OUT/tb_audio.log" | grep -vE "^\s*$"
grep -q "^RESULT: PASS" "$OUT/tb_audio.log" && { echo "AUDIO TB PASSED"; exit 0; }
echo "AUDIO TB FAILED"; exit 1
