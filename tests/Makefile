# tests/Makefile -- build the AE350 userspace diagnostics (static rv32 musl).
#
#   make            build all four
#   make verify     confirm atomic_test really emits hardware atomics
#   make upload     scp the binaries to the board /tmp  (override BOARD/RUSER)
#   make clean
#
# Override the toolchain with TC=... or CROSS=...; the default is the patched
# soft-atomic musl toolchain used by the rest of the project.

TC      ?= $(HOME)/projects/riscv32-ilp32d--musl--stable-2025.08-1
CROSS   ?= $(TC)/bin/riscv32-buildroot-linux-musl-
CC      := $(CROSS)gcc
OBJDUMP := $(CROSS)objdump

ARCH := -march=rv32imafdc -mabi=ilp32d

BOARD ?= 192.168.200.2
RUSER ?= ae350

BINS := atomic_test memthroughput compute_bench dsp_probe ext_probe amo_probe cctl_probe ddr_memtest

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
