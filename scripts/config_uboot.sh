#!/usr/bin/env bash
# Configure a mainline U-Boot tree for the Gowin AE350 (Tang Mega 138K Pro).
# Applies ae350_rv32_xip_defconfig + the Kconfig tweaks needed to BUILD
# (hard-float, single-core, no EFI/gnutls host tool) and BOOT (env-nowhere, no
# phantom SPI). Run this once on a fresh / distclean'd tree; then `uboot`.
#
# NOTE: this is the KCONFIG part only. The device-tree adaptation -- single
# CPU, 50 MHz UART/timer, 256 MB DRAM, removed mac/mmc/lcd/spi nodes in
# arch/riscv/dts/ae350_32.dts + ae350-u-boot.dtsi -- is a set of file edits
# that must already be present in the tree (they are not Kconfig settings).
# See project memory ae350-uboot-build for the full rationale.
#
# Env: UBOOT_DIR, UBOOT_CROSS, UBOOT_DEBUG_UART=1 (optional early console).
set -euo pipefail

UBOOT_DIR="${UBOOT_DIR:-$HOME/projects/u-boot}"
CROSS="${UBOOT_CROSS:-/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-}"

[ -d "$UBOOT_DIR" ] || { echo "UBOOT_DIR not found: $UBOOT_DIR" >&2; exit 1; }
cd "$UBOOT_DIR"

echo ">> make ae350_rv32_xip_defconfig"
make CROSS_COMPILE="$CROSS" ae350_rv32_xip_defconfig

cfg() { ./scripts/config "$@"; }

# Host tools / EFI that don't build with the available toolchains
# (mkeficapsule needs gnutls; EFI loader needs -shared).
cfg --disable TOOLS_MKEFICAPSULE
cfg --disable EFI_LOADER --disable CMD_BOOTEFI

# Hard-float: this A25 has an FPU (misa = ...IMAFDC).
cfg --enable RISCV_ISA_F --enable RISCV_ISA_D

# Single-hart SoC.
cfg --disable SMP --set-val NR_CPUS 1

# Environment: this SoC has no software SPI master (only the XIP instruction-
# flash interface), so the default ENV_IS_IN_SPI_FLASH probes a missing
# atcspi200 and faults. Use the built-in default env and drop the SPI driver.
cfg --disable ENV_IS_IN_SPI_FLASH --enable ENV_IS_NOWHERE
cfg --disable DM_SPI --disable SPI_FLASH --disable DM_SPI_FLASH
# (Keep MMC + CFI/MTD_NOR_FLASH enabled: env/board macros reference them and
#  they probe harmlessly to nothing.)

# Optional early debug console on UART2's 16550 block (0xf0300020, shift 2,
# 50 MHz). Off by default; enable for bring-up with UBOOT_DEBUG_UART=1.
if [ "${UBOOT_DEBUG_UART:-0}" = "1" ]; then
    echo ">> enabling DEBUG_UART on UART2"
    cfg --enable DEBUG_UART --enable DEBUG_UART_NS16550 --enable DEBUG_UART_ANNOUNCE
    cfg --set-val DEBUG_UART_BASE 0xf0300020
    cfg --set-val DEBUG_UART_CLOCK 50000000
    cfg --set-val DEBUG_UART_SHIFT 2
fi

make CROSS_COMPILE="$CROSS" olddefconfig
echo ">> configured: XIP=$(grep -c '^CONFIG_XIP=y' .config) hard-float(F/D)=$(grep -c '^CONFIG_RISCV_ISA_D=y' .config) env_nowhere=$(grep -c '^CONFIG_ENV_IS_NOWHERE=y' .config) SMP=$(grep -c '^CONFIG_SMP=y' .config)"
echo ">> Reminder: these tree edits are NOT Kconfig and must already be applied:"
echo ">>   - arch/riscv/dts/ae350_32.dts: board-adapted (no spi@f0b00000 node, 50MHz clocks, 256MB DRAM, single CPU)"
echo ">>   - include/configs/ae350.h: CFG_EXTRA_ENV_SETTINGS has 'autostart=yes' (so bootm runs standalone images) + 'bootpayload'"
