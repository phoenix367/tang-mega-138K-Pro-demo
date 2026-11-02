# boardcfg/Makefile -- board settings daemon/CLI for the Dock EEPROM, static
# rv32 musl (soft-atomic libc, see doc/02-build.md).
#
#   make            build boardcfg
#   make install    copy it into linux/rootfs/usr/sbin
#   make clean

TC     ?= $(if $(TOOLCHAIN),$(TOOLCHAIN),$(HOME)/projects/riscv32-ilp32d--musl--stable-2025.08-1)
CROSS  ?= $(TC)/bin/riscv32-buildroot-linux-musl-
CC     := $(CROSS)gcc
ROOTFS ?= ../../../linux/rootfs

ARCH   := -march=rv32imafdc -mabi=ilp32d
CFLAGS := -static $(ARCH) -O2 -Wall -Wextra -Wno-unused-parameter
LDFLAGS := -static $(ARCH) -s

all: boardcfg

boardcfg: boardcfg.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: boardcfg
	install -m 0755 boardcfg $(ROOTFS)/usr/sbin/boardcfg

clean:
	rm -f boardcfg

.PHONY: all install clean
