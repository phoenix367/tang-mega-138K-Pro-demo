#!/usr/bin/env bash
# Regression for ahb_ddr3_bridge: several buffer/prefetch configs x clock ratios
# x seeds, each a randomized self-checking run (tb_ahb_ddr3_bridge), plus one
# seed per combination with a client on the video read port.
# Usage: tb/run_regress.sh [ops] [seeds]      (run from ddr_bridge/)
set -u
OPS="${1:-20000}"
SEEDS="${2:-4}"
OUT="${OUT:-$(mktemp -d)}"
cd "$(dirname "$0")/.."

fail=0
for cfg in "8 1" "4 1" "2 0"; do
    set -- $cfg
    bin="$OUT/tb_n$1_p$2"
    iverilog -g2012 -P tb_ahb_ddr3_bridge.NBUF="$1" -P tb_ahb_ddr3_bridge.PREFETCH="$2" \
        -o "$bin" tb/tb_ahb_ddr3_bridge.v tb/ddr3_ui_model.v rtl/ahb_ddr3_bridge.v \
        rtl/ddr_async_fifo.v rtl/ddr_rd_bist.v || exit 1
    #            hclk uclk : AHB 50 MHz vs DDR 100/50/27 MHz, and AHB 100 MHz
    for clk in "20 10" "20 20" "20 37" "10 10"; do
        set -- $clk
        # seeds 1..SEEDS, then one more with a busy video-port client
        for ((s = 1; s <= SEEDS + 1; s++)); do
            v=0; [ $s -gt "$SEEDS" ] && v=30
            r=$(timeout 900 vvp "$bin" +seed=$((s * 7919)) +ops="$OPS" +hclk_ns="$1" +uclk_ns="$2" \
                +video=$v | grep -E "^seed|^video|TEST")
            echo "$(basename "$bin") hclk=$1 uclk=$2 seed=$s video=$v: $(echo "$r" | tr '\n' ' ')"
            echo "$r" | grep -q "TEST PASSED" || fail=1
        done
    done
done
[ $fail = 0 ] && echo "REGRESSION PASSED" || echo "REGRESSION FAILED"
exit $fail
