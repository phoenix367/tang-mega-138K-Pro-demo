#!/usr/bin/env bash
# libpcap 1.10.5, static, into $STAGING for tcpdump (no libnl/dbus/usb/bluetooth/rdma/netmap).
. "$(dirname "$0")/common.sh"

pkg_source libpcap libpcap-1.10.5 \
	https://www.tcpdump.org/release/libpcap-1.10.5.tar.gz \
	37ced90a19a302a7f32e458224a00c365c117905c2cd35ac544b6880a81488f0

./configure --host=$HOST --prefix="$STAGING" --disable-shared --enable-static \
	--without-libnl --disable-dbus --disable-rdma --disable-bluetooth --disable-usb \
	--disable-netmap >configure.log
make -s -j"$JOBS" >make.log 2>&1
make -s install >install.log 2>&1
echo ">> installed libpcap.a + headers + pcap-config into $STAGING"
