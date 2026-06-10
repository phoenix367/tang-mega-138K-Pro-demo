# Test firmware for the AE350 SoC (Tang Mega 138K Pro Dock), XIP build.
#
# Toolchain: the RISC-V GCC that ships with Xilinx Vitis works (rv32 multilib).
# Override CROSS / GCC_DIR if yours lives elsewhere.
#
#   make            - build ELF + .bin + .lst + size
#   make clean
#
# Flash the resulting build/ae350_fw.bin to the board's SPI flash so the
# AE350 boots it (see README.md).

GCC_DIR ?= /mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin
CROSS   ?= $(GCC_DIR)/riscv64-unknown-elf-

CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE    := $(CROSS)size

TARGET  := ae350_fw
BUILD   := build
SRCDIR  := src
BSP     := $(SRCDIR)/bsp

# rv32imac + zicsr/zifencei (GCC 13 split the CSR/fence extensions out).
ARCH    := -march=rv32imac_zicsr_zifencei -mabi=ilp32 -mcmodel=medany

INCLUDES := \
	-I$(SRCDIR) \
	-I$(BSP)/config \
	-I$(BSP)/ae350 \
	-I$(BSP)/lib \
	-I$(BSP)/driver/include

# XIP linker script (boot + run from SPI flash @ 0x80000000, data in DDR3).
LDSCRIPT := $(BSP)/sag/ae350-xip.ld

# REF_TEST_CLK selects the 50 MHz "test" clock in the BSP (ae350.h). This board's
# AE350 runs AHB/APB/UART at 50 MHz; without it the BSP assumes 100 MHz and every
# UART baud comes out at half (measured: 115200 -> 57600 on the wire).
CFLAGS  := $(ARCH) -DREF_TEST_CLK -Os -g3 -ffunction-sections -fdata-sections \
	-fno-builtin-printf -Wall -Wextra $(INCLUDES)
ASFLAGS := $(ARCH) $(INCLUDES)
LDFLAGS := $(ARCH) -nostartfiles -T $(LDSCRIPT) \
	-Wl,--gc-sections -Wl,-Map,$(BUILD)/$(TARGET).map

# Sources: startup + BSP runtime + console lib + GPIO driver + our main.
CSRCS := \
	$(SRCDIR)/main.c \
	$(SRCDIR)/puff.c \
	$(wildcard $(BSP)/ae350/*.c) \
	$(wildcard $(BSP)/lib/*.c) \
	$(BSP)/driver/ae350/gpio_ae350.c
SSRCS := $(BSP)/ae350/start.S

OBJS := $(addprefix $(BUILD)/,$(CSRCS:.c=.o) $(SSRCS:.S=.o))

.PHONY: all clean
all: $(BUILD)/$(TARGET).bin

$(BUILD)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: %.S
	@mkdir -p $(dir $@)
	$(CC) $(ASFLAGS) -c $< -o $@

$(BUILD)/$(TARGET).elf: $(OBJS)
	$(CC) $(OBJS) $(LDFLAGS) -o $@
	$(SIZE) $@

$(BUILD)/$(TARGET).bin: $(BUILD)/$(TARGET).elf
	$(OBJCOPY) -O binary $< $@
	$(OBJDUMP) -d $< > $(BUILD)/$(TARGET).lst
	@echo "Built $@"

clean:
	rm -rf $(BUILD)
