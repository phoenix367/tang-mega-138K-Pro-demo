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
   JTAG debug. Two PLLs (`gowin_pll_ae350` → 800 MHz core + 100 MHz data-memory `DDR_CLK` + 50 MHz AHB/APB + 10 MHz
   RTC; `gowin_pll_ddr3` → 400 MHz DDR3, netlist `src/ddr3_memory_interface_1g/`). `src/riscv_ae350_soc/` is encrypted Andes IP
   (`.v` synth source + `.vo` sim netlist) — regenerate via the IDE IP wizard, don't
   hand-edit. `src/key_debounce.v` debounces the DDR3/AE350 resets.
   DDR3 is **1 GB** (both x16 chips on the 32-bit bus, 15 row bits,
   `src/ddr3_memory_interface_1g/`, bridge `ADDR_BITS = 30`, 256-bit datapath: one BL8 =
   one 32 B line — see ddr_bridge/README.md; the x16 / 512 MB netlist stays disabled in
   `src/ddr3_memory_interface_512/`).
   DDR3 path: SoC data-memory AHB (`DDR_H*`) -> **`ddr_bridge/`** (`ahb_ddr3_top`,
   line-buffered bridge, replaces Gowin's `src/gw_ahb_ddr3*.v`, now `enable="0"`) ->
   DDR3 IP. `src/ddr_perf.v` = bus perf counters/trace + bridge MODE register on the
   SoC external APB @ `0xF8000000` (reset MODE 0x10000 = overlapped reads; needs the
   Linux page-table writeback patch `PATCHES/0005`, else use 0x100 — see
   ddr_bridge/README.md). Bridge RTL is validated with
   `ddr_bridge/tb/run_all.sh` (iverilog random regression, directed tests, mutation
   check, and a formal proof of the AHB side with yosys + ABC).
   **LCD:** `video/` = scan-out core for the Sipeed 5" 800×480 RGB panel (regs on EXTS
   @ `0xE8001000`, pixel clock = Ethernet PLL CLKOUT2 33.3 MHz). It reads the RGB565
   framebuffer straight from DDR3 through the bridge's read-only **video port** (not
   EXTM — reading over EXTM cost the CPU ~37% of its memory bandwidth). Linux fbdev
   driver `PATCHES/0006` (software rendering, fbcon); sim `video/tb/run_tb.sh`,
   hardware check `tests/fbtest.c`. See video/README.md.
   **Audio:** `audio/` = PT8211 (I2S-like DAC, E22/F24/G24, PA_EN H17) output core on
   EXTS @ `0xE8002000`, 2048-frame FIFO + threshold IRQ (EXT_INT[1] = PLIC source 11),
   NCO sample rate, frame counter + CRC for bit-exact checks; no DMA. Linux ALSA driver
   `PATCHES/0007` (`gowin-pt8211`, card 0). Sim `audio/tb/run_tb.sh`, hardware check
   `tests/wavplay.c` (raw ALSA ioctl player, 16-bit mono/stereo WAV). See audio/README.md.
   **Sensors:** `sensor/` = the FPGA's two hard ADC cores (ADCLRC die temperature,
   ADCULC supply rails; primitives instantiated directly, no pins, internal OSC) behind
   a free-running scan sequencer on EXTS @ `0xE8004000` (`HADDR[14]`). Linux hwmon
   driver `PATCHES/0008` (`gowin-adc`: temp1_input, in0..7). The AE350 SoC itself has no
   thermal block; the board has no current sense, so no power measurement. See
   sensor/README.md.
2. **`led_blink` — a disabled sample.** Counter-based LED blinker (`CLK_FREQ_HZ` /
   `BLINK_HZ` params) on the board's `clk`=P16 / `rst_n`=K16 / `led`=J14. Files present
   but `enable="0"` in the `.gprj`. To switch back to it: enable its three files, disable
   the AE350 files, set `TopModule` to `led_blink`, and use `STAGE=… TOP=led_blink`.

- `mega_138K_test.gprj` — Gowin project file (XML). Lists sources/constraints via
  `<FileList>`; each `<File>` has `enable="1|0"`.
- `scripts/gw_run.sh` + `gw_run.tcl` — drive `gw_sh` (synthesis / PnR / bitstream)
  headlessly. `scripts/gw_program.sh` — program the board via `programmer_cli`.
  All adapted from `~/projects/tang_nano_9K_ov7670`.
- `firmware/` — bare-metal **AE350 test firmware** (RISC-V, rv32imac) that runs on
  the SoC: UART2 banner/heartbeat + LED waterfall + key readback. Self-contained
  build (`make`) using the SDK BSP; flashed to SPI flash `0x600000` via
  `firmware/flash_fw.sh`. See `firmware/README.md`.
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

- Add HDL to `src/` and register each file in the `<FileList>` of `mega_138K_test.gprj`
  (the GUI does this automatically; if editing by hand, mirror Gowin's `<File>` entries
  with the right `type=` — `file.verilog`, `file.cst`, `file.sdc`).
- Every port needs a valid `IO_LOC` in the `.cst` before place-and-route — given the
  warning-as-error setting above, P&R fails (error `CT1113`, "Can't find pad location")
  on any missing or invalid pin. Get real pad numbers from the board schematic/pinout
  or the IDE FloorPlanner.
- Generated `impl/` artifacts are build output, not source.

## Linux userspace sources

Sources (and tarballs) of every library and application cross-built for the board's
rootfs — busybox, dropbear, musl-linked tools, sftp-server, etc. — live **outside this
repo** in `/home/ivan/projects/ae350_linux_user_level/`, one subdirectory per package
(plus any build script next to it). Put every new userspace package there, not in the
session scratchpad or `/tmp`, so it can be rebuilt later. The binaries go into
`linux/rootfs/` (static musl, soft-atomic libc — see doc/02-build.md), from which the
kernel build bakes the initramfs; nothing copied onto the live board persists.
