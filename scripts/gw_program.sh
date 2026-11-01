#!/usr/bin/env bash
# Program the generated bitstream onto the board over the Gowin USB-JTAG cable,
# using programmer_cli (ships under <GOWIN_PATH>/Programmer/bin).
# Adapted from tang_nano_9K_ov7670 (which uses GW1NR-9C / --run 2|6).
#
# Env vars:
#   GOWIN_PATH - Gowin install root. Required (used to locate programmer_cli).
#   DEVICE     - programmer device string. Defaults to GW5AST-138B.
#                Verify against `programmer_cli --device-list` for your exact part.
#   FS         - Path to the .fs bitstream. Defaults to impl/pnr/<base>.fs.
#   MODE       - sram (volatile, default) | flash (persistent).
#
# Operation indices (from `programmer_cli --help`):
#   2  = SRAM Program (volatile, reverts on power cycle)
#   53 = exFlash Erase,Program (Arora V) - external SPI flash @ 0x0, autoboot
# This GW5AST (Arora V) has no usable embFlash; the persistent bitstream lives in
# the external SPI flash at 0x0 (below the firmware at 0x600000), from which the
# FPGA self-configures on power-up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "${GOWIN_PATH:-}" ]]; then
    echo "GOWIN_PATH not set; point it at the Gowin install root" >&2
    exit 1
fi

DEVICE="${DEVICE:-GW5AST-138B}"
FS="${FS:-$REPO_DIR/impl/pnr/mega_138K_test.fs}"
MODE="${MODE:-sram}"

PROGRAMMER="$GOWIN_PATH/Programmer/bin/programmer_cli"

case "$MODE" in
    sram)  exec "$PROGRAMMER" --device "$DEVICE" --run 2  --fsFile "$FS" ;;
    flash) exec "$PROGRAMMER" --device "$DEVICE" --run 53 --fsFile "$FS" --spiaddr 0x000000 ;;
    *) echo "Unknown MODE: $MODE (expected sram|flash)" >&2; exit 1 ;;
esac
