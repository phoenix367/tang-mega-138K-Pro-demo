# Gowin AE350 Ethernet — descriptor-ring DMA design

> Design notes written before and during the implementation. The engine as built is
> described in `doc/05-eth-dma.md` (current block list, CSRs, burst mode, numbers);
> where the two differ, that document is the one that matches the RTL.

Goal: replace the single-frame PIO path (`gw_ahb_ethernet` bridge + `gw_tse.c`)
with a **descriptor-ring DMA**, so many frames are in flight and throughput is no
longer capped by the per-frame round-trip. The PIO driver is preserved at
`drivers/net/ethernet/gowin/gw_tse_pio.c.bak`.

## Findings that shape the design

- **The Gowin TSE MAC IP has no frame buffer** (IPUG538 §4.3.1): it is a pure
  byte-stream MAC. Interface (in `gw_ahb_ethernet_top`, exposed today):
  - RX: `rx_mac_clk`, `rx_mac_valid`, `rx_mac_data[7:0]`, `rx_mac_last`,
    `rx_mac_error`; post-frame `rx_statistics_valid` + `rx_statistics_vector[26:0]`
    (frame length [21:6], fcs/len/align err, type).
  - TX: `tx_mac_clk`, `tx_mac_valid`, `tx_mac_data[7:0]`, `tx_mac_last`,
    `tx_mac_ready` (backpressure), `tx_collision`/`tx_retransmit`; post-frame
    `tx_statistics_*`. Pause: `tx_pause_req/val/source_addr`.
  - MDIO: `miim_*` (already driven by `gw_tse.c`'s phylib path — reuse).
  - The single-frame ceiling is the **`gw_ahb_ethernet` PIO bridge**, NOT the MAC.
- **DRAM access path: the SoC's `EXTM_*` external-AHB-master-in port** (today tied
  off in `ae350_demo.v`). A fabric master on `EXTM` reaches DRAM through the SoC's
  own interconnect — no custom DDR3 multi-master arbiter needed.
- **Register/CPU interface: the `EXTS_*` external-AHB-slave port** (where the PIO
  bridge sits today, CPU base 0xE8000000). The DMA's control/status registers live
  here; the CPU programs the rings via EXTS, the DMA moves data via EXTM.
- **No coherence manager** ([[ae350-amo-cache-miss-hang]]): DMA buffers in DRAM are
  NOT cache-coherent with the CPU. The bare-metal ATCDMAC300 driver shows the
  recipe — writeback CPU cache before TX, invalidate after RX. The Linux driver
  must use the streaming DMA API (`dma_map_single` + `dma_sync_*`), and RISC-V
  Linux needs Andes cache-op hooks (the A25 likely lacks Zicbom CMOs).
- **Linux reference:** `drivers/net/ethernet/altera/` (`altera_tse` + `altera_sgdma`/
  `altera_msgdma`) — same MAC family, NAPI + ring DMA, already written for streaming
  (non-coherent) DMA. Our register map differs → a *custom* driver, modeled on it.

## Gateware: `gw_eth_dma` (new, replaces `gw_ahb_ethernet`)

```
          rx_mac_* (125MHz) --> [RX CDC FIFO] --> [RX engine] --EXTM write--> DRAM rx ring
 MAC <--  tx_mac_* (125MHz) <-- [TX CDC FIFO] <-- [TX engine] <--EXTM read--- DRAM tx ring
          EXTS (50MHz, slave)  <--> [CSR + descriptor pointers]  --> eth_int
```

- **RX engine:** pack the 8-bit stream into 32-bit words; on `rx_mac_last`, take the
  length from `rx_statistics_vector[21:6]`; write the frame to the current RX
  descriptor's buffer (EXTM burst writes), then mark the descriptor OWN=CPU + raise IRQ.
  Drop if no free descriptor (count it). Must drain at line rate (no MAC buffer).
- **TX engine:** when a TX descriptor is OWN=DMA, EXTM-read its buffer, stream to
  `tx_mac_*` honoring `tx_mac_ready`; on done, mark OWN=CPU + IRQ. Handle
  `tx_retransmit`/`tx_collision` (half-duplex) by replaying from the buffer.
- **CDC:** async FIFOs between `*_mac_clk` (125 MHz @ 1G) and the EXTM/EXTS bus clock
  (50 MHz). Depth ≥ one MTU so an EXTM stall can't underrun/overrun the MAC stream.
- **EXTM master:** AHB-lite master; incrementing bursts; 32-bit (the DDR path is
  64-bit but the SoC interconnect adapts). Arbitrate RX-write vs TX-read vs
  descriptor access internally (RX has priority — it can't backpressure the wire).

### CSR map (EXTS slave, base 0xE8000000) — draft
| off | reg | notes |
|----|-----|-------|
|0x00| CTRL | bit0 rx_en, bit1 tx_en, bit2 promisc, bit3 soft_reset |
|0x04| IRQ_STATUS | bit0 rx_done, bit1 tx_done, bit2 rx_drop (W1C) |
|0x08| IRQ_ENABLE | mask |
|0x10| RX_RING_BASE | phys addr of RX descriptor ring |
|0x14| RX_RING_LEN | # descriptors |
|0x18| RX_TAIL | CPU writes to hand descriptors to the DMA |
|0x20| TX_RING_BASE | phys addr of TX descriptor ring |
|0x24| TX_RING_LEN | |
|0x28| TX_TAIL | CPU writes to start TX |
|0x30| MIIM_* | reuse the existing MDIO regs (0x700.. in PIO map) or re-expose here |
|0x40| ETH_MODE / speed | from phy adjust_link |

### Descriptor format (16 bytes, in DRAM) — draft
```
word0: buf_addr (phys)
word1: length [13:0] | flags (SOP/EOP always single-buf for MTU)
word2: status (rx: frame len, err bits from statistics; tx: collisions)
word3: OWN bit [31] (1=DMA owns) + reserved
```
Ring is a power-of-two array; head/tail indices; OWN bit hands off between CPU/DMA.

## Linux driver `gw_tse_dma.c` (NAPI ring)

- probe: ioremap EXTS CSRs; `dma_set_mask(32)`; alloc RX/TX descriptor rings
  (`dma_alloc_coherent` if it works on this arch, else streaming-mapped + sync);
  alloc RX skbs, `dma_map_single` each, fill the RX ring, write RX_RING_BASE/LEN.
- NAPI poll: walk the RX ring for OWN=CPU descriptors; `dma_sync_single_for_cpu` /
  unmap; `napi_gro_receive`; refill with a fresh mapped skb; advance RX_TAIL.
- xmit: `dma_map_single(skb->data)`; fill a TX descriptor; `dma_sync_*_for_device`;
  advance TX_TAIL; stop the queue when the ring is full; TX-done IRQ frees + wakes.
- IRQ: ack IRQ_STATUS; `napi_schedule`. Reuse the phylib/MDIO + adjust_link from
  `gw_tse_pio.c`.
- Keeps everything atomic-safe (the soft-atomic headers cover the ring/refcount ops).

## Non-coherent DMA glue (the risky bit)

RISC-V Linux non-coherent DMA expects `arch_sync_dma_for_{device,cpu}` to do cache
writeback/invalidate. Mainline uses Zicbom CMOs. The A25 uses Andes `mcctl`-style
cache ops (cf. SDK `ae350_dma_writeback_range`/`invalidate_range`). Plan: enable
`CONFIG_RISCV_DMA_NONCOHERENT` + DT `dma-noncoherent`, and provide the cache ops —
either Zicbom if the core actually implements it, or a small Andes-cache shim in
`arch/riscv/mm/`. **Validate early** (a tiny DMA test) before trusting the NIC.

## Build milestones
1. `gw_eth_dma` RTL: RX engine + TX engine + CDC + EXTM master + EXTS CSRs.
2. Simulate against the ref-design TB (`.../RefDesign/tb/tb.v`, RGMII PHY model) —
   verify RX-to-DRAM and DRAM-to-TX before touching hardware.
3. Wire into `ae350_demo.v`: connect `EXTM_*` (un-tie-off), keep `EXTS_*`, MAC
   stream to `gw_eth_dma`; re-PnR (watch 125 MHz timing + the new EXTM master).
4. Non-coherent DMA glue + a standalone DMA self-test.
5. `gw_tse_dma.c` driver + DT (`dma-noncoherent`); bring up, debug, benchmark.

## Build progress / decisions

Work area: `mega_138K_test/eth_dma/{rtl,tb}`. Verification = **iverilog simulation**
(self-checking testbenches). **Formal (sby/yosys/z3) dropped — z3 BMC was too slow**
to be practical here.

Reuse the verified **FPGADesignElements** library (LaForest), at
`~/projects/tang_nano_9K_ov7670/FPGADesignElements` — ready/valid handshake modules.
Compile/sim with `iverilog -g2012 -y <lib> -I <lib>` (libdir auto-resolves modules;
`-I` for `clog2_function.vh`). Use `CDC_FIFO_Buffer` for the MAC↔bus CDC,
`Pipeline_FIFO_Buffer` / `Pipeline_Skid_Buffer` for sync buffering.

- **`rtl/ahb_master.v`** — AHB-lite master DMA mover (EXTM side). v1 single-beat
  (2 cyc/word), command + ready/valid-ish data ports. **iverilog PASS** (16-word
  AHB write→read round-trip vs `tb/ahb_slave_ram.v`). TODO: INCR bursts for speed.
- **`CDC_FIFO_Buffer`** (library) validated as the 125→50 MHz crossing — **iverilog
  PASS** (1000 words, in order). **KEY: the multi-bit CDC pointer handshake starts X
  in sim; both `input_clear` and `output_clear` must be asserted TOGETHER and held
  long enough** (covering several cycles of both clocks) to reset it — short/staggered
  clears leave it deadlocked (data in, none out). Matters for the real reset design.

- **`rtl/cdc_fifo_reset.v`** — safe reset generator for the CDC FIFO, built on
  the library **`Reset_Synchronizer`**. Extends `arst_n` by HOLD in_clk cycles
  into one common `ext_arst_n`, fed to a `Reset_Synchronizer` per domain.
  **iverilog PASS** (drives `CDC_FIFO_Buffer` clean from a single async reset,
  500 words). **KEY: the two clears must DE-assert ~together too** — a staggered
  release (faster clock's clear drops first) leaves the FIFO with data in / none
  out. The common-extended-reset approach guarantees aligned release.
- **`rtl/rx_capture.v`** — RX engine, MAC side (rx_mac_clk). Byte stream →
  little-endian 32-bit word pack + one-cycle per-frame trailer (`frame_len`,
  `frame_err`; error sampled at `rx_mac_last`). **iverilog PASS** (lengths
  1/4/14/60/64, error flag).

- **`rtl/rx_ring_writer.v`** — RX engine, bus side. Pops the metadata trailer +
  data words (ready/valid, from the CDC FIFOs) and DMAs each frame via
  `ahb_master` into a ring of 2 KB DRAM buffers: word0 = header `{err,len}`,
  word1+ = data. `rx_head`/`rx_tail` flow control, drop-on-full (still drains the
  data so streams stay aligned), per-frame IRQ. **iverilog PASS** (3 frames to
  the ring, headers + data correct, 0 drops, vs `ahb_master` + `ahb_slave_ram`).

- **`rtl/rx_path.v`** — full RX path integration: `rx_capture` → data + metadata
  `CDC_FIFO_Buffer` (clears from `cdc_fifo_reset`) → `rx_ring_writer` → `ahb_master`.
  **iverilog PASS end-to-end** (`tb/tb_rx_path.v`): 3 frames driven into the MAC
  byte stream @125 MHz cross the CDC into the 50 MHz bus domain and DMA into the
  DRAM ring intact (headers + data correct, 0 drops). **RX PATH COMPLETE.**
  (Note: the FIFOs' `input_ready` is unused — the MAC can't backpressure — so the
  data FIFO must cover worst-case bus latency; sustained 1 G also needs INCR
  bursts in `ahb_master`. Both fine for first bring-up / sub-line-rate.)

- **`rtl/tx_unpack.v`** — TX engine, MAC side (tx_mac_clk). Reverse of rx_capture:
  reads len (metadata FIFO) + words (data FIFO), unpacks LE → `tx_mac` bytes
  (valid/data/last, honoring `tx_mac_ready`), `frame_done` pulse. Gates on the
  metadata token (pushed after all data → whole frame already across the CDC) so
  no mid-frame underrun. **iverilog PASS** (`tb/tb_tx_unpack.v`: 3 frames, correct
  bytes + last, under ~75% random `tx_mac_ready` back-pressure). The `tx_mac_*`
  outputs come from a 2-entry skid buffer (125 MHz timing). The tb also checks that
  there are no mid-frame gaps in `tx_mac_valid`.

- **`rtl/tx_ring_reader.v`** — TX engine, bus side. Reads a queued frame from the
  TX ring via `ahb_master` (header→len, then data words → data FIFO), then pushes
  the len token to the metadata FIFO (after all data → no MAC underrun). Serial v1,
  paced by `tx_head`. **iverilog PASS** (within tx_path).
- **`rtl/tx_path.v`** — full TX integration: `tx_ring_reader` + `ahb_master` →
  data + metadata `CDC_FIFO_Buffer` (clears from `cdc_fifo_reset`) → `tx_unpack` →
  `tx_mac`; completion = `frame_done` toggle → `CDC_Bit_Synchronizer` → bus edge →
  `tx_head`. **iverilog PASS end-to-end** (`tb/tb_tx_path.v`: 3 frames DRAM→DMA→CDC
  →tx_mac intact, tx_head=3, under random `tx_mac_ready` back-pressure). **TX PATH
  COMPLETE. Both RX and TX datapaths are now simulation-verified.**

- **`rtl/csr.v`** — AHB-lite slave register block (EXTS, 0xE8000000): CTRL
  (rx_en/tx_en), IRQ_STAT(W1C)/IRQ_EN, RX/TX BASE/LEN/TAIL (rw) + HEAD/DROP/FETCH
  (ro), MDIO ADDR/WD/CTRL/STAT, ETH_MODE. Zero-wait slave (address-phase capture,
  data-phase service). **iverilog PASS** (`tb/tb_csr.v`: register round-trip,
  status reads, IRQ latch+mask+W1C, MDIO trigger+result).

- **Arbiter decision**: use the **Gowin `AHBBusArbiter` IP** (16 masters → 1 slave,
  fixed priority, 32-bit AHB; verified vendor IP) to merge RX (master0, write) + TX
  (master1, read) onto the single `EXTM` port. Keeps `rx_path`/`tx_path` unchanged
  (each keeps its `ahb_master`); RX wins contention via priority. Encrypted → not
  iverilog-simulable, so sim uses `tb/ahb_arbiter_beh.v` (a ~30-line behavioral
  2-master stand-in, priority on each master's new `busy` output).
- **`rtl/gw_eth_dma_core.v`** — top: `csr` + `rx_path`(m0) + `tx_path`(m1), exposing
  both AHB master ports (→ arbiter) + the MAC stream ports (→ encrypted MAC in
  ae350_demo.v) + MDIO + IRQ. Added `busy` to `ahb_master`/`rx_path`/`tx_path` and
  `tx_irq` to `tx_path` for the CSR.
- **FULL-CORE LOOPBACK iverilog PASS** (`tb/tb_gw_eth_dma.v`): CPU programs rings via
  the CSR, queues a TX frame; `tx_mac`→`rx_mac` loopback; frame round-trips
  CPU→TX→MAC→RX→CPU byte-intact, tx_head=1. **The entire DMA datapath is now
  simulation-verified.**

Next: (1) generate the Gowin `AHBBusArbiter` via the IP wizard + a thin
`Gowin_AHB_Arbiter_Top` wrapper. (2) Wire `gw_eth_dma_core` + the TSE MAC + the
arbiter into `ae350_demo.v` — un-tie `EXTM`, replace `gw_ahb_ethernet`, route the
MAC streams + MDIO + IRQ; CSR on EXTS at 0xE8000000. (3) Re-PnR, check 125 MHz
timing. (4) Linux: NAPI ring driver (gw_tse_dma.c) + DT + the non-coherent DMA
cache glue (validate with a standalone DMA self-test first).

## Risks
- 125 MHz CDC timing + EXTM-stall vs MAC no-buffer (RX FIFO must absorb bus latency).
- EXTM master correctness + arbitration with the CPU on the SoC interconnect.
- Non-coherent cache ops on the A25 under Linux (biggest unknown).
- Descriptor/buffer coherence (OWN-bit ordering vs cache sync).

## Driver performance pass (Oct 2026, `linux/driver/gw_tse.c`)

Profiled with a perf_event_open sampler on the board (TCP to/from the host,
DDR3-800 + 100 MHz memory bus). The CPU is busy at only ~2-3k frames/s; the
driver was ~15% of it, the rest the TCP/IP stack spread thinly (slow in-order
core, no L2, ~1.4 us DRAM miss, soft atomics, `rdtime` trapping to OpenSBI).

Fixed in the driver:
- **Cache coherence**: RISC-V marks DT devices DMA-coherent by default and rv32
  has no uncached page attribute, so `dma_alloc_coherent()` returned plain
  *cached* memory with no maintenance at all (RX could read stale lines). Rings
  are now kmalloc + streaming mappings; RX slots are invalidated before reading,
  TX slots written back before the doorbell (A25 CCTL ops). The driver clears
  `dev->dma_coherent` itself.
- Frame copies: ring data (0 mod 4) vs skb data (2 mod 4) made the riscv
  `memcpy` byte-copy; `gtse_copy()` uses aligned words with a 16-bit shift.
- TX-done interrupts only while the queue is stopped (was one per frame);
  TX_HEAD read only when the ring looks full; doorbell batched by `xmit_more`.
- Rings 64 RX / 32 TX (module params `rx_ring`, `tx_ring`).

Measured (32 MB transfers, md5-checked both ways):

| | before | after |
|---|---|---|
| RX TCP (board `wget`) | 23.6 Mbit/s | 24.8 Mbit/s |
| TX TCP (host `curl` from board `httpd`) | 29.6 Mbit/s | 36.0 Mbit/s |
| UDP TX blast, 1472 B | 2.1k pps | 3.3k pps |
| eth IRQs per benchmark run | 144k | 58k |

**RX is limited by the gateware, not the driver**: the RX DMA writes DRAM with
single-beat 32-bit AHB writes (half of the 64-bit EXTM port) at only ~7-8k
full frames/s (~10-12 MB/s). With an idle board only the first 6-7 frames of a
line-rate burst survive (staging + CDC FIFO ~8 KB); TCP bursts from the host
therefore lose ~5% of frames (RX_DROP == host retransmits). Next lever: INCR
bursts / 64-bit writes in `ahb_master` and more RX buffering.

Follow-ups (Oct 2026):
- **PHY reset on reconfiguration** (`src/rtl/ae350_demo.v`): `PHY_RST_N` used to be
  just the S3 button, so an FPGA reload stopped PHY_CLK under a running PHY.
  After that the RTL8211F could no longer train gigabit (downshifted to 100M at
  ~15 s, on every later load, even at the U-Boot prompt) until a power cycle.
  The PHY is now held in reset until the Ethernet PLL is locked + 21 ms (and on
  S3); gigabit came back without a power cycle and holds across reloads.
- **Bufferable EXTM writes do not help**: HPROT[2]=1 for the RX DMA writes (data,
  then header, then a read-back for ordering) left the RX DMA rate unchanged
  (same burst-loss curve), so the SoC does not post them on this path; reverted.
  The ~17 bus cycles per 32-bit EXTM write remain; the options are AHB bursts /
  64-bit beats through EXTM (gain unknown) or a dedicated DMA port into
  `ddr_bridge` that bypasses the SoC interconnect.
- **AHB bursts fix the RX DMA rate** (`ahb_master` v2): writes now go out as
  pipelined INCR16/8/4 bursts (32-bit beats, never across 1 KB); reads stay
  single beats. The SoC's EXTM port handles bursts well: the RX DMA went from
  ~7.5k to ~63k full frames/s (~95 MB/s, ~78% of line rate). Line-rate burst
  loss on an idle board: 8 frames 24% -> 0%, 32 frames 72% -> 4%, 64 frames
  81% -> 10%. TCP RX 24.6 -> 34.8 Mbit/s, RX drops / host retransmits -74%
  (TX unchanged, 36 Mbit/s). Verified in sim against a wait-state slave with
  burst-protocol checks (tb_ahb_master, tb_rx_path WAIT_PCT) and on hardware
  (Build 40, md5 both ways). Remaining headroom: 64-bit beats (EXTM is 64-bit)
  would take the RX DMA past line rate; TX reads could use bursts too.
- **64-bit RX beats** (Build 43): the SoC charges per burst *start* (~16 cycles),
  and it streams only fixed-length bursts -- undefined-length INCR bursts are
  as slow as single transfers (Build 41) -- so the way to fewer burst starts is
  wider beats. The RX path is now 64-bit end to end on the bus side: a MAC-domain
  pair packer puts {w[2i+1], w[2i]} into a 64-bit CDC FIFO, rx_ring_writer
  realigns them behind the header (beat 0 = {w0, header}, beat k = {w[2k],
  w[2k-1]}) and writes header + data as one INCR16 command of 64-bit beats; the
  arbiter carries 64-bit data (the 32-bit TX master gets lane handling there)
  and extm_bridge is a pass-through. Same DRAM layout, so no driver change.
  Result: no drops for line-rate bursts of 8..64 frames (the whole ring); TCP RX
  34.8 -> 48-50 Mbit/s, RX drops 973 -> 0, host retransmits 974 -> 5; TX 35
  Mbit/s; md5 OK both ways incl. a 6-round bidirectional soak.
- **Threaded NAPI + IRQ deferral** (driver, kernel #48): in softirq context a
  UDP stream above ~3.4k frames/s (~250 us of stack work each) starved the
  receiving task -- receive livelock: 40 Mbit/s offered -> 0.4 Mbit/s delivered,
  every datagram dropped at the full socket buffer after the stack had paid for
  it. The driver now runs NAPI as a kernel thread (dev_set_threaded) and sets
  napi_defer_hard_irqs = 2, gro_flush_timeout = 200 us (all still tunable in
  /sys/class/net/eth0/). UDP RX lossless at 40/60/80 Mbit/s, ~85 Mbit/s under a
  line-rate flood (the excess dropped in the hardware ring); TCP RX 48-50 ->
  65 Mbit/s, TX 36 -> 40 Mbit/s; ping 1.4 ms. While the board transmits, some
  of the host's ACKs overflow the RX ring (harmless; a 128-deep ring did not
  help), so the ring stays 64.
