#!/usr/bin/env python3
"""boardtest.py -- the board's peripheral test harness: kernel, network, gateware cores
and the desktop, run from the host over ssh and the input bridge.

  scripts/boardtest/boardtest.py                  # everything (~10 min)
  scripts/boardtest/boardtest.py --quick          # shorter transfers and clips (~5 min)
  scripts/boardtest/boardtest.py -g kernel,net    # some groups
  scripts/boardtest/boardtest.py -t cores.jpeg,ui.files
  scripts/boardtest/boardtest.py -i sd_clips      # also the SD card's own MJPEG clips
  scripts/boardtest/boardtest.py --list

Report: <out>/report.md and report.json, raw output in <out>/logs/, screenshots in
<out>/shots/.  Exit status 0 = no FAIL and no ERROR.  See scripts/boardtest/README.md.
"""
import argparse, datetime, os, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bt import core, t_kernel, t_net, t_cores, t_ui  # noqa: E402,F401  (registers the tests)
from bt.board import Board, BoardError  # noqa: E402
from bt.media import Media  # noqa: E402

COLOR = dict(PASS="32", WARN="33", FAIL="31", ERROR="35", SKIP="36")


def default_out():
    base = Path("/mnt/data/build") if Path("/mnt/data/build").is_dir() else Path.cwd()
    return base / "boardtest" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-b", "--board", default=os.environ.get("BOARD_IP", "192.168.200.2"))
    ap.add_argument("-g", "--group", help="comma-separated groups: " + ",".join(core.GROUPS))
    ap.add_argument("-t", "--test", help="comma-separated tests (group.name or name)")
    ap.add_argument("-i", "--include", default="", help="optional tests to add, e.g. sd_clips")
    ap.add_argument("-q", "--quick", action="store_true", help="shorter transfers, clips and memory tests")
    ap.add_argument("-o", "--out", help="output directory (default /mnt/data/build/boardtest/<time>)")
    ap.add_argument("-l", "--list", action="store_true", help="list the tests and exit")
    args = ap.parse_args()

    groups = args.group.split(",") if args.group else None
    names = args.test.split(",") if args.test else None
    include = [s for s in args.include.split(",") if s]
    sel = core.select(groups, names, include)
    if args.list:
        for t in core.select(include=[x["name"] for x in core.TESTS]):
            flags = " (optional)" if t["optional"] else " (slow)" if t["slow"] else ""
            print("  %-22s %s%s" % ("%s.%s" % (t["group"], t["name"]), t["title"], flags))
        return 0
    if not sel:
        print("no tests selected (see --list)")
        return 2

    out = Path(args.out) if args.out else default_out()
    out.mkdir(parents=True, exist_ok=True)
    media = Media(out.parent / "media" if not args.out else out / "media")
    tty = sys.stdout.isatty()

    def echo(r):
        st = "\033[%sm%-5s\033[0m" % (COLOR[r.status], r.status) if tty else "%-5s" % r.status
        print("  %s %-22s %s  (%.0f s)" % (st, r.id, r.summary, r.seconds), flush=True)
        for p in r.problems:
            print("        - " + p)
        for w in r.warnings:
            print("        ~ " + w)

    board = Board(args.board)
    if not board.reachable():
        print("the board does not answer on %s:22.  Check the cable and its address; the serial console"
              " shows what it thinks: scripts/uart_console.py run 'ifconfig eth0; cat /run/network.state'" % args.board)
        return 2
    started = time.time()
    try:
        board.run("mkdir -p /tmp/bt", timeout=60)
        kernel = board.run("uname -r; uname -v")[1].replace("\n", " ").strip()
        desktop_was = board.run("pgrep -x lvdesk >/dev/null")[0] == 0
    except BoardError as e:
        print("cannot log in to the board: %s" % e)
        return 2
    print("boardtest: %d tests on %s (%s), report in %s" % (len(sel), args.board, kernel, out))
    ctx = core.Ctx(args, board, out, media)
    results = []
    try:
        for g in core.GROUPS:
            ts = [t for t in sel if t["group"] == g]
            if ts:
                print("[%s]" % g)
            for t in ts:
                results.append(core.run_one(t, ctx, echo))
    except KeyboardInterrupt:
        print("interrupted")
    finally:
        try:
            if desktop_was:
                ctx.desktop(True)             # the cores group stops it
            board.run("rm -rf /tmp/bt")
        except Exception as e:                # report anyway
            print("cleanup: %s" % e)
        ctx.close()
        board.close()
    meta = dict(board=args.board, kernel=kernel, started=datetime.datetime.fromtimestamp(started).isoformat(" ", "seconds"),
                seconds=time.time() - started, quick=args.quick,
                git=subprocess.run(["git", "-C", str(core.REPO), "describe", "--always", "--dirty"],
                                   capture_output=True, text=True).stdout.strip())
    counts = core.write_report(results, out, meta)
    print("%s in %.0f s -- %s" % (", ".join("%d %s" % (n, s) for s, n in counts.items() if n), time.time() - started,
                                  out / "report.md"))
    return 1 if counts["FAIL"] or counts["ERROR"] else 0


if __name__ == "__main__":
    sys.exit(main())
