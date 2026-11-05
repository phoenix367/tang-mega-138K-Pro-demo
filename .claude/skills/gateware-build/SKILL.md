---
name: gateware-build
description: Simulate, synthesize, place-and-route, check, load and flash the Tang Mega 138K AE350 FPGA gateware (core testbenches, scripts/gw_run.sh, PnR timing and resource check, scripts/flash.sh load/bitstream, boardtest), then record the new Build N in BOOT.md. Use this whenever RTL under src/rtl, the .cst/.sdc constraints, the .gprj or the IP configs change, or the user asks for a new bitstream or "Build N", synthesis, PnR, a timing-closure or utilization check, or to load/flash the bitstream — even when phrased as "rebuild the gateware", "does it meet timing" or "put the new core on the board".
---

# Gateware: simulate → build → check → load → test → flash → record

The active design is `ae350_demo_top` (`src/rtl/ae350_demo.v`): the Andes AE350 hard SoC
and the fabric cores around it. `CLAUDE.md` and `doc/01-architecture.md` describe it.
A PnR run takes ~15 min and needs the floating licence, so the cheap checks come first.

Set this once per shell:
```
export GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux
```

## 1. Before PnR

- **Simulate what changed.**
  - Each core has `src/rtl/<core>/tb/run_tb.sh` (iverilog).
  - The DDR bridge has `src/rtl/ddr_bridge/tb/run_all.sh`: regression, mutants, and
    formal (needs `yosys-abc`).
  - The JPEG path also has `src/rtl/idct/tb/run_jpeg_tb.sh`.

  PnR cannot fix RTL that fails simulation, and simulation needs no licence.
- **Register new files and pins.**
  - A new HDL file goes into `mega_138K_test.gprj`'s `<FileList>`
    (`<File path="src/rtl/…" type="file.verilog" enable="1"/>`).
  - A new top-level port needs `IO_LOC` / `IO_PORT` lines in `src/rtl/ae350_demo.cst`.
    The process config promotes physical-constraint warnings to errors, so a missing
    pin fails PnR (`CT1113`).
- **Keep these settings.**
  - `CPU`, `MSPI`, `SSPI` = `true` in `impl/mega_138K_test_process_config.json`: the
    SoC's flash uses the MSPI configuration pins, and PnR fails with `PR2017` / `PR2028`
    otherwise.
  - `Place_Option 2`, `Route_Option 0`: Route 2 aborts with `PR0004`, and Place 0/1
    missed timing.

## 2. Build

```
STAGE=all scripts/gw_run.sh    # synthesis + PnR → impl/pnr/mega_138K_test.fs (run_in_background)
STAGE=syn scripts/gw_run.sh    # synthesis only: syntax, resources, a quick look
```

`gw_run.sh` retries six times when the licence server refuses. If "License verification
failed" persists, the server is down. Tell the user and stick to simulation; another
loop will not help.

## 3. Check the result

```
python3 .claude/skills/gateware-build/scripts/pnr_summary.py
```

It prints:
- each clock's Fmax against its constraint;
- failing setup and hold endpoints;
- logic, BSRAM, DSP and clock-wire use;
- whether the bitstream fits below `0x600000`, where U-Boot starts in flash.

Exit status 1 means something failed.

Reading it:
- **Every clock must meet its constraint.** Gowin's placer stops improving a path once
  its slack is positive, so a few picoseconds is normal. `ddr3_sysclk` carries an extra
  0.3 ns of uncertainty in the SDC on purpose. Look at the worst paths
  (`impl/pnr/mega_138K_test_tr_content.html`, the `report_timing` sections) when a
  domain fails or drops a lot against the previous build.
- **The tight domains.**
  - `ae350_ahb_clk`: 51.06 MHz in Build 72 against 50. The worst paths are the EXTS
    read mux and the JPEG core, so any new EXTS slave adds to them.
  - `ddr3_sysclk`: the bridge's read return and the BIST.
- **RGMII RX capture.** Setup ~1.6 ns, hold ~1.2 ns on the `rgmii_rxclk` input paths.
  If they swing (hold near 0.2 ns), the RX clock has lost its LW clock wire, and gigabit
  receive will fail. All 16 global clock wires are in use and pinned by `CLOCK_LOC` in
  the `.cst`.
- **Fixes that worked here** (`doc/06-key-findings.md`, timing sections):
  - `pipe_counter.v` for wide counters;
  - registers in cones that are used once per transaction;
  - registering paths into the SoC's pins;
  - pinned clock wires;
  - `APB_CLK` on its own PLL output.

## 4. Load into SRAM and test

```
scripts/flash.sh load        # volatile; the SoC resets and boots U-Boot + kernel from flash
scripts/board.py wait 180
python3 scripts/boardtest/boardtest.py        # all groups, ~5–6 min; close netinput.py first
```

- **SRAM is the safe way to try a bitstream.** A power cycle returns to the one in flash.
- **A feature that needs a new driver** is a kernel release as well (the
  `kernel-release` skill).
  - Drivers detect features through the cores' capability bits (video CAPS, idct
    STATUS[9:8], audio CAP).
  - Check that the flashed kernel still works on the new gateware.
- **Expected WARNs:** `kernel.time` (no internet) and `net.errors` (residual RGMII RX
  errors).

## 5. Write to flash

This replaces the bitstream every power-on uses. Do it only after the SRAM test passed
and the user wants the build in flash:
```
scripts/flash.sh bitstream   # .fs → flash 0x0
scripts/flash.sh load        # leave the programmer's SPI bridge (or power-cycle)
```

## 6. Record

- **BOOT.md**, flash table, the `0x000000` row: **Build N**, with:
  - the date;
  - "Build N-1 + what changed";
  - the clocks whose Fmax moved, and "all clocks met";
  - BSRAM x/340 and logic %;
  - where the `.bin` ends.

  Un-bold the previous build. The next number follows the last one in that row.
- **README.md** "Current state in flash".
- **For a new core or interface:**
  - `CLAUDE.md`: address, IRQ, EXTM master number, pins;
  - `doc/07-cores.md`: architecture, block diagram, register map;
  - the core's README and its testbench.
- **`doc/01-architecture.md`** §8.4 (timing history) and §8.5 (utilization) when the
  numbers change.
- **Commits only when the user asks.** `impl/` is build output and stays untracked,
  except `impl/mega_138K_test_process_config.json`.
