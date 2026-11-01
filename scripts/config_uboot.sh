#!/usr/bin/env bash
# Configure the U-Boot submodule (external/u-boot, phoenix367/tang-mega-138k-u-boot) for the
# Gowin AE350 on the Tang Mega 138K Pro Dock. Everything board-specific (XIP, hard-float,
# single hart, no EFI, env nowhere, no SPI master, board-adapted DTS and ae350.h env) is in
# the fork's ae350_rv32_tang_mega_138k_defconfig; this only applies it, plus the optional
# early debug console. Build afterwards with scripts/build_uboot.sh.
#
# Env: UBOOT_DIR, UBOOT_CROSS, UBOOT_DEBUG_UART=1 (early console on UART2's 16550).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
UBOOT_DIR="${UBOOT_DIR:-$REPO/external/u-boot}"
ANDES_ROOT="${ANDES_ROOT:-/mnt/data/toolchains}"
CROSS="${UBOOT_CROSS:-$ANDES_ROOT/nds32le-linux-glibc-v5d/bin/riscv32-linux-}"   # Andes Linux GCC

[ -d "$UBOOT_DIR" ] || { echo "UBOOT_DIR not found: $UBOOT_DIR (git submodule update --init external/u-boot)" >&2; exit 1; }
cd "$UBOOT_DIR"

echo ">> make ae350_rv32_tang_mega_138k_defconfig"
make CROSS_COMPILE="$CROSS" ae350_rv32_tang_mega_138k_defconfig

# Optional early debug console on UART2's 16550 block (0xf0300020, shift 2, 50 MHz).
if [ "${UBOOT_DEBUG_UART:-0}" = "1" ]; then
	echo ">> enabling DEBUG_UART on UART2"
	cfg() { ./scripts/config "$@"; }
	cfg --enable DEBUG_UART --enable DEBUG_UART_NS16550 --enable DEBUG_UART_ANNOUNCE
	cfg --set-val DEBUG_UART_BASE 0xf0300020
	cfg --set-val DEBUG_UART_CLOCK 50000000
	cfg --set-val DEBUG_UART_SHIFT 2
	make CROSS_COMPILE="$CROSS" olddefconfig
fi

echo ">> configured: XIP=$(grep -c '^CONFIG_XIP=y' .config) hard-float(F/D)=$(grep -c '^CONFIG_RISCV_ISA_D=y' .config) env_nowhere=$(grep -c '^CONFIG_ENV_IS_NOWHERE=y' .config) SMP=$(grep -c '^CONFIG_SMP=y' .config)"
