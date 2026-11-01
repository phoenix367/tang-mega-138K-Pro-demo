#!/usr/bin/env bash
# Package OpenSBI + the RV32 Linux kernel + the AE350 DTB into a single
# OpenSBI fw_payload image for the Gowin AE350.
#
# Boot model (AE350 has DRAM at 0x0, flash/XIP at 0x80000000):
#   U-Boot (M-mode, XIP) copies this image from flash-XIP into DRAM at 0x0 and
#   `go 0`. OpenSBI runs in M-mode at 0x0, then enters the kernel (S-mode) at
#   0x0 + FW_PAYLOAD_OFFSET. The kernel carries a built-in busybox initramfs.
#
#   fw_payload layout (in DRAM after copy):
#     0x000000  OpenSBI (M-mode firmware)
#     0x200000  Linux kernel Image (S-mode)   <- FW_PAYLOAD_OFFSET
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OPENSBI_DIR="${OPENSBI_DIR:-$REPO/external/opensbi}"   # submodule: phoenix367/tang-mega-138k-opensbi
LINUX_DIR="${LINUX_DIR:-$REPO/external/linux}"         # submodule: phoenix367/tang-mega-138k-linux
DTB="${DTB:-$REPO/linux/ae350-linux.dtb}"
CROSS="${LINUX_CROSS:-/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-}"
FW_TEXT_START="${FW_TEXT_START:-0x00000000}"
FW_PAYLOAD_OFFSET="${FW_PAYLOAD_OFFSET:-0x200000}"
IMAGE="$LINUX_DIR/arch/riscv/boot/Image"

[ -f "$IMAGE" ] || { echo "kernel Image not found: $IMAGE (build it first)" >&2; exit 1; }
[ -f "$DTB" ]   || { echo "DTB not found: $DTB" >&2; exit 1; }

echo ">> kernel Image: $(du -h "$IMAGE" | cut -f1)"
cd "$OPENSBI_DIR"
make -j"$(nproc)" CROSS_COMPILE="$CROSS" PLATFORM=generic \
	FW_PAYLOAD=y \
	FW_PAYLOAD_PATH="$IMAGE" \
	FW_FDT_PATH="$DTB" \
	FW_TEXT_START="$FW_TEXT_START" \
	FW_PAYLOAD_OFFSET="$FW_PAYLOAD_OFFSET"

OUT="$OPENSBI_DIR/build/platform/generic/firmware/fw_payload.bin"
echo ">> fw_payload: $OUT  ($(du -h "$OUT" | cut -f1), $(stat -c%s "$OUT") bytes)"
