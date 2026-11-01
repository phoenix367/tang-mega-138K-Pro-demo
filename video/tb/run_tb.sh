#!/usr/bin/env bash
# video_core simulation (iverilog): the core on the real ahb_ddr3_bridge video
# port against the DDR3 user-port model -- pixel-exact frame, CRC, no
# underruns with and without DDR back-pressure, and a starved port detected.
# Usage: video/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
SRC="video/tb/tb_video.v video/rtl/video_core.v video/rtl/video_csr.v video/rtl/video_fetch.v
     video/rtl/video_out.v eth_dma/lib/RAM_Simple_Dual_Port_Dual_Clock.v eth_dma/lib/Reset_Synchronizer.v
     ddr_bridge/rtl/ahb_ddr3_bridge.v ddr_bridge/rtl/ddr_async_fifo.v ddr_bridge/rtl/ddr_rd_bist.v
     ddr_bridge/tb/ddr3_ui_model.v"
fail=0
#    WAIT_PCT EXPECT_UNDERRUN  timing (HT HS VT VS; HA=64 VA=12)
for cfg in "0 0   100 20 20 3" "50 0  100 20 20 3" "98 1  100 20 20 3" \
           "0 0   72 0 14 0" "50 0  80 16 20 8"; do
    set -- $cfg
    bin="$OUT/tb_w$1_$3_$4_$5_$6"
    iverilog -g2012 -P tb_video.WAIT_PCT="$1" -P tb_video.EXPECT_UNDERRUN="$2" \
        -P tb_video.HT="$3" -P tb_video.HS="$4" -P tb_video.VT="$5" -P tb_video.VS="$6" \
        -o "$bin" $SRC || exit 1
    r=$(timeout 600 vvp -n "$bin" | grep -E "RESULT")
    echo "wait $1%, H $3/$4 V $5/$6: $r"
    [[ $r == "RESULT: PASS"* ]] || fail=1
done
[ $fail = 0 ] && echo "VIDEO TB PASSED" || echo "VIDEO TB FAILED"
exit $fail
