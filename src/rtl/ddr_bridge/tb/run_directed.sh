#!/usr/bin/env bash
# Directed checks for ahb_ddr3_bridge, each with an expected outcome:
#   PASS     the randomized self-check passes
#   FAIL     the self-check must FAIL (proves the DDR model / check is sensitive)
#   PROTO    0 data errors but DDR protocol errors (a protocol rule is checked)
#   BIST0    read BIST: done, 0 errors / reorders / stray returns, data PASS
#   BISTDET  read BIST against the reordering DDR model: reorders detected
# Usage: tb/run_directed.sh [ops]      (run from src/rtl/ddr_bridge/)
set -u
OPS="${1:-4000}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
cd "$(dirname "$0")/.."
SRC="tb/ddr3_ui_model.v rtl/ahb_ddr3_bridge.v rtl/ddr_async_fifo.v rtl/ddr_rd_bist.v ../pipe_counter.v"
iverilog -g2012 -o "$OUT/tb" tb/tb_ahb_ddr3_bridge.v $SRC || exit 1
iverilog -g2012 -P tb_ahb_ddr3_bridge.XROW_REORDER=1 -o "$OUT/tb_xrow" tb/tb_ahb_ddr3_bridge.v $SRC || exit 1
iverilog -g2012 -P tb_ahb_ddr3_bridge.ADDR_BITS=29 -o "$OUT/tb_a29" tb/tb_ahb_ddr3_bridge.v $SRC || exit 1
iverilog -g2012 -P tb_ahb_ddr3_bridge.ADDR_BITS=28 -o "$OUT/tb_a28" tb/tb_ahb_ddr3_bridge.v $SRC || exit 1

#     name                 binary   expect   plusargs (hclk/uclk in ns; 10/10 = 100 MHz bus)
TESTS=(
  "busy_none            tb       PASS     +busy=0  +hclk_ns=10 +uclk_ns=10"
  "busy_heavy           tb       PASS     +busy=60 +hclk_ns=10 +uclk_ns=10"
  "busy_heavy_slowbus   tb       PASS     +busy=60 +hclk_ns=20 +uclk_ns=10"
  "backpressure_heavy   tb       PASS     +rdy_pct=20 +hclk_ns=10 +uclk_ns=10"
  "backpressure_xrow    tb_xrow  PASS     +rdy_pct=20 +mode=0x0 +hclk_ns=10 +uclk_ns=10"
  "mode_noprefetch      tb       PASS     +mode=0x1      +hclk_ns=10 +uclk_ns=10"
  "mode_nomerge         tb       PASS     +mode=0x4      +hclk_ns=10 +uclk_ns=10"
  "mode_wr_rd_gap       tb       PASS     +mode=0x1020   +hclk_ns=10 +uclk_ns=10"
  "mode_serial          tb       PASS     +mode=0x40     +hclk_ns=10 +uclk_ns=10"
  "mode_wr_wr_gap       tb       PASS     +mode=0x2080   +hclk_ns=10 +uclk_ns=10"
  "mode_one_read        tb       PASS     +mode=0x100    +hclk_ns=10 +uclk_ns=10 +max_rd=1"
  "one_read_checked     tb       PROTO    +mode=0x0      +hclk_ns=10 +uclk_ns=10 +max_rd=1"
  "mode_no_wr_during_rd tb       PASS     +mode=0x200    +hclk_ns=10 +uclk_ns=10"
  "mode_rd_gaps         tb       PASS     +mode=0x3c00   +hclk_ns=10 +uclk_ns=10"
  "mode_xrow_default    tb       PASS     +mode=0x10000  +hclk_ns=10 +uclk_ns=10"
  "mode_legacy_hs       tb       PROTO    +mode=0x30000  +hclk_ns=10 +uclk_ns=10"
  "mode_whole_line      tb       PASS     +mode=0x40000  +hclk_ns=10 +uclk_ns=10"
  "mode_no_fast         tb       PASS     +mode=0x80000  +hclk_ns=10 +uclk_ns=10"
  "mode_line_overlap    tb       PASS     +mode=0x100000 +hclk_ns=10 +uclk_ns=10"
  "mode_half0_first     tb       PASS     +mode=0x200000 +hclk_ns=10 +uclk_ns=10"
  "xrow_model_rowrule   tb_xrow  PASS     +mode=0x0      +hclk_ns=10 +uclk_ns=10"
  "xrow_model_noguard   tb_xrow  FAIL     +mode=0x10000  +hclk_ns=10 +uclk_ns=10"
  "bist_random          tb       BIST0    +bist=0"
  "bist_same_row        tb       BIST0    +bist=1"
  "bist_line_pairs      tb       BIST0    +bist=2"
  "bist_desc_pairs      tb       BIST0    +bist=3"
  "bist_detects_reorder tb_xrow  BISTDET  +bist=0"
  "video_port           tb       PASS     +video=50 +mode=0x10000 +hclk_ns=10 +uclk_ns=10"
  "video_saturated      tb       PASS     +video=100 +mode=0x10000 +hclk_ns=10 +uclk_ns=10"
  "video_backpressure   tb       PASS     +video=50 +rdy_pct=20 +mode=0x10000 +hclk_ns=10 +uclk_ns=10"
  "video_busy_slowbus   tb       PASS     +video=30 +busy=60 +hclk_ns=20 +uclk_ns=10"
  "video_bist           tb       BIST0    +video=30 +bist=0"
  "addr29_random        tb_a29   PASS     +video=30 +mode=0x10000 +hclk_ns=10 +uclk_ns=10"
  "addr29_bist          tb_a29   BIST0    +bist=0"
  "addr28_random        tb_a28   PASS     +video=30 +mode=0x10000 +hclk_ns=10 +uclk_ns=10"
  "video_write_stream   tb       PASS     +video=100 +wrheavy +rdy_pct=60 +mode=0x10000 +hclk_ns=10 +uclk_ns=10 +vmaxwait=200"
)

fail=0
for t in "${TESTS[@]}"; do
    set -- $t
    name=$1; bin=$2; exp=$3; shift 3
    log="$OUT/$name.log"
    timeout 900 vvp -n "$OUT/$bin" +seed=31 +ops="$OPS" "$@" > "$log" 2>&1
    res=$(grep -E "^TEST (PASSED|FAILED)" "$log" | head -1)
    bist=$(grep -E "^bist:" "$log" | head -1)
    ok=0
    case $exp in
        PASS)    [[ $res == "TEST PASSED" ]] && ok=1 ;;
        FAIL)    [[ $res == TEST\ FAILED* ]] && ok=1 ;;
        PROTO)   [[ $res =~ ^TEST\ FAILED:\ 0\ data\ errors,\ [1-9][0-9]*\ DDR\ protocol ]] && ok=1 ;;
        BIST0)   [[ $res == "TEST PASSED" && $bist =~ status\ 4[0-9a-f]{7}\ err\ 0\ reorder\ 0\ .*extra\ 0$ ]] && ok=1 ;;
        BISTDET) [[ $bist =~ reorder\ ([1-9][0-9]*) ]] && ok=1 ;;
    esac
    printf "%-22s expect %-7s : %s %s\n" "$name" "$exp" "$([ $ok = 1 ] && echo ok || echo MISMATCH)" \
        "$(echo "$res $bist" | cut -c1-90)"
    [ $ok = 1 ] || fail=1
done
[ $fail = 0 ] && echo "DIRECTED PASSED" || echo "DIRECTED FAILED"
exit $fail
