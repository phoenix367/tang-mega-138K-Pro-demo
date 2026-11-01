#!/usr/bin/env bash
# Rebuild every cross-built binary in linux/rootfs/ (libraries first). Each step prints whether
# its result is identical to the file in the rootfs; pass INSTALL=1 to replace them, then
# rebuild the kernel so the initramfs picks them up. busybox is last because it is the slowest.
# lvdesk / inputd / wavplay are built from this repo (src/apps/desktop) and are not covered.
set -euo pipefail
cd "$(dirname "$0")"
for s in ncurses libpcap tcpdump htop iproute2 dropbear doas sftp_server busybox; do
	echo "### $s"
	./build_$s.sh
done
./fetch_lvgl.sh
