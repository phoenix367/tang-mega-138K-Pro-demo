# Building the Gowin AE350 project (Tang Mega 138K Pro Dock)

How to build everything in this project and put it on the board. Four independent
build flows share one 16 MB SPI flash:

| Flow | What it is | Tool | Output |
|------|-----------|------|--------|
| **Gateware** | `ae350_demo_top` SoC + `eth_dma` engine | Gowin `gw_sh` | `impl/pnr/mega_138K_test.fs` |
| **Firmware** | bare-metal RV32 test (`src/firmware/`, DMA self-test, UART) | Vitis bare-metal GCC | `src/firmware/build/ae350_fw.bin` |
| **RTL sims** | `eth_dma` testbenches (optional) | `iverilog` | pass/fail on stdout |
| **Linux boot stack** | U-Boot + OpenSBI + RV32 kernel + busybox | Vitis linux-gnu GCC | `u-boot-ae350-xip.bin`, `fw_payload.bin.gz` |

The Linux boot stack is documented in depth in **[BOOT.md](BOOT.md)**; this file is
the master build/toolchain reference. Repo layout is in **[CLAUDE.md](CLAUDE.md)**;
the no-coherence-manager constraints behind the soft-atomics in **CACHE_ISSUES.md**.

---

## Toolchains

| Purpose | Path / package | Notes |
|---------|----------------|-------|
| FPGA synth/PnR/program | `GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux` | `gw_sh`, `programmer_cli`. Floating **license server** — flaky; if down, syn/pnr fail "License verification failed". |
| Bare-metal firmware | `/mnt/data/xilinx/2025.2/Vitis/gnu/riscv/lin/bin/riscv64-unknown-elf-gcc` | actually `riscv32-xilinx-elf`, GCC 13.4, rv32 multilib. `-march=rv32imac_zicsr_zifencei -mabi=ilp32`. |
| Kernel / OpenSBI / U-Boot | `LGNU=/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-` | GCC 13.4, **PIE-capable** (the bare-metal `-elf` linkers are not). |
| Hard-float libgcc (U-Boot) | `/usr/lib/gcc/riscv64-unknown-elf/13.2.0/rv32imafdc/ilp32d` | the AMD linux-gnu toolchain ships no ilp32d libgcc. |
| busybox initramfs | `riscv32-buildroot-linux-musl-` (Bootlin) | prebuilt rootfs already in `linux/rootfs/`; the Vitis glibc/musl userspace toolchains are broken. |
| Device tree | `dtc` (`/mnt/data/xilinx/2025.2/Vitis/bin/dtc` or kernel `scripts/dtc`) | |
| RTL simulation | `iverilog` / `vvp` | |

> **PATH trap:** the user's shell profile prepends a crippled `riscv64-unknown-elf-`
> to `PATH`. Always pass `CROSS_COMPILE`/`PLATFORM_LIBGCC` as **absolute paths**.

External trees (siblings of this repo): `~/projects/linux`, `~/projects/opensbi`,
`~/projects/u-boot`. Verified board config (from `misa`/`mmsc_cfg` CSRs): **A25**,
RV32 IMAFDC + S/U (Linux-capable), single hart, 32 KB I + 32 KB D L1 (4-way, 32 B
line), **CCTL cache-control CSRs present** (`mmsc_cfg` b16), no L2, no coherence
manager. Clocks (logic-analyzer-verified): **core 800 MHz, AHB/APB/DDR 50 MHz,
RTC 10 MHz**, DDR3 200 MHz.

A `CMakeLists.txt` wraps most of this: targets `hw_synth`/`hw_pnr`/`hw_all`,
`firmware`, `flash-bitstream`, `upload`, `uboot-config`/`uboot`/`uboot-flash`,
`payload`/`payload-flash`, `help-targets`. The Linux kernel/OpenSBI steps are
driven by `scripts/build_linux_boot.sh` (not CMake).

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
- The current build: ~8% registers, ~7% BSRAM on `gw5ast138b-007`.

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
The self-test prints over **UART2** (logic analyzer / USB-TTL on **U16**, 8N1, 115200;
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
export LGNU=/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-
```

### 4a. Kernel (`~/projects/linux`, 6.12, RV32, UP + soft atomics)
```sh
cd ~/projects/linux
make ARCH=riscv CROSS_COMPILE=$LGNU -j$(nproc) Image     # -> arch/riscv/boot/Image
```
Key config (`.config` on disk; built on this machine): `CONFIG_SMP=n` (UP — qspinlock
deadlocks with soft atomics), `CONFIG_NONPORTABLE=y`, `CONFIG_HZ=250`,
`CONFIG_RISCV_DMA_NONCOHERENT=y`, `CONFIG_RISCV_NONSTANDARD_CACHE_OPS=y`, heavy debug
off, `CONFIG_INITRAMFS_SOURCE="…/linux/rootfs …/linux/initramfs_nodes.list"`. Soft-atomic
patches live in `arch/riscv/include/asm/{soft_atomic,cmpxchg,atomic,bitops,futex}.h`.
The Gowin ethernet driver is `drivers/net/ethernet/gowin/gw_tse.c`
(`CONFIG_NET_VENDOR_GOWIN`); `linux/driver/` here holds the older PIO copy for reference.
Sanity-check the build is atomic-free:
```sh
$LGNU.objdump -d vmlinux | grep -cE '\b(amo[a-z]+|lr\.[wd]|sc\.[wd])\b'   # expect ~1
```

### 4b. Device tree (`linux/ae350-linux.dts`)
`compatible = "andestech,a25"` (NOT `ae350` — that OpenSBI override resets this SoC),
`timebase-frequency = <50000000>`, cpu `clock-frequency = <800000000>`, eth at
`ethernet@e8000000` (`gowin,ae350-tse`). Rebuild after edits:
```sh
dtc -I dts -O dtb -o linux/ae350-linux.dtb linux/ae350-linux.dts
```

### 4c. OpenSBI fw_payload (`~/projects/opensbi`) + gzip
```sh
FW_PAYLOAD_OFFSET=0x400000 LINUX_CROSS=$LGNU scripts/build_linux_boot.sh
cd ~/projects/opensbi/build/platform/generic/firmware
gzip -9 -k -f fw_payload.bin && cp -f fw_payload.bin.gz fw_payload_gz.bin
```
> **Footgun:** the kernel payload offset **must be 4 MB-aligned = `0x400000`** (rv32 sv32
> superpage); `0x200000` fails silently before earlycon. `build_linux_boot.sh` *defaults*
> to `0x200000` — **always pass `FW_PAYLOAD_OFFSET=0x400000`** (matches BOOT.md).
> Soft-atomic patches in opensbi `lib/sbi/{riscv_atomic,riscv_locks,sbi_ipi}.c` +
> `firmware/fw_base.S` must already be applied.

### 4d. U-Boot (`~/projects/u-boot`, hard-float XIP loader)
```sh
scripts/config_uboot.sh        # one-time: defconfig + Kconfig tweaks (re-run on a clean tree)
scripts/build_uboot.sh         # -> ~/projects/u-boot/u-boot-ae350-xip.bin (u-boot + DTB @0xf0000)
```
DT adaptation (single CPU, 50 MHz clocks, 256 MB DRAM, no `spi@f0b00000`/mac/mmc nodes)
and `include/configs/ae350.h` env (`autostart=yes`, `bootcmd = "unzip 0x80200000 0
0x2000000; sdboot 0"`) are **file edits in the tree**, not Kconfig — see memory
`ae350-uboot-build`.

---

## 5. Flash layout & deploy

16 MB SPI NOR (W25Q128, id `0xEF4018`); CPU XIP base `0x80000000` = flash offset `0x600000`.

| Flash offset | XIP addr | Contents |
|--------------|----------|----------|
| `0x000000` | — | FPGA bitstream (`.fs`) — for power-cycle autoboot |
| `0x600000` | `0x80000000` | U-Boot (XIP) + appended DTB @ `+0xf0000` |
| `0x800000` | `0x80200000` | `fw_payload.bin.gz` (OpenSBI + kernel + DTB, gzip) |

```sh
GOWIN_PATH=$GP FW=~/projects/u-boot/u-boot-ae350-xip.bin SPIADDR=0x600000 src/firmware/flash_fw.sh
GOWIN_PATH=$GP FW=~/projects/opensbi/build/platform/generic/firmware/fw_payload_gz.bin SPIADDR=0x800000 src/firmware/flash_fw.sh
GOWIN_PATH=$GP MODE=sram scripts/gw_program.sh        # or MODE=flash for persistent bitstream @0x0
```
Reset (S3) → U-Boot auto-boots → gunzips the payload to DRAM `0x0` → OpenSBI → Linux →
shell on UART2 (~24 s).

> **Programmer quirk:** `programmer_cli`'s exFlash bridge only reliably writes images based
> at **`0x0`** or **`0x600000`**. A separate write to a higher offset can be silently dropped
> (prints `ends at <start>`, reads back `0xff`). For one-shot programming, build a single
> combined image with `scripts/build_app_image.sh` (U-Boot @0, payload @ `PAYLOAD_OFF`).
> Also: `--mcuFile` only writes files with a **`.bin`** extension (hence `fw_payload_gz.bin`).

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
LGNU=/mnt/data/xilinx/2025.2/gnu/riscv/linux_toolchain/lin32/bin/riscv32-amd-linux-gnu-

GOWIN_PATH=$GP STAGE=all scripts/gw_run.sh            # gateware bitstream
make -C firmware                                       # bare-metal firmware
( cd ~/projects/linux && make ARCH=riscv CROSS_COMPILE=$LGNU -j$(nproc) Image )
dtc -I dts -O dtb -o linux/ae350-linux.dtb linux/ae350-linux.dts
FW_PAYLOAD_OFFSET=0x400000 LINUX_CROSS=$LGNU scripts/build_linux_boot.sh
scripts/build_uboot.sh
```
