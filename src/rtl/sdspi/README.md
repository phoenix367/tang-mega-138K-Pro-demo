# src/rtl/sdspi/ — microSD card (SPI mode)

The Dock's microSD slot **J19** (schematic sheet FPGA_STORAGE, same on rev 4071d
and 4071f) is wired to the FPGA through 0 Ω links, with 10 kΩ pull-ups on every
data line and RCLAMP ESD protection:

| card pin | FPGA pin (bank) | SPI-mode use |
|---|---|---|
| CLK | **D23** (5), 22 Ω series | SCK |
| CMD | **D24** (5) | MOSI |
| DAT0 | **H23** (4) | MISO |
| DAT3/CD | **B25** (5) | CS_N |
| DAT1 | J23 (4) | unused (pulled up) |
| DAT2 | A25 (5) | unused (pulled up) |
| DET | **J15** (2) | card detect, 0 = inserted |

Earlier attempts with Gowin's native SD IPs (`apb_sd_top`, `APBSDHost`) never got
a response from a card. This design keeps the gateware minimal — a plain SPI
master — and lets the mainline kernel do the SD protocol: the **`mmc_spi`** host
driver talks to the card in SPI mode through a small **`spi_controller`** driver
for the core. Every SD/MMC command, CRC, timeout and the block device come from
the stock MMC stack, which is why this route is robust.

## Core (`rtl/sdspi_core.v`)

AHB-lite slave on EXTS @ `0xE8010000` (`HADDR[16]`, 8 KB window), zero-wait with
the address sampled in the address phase (needed for the buffer RAMs).

| offset | name | bits |
|---|---|---|
| 0x0000 | CTRL | [0] CS_N level (reset 1), [15:8] DIV, [16] discard RX |
| 0x0004 | STATUS | [0] busy, [1] card inserted, [27:16] bytes of the last LEN |
| 0x0008 | LEN | write 1..2048 = transfer that many bytes |
| 0x000C | ID | `0x53445350` "SDSP" |
| 0x0800 | TX buffer | 2 KB, little-endian words (byte 0 first) |
| 0x1000 | RX buffer | 2 KB, same layout |

SPI mode 0, MSB first, SCK = 50 MHz / (2 × (DIV + 1)): DIV 0 = 25 MHz, DIV 62 =
397 kHz for card initialisation. A transfer shifts LEN bytes out of the TX
buffer while capturing MISO into the RX buffer; CS is a register bit so the
host can hold it across command/response/data transfers as mmc_spi requires.
`tb/run_tb.sh`: iverilog bench against an SPI slave model (byte order, clock
divider, 2 KB transfer, discard mode, card detect).

## Linux

`PATCHES/0010` → `drivers/spi/spi-gowin.c` (`SPI_GOWIN`, DT `"gowin,ae350-spi"`)
plus `CONFIG_MMC_SPI`; DT node `spi0: spi@e8010000` with a `mmc-spi-slot` child
(25 MHz max, 3.3 V, no card-detect GPIO so the MMC core polls the slot once a
second). The card appears as `/dev/mmcblk0` (partitions `mmcblk0p1`…);
`/etc/init.d/S45sdcard` mounts the first partition (or the whole device) at
`/mnt/sd` at boot, and the desktop's file browser has an "SD card" entry.

```
dmesg | grep -i "mmc\|spi"            # host, card, capacity
cat /proc/partitions
/etc/init.d/S45sdcard start           # (re)mount after inserting a card
mkfs.vfat /dev/mmcblk0p1              # if the card is blank
```

Throughput is CPU-bound PIO (mmc_spi issues a command, token, data and CRC
transfer per 512-byte block): about 1.0 MB/s read and 0.9 MB/s write at 25 MHz SCK.
A native 4-bit host on the same pins (DAT0..3), ideally with a DMA master like
the Ethernet core, would be the upgrade path if that ever matters.

Two findings while tuning (worth knowing for every MMIO driver on this SoC):
- The card's output delay (up to 14 ns) plus the 22 Ω series resistor and the
  FPGA I/O exceed the 20 ns half period at 25 MHz, so MISO is sampled on the
  **falling** SCK edge (a full period after the card drove it), `CTRL[17]`
  selects the early (rising-edge) sampling if ever needed. With rising-edge
  sampling everything passed at 400 kHz and the first 25 MHz read (SCR) failed.
- `writel()` costs about 1.8 µs on the A25 because its `fence w,o` waits for the
  posted write to complete, while `writel_relaxed()` issues in 230 ns; the
  driver fills the 2 KB buffer with relaxed writes and relies on the fence of
  the final LEN write. That alone doubled the throughput.
