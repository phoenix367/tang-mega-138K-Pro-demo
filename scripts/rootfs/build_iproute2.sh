#!/usr/bin/env bash
# iproute2 6.11.0: only misc/nstat -> linux/rootfs/usr/bin/nstat (static). The rest of the
# suite (ip, ss, tc) is busybox's job on this rootfs. iproute2's configure takes the compiler
# from CC and finds none of the optional libs (libmnl, libbpf, libcap, selinux) with the cross
# compiler, which is what we want.
. "$(dirname "$0")/common.sh"

pkg_source iproute2 iproute2-6.11.0 \
	https://www.kernel.org/pub/linux/utils/net/iproute2/iproute2-6.11.0.tar.xz \
	1f795398a04aeaacd06a8f6ace2cfd913c33fa5953ca99daae83bb5c534611c3

#
# Only the top-level Makefile exports the real CFLAGS (.EXPORT_ALL_VARIABLES), so build through
# it with SUBDIRS. musl's headers do not pull in <endian.h> the way glibc's do and
# include/libnetlink.h uses htobe64() without including it: force-include it.
#
# The nstat shipped in the rootfs (June 2026) was compiled by hand from this tree without
# RESOLVE_HOSTNAMES and with CONF_USR_DIR=/usr/lib/iproute2 (neither matters: nstat reads
# /proc/net/{snmp,netstat} and the rootfs has no iproute2 config dir), so this Makefile
# build differs from it by a few KB.
CC=${HOST}-gcc ./configure >configure.log
make -s SUBDIRS="lib misc" CC=${HOST}-gcc AR=${HOST}-ar LDFLAGS=-static \
	CPPFLAGS="-include endian.h" >make.log 2>&1
finish_bin misc/nstat usr/bin/nstat
