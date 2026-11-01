# Shared helpers for the scripts/rootfs/build_*.sh package builds. Source it, don't run it.
#
# Every binary in linux/rootfs/ is a static rv32 musl executable built with the Bootlin
# toolchain whose libc.a has been rebuilt without lr/sc/amo instructions
# (scripts/build_musl_toolchain.sh; the AE350 here has no coherency manager). The package
# sources (tarball + extracted tree) live outside the repo in
# ~/projects/ae350_linux_user_level/<pkg>/ (CLAUDE.md, "Linux userspace sources"); only
# these build recipes are versioned.
#
# Environment (all optional):
#   AE350_USERSPACE  package root (default ~/projects/ae350_linux_user_level)
#   TOOLCHAIN        toolchain root (default ~/projects/riscv32-ilp32d--musl--stable-2025.08-1)
#   FRESH=1          delete and re-extract the source tree before building
#   INSTALL=1        copy the stripped result over the file in linux/rootfs/
#   JOBS             make parallelism (default nproc)
set -euo pipefail

ROOTFS_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$ROOTFS_SCRIPTS/../.." && pwd)
ROOTFS="$REPO/linux/rootfs"
PKGROOT=${AE350_USERSPACE:-"$HOME/projects/ae350_linux_user_level"}
STAGING="$PKGROOT/staging"                      # cross-built static libs + headers (ncurses, libpcap)
HOST=riscv32-buildroot-linux-musl
TCDIR=${TOOLCHAIN:-"$HOME/projects/riscv32-ilp32d--musl--stable-2025.08-1"}/bin
CROSS="$TCDIR/$HOST-"
JOBS=${JOBS:-$(nproc)}

die() { echo "error: $*" >&2; exit 1; }

[ -x "${CROSS}gcc" ] || die "toolchain not found: ${CROSS}gcc"
mkdir -p "$PKGROOT" "$STAGING"

# The configure scripts find $HOST-gcc, pcap-config etc. by name; the triple is distinct from
# any other RISC-V toolchain on PATH, so prepending is safe. pkg-config sees only the staging libs.
export PATH="$TCDIR:$STAGING/bin:$PATH"
export PKG_CONFIG_LIBDIR="$STAGING/lib/pkgconfig"
export PKG_CONFIG_PATH=""

# pkg_source DIR TREE URL SHA256 [TARBALL]
#   Fetches (if missing or corrupt) and verifies the tarball into $PKGROOT/DIR (saved as TARBALL,
#   default the URL's basename), extracts it as $PKGROOT/DIR/TREE when that is missing (or
#   FRESH=1), and cds into it. Sets PKGDIR and SRC.
pkg_source() {
	local dir=$1 tree=$2 url=$3 sha=$4
	PKGDIR="$PKGROOT/$dir"; SRC="$PKGDIR/$tree"
	local f="$PKGDIR/${5:-$(basename "$url")}"
	mkdir -p "$PKGDIR"
	if [ ! -f "$f" ] || ! echo "$sha  $f" | sha256sum -c --quiet - 2>/dev/null; then
		echo ">> downloading $(basename "$url")"
		curl -fsSL --retry 3 -o "$f" "$url"
	fi
	echo "$sha  $f" | sha256sum -c --quiet - || die "checksum mismatch: $f"
	[ "${FRESH:-0}" = 1 ] && rm -rf "$SRC"
	if [ ! -d "$SRC" ]; then
		echo ">> extracting $(basename "$f")"
		tar xf "$f" -C "$PKGDIR"
		[ -d "$SRC" ] || die "$f did not extract to $SRC"
	fi
	cd "$SRC"
}

# check_atomics FILE: fail if the binary contains any lr/sc/amo instruction (wrong libc.a?).
check_atomics() {
	local n
	n=$("${CROSS}objdump" -d "$1" | grep -cE '\b(amo[a-z.]+|lr\.w|sc\.w)\b' || true)
	[ "$n" = 0 ] || die "$1 contains $n lr/sc/amo instructions"
}

# finish_bin BUILT ROOTFS_PATH
#   Strips BUILT to $PKGDIR/<name> (copies it unchanged with NOSTRIP=1), checks it is static
#   and atomic-free, reports whether it matches linux/rootfs/ROOTFS_PATH, and with INSTALL=1
#   copies it there.
finish_bin() {
	local built=$1 rel=$2 out="$PKGDIR/$(basename "$1")" msg
	if [ "${NOSTRIP:-0}" = 1 ]; then cp -f "$built" "$out"; else "${CROSS}strip" -o "$out" "$built"; fi
	file "$out" | grep -q 'statically linked' || die "$out is not statically linked"
	check_atomics "$out"
	msg="$out ($(stat -c %s "$out") bytes, static, 0 lr/sc/amo)"
	if cmp -s "$out" "$ROOTFS/$rel"; then msg="$msg, identical to linux/rootfs/$rel"
	elif [ "${NOSTRIP:-0}" != 1 ] && "${CROSS}strip" -o "$out.rootfs-stripped" "$ROOTFS/$rel" 2>/dev/null \
	     && cmp -s "$out" "$out.rootfs-stripped"; then
		msg="$msg, identical to linux/rootfs/$rel once that is stripped (it ships with debug info)"
	else msg="$msg, DIFFERS from linux/rootfs/$rel"; fi
	rm -f "$out.rootfs-stripped"
	echo ">> $msg"
	if [ "${INSTALL:-0}" = 1 ]; then
		install -m 755 "$out" "$ROOTFS/$rel"
		echo ">> installed as linux/rootfs/$rel (rebuild the kernel to bake it into the initramfs)"
	fi
}
