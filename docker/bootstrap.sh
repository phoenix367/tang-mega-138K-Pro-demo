#!/usr/bin/env bash
# Build the project's Docker build environment and configure docker/run.sh.
#
#   docker/bootstrap.sh [options]
#
# Options (all optional; defaults in brackets):
#   --gowin-path DIR     Gowin EDA install root on the host, the dir containing IDE/
#                        [$GOWIN_PATH, else /mnt/data/Gowin_V1.9.12.02_SP2_linux]. Not copied
#                        into the image: run.sh bind-mounts it read-only at /opt/gowin.
#   --userspace DIR      host dir for rootfs package sources/tarballs (scripts/rootfs/)
#                        [$AE350_USERSPACE, else ~/projects/ae350_linux_user_level]
#   --tag NAME[:TAG]     image name [tang-mega-138k-build:latest]
#   --andes-release TAG  Andes-Development-Kit release to fetch the toolchains from
#                        [ast-v5_4_1-release-linux]; a different release needs new
#                        checksums: --andes-elf-sha256 / --andes-linux-sha256
#   --uid N / --gid N    uid/gid of the container user (files in the mounted repo get
#                        this owner) [current user's]
#   --no-cache           rebuild every layer
#   --dry-run            print the docker build command and the run.sh settings, build nothing
#
# Writes docker/.env (read by run.sh) and builds the image from docker/Dockerfile with the
# repository root as build context (.dockerignore keeps the context to the two files the
# Dockerfile copies). The image is ~3 GB; Docker's data root needs that much free space.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

GOWIN="${GOWIN_PATH:-/mnt/data/Gowin_V1.9.12.02_SP2_linux}"
USERSPACE="${AE350_USERSPACE:-$HOME/projects/ae350_linux_user_level}"
TAG=tang-mega-138k-build:latest
ANDES_RELEASE=ast-v5_4_1-release-linux
ANDES_ELF_SHA256=
ANDES_LINUX_SHA256=
BUILD_UID=$(id -u)
BUILD_GID=$(id -g)
NO_CACHE=
DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
	--gowin-path) GOWIN=$2; shift 2 ;;
	--userspace) USERSPACE=$2; shift 2 ;;
	--tag) TAG=$2; shift 2 ;;
	--andes-release) ANDES_RELEASE=$2; shift 2 ;;
	--andes-elf-sha256) ANDES_ELF_SHA256=$2; shift 2 ;;
	--andes-linux-sha256) ANDES_LINUX_SHA256=$2; shift 2 ;;
	--uid) BUILD_UID=$2; shift 2 ;;
	--gid) BUILD_GID=$2; shift 2 ;;
	--no-cache) NO_CACHE=--no-cache; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | cut -c3-; exit 0 ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

GOWIN=$(readlink -m "$GOWIN"); USERSPACE=$(readlink -m "$USERSPACE")
[ -x "$GOWIN/IDE/bin/gw_sh" ] || echo "warning: $GOWIN/IDE/bin/gw_sh not found; gateware builds in the container will not work until --gowin-path points at a Gowin install" >&2
command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

args=(build -f "$HERE/Dockerfile" -t "$TAG" $NO_CACHE
      --build-arg "ANDES_RELEASE=$ANDES_RELEASE"
      --build-arg "BUILD_UID=$BUILD_UID" --build-arg "BUILD_GID=$BUILD_GID")
[ -n "$ANDES_ELF_SHA256" ]   && args+=(--build-arg "ANDES_ELF_SHA256=$ANDES_ELF_SHA256")
[ -n "$ANDES_LINUX_SHA256" ] && args+=(--build-arg "ANDES_LINUX_SHA256=$ANDES_LINUX_SHA256")
args+=("$REPO")

cat >"$HERE/.env" <<EOF
# written by docker/bootstrap.sh on $(date -I); read by docker/run.sh
IMAGE=$TAG
GOWIN_PATH=$GOWIN
AE350_USERSPACE=$USERSPACE
EOF
echo ">> wrote $HERE/.env:"; sed 's/^/   /' "$HERE/.env"

if [ "$DRY_RUN" = 1 ]; then echo ">> docker ${args[*]}"; exit 0; fi

# Docker keeps the image under its data root; refuse early if that cannot hold it.
root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
free_kb=$(df -Pk "$root" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt $((4*1024*1024)) ]; then
	echo "error: only $((free_kb/1024)) MB free under Docker's data root ($root); the image needs ~3 GB plus build scratch." >&2
	echo "       Move the data root (e.g. {\"data-root\": \"/mnt/data/docker\"} in /etc/docker/daemon.json, then restart docker) or free space." >&2
	exit 1
fi

mkdir -p "$USERSPACE"
echo ">> docker ${args[*]}"
docker "${args[@]}"
echo ">> image $TAG ready. Use docker/run.sh <command> (or docker/run.sh for a shell)."
