#!/usr/bin/env bash
# Reproduce the soft-atomic rv32 musl toolchain used for every binary in linux/rootfs/.
#
# The toolchain is the stock Bootlin "riscv32-ilp32d--musl--stable-2025.08-1" release
# (GCC 14.3.0, binutils 2.43.1, musl 1.2.5, hard-float ilp32d) with ONE file replaced:
# sysroot/lib/libc.a, rebuilt from musl 1.2.5 + PATCHES/0012-musl-riscv32-soft-atomics.patch
# so that it contains no lr/sc/amo instructions (the AE350 here has no coherency manager,
# see doc/06-key-findings.md). Only static linking is covered: libc.so is left stock, and
# the rootfs has no dynamically linked binaries.
#
# Usage:
#   scripts/build_musl_toolchain.sh [DEST]          # default DEST: ~/projects/<release name>
#
# Environment:
#   WORK      scratch dir for downloads and the musl build (default: mktemp -d, removed
#             on success; set it to keep the tarballs between runs)
#   KEEP_WORK=1  keep WORK even on success
#
# Behaviour:
#   - DEST missing: download + verify the Bootlin tarball, unpack it as DEST, relocate it.
#   - DEST present: reuse it (the stock libc.a is kept as libc.a.orig on first run).
#   - Then download + verify musl 1.2.5, apply the patch, build lib/libc.a with DEST's own
#     compiler and musl's default flags, install it as a deterministic archive and check
#     that it contains zero lr/sc/amo instructions.
set -euo pipefail

RELEASE=riscv32-ilp32d--musl--stable-2025.08-1
TRIPLE=riscv32-buildroot-linux-musl
BOOTLIN_URL="https://toolchains.bootlin.com/downloads/releases/toolchains/riscv32-ilp32d/tarballs/${RELEASE}.tar.xz"
BOOTLIN_SHA256=f15e9ed67724b249eb149126eb6ed945648c3cdcd3c1c484b23c1a12df368391
MUSL_VER=1.2.5
MUSL_URL="https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
MUSL_SHA256=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4

HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/../PATCHES/0012-musl-riscv32-soft-atomics.patch"
DEST=${1:-"$HOME/projects/$RELEASE"}
DEST=$(readlink -m "$DEST")

if [ -n "${WORK:-}" ]; then
	mkdir -p "$WORK"; CLEAN_WORK=0
else
	WORK=$(mktemp -d); CLEAN_WORK=1
fi
[ "${KEEP_WORK:-0}" = 1 ] && CLEAN_WORK=0

fetch() {	# fetch URL SHA256 -> file in WORK (skipped if already present and valid)
	local url=$1 sha=$2 f="$WORK/$(basename "$1")"
	if [ ! -f "$f" ] || ! echo "$sha  $f" | sha256sum -c --quiet - 2>/dev/null; then
		echo ">> downloading $(basename "$url")"
		curl -fsSL --retry 3 -o "$f" "$url"
	fi
	echo "$sha  $f" | sha256sum -c --quiet - || { echo "checksum mismatch: $f" >&2; exit 1; }
	echo "$f"
}

[ -f "$PATCH" ] || { echo "patch not found: $PATCH" >&2; exit 1; }

# 1. Toolchain
if [ ! -x "$DEST/bin/${TRIPLE}-gcc" ]; then
	[ -e "$DEST" ] && { echo "$DEST exists but has no ${TRIPLE}-gcc; refusing" >&2; exit 1; }
	TARBALL=$(fetch "$BOOTLIN_URL" "$BOOTLIN_SHA256")
	echo ">> unpacking toolchain into $DEST"
	mkdir -p "$(dirname "$DEST")"
	tmp=$(mktemp -d "$(dirname "$DEST")/.${RELEASE}.XXXXXX")
	tar xJf "$TARBALL" -C "$tmp"
	mv "$tmp/$RELEASE" "$DEST"; rmdir "$tmp"
	(cd "$DEST" && ./relocate-sdk.sh >/dev/null)
fi
CROSS="$DEST/bin/${TRIPLE}-"
LIBDIR="$DEST/$TRIPLE/sysroot/lib"
"${CROSS}gcc" --version | head -1

# 2. musl with soft atomics
MUSL_TGZ=$(fetch "$MUSL_URL" "$MUSL_SHA256")
rm -rf "$WORK/musl-$MUSL_VER"
tar xzf "$MUSL_TGZ" -C "$WORK"
cd "$WORK/musl-$MUSL_VER"
patch -p1 -s < "$PATCH"
echo ">> building libc.a"
CC="${CROSS}gcc" ./configure --target=riscv32 --prefix=/usr --disable-shared --disable-gcc-wrapper >configure.log
make -s -j"$(nproc)" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" lib/libc.a >make.log 2>&1

# deterministic archive (zeroed member timestamps/uids; objcopy keeps the members that
# share a basename -- clone.lo, free.lo, realloc.lo -- which an extract/repack would lose)
"${CROSS}objcopy" --enable-deterministic-archives lib/libc.a lib/libc.a.det

n=$("${CROSS}objdump" -d lib/libc.a.det | grep -cE '\b(amo[a-z.]+|lr\.w|sc\.w)\b' || true)
[ "$n" = 0 ] || { echo "rebuilt libc.a still has $n lr/sc/amo instructions" >&2; exit 1; }

# 3. Install
[ -f "$LIBDIR/libc.a.orig" ] || cp -p "$LIBDIR/libc.a" "$LIBDIR/libc.a.orig"
install -m 644 lib/libc.a.det "$LIBDIR/libc.a"
echo ">> installed $LIBDIR/libc.a ($(stat -c %s "$LIBDIR/libc.a") bytes, 0 lr/sc/amo); stock copy in libc.a.orig"

cd /
[ "$CLEAN_WORK" = 1 ] && rm -rf "$WORK"
echo "done: $DEST"
