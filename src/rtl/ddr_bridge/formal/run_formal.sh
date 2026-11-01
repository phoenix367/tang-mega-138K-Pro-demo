#!/usr/bin/env bash
# Formal safety check of the bridge's AHB side (the assertions under
# `ifdef FORMAL` in rtl/ahb_ddr3_bridge.v).  Builds the same model SymbiYosys
# would -- stubs.v for the clock-crossing FIFOs and the BIST, data cut into free
# values -- and runs ABC on it directly:
#   bmc3 -F DEPTH   no assertion can fail within DEPTH cycles of reset
#   pdr             unbounded: the assertions hold in every reachable state
# Why not sby: with yosys 0.33, sby's ABC trace post-processing fails
# (KeyError 'asserts'), and Z3 through yosys-smtbmc does not finish even step 0
# of this model.  bridge_ahb.sby keeps the Z3 BMC tasks for newer tools.
# Usage: [PDR=0] formal/run_formal.sh [small|full] [depth]
#   small: 12-bit address space, 4 line buffers (default)   full: 30-bit, 8 buffers
#   PDR=0 skips the unbounded proof (it can take a long time on the full size)
set -u
CFG="${1:-small}"
DEPTH="${2:-20}"
cd "$(dirname "$0")"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
PARAM=""
[ "$CFG" = small ] && PARAM="chparam -set ADDR_BITS 12 -set NBUF 4 ahb_ddr3_bridge"

yosys -q -l "$OUT/yosys.log" -p "
read_verilog -formal -DFORMAL ../rtl/ahb_ddr3_bridge.v
read_verilog -formal ../../pipe_counter.v
read_verilog -formal stubs.v
$PARAM
prep -top ahb_ddr3_bridge
flatten
memory_map
opt_clean
cutpoint w:ent_data* w:cl_data w:wb_data w:wb_mask w:wh_data w:wq_mem* w:hrdata_q w:rf_data w:rfq_d
cutpoint w:pc_* w:uc_* w:ucnt w:tq* w:hq_d w:is_d w:tq_wd_q w:cfq_data w:umode_s* w:wgap w:rgap
opt_clean
memory_nordff
async2sync
chformal -assume -early
opt_clean
formalff -setundef -clk2ff -ff2anyinit -hierarchy
chformal -live -fair -cover -remove
opt_clean
setundef -undriven -anyseq
opt -fast
hierarchy -simcheck
formalff -assume
setattr -unset keep
delete -output
opt -full
techmap
opt -fast
memory_map -formal
formalff -clk2ff -ff2anyinit
simplemap
dffunmap
aigmap
opt_clean
write_aiger -I -B -zinit -no-startoffset -map $OUT/design.aim $OUT/design.aig
" > /dev/null 2>&1 || { echo "FORMAL ($CFG): model build failed, see $OUT/yosys.log"; exit 1; }

# ABC numbers the failing property (an index into the asserts of the FORMAL
# block, not necessarily in source order); for a trace use bridge_ahb.sby with
# a newer sby/yosys, or simulate
explain() { echo "  failing property: miter output $1"; }

fail=0
bmc=$(timeout 1800 yosys-abc -c "read_aiger $OUT/design.aig; fold; strash; bmc3 -F $DEPTH" 2>&1)
if echo "$bmc" | grep -q "No output asserted in $DEPTH frames"; then
    echo "FORMAL ($CFG) bmc3: no assertion fails within $DEPTH cycles"
else
    echo "FORMAL ($CFG) bmc3: FAIL"; echo "$bmc" | grep -E "asserted|rror" | head -3
    idx=$(echo "$bmc" | sed -n 's/.*Output \([0-9]*\) of miter.*/\1/p' | head -1)
    [ -n "$idx" ] && explain "$idx"
    fail=1
fi
if [ "${PDR:-1}" = 0 ]; then
    pdr="skipped"
else
    pdr=$(timeout 3600 yosys-abc -c "read_aiger $OUT/design.aig; fold; strash; pdr" 2>&1)
fi
if [ "$pdr" = skipped ]; then
    echo "FORMAL ($CFG) pdr: skipped"
elif echo "$pdr" | grep -q "Property proved"; then
    echo "FORMAL ($CFG) pdr: proved for all reachable states"
elif echo "$pdr" | grep -q "asserted in frame"; then
    echo "FORMAL ($CFG) pdr: FAIL"; echo "$pdr" | grep -E "asserted" | head -3
    idx=$(echo "$pdr" | sed -n 's/.*Output \([0-9]*\) of miter.*/\1/p' | head -1)
    [ -n "$idx" ] && explain "$idx"
    fail=1
else
    echo "FORMAL ($CFG) pdr: undecided (bounded result above still holds)"
    echo "$pdr" | tail -2
fi
[ $fail = 0 ] && echo "FORMAL PASSED" || echo "FORMAL FAILED"
exit $fail
