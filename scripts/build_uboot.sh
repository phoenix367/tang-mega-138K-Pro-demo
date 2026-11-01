#!/usr/bin/env bash
# Build mainline U-Boot for the Gowin AE350 (Tang Mega 138K Pro) and produce a
# combined "u-boot + DTB" XIP flash image ready to program at flash 0x600000.
#
# The U-Boot tree must already be configured + device-tree-adapted for this
# board (ae350_rv32_xip_defconfig + RISCV_ISA_F/D on, ENV_IS_NOWHERE, no SPI
# node in ae350_32.dts, etc.). This script does the incremental build with the
# right toolchain and assembles the flash image; it does not re-run defconfig.
#
# Why each piece (see project memory ae350-uboot-build):
#   - CROSS is the Vitis linux-gnu rv32 toolchain (its ld supports -pie, unlike
#     the bare-metal *-elf ones). Give it by ABSOLUTE path: the user's profile
#     prepends a crippled riscv64-unknown-elf- to PATH.
#   - HF_LIBGCC: the AMD toolchain ships no hard-float (ilp32d) libgcc, so we
#     point PLATFORM_LIBGCC at the Debian elf toolchain's ilp32d libgcc.
#   - The AE350 board finds its DTB at CONFIG_SYS_FDT_BASE=0x800f0000, i.e. at
#     FDT_OFFSET (=0x800f0000-0x80000000) into the flash image. So: pad
#     u-boot.bin to FDT_OFFSET and append the DTB.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
UBOOT_DIR="${UBOOT_DIR:-$REPO/external/u-boot}"        # submodule: phoenix367/tang-mega-138k-u-boot
CROSS="${UBOOT_CROSS:-/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-}"
HF_LIBGCC="${UBOOT_HF_LIBGCC:-/usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32imafdc/ilp32d}"
DTB="${UBOOT_DTB:-arch/riscv/dts/ae350_32.dtb}"
FDT_OFFSET="${UBOOT_FDT_OFFSET:-983040}"      # 0xf0000 = SYS_FDT_BASE - TEXT_BASE
OUT="${UBOOT_IMAGE:-$UBOOT_DIR/u-boot-ae350-xip.bin}"

[ -d "$UBOOT_DIR" ] || { echo "UBOOT_DIR not found: $UBOOT_DIR" >&2; exit 1; }
[ -x "${CROSS}gcc" ] || { echo "toolchain not found: ${CROSS}gcc" >&2; exit 1; }
cd "$UBOOT_DIR"

echo ">> Building U-Boot (hard-float XIP) with $CROSS"
make -j"$(nproc)" CROSS_COMPILE="$CROSS" PLATFORM_LIBGCC="-L $HF_LIBGCC -lgcc"

[ -f u-boot.bin ] || { echo "build produced no u-boot.bin" >&2; exit 1; }
[ -f "$DTB" ]     || { echo "DTB not found: $DTB (build it / check name)" >&2; exit 1; }

ubsz=$(stat -c%s u-boot.bin)
if [ "$ubsz" -gt "$FDT_OFFSET" ]; then
    echo "ERROR: u-boot.bin ($ubsz B) overruns the DTB offset ($FDT_OFFSET B)." >&2
    echo "       Raise CONFIG_SYS_FDT_BASE / UBOOT_FDT_OFFSET." >&2
    exit 1
fi

echo ">> Assembling combined image: u-boot.bin + DTB @ offset $FDT_OFFSET"
cp u-boot.bin "$OUT"
truncate -s "$FDT_OFFSET" "$OUT"
cat "$DTB" >> "$OUT"
echo ">> $OUT  ($(stat -c%s "$OUT") bytes)  [u-boot @0, DTB @ $(printf 0x%x "$FDT_OFFSET")]"
