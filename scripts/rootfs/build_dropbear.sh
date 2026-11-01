#!/usr/bin/env bash
# Dropbear 2022.83 -> linux/rootfs/usr/bin/dropbearmulti (static, no zlib): one multi-call
# binary for dropbear, dbclient, dropbearkey, dropbearconvert and scp; the rootfs holds those
# names as symlinks plus an /usr/bin/ssh shim ("ssh" is not a dropbear multi name). The host
# keys in linux/rootfs/etc/dropbear/ are baked in, not generated on the board.
. "$(dirname "$0")/common.sh"

pkg_source dropbear dropbear-2022.83 \
	https://matt.ucc.asn.au/dropbear/releases/dropbear-2022.83.tar.bz2 \
	bc5a121ffbc94b5171ad5ebe01be42746d50aa797c9549a4639894a16749443b

./configure --host=$HOST --disable-zlib --enable-static >configure.log
make -s -j"$JOBS" PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" MULTI=1 >make.log 2>&1
finish_bin dropbearmulti usr/bin/dropbearmulti
