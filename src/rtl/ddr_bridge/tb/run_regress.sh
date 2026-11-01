#!/usr/bin/env bash
# Regression for ahb_ddr3_bridge: several buffer/prefetch configs x clock ratios
# x seeds, each a randomized self-checking run (tb_ahb_ddr3_bridge), plus one
# seed per combination with a client on the video read port.
# Usage: tb/run_regress.sh [ops] [seeds]      (run from src/rtl/ddr_bridge/)
set -u
OPS="${1:-20000}"
SEEDS="${2:-4}"
OUT="${OUT:-$(mktemp -d)}"
cd "$(dirname "$0")/.."

fail=0
for cfg in "8 1" "4 1" "2 0"; do
    set -- $cfg
    bin="$OUT/tb_n$1_p$2"
    # two builds: SYNC_CLK=1 (hclk = uclk, the hardware since Build 64) and the
    # async FIFOs (SYNC_CLK=0) for the unequal clock ratios
    for sync in 1 0; do
        iverilog -g2012 -P tb_ahb_ddr3_bridge.NBUF="$1" -P tb_ahb_ddr3_bridge.PREFETCH="$2" \
            -P tb_ahb_ddr3_bridge.SYNC_CLK=$sync \
            -o "${bin}_s$sync" tb/tb_ahb_ddr3_bridge.v tb/ddr3_ui_model.v rtl/ahb_ddr3_bridge.v \
            rtl/ddr_async_fifo.v rtl/ddr_rd_bist.v ../pipe_counter.v || exit 1
    done
    #            hclk uclk : AHB 100 MHz = DDR (sync), AHB 50 MHz vs DDR 100/50/27 MHz (async)
    for clk in "10 10 1" "20 10 0" "20 20 0" "20 37 0" "10 10 0"; do
        set -- $clk
        # seeds 1..SEEDS, then one more with a busy video-port client
        for ((s = 1; s <= SEEDS + 1; s++)); do
            v=0; [ $s -gt "$SEEDS" ] && v=30
            r=$(timeout 900 vvp "${bin}_s$3" +seed=$((s * 7919)) +ops="$OPS" +hclk_ns="$1" +uclk_ns="$2" \
                +video=$v | grep -E "^seed|^video|TEST")
            echo "$(basename "$bin") sync=$3 hclk=$1 uclk=$2 seed=$s video=$v: $(echo "$r" | tr '\n' ' ')"
            echo "$r" | grep -q "TEST PASSED" || fail=1
        done
    done
done
[ $fail = 0 ] && echo "REGRESSION PASSED" || echo "REGRESSION FAILED"
exit $fail
