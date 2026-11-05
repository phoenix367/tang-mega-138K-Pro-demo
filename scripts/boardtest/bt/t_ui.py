"""ui: the desktop through the input bridge, as a user drives it from netinput.py:
inputd, a reconnect, every home tile, the file manager (copy, paste, rename, context
menu, delete), and a video started from the Files panel with the panel's frame timing.

The flows rely on lvdesk's fixed geometry: tile centres (ui.TILES) and the Files
table (files.c: first entry row at y 148, rows 26 px apart, places on the left; a
panel starts right under the status bar, whose "< Panel" is the back control).
Test folders start with "!", which sorts before letters and dot files, so a test
folder is the first row of the home folder whatever else is there.  Every action is
checked on the board over ssh or by comparing frame grabs; dialogs are driven by
keyboard (F2, Tab, Enter), not by guessing button positions.
"""
import re, time

from .core import Skip, grep, test
from .ui import TILES, changed

FILES_TILE = (302, 155)
PLACE_HOME = (70, 100)
PATH_BOX = (200, 80, 560, 104)          # the Files path bar
ROW_X, ROW0_Y, ROW_H = 300, 148, 26
HOME = "/home/ae350"


def row(i):
    return ROW_X, ROW0_Y + i * ROW_H


def open_home_in_files(ui):
    ui.home()
    ui.click(*FILES_TILE, wait=1.5)
    ui.click(*PLACE_HOME, wait=1.0)


def lvdesk_pid(ctx):
    return ctx.board.run("pgrep -x lvdesk")[1].strip()


def ls(ctx, d):
    rc, out = ctx.run("ls -1A '%s' 2>&1" % d)
    return [l for l in out.split("\n") if l]


@test("ui", "inputd", "input bridge: connect and grab the screen")
def inputd(ctx, r):
    ctx.desktop(True)
    t0 = time.time()
    ui = ctx.ui
    r.metric("connect_s", round(time.time() - t0, 2))
    t0 = time.time()
    img = ui.frame()
    r.metric("grab_ms", int((time.time() - t0) * 1000))
    r.check(img.shape == (480, 800, 3), "frame %s, expected 800x480" % (img.shape,))
    ui.home()
    ctx.home_img = ui.frame()
    ctx.shot(ctx.home_img, "home")
    return "800x480 frames, a grab takes %d ms" % r.metrics["grab_ms"]


@test("ui", "reconnect", "input bridge: a dropped client, then a new one")
def reconnect(ctx, r):
    ctx.desktop(True)
    ctx.ui.close()                                  # gone without a word, as a crashed client
    ctx._ui = None
    t0 = time.time()
    img = ctx.ui.frame()
    r.metric("reconnect_s", round(time.time() - t0, 2))
    r.check(img.shape == (480, 800, 3), "no frame after reconnecting")
    return "served again after %.1f s" % r.metrics["reconnect_s"]


@test("ui", "panels", "every home tile opens its panel")
def panels(ctx, r):
    ctx.desktop(True)
    ui = ctx.ui
    pid = lvdesk_pid(ctx)
    ui.home()
    home = ui.frame()
    opened = []
    for name, x, y in TILES:
        ui.home()
        ui.click(x, y, wait=1.8)
        img = ui.frame()
        ctx.shot(img, "panel_" + re.sub(r"\W+", "_", name.lower()))
        frac = changed(home, img)
        if r.check(frac > 0.15, "%s: the screen hardly changed (%.0f%% of the pixels)" % (name, frac * 100)):
            opened.append(name)
    ui.home()
    r.check(lvdesk_pid(ctx) == pid, "lvdesk restarted while the panels were opened (crash?)")
    return "%d of %d panels: %s" % (len(opened), len(TILES), ", ".join(opened))


@test("ui", "files", "file manager: copy, paste, rename, context menu, delete")
def files(ctx, r):
    ctx.desktop(True)
    ui = ctx.ui
    d = HOME + "/!bt_files"
    ctx.root("rm -rf '%s'; mkdir -p '%s'; echo alpha > '%s/a.txt'; echo beta > '%s/b.txt'; chown -R ae350:ae350 '%s'\n"
             % (d, d, d, d, d))
    pid = lvdesk_pid(ctx)
    try:
        open_home_in_files(ui)
        before = ui.frame()
        ui.dclick(*row(0), wait=1.5)                      # open !bt_files
        img = ui.frame()
        ctx.shot(img, "files_folder")
        # the path bar changes for sure ("/home/ae350" -> "/home/ae350/!bt_files"); the list may not much
        r.check(changed(before, img, box=PATH_BOX) > 0.02, "double click did not open the folder")
        # copy + paste in place: "a (copy).txt"
        ui.click(*row(0))
        ui.keys("ctrl", "c")
        ui.keys("ctrl", "v", wait=2.5)
        names = ls(ctx, d)
        r.check("a (copy).txt" in names, "Ctrl+C, Ctrl+V: no 'a (copy).txt' (%s)" % names)
        r.check(ctx.run("cat '%s/a (copy).txt'" % d)[1].strip() == "alpha", "the copy's contents differ")
        # rename b.txt (row 2: a (copy).txt, a.txt, b.txt): F2 highlights "b", typing replaces it
        ui.click(*row(2))
        ui.keys("f2", wait=0.8)
        ctx.shot(ui.frame(), "files_rename")
        ui.type("renamed")
        ui.keys("enter", wait=1.5)
        names = ls(ctx, d)
        r.check("renamed.txt" in names and "b.txt" not in names, "F2 rename to 'renamed.txt' failed (%s)" % names)
        # the context menu on a file appears, and Esc closes it (compared below the three rows:
        # the right click also moves the selection, and the pointer is drawn into the grabs)
        before = ui.frame()
        ui.rclick(*row(1))
        menu = ui.frame()
        ctx.shot(menu, "files_menu")
        box = (ROW_X + 10, ROW0_Y + 3 * ROW_H + 8, 540, 470)
        # thresh 3: the menu's background is within a few levels of the table's (RGB565), so a
        # coarse threshold sees only its text; nothing else changes in this box (87 % vs 0.7 %)
        r.check(changed(before, menu, box, thresh=3) > 0.3, "right click opened no menu")
        ui.keys("esc", wait=0.6)
        r.check(changed(before, ui.frame(), box, thresh=3) < 0.05, "Esc did not close the menu")
        # delete "a (copy).txt": the dialog starts on Cancel; Tab to Delete, Enter
        ui.click(*row(0))
        ui.keys("delete", wait=0.8)
        ctx.shot(ui.frame(), "files_delete")
        ui.keys("tab", wait=0.3)
        ui.keys("enter", wait=2.0)
        names = ls(ctx, d)
        r.check("a (copy).txt" not in names and "a.txt" in names, "Delete did not remove 'a (copy).txt' (%s)" % names)
        # select all: every row highlighted
        before = ui.frame()
        ui.keys("ctrl", "a", wait=0.6)
        r.check(changed(before, ui.frame(), box=(170, ROW0_Y - 13, 780, ROW0_Y + 2 * ROW_H - 13)) > 0.3,
                "Ctrl+A highlighted no rows")
        ui.keys("esc", wait=0.3)
    finally:
        ui.keys("backspace", wait=0.5)
        ctx.root("rm -rf '%s'\n" % d)
        ui.home()
    r.check(lvdesk_pid(ctx) == pid, "lvdesk restarted during the file operations (crash?)")
    return "paste made 'a (copy).txt', F2 renamed, menu opened and closed, Delete confirmed, Ctrl+A"


@test("ui", "video", "a video started from the Files panel, frame timing on the panel", slow=True)
def video(ctx, r):
    ctx.desktop(True)
    ui = ctx.ui
    d = HOME + "/!!bt_video"
    clip = ctx.media.clip(852, 480, 25, 10)
    ctx.board.put(str(clip), "/tmp/bt/uiclip.mp4")
    lm = ctx.tool("lcdmon")
    ctx.root("rm -rf '%s'; mkdir -p '%s'; mv /tmp/bt/uiclip.mp4 '%s/clip.mp4'; chown -R ae350:ae350 '%s'\n" % (d, d, d, d))
    pid = lvdesk_pid(ctx)
    out = ""
    try:
        open_home_in_files(ui)
        ui.dclick(*row(0), wait=1.5)                      # open !!bt_video
        ctx.root("setsid %s -t 40 -f 25 -w 30 </dev/null >/tmp/bt/lcdmon_ui.out 2>&1 &\nsleep 1\n" % lm)
        ui.dclick(*row(0), wait=2.0)                      # the clip: the desktop starts vidplay
        started = ctx.run("pgrep -x vidplay")[0] == 0
        r.check(started, "double click on the clip started no vidplay")
        t0 = time.time()
        while started and time.time() - t0 < 40 and ctx.run("pgrep -x vidplay >/dev/null")[0] == 0:
            time.sleep(2)
        time.sleep(2)
        rc, out = ctx.root("pkill -x lcdmon; sleep 1; grep -a 'VIDPLAY\\|skipped' /run/vidplay.log; cat /tmp/bt/lcdmon_ui.out\n")
        after = ui.frame()
        ctx.shot(after, "files_after_video")
    finally:
        ui.keys("backspace", wait=0.5)
        ctx.root("rm -rf '%s'\n" % d)
        ui.home()
    decoded = grep(r"VIDPLAY .*?: (\d+) frames decoded", out, conv=int, default=0)
    pictures = grep(r"(\d+) pictures", out, conv=int, default=0)
    skipped = grep(r"(\d+) packets skipped", out, conv=int, default=0)
    late = grep(r"holds longer than \d+ refreshes[^:]*: (\d+)", out, conv=int, default=0)
    longest = grep(r"longest hold (\d+) refreshes \((\d+) ms\)", out, 2, int, 0)
    for k, v in (("decoded", decoded), ("pictures", pictures), ("skipped", skipped), ("late_holds", late),
                 ("longest_hold_ms", longest)):
        r.metric(k, v)
    r.check(decoded >= 240, "only %d frames decoded of 250" % decoded)
    r.check(skipped == 0, "%d packets skipped" % skipped)
    r.check(late == 0, "%d pictures held too long (longest %d ms): the desktop must stay idle while a video plays" % (late, longest))
    r.check(lvdesk_pid(ctx) == pid, "lvdesk restarted around the video (crash?)")
    return "%d frames decoded, %d on the panel, longest hold %d ms" % (decoded, pictures, longest)
