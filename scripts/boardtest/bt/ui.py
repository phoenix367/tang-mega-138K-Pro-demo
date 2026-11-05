"""The desktop through inputd (tcp/5555), as doc/tools/shot.py drives it: the events
host/netinput.py sends, and frame grabs of /dev/fb0.

inputd serves one client at a time: with a netinput.py window open, a second client
waits in the listen queue, so the first frame grab times out -- UiBusy says so.
Frame grabs show the desktop's RGB framebuffer; while vidplay owns the panel in YUV
mode they show the desktop's last picture, not the video.
"""
import socket, sys, time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "src" / "apps" / "desktop" / "host"))
import netinput as ni  # noqa: E402

# Linux key codes
KEY = dict(esc=1, backspace=14, tab=15, enter=28, ctrl=29, shift=42, alt=56, space=57,
           f2=60, f5=63, home=102, up=103, end=107, down=108, delete=111)
_ROWS = {"1234567890-=": 2, "qwertyuiop[]": 16, "asdfghjkl;'": 30, "zxcvbnm,./": 44}
for chars, base in _ROWS.items():
    for i, ch in enumerate(chars):
        KEY[ch] = base + i

# the desktop's home grid (lvdesk main.c): tile centres, in tile order
TILES = [("System", 110, 155), ("Files", 302, 155), ("Audio", 494, 155), ("Network", 686, 155),
         ("Console", 110, 358), ("Settings", 302, 358), ("Date & Time", 494, 358), ("About", 686, 358)]


class UiBusy(Exception):
    pass


class Ui:
    def __init__(self, host, port=5555):
        self.host, self.port = host, port
        self.connect()

    def connect(self):
        self.link = ni.Link(self.host, self.port)
        try:
            self.frame()
        except (socket.timeout, TimeoutError) as e:
            self.link.close()
            raise UiBusy("inputd does not answer: it serves one client at a time -- close any "
                         "netinput.py window and retry (%s)" % e)

    def close(self):
        try:
            self.link.close()
        except OSError:
            pass

    # -- input ----------------------------------------------------------------
    def move(self, x, y, wait=0.15):
        self.link.ev(ni.EV_ABS, ni.ABS_X, x)
        self.link.ev(ni.EV_ABS, ni.ABS_Y, y)
        self.link.syn()
        time.sleep(wait)

    def click(self, x, y, btn=ni.BTN_LEFT, wait=1.0):
        self.move(x, y)
        self.link.ev(ni.EV_KEY, btn, 1); self.link.syn(); time.sleep(0.12)
        self.link.ev(ni.EV_KEY, btn, 0); self.link.syn(); time.sleep(wait)

    def dclick(self, x, y, wait=1.0):
        self.click(x, y, wait=0.05)
        self.click(x, y, wait=wait)

    def rclick(self, x, y, wait=0.6):
        self.click(x, y, ni.BTN_RIGHT, wait)

    def keys(self, *names, wait=0.4):
        """Keys held together, pressed in order and released in reverse: keys('ctrl', 'c')."""
        codes = [KEY[n] if isinstance(n, str) else n for n in names]
        for c in codes:
            self.link.ev(ni.EV_KEY, c, 1); self.link.syn(); time.sleep(0.04)
        for c in reversed(codes):
            self.link.ev(ni.EV_KEY, c, 0); self.link.syn(); time.sleep(0.04)
        time.sleep(wait)

    def type(self, text):
        for ch in text:
            self.keys(ch, wait=0.08)

    def home(self):
        self.keys("ctrl", "alt", "h", wait=1.0)

    # -- screen ---------------------------------------------------------------
    def frame(self):
        """The framebuffer as an (h, w, 3) uint8 RGB array."""
        w, h, bpp, raw = self.link.frame()
        px = np.frombuffer(raw, dtype="<u2").reshape(h, w)
        r = ((px >> 11) & 0x1F).astype(np.uint8) << 3
        g = ((px >> 5) & 0x3F).astype(np.uint8) << 2
        b = (px & 0x1F).astype(np.uint8) << 3
        return np.stack([r, g, b], axis=-1)


def changed(a, b, box=None, thresh=24):
    """Fraction of pixels that differ between two grabs (inside box = (x0, y0, x1, y1))."""
    if box:
        x0, y0, x1, y1 = box
        a, b = a[y0:y1, x0:x1], b[y0:y1, x0:x1]
    d = np.abs(a.astype(np.int16) - b.astype(np.int16)).max(axis=-1)
    return float((d > thresh).mean())


def save_png(img, path):
    from PIL import Image
    Image.fromarray(img).save(str(path))
