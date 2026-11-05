"""shot.py NAME ACTION... -- drive the board's desktop through the input bridge (inputd, tcp/5555), then grab NAME.png
from its framebuffer.  BOARD_IP (default 192.168.200.2).  Used for doc/images/desktop-*.png, e.g.
    shot.py desktop-system home c 110 155 w 2      (home, click the System tile, wait 2 s)
actions: c X Y (click) | dc X Y (double click) | r X Y (right click) | home (Ctrl+Alt+H) | w SECONDS |
         key CODE[+CODE...] (Linux key codes, held together: key 29+30 = Ctrl+A) |
         kd CODE / ku CODE (key down / up: kd 42 c X Y ku 42 = Shift+click)"""
import sys, time, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../src/apps/desktop/host"))
import netinput as ni
from PIL import Image
L = ni.Link(os.environ.get("BOARD_IP", "192.168.200.2"), 5555)
a = sys.argv[1:]; name = a.pop(0)
def move(x, y): L.ev(ni.EV_ABS, ni.ABS_X, x); L.ev(ni.EV_ABS, ni.ABS_Y, y); L.syn(); time.sleep(0.15)
def click(x, y, btn=ni.BTN_LEFT, after=1.0):
    move(x, y)
    L.ev(ni.EV_KEY, btn, 1); L.syn(); time.sleep(0.12)
    L.ev(ni.EV_KEY, btn, 0); L.syn(); time.sleep(after)
def key(*codes):
    for c in codes: L.ev(ni.EV_KEY, c, 1); L.syn(); time.sleep(0.04)
    for c in reversed(codes): L.ev(ni.EV_KEY, c, 0); L.syn(); time.sleep(0.04)
i = 0
while i < len(a):
    t = a[i]
    if t == 'c': click(int(a[i+1]), int(a[i+2])); i += 3
    elif t == 'dc': click(int(a[i+1]), int(a[i+2]), after=0.05); click(int(a[i+1]), int(a[i+2])); i += 3
    elif t == 'r': click(int(a[i+1]), int(a[i+2]), ni.BTN_RIGHT); i += 3
    elif t == 'home': key(29, 56, 35); time.sleep(1.0); i += 1
    elif t == 'w': time.sleep(float(a[i+1])); i += 2
    elif t == 'key': key(*[int(k) for k in a[i+1].split('+')]); time.sleep(0.5); i += 2
    elif t in ('kd', 'ku'): L.ev(ni.EV_KEY, int(a[i+1]), 1 if t == 'kd' else 0); L.syn(); time.sleep(0.1); i += 2
    else: raise SystemExit('bad action ' + t)
move(799, 479); time.sleep(1.2)
w, h, bpp, raw = L.frame()
open(name + ".ppm", "wb").write(ni.rgb565_to_ppm(w, h, raw)); Image.open(name + ".ppm").save(name + ".png"); os.remove(name + ".ppm")
print("frame", name)
