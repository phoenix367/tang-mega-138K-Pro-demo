#!/usr/bin/env bash
# Run a command (default: an interactive shell) in the build image, with the repository
# mounted at /work, the Gowin install at /opt/gowin and the userspace package dir at
# /userspace. Settings come from docker/.env, written by docker/bootstrap.sh; any of
# IMAGE / GOWIN_PATH / AE350_USERSPACE in the environment overrides them.
#
#   docker/run.sh                                   # shell
#   docker/run.sh make -C src/firmware              # bare-metal firmware
#   docker/run.sh scripts/build_uboot.sh            # U-Boot
#   docker/run.sh make -C external/linux ARCH=riscv CROSS_COMPILE=riscv32-linux- -j8 Image
#   docker/run.sh env STAGE=all scripts/gw_run.sh   # gateware (needs the licence server)
#   docker/run.sh scripts/rootfs/build_all.sh       # rootfs binaries
#
# USB (programmer_cli, the UART console) is passed through when /dev/bus/usb exists;
# the container runs as the uid/gid chosen at bootstrap, so the host's udev rules for the
# Gowin programmer (Programmer/bin/50-programmer_usb.rules) must already allow that user.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
[ -f "$HERE/.env" ] && { set -a; . "$HERE/.env"; set +a; }
IMAGE=${IMAGE:-tang-mega-138k-build:latest}
GOWIN_PATH=${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}
AE350_USERSPACE=${AE350_USERSPACE:-$HOME/projects/ae350_linux_user_level}

opts=(--rm -v "$REPO:/work" -v "$AE350_USERSPACE:/userspace" -w /work -e TERM="${TERM:-xterm}")
[ -t 0 ] && opts+=(-it)
[ -d "$GOWIN_PATH/IDE" ] && opts+=(-v "$GOWIN_PATH:/opt/gowin:ro")
[ -d /dev/bus/usb ] && opts+=(--device /dev/bus/usb)
for t in /dev/ttyUSB* /dev/ttyACM*; do [ -e "$t" ] && opts+=(--device "$t"); done
# git inside the container: the mounted repo and its submodules belong to the same uid,
# but git still wants the path whitelisted
opts+=(-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*')

mkdir -p "$AE350_USERSPACE"
exec docker run "${opts[@]}" "$IMAGE" "$@"
