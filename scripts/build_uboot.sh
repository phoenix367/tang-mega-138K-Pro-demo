#!/usr/bin/env bash
# Build mainline U-Boot for the Gowin AE350 (Tang Mega 138K Pro) and produce a
# combined "u-boot + DTB" XIP flash image ready to program at flash 0x600000.
#
# The board configuration (XIP, hard-float, ENV_IS_NOWHERE, the adapted DTS, ...) is
# the fork's ae350_rv32_tang_mega_138k_defconfig, applied by scripts/config_uboot.sh.
# This script runs that only on a tree without a .config (a fresh clone), so local
# config changes survive; then it does the incremental build with the right toolchain
# and assembles the flash image.
#
# Why each piece (see project memory ae350-uboot-build):
#   - CROSS is the Andes Linux rv32 toolchain (its ld supports -pie, unlike the
#     bare-metal *-elf ones, and it ships the hard-float ilp32d libgcc). Give it by
#     ABSOLUTE path: the user's profile prepends a crippled riscv64-unknown-elf- to PATH.
#   - HF_LIBGCC (optional): a toolchain without an ilp32d libgcc, such as the AMD
#     Vitis linux-gnu one, needs PLATFORM_LIBGCC pointed at one (UBOOT_HF_LIBGCC).
#   - The AE350 board finds its DTB at CONFIG_SYS_FDT_BASE=0x800f0000, i.e. at
#     FDT_OFFSET (=0x800f0000-0x80000000) into the flash image. So: pad
#     u-boot.bin to FDT_OFFSET and append the DTB.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
UBOOT_DIR="${UBOOT_DIR:-$REPO/external/u-boot}"        # submodule: phoenix367/tang-mega-138k-u-boot
# Andes Linux GCC (nds32le-linux-glibc-v5d): PIE-capable ld, ships the ilp32d libgcc.
ANDES_ROOT="${ANDES_ROOT:-/mnt/data/toolchains}"
CROSS="${UBOOT_CROSS:-$ANDES_ROOT/nds32le-linux-glibc-v5d/bin/riscv32-linux-}"
# Only for a toolchain without a hard-float libgcc (the AMD/Vitis linux-gnu one needed
# the elf toolchain's ilp32d libgcc): UBOOT_HF_LIBGCC=/path/to/rv32imafdc/ilp32d
HF_LIBGCC="${UBOOT_HF_LIBGCC:-}"
DTB="${UBOOT_DTB:-arch/riscv/dts/ae350_32.dtb}"
FDT_OFFSET="${UBOOT_FDT_OFFSET:-983040}"      # 0xf0000 = SYS_FDT_BASE - TEXT_BASE
OUT="${UBOOT_IMAGE:-$UBOOT_DIR/u-boot-ae350-xip.bin}"

[ -d "$UBOOT_DIR" ] || { echo "UBOOT_DIR not found: $UBOOT_DIR" >&2; exit 1; }
[ -x "${CROSS}gcc" ] || { echo "toolchain not found: ${CROSS}gcc" >&2; exit 1; }
cd "$UBOOT_DIR"

[ -f .config ] || UBOOT_DIR="$UBOOT_DIR" UBOOT_CROSS="$CROSS" "$REPO/scripts/config_uboot.sh"

echo ">> Building U-Boot (hard-float XIP) with $CROSS"
if [ -n "$HF_LIBGCC" ]; then
    make -j"$(nproc)" CROSS_COMPILE="$CROSS" PLATFORM_LIBGCC="-L $HF_LIBGCC -lgcc"
else
    make -j"$(nproc)" CROSS_COMPILE="$CROSS"
fi

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
# boot splash (src/splash/splash.bmp, see src/splash/make_splash.py) at image offset
# 0x100000 = flash 0x700000 = XIP 0x80100000 (U-Boot env splashimage)
SPLASH="${UBOOT_SPLASH:-$REPO/src/splash/splash.bmp}"
SPLASH_OFFSET=1048576
if [ -f "$SPLASH" ]; then
    [ "$(stat -c%s "$OUT")" -le "$SPLASH_OFFSET" ] || { echo "ERROR: u-boot+DTB overrun the splash offset" >&2; exit 1; }
    truncate -s "$SPLASH_OFFSET" "$OUT"
    cat "$SPLASH" >> "$OUT"
    echo ">> appended splash $SPLASH @ $(printf 0x%x "$SPLASH_OFFSET")"
fi
echo ">> $OUT  ($(stat -c%s "$OUT") bytes)  [u-boot @0, DTB @ $(printf 0x%x "$FDT_OFFSET")${SPLASH:+, splash @ 0x100000}]"
