# DDR3 IP netlist, 400 MHz (DDR3-800), x32 bus, 15 row bits (1 GB)

**Active** since 2026-10-29, the only DDR3 netlist in the tree (the stock 200 MHz x16 one
and the 400 MHz x16 steps, 14 and 15 row bits, were removed on 2026-11-01; git history
before that date has them under `ddr3_memory_interface/`, `_400/` and `_512/`).

Generated without the IDE wizard by running GowinSynthesis on the IP sources shipped with
the AE350 SoC IP, with `gwmc_param.v` from this directory:

    sources : IDE/ipcore/RiscV_AE350_SOC/data/{ddr3_1_4code_hs.v, DDR3_TOP.v}
    includes: that data dir + this dir (gwmc_param.v, DDR3_define.v, ddr3_name.v
              from any generated DDR3 IP temp/ dir)

Regeneration on this machine needs the same preload as scripts/gw_run.sh, or GowinSynthesis
aborts on its Qt platform plugin (run from this directory; then rename the `.vg`; retry on
license errors):

    LD_PRELOAD="/lib/x86_64-linux-gnu/libstdc++.so.6 /lib/x86_64-linux-gnu/libfreetype.so" \
    LD_LIBRARY_PATH=$GOWIN_PATH/IDE/lib QT_QPA_PLATFORM=offscreen \
    $GOWIN_PATH/IDE/bin/GowinSynthesis -prj DDR3.prj     # then mv ddr3_memory_interface.vg ...v

## Parameters (`gwmc_param.v`)

H5TQ4G63EFR-RDC (Hynix 4 Gbit x16) at DDR3-800, Sipeed's validated values for this board,
vs the stock AE350 default: CL 6 (was 5), tRFC 260 ns (4 Gbit; stock had the 2 Gbit 160 ns),
tRCD/tRP 15 ns, tRRD 10 ns, tCKE 10 ns, RTT_NOM 60. `ROW_WIDTH = 15` (the stock 14-row
netlist aliased the upper half of each chip onto the lower) and `DQ_WIDTH = 32`: the board's
two x16 chips sit on one 32-bit bus (Sipeed's own examples use this configuration), so the IP
drives both and reaches all 1 GB.

The 400 MHz clocking lives outside this directory: `src/rtl/gowin_pll_ddr3/gowin_pll_ddr3.v`
`ODIV2_SEL = 2` (VCO 800 -> 400 MHz) with the matching `Clkout2*` fields in its `.ipc`,
`src/rtl/ae350_demo.sdc` `ddr3_memory_clk` 2.5 ns / `ddr3_sysclk` 10 ns, and the ddr_perf
`CONFIG` low byte in `src/rtl/ae350_demo.v` = DDR3 MHz (`0x0190`). At 400 MHz Linux needs the
PATCHES/0005 kernel even in the bridge's MODE 0x100 (fork/exec oopses without it).

## User port

What the bridge sees: `addr[28:0]` (x32 word address = byte >> 2, top bit unused),
`wr_data[255:0]` / `rd_data[255:0]` / `wr_data_mask[31:0]` -- one BL8 command moves 32 B = one
A25 L1 line -- and the DRAM side `O_ddr_addr[14:0]`, `O_ddr_dqm[3:0]`, `IO_ddr_dq[31:0]`,
`IO_ddr_dqs[3:0]`, `IO_ddr_dqs_n[3:0]`. The bridge follows with `ADDR_BITS = 30` and a 256-bit
datapath (src/rtl/ddr_bridge/README.md); the extra pins (`DDR3_DQ[31:16]`, `DDR3_DQS[3:2]`,
`DDR3_DM[3:2]`) are in `src/rtl/ae350_demo.cst`, taken from Sipeed's `ddr_test` /
`138K_PRO_DOCK.cst` examples (whose DQ[15:0] / DQS[1:0] / DM[1:0] / address pins match ours
exactly). `DDR3_ADDR[14]` (row bit 14, pin U5) is part of the `DDR3_ADDR` bus. The DTS
`memory@0` is 1 GB. The bridge's DDR side runs on the IP's 100 MHz user clock (`clk_out`),
which is also the SoC's data-memory clock (Build 64+).
