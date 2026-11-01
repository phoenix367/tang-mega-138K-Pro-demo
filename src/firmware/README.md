# AE350 test firmware

Bare-metal test firmware for the Andes **AE350 RISC-V SoC** built into this
project's gateware (top `ae350_demo_top`), running on the **Tang Mega 138K Pro
Dock**. It exercises the two peripherals wired to the board's user IO:

- **UART2** (TX=W20, RX=Y20) — prints a banner once, then a periodic heartbeat.
- **GPIO** — LED waterfall on `LED[2:0]` (GPIO 0..2) and reads `KEY[2:0]`
  (GPIO 3..5).

## Layout

```
src/main.c            test application
src/bsp/              AE350 BSP copied from the SDK (RiscV_AE350_SOC_V1.3),
                      Emb_TCM/ae350_demo: startup, drivers, console, linker
Makefile              standalone build (no AndeSight needed)
flash_fw.sh           program the .bin into SPI flash via Gowin programmer_cli
```

Two local patches make the Andes BSP build with a generic RISC-V GCC instead of
the Andes toolchain (which the SDK assumes):
- `src/bsp/sag/ae350-xip.ld` — added `PROVIDE(__global_pointer$ = . + 0x800)`
  (the Andes linker auto-provides this; GNU ld does not).
- `src/bsp/ae350/trap.c` — one `__nds__mfsr(NDS_MHARTID)` → `read_csr(NDS_MHARTID)`
  (the `__nds__mfsr` intrinsic only exists in Andes GCC).

## Build

Toolchain: the Andes bare-metal GCC (`nds32le-elf-newlib-v5`, `riscv32-elf-*`) under
`ANDES_ROOT` (default `/mnt/data/toolchains`). Any rv32imac bare-metal GCC works:
override `CROSS=`. The `payload/` build is linked `-nostdlib` and therefore passes
`-mno-save-restore` (otherwise GCC emits calls to libgcc's `__riscv_save_*` helpers).

```
make                  # -> build/ae350_fw.{elf,bin,lst,map}
```

Target is **rv32imac_zicsr_zifencei / ilp32**, **BUILD_XIP**: code executes in
place from SPI flash at `0x80000000`; `.data`/`.bss`/stack live in DDR3
(`0x00000000`, stack `0x08000000`). Image is ~3.8 KB.

## Flash + run

The board's SoC instruction flash is the **same SPI NOR that holds the FPGA
bitstream** (Winbond W25Q128, 16 MB). Standard layout (from the SDK Flash
example doc):

| Flash offset | Contents              | CPU view     |
|--------------|-----------------------|--------------|
| `0x000000`   | FPGA bitstream (`.fs`)| (config)     |
| `0x600000`   | AE350 firmware (`.bin`)| `0x80000000` (XIP) |

```
# 1. Program firmware to SPI flash @ 0x600000 (exFlash C Bin, Arora V = run 55)
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux ./flash_fw.sh

# 2. (Re)load the AE350 gateware so the CPU boots and XIP-reads the firmware.
#    programmer_cli leaves its own SPI-bridge on the FPGA after step 1, so
#    re-run the SRAM load (or flash the bitstream to 0x0 for a persistent boot).
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux ../scripts/gw_program.sh
```

The AE350 holds the CPU in reset until DDR3 calibration completes, then fetches
from `0x80000000` (= flash `0x600000`) and runs this firmware.

## Observing it

- **LEDs**: `LED[2:0]` (R26 / L20 / M25) waterfall ~continuously.
- **UART2 = U16 (TXD) / V16 (RXD)** — the official AE350 console pins for this
  board (from `TangMega-138KPro-example/ae350_customized_demo`). Read it with a
  **logic analyzer or an external 3.3 V USB-TTL adapter on U16** (adapter RX <- U16,
  GND <- GND) at the firmware's baud (currently **9600 8N1** — see `UART_BAUD` in
  `src/main.c`).
  - The board's onboard FT2232 ch-B (`/dev/ttyUSB1`, "Sipeed USB Debugger") is the
    JTAG debugger's channel and does **not** work as a plain user UART here, so the
    firmware output is not readable through it — use the LA / external adapter.
  - Baud note: build **must** define `REF_TEST_CLK` (set in the Makefile). Without it
    the BSP assumes a 100 MHz APB clock (real = 50 MHz) and every baud comes out at
    half. With it, the requested baud is correct (verified: 9600 -> 104.3 us/bit).
- Press `KEY[2:0]` (K16 / F15 / G15) and the printed `KEY[2:0]=` bits change.
