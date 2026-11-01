#!/usr/bin/env python3
"""
netinput.py -- drive the AE350 board's LCD desktop with this PC's mouse and
keyboard over the network (counterpart of desktop/inputd.c on the board).

    host/netinput.py [board-ip] [--port 5555] [--view [fps]] [--scale N]

A window the size of the board's screen (800x480) opens.  While the pointer
is inside it, its position is sent as an absolute position on the LCD, so
the board's cursor sits exactly under yours; clicks, wheel and every key
typed into the window go to the board.  With --view the window shows the
board's framebuffer, so it works as a remote display of the LCD: the board
sends only the rows that changed since the previous frame, run-length
encoded (an idle screen costs a few bytes per frame; --raw sends full
frames instead).  No root needed: events come from Tk, not from
/dev/input, and Tk's X11 keycodes are Linux key codes + 8.

Protocol (big-endian): "NETINPUT1", then 8-byte records
{u16 type, u16 code, i32 value}; type 0xFFFF code 1 asks for a frame
({u16 w, u16 h, u16 bpp, u16 fmt} header): value 0 = raw pixels, value 1 =
u32 length + {u16 row, u16 len, RLE pixels} for each changed row (see
inputd.c for the RLE).
"""
import argparse
import socket
import struct
import sys
import time
import tkinter as tk

try:
    import numpy
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False

EV_SYN, EV_KEY, EV_REL, EV_ABS = 0, 1, 2, 3
REL_X, REL_Y, REL_WHEEL = 0, 1, 8
ABS_X, ABS_Y = 0, 1
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
SYN_REPORT = 0
REQ_TYPE, REQ_FRAME = 0xFFFF, 1
W, H = 800, 480


class Link:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=5)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.s.settimeout(None)
        self.s.sendall(b"NETINPUT1")
        self.pending = b""

    def ev(self, t, c, v):
        self.pending += struct.pack(">HHi", t, c, v)

    def syn(self):
        self.ev(EV_SYN, SYN_REPORT, 0)
        self.s.sendall(self.pending)
        self.pending = b""

    def recv_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("board closed the connection")
            buf += chunk
        return bytes(buf)

    def frame(self):
        """One raw frame: (w, h, bpp, pixels)."""
        self.s.sendall(struct.pack(">HHi", REQ_TYPE, REQ_FRAME, 0))
        w, h, bpp, fmt = struct.unpack(">HHHH", self.recv_exact(8))
        assert fmt == 0
        return w, h, bpp, self.recv_exact(w * h * bpp // 8)

    canvas = None          # numpy uint16 (h, w): the picture as last reconstructed

    def frame_delta(self, keyframe=False):
        """Changed rows + RLE (fmt 1); patches self.canvas.  keyframe=True asks
        for every row (first frame, or to resync).  Returns
        (w, h, rows_changed, bytes_received).  Needs numpy."""
        import numpy as np
        if self.canvas is None:
            keyframe = True
        self.s.sendall(struct.pack(">HHi", REQ_TYPE, REQ_FRAME, 2 if keyframe else 1))
        w, h, bpp, fmt = struct.unpack(">HHHH", self.recv_exact(8))
        if fmt == 0:                                   # board fell back to raw (not 16 bpp)
            raw = self.recv_exact(w * h * bpp // 8)
            self.canvas = np.frombuffer(raw, dtype="<u2").reshape(h, w).copy()
            self.last_rows = list(range(h))
            return w, h, h, len(raw) + 8
        (n,) = struct.unpack(">I", self.recv_exact(4))
        buf = self.recv_exact(n)
        if self.canvas is None or self.canvas.shape != (h, w):
            self.canvas = np.zeros((h, w), dtype="<u2")
        self.last_rows = rle_decode_frame(buf, w, self.canvas)
        return w, h, len(self.last_rows), n + 12


_ONES = [1] * 128


def rle_decode_frame(buf, w, canvas):
    """Decode a fmt-1 payload ({u16 row, u16 len, RLE} ...) into canvas rows.
    One Python pass collects (pixel, count) pairs for every row, then a single
    numpy repeat expands them; returns the list of row numbers written."""
    import numpy as np
    vals, counts, rows = [], [], []
    off, n = 0, len(buf)
    while off < n:
        row = (buf[off] << 8) | buf[off + 1]
        end = off + 4 + ((buf[off + 2] << 8) | buf[off + 3])
        off += 4
        rows.append(row)
        while off < end:
            c = buf[off]
            off += 1
            if c < 0x80:                               # run of c+1 pixels
                vals.append(buf[off] | (buf[off + 1] << 8))
                counts.append(c + 1)
                off += 2
            else:                                      # c-127 literal pixels
                cnt = c - 127
                vals.extend(struct.unpack_from("<%dH" % cnt, buf, off))
                counts.extend(_ONES[:cnt])
                off += 2 * cnt
    if not rows:
        return rows
    px = np.repeat(np.array(vals, dtype="<u2"), np.array(counts, dtype=np.int32))
    if px.size != len(rows) * w:
        raise ValueError("bad RLE payload: %d pixels for %d rows" % (px.size, len(rows)))
    canvas[np.array(rows)] = px.reshape(len(rows), w)
    return rows


def rgb565_to_ppm(w, h, raw):
    """RGB565 little-endian framebuffer (bytes or numpy uint16) -> binary PPM."""
    try:
        import numpy as np
        px = raw if hasattr(raw, "dtype") else np.frombuffer(raw, dtype="<u2")
        px = px.reshape(-1)
        r = ((px >> 11) & 0x1F).astype(np.uint8) << 3
        g = ((px >> 5) & 0x3F).astype(np.uint8) << 2
        b = (px & 0x1F).astype(np.uint8) << 3
        rgb = np.stack([r, g, b], axis=-1).tobytes()
    except ImportError:
        out = bytearray(w * h * 3)
        for i in range(w * h):
            p = raw[2 * i] | (raw[2 * i + 1] << 8)
            out[3 * i] = (p >> 8) & 0xF8
            out[3 * i + 1] = (p >> 3) & 0xFC
            out[3 * i + 2] = (p << 3) & 0xF8
        rgb = bytes(out)
    return b"P6 %d %d 255\n" % (w, h) + rgb


class App:
    def __init__(self, args):
        self.args = args
        self.link = Link(args.host, args.port)
        self.root = tk.Tk()
        self.root.title("AE350 netinput  %s" % args.host)
        self.scale = args.scale
        self.canvas = tk.Canvas(self.root, width=W * self.scale, height=H * self.scale,
                                bg="#202830", highlightthickness=0, cursor="crosshair")
        self.canvas.pack()
        self.photo = None
        self.canvas.create_text(W * self.scale // 2, H * self.scale // 2, fill="#9ab",
                                text="move the mouse here / type here\n(board %s)" % args.host,
                                justify="center", font=("Helvetica", 14), tags="hint")
        self.status = tk.Label(self.root, anchor="w", text="connected to %s:%d" % (args.host, args.port))
        self.status.pack(fill="x")
        self.last = (-1, -1)
        self.down = set()
        c = self.canvas
        c.bind("<Motion>", self.on_motion)
        c.bind("<B1-Motion>", self.on_motion)
        c.bind("<B2-Motion>", self.on_motion)
        c.bind("<B3-Motion>", self.on_motion)
        for n, code in ((1, BTN_LEFT), (2, BTN_MIDDLE), (3, BTN_RIGHT)):
            c.bind("<ButtonPress-%d>" % n, lambda e, k=code: self.on_button(e, k, 1))
            c.bind("<ButtonRelease-%d>" % n, lambda e, k=code: self.on_button(e, k, 0))
        c.bind("<Button-4>", lambda e: self.on_wheel(1))
        c.bind("<Button-5>", lambda e: self.on_wheel(-1))
        c.bind("<MouseWheel>", lambda e: self.on_wheel(1 if e.delta > 0 else -1))
        self.root.bind("<KeyPress>", lambda e: self.on_key(e, 1))
        self.root.bind("<KeyRelease>", lambda e: self.on_key(e, 0))
        c.bind("<Enter>", lambda e: c.focus_set())
        c.focus_set()
        self.root.protocol("WM_DELETE_WINDOW", self.quit)
        if args.view:
            self.root.after(100, self.refresh)

    # -- pointer -----------------------------------------------------------
    def pos(self, e):
        x = max(0, min(W - 1, int(e.x / self.scale)))
        y = max(0, min(H - 1, int(e.y / self.scale)))
        return x, y

    def on_motion(self, e):
        p = self.pos(e)
        if p == self.last:
            return
        self.last = p
        self.link.ev(EV_ABS, ABS_X, p[0])
        self.link.ev(EV_ABS, ABS_Y, p[1])
        self.link.syn()

    def on_button(self, e, code, val):
        p = self.pos(e)
        self.link.ev(EV_ABS, ABS_X, p[0])
        self.link.ev(EV_ABS, ABS_Y, p[1])
        self.link.ev(EV_KEY, code, val)
        self.link.syn()
        (self.down.add if val else self.down.discard)(code)

    def on_wheel(self, d):
        self.link.ev(EV_REL, REL_WHEEL, d)
        self.link.syn()

    # -- keyboard ----------------------------------------------------------
    def on_key(self, e, val):
        code = e.keycode - 8          # X11 keycode -> Linux KEY_*
        if code <= 0 or code > 0x2ff:
            return
        if val and code in self.down:
            return                    # X autorepeat: the board repeats itself
        self.link.ev(EV_KEY, code, val)
        self.link.syn()
        (self.down.add if val else self.down.discard)(code)

    # -- remote view -------------------------------------------------------
    def refresh(self):
        t0 = time.time()
        try:
            if self.args.raw or not HAVE_NUMPY:
                w, h, bpp, raw = self.link.frame()
                rows, nbytes = h, len(raw) + 8
            else:
                w, h, rows, nbytes = self.link.frame_delta()
                bpp, raw = 16, self.link.canvas
        except Exception as ex:
            self.status.config(text="view error: %s" % ex)
            return
        if bpp == 16 and (rows or self.photo is None):   # nothing changed: keep the image
            ppm = rgb565_to_ppm(w, h, raw)
            self.photo = tk.PhotoImage(data=ppm)
            if self.scale != 1:
                self.photo = self.photo.zoom(self.scale, self.scale)
            self.canvas.delete("hint")
            self.canvas.delete("fb")
            self.canvas.create_image(0, 0, anchor="nw", image=self.photo, tags="fb")
        dt = time.time() - t0
        self.status.config(text="view %dx%d  %d rows changed, %d KB, %.0f ms" % (w, h, rows, nbytes // 1024, dt * 1000))
        self.root.after(max(10, int(1000 / self.args.view - dt * 1000)), self.refresh)

    def quit(self):
        for k in list(self.down):
            self.link.ev(EV_KEY, k, 0)
        try:
            self.link.syn()
        except Exception:
            pass
        self.root.destroy()

    def run(self):
        self.root.mainloop()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host", nargs="?", default="192.168.200.2")
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--view", nargs="?", type=float, const=10.0, default=0,
                    help="show the board's framebuffer in the window (optional fps, default 10)")
    ap.add_argument("--raw", action="store_true", help="--view with full raw frames instead of changed rows + RLE")
    ap.add_argument("--scale", type=int, default=1, help="window magnification (1 or 2)")
    ap.add_argument("--snapshot", metavar="FILE.ppm", help="save one framebuffer snapshot and exit")
    args = ap.parse_args()
    if args.snapshot:
        link = Link(args.host, args.port)
        w, h, bpp, raw = link.frame()
        with open(args.snapshot, "wb") as f:
            f.write(rgb565_to_ppm(w, h, raw))
        print("saved %s (%dx%d)" % (args.snapshot, w, h))
        return
    try:
        App(args).run()
    except ConnectionError as ex:
        sys.exit("netinput: %s (is inputd running on the board?)" % ex)


if __name__ == "__main__":
    main()
