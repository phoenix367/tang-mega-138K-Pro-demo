#!/usr/bin/env bash
# idct_core simulation (iverilog): records in a ring on a 64-bit AHB RAM, the
# core transforms and assembles a small 4:2:0 frame, every pixel compared with
# a model of FFmpeg's integer IDCT.  Covers explicit and automatic band
# flushes (FLAGS 1 = per block, 0 = automatic + last row, 2 = flush-only records),
# a height that is not a multiple of 16, and a ring that wraps.
# Usage: src/rtl/idct/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
SRC="idct/tb/tb_idct.v idct/rtl/idct_core.v idct/rtl/idct_1d.v idct/rtl/idct_ram.v idct/rtl/jpeg_entropy.v
     eth_dma/rtl/ahb_master.v eth_dma/tb/ahb_slave_ram64.v"
fail=0
#          W   H  FLAGS RING
for cfg in "96 48 1 4096" "96 48 0 4096" "96 48 2 4096" "112 40 1 1024" "64 24 0 512" "160 64 1 65536"; do
    set -- $cfg
    bin="$OUT/tb_idct_$1x$2_f$3_r$4"
    iverilog -g2012 -P tb_idct.W="$1" -P tb_idct.H="$2" -P tb_idct.FLAGS="$3" -P tb_idct.RING="$4" \
        -o "$bin" $SRC || exit 1
    r=$(timeout 900 vvp -n "$bin" | grep -E "RESULT")
    echo "${1}x$2 flags $3 ring $4: $r"
    [[ $r == "RESULT: PASS"* ]] || fail=1
done
[ $fail = 0 ] && echo "IDCT TB PASSED" || echo "IDCT TB FAILED"
exit $fail
