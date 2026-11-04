#!/usr/bin/env bash
# video_core simulation (iverilog): the core on the real ahb_ddr3_bridge video
# port against the DDR3 user-port model -- pixel-exact frame, CRC, no
# underruns with and without DDR back-pressure, a starved port detected, and the
# YUV 4:2:0 mode (full and limited range) pixel-exact against a model of the conversion,
# and the scaler (up, down, odd factors, windows with background) and the ARGB OSD
# layer, alone and together, in both modes.
# Usage: src/rtl/video/tb/run_tb.sh      (from anywhere)
set -u
cd "$(dirname "$0")/../.."
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
SRC="video/tb/tb_video.v video/rtl/video_core.v video/rtl/video_csr.v video/rtl/video_fetch.v
     video/rtl/video_out.v eth_dma/lib/RAM_Simple_Dual_Port_Dual_Clock.v eth_dma/lib/Reset_Synchronizer.v
     ddr_bridge/rtl/ahb_ddr3_bridge.v ddr_bridge/rtl/ddr_async_fifo.v ddr_bridge/rtl/ddr_rd_bist.v
     ddr_bridge/tb/ddr3_ui_model.v pipe_counter.v"
fail=0
#    WAIT_PCT EXPECT_UNDERRUN  timing (HT HS VT VS; HA=64 VA=12)  YUV FULL
#    [SCALE SW SH DX DY DW DH  OSD OX OY OW OH]
for cfg in "0 0   100 20 20 3  0 0" "50 0  100 20 20 3  0 0" "98 1  100 20 20 3  0 0" \
           "0 0   72 0 14 0  0 0" "50 0  80 16 20 8  0 0" \
           "0 0   100 20 20 3  1 1" "50 0  100 20 20 3  1 0" "0 0  72 0 14 0  1 1" "98 1  100 20 20 3  1 1" \
           "0 0   100 20 20 3  1 1  1 40 8 4 1 56 10   0 0 0 16 4" \
           "50 0  100 20 20 3  1 0  1 120 20 8 2 48 9  1 10 3 40 6" \
           "0 0   100 20 20 3  0 0  1 24 6 0 0 64 12   1 0 0 64 12" \
           "0 0   100 20 20 3  1 1  0 64 12 0 0 64 12  1 6 2 20 9" \
           "0 0   100 20 20 3  1 1  1 150 23 3 3 61 7  1 33 0 31 12" \
           "50 0  80 16 20 8  1 1  1 64 12 16 4 32 6  1 0 10 64 2"; do
    set -- $cfg
    SC=${9:-0} SW=${10:-64} SH=${11:-12} DX=${12:-0} DY=${13:-0} DW=${14:-64} DH=${15:-12}
    OS=${16:-0} OX=${17:-0} OY=${18:-0} OW=${19:-16} OH=${20:-4}
    bin="$OUT/tb_w$1_$3_$4_$5_$6_y$7$8_s${SC}_${SW}x${SH}_${DW}x${DH}_o${OS}"
    iverilog -g2012 -P tb_video.WAIT_PCT="$1" -P tb_video.EXPECT_UNDERRUN="$2" \
        -P tb_video.HT="$3" -P tb_video.HS="$4" -P tb_video.VT="$5" -P tb_video.VS="$6" \
        -P tb_video.YUV="$7" -P tb_video.FULL="$8" \
        -P tb_video.SCALE="$SC" -P tb_video.SW="$SW" -P tb_video.SH="$SH" -P tb_video.DX="$DX" -P tb_video.DY="$DY" \
        -P tb_video.DW="$DW" -P tb_video.DH="$DH" -P tb_video.OSD="$OS" -P tb_video.OX="$OX" -P tb_video.OY="$OY" \
        -P tb_video.OW="$OW" -P tb_video.OH="$OH" \
        -o "$bin" $SRC || exit 1
    r=$(timeout 600 vvp -n "$bin" | grep -E "RESULT|^  ")
    echo "wait $1%, H $3/$4 V $5/$6, yuv $7 full $8, scale $SC ${SW}x$SH->${DW}x$DH+$DX+$DY, osd $OS: $r"
    [[ $r == *"RESULT: PASS"* ]] || fail=1
done
[ $fail = 0 ] && echo "VIDEO TB PASSED" || echo "VIDEO TB FAILED"
exit $fail
