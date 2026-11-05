#!/usr/bin/env python3
"""Run commands on the board over ssh from the host, through the board test
harness's connection code (scripts/boardtest/bt/board.py).

Usage:
  board.py run 'CMD' [TIMEOUT]       # as ae350; prints the output, exits with its status
  board.py root 'SCRIPT' [TIMEOUT]   # a shell script as root (doas sh FILE on a tty;
                                     # `doas sh -c '...'` through ssh breaks the quoting)
  board.py put LOCAL REMOTE          # scp -O (dropbear's scp)
  board.py get REMOTE LOCAL
  board.py wait [TIMEOUT]            # until ssh answers, e.g. after a reflash (default 180 s)

Env: BOARD_IP (default 192.168.200.2). The board's dropbear has no key installed:
ae350 / ae350 (doc/03-boot.md). Nothing written on the board survives a reboot (the
rootfs is an initramfs): changes belong in linux/rootfs/.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "boardtest"))
from bt.board import Board, BoardError  # noqa: E402


def wait(b, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if b.reachable():
            try:
                if b.run("true", timeout=30)[0] == 0:
                    return True
            except BoardError:
                pass
        time.sleep(3)
    return False


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    op, args = sys.argv[1], sys.argv[2:]
    b = Board(os.environ.get("BOARD_IP", "192.168.200.2"))
    try:
        if op == "wait":
            t = float(args[0]) if args else 180
            if wait(b, t):
                print("board up")
                return 0
            print("board not answering after %d s" % t, file=sys.stderr)
            return 1
        if op in ("run", "root") and args:
            t = int(args[1]) if len(args) > 1 else 120
            rc, out = (b.run if op == "run" else b.root)(args[0], timeout=t)
            sys.stdout.write(out.lstrip("\n"))
            return min(rc, 255)
        if op == "put" and len(args) == 2:
            b.put(*args)
            return 0
        if op == "get" and len(args) == 2:
            b.get(*args)
            return 0
        print(__doc__)
        return 2
    except BoardError as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    finally:
        b.close()


if __name__ == "__main__":
    sys.exit(main())
