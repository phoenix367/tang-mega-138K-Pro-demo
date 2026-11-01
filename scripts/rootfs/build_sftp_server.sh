#!/usr/bin/env bash
# OpenSSH 9.9p2 sftp-server only -> linux/rootfs/usr/libexec/sftp-server (static; sftp-server
# needs neither OpenSSL nor zlib). Dropbear execs that path for scp/sftp sessions from a
# modern OpenSSH client (dropbear has no SFTP subsystem of its own).
. "$(dirname "$0")/common.sh"

pkg_source openssh openssh-9.9p2 \
	https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz \
	91aadb603e08cc285eddf965e1199d02585fa94d994d6cae5b41e1721e215673

./configure --host=$HOST CC=${CROSS}gcc AR=${CROSS}ar RANLIB=${CROSS}ranlib STRIP=${CROSS}strip \
	--without-openssl --without-zlib --without-pam --disable-strip \
	--libexecdir=/usr/libexec LDFLAGS=-static >configure.log
make -s -j"$JOBS" sftp-server >make.log 2>&1
finish_bin sftp-server usr/libexec/sftp-server
