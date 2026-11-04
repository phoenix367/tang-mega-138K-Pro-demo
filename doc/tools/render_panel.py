"""render_panel.py YUV W H POS DUR TITLE OUT.png [--nobar] -- the LCD as the video core drives it:
nearest-neighbour fit to 800x480 (pixel-centre sampling, 16.16 steps as gowin-lcdfb computes them),
full-range fixed-point YUV->RGB as video_out.v, vidplay's osd.c bar blended as the core does,
RGB565 as sent to the panel.  The board's YUV/OSD scan-out cannot be grabbed (it never passes
through the RGB framebuffer), so doc/images/vidplay-*.png are made with this; scaletest checks
the same arithmetic against the core's frame CRC.  Build osd_preview first (see osd_preview.c).
The YUV file is one yuvj420p frame decoded like the board decodes it:
    ffmpeg -cpuflags 0 -idct simple -ss 112 -i video.mp4 -frames:v 1 -f rawvideo -pix_fmt yuvj420p f.yuv
    render_panel.py f.yuv 852 480 112.4 305.7 "title" out.png"""
import os, sys, subprocess, numpy as np
from PIL import Image
yuvf, W, H, pos, dur, title, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
bar = '--nobar' not in sys.argv
raw = np.fromfile(yuvf, np.uint8)
cw, ch = (W + 1) // 2, (H + 1) // 2
Y = raw[:W * H].reshape(H, W).astype(np.int64)
U = raw[W * H:W * H + cw * ch].reshape(ch, cw).astype(np.int64)
V = raw[W * H + cw * ch:W * H + 2 * cw * ch].reshape(ch, cw).astype(np.int64)
PW, PH = 800, 480
# vidplay's fit (aspect kept, even sizes) and the driver's steps
if PW * H <= PH * W: dw, dh = PW, ((H * PW + W // 2) // W) & ~1
else: dh, dw = PH, ((W * PH + H // 2) // H) & ~1
dx, dy = (PW - dw) // 2, (PH - dh) // 2
stx, sty = (W << 16) // dw, (H << 16) // dh
sx = np.minimum((np.arange(dw) * stx + stx // 2) >> 16, W - 1)
sy = np.minimum((np.arange(dh) * sty + sty // 2) >> 16, H - 1)
y = Y[sy][:, sx]; u = U[sy // 2][:, sx // 2] - 128; v = V[sy // 2][:, sx // 2] - 128
def c8(a): a = a >> 8; return np.clip(a, 0, 255)
pic = np.zeros((PH, PW, 3), np.int64)
pic[dy:dy + dh, dx:dx + dw, 0] = c8(256 * y + 128 + 359 * v)
pic[dy:dy + dh, dx:dx + dw, 1] = c8(256 * y + 128 - 88 * u - 183 * v)
pic[dy:dy + dh, dx:dx + dw, 2] = c8(256 * y + 128 + 454 * u)
if bar:
    strip = subprocess.run(['./osd_preview', pos, dur, title], capture_output=True, check=True,
                           cwd=os.path.dirname(os.path.abspath(__file__))).stdout
    s = np.frombuffer(strip, np.uint8).reshape(64, 800, 4).astype(np.int64)   # B G R A
    a = s[:, :, 3] + (s[:, :, 3] >> 7)
    for c, i in ((0, 2), (1, 1), (2, 0)):
        p = pic[416:480, :, c]
        pic[416:480, :, c] = (s[:, :, i] * a + p * (256 - a)) >> 8
r5, g6, b5 = pic[:, :, 0] >> 3, pic[:, :, 1] >> 2, pic[:, :, 2] >> 3            # RGB565 as sent
img = np.stack([(r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)], -1).astype(np.uint8)
Image.fromarray(img).save(out)
print(out, 'window %dx%d at (%d,%d), steps %#x %#x' % (dw, dh, dx, dy, stx, sty))
