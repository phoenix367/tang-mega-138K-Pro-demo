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
| `0x000000`   | —          | FPGA bitstream (binary ~4.8 MB, ends `0x48C000`); `MODE=flash scripts/gw_program.sh`. Build 55 (2026-10-29): LCD + 1 GB DDR (32-bit bus) + PT8211 audio + temperature/voltage sensor core |
| `0x600000`   | `0x80000000` | U-Boot (XIP, with appended DTB @0xf0000) |
| `0x800000`   | `0x80200000` | `fw_payload.bin.gz` (OpenSBI+kernel+DTB, gzip); kernel #57 (2026-10-29): ALSA PT8211 driver, hwmon gowin-adc (die temperature + rails), `/usr/libexec/sftp-server` for scp/sftp, LCD console (`console=tty0`, `tty1` in inittab) |

U-Boot auto-runs (`CONFIG_BOOTCOMMAND`): `unzip 0x80200000 0 0x2000000; sdboot 0`
— gunzips the ~5 MB image into DRAM `0x0` (OpenSBI @0x0, kernel @0x400000) and jumps.

---

## Build

Toolchains:
- Linux/kernel/OpenSBI: `LGNU=/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-`
- busybox initramfs: `riscv32-buildroot-linux-musl-` (prebuilt rootfs in `linux/rootfs/`)
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
cd ~/projects/linux
make ARCH=riscv CROSS_COMPILE=$LGNU -j$(nproc) Image
# verify atomic-free (only 1 harmless reservation-clear sc.w is OK):
$LGNU.objdump -d vmlinux | grep -cE '\b(amo[a-z]+|lr\.[wd]|sc\.[wd])\b'
```

### 2. OpenSBI fw_payload (soft atomics) + gzip
Soft-atomic patches: `lib/sbi/{riscv_atomic.c,riscv_locks.c,sbi_ipi.c}`; A25 priv-1.10
fixes in `firmware/fw_base.S` (CLEAR_MDT no-op, lottery-skip, trap handler) and the
`andestech,a25` DTB (`linux/ae350-linux.dts`).
```
cd ~/projects/opensbi
rm -f build/platform/generic/firmware/fw_payload.*
make CROSS_COMPILE=$LGNU PLATFORM=generic FW_TEXT_START=0x0 \
     FW_FDT_PATH=~/projects/mega_138K_test/linux/ae350-linux.dtb \
     FW_PAYLOAD_PATH=~/projects/linux/arch/riscv/boot/Image \
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
GOWIN_PATH=$GOWIN_PATH FW=~/projects/u-boot/u-boot-ae350-xip.bin SPIADDR=0x600000 firmware/flash_fw.sh
GOWIN_PATH=$GOWIN_PATH FW=~/projects/opensbi/build/platform/generic/firmware/fw_payload_gz.bin SPIADDR=0x800000 firmware/flash_fw.sh
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
