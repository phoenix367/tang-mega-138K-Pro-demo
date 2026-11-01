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
| `0x000000`   | —          | FPGA bitstream (binary ~4.9 MB, ends `0x4DCB00`); `MODE=flash scripts/gw_program.sh`. **Build 65** (2026-11-01, in flash, ends `0x4E4700`): Build 64 + the DDR3 IP's 50 MHz reference input taken from the board clock (DDR3 PLL CLKOUT0 unused: 3 → 2 generated 50 MHz clocks; `APB_CLK` must keep its own PLL output, fed from the AHB_CLK net the PLIC drops audio interrupt completions), the 16 global clock wires pinned in the `.cst` (`CLOCK_LOC`; the RGMII RX clock must stay on an LW wire, on a PRIMARY one gigabit RX breaks), bridge statistics counters as `pipe_counter`; all clocks met (ddr3_sysclk 100.11 MHz, ahb_clk 54.9, rgmii_rxclk 125.3), same read-wait numbers as Build 64. Build 64 (2026-11-01): Build 63 + the SoC's `DDR_CLK` driven by the DDR3 IP user clock, so the DDR bridge is single-clock and its FIFOs hand pointers across without synchronizers (`SYNC_CLK=1`); average read wait per data-memory transfer 19.6–20.0 → 17.9–18.5 HCLK; all clocks met (ddr3_sysclk 100.12 MHz, ahb_clk 53.5). Build 63 (2026-10-31, timing): Build 62 + two-stage audio DMA command sizing, sdhost FIFO in BSRAM, `src/rtl/pipe_counter.v` for the ddr_perf/BIST counters, EXTS reads through a register with one wait state; every clock meets with margin (ahb_clk 58.0 MHz, ddr_clk 100.01, ddr3_sysclk 101.0), 8k fewer flops, 4.3k fewer LUTs; per-path reports for ahb_clk/ddr3_sysclk added to the SDC. Build 62 (2026-10-30): Build 61 + audio DMA fetch engine (`src/rtl/audio/`, 64-bit read master on the EXTM arbiter's 4th port `src/rtl/audio/rtl/ahb_arbiter4.v`, ring buffer up to a driver-committed DMA_LIMIT, period/error IRQ bits); PnR Place_Option 2 + Route_Option 0 (Route_Option 2 now aborts the router with PR0004, Place 0/1 miss ddr_clk by 1 ns). Build 61 (2026-10-30): Build 57 (LCD + 1 GB DDR + PT8211 audio + sensor + fan cores, registered-predicted-beat bridge) + native 4-bit microSD host with DMA (`src/rtl/sdhost/`, EXTS 0xE8020000, arbiter master 2, EXT_INT[2], late input sampling; replaces Build 59's SPI-mode core); PnR Place_Option 2 (3 aborts the router on this netlist) |
| `0x600000`   | `0x80000000` | U-Boot (XIP, with appended DTB @0xf0000) |
| `0x800000`   | `0x80200000` | `fw_payload.bin.gz` (OpenSBI+kernel+DTB, gzip); kernel #71 (2026-10-30; payload 7.32 MB; #68 + gowin-pt8211 DMA mode (`PATCHES/0007`: CAP[0] cores use a contiguous streaming-mapped ALSA buffer read by the core, `.ack` cleans the cache + writes DMA_LIMIT, DRAIN trigger sets stop-when-empty, `pio=1` sysfs switch for the old interrupt-fill mode, serialiser enabled only after the first fetch; #69/#70 = earlier DMA kernels with start/tail underruns); #68 = #66 + desktop microSD mount/unmount row, inputd send timeouts; #66 = #64 + gowin-sdhost MMC host (`PATCHES/0011`, DT `mmc@e8020000`, PLIC 12) with clock/phase tuning for the native SD host; #64 = #61 + spi-gowin + mmc_spi (`PATCHES/0010`, `S45sdcard` → /mnt/sd, vfat charsets built in); #61 = #60 + fan status-bar indicator, XZ initramfs — the region ends at 0x1000000, keep it under 8 MB): #59 (#57 + evdev/uinput) + hwmon gowin-fan (`PATCHES/0009`, DT `fan0`) + `S80fan` temperature curve; #59 = #57 (ALSA PT8211, hwmon gowin-adc, sftp-server) + evdev/uinput for the network input bridge (`inputd`) and the LVGL desktop (`lvdesk` on VT 1, no getty on tty1); `console=tty0` still prints boot messages on the LCD |

U-Boot auto-runs (`CONFIG_BOOTCOMMAND`): `unzip 0x80200000 0 0x2000000; sdboot 0`
— gunzips the ~5 MB image into DRAM `0x0` (OpenSBI @0x0, kernel @0x400000) and jumps.

---

## Build

Toolchains:
- Linux/kernel/OpenSBI: `LGNU=/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-`
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
gzip -9 -k -f fw_payload.bin
cp -f fw_payload.bin.gz fw_payload_gz.bin   # programmer_cli --mcuFile only writes *.bin
```

### 3. U-Boot (loader; auto-boot bootcmd)
`CONFIG_BOOTCOMMAND="unzip 0x80200000 0 0x2000000; sdboot 0"`, `ENV_IS_NOWHERE`,
custom `sdread`/`sdboot`/`amotest` cmds in `board/andestech/ae350/sdread.c`,
`mcache_ctl` ECC-off in `arch/riscv/cpu/andes/cpu.c`.
```
cd ~/projects/mega_138K_test && bash scripts/build_uboot.sh   # -> u-boot-ae350-xip.bin
```

## Flash + run
```
cd ~/projects/mega_138K_test
GOWIN_PATH=$GOWIN_PATH FW=external/u-boot/u-boot-ae350-xip.bin SPIADDR=0x600000 src/firmware/flash_fw.sh
GOWIN_PATH=$GOWIN_PATH FW=external/opensbi/build/platform/generic/firmware/fw_payload_gz.bin SPIADDR=0x800000 src/firmware/flash_fw.sh
GOWIN_PATH=$GOWIN_PATH MODE=sram scripts/gw_program.sh   # load bitstream
```
Power on / reset (S3) → U-Boot auto-boots → OpenSBI → Linux → `~ #` on UART2 (B19, 115200 8N1).
To stop at the U-Boot prompt, hit a key within 2 s; then run the two commands manually.

---

## Non-obvious requirements (why each matters)

- **Soft atomics** — A25 has no coherence manager; `amo`/`lr-sc` hang on a cache-miss. RMW is emulated via `csrrc sstatus,SIE` + load/store (single-hart). See `CACHE_ISSUES.md`.
- **`CONFIG_SMP=n`** — SMP pulls in qspinlock, whose MCS slowpath deadlocks with soft atomics on one hart (`spinlock bad magic`). UP makes spinlocks trivial.
- **4 MB-aligned kernel** — rv32 sv32 boot protocol; `0x200000` fails silently before earlycon.
- **gzip + U-Boot `unzip`** — the ~29 MB payload won't fit 16 MB flash; gzip → ~5 MB. The host uses `gzip`; U-Boot's `unzip` *is* gunzip.
- **`.bin` extension** — `programmer_cli --mcuFile` silently writes 0 bytes for non-`.bin` files.
- **static `/dev/console`** — kernel opens it before running `/init`; without it the shell's stdio never reaches the UART.
- **Page-table writeback (`a25_ptwb`)** — the A25 page-table walker does not see dirty L1 lines; every page-table store must be written back to DRAM (PATCHES/0005). The slow stock DDR bridge used to hide this.
- **DTB `compatible="andestech,a25"`** (NOT `andestech,ae350`) — the ae350 OpenSBI override resets this SoC.
