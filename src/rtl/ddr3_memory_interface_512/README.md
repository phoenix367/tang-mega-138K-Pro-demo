# DDR3 IP netlist, 400 MHz, 15 row bits (512 MB)

**Superseded** on 2026-10-29 by `../ddr3_memory_interface_1g/` (same with `DQ_WIDTH = 32`: both
chips, 1 GB); kept in the project with `enable="0"`. Was active between the 400 MHz x16 netlist and the 1 GB one. Same generation flow and timings as `../ddr3_memory_interface_400/`
(H5TQ4G63EFR at DDR3-800, see its README), with `ROW_WIDTH = 15` in `gwmc_param.v`: the
board's Hynix 4 Gbit x16 chip has 15 row bits, so the 16-bit bus reaches all 512 MB of it
(the stock 14-row netlist aliased the upper half onto the lower). User port: `addr[28:0]`
(x16 word address, top bit 0), `O_ddr_addr[14:0]` (row bit 14 goes out on the `DDR3_ADDR14`
pin, U5). The bridge follows with `ADDR_BITS = 29` (ahb_ddr3_top), the DTS `memory@0` is 512 MB.

The board actually has two of these chips on a 32-bit bus (1 GB; Sipeed's examples use
`DQ_WIDTH = 32`); using the second needs a 256-bit bridge datapath, see src/rtl/ddr_bridge/README.md.

Regeneration on this machine needs the same preload as scripts/gw_run.sh, or GowinSynthesis
aborts on its Qt platform plugin:

    LD_PRELOAD="/lib/x86_64-linux-gnu/libstdc++.so.6 /lib/x86_64-linux-gnu/libfreetype.so" \
    LD_LIBRARY_PATH=$GOWIN_PATH/IDE/lib QT_QPA_PLATFORM=offscreen \
    $GOWIN_PATH/IDE/bin/GowinSynthesis -prj DDR3.prj     # then mv ddr3_memory_interface.vg ...v
