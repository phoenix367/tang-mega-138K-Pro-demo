---
name: board-test
description: Run the Tang Mega 138K board's test harness (scripts/boardtest/boardtest.py) against the live board, choose the groups or tests that fit the change, read the report and logs, compare with the previous run for regressions, triage FAIL / WARN / ERROR results, and add a test for a new core or driver. Use this whenever the user asks to test the board, check that a reflash, new kernel or new bitstream works, find out whether something regressed, look into a failing board test, or add a hardware check — even when phrased as "is the board ok", "run the tests", "check the cores" or "did that break anything".
---

# Board tests

`scripts/boardtest/boardtest.py` checks a running board from the host, over ssh and the
desktop's input bridge:
- the kernel and its drivers;
- the network;
- the gateware cores, bit-exactly;
- the desktop.

Nothing is installed on the board, nothing is written to flash, and nothing reboots.
`scripts/boardtest/README.md` lists every test, what fails it, and how the harness works.
Read it for anything this page does not cover.

## 1. Before a run

- **The board must answer.** Check with `scripts/board.py wait 60`. The address is
  192.168.200.2 by default; set `BOARD_IP` or pass `-b ADDR` otherwise.
- **Close `netinput.py`.** inputd serves one client at a time; with another one
  connected, the ui group reports the bridge as busy.
- **The board is busy during a run.** Patterns and clips play on the panel and tones on
  the speaker. The cores group stops the desktop; the run restarts it at the end. Tell
  the user if they may be using the board.
- **Board-side tools** (`fbtest`, `yuvtest`, `idcttest`, `ddr_memtest`…) are built from
  `src/apps/tests` with the soft-atomic musl toolchain. Without that toolchain those
  tests SKIP.
- **One run at a time.** Never run alongside another run or a flash.

## 2. Choose the scope

| situation | command |
|---|---|
| after any reflash, and before recording a release | `scripts/boardtest/boardtest.py` (all groups, ~5–6 min) |
| a quick sanity check | `scripts/boardtest/boardtest.py --quick` (shorter transfers and memory test) |
| a kernel, driver, DT or rootfs change | `-g kernel`, plus the group of what changed |
| a network change | `-g net` |
| one core's RTL or its driver | `-t cores.<name>`: lcd, yuv, scaler, idct, jpeg, audio, video, sensors, fan, sd, ddr_perf, ddr |
| the desktop, lvdesk or inputd | `-g ui` |
| every MJPEG clip on the SD card | `-i sd_clips` (40 s per clip) |

- `-g` and `-t` take comma-separated lists (`-g kernel,net`); `--list` prints every
  test.
- Run a full run with `run_in_background`.
- The groups run in a fixed order: kernel, net, cores, ui. The cores group stops the
  desktop and the ui group starts it again.

## 3. Read the result

The last line reads `N PASS, M WARN … -- <dir>/report.md`. The exit status is 0 when
there is no FAIL and no ERROR.

| status | meaning |
|---|---|
| PASS | the check passed |
| WARN | works, but worth a look; the warning says why |
| FAIL | the check failed |
| ERROR | the test itself could not run; the traceback is in its log |
| SKIP | a precondition is missing (no SD card, no toolchain) |

**Expected on this bench**, not regressions:
- `kernel.time` WARN: no internet, so the clock says 1970 and NTP is waiting.
- `net.errors` WARN: a few `rx_errors`. These are the known residual RGMII receive
  errors, about one frame in 10⁵–10⁶.
- `kernel.version` WARN when the release in the board's `uname -v` is not
  `linux/RELEASE`. That is expected whenever the board runs another kernel than the
  tree describes.

**Compare with the previous comparable run:**
```
python3 .claude/skills/board-test/scripts/compare_runs.py [NEW [OLD]] [--min-change PCT]
```

By default it compares the latest run with the latest earlier run that covers the same
tests. It prints:
- status changes;
- tests that are new;
- numeric metrics that moved by ≥ 10 %: throughput, latency, error counts;
- short labels that changed: release, link speed.

Some metrics drift 10–20 % from run to run, notably ping round-trip times and the DDR
miss latency. Treat a single move as noise unless it repeats or crosses the test's
warning threshold.

**Details of a run** (`/mnt/data/build/boardtest/<date-time>/`):
- `report.md`: the table and each test's details;
- `logs/<test>.txt`: every command and its raw output;
- `shots/*.png`: screen grabs from the ui tests. Read them to see what the screen
  showed.

## 4. Triage

Start from `logs/<test>.txt`, then rerun only that test (`-t group.name`) to see
whether it repeats.

| test | where to look |
|---|---|
| `kernel.dmesg` | the first Oops, BUG or WARNING in the log; `scripts/board.py run 'dmesg'` for context |
| `kernel.drivers` | a driver that did not probe: its DT node (`linux/ae350-linux.dts`), its config option (`kernel.config`), or gateware older than the driver (the core's ID or capability register); its probe error in dmesg |
| `kernel.rootfs_atomics` | a binary in `linux/rootfs` built with a toolchain that emits atomics; rebuild it through `scripts/rootfs/` or `src/apps/` with the soft-atomic musl toolchain |
| `net.*` | link speed in `kernel.drivers` (should be 1Gbps/Full); the error counters in `net.errors`; a PHY that came up at 100M after an FPGA reload |
| `cores.lcd`, `cores.yuv`, `cores.scaler` | the LCD core or `gowin-lcdfb`; something else drawing on `/dev/fb0` during the test (a leftover desktop or console process); `src/rtl/video/tb/run_tb.sh` |
| `cores.idct`, `cores.jpeg` | the JPEG core or `gowin-idct`; `src/rtl/idct/tb/run_tb.sh` and `run_jpeg_tb.sh`; `vidplay -C` on the board for the failing clip |
| `cores.audio` | a frame or CRC mismatch: the audio core or `gowin-pt8211`. A stall after a few interrupts was once the PLIC losing completions when `APB_CLK` shared the AHB clock net (`doc/06-key-findings.md`) |
| `cores.video`, `ui.video` | skipped packets or held pictures: CPU load (is the desktop idle? anything else running?), LCD underruns (the bridge's video port) |
| `cores.sd` | no card, a slow card, an md5 mismatch; a card initialised in SPI mode needs a power cycle |
| `cores.ddr`, `cores.ddr_perf` | the bridge's MODE (should be `0x10000`) and the kernel's `PATCHES/0005`. A `ddr_memtest` MISMATCH is memory corruption: stop and investigate before anything else |
| `ui.*` | the bridge busy (`netinput.py` open); lvdesk restarted (it crashed); the desktop's layout changed (the flows use lvdesk's fixed geometry, so update `bt/t_ui.py` with the desktop) |
| any ERROR | the harness broke: ssh trouble, a tool that did not build, missing media; the traceback is in the log |

Nothing changed on the live board persists, because the rootfs is in RAM. Fixes go
into the source and a new image (`kernel-release`) or bitstream (`gateware-build`).

## 5. Add a test

Every new core or driver gets a test. Put it in `scripts/boardtest/bt/t_<group>.py`:

```python
from .core import Skip, grep, test

@test("cores", "mycore", "my core: what it checks")
def mycore(ctx, r):
    tool = ctx.tool("mytest")                    # src/apps/tests/mytest, built and copied to /tmp/bt
    rc, out = ctx.root("%s --check\n" % tool)    # as root; ctx.run() as the user
    r.check(rc == 0, "mytest: " + out[-200:])    # a FAIL; the test goes on
    r.metric("speed", grep(r"([\d.]+) MB/s", out, conv=float))
    return "one-line summary"
```

- `r.fail()` and `r.warn()` are also available. `raise Skip("why")` skips.
- `ctx.desktop(False)` / `ctx.desktop(True)` set the desktop's state, `ctx.ui` is the
  input bridge, and `ctx.shot(img, name)` saves a screen grab into the report.
- `@test(..., slow=True)` marks a test that `--quick` shortens (the test reads
  `ctx.quick`); `optional=True` runs it only with `-i NAME`.
- **Prefer checks that prove correctness:** a CRC from the core against a model, md5
  round trips, comparison with FFmpeg. "It printed OK" proves little.
- **Record useful numbers** with `r.metric`, so `compare_runs.py` can track them.
- Add a row for the test to the table in `scripts/boardtest/README.md`.

## 6. Report back

Tell the user:
- the totals;
- each FAIL or ERROR, with its one-line cause;
- WARNs that are not the expected ones;
- notable metric moves against the previous run;
- the report's path.

For a release, these results go into the BOOT.md entry (see `kernel-release` and
`gateware-build`).
