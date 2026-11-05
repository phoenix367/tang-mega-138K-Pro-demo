#!/usr/bin/env bash
# Clone the pushed repository (with its submodules) into a fresh directory and run each
# build step there through the Docker image (docker/run.sh), the way a new user would.
#
#   fresh_clone_build.sh [-d DEST] [STEP...]
#
# Steps (default: kernel firmware uboot tests boardcfg desktop vidplay):
#   kernel    scripts/build_kernel.sh (Image + initramfs + OpenSBI fw_payload, ~7 min)
#   firmware  make -C src/firmware
#   uboot     scripts/build_uboot.sh
#   tests boardcfg desktop vidplay   make -B in src/apps/<step>
#   rootfs    scripts/rootfs/build_all.sh (every userspace package; long, downloads sources)
#   gateware  STAGE=all scripts/gw_run.sh (needs the Gowin licence server)
#
# Env: REPO_URL (default the GitHub origin), BRANCH (default the remote's HEAD).
# DEST defaults to /mnt/data/build/ctest-<date> (the root disk is nearly full); the logs
# go to DEST.logs. An existing DEST is refused rather than deleted.
set -uo pipefail

URL=${REPO_URL:-git@github.com:phoenix367/tang-mega-138K-Pro-demo.git}
D=/mnt/data/build/ctest-$(date +%Y%m%d-%H%M)
if [ "${1:-}" = -d ]; then D=$2; shift 2; fi
STEPS=("$@")
[ ${#STEPS[@]} -gt 0 ] || STEPS=(kernel firmware uboot tests boardcfg desktop vidplay)
L=$D.logs

if [ -e "$D" ]; then echo "$D exists: remove it or pass another -d DEST" >&2; exit 2; fi
docker image inspect tang-mega-138k-build:latest >/dev/null 2>&1 ||
	{ echo "no tang-mega-138k-build image: run docker/bootstrap.sh first" >&2; exit 2; }
mkdir -p "$L"

clone=(git clone -q --recurse-submodules --shallow-submodules)
[ -n "${BRANCH:-}" ] && clone+=(-b "$BRANCH")
if ! "${clone[@]}" "$URL" "$D" >"$L/clone.log" 2>&1; then
	echo "clone failed, see $L/clone.log" >&2; exit 1
fi
cd "$D" || exit 1
echo "clone $D: $(git log --oneline -1)"
git submodule status | awk '{printf "  %s @ %s\n", $2, substr($1, 1, 9)}'

fails=0
step() {
	local name=$1; shift
	local s=$SECONDS
	if docker/run.sh "$@" >"$L/$name.log" 2>&1; then
		echo "$name: ok ($((SECONDS - s)) s)"
	else
		echo "$name: FAIL ($((SECONDS - s)) s), see $L/$name.log"; fails=$((fails + 1))
	fi
}
for t in "${STEPS[@]}"; do
	case "$t" in
	kernel)   step kernel scripts/build_kernel.sh ;;
	firmware) step firmware make -C src/firmware ;;
	uboot)    step uboot scripts/build_uboot.sh ;;
	tests|boardcfg|vidplay) step "$t" make -B -C "src/apps/$t" ;;
	desktop)  step desktop make -B -j"$(nproc)" -C src/apps/desktop ;;
	rootfs)   step rootfs scripts/rootfs/build_all.sh ;;
	gateware) step gateware env STAGE=all scripts/gw_run.sh ;;
	*) echo "unknown step: $t" >&2; fails=$((fails + 1)) ;;
	esac
done

echo "results:"
grep -h '^>> kernel 6' "$L/kernel.log" 2>/dev/null | sed 's/^/  /'
p=external/opensbi/build/platform/generic/firmware/fw_payload.bin
[ -f "$p" ] && echo "  fw_payload.bin: $(stat -c %s "$p") bytes"
[ -f external/u-boot/u-boot-ae350-xip.bin ] && echo "  u-boot-ae350-xip.bin: $(stat -c %s external/u-boot/u-boot-ae350-xip.bin) bytes"
# the app binaries against the copies committed in linux/rootfs: the static musl builds
# are reproducible, except lvdesk, which embeds LVGL's source path (/userspace/... here)
for pair in src/apps/vidplay/vidplay:usr/bin/vidplay src/apps/desktop/build/lvdesk:usr/bin/lvdesk \
            src/apps/desktop/inputd:usr/bin/inputd src/apps/boardcfg/boardcfg:usr/sbin/boardcfg; do
	b=${pair%%:*}; r=linux/rootfs/${pair#*:}
	[ -f "$b" ] && [ -f "$r" ] || continue
	if cmp -s "$b" "$r"; then echo "  $r: identical to the committed copy"
	else echo "  $r: differs from the committed copy"; fi
done
echo "$fails step(s) failed; logs in $L"
[ "$fails" = 0 ]
