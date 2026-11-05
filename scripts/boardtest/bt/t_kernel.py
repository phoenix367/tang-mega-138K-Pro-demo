"""kernel: boot log, drivers, configuration, accounting, EEPROM, services, time, login, ISA."""
import glob, os, re, subprocess, time
from pathlib import Path

from .core import REPO, Skip, grep, test

# probe lines of the board's drivers (dmesg) and what each must have created
DRIVERS = [
    ("LCD framebuffer, YUV buffers", r"gowin-lcdfb \S+: (\d+) YUV 4:2:0 scan-out buffers of (\d+) KB", "/dev/fb0"),
    ("LCD scaler + OSD", r"gowin-lcdfb \S+: scaler, \d+ ARGB8888 OSD buffers", None),
    ("JPEG / IDCT core", r"gowin-idct \S+: IDCT core, frames up to (\d+) wide", "/dev/gowin-idct"),
    ("ADC: temperature + rails", r"gowin-adc \S+: on-die temperature", None),
    ("fan PWM + tacho", r"gowin-fan \S+: fan PWM", None),
    ("audio PT8211", r"gowin-pt8211 \S+: PT8211 audio", "/dev/snd/pcmC0D0p"),
    ("SD host", r"gowin-sdhost \S+: SD host, 4-bit", None),
    ("board EEPROM", r"at24 \S+: \d+ byte 24c08 EEPROM", "/sys/bus/nvmem/devices/board-eeprom0"),
    ("I2C mux", r"i2c-mux-gpio \S+: \d+ port mux", None),
    ("DDR bus counters", r"gowin-ddr-perf \S+: DDR bus counters", "/sys/bus/platform/devices/f8000000.ddr-perf/counters"),
    ("Ethernet MAC", r"gw-tse \S+ eth0: Gowin TSE", None),
    ("Ethernet link", r"eth0: Link is Up - (\S+)", None),
    ("input bridge devices", r"input: netinput mouse", "/dev/input/event0"),
]
CONFIG = ["FB_GOWIN_LCD", "GOWIN_IDCT", "SND_GOWIN_PT8211", "SENSORS_GOWIN_ADC", "SENSORS_GOWIN_FAN",
          "MMC_GOWIN_SDHOST", "GOWIN_TSE", "EEPROM_AT24", "I2C_GPIO", "INPUT_EVDEV", "INPUT_UINPUT",
          "TASK_IO_ACCOUNTING", "IKCONFIG_PROC", "GOWIN_DDR_PERF"]
SERVICES = [("inputd", "inputd"), ("lvdesk", "desktop"), ("dropbear", "ssh"), ("boardcfg", "settings daemon"),
            ("S80fan", "fan curve"), ("getty", "serial console")]


@test("kernel", "version", "kernel name, release, uptime; /etc/issue")
def version(ctx, r):
    rc, out = ctx.run("uname -r; uname -v; cut -d' ' -f1 /proc/uptime; grep MemTotal /proc/meminfo")
    lines = out.split("\n")
    r.metric("release", lines[0].strip())
    r.metric("build", lines[1].split()[0] if len(lines) > 1 else "?")
    up = float(lines[2]) if len(lines) > 2 else 0
    mem = grep(r"MemTotal:\s+(\d+)", out, conv=int, default=0) // 1024
    r.metric("uptime_s", int(up))
    r.metric("mem_mb", mem)
    r.check(mem >= 900, "MemTotal %d MB: the board has 1 GB" % mem)
    ctx.kernel = "%s %s" % (lines[0].strip(), r.metrics["build"])
    # scripts/build_kernel.sh: the name from CONFIG_LOCALVERSION, the release (uname -v) from linux/RELEASE
    if "-tangmega138k" not in lines[0]:
        r.warn("kernel %s has no -tangmega138k name (before release #98)" % lines[0].strip())
    tree = (REPO / "linux" / "RELEASE").read_text().strip()
    if r.metrics["build"] != "#" + tree:
        r.warn("the board runs release %s, linux/RELEASE says #%s (built without scripts/build_kernel.sh, "
               "or not flashed)" % (r.metrics["build"], tree))
    # rcS writes the kernel's name and release into the /etc/issue template at boot
    rc, issue = ctx.run("cat /etc/issue")
    r.check(lines[0].strip() in issue and lines[1].strip() in issue and "\\" not in issue,
            "/etc/issue does not carry this kernel's uname -r / -v: %r" % issue.strip()[-160:])
    return "Linux %s, release %s, up %d s, %d MB" % (lines[0].strip(), r.metrics["build"], up, mem)


@test("kernel", "dmesg", "kernel log clean")
def dmesg(ctx, r):
    rc, out = ctx.run("dmesg")
    bad = [l for l in out.split("\n") if re.search(r"Oops|BUG:|Kernel panic|Unable to handle kernel|"
                                                   r"WARNING: CPU|kernel BUG|segfault at|general protection", l)]
    meh = [l for l in out.split("\n") if re.search(r"blocked for more than|I/O error|mmc\d+: (error|timeout)|"
                                                   r"timed out|nobody cared|soft lockup|underrun|fifo error", l, re.I)]
    for l in bad[:10]:
        r.fail(l.strip())
    for l in meh[:10]:
        r.warn(l.strip())
    r.metric("lines", out.count("\n"))
    return "%d lines, %d errors, %d warnings" % (out.count("\n"), len(bad), len(meh))


@test("kernel", "drivers", "board drivers probed")
def drivers(ctx, r):
    rc, log = ctx.run("dmesg")
    nodes = [n for _, _, n in DRIVERS if n] + ["/dev/uinput", "/dev/input/event1", "/dev/mmcblk0"]
    rc, have = ctx.run("for f in %s; do [ -e $f ] && echo HAVE $f; done; cat /sys/class/hwmon/*/name" % " ".join(nodes))
    ok = 0
    for name, pat, node in DRIVERS:
        m = re.search(pat, log)
        if not m:
            # an old boot log can have rotated out of the ring buffer: then the node decides
            if node and "HAVE " + node in have:
                r.warn("%s: probe line not in dmesg (rotated?), %s exists" % (name, node))
            else:
                r.fail("%s: not probed" % name)
            continue
        ok += 1
        if node and "HAVE " + node not in have:
            r.fail("%s: probed, but %s is missing" % (name, node))
    for n in ("/dev/uinput", "/dev/input/event1"):
        r.check("HAVE " + n in have, n + " missing")
    if "HAVE /dev/mmcblk0" not in have:
        r.warn("no microSD card (/dev/mmcblk0)")
    for hw in ("gowin_adc", "gowin_fan"):
        r.check(hw in have, "hwmon %s missing" % hw)
    width = grep(r"IDCT core, frames up to (\d+) wide", log, conv=int)
    yuv_kb = grep(r"scan-out buffers of (\d+) KB", log, conv=int)
    link = grep(r"eth0: Link is Up - (\S+)", log)
    if width:
        r.metric("idct_max_width", width)
        if width < 2048:
            r.warn("JPEG core takes frames up to %d wide: gateware before Build 72, no 720p" % width)
    if yuv_kb:
        r.metric("yuv_buffer_kb", yuv_kb)
        if yuv_kb < 1350:
            r.warn("YUV buffers of %d KB hold no 1280x720 picture (kernel before #93)" % yuv_kb)
    if link:
        r.metric("link", link)
        r.check(link.startswith("1Gbps"), "Ethernet link %s, not 1 Gbit/s" % link)
    return "%d of %d probe lines; JPEG up to %s wide, YUV buffers %s KB, link %s" % (
        ok, len(DRIVERS), width, yuv_kb, link)


@test("kernel", "config", "kernel configuration")
def config(ctx, r):
    rc, out = ctx.run("zcat /proc/config.gz")
    if rc:
        raise Skip("no /proc/config.gz")
    missing = [c for c in CONFIG if "CONFIG_%s=y" % c not in out]
    for c in missing:
        r.fail("CONFIG_%s is not =y" % c)
    return "%d of %d options set" % (len(CONFIG) - len(missing), len(CONFIG))


@test("kernel", "io_accounting", "per-process I/O counters (/proc/PID/io)")
def io_accounting(ctx, r):
    # the shell's own counters after a child wrote: tmpfs is no disk I/O, the card is
    script = """
show() { awk '/^(wchar|write_bytes|rchar|read_bytes):/ {printf "%s %s ", $1, $2}' /proc/$1/io; echo; }
sh -c 'dd if=/dev/zero of=/tmp/bt/io.bin bs=1M count=4 2>/dev/null; cat /proc/$$/io' > /tmp/bt/io1
echo "TMPFS $(awk '/^(wchar|write_bytes):/ {printf "%s %s ", $1, $2}' /tmp/bt/io1)"
if grep -q ' /mnt/sd ' /proc/mounts; then
  sh -c 'dd if=/dev/zero of=/mnt/sd/bt_io.bin bs=1M count=4 conv=fsync 2>/dev/null; cat /proc/$$/io' > /tmp/bt/io2
  echo "SDW $(awk '/^(wchar|write_bytes):/ {printf "%s %s ", $1, $2}' /tmp/bt/io2)"
  sync; echo 3 > /proc/sys/vm/drop_caches
  sh -c 'dd if=/mnt/sd/bt_io.bin of=/dev/null bs=1M 2>/dev/null; cat /proc/$$/io' > /tmp/bt/io3
  echo "SDR $(awk '/^(rchar|read_bytes):/ {printf "%s %s ", $1, $2}' /tmp/bt/io3)"
  rm -f /mnt/sd/bt_io.bin
fi
rm -f /tmp/bt/io.bin /tmp/bt/io1 /tmp/bt/io2 /tmp/bt/io3
"""
    rc, out = ctx.root(script)
    if "TMPFS" not in out or "wchar:" not in out:
        r.fail("/proc/PID/io missing: CONFIG_TASK_IO_ACCOUNTING")
        return "no per-process I/O counters"
    wb_tmp = grep(r"TMPFS wchar: \d+ write_bytes: (\d+)", out, conv=int, default=-1)
    r.check(wb_tmp == 0, "writing to tmpfs counted %s disk bytes, expected 0" % wb_tmp)
    if "SDW" not in out:
        return "counters present; no SD card for the disk part"
    wb = grep(r"SDW wchar: \d+ write_bytes: (\d+)", out, conv=int, default=0)
    rb = grep(r"SDR rchar: \d+ read_bytes: (\d+)", out, conv=int, default=0)
    r.metric("sd_write_bytes", wb)
    r.metric("sd_read_bytes", rb)
    r.check(wb >= 4 << 20, "4 MB written to the card counted as %d disk bytes" % wb)
    r.check(rb >= 4 << 20, "4 MB read from the card counted as %d disk bytes" % rb)
    return "tmpfs 0 disk bytes, card write %d / read %d bytes for 4 MB" % (wb, rb)


@test("kernel", "eeprom", "board EEPROM and MAC")
def eeprom(ctx, r):
    rc, out = ctx.root("dd if=/sys/bus/nvmem/devices/board-eeprom0/nvmem bs=1 skip=272 count=6 2>/dev/null | od -An -tx1\n"
                       "cat /sys/class/net/eth0/address\ngrep '^mac=' /etc/board.conf\n")
    lines = [l.strip() for l in out.split("\n") if l.strip()]
    if len(lines) < 2:
        r.fail("EEPROM not readable: " + out.strip()[:120])
        return "unreadable"
    ee = lines[0].replace(" ", ":")
    eth = lines[1]
    r.metric("eeprom_mac", ee)
    r.metric("eth0_mac", eth)
    r.check(ee == eth, "MAC in the EEPROM (0x110) %s differs from eth0 %s" % (ee, eth))
    if len(lines) > 2:
        r.check(lines[2] == "mac=" + eth, "/etc/board.conf says %s, eth0 is %s" % (lines[2], eth))
    return "MAC %s from the EEPROM" % eth


@test("kernel", "services", "daemons running")
def services(ctx, r):
    rc, out = ctx.run("ps -o args; cat /run/network.state; ls /run/lvdesk.lock")
    for proc, what in SERVICES:
        r.check(re.search(r"(^|/|\s|\{)%s(\s|$|\})" % re.escape(proc), out, re.M), "%s (%s) not running" % (proc, what))
    if "ntpd" not in out and "ntp=off" not in out:
        r.warn("ntpd not running")
    r.check("net=" in out, "/run/network.state missing")
    r.metric("network", grep(r"^(net=.*)$", out, default="?"))
    return grep(r"^(net=.*)$", out, default="no network state")


@test("kernel", "time", "clock and NTP state")
def clock(ctx, r):
    rc, out = ctx.run("date +%Y; cat /run/ntp.state 2>/dev/null")
    year = int(out.split("\n")[0] or 0)
    state = grep(r"state=(\S+)", out, default="none")
    stratum = grep(r"stratum=(\d+)", out, conv=int)
    r.metric("year", year)
    r.metric("ntp_state", state)
    if year < 2024:
        r.warn("the clock says %d: no battery RTC and NTP has not set it (no internet?)" % year)
    event = grep(r"event=(\S+)", out, default="")
    if state == "synced" and stratum == 16 and event != "step":
        r.fail("ntp.state says synced at stratum 16 (= unsynchronised) after a '%s' event" % event)
    return "year %d, ntp %s%s" % (year, state, "" if stratum is None else " (stratum %d, %s)" % (stratum, event))


# what the event hook must leave in ntp.state after each ntpd event (busybox runs
# "periodic" every ~11 min whether synchronised or not, "step" with stratum 16)
NTP_EVENTS = [
    ("periodic", 16, "waiting", "no server yet: a periodic event changes nothing"),
    ("step", 16, "synced", "the clock is stepped from a server"),
    ("stratum", 3, "synced", "ntpd locks on, stratum 3"),
    ("periodic", 3, "synced", "periodic while synchronised"),
    ("unsync", 16, "unsynced", "the server is lost"),
    ("periodic", 16, "unsynced", "periodic with no server again"),
]


@test("kernel", "ntp_hook", "NTP event hook: ntp.state after each ntpd event")
def ntp_hook(ctx, r):
    cmd = "f=/tmp/bt/ntp.state; echo 'state=waiting servers=a,b since=1' > $f; "
    for ev, st, _, _ in NTP_EVENTS:
        cmd += ("NTP_STATE=$f stratum=%d offset=0.0123 poll_interval=64 freq_drift_ppm=1 "
                "/usr/share/ntpd/event %s 2>/dev/null; echo \"R %s $(cat $f)\"; " % (st, ev, ev))
    rc, out = ctx.run(cmd + "rm -f $f")
    got = re.findall(r"^R (\S+) state=(\S+)", out, re.M)
    for (ev, st, want, what), (_, state) in zip(NTP_EVENTS, got):
        r.check(state == want, "%s (%s, stratum %d): state=%s, expected %s" % (what, ev, st, state, want))
    r.check(len(got) == len(NTP_EVENTS), "the hook did not run every event (%d of %d)" % (len(got), len(NTP_EVENTS)))
    return "%d events: %s" % (len(got), " -> ".join("%s:%s" % g for g in got))


@test("kernel", "login", "login shell TERM (/etc/profile)")
def login(ctx, r):
    cases = [("xterm-256color", "xterm-256color"), ("xterm-kitty", "xterm-256color"), ("vt100", "linux")]
    got = []
    for client, want in cases:
        term = ctx.board.login_term(client)
        got.append("%s->%s" % (client, term))
        r.check(term == want, "a %s client gets TERM=%s, expected %s" % (client, term, want))
    return ", ".join(got)


def isa_extensions(isa):
    """'rv32imafdcp_zicntr_..._xandesperf' -> {'i', 'm', ..., 'p', 'zicntr', ..., 'xandesperf'}"""
    head, *multi = isa.strip().split("_")
    return set(head[4:]) | set(multi)


# advertised in /proc/cpuinfo <-> the probe's line saying it executed correctly
ISA_PROBES = [
    ("p", "dsp_probe", r"-> (\d+)/(\d+) extended ops correct", "Andes DSP (P draft v0.5)"),
    ("xandesperf", "ext_probe", r"-> XAndesPerf (\d+)/(\d+) correct", "Andes performance extension"),
    ("xandescodense", "ext_probe", r"-> XAndesCoDense (\d+)/(\d+) correct", "Andes CoDense (exec.it)"),
    ("zbb", "ext_probe", r"-> Zbb (\d+)/(\d+) correct", "Zbb"),
]


@test("kernel", "isa", "ISA string in /proc/cpuinfo vs what executes")
def isa(ctx, r):
    rc, out = ctx.run("grep -m1 '^isa' /proc/cpuinfo")
    line = out.split(":", 1)[-1].strip()
    r.check(line.startswith("rv32"), "no isa line in /proc/cpuinfo: " + out[-200:])
    exts = isa_extensions(line)
    r.metric("isa", line)
    probes = {}
    for name in ("dsp_probe", "ext_probe"):
        rc, probes[name] = ctx.run(ctx.tool(name))
    got = []
    for ext, probe, rx, what in ISA_PROBES:
        m = re.search(rx, probes[probe])
        ok, total = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
        works = total > 0 and ok == total
        r.check(m is not None, "%s: no result line from %s" % (what, probe))
        r.check(works == (ext in exts), "%s: %s %s, but %d/%d instructions executed correctly"
                % (what, ext, "advertised" if ext in exts else "not advertised", ok, total))
        got.append("%s %s" % (ext, "yes" if works else "no"))
    # the A25 extensions only the firmware can see (OpenSBI reads mmsc_cfg)
    for ext in ("p", "xandesperf", "xandescodense"):
        r.check(ext in exts, "%s missing from the isa line (OpenSBI's andestech,a25 override, kernel #96+)" % ext)
    return "%s; %s" % (line, ", ".join(got))


@test("kernel", "ucsr", "Andes user CSRs (DSP ucode, CoDense uitb) kept per process")
def ucsr(ctx, r):
    rc, out = ctx.run("%s 4 5000" % ctx.tool("ucsr_test"))
    r.check(rc == 0 and "UCSRTEST PASSED" in out, "a process saw another's ucode / uitb: " + out[-300:])
    r.check("OV bit writable: yes" in out and "base: yes" in out, "the CSRs did not hold a written value: " + out[:200])
    return grep(r"UCSRTEST (\w+ \(.*\))", out, default=out[-100:])


@test("kernel", "rootfs_atomics", "rootfs binaries free of lr/sc/amo (host tree)")
def rootfs_atomics(ctx, r):
    objdump = os.path.expanduser("~/projects/riscv32-ilp32d--musl--stable-2025.08-1/bin/riscv32-buildroot-linux-musl-objdump")
    if not os.path.exists(objdump):
        raise Skip("no musl objdump at " + objdump)
    root = REPO / "linux" / "rootfs"
    elves = []
    for d in ("bin", "sbin", "usr/bin", "usr/sbin"):
        for p in sorted((root / d).glob("*")):
            if p.is_file() and not p.is_symlink() and p.read_bytes()[:4] == b"\x7fELF":
                elves.append(p)
    bad = 0
    for p in elves:
        dis = subprocess.run([objdump, "-d", str(p)], capture_output=True, text=True).stdout
        n = len(re.findall(r"\s(lr\.w|sc\.w|amo[a-z]+\.w)", dis))
        if n:
            bad += 1
            r.fail("%s: %d atomic instructions (the A25 has no coherent AMO/LR/SC on DDR)" % (p.relative_to(root), n))
    r.metric("binaries", len(elves))
    return "%d ELF binaries, %d with atomics" % (len(elves), bad)
