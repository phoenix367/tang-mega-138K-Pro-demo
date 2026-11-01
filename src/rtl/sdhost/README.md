# src/rtl/sdhost/ — native 4-bit SD host with DMA

Replaces the SPI-mode path of the former `sdspi/` core (removed from the tree on
2026-11-01 together with Gowin's unused SD IPs; git history has them) for the Dock's
microSD slot **J19**. Same pins, now used as the real SD
bus:

| card pin | FPGA pin (bank) | use |
|---|---|---|
| CLK | D23 (5), 22 Ω series | SD clock, host output |
| CMD | D24 (5) | command / response, bidirectional |
| DAT0..3 | H23 (4), J23 (4), A25 (5), B25 (5) | data lanes, bidirectional |
| DET | J15 (2) | card detect (0 = inserted) |

All lines have 10 kΩ pull-ups on the Dock; the FPGA I/Os add `PULL_MODE=UP`.

## Gateware

- `rtl/sdhost_core.v` — AHB-lite slave on EXTS @ `0xE8020000` (`HADDR[17]`) and a
  64-bit AHB master (`src/rtl/eth_dma/rtl/ahb_master.v`, INCR16 bursts) that moves blocks
  between a 128×64-bit FIFO and DDR. The FIFO is a synchronous-read BSRAM whose read
  address is the pointer after the current pop, so the head word is always present
  (as it was with the original flop array), plus a bypass register for a write into
  the location being read; the flop array (8k flip-flops behind a 128:1 mux on a
  4099-fanout pointer) had been the second-longest path of the 50 MHz domain, into
  the CRC engine and the arbiter's write-data mux. Everything runs on the 50 MHz bus clock; the
  SD clock is a divided register output (25 MHz at DIV 0, 397 kHz at DIV 62).
  Outputs change on the SD falling edge. Inputs are sampled one bus clock
  (20 ns) **after** the SD rising edge by default (`CTRL[16]` = 1 samples on the
  edge): the card launches on the rising edge with up to 14 ns delay, and with the
  Dock's 22 Ω and the FPGA's clock-output and input paths the on-edge sample
  failed at 25 MHz on hardware (CRC/end-bit errors; everything passed at
  397 kHz), while the late sample has the card's own output delay as hold margin.
  - **Command engine:** 48-bit command with CRC7; 48-bit (R1/R1b/R3/R6/R7) or
    136-bit (R2) responses, CRC7 and index checks selectable per command,
    response timeout after 80 clocks, R1b busy wait on DAT0 (TIMEOUT register).
  - **Data engine:** BLKCNT blocks of BLKSIZE (8..512, multiple of 8) over 1 or 4
    lanes with a CRC16 per lane. Reads: start bit, data, CRC compare, end bit.
    Writes: Nwr gap, start bit, data, CRC, end bit, then the card's CRC-status
    token (010 = accepted) and busy. One DMA command per block
    (`DMA_ADDR + n·BLKSIZE`); the FIFO holds two 512-byte blocks so a read never
    stalls the card while the DMA drains.
  - Sticky STATUS bits (done / timeout / CRC / end-bit / CRC-status / DMA / FIFO)
    with an INT_EN mask → `EXT_INT[2]` = PLIC source 12.
- The EXTM arbiter with SD as the third master (priority: Ethernet RX > SD >
  Ethernet TX) is `src/rtl/audio/rtl/ahb_arbiter4.v` (audio DMA as the fourth master,
  below SD); the earlier three-master `ahb_arbiter3.v` was removed on 2026-11-01.
- `tb/` — `run_tb.sh`: the core + DMA on a 64-bit AHB memory with random wait
  states against `sd_card_model.v` (a behavioural card: identification, CID/CSD/
  SCR, CMD17/18/24/25/12, ACMD6, CRC checking, injectable CRC error). The bench
  runs the Linux init sequence, 4-bit and 1-bit multi-block writes/reads
  compared through memory, 8-byte register blocks, and the error paths.

Register map (byte offsets): CTRL 0x00 (clk en, 4-bit, soft reset, DIV[15:8]),
ARG 0x04, CMD 0x08 (index, response type, CRC/index/busy/data/write flags;
writing starts), RESP0..3 0x0C..0x18, BLK 0x1C (size | count<<16), DMA 0x20,
STATUS 0x24 (W1C sticky bits [18:8]), INT_EN 0x28, TIMEOUT 0x2C, ID 0x30
("SDHC"), DBG 0x34. Details in the file header.

## Linux

`PATCHES/0011` → `drivers/mmc/host/gowin-sdhost.c` (`MMC_GOWIN_SDHOST`, DT
`"gowin,ae350-sdhost"`, node `sdhost0: mmc@e8020000`, `bus-width = <4>`,
`max-frequency = <25000000>`): a regular MMC host. One request = one command with
its data moved by the core's DMA to/from a 64 KB bounce buffer (streaming DMA
mapping, so the cache maintenance comes from the A25 CCTL patches); completion
by interrupt; CMD12 issued by the driver after multi-block data. Card detect is
read from the core and polled by the MMC core. The card appears as
`/dev/mmcblk0`, mounted at `/mnt/sd` by `S45sdcard`. The desktop's Files panel shows
the card as a mountable resource (size, free space, Mount/Unmount button, "safe to
remove" when unmounted) and browses it under "SD card".

## Results (Build 61, kernel #66, 4 GB class-10 card)

| | native 4-bit host | SPI-mode path (former `sdspi/`) |
|---|---|---|
| sequential read | 6.0–6.6 MB/s | 1.0 MB/s |
| sequential write | 3.0 MB/s | 0.9 MB/s |

16 MB of random data written and read back bit-exact, zero MMC errors. The
driver tuned the card to 25 MHz with late sampling on the first fast read
("tuned: 25000 kHz, late sampling" in dmesg). The remaining gap to the 12.5 MB/s
wire rate is the bounce-buffer copy and per-request overhead on the A25; direct
scatter-gather DMA would be the next step if ever needed.

Note for anyone switching between the SPI and native paths: a card initialised
in SPI mode stays in SPI mode until its power is cycled, and reloading the FPGA
does not cut the card's supply. Re-seat the card (or power-cycle the board).

