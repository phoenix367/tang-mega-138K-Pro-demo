# desktop/Makefile -- LVGL desktop (lvdesk) + network input bridge (inputd)
# for the AE350 board, static rv32 musl (soft-atomic libc, see doc/02-build.md).
#
#   make            build inputd + lvdesk (LVGL compiled from LVGL_DIR)
#   make install    copy the binaries + wavplay into linux/rootfs/usr/bin
#   make clean
#
# LVGL sources live outside the repo (CLAUDE.md "Linux userspace sources"):
#   ~/projects/ae350_linux_user_level/lvgl/lvgl-<ver>/

# Bootlin musl toolchain with the soft-atomic libc.a; TOOLCHAIN is what the Docker image
# and scripts/rootfs/common.sh use, TC the older name
TC       ?= $(if $(TOOLCHAIN),$(TOOLCHAIN),$(HOME)/projects/riscv32-ilp32d--musl--stable-2025.08-1)
CROSS    ?= $(TC)/bin/riscv32-buildroot-linux-musl-
CC       := $(CROSS)gcc
AR       := $(CROSS)ar
LVGL_DIR ?= $(HOME)/projects/ae350_linux_user_level/lvgl/lvgl-9.6.0
ROOTFS   ?= ../../../linux/rootfs

ARCH   := -march=rv32imafdc -mabi=ilp32d
OPT    := -O2 -fno-strict-aliasing -ffunction-sections -fdata-sections
CFLAGS := -static $(ARCH) $(OPT) -Wall -Wno-unused-function \
          -DLV_CONF_INCLUDE_SIMPLE -I. -I$(LVGL_DIR)/include/lvgl -I$(LVGL_DIR)/include -I$(LVGL_DIR)
LDFLAGS := -static $(ARCH) -Wl,--gc-sections -s

BUILD := build

LV_SRC  := $(shell find $(LVGL_DIR)/src -name '*.c') \
           $(shell find $(LVGL_DIR)/demos/widgets -name '*.c') \
           $(LVGL_DIR)/demos/lv_demos.c
LV_OBJ  := $(patsubst $(LVGL_DIR)/%.c,$(BUILD)/lvgl/%.o,$(LV_SRC))
APP_SRC := $(wildcard lvdesk/*.c)
APP_OBJ := $(patsubst lvdesk/%.c,$(BUILD)/app/%.o,$(APP_SRC))

all: inputd $(BUILD)/lvdesk

inputd: inputd.c
	$(CC) -static $(ARCH) -O2 -Wall -s -o $@ $<

$(BUILD)/liblvgl.a: $(LV_OBJ)
	@mkdir -p $(dir $@)
	@$(AR) rcs $@ $^

$(BUILD)/lvgl/%.o: $(LVGL_DIR)/%.c lv_conf.h
	@mkdir -p $(dir $@)
	@$(CC) $(CFLAGS) -Os -Wno-unused-variable -Wno-format -c -o $@ $<

$(BUILD)/app/%.o: lvdesk/%.c lv_conf.h $(wildcard lvdesk/*.h)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wno-deprecated-declarations -Ilvdesk -c -o $@ $<

$(BUILD)/lvdesk: $(APP_OBJ) $(BUILD)/liblvgl.a
	$(CC) $(LDFLAGS) -o $@ $(APP_OBJ) $(BUILD)/liblvgl.a -lm
	@echo "hardware atomics in lvdesk (must be 0): $$($(CROSS)objdump -d $@ | /usr/bin/grep -cE '\b(amo[a-z.]+|lr\.w|sc\.w)\b')"

install: all
	install -m 755 -s --strip-program=$(CROSS)strip inputd $(BUILD)/lvdesk ../tests/wavplay $(ROOTFS)/usr/bin/
	install -m 755 rootfs/S45sdcard rootfs/S60inputd rootfs/S70desktop rootfs/S80fan $(ROOTFS)/etc/init.d/

clean:
	rm -rf $(BUILD) inputd

.PHONY: all install clean
