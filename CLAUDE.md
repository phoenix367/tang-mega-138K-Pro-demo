# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **GOWIN EDA FPGA project** (not software) for the **Tang Mega 138K Pro Dock**. The
toolchain is Gowin's IDE / `gw_sh` Tcl shell, not a typical build system, so there are
no npm/make/test commands. The project holds **two designs**; only one is enabled in the
`.gprj` `<FileList>` at a time (the disabled one stays on disk with `enable="0"`):

1. **`ae350_demo_top` — the active design.** Andes RISC-V **AE350 SoC** reference,
   imported from `~/Downloads/RiscV_AE350_SOC_V1.3/.../Tang_MEGA_138K_Pro_Dock`. Boots
   from SPI flash, runs DDR3 data memory, UART2, GPIO (3 LEDs + 3 keys), PIT/WDT/RTC,
   JTAG debug. Two PLLs (`gowin_pll_ae350` → 800 MHz core + 50 MHz AHB/APB + 10 MHz
   RTC; `gowin_pll_ddr3` → 400 MHz DDR3, netlist `src/rtl/ddr3_memory_interface_1g/`). The SoC's
   100 MHz data-memory clock `DDR_CLK` is the DDR3 IP's user clock (`clk_out`, Build 64+), so
   the DDR bridge is single-clock (`SYNC_CLK=1`); the AE350 PLL's 100 MHz CLKOUT0 is unused.
   The DDR3 IP's 50 MHz reference input is the board clock `CLK` (Build 65+, DDR3 PLL
   CLKOUT0 unused). `APB_CLK` must stay on its own PLL output even though it is 1:1 with
   `AHB_CLK`: fed from the AHB_CLK net the SoC's PLIC drops interrupt completions (audio
   stalls) — see doc/06-key-findings.md. The 16 global clock wires are all used and pinned
   in `src/rtl/ae350_demo.cst` (`CLOCK_LOC`): the RGMII RX clock must stay on an LW wire
   (`BUFG[8]`), on a PRIMARY wire its capture window shifts and gigabit RX breaks. `src/rtl/riscv_ae350_soc/` is encrypted Andes IP
   (`.v` synth netlist + `.ipc` wizard config; the `.vo` sim netlist and the wizard's
   `temp/` are not kept) — regenerate via the IDE IP wizard, don't hand-edit. `src/rtl/key_debounce.v` debounces the DDR3/AE350 resets.
   DDR3 is **1 GB** (both x16 chips on the 32-bit bus, 15 row bits,
   `src/rtl/ddr3_memory_interface_1g/`, bridge `ADDR_BITS = 30`, 256-bit datapath: one BL8 =
   one 32 B line — see src/rtl/ddr_bridge/README.md; the older x16 netlists are gone, git
   history before 2026-11-01 has them).
   DDR3 path: SoC data-memory AHB (`DDR_H*`) -> **`src/rtl/ddr_bridge/`** (`ahb_ddr3_top`,
   line-buffered bridge; Gowin's stock `gw_ahb_ddr3` was removed from the tree) ->
   DDR3 IP. `src/rtl/ddr_perf.v` = bus perf counters/trace + bridge MODE register on the
   SoC external APB @ `0xF8000000` (reset MODE 0x10000 = overlapped reads; needs the
   Linux page-table writeback patch `PATCHES/0005`, else use 0x100 — see
   src/rtl/ddr_bridge/README.md). Wide event counters use `src/rtl/pipe_counter.v` (byte slices
   with registered carries: GowinSyn builds a 32-bit `+1` as a 12-level LUT chain).
   EXTS register reads take one wait state (read data registered at the top level
   before the SoC's pins; writes zero-wait) — see doc/06-key-findings.md, timing section. Bridge RTL is validated with
   `src/rtl/ddr_bridge/tb/run_all.sh` (iverilog random regression, directed tests, mutation
   check, and a formal proof of the AHB side with yosys + ABC).
   **LCD:** `src/rtl/video/` = scan-out core for the Sipeed 5" 800×480 RGB panel (regs on EXTS
   @ `0xE8001000`, pixel clock = Ethernet PLL CLKOUT2 33.3 MHz). It reads the RGB565
   framebuffer straight from DDR3 through the bridge's read-only **video port** (not
   EXTM — reading over EXTM cost the CPU ~37% of its memory bandwidth). Linux fbdev
   driver `PATCHES/0006` (software rendering, fbcon); sim `src/rtl/video/tb/run_tb.sh`,
   hardware check `src/apps/tests/fbtest.c`. See src/rtl/video/README.md.
   **Audio:** `src/rtl/audio/` = PT8211 (I2S-like DAC, E22/F24/G24, PA_EN H17) output core on
   EXTS @ `0xE8002000`, 2048-frame FIFO + threshold IRQ (EXT_INT[1] = PLIC source 11),
   NCO sample rate, frame counter + CRC for bit-exact checks, and a 64-bit DMA fetch
   engine (arbiter master 3 on EXTM) that reads the ALSA buffer as a ring up to a
   driver-committed byte limit (the SoC's own DMAC hangs on any fabric access, see
   doc/06-key-findings.md). Linux ALSA driver `PATCHES/0007` (`gowin-pt8211`, card 0;
   DMA mode by default, `pio=1` for the old interrupt-fill scheme). Sim `src/rtl/audio/tb/run_tb.sh`, hardware check
   `src/apps/tests/wavplay.c` (raw ALSA ioctl player, 16-bit mono/stereo WAV). See src/rtl/audio/README.md.
   **Sensors:** `src/rtl/sensor/` = the FPGA's two hard ADC cores (ADCLRC die temperature,
   ADCULC supply rails; primitives instantiated directly, no pins, internal OSC) behind
   a free-running scan sequencer on EXTS @ `0xE8004000` (`HADDR[14]`). Linux hwmon
   driver `PATCHES/0008` (`gowin-adc`: temp1_input, in0..7). The AE350 SoC itself has no
   thermal block; the board has no current sense, so no power measurement. See
   src/rtl/sensor/README.md.
   **Desktop + input:** `src/apps/desktop/` = LVGL 9.6 desktop (`lvdesk`, static musl) on
   `/dev/fb0` with system monitor, file browser, WAV player, network, console and
   settings panels, started on VT 1 by `S70desktop`; keyboard/mouse come from the PC
   over TCP (`src/apps/desktop/host/netinput.py` → `inputd` on the board → `/dev/uinput`, kernel
   #59+ with EVDEV/UINPUT). LVGL sources live in `~/projects/ae350_linux_user_level/lvgl/`.
   See src/apps/desktop/README.md.
   **Fan:** `src/rtl/fan/` = PWM + tacho core on EXTS @ `0xE8008000` (`HADDR[15]`) for the
   Dock's 4-pin fan header M1 (PWM T17, tacho T18, bank 2). Dock rev 4071d drives the
   fan's PWM pin, rev 4071f switches its 5 V through a P-MOSFET (inverted: DT
   `gowin,pwm-inverted`). Linux hwmon `PATCHES/0009` (`gowin-fan`: pwm1, fan1_input),
   fan curve `S80fan`. See src/rtl/fan/README.md.
   **microSD:** `src/rtl/sdhost/` = native 4-bit SD host with CRC engines and a 64-bit DMA
   master (arbiter master 2) on EXTS @ `0xE8020000` (`HADDR[17]`), IRQ EXT_INT[2] =
   PLIC 12, for the Dock slot J19 (CLK D23, CMD D24, DAT0..3 H23/J23/A25/B25, detect
   J15). Linux `PATCHES/0011` (`gowin-sdhost` mmc_host, 64 KB bounce buffer) →
   `/dev/mmcblk0`, mounted at `/mnt/sd` by `S45sdcard`. The earlier SPI-mode route (`sdspi/`
   core + `spi-gowin` + mmc_spi, PATCHES/0010) and Gowin's native SD IPs (never answered on
   this board) were removed from the tree on 2026-11-01; see src/rtl/sdhost/README.md.
2. **`led_blink` — a disabled sample.** Counter-based LED blinker (`CLK_FREQ_HZ` /
   `BLINK_HZ` params) on the board's `clk`=P16 / `rst_n`=K16 / `led`=J14. Files present
   but `enable="0"` in the `.gprj`. To switch back to it: enable its three files, disable
   the AE350 files, set `TopModule` to `led_blink`, and use `STAGE=… TOP=led_blink`.

- `mega_138K_test.gprj` — Gowin project file (XML). Lists sources/constraints via
  `<FileList>`; each `<File>` has `enable="1|0"`.
- `scripts/gw_run.sh` + `gw_run.tcl` — drive `gw_sh` (synthesis / PnR / bitstream)
  headlessly. `scripts/gw_program.sh` — program the board via `programmer_cli`.
  All adapted from `~/projects/tang_nano_9K_ov7670`.
- `external/{u-boot,opensbi,linux}` — git **submodules**: the board forks of the Linux boot
  stack (phoenix367/tang-mega-138k-{u-boot,opensbi,linux}, one port commit each on top of
  upstream; `git submodule update --init` after cloning). `scripts/build_uboot.sh`,
  `config_uboot.sh` and `build_linux_boot.sh` default to these paths. See BUILD.md §4.
- `src/firmware/` — bare-metal **AE350 test firmware** (RISC-V, rv32imac) that runs on
  the SoC: UART2 banner/heartbeat + LED waterfall + key readback. Self-contained
  build (`make`) using the SDK BSP; flashed to SPI flash `0x600000` via
  `src/firmware/flash_fw.sh`. See `src/firmware/README.md`.
- `impl/mega_138K_test_process_config.json` — synthesis, place-and-route, and bitstream
  settings. `TopModule` selects the active top. Generated build output
  (`impl/gwsynthesis/`, `impl/pnr/`) also lands under `impl/`.

### Dual-purpose configuration pins (AE350)

The AE350 drives the SPI-flash interface on the FPGA's **dedicated MSPI/config pins**.
Those are reserved by default, so PnR fails with `PR2017 … dedicated pin (MSPI)` /
`PR2028` unless the process config releases them: `CPU`, `MSPI`, and `SSPI` must all be
`true` (matched from the AE350 reference's `impl` config). They are set that way now —
keep them `true` for any design that reuses config pins, `false` otherwise.

## Build and program

Set `GOWIN_PATH` to the Gowin install root (the dir containing `IDE/`); on this
machine that is `/mnt/data/Gowin_V1.9.12.02_SP2_linux`.
Cross toolchains: Andes `nds32le-elf-newlib-v5` (bare metal) and `nds32le-linux-glibc-v5d`
(U-Boot/OpenSBI/kernel) under `ANDES_ROOT` (default `/mnt/data/toolchains`), Bootlin musl
(rootfs) in `~/projects/`; see BUILD.md "Toolchains". `docker/bootstrap.sh` + `docker/run.sh`
build everything in a container with the Gowin install bind-mounted. Scratch builds that
need space go under `/mnt/data/build/` (the root disk is nearly full).

```
# Synthesis only
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux STAGE=syn scripts/gw_run.sh
# Place-and-route + bitstream (-> impl/pnr/mega_138K_test.fs)
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux STAGE=pnr scripts/gw_run.sh
# Both
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux STAGE=all scripts/gw_run.sh

# Program (MODE=sram volatile [default] | flash persistent)
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux MODE=sram scripts/gw_program.sh
```

`gw_run.sh` runs `open_project` then `run syn|pnr|all` in `gw_sh`; `gw_program.sh`
runs `programmer_cli --device <DEVICE> --run <2=SRAM|6=embFlash> --fsFile <.fs>`.
The default programmer `DEVICE` is `GW5AST-138B` — verify it against
`programmer_cli --device-list` for the exact part. The Gowin IDE GUI is an
equivalent fallback (open `mega_138K_test.gprj`).

## Target device

`gw5ast138b-007` — Gowin **Arora V** GW5AST-138B, ~138K LUTs. Keep device-specific
choices (BSRAM/DSP primitives, I/O standards, clock resources) consistent with this part.

Key settings already chosen in `impl/mega_138K_test_process_config.json`:
- Synthesis tool: **GowinSyn**; Verilog standard **SystemVerilog 2017**, VHDL **1993**.
- Bitstream `FORMAT`: binary; `CRC_CHECK` and `SECURITY_BIT` on.
- `CPU` / `MSPI` / `SSPI` are `true` to free the SPI-flash/config pins for the AE350
  (see above).
- `Promote_Physical_Constraint_Warning_to_Error: true` — constraint warnings fail the
  build, so pin/timing constraints must be complete and correct.
- `TopModule` selects the active design (currently `ae350_demo_top`).

The reference design targets `gw5ast138b-002`; this project is `-007` (same Pro Dock
board/FPG676 package, different speed-grade variant). The generated AE350/PLL/DDR3 IP
synthesizes and place-and-routes unchanged on `-007` — verified (≈5% LUT, 8% BSRAM).

## Working in this repo

- Add HDL to `src/rtl/` and register each file in the `<FileList>` of `mega_138K_test.gprj`
  (the GUI does this automatically; if editing by hand, mirror Gowin's `<File>` entries
  with the right `type=` — `file.verilog`, `file.cst`, `file.sdc`).
- Every port needs a valid `IO_LOC` in the `.cst` before place-and-route — given the
  warning-as-error setting above, P&R fails (error `CT1113`, "Can't find pad location")
  on any missing or invalid pin. Get real pad numbers from the board schematic/pinout
  or the IDE FloorPlanner.
- Generated `impl/` artifacts are build output, not source.

## Linux userspace sources

Sources (tarballs + extracted trees) of every library and application cross-built for the
board's rootfs — busybox, dropbear, doas, htop, tcpdump, sftp-server, LVGL, etc. — live
**outside this repo** in `/home/ivan/projects/ae350_linux_user_level/`, one subdirectory
per package plus a shared `staging/` prefix for static libs. They are all unmodified
upstream; what this repo versions is the recipe: one `scripts/rootfs/build_<pkg>.sh` per
package (upstream URL + sha256, configure/make lines, atomic-free check, `INSTALL=1` to
replace the rootfs file; `build_all.sh` runs them all; busybox's config is
`linux/busybox.config`). Add every new userspace package the same way, not in the session
scratchpad or `/tmp`, so it can be rebuilt later. The binaries go into `linux/rootfs/`
(static musl, soft-atomic libc — see doc/02-build.md), from which the kernel build bakes
the initramfs; nothing copied onto the live board persists.
