# tests/Makefile -- build the AE350 userspace diagnostics (static rv32 musl).
#
#   make            build all of them (BINS below)
#   make verify     confirm atomic_test really emits hardware atomics
#   make upload     scp the binaries to the board /tmp  (override BOARD/RUSER)
#   make clean
#
# Override the toolchain with TC=... or CROSS=...; the default is the patched
# soft-atomic musl toolchain used by the rest of the project (TOOLCHAIN, as set in the
# Docker image and by scripts/rootfs/common.sh, else the one in ~/projects).

TC      ?= $(if $(TOOLCHAIN),$(TOOLCHAIN),$(HOME)/projects/riscv32-ilp32d--musl--stable-2025.08-1)
CROSS   ?= $(TC)/bin/riscv32-buildroot-linux-musl-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump

ARCH := -march=rv32imafdc -mabi=ilp32d

BOARD ?= 192.168.200.2
RUSER ?= ae350

BINS := atomic_test memthroughput compute_bench dsp_probe ext_probe amo_probe cctl_probe ddr_memtest fbtest wavplay amotrace dmactest yuvtest idcttest scaletest lcdmon ucsr_test

all: $(BINS)

# -O0: keep the explicit atomic asm + eviction loops predictable
atomic_test: atomic_test.c
	$(CC) -static -O0 $(ARCH) -o $@ $<

# zicbop so __builtin_prefetch emits a real prefetch.r (harmless hint if HW lacks it)
memthroughput: memthroughput.c
	$(CC) -static -O2 -march=rv32imafdc_zicbop -mabi=ilp32d -o $@ $<

# DDR path correctness + per-miss latency / bandwidth (bridge validation)
ddr_memtest: ddr_memtest.c
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

# LCD: CPU CRC of /dev/fb0 vs the video core's CRC of the pixels it sent
fbtest: fbtest.c
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

yuvtest: yuvtest.c ../vidplay/gowin-lcdfb.h
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

# the LCD core's scaler and OSD layer, scene CRCs against a C model
scaletest: scaletest.c ../vidplay/gowin-lcdfb.h
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

# which picture every LCD refresh showed during video playback (frame misses, hitches)
lcdmon: lcdmon.c
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

# the hardware IDCT core against FFmpeg's integer IDCT in C, through a YUV buffer
idcttest: idcttest.c ../vidplay/gowin-lcdfb.h ../vidplay/gowin-idct.h
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

# bus trace of a cold-line LR/SC or AMO through ddr_perf (amo = hangs the CPU,
# the ATCWDT200 is armed first so the SoC resets; then `amotrace dump`)
amotrace: amotrace.c
	$(CC) -static -O1 $(ARCH) -Wall -o $@ $<

# SoC DMAC (ATCDMAC300) probe: m2m copy works; any peripheral/XIP target hangs
# the bus (see doc/06-key-findings.md); arms the watchdog, reload via JTAG if stuck
dmactest: dmactest.c
	$(CC) -static -O1 $(ARCH) -Wall -o $@ $<

# audio: play a WAV through the raw ALSA ioctl API, check the core's FRAMES/CRC
wavplay: wavplay.c
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

# -fno-math-errno + -ffp-contract=fast => hardware fsqrt.d / fmadd.d (not libcalls)
compute_bench: compute_bench.c
	$(CC) -static -O2 $(ARCH) -fno-math-errno -ffp-contract=fast -o $@ $< -lm

# Andes DSP / P-ext via raw .insn (no -march P support needed in the toolchain)
amo_probe: amo_probe.c
	$(CC) -static -O2 $(ARCH) -o $@ $<

ext_probe: ext_probe.c
	$(CC) -static -O2 $(ARCH) -o $@ $<

dsp_probe: dsp_probe.c
	$(CC) -static -O2 $(ARCH) -o $@ $<

# the Andes user CSRs (DSP ucode, CoDense uitb) must be switched per process by the kernel
ucsr_test: ucsr_test.c
	$(CC) -static -O2 $(ARCH) -Wall -o $@ $<

cctl_probe: cctl_probe.c
	$(CC) -static -O2 -o $@ $<

verify: atomic_test
	@echo "atomic_test hardware atomics:"; \
	$(OBJDUMP) -d atomic_test | grep -E '\b(amoadd|lr\.w|sc\.w)\b' | head

upload: $(BINS)
	scp -O $(BINS) $(RUSER)@$(BOARD):/tmp/

clean:
	rm -f $(BINS)

.PHONY: all verify upload clean
