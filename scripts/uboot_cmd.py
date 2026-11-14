#!/usr/bin/env python3
"""Load a bitstream to SRAM, stop U-Boot at its prompt and run commands.

  uboot_cmd.py BITSTREAM.fs 'cmd1' 'cmd2' ...   (each waits for the next '=> ')
Env: GOWIN_PATH; per-command timeout UBOOT_TIMEOUT (default 120 s).
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import uart_console as uc  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
s = uc.open_port()
s.reset_input_buffer()
env = dict(os.environ, MODE="sram", FS=os.path.abspath(sys.argv[1]))
prog = subprocess.Popen([os.path.join(REPO, "scripts/gw_program.sh")], env=env,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
text, ok = uc.stop_autoboot(s, 90)
if not ok:
    sys.exit("no U-Boot prompt:\n" + text[-1500:])
prog.wait()
tmo = float(os.environ.get("UBOOT_TIMEOUT", "120"))
for cmd in sys.argv[2:]:
    t0 = time.time()
    s.write((cmd + "\r").encode())
    text, hit = uc.read_until(s, ["\nRISC-V # ", "\n=> "], tmo)
    print("# " + text.replace("\r", "").replace("RISC-V # ", "").rstrip())
    print("  (%.2f s)" % (time.time() - t0))
    if hit is None:
        print("(timeout)")
        break
