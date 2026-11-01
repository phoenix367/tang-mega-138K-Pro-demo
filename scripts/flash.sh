#!/usr/bin/env bash
# Program the board over the Gowin USB-JTAG cable: one named target per flash region.
#
#   scripts/flash.sh [-n] TARGET...
#
# Targets (SPI NOR layout, see BOOT.md):
#   load        load impl/pnr/mega_138K_test.fs into SRAM (volatile, gone at power-cycle)
#   bitstream   write the .fs to flash 0x000000 (FPGA self-configures from it at power-on)
#   uboot       external/u-boot/u-boot-ae350-xip.bin -> flash 0x600000 (U-Boot XIP + DTB)
#   kernel      gzip external/opensbi/.../fw_payload.bin -> fw_payload_gz.bin -> flash 0x800000
#               (OpenSBI + kernel + DTB; must stay under 8 MB, the region ends at 0x1000000)
#   firmware    src/firmware/build/ae350_fw.bin -> flash 0x600000 (bare metal, replaces U-Boot)
#
# Options / env:
#   -n, --dry-run   print the programmer commands, run nothing
#   GOWIN_PATH      Gowin install root (required); DEVICE (GW5AST-138B)
#
# Notes: a flash write leaves the programmer's SPI bridge loaded in the FPGA, so after
# bitstream/uboot/kernel/firmware either power-cycle the board or run `load` to get the
# design back. The exFlash bridge reliably writes images based at 0x0, 0x600000 and
# 0x800000 only (other offsets are silently dropped, see BOOT.md).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
DRY=0
[ "${1:-}" = -n ] || [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ $# -gt 0 ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-; exit 2; }

GOWIN_PATH="${GOWIN_PATH:?set GOWIN_PATH to the Gowin install root}"
DEVICE="${DEVICE:-GW5AST-138B}"
PROG="$GOWIN_PATH/Programmer/bin/programmer_cli"
FS="$REPO/impl/pnr/mega_138K_test.fs"
UBOOT="$REPO/external/u-boot/u-boot-ae350-xip.bin"
PAYLOAD="$REPO/external/opensbi/build/platform/generic/firmware/fw_payload.bin"
FIRMWARE="$REPO/src/firmware/build/ae350_fw.bin"

run() { echo ">> $*"; [ "$DRY" = 1 ] || "$@"; }
need() { [ -f "$1" ] || { echo "error: $1 not found (build it first)" >&2; exit 1; }; }
# programmer_cli --mcuFile accepts only *.bin and exFlash writes of 0x600000/0x800000 use op 55
exflash() { run "$PROG" --device "$DEVICE" --run 55 --mcuFile "$1" --spiaddr "$2"; }

[ "$DRY" = 1 ] || [ -x "$PROG" ] || { echo "error: $PROG not found" >&2; exit 1; }

wrote=0
for t in "$@"; do
	[ "$t" = load ] || wrote=1
	case "$t" in
	load)
		need "$FS"; run "$PROG" --device "$DEVICE" --run 2 --fsFile "$FS" ;;
	bitstream)
		need "$FS"; run "$PROG" --device "$DEVICE" --run 53 --fsFile "$FS" --spiaddr 0x000000 ;;
	uboot)
		need "$UBOOT"; exflash "$UBOOT" 0x600000 ;;
	firmware)
		need "$FIRMWARE"; exflash "$FIRMWARE" 0x600000 ;;
	kernel)
		need "$PAYLOAD"
		gz="${PAYLOAD%.bin}_gz.bin"
		run sh -c "gzip -9 -c '$PAYLOAD' > '$gz'"
		if [ "$DRY" != 1 ]; then
			sz=$(stat -c %s "$gz")
			[ "$sz" -le $((8*1024*1024)) ] || { echo "error: $gz is $sz bytes, over the 8 MB region" >&2; exit 1; }
			echo ">> $gz: $sz bytes"
		fi
		exflash "$gz" 0x800000 ;;
	*) echo "unknown target: $t (load|bitstream|uboot|kernel|firmware)" >&2; exit 2 ;;
	esac
done
[ "$wrote" = 1 ] && echo ">> done; power-cycle the board or run 'scripts/flash.sh load' to leave the programmer's SPI bridge"
exit 0
