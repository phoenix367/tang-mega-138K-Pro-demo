#!/usr/bin/env bash
# Rebuild the busybox binary in linux/rootfs/bin/ from linux/busybox.config.
#
# Source: the busybox git mirror at the commit below (v1.37.0.git, 2024-07-14, no
# release tag), unmodified. Config: busybox's defconfig plus static linking and a few
# applets switched off (CONFIG_STATIC, CONFIG_STATIC_LIBGCC, no HWCLOCK / RDATE / TC /
# SHA*_HWACCEL). Compiler: the Bootlin musl toolchain with the soft-atomic libc.a
# (scripts/build_musl_toolchain.sh), so the result contains no lr/sc/amo instructions.
#
# Usage:
#   scripts/build_busybox.sh                 # build into WORK, print the binary's path
#   INSTALL=1 scripts/build_busybox.sh       # ...and copy it over linux/rootfs/bin/busybox
#
# Environment:
#   CROSS     toolchain prefix (default: ~/projects/riscv32-ilp32d--musl--stable-2025.08-1/...)
#   WORK      scratch dir for the source checkout and build (default: mktemp -d, kept)
#   SOURCE_DATE_EPOCH  fixes the timestamp in the "BusyBox v1.37.0.git (date)" banner,
#             the only thing that differs between two builds. SOURCE_DATE_EPOCH=1781018868
#             (2026-06-09 19:27:48 +04, in this time zone) reproduces the rootfs binary
#             byte for byte.
set -euo pipefail

BUSYBOX_GIT=https://github.com/mirror/busybox
BUSYBOX_COMMIT=371fe9f71d445d18be28c82a2a6d82115c8af19d

HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG="$HERE/../linux/busybox.config"
ROOTFS_BIN="$HERE/../linux/rootfs/bin/busybox"
CROSS=${CROSS:-"$HOME/projects/riscv32-ilp32d--musl--stable-2025.08-1/bin/riscv32-buildroot-linux-musl-"}
WORK=${WORK:-$(mktemp -d)}

[ -f "$CONFIG" ] || { echo "config not found: $CONFIG" >&2; exit 1; }
[ -x "${CROSS}gcc" ] || { echo "toolchain not found: ${CROSS}gcc" >&2; exit 1; }

SRC="$WORK/busybox"
if [ ! -d "$SRC/.git" ]; then
	echo ">> fetching busybox $BUSYBOX_COMMIT into $SRC"
	mkdir -p "$SRC"
	git -C "$SRC" init -q
	git -C "$SRC" remote add origin "$BUSYBOX_GIT"
	git -C "$SRC" fetch -q --depth 1 origin "$BUSYBOX_COMMIT"
	git -C "$SRC" checkout -q FETCH_HEAD
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$BUSYBOX_COMMIT" ] || { echo "$SRC is not at $BUSYBOX_COMMIT" >&2; exit 1; }

cp "$CONFIG" "$SRC/.config"
echo ">> building (log: $WORK/make.log)"
make -s -C "$SRC" CROSS_COMPILE="$CROSS" -j"$(nproc)" >"$WORK/make.log" 2>&1

n=$("${CROSS}objdump" -d "$SRC/busybox" | grep -cE '\b(amo[a-z.]+|lr\.w|sc\.w)\b' || true)
[ "$n" = 0 ] || { echo "busybox contains $n lr/sc/amo instructions; wrong libc.a?" >&2; exit 1; }
echo ">> $SRC/busybox ($(stat -c %s "$SRC/busybox") bytes, static, 0 lr/sc/amo)"

if [ "${INSTALL:-0}" = 1 ]; then
	install -m 755 "$SRC/busybox" "$ROOTFS_BIN"
	echo ">> installed as $ROOTFS_BIN (rebuild the kernel to bake it into the initramfs)"
fi
