#!/usr/bin/env python3
"""make_splash.py -- render the U-Boot boot splash (src/splash/splash.bmp).

800x480, 8-bit palette BMP (what U-Boot's bmp code draws fastest into the
RGB565 framebuffer).  The image is appended to the U-Boot XIP image at offset
0x100000 by scripts/build_uboot.sh (flash 0x700000, XIP 0x80100000) and shown
by U-Boot's splash support before the autoboot countdown.

    python3 src/splash/make_splash.py [out.bmp] [preview.png]
"""
import sys, os, zlib, struct
from PIL import Image, ImageDraw, ImageFont

W, H = 800, 480
FONT_DIR = "/usr/share/fonts/truetype/dejavu"
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "splash.bmp")
preview = sys.argv[2] if len(sys.argv) > 2 else None

bg, fg, dim, accent, chip = (24, 26, 32), (240, 240, 240), (170, 175, 190), (0, 188, 212), (44, 48, 60)
img = Image.new("RGB", (W, H), bg)
d = ImageDraw.Draw(img)
big = ImageFont.truetype(f"{FONT_DIR}/DejaVuSans-Bold.ttf", 44)
mid = ImageFont.truetype(f"{FONT_DIR}/DejaVuSans.ttf", 21)
small = ImageFont.truetype(f"{FONT_DIR}/DejaVuSans.ttf", 16)

# accent bar and Tux (the kernel's own boot logo, keyed onto the background)
d.rectangle((60, 160, 70, 320), fill=accent)
TUX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "external", "linux",
                   "drivers", "video", "logo", "logo_linux_clut224.ppm")
tux = Image.open(TUX).convert("RGB")
tux = tux.crop((12, 0, tux.size[0], tux.size[1]))  # drop the signature strip on the left edge
key = tux.getpixel((0, 0))                       # the logo's background colour
mask = Image.new("L", tux.size, 0)
px, mp = tux.load(), mask.load()
for y in range(tux.size[1]):
    for x in range(tux.size[0]):
        mp[x, y] = 0 if px[x, y] == key else 255
th = 104
tw = tux.size[0] * th // tux.size[1]
tux = tux.resize((tw, th), Image.Resampling.LANCZOS)
mask = mask.resize((tw, th), Image.Resampling.LANCZOS)
img.paste(tux, (90 + (104 - tw) // 2, 240 - th // 2), mask)

d.text((204, 192), "Tang Mega 138K Pro", fill=fg, font=big, anchor="lm")
d.text((206, 240), "Andes AE350  ·  RISC-V A25 @ 800 MHz  ·  Linux 6.12", fill=dim, font=mid, anchor="lm")
d.text((206, 290), "Loading the kernel from SPI flash ...", fill=accent, font=mid, anchor="lm")
d.text((W // 2, 444), "github.com/phoenix367/tang-mega-138K-Pro-demo", fill=(110, 115, 130), font=small, anchor="mm")

pal = img.quantize(colors=64, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
pal.save(out, "BMP")
if preview:
    img.save(preview)
# the frame CRC-32 the scan-out core reports (register 0x28) once U-Boot shows the image:
# its bmp code maps the palette to RGB565 by truncation, row by row, little-endian
palette, px, frame = pal.getpalette(), pal.load(), bytearray()
for y in range(H):
    for x in range(W):
        i = px[x, y]
        frame += struct.pack("<H", ((palette[3 * i] >> 3) << 11) | ((palette[3 * i + 1] >> 2) << 5) | (palette[3 * i + 2] >> 3))
print(f"{out}: {os.path.getsize(out)} bytes, frame CRC-32 0x{zlib.crc32(frame) & 0xffffffff:08x} (md.l 0xe8001028 1 in U-Boot)")
