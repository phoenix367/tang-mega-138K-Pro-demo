#!/usr/bin/env bash
# OpenDoas 6.8.2 -> linux/rootfs/usr/bin/doas (static, shadow auth, persist timestamps; busybox
# has no sudo/doas). Config is linux/rootfs/etc/doas.conf; rcS must chown 0:0 + chmod 4755
# the binary because the initramfs carries the build host's uid.
. "$(dirname "$0")/common.sh"

pkg_source doas opendoas-6.8.2 \
	https://github.com/Duncaen/OpenDoas/releases/download/v6.8.2/opendoas-6.8.2.tar.xz \
	4e98828056d6266bd8f2c93e6ecf12a63a71dbfd70a5ea99ccd4ab6d0745adf0

CC=${HOST}-gcc ./configure --without-pam --with-timestamp >configure.log
make -s CC=${HOST}-gcc CFLAGS=-static LDFLAGS=-static >make.log 2>&1
finish_bin doas usr/bin/doas
