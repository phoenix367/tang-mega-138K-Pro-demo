# vidplay/Makefile -- MJPEG AVI / MP3 player (MJPEG + AAC/MP3 through the trimmed static FFmpeg
# from scripts/rootfs/build_ffmpeg.sh), static rv32 musl (soft-atomic libc, doc/02-build.md).
#
#   make            build vidplay (needs the staging libav*: scripts/rootfs/build_ffmpeg.sh)
#   make install    copy it into linux/rootfs/usr/bin
#   make clean

TC      ?= $(if $(TOOLCHAIN),$(TOOLCHAIN),$(HOME)/projects/riscv32-ilp32d--musl--stable-2025.08-1)
CROSS   ?= $(TC)/bin/riscv32-buildroot-linux-musl-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump
STAGING ?= $(HOME)/projects/ae350_linux_user_level/staging
ROOTFS  ?= ../../../linux/rootfs
# idct_dsp.c uses the Andes DSP extension, which only the Andes GCC knows (-mext-dsp);
# its object links fine into the musl binary (same ilp32d ABI; no libc, no unwind tables)
ANDES_ROOT ?= /mnt/data/toolchains
ANDES_CC   ?= $(ANDES_ROOT)/nds32le-linux-glibc-v5d/bin/riscv32-linux-gcc

ARCH    := -march=rv32imafdc -mabi=ilp32d
CFLAGS  := -static $(ARCH) -O2 -Wall -Wextra -Wno-unused-parameter -I$(STAGING)/include
LDFLAGS := -static $(ARCH) -s -L$(STAGING)/lib
LIBS    := -lavformat -lavcodec -lswresample -lavutil -lsoftatomic -lm
# the DSP IDCT replaces FFmpeg's C one for every caller; the FFmpeg tree stays unmodified
WRAP    := -Wl,--wrap=ff_simple_idct_put_int16_8bit

all: vidplay

idct_dsp.o: idct_dsp.c
	$(ANDES_CC) -march=rv32imafdc -mabi=ilp32d -mext-dsp -mno-relax -O3 -mtune=andes-25-series \
	    -funroll-loops -fschedule-insns -fsched-pressure -ffreestanding -fno-builtin \
	    -fno-asynchronous-unwind-tables -fno-unwind-tables -Wall -c -o $@ $<

# unstripped copy for -P profiles (resolve the PC samples with $(CROSS)nm -n vidplay.prof)
idct_hw.o: idct_hw.c idct_hw.h gowin-idct.h gowin-lcdfb.h
	$(CC) $(CFLAGS) -c -o $@ $<

jpeg_hw.o: jpeg_hw.c jpeg_hw.h idct_hw.h gowin-idct.h
	$(CC) $(CFLAGS) -c -o $@ $<

osd.o: osd.c osd.h osd_font.h gowin-lcdfb.h
	$(CC) $(CFLAGS) -c -o $@ $<

# the OSD font (needs Pillow and DejaVu; the generated header is in the repo)
font:
	python3 mkfont.py > osd_font.h

vidplay.prof: vidplay.c idct_dsp.o idct_hw.o jpeg_hw.o osd.o $(STAGING)/lib/libavcodec.a
	$(CC) $(filter-out -s,$(CFLAGS)) -o $@ $< idct_dsp.o idct_hw.o jpeg_hw.o osd.o $(filter-out -s,$(LDFLAGS)) $(WRAP) $(LIBS)

vidplay: vidplay.c idct_hw.h jpeg_hw.h osd.h idct_dsp.o idct_hw.o jpeg_hw.o osd.o $(STAGING)/lib/libavcodec.a
	$(CC) $(CFLAGS) -o $@ $< idct_dsp.o idct_hw.o jpeg_hw.o osd.o $(LDFLAGS) $(WRAP) $(LIBS)
	@n=$$($(OBJDUMP) -d $@ | grep -cE '\b(amo[a-z.]+|lr\.w|sc\.w)\b' || true); \
	 [ "$$n" = 0 ] || { echo "error: vidplay contains $$n lr/sc/amo instructions"; exit 1; }; \
	 echo ">> vidplay: $$(stat -c %s $@) bytes, static, 0 lr/sc/amo"

install: vidplay
	install -m 0755 vidplay $(ROOTFS)/usr/bin/vidplay

clean:
	rm -f vidplay vidplay.prof idct_dsp.o idct_hw.o jpeg_hw.o osd.o

.PHONY: all install clean font
