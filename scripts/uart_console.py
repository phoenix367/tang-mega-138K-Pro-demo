#!/usr/bin/env python3
"""Drive the AE350 Linux console over the external USB-UART (PL2303, /dev/ttyUSB0).

Usage:
  uart_console.py login                 # log in as ae350 and become root (doas -s)
  uart_console.py run 'cmd' [timeout]   # run one shell command, print its output
  uart_console.py listen [seconds]      # dump raw console output (e.g. boot log)
  uart_console.py push LOCAL REMOTE     # copy a file to the board (gzip+base64)

Env: UART_DEV (default /dev/ttyUSB0), UART_BAUD (default 115200).
"""
import os
import sys
import time

import serial

DEV = os.environ.get("UART_DEV", "/dev/ttyUSB0")
BAUD = int(os.environ.get("UART_BAUD", "115200"))
MARK = "__DONE_7f3a__"


def open_port():
    return serial.Serial(DEV, BAUD, timeout=0.1)


def read_until(s, needles, timeout):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        chunk = s.read(4096)
        if chunk:
            buf += chunk
            text = buf.decode(errors="replace")
            for n in needles:
                if n in text:
                    return text, n
    return buf.decode(errors="replace"), None


def login(s):
    s.write(b"\x03\r")
    text, hit = read_until(s, ["login:", "Password:", "# ", "$ "], 5)
    if hit == "Password:":
        s.write(b"\r")                      # abort a half-finished login
        text, hit = read_until(s, ["login:"], 10)
    if hit in ("login:", None):
        s.write(b"ae350\r")
        read_until(s, ["Password:"], 10)
        s.write(b"ae350\r")
        text, hit = read_until(s, ["$ ", "# "], 15)
    if hit == "$ ":
        s.write(b"doas -s\r")
        text, hit = read_until(s, ["assword", "# "], 10)
        if hit == "assword":
            s.write(b"ae350\r")
            text, hit = read_until(s, ["# "], 10)
    return hit == "# "


def run(s, cmd, timeout):
    s.reset_input_buffer()
    s.write((cmd + "; echo __DONE_'7f3a'__\r").encode())
    text, hit = read_until(s, [MARK + "\r\n", MARK + "\n"], timeout)
    # strip the echoed command line and the trailing marker/prompt
    lines = text.replace("\r", "").split("\n")
    out = [l for l in lines[1:] if MARK not in l]
    return "\n".join(out).rstrip(), hit is not None


def push(s, local, remote):
    """Send a file through a shell heredoc: gzip | base64, one line at a time,
    waiting for the heredoc continuation prompt so the UART never overruns."""
    import base64
    import gzip
    data = base64.encodebytes(gzip.compress(open(local, "rb").read(), 9)).decode()
    s.reset_input_buffer()
    s.write(("base64 -d << 'B64EOF' | gunzip > %s\r" % remote).encode())
    read_until(s, ["> "], 5)
    lines = data.splitlines()
    for i, line in enumerate(lines):
        s.write((line + "\r").encode())
        _, hit = read_until(s, ["> "], 5)
        if hit is None:
            print("push: no prompt after line %d" % i)
            return False
    s.write(b"B64EOF\r")
    read_until(s, ["# ", "$ "], 10)
    out, ok = run(s, "chmod +x %s; md5sum %s" % (remote, remote), 20)
    import hashlib
    want = hashlib.md5(open(local, "rb").read()).hexdigest()
    good = want in out
    print("push %s -> %s: %d bytes, md5 %s" % (local, remote, len(open(local, "rb").read()),
                                              "OK" if good else "MISMATCH: " + out))
    return good


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    op = sys.argv[1]
    s = open_port()
    if op == "login":
        ok = login(s)
        print("root shell" if ok else "LOGIN FAILED")
        sys.exit(0 if ok else 1)
    elif op == "run":
        timeout = float(sys.argv[3]) if len(sys.argv) > 3 else 30
        out, ok = run(s, sys.argv[2], timeout)
        print(out)
        sys.exit(0 if ok else 2)
    elif op == "push":
        sys.exit(0 if push(s, sys.argv[2], sys.argv[3]) else 1)
    elif op == "listen":
        secs = float(sys.argv[2]) if len(sys.argv) > 2 else 10
        end = time.time() + secs
        while time.time() < end:
            chunk = s.read(4096)
            if chunk:
                sys.stdout.write(chunk.decode(errors="replace"))
                sys.stdout.flush()
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
