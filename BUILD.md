# Building the Gowin AE350 project (Tang Mega 138K Pro Dock)

How to build everything in this project and put it on the board. Four independent
build flows share one 16 MB SPI flash:

| Flow | What it is | Tool | Output |
|------|-----------|------|--------|
| **Gateware** | `ae350_demo_top` SoC + `eth_dma` engine | Gowin `gw_sh` | `impl/pnr/mega_138K_test.fs` |
| **Firmware** | bare-metal RV32 test (`src/firmware/`, DMA self-test, UART) | Andes bare-metal GCC | `src/firmware/build/ae350_fw.bin` |
| **RTL sims** | `eth_dma` testbenches (optional) | `iverilog` | pass/fail on stdout |
| **Linux boot stack** | U-Boot + OpenSBI + RV32 kernel + busybox | Andes Linux GCC | `u-boot-ae350-xip.bin`, `fw_payload.bin.gz` |

The Linux boot stack is documented in depth in **[BOOT.md](BOOT.md)**; this file is
the master build/toolchain reference. Repo layout is in **[CLAUDE.md](CLAUDE.md)**;
the no-coherence-manager constraints behind the soft-atomics in **CACHE_ISSUES.md**.

---

## Toolchains

Both Andes toolchains come from the [Andes-Development-Kit releases](https://github.com/andestech/Andes-Development-Kit/releases)
(`ast-v5_4_1-release-linux`: `nds32le-elf-newlib-v5.txz`, `nds32le-linux-glibc-v5d.txz`),
unpacked under `ANDES_ROOT` (default `/mnt/data/toolchains`; the Makefiles and scripts
read it). `docker/bootstrap.sh` builds an image with all of them (section 0).

| Purpose | Path / package | Notes |
|---------|----------------|-------|
| FPGA synth/PnR/program | `GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux` | `gw_sh`, `programmer_cli`. Floating **license server** — flaky; if down, syn/pnr fail "License verification failed". |
| Bare-metal firmware | `ANDES_ROOT/nds32le-elf-newlib-v5/bin/riscv32-elf-` | Andes `nds32le-elf-newlib-v5` (GCC 14.2, newlib, rv32 multilibs; `-march=rv32imac_zicsr_zifencei -mabi=ilp32`). Any rv32imac bare-metal GCC works via `CROSS=`; the `-nostdlib` payload needs `-mno-save-restore`. |
| Kernel / OpenSBI / U-Boot | `LGNU=$ANDES_ROOT/nds32le-linux-glibc-v5d/bin/riscv32-linux-` | Andes `nds32le-linux-glibc-v5d` (GCC 14.2, binutils 2.42): **PIE-capable** ld (the bare-metal `-elf` linkers are not) and it ships the ilp32d libgcc U-Boot needs. |
| (alternative) AMD Vitis `riscv32-amd-linux-gnu-` | GCC 13.4, PIE-capable | works too, but ships no ilp32d libgcc: set `UBOOT_HF_LIBGCC=/usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32imafdc/ilp32d`. |
| Userspace / rootfs | `~/projects/riscv32-ilp32d--musl--stable-2025.08-1/bin/riscv32-buildroot-linux-musl-` (Bootlin) | GCC 14.3, musl 1.2.5 with the soft-atomic `libc.a` (PATCHES/0012); rebuild it with `scripts/build_musl_toolchain.sh`. The Vitis glibc/musl userspace toolchains are broken. |
| Device tree | `dtc` (Debian `device-tree-compiler` or kernel `scripts/dtc`) | |
| RTL simulation | `iverilog` / `vvp` | |

> **PATH trap:** the user's shell profile prepends a crippled `riscv64-unknown-elf-`
> to `PATH`. Always pass `CROSS_COMPILE`/`PLATFORM_LIBGCC` as **absolute paths**.

The boot-stack trees are submodules: `external/linux`, `external/opensbi`, `external/u-boot`
(forks phoenix367/tang-mega-138k-{linux,opensbi,u-boot}; `git submodule update --init`
after cloning). Paths below are relative to the repo root. Verified board config (from `misa`/`mmsc_cfg` CSRs): **A25**,
RV32 IMAFDC + S/U (Linux-capable), single hart, 32 KB I + 32 KB D L1 (4-way, 32 B
line), **CCTL cache-control CSRs present** (`mmsc_cfg` b16), no L2, no coherence
manager. Clocks (logic-analyzer-verified): **core 800 MHz, AHB/APB 50 MHz, data-memory bus 100 MHz,
RTC 10 MHz**, DDR3 400 MHz (DDR3-800).

A `CMakeLists.txt` wraps most of this: targets `hw_synth`/`hw_pnr`/`hw_all`,
`firmware`, `flash-bitstream`, `upload`, `uboot-config`/`uboot`/`uboot-flash`,
`payload`/`payload-flash`, `help-targets`. The Linux kernel/OpenSBI steps are
driven by `scripts/build_linux_boot.sh` (not CMake).

---

## 0. Building in Docker (optional)

`docker/bootstrap.sh` builds an image with every cross toolchain above (both Andes
toolchains fetched by checksum from the Andes release, the Bootlin musl toolchain with the
soft-atomic `libc.a` built by `scripts/build_musl_toolchain.sh`) and the host tools, and
writes `docker/.env`. `docker/run.sh` runs a command in it with the repo at `/work`, the
Gowin install bind-mounted read-only at `/opt/gowin` (`GOWIN_PATH` set), the userspace
package dir at `/userspace` and USB passed through:

```sh
docker/bootstrap.sh --gowin-path /mnt/data/Gowin_V1.9.12.02_SP2_linux   # once; ~3 GB image
docker/run.sh make -C src/firmware
docker/run.sh scripts/build_uboot.sh
docker/run.sh scripts/build_kernel.sh             # kernel (name + linux/RELEASE) + OpenSBI fw_payload
docker/run.sh env STAGE=all scripts/gw_run.sh        # gateware; the licence server must be reachable
docker/run.sh scripts/rootfs/build_all.sh
docker/run.sh --flash bitstream uboot kernel      # program the board from the container (USB passed through)
```

Options: `--tag`, `--andes-release` (+ `--andes-*-sha256`), `--uid/--gid`, `--userspace`,
`--no-cache`, `--dry-run`. The Gowin tools are never copied into the image. Inside the
container the toolchains are under `/opt/toolchains` (`ANDES_ROOT`, `TOOLCHAIN`), so every
Makefile and script works unchanged. Verified in the image: firmware, payload, U-Boot,
OpenSBI payload, kernel, all rootfs packages, and a gateware synthesis (`gw_sh` runs with
`QT_QPA_PLATFORM=offscreen`, preset in the image, since it is a Qt program even headless;
the licence server is reached through the default bridge network). The submodule's
`tools/mkimage` is a host binary of whichever side built U-Boot last; the payload Makefile
falls back to the distro `mkimage` (`u-boot-tools`, in the image) when it cannot run.

> Docker with the containerd image store keeps image layers under **containerd's** root
> (`/var/lib/containerd`), not under Docker's `data-root`; move both when relocating.

---

## 1. FPGA gateware

```sh
GP=/mnt/data/Gowin_V1.9.12.02_SP2_linux
GOWIN_PATH=$GP STAGE=syn scripts/gw_run.sh    # synthesis only
GOWIN_PATH=$GP STAGE=all scripts/gw_run.sh    # syn + PnR + bitstream -> impl/pnr/mega_138K_test.fs
```
- `impl/mega_138K_test_process_config.json` keeps `CPU`/`MSPI`/`SSPI` = `true` so the
  AE350's SPI-flash interface can use the dedicated config pins (else PnR fails `PR2017`).
- Synthesis-only needs no constraints; PnR enforces `Promote_Physical_Constraint_Warning_to_Error`.
- Build 72: logic 30 %, registers 26 %, BSRAM 57 % (192 of 340), DSP 11 % on
  `gw5ast138b-007` (doc/01-architecture.md §8.5).

Program the board:
```sh
GOWIN_PATH=$GP MODE=sram  scripts/gw_program.sh   # volatile (default) — reverts on power cycle
GOWIN_PATH=$GP MODE=flash scripts/gw_program.sh   # persistent: writes bitstream to SPI flash 0x0
```
After SRAM programming the FPGA self-configures and the CPU boots from SPI flash.

---

## 2. Bare-metal test firmware

```sh
cd firmware && make            # -> build/ae350_fw.bin   (CFLAGS already include -DREF_TEST_CLK)
```
> **`-DREF_TEST_CLK` is mandatory.** The BSP `OSCFREQ` defaults to 100 MHz; this board's
> APB is **50 MHz**. Without it every UART baud is halved.

Flash + run (this **overwrites U-Boot** at `0x600000` — reflash the boot stack to get
Linux back):
```sh
GOWIN_PATH=$GP src/firmware/flash_fw.sh              # writes ae350_fw.bin -> flash 0x600000 (run 55)
GOWIN_PATH=$GP MODE=sram scripts/gw_program.sh   # reload gateware -> CPU resets, XIP-boots the fw
```
The self-test prints over **UART2** (USB-TTL adapter on the header's **B19** TX / **A17** RX, 8N1, 115200;
the on-board FT2232 ch-B `/dev/ttyUSB1` does **not** work as the console — see memory).

---

## 3. eth_dma RTL simulations (optional)

No license needed. Example (full RX path + the store-and-forward staging buffer):
```sh
cd eth_dma
iverilog -g2012 -I lib -I rtl -o /tmp/t.vvp \
  tb/tb_rx_path.v tb/ahb_slave_ram.v \
  rtl/rx_path.v rtl/rx_capture.v rtl/rx_sf_buffer.v rtl/rx_ring_writer.v \
  rtl/ahb_master.v rtl/cdc_fifo_reset.v lib/*.v && vvp /tmp/t.vvp
```
Other self-contained tbs: `tb_rx_sf_buffer`, `tb_rx_capture`, `tb_rx_ring_writer`,
`tb_gw_eth_dma` (full DMA-core loopback). The `tb_eth_core*` tbs instantiate the
Gowin `mac.vo` netlist and need the Gowin simulator, not `iverilog`.

---

## 4. Linux boot stack

Full rationale and the working flash/boot recipe are in **[BOOT.md](BOOT.md)**. Summary:

```sh
export LGNU=/mnt/data/toolchains/nds32le-linux-glibc-v5d/bin/riscv32-linux-
```

### 4a. Kernel (`external/linux`, 6.12, RV32, UP + soft atomics)
```sh
LINUX_CROSS=$LGNU scripts/build_kernel.sh      # -> external/linux/arch/riscv/boot/Image + fw_payload (4c)
NO_PAYLOAD=1 LINUX_CROSS=$LGNU scripts/build_kernel.sh   # Image only
```
The script names the build. `uname -r` is `6.12.0-tangmega138k-g<commit>[-dirty]`
(`CONFIG_LOCALVERSION` in `tang_mega_138k_defconfig`, then the fork's commit), `uname -v`
is `#<release> <build date>` with the board release from **`linux/RELEASE`**
(`KBUILD_BUILD_VERSION`; a plain `make Image` in the tree puts its own build counter
there instead). The release is the "kernel #N" of BOOT.md, one number for the kernel and
the initramfs rootfs in it: bump `linux/RELEASE` for each new release (test builds of one
release share the number; the build date tells them apart). At boot `rcS` writes both into
`/etc/issue` (the rootfs file is a template with getty's `\s \r \v \m`), which the serial
console's getty prints before the login prompt; boardtest's `kernel.version` warns when
the board's release differs from the file. Without a
`.config` the script starts from `tang_mega_138k_defconfig`.
Key config (`.config` on disk; built on this machine): `CONFIG_SMP=n` (UP — qspinlock
deadlocks with soft atomics), `CONFIG_NONPORTABLE=y`, `CONFIG_HZ=250`,
`CONFIG_RISCV_DMA_NONCOHERENT=y`, `CONFIG_RISCV_NONSTANDARD_CACHE_OPS=y`, heavy debug
off, `CONFIG_INITRAMFS_SOURCE="…/linux/rootfs …/linux/initramfs_nodes.list"`. Soft-atomic
patches live in `arch/riscv/include/asm/{soft_atomic,cmpxchg,atomic,bitops,futex}.h`.
The Gowin ethernet driver is `drivers/net/ethernet/gowin/gw_tse.c`
(`CONFIG_NET_VENDOR_GOWIN`); `linux/driver/` here holds reference copies of the board drivers, plus the older PIO
Ethernet driver (`gw_tse_pio.c`).
Sanity-check the build is atomic-free:
```sh
$LGNU.objdump -d vmlinux | grep -cE '\b(amo[a-z]+|lr\.[wd]|sc\.[wd])\b'   # expect ~1
```

### 4b. Device tree (`linux/ae350-linux.dts`)
`compatible = "andestech,a25"` (NOT `ae350` — that OpenSBI override resets this SoC; the
`a25` one, `external/opensbi/platform/generic/andes/a25.c`, only adds the core's
`mmsc_cfg` extensions — `p`, `xandesperf`, `xandescodense` — to the CPU node's
`riscv,isa-extensions`, which must therefore list the standard ones too; Linux shows them
in `/proc/cpuinfo`), `timebase-frequency = <50000000>`, cpu `clock-frequency = <800000000>`,
eth at `ethernet@e8000000` (`gowin,ae350-tse`). Rebuild after edits:
```sh
dtc -I dts -O dtb -o linux/ae350-linux.dtb linux/ae350-linux.dts
```

### 4c. OpenSBI fw_payload (`external/opensbi`) + gzip
`scripts/build_kernel.sh` ends with this step; on its own:
```sh
FW_PAYLOAD_OFFSET=0x400000 LINUX_CROSS=$LGNU scripts/build_linux_boot.sh
cd external/opensbi/build/platform/generic/firmware
xz --format=lzma --lzma1=preset=9,dict=8MiB -c fw_payload.bin > fw_payload_lzma.bin   # or: scripts/flash.sh kernel
```
> **Footgun:** the kernel payload offset **must be 4 MB-aligned = `0x400000`** (rv32 sv32
> superpage); `0x200000` fails silently before earlycon. `build_linux_boot.sh` *defaults*
> to `0x200000` — **always pass `FW_PAYLOAD_OFFSET=0x400000`** (matches BOOT.md).
> Soft-atomic patches in opensbi `lib/sbi/{riscv_atomic,riscv_locks,sbi_ipi}.c` +
> `firmware/fw_base.S` must already be applied.

### 4d. U-Boot (`external/u-boot`, hard-float XIP loader)
```sh
scripts/config_uboot.sh        # defconfig + Kconfig tweaks; build_uboot.sh runs it on a tree without .config
scripts/build_uboot.sh         # -> external/u-boot/u-boot-ae350-xip.bin (u-boot + DTB @0xf0000)
```
DT adaptation (single CPU, 50 MHz clocks, no `spi@f0b00000`/mac/mmc nodes; its memory
node still says 256 MB, harmless since U-Boot only decompresses the payload and Linux uses
`linux/ae350-linux.dts` with the full 1 GB)
and `include/configs/ae350.h` env (`autostart=yes`, `bootcmd = "lzmadec 0x80200000 0
0x2000000; sdboot 0"`) are **file edits in the tree**, not Kconfig — see memory
`ae350-uboot-build`.

### 4e. rootfs binaries (`linux/rootfs/`)
```sh
scripts/rootfs/build_all.sh            # ncurses, libpcap, tcpdump, htop, nstat, dropbear, doas, sftp-server, busybox
INSTALL=1 scripts/rootfs/build_busybox.sh   # or any single build_<pkg>.sh; INSTALL=1 replaces the rootfs file
```
Each script fetches + checksums its upstream tarball into `~/projects/ae350_linux_user_level/<pkg>/`,
builds static against the soft-atomic musl toolchain, verifies 0 lr/sc/amo and says whether the
result is identical to the shipped binary. busybox = mirror/busybox @ `371fe9f` +
`linux/busybox.config` (`defconfig` + `CONFIG_STATIC=y`, HWCLOCK / RDATE / TC / SHA*_HWACCEL off).
lvdesk / inputd / wavplay come from `src/apps/desktop` (`make install`).

---

## 5. Flash layout & deploy

16 MB SPI NOR (W25Q128, id `0xEF4018`); CPU XIP base `0x80000000` = flash offset `0x600000`.

| Flash offset | XIP addr | Contents |
|--------------|----------|----------|
| `0x000000` | — | FPGA bitstream (`.fs`) — for power-cycle autoboot |
| `0x600000` | `0x80000000` | U-Boot (XIP) + appended DTB @ `+0xf0000` + boot splash BMP @ `+0x100000` (flash `0x700000`, see BOOT.md) |
| `0x800000` | `0x80200000` | `fw_payload_lzma.bin` (OpenSBI + kernel + DTB, LZMA; 8 MB region) |

```sh
GOWIN_PATH=$GP scripts/flash.sh bitstream uboot kernel   # named targets; -n = dry run; 'load' = SRAM only
# ...or the underlying commands:
GOWIN_PATH=$GP FW=external/u-boot/u-boot-ae350-xip.bin SPIADDR=0x600000 src/firmware/flash_fw.sh
GOWIN_PATH=$GP FW=external/opensbi/build/platform/generic/firmware/fw_payload_lzma.bin SPIADDR=0x800000 src/firmware/flash_fw.sh
GOWIN_PATH=$GP MODE=sram scripts/gw_program.sh        # or MODE=flash for persistent bitstream @0x0
```
Reset (S3) → U-Boot auto-boots → LZMA-decompresses the payload to DRAM `0x0` (~9 s) → OpenSBI → Linux →
shell on UART2 (~24 s).

> **Programmer quirk:** `programmer_cli`'s exFlash bridge only reliably writes images based
> at **`0x0`** or **`0x600000`**. A separate write to a higher offset can be silently dropped
> (prints `ends at <start>`, reads back `0xff`). For one-shot programming, build a single
> combined image with `scripts/build_app_image.sh` (U-Boot @0, payload @ `PAYLOAD_OFF`).
> Also: `--mcuFile` only writes files with a **`.bin`** extension (hence `fw_payload_lzma.bin`).

---

## Gotchas (consolidated)

- **`-DREF_TEST_CLK`** — APB is 50 MHz, BSP defaults to 100 → halved UART baud without it.
- **Kernel payload 4 MB-aligned** (`FW_PAYLOAD_OFFSET=0x400000`); `0x200000` boots nothing.
- **Soft atomics + `CONFIG_SMP=n`** everywhere — A25 `amo`/`lr-sc` hang on a DRAM cache-miss
  (no coherence manager). See CACHE_ISSUES.md.
- **Linux-gnu toolchain (PIE)** for U-Boot/OpenSBI/kernel, by **absolute path**.
- **Hard-float libgcc** (`ilp32d`) pointed in via `PLATFORM_LIBGCC` for U-Boot.
- **DTB `andestech,a25`**, not `ae350`.
- **`.bin` extension** required by `programmer_cli --mcuFile`; programmer writes only `0x0`/`0x600000` reliably.
- **Gowin license server** must be reachable for syn/pnr/bitstream.

## Quick reference

```sh
GP=/mnt/data/Gowin_V1.9.12.02_SP2_linux
LGNU=/mnt/data/toolchains/nds32le-linux-glibc-v5d/bin/riscv32-linux-

GOWIN_PATH=$GP STAGE=all scripts/gw_run.sh            # gateware bitstream
make -C firmware                                       # bare-metal firmware
dtc -I dts -O dtb -o linux/ae350-linux.dtb linux/ae350-linux.dts
LINUX_CROSS=$LGNU scripts/build_kernel.sh             # kernel #$(cat linux/RELEASE) + fw_payload
scripts/build_uboot.sh
```
