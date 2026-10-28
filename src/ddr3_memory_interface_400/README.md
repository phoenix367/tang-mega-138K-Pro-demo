# DDR3 IP netlist for 400 MHz (DDR3-800), H5TQ4G63EFR-RDC timings

**Superseded** on 2026-10-29 by `../ddr3_memory_interface_512/` (same, with 15 row bits = all
512 MB of the chip); this one and the stock 200 MHz netlist in `src/ddr3_memory_interface/`
stay in the project with `enable="0"`.

Generated without the IDE wizard by running GowinSynthesis on the IP sources shipped with
the AE350 SoC IP, with `gwmc_param.v` from this directory:

    sources : IDE/ipcore/RiscV_AE350_SOC/data/{ddr3_1_4code_hs.v, DDR3_TOP.v}
    includes: that data dir + this dir (gwmc_param.v, DDR3_define.v, ddr3_name.v
              from any generated DDR3 IP temp/ dir)
    run     : LD_LIBRARY_PATH=$GOWIN_PATH/IDE/lib QT_QPA_PLATFORM=offscreen \
              $GOWIN_PATH/IDE/bin/GowinSynthesis -prj DDR3.prj   (retry on license errors)

Parameters vs the stock AE350 default: CL 6 (was 5), tRFC 260 ns (4 Gbit; stock had the
2 Gbit 160 ns), tRCD/tRP 15 ns, tRRD 10 ns, tCKE 10 ns, RTT_NOM 60 -- Sipeed's validated
Hynix 400 MHz values for this board, kept at x16 / 14 row bits (256 MB) to match the pinout.

The 400 MHz switch is four edits; reverse them to go back to 200 MHz:
- `.gprj`: enable this netlist, disable `src/ddr3_memory_interface/ddr3_memory_interface.v`;
- `src/gowin_pll_ddr3/gowin_pll_ddr3.v`: `ODIV2_SEL = 2` (VCO 800 -> 400 MHz; was 4), and the
  matching `Clkout2*` fields in `gowin_pll_ddr3.ipc`;
- `src/ae350_demo.sdc`: `ddr3_memory_clk` 2.5 ns, `ddr3_sysclk` 10 ns (were 5 / 20);
- `src/ae350_demo.v`: ddr_perf `CONFIG` low byte = DDR3 MHz (`0x0190`; 200 MHz = `0x00C8`).

At 400 MHz the bridge's DDR side runs on a 100 MHz user clock; ddr_bridge meets timing
there (see ddr_bridge/README.md). At 400 MHz Linux needs the PATCHES/0005 kernel even in
the bridge's MODE 0x100 (fork/exec oopses without it). The stock gw_ahb_ddr3 bridge does
NOT work at 400 MHz.
