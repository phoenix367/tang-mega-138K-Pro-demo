#!/usr/bin/env bash
# sdhost_core simulation (iverilog): the host + DMA master against a
# behavioural SD card (sd_card_model.v) and a 64-bit AHB memory: the Linux
# init sequence, 4-bit and 1-bit multi-block writes/reads compared through
# DDR, 8/64-byte register blocks, CRC and timeout error paths.
# Usage: sdhost/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
iverilog -g2012 -Wall -Wno-timescale -o "$OUT/tb_sdhost" sdhost/tb/tb_sdhost.v sdhost/tb/sd_card_model.v \
    sdhost/rtl/sdhost_core.v eth_dma/rtl/ahb_master.v || exit 1
(cd "$OUT" && timeout 900 vvp -n tb_sdhost) | tee "$OUT/tb_sdhost.log" | grep -vE "^\s*$"
grep -q "^RESULT: PASS" "$OUT/tb_sdhost.log" && { echo "SDHOST TB PASSED"; exit 0; }
echo "SDHOST TB FAILED"; exit 1
