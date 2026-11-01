# Build the bare-metal bootm payload and wrap it as a U-Boot 'standalone' image.
#
#   make            -> payload.bin + payload.img (the bootm image)
#   make clean
#
# Flash payload.img to SPI flash 0x800000 (= CPU 0x80200000), then in U-Boot:
#   bootm 0x80200000

# Andes bare-metal GCC (nds32le-elf-newlib-v5) under ANDES_ROOT; override CROSS for another.
ANDES_ROOT ?= /mnt/data/toolchains
CROSS      ?= $(ANDES_ROOT)/nds32le-elf-newlib-v5/bin/riscv32-elf-
# U-Boot's mkimage (built in the U-Boot submodule); override if elsewhere.
MKIMAGE ?= ../../../external/u-boot/tools/mkimage

CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy

LOAD    := 0x00100000          # DRAM load + entry address (matches payload.ld)
# -mno-save-restore: this is linked -nostdlib, and the Andes GCC would otherwise emit
# calls to libgcc's __riscv_save_*/__riscv_restore_* prologue helpers.
ARCH    := -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany -mno-save-restore
CFLAGS  := $(ARCH) -Os -ffreestanding -nostdlib -fno-pic -Wall -Wextra \
	-fno-asynchronous-unwind-tables -fno-unwind-tables -Wl,--build-id=none

all: payload.img

payload.elf: payload.c payload.ld
	$(CC) $(CFLAGS) -T payload.ld payload.c -o payload.elf

payload.bin: payload.elf
	$(OBJCOPY) -O binary payload.elf payload.bin

payload.img: payload.bin
	$(MKIMAGE) -A riscv -O u-boot -T standalone -C none \
		-a $(LOAD) -e $(LOAD) -n "ae350-bootm-payload" \
		-d payload.bin payload.img

clean:
	rm -f payload.elf payload.bin payload.img
