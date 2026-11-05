# scripts/boardtest/ — the board's peripheral test harness

`boardtest.py` checks a running board from the host: the kernel and its drivers, the
network, the gateware cores and the desktop. Everything runs over ssh and the
desktop's input bridge, so nothing needs to be installed on the board, and a reflash
needs no preparation before a test run. The checks are the ones that proved
themselves while each part was brought up. Bit-exact checks compare against a CRC, a
C model or FFmpeg. Measurements watch the panel (`lcdmon`), the audio core's
counters, md5 round trips, and changes in screen grabs.

```sh
scripts/boardtest/boardtest.py                  # all groups, ~5 min
scripts/boardtest/boardtest.py --quick          # shorter transfers / memory test
scripts/boardtest/boardtest.py -g kernel,net    # some groups
scripts/boardtest/boardtest.py -t cores.jpeg,ui.files
scripts/boardtest/boardtest.py -i sd_clips      # + every MJPEG clip on the SD card, 40 s each
scripts/boardtest/boardtest.py --list
BOARD_IP=192.168.200.2 (default) or -b ADDR
```

Output: `report.md` (a table plus the details), `report.json`, `logs/<test>.txt` (every
command and its raw output) and `shots/*.png` (screen grabs), in
`/mnt/data/build/boardtest/<date-time>/` (or `-o DIR`). Test media is cached in
`/mnt/data/build/boardtest/media/`. Exit status: 0 = no FAIL and no ERROR.

Statuses: **PASS**; **WARN**, which works but is worth a look (each warning says why);
**FAIL**; **ERROR**, where the test itself could not run (traceback in its log); **SKIP**,
when a precondition is missing (no SD card, no cross toolchain to build a tool).

## Tests

| Test | Checks | Fails when |
|---|---|---|
| `kernel.version` | `uname`, uptime, memory, `/etc/issue` | MemTotal < 900 MB, `/etc/issue` without this kernel's `uname -r` / `uname -v` (rcS writes them in) or with an escape left (warn: no `-tangmega138k` name, or the release in `uname -v` is not `linux/RELEASE`) |
| `kernel.dmesg` | the kernel log | oops / BUG / panic / WARNING; warns on hung tasks, I/O errors, MMC errors, underruns |
| `kernel.drivers` | probe line + device node of every board driver (LCD, IDCT, ADC, fan, PT8211, SD host, EEPROM, I2C mux, DDR counters, TSE MAC + link, input bridge), hwmon names | a driver missing; warns on a JPEG core < 2048 wide (before Build 72) or YUV buffers too small for 720p (before kernel #93) |
| `kernel.config` | `/proc/config.gz` | a board option not `=y` |
| `kernel.io_accounting` | `/proc/PID/io` after 4 MB to tmpfs, to the card, from the card | tmpfs counted as disk I/O, or the card's bytes not counted |
| `kernel.eeprom` | the MAC at EEPROM 0x110, eth0, `/etc/board.conf` | they differ |
| `kernel.services` | inputd, lvdesk, dropbear, boardcfg, S80fan, getty, ntpd, `/run/network.state` | one missing |
| `kernel.time` | clock, `/run/ntp.state` | "synced" at stratum 16 after anything but a step (warn: clock before 2024) |
| `kernel.ntp_hook` | the ntpd event hook driven with made-up events (`NTP_STATE` in `/tmp/bt`): periodic without a server, step, stratum, periodic, unsync, periodic | a state other than waiting → synced → synced → synced → unsynced → unsynced |
| `kernel.login` | `TERM` of a login shell for xterm-256color / xterm-kitty / vt100 clients | `/etc/profile` maps them wrongly |
| `kernel.isa` | the `isa` line of `/proc/cpuinfo` against `dsp_probe` and `ext_probe`: P (DSP), XAndesPerf, XAndesCoDense (`exec.it`), Zbb | an extension advertised that does not execute, or one that executes but is not advertised; P / xandesperf / xandescodense missing (kernel #96+ with OpenSBI's A25 override) |
| `kernel.ucsr` | `ucsr_test 4 5000`: four processes keep their own DSP `ucode` and CoDense `uitb` across `sched_yield()` | a process reads another's value (the kernel does not switch them) |
| `kernel.rootfs_atomics` | `objdump` of every ELF in `linux/rootfs` (host tree) | any `lr.w` / `sc.w` / `amo*.w` |
| `net.link` | carrier, operstate, address vs `network.state` | |
| `net.ping` | 50 pings | loss ≥ 5 % (warn > 0) |
| `net.tcp_to_board` | board `wget` from a host HTTP server: 32 MB speed, 8 MB md5 | md5 differs (warn < 3 MB/s) |
| `net.tcp_from_board` | host download from board `httpd`: 32 MB, md5 | md5 differs (warn < 2.5 MB/s) |
| `net.errors` | eth0 error counters across the transfers | (warnings) |
| `net.scp` | 4 MB scp up and down, md5 | md5 differs |
| `cores.lcd` | `fbtest bars/grad/noise/write`: framebuffer CRC = panel CRC | any MISMATCH |
| `cores.yuv` | `yuvtest`, `yuvtest -l` | CRC mismatch |
| `cores.scaler` | `scaletest` (scaler + OSD scenes by CRC) | FAILED |
| `cores.idct` | `idcttest` (core vs FFmpeg's integer IDCT) | FAILED |
| `cores.jpeg` | `vidplay -C 100` on 852×480 and 1280×720 MJPEG: every frame vs FFmpeg's C decoder | any pixel differs |
| `cores.audio` | `wavplay` on the `wavgen.py` set: frames + CRC at the DAC | MISMATCH, or a CRC other than wavgen's |
| `cores.video` | 852×480 and 1280×720, 25 fps, `vidplay -v` + `lcdmon` | a packet skipped, a picture held too long, LCD underruns, audio xruns |
| `cores.sd_clips` (optional) | the same for every MJPEG clip in `/mnt/sd/video` | as above |
| `cores.sensors` | die temperature, rails vs nominal (0.9 / 1.0 / 0.9 / 1.8 / 1.8 / 1.5 V) | outside 10–85 °C or ±10 %, a fault flag |
| `cores.fan` | tacho rpm | (warns at 0 rpm) |
| `cores.sd` | card identity and class, raw read, write through vfat, md5 of 32 MB read back | md5 differs (warn: read < 4, write < 1 MB/s) |
| `cores.ddr_perf` | `gowin-ddr-perf` sysfs: `counters` around 16 MB written to tmpfs and read back; cycles vs wall time over the workload and since boot; one sample adds up (transfers by burst type and by size); the trace armed around a file read | bus bytes below the workload's, cycles off by > 5 % or a lost 43 s wrap, sums that differ, a trace that is not full or not DDR addresses (warn: bridge MODE not 0x10000) |
| `cores.ddr` | `ddr_memtest 64 1` | any MISMATCH |
| `ui.inputd` | connect to inputd, grab 800×480 | |
| `ui.reconnect` | a client dropped without a word, then a new one | no frame |
| `ui.panels` | every home tile opens its panel (screen grab differs from home, saved) | a tile does nothing; lvdesk restarted |
| `ui.files` | file manager: double click opens a folder, Ctrl+C/V makes "a (copy).txt", F2 renames, right click shows the menu and Esc closes it, Delete + Tab + Enter deletes, Ctrl+A selects | an outcome missing on the board (checked over ssh) or on the screen |
| `ui.video` | a clip double-clicked in Files, with `lcdmon` watching (the desktop must stay idle) | skipped packets or late pictures; lvdesk restarted |

## What it does to the board

- **Desktop:** the cores group stops it (`fbtest` and friends draw on the panel); the
  ui group starts it again, and the runner restarts it at the end if it was running.
- **Text console:** while the desktop is down, the console cursor is hidden and its
  blink turned off. Otherwise fbcon draws into `/dev/fb0` behind fbtest's back, and
  the CPU and panel CRCs differ.
- **Temporary files:**
  - `/tmp/bt/` holds the tools, scripts, clips and WAVs; it is removed at the end;
  - `/mnt/sd/bt_*.bin` are the card's test files, removed right away;
  - `/home/ae350/!bt_files` and `!!bt_video` are the UI test folders, removed by the test.
- **The panel:** the board is in use while the tests run. Patterns and clips play on
  it, and the speaker plays tones.

Nothing is written to flash, nothing reboots, and no settings change.

## How it works (and why)

- **One ssh connection** (`bt/board.py`): an OpenSSH ControlMaster for the whole run,
  so the password (ae350 / ae350, no key installed) goes in once, and later commands
  skip the A25's slow key exchange.
- **Root work goes in a script file:** the script is copied to `/tmp/bt/` and run with
  `doas sh FILE` on a tty. Quotes do not survive `ssh` plus `doas sh -c '…'`.
- **Detached starts use `setsid … &` followed by `sleep 1`:** a plain `&` job dies when
  the ssh session hangs up. That covers the desktop's supervisor, `lcdmon` and `httpd`.
- **Board-side programs** come from `src/apps/tests` (`make` builds them with the musl
  cross toolchain) and are copied to `/tmp/bt/`. `vidplay` and `wavplay` are the
  rootfs ones.
- **The input bridge** (`bt/ui.py`) is `netinput.Link`, as `doc/tools/shot.py` uses
  it. inputd serves **one client at a time**, so close any `netinput.py` window
  first; otherwise the harness reports the bridge as busy.
- **Locating things on screen:**
  - the UI flows use lvdesk's fixed geometry: tile centres, and the Files table's
    rows 26 px apart from y 196;
  - test folders start with "!", which sorts before letters and dot files, so the
    test's folder is always the first row of the home folder;
  - dialogs are driven by keyboard (F2, Tab, Enter) instead of guessed button positions.
- **Screen checks** compare grabs inside boxes chosen so that the selection highlight
  and the mouse pointer (drawn into the framebuffer) cannot fake a change.
- **Media** (`bt/media.py`):
  - WAVs come from `wavgen.py`, with the frame counts and CRCs the audio core must report;
  - clips are FFmpeg's moving `testsrc2` plus a tone, encoded like the player's clips
    (MJPEG q 8, yuvj420p, AAC);
  - random blobs feed the md5 round trips.

## Adding a test

```python
from .core import Skip, grep, test

@test("cores", "mycore", "my core: what it checks")
def mycore(ctx, r):
    tool = ctx.tool("mytest")                     # src/apps/tests/mytest, built and copied
    rc, out = ctx.root("%s --check\n" % tool)     # as root; ctx.run() as the user
    r.check(rc == 0, "mytest: " + out[-200:])     # a FAIL, the test goes on
    r.metric("speed", grep(r"([\d.]+) MB/s", out, conv=float))
    return "one-line summary"
```

Put it in the `t_<group>.py` of its group (imported by `boardtest.py`). `ctx.desktop(False)`
/ `ctx.desktop(True)` set the desktop's state, `ctx.ui` is the input bridge, `ctx.shot(img,
name)` saves a grab into the report, and `raise Skip("why")` skips.
