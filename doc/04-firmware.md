# Bare-metal firmware

`firmware/src/main.c` is a self-contained rv32imac program (XIP from flash at
`0x8000_0000`, data/stack in DDR) that exercises the SoC and the `eth_dma` engine
*before* any OS. It is flashed to `0x60_0000` in place of U-Boot.

It does two things:

1. **Config dump** — prints `misa`, `marchid`/`mimpid`, the cache/`mmsc` CSRs, and
   a clock calibration (`mcycle` vs the 50 MHz PLMT `mtime`) over UART2.
2. **`dma_selftest`** — a 7-stage exercise of the Ethernet DMA datapath using PHY
   internal loopback, with the non-coherent cache recipe applied per frame.

Build with `-DREF_TEST_CLK` (see [02-build.md](02-build.md)).

## DMA self-test stages

| # | Test | What it proves |
|---|---|---|
| 1 | CSR read / write-back (`RX_BASE`, `TX_BASE`) | EXTS slave + register block alive |
| 2 | MDIO read PHY id regs 2,3 (`001c.c916` = RTL8211F) | MDIO controller + PHY reachable |
| 3 | single 64 B frame, CPU→TX→MAC→**PHY loopback**→RX→CPU | end-to-end DMA datapath |
| 4 | 8 varied-size frames + ring wrap | ring indexing, NAPI-style consume, no drops |
| 5a | 20 B payload (MAC pads to 60) | runt padding |
| 5b | full 1500 B MTU frame | max-size frame integrity |
| 6 | fill ring + send `RING_LEN` more unconsumed | exact drop count, kept frames intact |
| 7 | loopback round-trip throughput | informational (ring-depth + poll bound, ~18 Mbps) |

> Stages 4 and 5b previously failed (frames >64 B corrupted) — that was the
> under-constrained RGMII RX clock, **not** the datapath. After constraining
> `rgmii_rxclk` to 125 MHz the suite passes `[1]`–`[7]`. See
> [06-key-findings.md](06-key-findings.md).

## Self-test data flow (stage 3)

```mermaid
sequenceDiagram
  participant CPU as A25 firmware
  participant CSR as eth_dma CSR (0xE8000000)
  participant TXR as TX ring (DRAM)
  participant DMA as eth_dma engine
  participant MAC as TSE MAC
  participant PHY as RTL8211F (loopback)
  participant RXR as RX ring (DRAM)

  CPU->>CSR: MDIO write BMCR=0x4140 (loopback + 1000M/FD)
  CPU->>TXR: build frame [word0={len}][data…]
  Note over CPU: ae350_dma_writeback_range(buf)  ← flush D-cache
  CPU->>CSR: program TX_BASE/RING_LEN, bump TX_TAIL, rx_en/tx_en
  DMA->>TXR: m1 AHB read frame
  DMA->>MAC: tx_mac byte stream
  MAC->>PHY: RGMII TX
  PHY-->>MAC: RGMII RX (looped back)
  MAC-->>DMA: rx_mac byte stream
  DMA->>RXR: m0 AHB write [word0={err,len}][data…], bump RX_HEAD, IRQ
  Note over CPU: poll RX_HEAD; ae350_dma_invalidate_range(buf)  ← invalidate D-cache
  CPU->>RXR: read frame, compare to sent
  CPU->>CSR: cleanup: DMA off, PHY reset 0x8000 (so Linux boots clean)
```

## Non-coherent cache recipe (used by `eth_tx_put` / `eth_rx_get`)

The A25 has L1 D-cache but **no coherence manager**, so the CPU and the DMA see
different views of DRAM unless the cache is maintained explicitly:

- **Before TX:** `ae350_dma_writeback_range(buf, len)` — write dirty cache lines
  back to DRAM so the DMA reads the data the CPU wrote.
- **After RX:** `ae350_dma_invalidate_range(buf, len)` — drop stale cache lines so
  the CPU reads the data the DMA wrote.

These wrap the AndeStar V5 L1 CCTL operations. The same pattern is what the Linux
`gw_tse` driver does via `CONFIG_RISCV_DMA_NONCOHERENT`.

## Useful firmware CSRs (debug)

`firmware/src/gw_eth_dma.h` mirrors the register map. Debug-only CSRs surface the
DMA/AHB handshake when bringing up new gateware:

- `TX_DBG 0x70` / `RX_DBG 0x74` = `{cmd_done_cnt[31:16], busy[0]}`
- `EXTM_DBG 0x78` = `{hresp, hreadyout, htrans, hsel}` (also on debug pins
  U16=hsel / U15=hreadyout)
