#!/usr/bin/env bash
# Flash the AE350 test firmware into the board's external SPI flash via the
# Gowin programmer (JTAG -> SPI bridge).
#
# Layout on this board's shared SPI flash (per the SDK Flash example doc):
#   0x000000  FPGA bitstream (.fs)
#   0x600000  AE350 firmware (.bin)   <- CPU 0x80000000 maps here (XIP)
#
# Operation 55 = "exFlash C Bin Erase,Program (Arora V)"; the firmware binary
# is passed with --mcuFile and the destination offset with --spiaddr.
#
# Env: GOWIN_PATH (install root). DEVICE/SPIADDR/FW overridable.
set -euo pipefail

GOWIN_PATH="${GOWIN_PATH:?set GOWIN_PATH to the Gowin install root}"
DEVICE="${DEVICE:-GW5AST-138B}"
SPIADDR="${SPIADDR:-0x600000}"
FW="${FW:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build/ae350_fw.bin}"

PROGRAMMER="$GOWIN_PATH/Programmer/bin/programmer_cli"

echo "Flashing $FW -> exFlash @ $SPIADDR on $DEVICE"
exec "$PROGRAMMER" --device "$DEVICE" --run 55 --mcuFile "$FW" --spiaddr "$SPIADDR"
