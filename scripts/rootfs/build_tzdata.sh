#!/usr/bin/env bash
# IANA tzdata -> linux/rootfs/usr/share/zoneinfo (slim TZif files for the zone1970.tab
# zones + Etc/UTC, plus zone1970.tab itself, which the desktop's Date & Time panel reads
# for its region / city lists). musl reads /etc/localtime or $TZ=<zone name> from
# /usr/share/zoneinfo; the panel copies the chosen file to /etc/localtime.
#
# ~200 KB uncompressed for 313 zones; compiled with the host's zic (libc-bin).
. "$(dirname "$0")/common.sh"
command -v zic >/dev/null || die "zic not found (Debian: libc-bin)"

TZ_VER=2026e
TZ_URL="https://data.iana.org/time-zones/releases/tzdata${TZ_VER}.tar.gz"
TZ_SHA256=b26882805f26aac59d5b222978e6580484b834ccdc98be89df2f05a6dc53a652
# not pkg_source: the tarball has no top-level directory, so extract it into one by hand
PKGDIR="$PKGROOT/tzdata"; SRC="$PKGDIR/tzdata-$TZ_VER"; f="$PKGDIR/$(basename "$TZ_URL")"
mkdir -p "$PKGDIR"
if [ ! -f "$f" ] || ! echo "$TZ_SHA256  $f" | sha256sum -c --quiet - 2>/dev/null; then
	echo ">> downloading $(basename "$TZ_URL")"; curl -fsSL --retry 3 -o "$f" "$TZ_URL"
fi
echo "$TZ_SHA256  $f" | sha256sum -c --quiet - || die "checksum mismatch: $f"
[ "${FRESH:-0}" = 1 ] && rm -rf "$SRC"
if [ ! -d "$SRC" ]; then mkdir -p "$SRC"; tar xzf "$f" -C "$SRC"; fi
OUT="$PKGDIR/zoneinfo"
rm -rf "$OUT"; mkdir -p "$OUT"
(cd "$SRC" && zic -b slim -d "$OUT" africa antarctica asia australasia europe northamerica southamerica etcetera)

# keep the canonical zones only (one file per zone1970.tab line) + Etc/UTC
keep="$PKGDIR/zones.txt"
{ echo Etc/UTC; grep -v '^#' "$SRC/zone1970.tab" | cut -f3; } > "$keep"
mkdir -p "$PKGDIR/zoneinfo.keep"
while read -r z; do
	[ -f "$OUT/$z" ] || die "zic produced no $z"
	mkdir -p "$PKGDIR/zoneinfo.keep/$(dirname "$z")"
	cp -p "$OUT/$z" "$PKGDIR/zoneinfo.keep/$z"
done < "$keep"
cp -p "$SRC/zone1970.tab" "$PKGDIR/zoneinfo.keep/"
rm -rf "$OUT"; mv "$PKGDIR/zoneinfo.keep" "$OUT"
n=$(find "$OUT" -type f | wc -l); sz=$(du -sb "$OUT" | cut -f1)
echo ">> $OUT: $n files, $sz bytes (tzdata $TZ_VER, slim)"

if [ "${INSTALL:-0}" = 1 ]; then
	rm -rf "$ROOTFS/usr/share/zoneinfo"
	mkdir -p "$ROOTFS/usr/share"
	cp -rp "$OUT" "$ROOTFS/usr/share/zoneinfo"
	echo ">> installed as linux/rootfs/usr/share/zoneinfo (rebuild the kernel to bake it into the initramfs)"
fi
