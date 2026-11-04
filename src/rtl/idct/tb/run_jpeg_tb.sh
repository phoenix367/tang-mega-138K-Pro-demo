#!/usr/bin/env bash
# idct_core JPEG path (jpeg_entropy.v) regression: real JPEG files -> records
# -> core -> planes, compared byte for byte with jpeg_ref.py (FFmpeg's decode,
# ported).  jpeg_ref.py itself is first checked against the host's FFmpeg
# (C code only: -cpuflags 0 -idct simple) on every image.
#   images: libjpeg standard tables; optimised tables; restart markers; dense
#   noise at q 100; q 5 with a width and height not multiples of 16 (odd
#   height); an ffmpeg MJPEG frame (its per-frame optimal tables); damaged
#   frames followed by a good one (flagged, no hang, the good one exact); a
#   full 800x450 frame encoded like the player's clips (FRAMES=extra.jpg,... adds files).
# Usage: src/rtl/idct/tb/run_jpeg_tb.sh      (from anywhere; needs python3 + Pillow, ffmpeg)
set -u
cd "$(dirname "$0")/../.."
TB="$PWD/idct/tb"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT/img"
SRC="$TB/tb_jpeg.v $PWD/idct/rtl/idct_core.v $PWD/idct/rtl/idct_1d.v $PWD/idct/rtl/idct_ram.v
     $PWD/idct/rtl/jpeg_entropy.v $PWD/eth_dma/rtl/ahb_master.v $PWD/eth_dma/tb/ahb_slave_ram64.v"

python3 -I - "$OUT/img" <<'EOF'
import sys, random
from PIL import Image, ImageDraw
out = sys.argv[1]
def scene(w, h, seed, noise):
    r = random.Random(seed)
    im = Image.new('RGB', (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = ((x * 255) // max(1, w - 1), (y * 255) // max(1, h - 1), ((x + y) * 3) & 255)
    d = ImageDraw.Draw(im)
    for _ in range(6):
        x0, y0 = r.randrange(w), r.randrange(h)
        d.ellipse([x0, y0, x0 + r.randrange(4, w // 2), y0 + r.randrange(4, h // 2)],
                  fill=(r.randrange(256), r.randrange(256), r.randrange(256)))
    d.line([0, 0, w - 1, h - 1], fill=(255, 255, 255), width=2)
    if noise:
        for y in range(h):
            for x in range(w):
                p = px[x, y]
                px[x, y] = tuple(max(0, min(255, c + r.randrange(-noise, noise + 1))) for c in p)
    return im
scene(96, 48, 1, 8).save(out + '/std.jpg', quality=75, subsampling=2)
scene(112, 40, 2, 12).save(out + '/opt.jpg', quality=90, subsampling=2, optimize=True)
scene(80, 64, 3, 6).save(out + '/rst.jpg', quality=80, subsampling=2, restart_marker_blocks=2)
scene(64, 32, 4, 120).save(out + '/dense.jpg', quality=100, subsampling=2)
scene(100, 37, 5, 4).save(out + '/sparse.jpg', quality=5, subsampling=2)
scene(96, 48, 6, 60).save(out + '/bad.jpg', quality=90, subsampling=2, restart_marker_blocks=3)
EOF
ffmpeg -v error -y -f lavfi -i testsrc=size=160x64:rate=1 -frames:v 1 -c:v mjpeg -q:v 2 -pix_fmt yuvj420p "$OUT/img/ffmjpeg.jpg"
# a full panel-sized frame the way the player's clips are encoded (q 8, optimal tables)
ffmpeg -v error -y -f lavfi -i testsrc2=size=800x450:rate=1 -frames:v 1 -c:v mjpeg -q:v 8 -pix_fmt yuvj420p "$OUT/img/panel.jpg"

fail=0
#        name     files                        ring   corrupt
for t in "std     std.jpg                      4096   0" \
         "opt     opt.jpg                      1024   0" \
         "rst     rst.jpg                      4096   0" \
         "dense   dense.jpg                    2048   0" \
         "sparse  sparse.jpg                   512    0" \
         "ffmjpeg ffmjpeg.jpg                  4096   0" \
         "panel   panel.jpg                    65536  0" \
         "corrupt bad.jpg,bad.jpg,std.jpg      4096   1"; do
    set -- $t
    name=$1; files=$(echo "$2" | tr ',' ' '); ring=$3; corrupt=$4
    d="$OUT/$name"; mkdir -p "$d"
    paths=""; for f in $files; do paths="$paths $OUT/img/$f"; done
    flag=""; [ "$corrupt" = 1 ] && flag="--corrupt"
    info=$(python3 -I "$TB/jpeg_ref.py" "$d" $flag $paths) || { echo "$name: jpeg_ref failed"; fail=1; continue; }
    read W H CW NW BAD < "$d/params.txt"
    # the reference against the host's FFmpeg (last file; C code, simple IDCT)
    last=$(echo $paths | awk '{print $NF}')
    ffmpeg -v error -y -cpuflags 0 -idct simple -i "$last" -f rawvideo -pix_fmt yuvj420p "$d/ff.yuv"
    ref=$(python3 -I - "$d" "$W" "$H" "$CW" <<'EOF'
import sys
d, w, h, cw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
ff = open(d + '/ff.yuv', 'rb').read()
cwc, chc, ws = (w + 1) // 2, (h + 1) // 2, cw // 2
def plane(name, pw, ph, stride):
    v = [int(l, 16) for l in open('%s/exp_%s.hex' % (d, name))]
    return bytes(v[y * stride + x] for y in range(ph) for x in range(pw))
mine = plane('y', w, h, cw) + plane('u', cwc, chc, ws) + plane('v', cwc, chc, ws)
print('ffmpeg-match' if mine == ff else 'ffmpeg-MISMATCH (%d vs %d bytes)' % (len(mine), len(ff)))
EOF
)
    bin="$d/tb"
    iverilog -g2012 -P tb_jpeg.W="$W" -P tb_jpeg.H="$H" -P tb_jpeg.CW="$CW" -P tb_jpeg.NW="$NW" \
        -P tb_jpeg.RING="$ring" -P tb_jpeg.CORRUPT="$corrupt" -o "$bin" $SRC || exit 1
    r=$(cd "$d" && timeout 1800 vvp -n "$bin" | grep -E "RESULT|^  ")
    echo "$name: $info; reference $ref"
    echo "    $r" | sed 's/^ *//; s/^/    /'
    [[ $r == *"RESULT: PASS"* && $ref == ffmpeg-match ]] || fail=1
done
[ $fail = 0 ] && echo "JPEG TB PASSED" || echo "JPEG TB FAILED"
exit $fail
