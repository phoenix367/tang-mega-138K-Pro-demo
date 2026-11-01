#!/usr/bin/env python3
"""Load a bitstream to SRAM, set the DDR bridge debug MODE from U-Boot, boot
Linux and report how far it got.

  boot_mode.py BITSTREAM.fs MODE [--wait 90] [--log FILE]

MODE is written to ddr_perf's MODE register (0xF8000020) at the U-Boot prompt
before `boot`, so one bitstream can bisect bridge features
(bit0 no-prefetch, bit1 no-retention, bit2 no-write-merge).
Needs GOWIN_PATH; uses the external USB-UART (see uart_console.py).
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uart_console as uc  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fs")
    ap.add_argument("mode", type=lambda x: int(x, 0))
    ap.add_argument("--wait", type=float, default=90, help="seconds to wait for login")
    ap.add_argument("--log", default=None)
    a = ap.parse_args()

    s = uc.open_port()
    s.reset_input_buffer()
    env = dict(os.environ, MODE="sram", FS=os.path.abspath(a.fs))
    prog = subprocess.Popen([os.path.join(REPO, "scripts/gw_program.sh")], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = ""
    # catch the autoboot countdown
    text, hit = uc.read_until(s, ["Hit any key"], 90)
    log += text
    if hit is None:
        print("no U-Boot autoboot prompt seen")
        print(log[-2000:])
        sys.exit(2)
    s.write(b" ")
    text, hit = uc.read_until(s, ["=> "], 10)
    log += text
    s.write(b"mw.l 0xf8000020 0x%x; md.l 0xf8000018 3\r" % a.mode)
    text, _ = uc.read_until(s, ["=> "], 10)
    log += text
    print("U-Boot:", " ".join(l.strip() for l in text.splitlines()[1:2]))
    s.write(b"boot\r")
    t0 = time.time()
    text, hit = uc.read_until(s, ["login:"], a.wait)
    log += text
    prog.wait()
    if a.log:
        open(a.log, "w").write(log)
    clean = log.replace("\r", "")
    oops = clean.count("Oops")
    init = [l for l in clean.splitlines() if "Run /init" in l]
    print("mode 0x%x: %s after %.0f s, %d oops, %s" % (
        a.mode, "LOGIN" if hit else "no login", time.time() - t0, oops,
        init[0].strip() if init else "init not reached"))
    for l in clean.splitlines():
        if "Unable to handle" in l or "epc :" in l or "Segmentation" in l:
            print("   ", l.strip())
            oops -= 1
            if oops < -6:
                break


if __name__ == "__main__":
    main()
