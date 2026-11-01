# AE350 DRAM Atomics / Cache Coherence Issue

**Status:** hardware/IP limitation, **worked around**: the whole stack (OpenSBI, Linux,
musl) runs single-hart with software atomics (`PATCHES/`, `doc/06-key-findings.md`),
and Linux has been stable on it since mid-2026. This file is the original investigation
and is kept as the reference for *why*; bare-metal / RTOS code that never uses the A
extension on DRAM is unaffected.

**Target:** Gowin GW5AST-138B (`gw5ast138b-007`), Andes **A25** core (RV32IMAFDC,
`misa=0x4094312d`, `marchid=0x80000a25`, `mimpid=0x00000160`), Tang Mega 138K Pro Dock.

---

## TL;DR

The A25 in this Gowin AE350 SoC has **no Coherence Manager (CM)**. Atomic
read-modify-write (the RISC-V **A** extension) only works on a cache line the hart
**already owns exclusively** (i.e. one it just stored to). On any **clean, evicted, or
not-yet-cached** line:

- **`AMO*` instructions hang** (the access escapes to the bus and nothing services it).
- **`LR`/`SC` never converges** — `SC` fails forever (can't upgrade a clean line to
  exclusive without a CM).

Linux and OpenSBI perform atomics on arbitrary/evicted DRAM constantly, so they cannot
run. There is **no software workaround** (LR/SC fails too; the AMO *hangs* rather than
faulting, so it can't be trap-and-emulated).

---

## Symptom chain that led here

1. U-Boot boots fully; payloads run. OpenSBI (generic, RV32, fw_payload with embedded
   FDT, `FW_TEXT_START=0x0`) reaches `sbi_init` but dies **before its banner**.
2. Bisected with direct-UART trace markers to the **first DRAM atomic**:
   `atomic_xchg(&coldboot_lottery, 1)` in `lib/sbi/sbi_init.c` → `amoswap.w` on a
   `.bss` line at ~`0x43000` → **hang**.
3. Many false leads ruled out (see below) before isolating it to **AMO-on-cache-miss**.

(Earlier, genuine priv-1.10 fixes were also needed and are correct: `CLEAR_MDT`
no-op'd, trap handler not reading `mstatush`/H-ext CSRs, boot-hart lottery skipped.
Those are unrelated to this atomics issue.)

---

## Evidence (bare-metal firmware probe)

Firmware runs the SDK BSP `__platform_init` (cache enable) then tests atomics directly.
`src/firmware/src/main.c` → `amo_at()` (hot-line) and `test_amo_cold()` (`[A]/[C]/[D]`).

CPU state at test time (identical in firmware **and** U-Boot):
```
mcache_ctl = 0x00000003   (only IC_EN|DC_EN; prefetch/write-around/COHEN bits hardwire 0)
mmisc_ctl  = 0x00000048
misa       = 0x4094312d   (A present)
L2 @0xe0500000 = 0xffffffff  (no L2 controller present)
```

Results:
```
# Hot line (store, THEN atomic) — at 0x43000, 0x100000, 0x04000000, 0x08000000:
  amoswap/add/xor/and/or/min/max/minu/maxu : ALL OK
  lr/sc (after a store)                    : sc=0 (success)

# [A] flush + LOAD (read-allocate) + amoswap        -> OK   (atomic on a refilled HIT)
# [C] flush + LR/SC once (cold)                      -> no hang, but sc=1 (SC failed), no write
# [D] flush + LR/SC RETRY LOOP (cold)                -> tries=20, sc=1, never writes  (NEVER converges)
# [B] flush + amoswap (cold miss)                    -> HANGS  (no completion)
```

Interpretation:
- The region **is** cacheable and the cache holds lines fine (load- and store-allocate
  both work; atomic on a held line works).
- The failure is specific to obtaining **exclusive ownership for an atomic RMW** on a
  line the hart doesn't already own — which is the Coherence Manager's job. With
  `DC_COHEN` (mcache_ctl bit 19) **hardwired 0**, there is no CM, so:
  - `AMO` forwards to the bus → hang.
  - `SC` cannot upgrade clean→exclusive → fails permanently.

The SDK `__platform_init` itself proves the absence: it writes `mcache_ctl=0x82603`
(requesting prefetch + write-around + CM), but only `0x3` sticks, and its own
`if (read_csr(NDS_MCACHE_CTL) & (1<<19))` CM check evaluates **false** on this part.

Direct before/after probe (`test_platform_init()`), confirming the CM bit cannot be set:
```
[INIT] mcache_ctl BEFORE         = 0x00000003
[INIT] mcache_ctl AFTER 0x82603  = 0x00000003   <- writing 0x82603 changes nothing
[INIT] DC_COHEN(b19)=0  DC_COHSTA(b20)=0         <- coherency agent hardwired off
```

**Restated in AXI terms (per Gowin/Andes guidance):** RISC-V AMOs are issued as **AXI
exclusive accesses (AWLOCK/ARLOCK)**; LR/SC use the same exclusive-monitor path. The
AE350 AXI interconnect / DDR3 memory interface here does **not** support exclusive
accesses, and there is **no on-chip coherency agent** (`DC_COHEN` won't set) to grant
them — so the exclusive transaction never gets a response: `amoswap` hangs, `sc` never
succeeds. Verified on normal cacheable WB DRAM (not MMIO), latest OpenSBI ruled out (the
probe is bare-metal, no firmware).

---

## Why the SDK demo & U-Boot "looked" fine

- The SDK `ae350_atomic` demo passes because its atomic operates on the **stack**
  (always recently-stored → owned/hot → the working case).
- U-Boot itself uses no DRAM atomics, so it boots normally; the hang only appears once
  OpenSBI/Linux issue an atomic on a non-owned line.
- The whole "U-Boot vs firmware" difference was a red herring — both have
  `mcache_ctl=0x3`; it was always **hit vs miss**.

---

## Things tried that did NOT fix it

| Attempt | Result |
|---|---|
| `mcache_ctl` = `0x3` vs OR'd `0x8272b` vs exact `0x82603` | no change; extra bits don't stick; exact write mid-flight **hangs** |
| Enable D-cache coherency (`DC_COHEN`) + wait `DC_COHSTA` | bit 19 hardwired 0 → CM not present |
| Clear `mmisc_ctl.NON_BLOCKING_EN` | already 0; no effect |
| Regenerate SoC with `sharedDdr3RWMode=false` | AMO-miss still hangs |
| **Customized/Extended Data Memory route** (`ENABLE_CUSTOMIZED_DATA=true`, `ENABLE_DDR3=false`; SoC `DDR_H*` AHB → `gw_ahb_ddr3_top` bridge → external `DDR3_Memory_Interface_Top`, copied from SDK `ae350_customized`) | bitstream built & runs, **DDR R/W works**, but AMO-on-miss **still hangs** (A25 doesn't fall back to read-allocate on an atomic miss) |
| LR/SC instead of AMO | `SC` never succeeds on non-owned lines |

The Gowin AE350 IP wizard exposes **no L2 / Coherence-Manager / atomic option**
(plugin dialogs: Ddr3, Dmac, Dtcm, Itcm, Plic, Spi2, Uart, ApbExt, InsMem, RiscV —
none for coherence). The A25 IP doc lists only "Instruction and Data caches, Local
Memories, ECC for L1" — **no L2**.

---

## Current gateware state

The project is left on the **Customized-AHB-DDR3** configuration (DDR works; only
atomics-on-miss are affected):

- `src/rtl/gw_ahb_ddr3_top.v`, `src/rtl/gw_ahb_ddr3.v`,
  `src/rtl/ddr3_memory_interface/ddr3_memory_interface.v` (from SDK `ae350_customized`),
  registered in `mega_138K_test.gprj`.
- SoC regenerated with `ENABLE_CUSTOMIZED_DATA=true`, `ENABLE_DDR3=false`,
  `ENABLE_SPI_FLASH=true`, `ENABLE_EXTENDED_APB_SLAVE=true` (SD controller kept).
- `src/rtl/ae350_demo.v`: SoC `DDR_H*` AHB master ↔ `gw_ahb_ddr3_top` ↔ DDR3 PHY.
- `.cst`/`.sdc`: DDR3 DLL/clock paths updated to
  `u_gw_ahb_ddr3_top/u_gw_ahb_ddr3/u_ddr3_memory_ahb_top/u_ddr3/gw3_top/u_ddr_phy_top/...`.

(Reverting to the simpler embedded-DDR3 SoC is also valid for bare-metal use; the
atomics behavior is the same either way.)

---

## Paths forward

1. **Gowin / Andes support (recommended).** File the evidence above and request an
   **AE350/A25 configuration with a Coherence Manager** (or L2) so atomic RMW works on
   DRAM. Concise report: *"RV32A atomics on DDR fail — `amoswap` on a cache-miss hangs,
   LR/SC `sc.w` never succeeds on a non-owned line, `mcache_ctl.DC_COHEN` reads 0 (no
   CM). Need a config where atomics on DRAM work for Linux."*
2. **Bare-metal / RTOS.** Fully functional today (SoC + DDR3 + SPI-flash XIP + UART2 +
   GPIO + SD-over-SPI via `apb_sd_top`). Atomics on owned lines / TCM work.
3. **A coherent RISC-V SoC** if Linux is a hard requirement.

---

## Reproduce

Flash the probe firmware and read UART2 (B19 @ 115200):
```
cd firmware && make
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux \
  FW=$PWD/build/ae350_fw.bin SPIADDR=0x600000 ./flash_fw.sh
GOWIN_PATH=/mnt/data/Gowin_V1.9.12.02_SP2_linux MODE=sram ../scripts/gw_program.sh
# press S3; watch the AMO / [A]/[C]/[D] section.  [B] (cold amoswap) hangs.
```
