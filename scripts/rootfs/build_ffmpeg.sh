#!/usr/bin/env bash
# FFmpeg 7.1.1, trimmed to what src/apps/vidplay needs -> static libavformat/avcodec/avutil/
# swresample in the staging prefix (no programs: vidplay -b is the benchmark):
#   decoders mjpeg, aac, mp3; demuxers avi, mov/mp4, mp3, matroska, wav; parsers; file protocol.
#   (MJPEG only: intra-only video suits this latency-bound SoC; H.264 was measured at
#   ~12 fps for 480x270 and dropped on 2026-11-04 -- see src/apps/vidplay/README.md)
# Also builds $STAGING/lib/libsoftatomic.a from soft_atomic.c: the libraries are compiled
# with -march=rv32imfdc (no "a"), so their C11 atomics become __atomic_*_4() calls, which
# that shim answers with plain loads and stores (single hart). Link it after libav*.
# Single-threaded (--disable-pthreads), no asm (the A25 has no RVV).
. "$(dirname "$0")/common.sh"

pkg_source ffmpeg ffmpeg-7.1.1 \
	https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz \
	733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1

# -march without "a": GCC lowers every atomic builtin to a libatomic-style call (see above)
# instead of emitting amo/lr/sc.
ARCHFLAGS="-march=rv32imfdc -mabi=ilp32d"
./configure --prefix="$STAGING" --enable-cross-compile --cross-prefix="$CROSS" \
	--arch=riscv --target-os=linux --cc="${CROSS}gcc" --nm="${CROSS}nm" --ar="${CROSS}ar" \
	--extra-cflags="$ARCHFLAGS -O3" --extra-ldflags="$ARCHFLAGS -static" --pkg-config=false \
	--disable-shared --enable-static --disable-pthreads --disable-asm --disable-rvv \
	--disable-doc --disable-network --disable-autodetect --disable-iconv --disable-debug \
	--disable-everything \
	--disable-programs --disable-avfilter \
	--enable-decoder=mjpeg,aac,mp3,mp3float,pcm_s16le \
	--enable-demuxer=avi,mov,mp3,matroska,wav \
	--enable-parser=mjpeg,aac,mpegaudio \
	--enable-protocol=file \
	--enable-swresample --disable-swscale --disable-avdevice --disable-postproc \
	>configure.log 2>&1 || { tail -30 configure.log; die "configure failed (see $SRC/configure.log)"; }
grep -E "^(ARCH|pthreads|stdatomic|atomics|threading)" ffbuild/config.log 2>/dev/null | head -5 || true
make -s -j"$JOBS" >make.log 2>&1 || { tail -30 make.log; die "make failed (see $SRC/make.log)"; }
make -s install >>make.log 2>&1
for lib in libavcodec libavformat libavutil libswresample; do
	check_atomics "$STAGING/lib/$lib.a"
done
"${CROSS}gcc" $ARCHFLAGS -O2 -Wall -c "$ROOTFS_SCRIPTS/soft_atomic.c" -o soft_atomic.o
"${CROSS}ar" rcs "$STAGING/lib/libsoftatomic.a" soft_atomic.o
echo ">> libavformat/avcodec/avutil/swresample + libsoftatomic installed in $STAGING (atomic-free)"
