#!/usr/bin/env bash
# htop 3.3.0 -> linux/rootfs/usr/bin/htop (static, unicode, against the staging ncursesw;
# no unwind/hwloc/sensors/capabilities/delayacct). Needs build_ncurses.sh first.
. "$(dirname "$0")/common.sh"
[ -f "$STAGING/lib/libncursesw.a" ] || die "run build_ncurses.sh first"

pkg_source htop htop-3.3.0 \
	https://github.com/htop-dev/htop/releases/download/3.3.0/htop-3.3.0.tar.xz \
	a69acf9b42ff592c4861010fce7d8006805f0d6ef0e8ee647a6ee6e59b743d5c

./configure --host=$HOST --prefix=/usr --enable-unicode --disable-unwind --disable-hwloc \
	--disable-sensors --disable-capabilities --disable-delayacct \
	CPPFLAGS="-I$STAGING/include -I$STAGING/include/ncursesw" \
	LDFLAGS="-L$STAGING/lib -static" LIBS=-lncursesw >configure.log
make -s -j"$JOBS" >make.log 2>&1
finish_bin htop usr/bin/htop
