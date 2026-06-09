#!/usr/bin/env bash
# Assemble the combined "application" flash image for the AE350:
#   offset 0          : U-Boot (+ its DTB)            -> CPU 0x80000000
#   offset PAYLOAD_OFF: the bootm payload uImage      -> CPU 0x80000000+PAYLOAD_OFF
#
# Why one image: the Gowin programmer's exFlash bridge only reliably writes the
# 0x600000 region (and 0x0). A separate write to e.g. 0x800000 is silently
# dropped (reads back 0xff). So everything U-Boot-side must ride a single image
# based at FW_SPIADDR (0x600000), which is then flashed in one shot.
set -euo pipefail

UBOOT_IMAGE="${UBOOT_IMAGE:?set UBOOT_IMAGE}"      # u-boot + dtb combined image
PAYLOAD_IMG="${PAYLOAD_IMG:?set PAYLOAD_IMG}"      # mkimage'd payload uImage
OUT="${APP_IMAGE:?set APP_IMAGE}"                  # output combined app image
FW_SPIADDR="${FW_SPIADDR:-0x600000}"
PAYLOAD_SPIADDR="${PAYLOAD_SPIADDR:-0x800000}"

PAYLOAD_OFF=$(( PAYLOAD_SPIADDR - FW_SPIADDR ))    # bash parses 0x... hex
ubsz=$(stat -c%s "$UBOOT_IMAGE")
if [ "$ubsz" -gt "$PAYLOAD_OFF" ]; then
    echo "ERROR: U-Boot image ($ubsz B) overruns payload offset ($PAYLOAD_OFF B)." >&2
    echo "       Raise PAYLOAD_SPIADDR." >&2
    exit 1
fi

cp "$UBOOT_IMAGE" "$OUT"
truncate -s "$PAYLOAD_OFF" "$OUT"
cat "$PAYLOAD_IMG" >> "$OUT"
echo "App image: $OUT ($(stat -c%s "$OUT") bytes)  [u-boot @0, payload @ $(printf 0x%x "$PAYLOAD_OFF")]"
