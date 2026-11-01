# DDR3 IP netlist, 400 MHz, x32 bus, 15 row bits (1 GB)

**Active** since 2026-10-29. Same generation flow and timings as `../ddr3_memory_interface_512/`
and `../ddr3_memory_interface_400/` (H5TQ4G63EFR at DDR3-800, CL 6, tRFC 260 ns, see the 400
README), with `DQ_WIDTH = 32` in `gwmc_param.v`: the board's two Hynix 4 Gbit x16 chips sit on
one 32-bit bus (Sipeed's own examples use this configuration), so the IP now drives both and
reaches all 1 GB. `gwmc_param.v` is otherwise identical to the 512 MB one (`ROW_WIDTH = 15`).

User port (what the bridge sees): `addr[28:0]` (x32 word address = byte >> 2, top bit unused),
`wr_data[255:0]` / `rd_data[255:0]` / `wr_data_mask[31:0]` -- one BL8 command moves 32 B = one
A25 L1 line -- and the DRAM side `O_ddr_addr[14:0]`, `O_ddr_dqm[3:0]`, `IO_ddr_dq[31:0]`,
`IO_ddr_dqs[3:0]`, `IO_ddr_dqs_n[3:0]`. The bridge follows with `ADDR_BITS = 30` and a 256-bit
datapath (ddr_bridge/README.md); the extra pins (`DDR3_DQ[31:16]`, `DDR3_DQS[3:2]`,
`DDR3_DM[3:2]`) are in `src/ae350_demo.cst`, taken from Sipeed's `ddr_test` /
`138K_PRO_DOCK.cst` examples (whose DQ[15:0] / DQS[1:0] / DM[1:0] / address pins match ours
exactly). `DDR3_ADDR[14]` (U5) is now part of the `DDR3_ADDR` bus instead of a separate port.
The DTS `memory@0` is 1 GB.

Regeneration on this machine needs the same preload as scripts/gw_run.sh, or GowinSynthesis
aborts on its Qt platform plugin (run from this directory; then rename the `.vg`):

    LD_PRELOAD="/lib/x86_64-linux-gnu/libstdc++.so.6 /lib/x86_64-linux-gnu/libfreetype.so" \
    LD_LIBRARY_PATH=$GOWIN_PATH/IDE/lib QT_QPA_PLATFORM=offscreen \
    $GOWIN_PATH/IDE/bin/GowinSynthesis -prj DDR3.prj     # then mv ddr3_memory_interface.vg ...v
