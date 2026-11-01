#!/usr/bin/env bash
# Full ddr_bridge verification: randomized regression, directed checks,
# mutation check of the testbench, the ddr_perf monitor test, and the formal
# safety check of the AHB side (formal/run_formal.sh: ABC; the small
# configuration is proved for all reachable states, the full one bounded).
# Usage: tb/run_all.sh [regress_ops] [regress_seeds]   (run from src/rtl/ddr_bridge/)
set -u
cd "$(dirname "$0")/.."
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"/{regress,directed,mutants,perf,formal}
declare -A R

OUT="$OUT/regress"  tb/run_regress.sh "${1:-20000}" "${2:-4}" > "$OUT/regress.log" 2>&1;  R[regress]=$?
OUT="$OUT/directed" tb/run_directed.sh > "$OUT/directed.log" 2>&1;                     R[directed]=$?
OUT="$OUT/mutants"  tb/run_mutants.sh  > "$OUT/mutants.log" 2>&1;                      R[mutants]=$?
iverilog -g2012 -o "$OUT/perf/tb" tb/tb_ddr_perf.v ../ddr_perf.v ../pipe_counter.v && \
    vvp -n "$OUT/perf/tb" > "$OUT/perf.log" 2>&1 && grep -q "TEST PASSED" "$OUT/perf.log"; R[ddr_perf]=$?
if command -v yosys-abc > /dev/null; then
    { OUT="$OUT/formal/small" formal/run_formal.sh small 20 &&
      OUT="$OUT/formal/full" PDR=0 formal/run_formal.sh full 12; } > "$OUT/formal.log" 2>&1
    R[formal]=$?
else
    echo "yosys-abc not found: formal check skipped" > "$OUT/formal.log"; R[formal]=0
fi

fail=0
for k in regress directed mutants ddr_perf formal; do
    printf "%-9s %s\n" "$k" "$([ ${R[$k]} = 0 ] && echo PASS || echo FAIL)"
    [ ${R[$k]} = 0 ] || fail=1
done
echo "logs: $OUT"
[ $fail = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
exit $fail
