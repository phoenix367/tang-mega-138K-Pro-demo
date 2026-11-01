#!/usr/bin/env bash
# ncurses 6.6, static wide-char libs into $STAGING for htop. No terminfo database on the
# board: the terminal descriptions htop needs are compiled in as fallbacks (needs the host's
# tic/infocmp, package ncurses-bin).
. "$(dirname "$0")/common.sh"

pkg_source ncurses ncurses-6.6 \
	https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz \
	355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11

./configure --host=$HOST --build=x86_64-linux-gnu --prefix="$STAGING" \
	--without-shared --without-debug --without-cxx-binding --without-ada \
	--enable-widec --disable-database \
	--with-fallbacks=linux,vt100,vt220,xterm,xterm-256color,screen \
	--without-manpages --without-tests --with-build-cc=gcc >configure.log
make -s -j"$JOBS" >make.log 2>&1
make -s install.libs install.includes >install.log 2>&1   # no programs (tic/infocmp are host tools here)
echo ">> installed libncursesw.a + headers into $STAGING"
