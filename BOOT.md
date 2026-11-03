# Booting Linux on the Gowin AE350 (Tang Mega 138K Pro)

A full RISC-V Linux (kernel 6.12, rv32, busybox) boots to an interactive shell on
the Gowin AE350 (Andes A25) hard SoC, **despite the SoC having no coherence
manager** (hardware atomics hang on a DRAM cache-miss — see `CACHE_ISSUES.md`).
The trick is **single-hart soft atomics** (interrupt-disable RMW) in both OpenSBI
and the kernel, plus a UP kernel.

```
OpenSBI v1.8 (soft atomics) @ DRAM 0x0
        |
        v  (S-mode)
Linux 6.12 (soft atomics, CONFIG_SMP=n) @ DRAM 0x400000  + busybox initramfs
```

Boot is **automatic** (U-Boot `bootcmd`) and from **flash only** (no SD): ~24 s to a shell.

---

## Flash layout (16 MB SPI flash; XIP base 0x80000000 = flash offset 0x600000)

| Flash offset | XIP addr   | Contents                                  |
|--------------|------------|-------------------------------------------|
| `0x000000`   | —          | FPGA bitstream (binary ~4.9 MB, ends `0x4DCB00`); **Build 67** (2026-11-03: Build 66 + `PULL_MODE=UP` on `UART2_RXD` A17 so an unplugged console adapter leaves the line idle-high; timing unchanged, 0 negative slack); `MODE=flash scripts/gw_program.sh`. **Build 66** (2026-11-02, in flash, ends `0x4DCB00`): Build 65 + `src/rtl/gpio/` board-control register block on EXTS `0xE8010000` (`HADDR[16]`; the Dock's `SYS_TWI` I2C bus K25/K26, its 74HC4051 TWI mux select N19/P19/P26 and the ZD24C08A EEPROM write protect V14, all tri-state); all clocks met (ahb_clk 64.0 MHz, ddr3_sysclk 100.16, rgmii_rxclk 134.4). Build 65 (2026-11-01, ends `0x4E4700`): Build 64 + the DDR3 IP's 50 MHz reference input taken from the board clock (DDR3 PLL CLKOUT0 unused: 3 → 2 generated 50 MHz clocks; `APB_CLK` must keep its own PLL output, fed from the AHB_CLK net the PLIC drops audio interrupt completions), the 16 global clock wires pinned in the `.cst` (`CLOCK_LOC`; the RGMII RX clock must stay on an LW wire, on a PRIMARY one gigabit RX breaks), bridge statistics counters as `pipe_counter`; all clocks met (ddr3_sysclk 100.11 MHz, ahb_clk 54.9, rgmii_rxclk 125.3), same read-wait numbers as Build 64. Build 64 (2026-11-01): Build 63 + the SoC's `DDR_CLK` driven by the DDR3 IP user clock, so the DDR bridge is single-clock and its FIFOs hand pointers across without synchronizers (`SYNC_CLK=1`); average read wait per data-memory transfer 19.6–20.0 → 17.9–18.5 HCLK; all clocks met (ddr3_sysclk 100.12 MHz, ahb_clk 53.5). Build 63 (2026-10-31, timing): Build 62 + two-stage audio DMA command sizing, sdhost FIFO in BSRAM, `src/rtl/pipe_counter.v` for the ddr_perf/BIST counters, EXTS reads through a register with one wait state; every clock meets with margin (ahb_clk 58.0 MHz, ddr_clk 100.01, ddr3_sysclk 101.0), 8k fewer flops, 4.3k fewer LUTs; per-path reports for ahb_clk/ddr3_sysclk added to the SDC. Build 62 (2026-10-30): Build 61 + audio DMA fetch engine (`src/rtl/audio/`, 64-bit read master on the EXTM arbiter's 4th port `src/rtl/audio/rtl/ahb_arbiter4.v`, ring buffer up to a driver-committed DMA_LIMIT, period/error IRQ bits); PnR Place_Option 2 + Route_Option 0 (Route_Option 2 now aborts the router with PR0004, Place 0/1 miss ddr_clk by 1 ns). Build 61 (2026-10-30): Build 57 (LCD + 1 GB DDR + PT8211 audio + sensor + fan cores, registered-predicted-beat bridge) + native 4-bit microSD host with DMA (`src/rtl/sdhost/`, EXTS 0xE8020000, arbiter master 2, EXT_INT[2], late input sampling; replaces Build 59's SPI-mode core); PnR Place_Option 2 (3 aborts the router on this netlist) |
| `0x600000`   | `0x80000000` | U-Boot (XIP, with appended DTB @0xf0000); since 2026-11-03 built with `CONFIG_AUTOBOOT_KEYED` + `AUTOBOOT_STOP_STR="uboot"` so UART noise cannot stop the autoboot (not `AUTOBOOT_FLUSH_STDIN`: its drain loop never ends on a line that delivers continuous garbage) |
| `0x800000`   | `0x80200000` | `fw_payload_lzma.bin` (OpenSBI+kernel+DTB, LZMA since 2026-11-02; gzip before); **kernel #75** (2026-11-03; build string #97; LZMA payload 6.45 MB; #74 + network settings in the EEPROM: `boardcfg` keys `net` (dhcp|static), `ip`, `gateway`, `dns`, `S40network` configures eth0 from them (busybox `udhcpc` + `/usr/share/udhcpc/default.script` for DHCP) and the daemon re-runs it on change, lvdesk Network panel shows mode/gateway/real prefix and gets a Configure dialog for all of it, status-bar CPU% no longer reads 0/100 with a panel open, boardcfg EEPROM writes read/verify only the written bytes); #74 (2026-11-02; build string #93; LZMA payload 6.44 MB; #73 + `boardcfg` settings daemon (`src/apps/boardcfg/`, `/usr/sbin/boardcfg`, `S35boardcfg`: EEPROM-backed mac/hostname/tz/free keys), DT nvmem cell `eth_mac` @0x110 on the EEPROM + `gw-tse` probe deferral so eth0 boots with the stored MAC, lvdesk Date & Time persists the zone through boardcfg); #73 (2026-11-02; build string #92; LZMA payload 6.43 MB; #72 + the board EEPROM stack: DT `gpio@e8010000` (gpio-mmio) + `i2c-sys` (i2c-gpio) + `i2c-mux` (i2c-mux-gpio, idle on the EEPROM channel) + `eeprom@50` (at24, `wp-gpios`), defconfig I2C_GPIO/I2C_MUX_GPIO/GPIO_GENERIC_PLATFORM/EEPROM_AT24/I2C_CHARDEV; needs Build 66); #72 (2026-11-02; payload 7.52 MB; #71 config, rootfs with the lvdesk wired-network icon + cable-unplug detection and the fan icon; first image built with the Andes `nds32le-linux-glibc-v5d` toolchain, `external/linux` @ 56473dac8); #71 (2026-10-30; payload 7.32 MB; #68 + gowin-pt8211 DMA mode (`PATCHES/0007`: CAP[0] cores use a contiguous streaming-mapped ALSA buffer read by the core, `.ack` cleans the cache + writes DMA_LIMIT, DRAIN trigger sets stop-when-empty, `pio=1` sysfs switch for the old interrupt-fill mode, serialiser enabled only after the first fetch; #69/#70 = earlier DMA kernels with start/tail underruns); #68 = #66 + desktop microSD mount/unmount row, inputd send timeouts; #66 = #64 + gowin-sdhost MMC host (`PATCHES/0011`, DT `mmc@e8020000`, PLIC 12) with clock/phase tuning for the native SD host; #64 = #61 + spi-gowin + mmc_spi (`PATCHES/0010`, `S45sdcard` → /mnt/sd, vfat charsets built in); #61 = #60 + fan status-bar indicator, XZ initramfs — the region ends at 0x1000000, keep it under 8 MB): #59 (#57 + evdev/uinput) + hwmon gowin-fan (`PATCHES/0009`, DT `fan0`) + `S80fan` temperature curve; #59 = #57 (ALSA PT8211, hwmon gowin-adc, sftp-server) + evdev/uinput for the network input bridge (`inputd`) and the LVGL desktop (`lvdesk` on VT 1, no getty on tty1); `console=tty0` still prints boot messages on the LCD |

U-Boot auto-runs (`CONFIG_BOOTCOMMAND`): `lzmadec 0x80200000 0 0x2000000; sdboot 0`
— LZMA-decompresses the ~6.4 MB image into DRAM `0x0` (OpenSBI @0x0, kernel @0x400000;
~9 s on the A25, gzip took 4 s) and jumps.

---

## Build

Toolchains:
- Linux/kernel/OpenSBI: `LGNU=/mnt/data/toolchains/nds32le-linux-glibc-v5d/bin/riscv32-linux-`
- busybox initramfs: `riscv32-buildroot-linux-musl-` (prebuilt rootfs in `linux/rootfs/`;
  busybox config `linux/busybox.config`; every rootfs binary is rebuilt by `scripts/rootfs/`)
- `GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux`

### 1. Kernel (UP + soft atomics)
Key config: `CONFIG_SMP=n` (UP — avoids qspinlock, which deadlocks with soft atomics),
heavy debug off (`DEBUG_VM_PGTABLE`, `DEBUG_SPINLOCK`, lockdep, RCU-debug),
`CONFIG_INITRAMFS_SOURCE="…/linux/rootfs …/linux/initramfs_nodes.list"` (the second
entry adds the static `/dev/console`,`/dev/kmsg` nodes the kernel needs before init).
Soft-atomic patches: `arch/riscv/include/asm/{soft_atomic.h,cmpxchg.h,atomic.h,bitops.h,futex.h}`.
A25 page-table writeback (`PATCHES/0005`, `asm/a25-ptwb.h`) is required with the fast
DDR bridge (gateware MODE 0x10000): without it fork/exec oopses.
```
# paths relative to the repo root; the trees are submodules (git submodule update --init)
cd external/linux
make ARCH=riscv CROSS_COMPILE=$LGNU -j$(nproc) Image
# verify atomic-free (only 1 harmless reservation-clear sc.w is OK):
$LGNU.objdump -d vmlinux | grep -cE '\b(amo[a-z]+|lr\.[wd]|sc\.[wd])\b'
```

### 2. OpenSBI fw_payload (soft atomics) + gzip
Soft-atomic patches: `lib/sbi/{riscv_atomic.c,riscv_locks.c,sbi_ipi.c}`; A25 priv-1.10
fixes in `firmware/fw_base.S` (CLEAR_MDT no-op, lottery-skip, trap handler) and the
`andestech,a25` DTB (`linux/ae350-linux.dts`).
```
cd external/opensbi
rm -f build/platform/generic/firmware/fw_payload.*
make CROSS_COMPILE=$LGNU PLATFORM=generic FW_TEXT_START=0x0 \
     FW_FDT_PATH=../../linux/ae350-linux.dtb \
     FW_PAYLOAD_PATH=../linux/arch/riscv/boot/Image \
     FW_PAYLOAD_OFFSET=0x400000        # MUST be 4 MB-aligned (rv32 sv32 superpage)
cd build/platform/generic/firmware
xz --format=lzma --lzma1=preset=9,dict=8MiB -c fw_payload.bin > fw_payload_lzma.bin   # = scripts/flash.sh kernel; --mcuFile wants *.bin
```

### 3. U-Boot (loader; auto-boot bootcmd)
`CONFIG_BOOTCOMMAND="lzmadec 0x80200000 0 0x2000000; sdboot 0"`, `CONFIG_SYS_MALLOC_LEN=0x1000000`
(the LZMA dictionary lives on the heap), `ENV_IS_NOWHERE`,
custom `sdread`/`sdboot`/`amotest` cmds in `board/andestech/ae350/sdread.c`,
`mcache_ctl` ECC-off in `arch/riscv/cpu/andes/cpu.c`.
```
cd ~/projects/mega_138K_test && bash scripts/build_uboot.sh   # -> u-boot-ae350-xip.bin
```

## Flash + run
```
cd ~/projects/mega_138K_test
scripts/flash.sh uboot kernel            # = the two flash_fw.sh lines below (kernel target gzips first)
GOWIN_PATH=$GOWIN_PATH FW=external/u-boot/u-boot-ae350-xip.bin SPIADDR=0x600000 src/firmware/flash_fw.sh
GOWIN_PATH=$GOWIN_PATH FW=external/opensbi/build/platform/generic/firmware/fw_payload_lzma.bin SPIADDR=0x800000 src/firmware/flash_fw.sh
GOWIN_PATH=$GOWIN_PATH MODE=sram scripts/gw_program.sh   # load bitstream
```
Power on / reset (S3) → U-Boot auto-boots → OpenSBI → Linux → `~ #` on UART2 (B19, 115200 8N1).
To stop at the U-Boot prompt, type `uboot` within 2 s (keyed autoboot since 2026-11-03:
a floating RX line, e.g. with the USB-UART adapter unplugged or unpowered, used to stop the
autoboot like a keypress and the board sat at the prompt with a blank LCD; the gateware also
pulls `UART2_RXD` up since Build 67); then run the two commands manually.

---

## Non-obvious requirements (why each matters)

- **Soft atomics** — A25 has no coherence manager; `amo`/`lr-sc` hang on a cache-miss. RMW is emulated via `csrrc sstatus,SIE` + load/store (single-hart). See `CACHE_ISSUES.md`.
- **`CONFIG_SMP=n`** — SMP pulls in qspinlock, whose MCS slowpath deadlocks with soft atomics on one hart (`spinlock bad magic`). UP makes spinlocks trivial.
- **4 MB-aligned kernel** — rv32 sv32 boot protocol; `0x200000` fails silently before earlycon.
- **LZMA + U-Boot `lzmadec`** (gzip + `unzip` until 2026-11-02) — the ~30 MB payload won't fit
  the 8 MB region; LZMA → 6.4 MB (gzip 7.5 MB), 8 MiB dictionary, 16 MB U-Boot heap. The host uses `gzip`; U-Boot's `unzip` *is* gunzip.
- **`.bin` extension** — `programmer_cli --mcuFile` silently writes 0 bytes for non-`.bin` files.
- **static `/dev/console`** — kernel opens it before running `/init`; without it the shell's stdio never reaches the UART.
- **Page-table writeback (`a25_ptwb`)** — the A25 page-table walker does not see dirty L1 lines; every page-table store must be written back to DRAM (PATCHES/0005). The slow stock DDR bridge used to hide this.
- **DTB `compatible="andestech,a25"`** (NOT `andestech,ae350`) — the ae350 OpenSBI override resets this SoC.
