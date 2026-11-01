#!/usr/bin/env bash
# busybox -> linux/rootfs/bin/busybox from linux/busybox.config.
#
# Source: the busybox git mirror at the commit below (v1.37.0.git, 2024-07-14, no release
# tag), unmodified, checked out shallow into $AE350_USERSPACE/busybox/src (BUSYBOX_SRC
# overrides). Config: busybox's defconfig plus static linking and a few applets switched off
# (CONFIG_STATIC, CONFIG_STATIC_LIBGCC, no HWCLOCK / RDATE / TC / SHA*_HWACCEL).
#
# SOURCE_DATE_EPOCH fixes the timestamp in the "BusyBox v1.37.0.git (date)" banner, the only
# thing that differs between two builds; SOURCE_DATE_EPOCH=1781018868 (2026-06-09 19:27:48
# +04, in this time zone) reproduces the shipped binary byte for byte.
. "$(dirname "$0")/common.sh"

BUSYBOX_GIT=https://github.com/mirror/busybox
BUSYBOX_COMMIT=371fe9f71d445d18be28c82a2a6d82115c8af19d
CONFIG="$REPO/linux/busybox.config"
PKGDIR="$PKGROOT/busybox"
SRC=${BUSYBOX_SRC:-"$PKGDIR/src"}

[ -f "$CONFIG" ] || die "config not found: $CONFIG"
if [ ! -d "$SRC/.git" ]; then
	echo ">> fetching busybox $BUSYBOX_COMMIT into $SRC"
	mkdir -p "$SRC"
	git -C "$SRC" init -q
	git -C "$SRC" remote add origin "$BUSYBOX_GIT"
	git -C "$SRC" fetch -q --depth 1 origin "$BUSYBOX_COMMIT"
	git -C "$SRC" checkout -q FETCH_HEAD
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$BUSYBOX_COMMIT" ] || die "$SRC is not at $BUSYBOX_COMMIT"

cp "$CONFIG" "$SRC/.config"
make -s -C "$SRC" CROSS_COMPILE="$CROSS" -j"$JOBS" >"$PKGDIR/make.log" 2>&1
# the busybox build already strips the binary; keep it exactly as built
NOSTRIP=1 finish_bin "$SRC/busybox" bin/busybox
