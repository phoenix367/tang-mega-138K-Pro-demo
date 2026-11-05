#!/usr/bin/env bash
# Build the board kernel (external/linux, tang_mega_138k_defconfig) with its name
# and release number, then the OpenSBI fw_payload that `scripts/flash.sh kernel`
# compresses and flashes.
#
#   uname -r   6.12.0-tangmega138k-g<commit>[-dirty]   CONFIG_LOCALVERSION + the fork's commit
#   uname -v   #<release> <build date>                 the board release, linux/RELEASE
#
# The release is the "kernel #N" of BOOT.md: one number for the kernel and the rootfs
# baked into it (the initramfs from linux/rootfs).  Bump linux/RELEASE for a new release
# (test builds of one release share it).  At boot rcS writes both strings into /etc/issue.
#
#   scripts/build_kernel.sh                 Image + fw_payload.bin
#   NO_PAYLOAD=1 scripts/build_kernel.sh    Image only
#   RELEASE=99 scripts/build_kernel.sh      another release number for this build
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
LINUX_DIR="${LINUX_DIR:-$REPO/external/linux}"         # submodule: phoenix367/tang-mega-138k-linux
ANDES_ROOT="${ANDES_ROOT:-/mnt/data/toolchains}"
CROSS="${LINUX_CROSS:-$ANDES_ROOT/nds32le-linux-glibc-v5d/bin/riscv32-linux-}"   # Andes Linux GCC
RELEASE="${RELEASE:-$(tr -d ' \n' < "$REPO/linux/RELEASE")}"
case "$RELEASE" in
''|*[!0-9]*) echo "release '$RELEASE' is not a number (linux/RELEASE)" >&2; exit 1 ;;
esac

KMAKE=(make -C "$LINUX_DIR" ARCH=riscv CROSS_COMPILE="$CROSS")
[ -f "$LINUX_DIR/.config" ] || "${KMAKE[@]}" tang_mega_138k_defconfig
# KBUILD_BUILD_VERSION replaces the tree's build counter (.version) in uname -v
"${KMAKE[@]}" KBUILD_BUILD_VERSION="$RELEASE" -j"$(nproc)" Image
echo ">> kernel $(cat "$LINUX_DIR/include/config/kernel.release") #$RELEASE"

# the payload must sit 4 MB-aligned (rv32 sv32 superpage): 0x200000 boots nothing
[ -n "${NO_PAYLOAD:-}" ] ||
	FW_PAYLOAD_OFFSET="${FW_PAYLOAD_OFFSET:-0x400000}" LINUX_CROSS="$CROSS" "$REPO/scripts/build_linux_boot.sh"
