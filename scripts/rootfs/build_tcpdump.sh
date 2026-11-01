#!/usr/bin/env bash
# tcpdump 4.99.5 -> linux/rootfs/usr/bin/tcpdump (static, no crypto/smi). Needs build_libpcap.sh
# first: configure finds the staging libpcap through pcap-config on PATH.
. "$(dirname "$0")/common.sh"
[ -x "$STAGING/bin/pcap-config" ] || die "run build_libpcap.sh first"

pkg_source tcpdump tcpdump-4.99.5 \
	https://www.tcpdump.org/release/tcpdump-4.99.5.tar.gz \
	8c75856e00addeeadf70dad67c9ff3dd368536b2b8563abf6854d7c764cd3adb

#
# Setting CFLAGS at configure time replaces autoconf's default "-g -O2", so give -O2 explicitly.
# The tcpdump shipped in the rootfs (June 2026) was configured with CFLAGS="-I<staging>/include"
# only and is therefore an -O0 build; dropping the -O2 below reproduces it byte for byte.
CFLAGS="-O2 -I$STAGING/include" LDFLAGS="-L$STAGING/lib -static" \
	./configure --host=$HOST --prefix=/usr --without-crypto --without-smi \
	ac_cv_lib_pcap_pcap_open_live=yes >configure.log
make -s -j"$JOBS" tcpdump >make.log 2>&1
finish_bin tcpdump usr/bin/tcpdump
