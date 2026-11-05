"""Test registry, results and the run context.

A test is a function registered with @test(group, name, title).  It gets the run
context and its Result, records numbers with r.metric(), problems with r.fail() and
r.warn() (it keeps going: one run shows every problem), may raise Skip, and returns a
one-line summary.  Status: FAIL if any r.fail(), else WARN if any r.warn(), else PASS;
an exception other than Skip is an ERROR (the harness itself, or the board, broke).
"""
import json, os, re, subprocess, time, traceback
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOLS = REPO / "src" / "apps" / "tests"
GROUPS = ("kernel", "net", "cores", "ui")          # run order: cores stop the desktop, ui restarts it

TESTS = []


class Skip(Exception):
    pass


def test(group, name, title, slow=False, optional=False):
    """slow: shortened by --quick; optional: only with --include NAME (e.g. reboot)."""
    def deco(fn):
        TESTS.append(dict(group=group, name=name, title=title, fn=fn, slow=slow, optional=optional))
        return fn
    return deco


class Result:
    def __init__(self, t):
        self.group, self.name, self.title = t["group"], t["name"], t["title"]
        self.status, self.summary, self.seconds = "PASS", "", 0.0
        self.problems, self.warnings, self.metrics, self.files = [], [], {}, []

    @property
    def id(self):
        return "%s.%s" % (self.group, self.name)

    def fail(self, msg):
        self.problems.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def check(self, cond, msg):
        if not cond:
            self.fail(msg)
        return cond

    def metric(self, key, value):
        self.metrics[key] = value
        return value

    def as_dict(self):
        return dict(id=self.id, title=self.title, status=self.status, summary=self.summary,
                    seconds=round(self.seconds, 1), problems=self.problems, warnings=self.warnings,
                    metrics=self.metrics, files=self.files)


class Ctx:
    """What every test gets: the board, the desktop's input bridge (opened on first use),
    the media, the output directory, and helpers for board state and board-side tools."""

    def __init__(self, args, board, out, media):
        self.args, self.board, self.out, self.media = args, board, Path(out), media
        self.quick = args.quick
        self._ui = None
        self._tools = {}
        self.result = None
        (self.out / "logs").mkdir(parents=True, exist_ok=True)
        (self.out / "shots").mkdir(parents=True, exist_ok=True)

    # -- logs ---------------------------------------------------------------
    def log(self, text, name=None):
        """Raw output of a test step, into logs/<test>.txt."""
        name = name or (self.result.id if self.result else "harness")
        with open(self.out / "logs" / (name + ".txt"), "a") as f:
            f.write(text if text.endswith("\n") else text + "\n")

    # -- board helpers ------------------------------------------------------
    def run(self, cmd, timeout=60):
        rc, out = self.board.run(cmd, timeout)
        self.log("$ %s   [rc %s]\n%s" % (cmd, rc, out))
        return rc, out

    def root(self, script, timeout=60):
        rc, out = self.board.root(script, timeout)
        self.log("# (root script) [rc %s]\n%s\n--- output\n%s" % (rc, script.strip(), out))
        return rc, out

    def tool(self, name):
        """A board-side test program from src/apps/tests, built if needed, on the board
        as /tmp/bt/<name>.  Skip if it cannot be built (no cross toolchain)."""
        if name in self._tools:
            return self._tools[name]
        r = subprocess.run(["make", "-s", "-C", str(TOOLS), name], capture_output=True, text=True)
        local = TOOLS / name
        if r.returncode or not local.exists():
            raise Skip("cannot build src/apps/tests/%s: %s" % (name, (r.stderr or r.stdout).strip()[-200:]))
        remote = "/tmp/bt/" + name
        self.board.put(str(local), remote)
        self.board.run("chmod +x " + remote)
        self._tools[name] = remote
        return remote

    def desktop(self, running):
        """Start or stop the desktop.  A start from ssh must be detached (setsid): the
        supervisor loop of S70desktop is a background job that would die with the
        session otherwise.  With the desktop stopped VT 1 is the text console again,
        whose blinking cursor draws into /dev/fb0 behind a test's back (fbtest's CPU and
        panel CRCs then differ): it is hidden while the desktop is down."""
        rc, _ = self.board.run("pgrep -x lvdesk >/dev/null")
        if running and rc != 0:
            self.root("printf '\\033[?25h' > /dev/tty1; echo 1 > /sys/class/graphics/fbcon/cursor_blink\n"
                      "rm -f /run/desktop.pid\nsetsid /etc/init.d/S70desktop start </dev/null >/dev/null 2>&1\nsleep 5\n")
            if self.board.run("pgrep -x lvdesk >/dev/null")[0] != 0:
                raise RuntimeError("the desktop did not start (see /run/desktop.log)")
        elif not running and rc == 0:
            if self._ui:
                self._ui.close()
                self._ui = None
            self.root("/etc/init.d/S70desktop stop\nsleep 2\n"
                      "echo 0 > /sys/class/graphics/fbcon/cursor_blink; printf '\\033[?25l' > /dev/tty1\nsleep 1\n")

    @property
    def ui(self):
        if self._ui is None:
            from .ui import Ui
            self._ui = Ui(self.board.host)
        return self._ui

    def shot(self, img, name):
        """Save a frame grab as shots/<name>.png and list it with the result."""
        from .ui import save_png
        p = self.out / "shots" / (name + ".png")
        save_png(img, p)
        if self.result:
            self.result.files.append(str(p.relative_to(self.out)))
        return p

    def close(self):
        if self._ui:
            self._ui.close()


def select(groups=None, names=None, include=()):
    sel = []
    for t in TESTS:
        tid = "%s.%s" % (t["group"], t["name"])
        if t["optional"] and tid not in include and t["name"] not in include:
            continue
        if groups and t["group"] not in groups:
            continue
        if names and tid not in names and t["name"] not in names:
            continue
        sel.append(t)
    return sorted(sel, key=lambda t: GROUPS.index(t["group"]))


def run_one(t, ctx, echo):
    r = Result(t)
    ctx.result = r
    t0 = time.time()
    try:
        r.summary = t["fn"](ctx, r) or ""
        r.status = "FAIL" if r.problems else "WARN" if r.warnings else "PASS"
    except Skip as e:
        r.status, r.summary = "SKIP", str(e)
    except Exception as e:                       # the harness or the board broke: say where
        r.status, r.summary = "ERROR", "%s: %s" % (type(e).__name__, e)
        ctx.log(traceback.format_exc())
    r.seconds = time.time() - t0
    ctx.result = None
    echo(r)
    return r


# ---- report ------------------------------------------------------------------
def write_report(results, out, meta):
    out = Path(out)
    (out / "report.json").write_text(json.dumps(dict(meta=meta, results=[r.as_dict() for r in results]), indent=2))
    counts = {s: sum(r.status == s for r in results) for s in ("PASS", "WARN", "FAIL", "ERROR", "SKIP")}
    L = ["# Board test report", "",
         "- board: `%s`, kernel `%s`" % (meta.get("board"), meta.get("kernel", "?")),
         "- started %s, %.0f s" % (meta.get("started"), meta.get("seconds", 0)),
         "- " + ", ".join("%d %s" % (n, s) for s, n in counts.items() if n), "",
         "| Test | Status | Summary | s |", "|---|---|---|---|"]
    for r in results:
        L.append("| `%s` %s | **%s** | %s | %.0f |" % (r.id, r.title, r.status, r.summary.replace("|", "/"), r.seconds))
    for r in results:
        if not (r.problems or r.warnings or r.metrics or r.files):
            continue
        L += ["", "## %s (%s)" % (r.id, r.status), ""]
        L += ["- FAIL: " + p for p in r.problems] + ["- WARN: " + w for w in r.warnings]
        if r.metrics:
            L.append("- " + ", ".join("%s = %s" % (k, v) for k, v in r.metrics.items()))
        L += ["", " ".join("![%s](%s)" % (Path(f).stem, f) for f in r.files)] if r.files else []
        if os.path.exists(out / "logs" / (r.id + ".txt")):
            L.append("- log: `logs/%s.txt`" % r.id)
    (out / "report.md").write_text("\n".join(L) + "\n")
    return counts


def grep(pattern, text, group=1, conv=str, default=None):
    m = re.search(pattern, text, re.M)
    return conv(m.group(group)) if m else default
