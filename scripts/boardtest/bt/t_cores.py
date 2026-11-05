"""cores: the gateware cores, checked bit-exactly where they can be (CRC / model / FFmpeg)
and measured where they cannot (frame timing, sensors, throughput).  The checks that
draw on the panel run with the desktop stopped; it is started again by the ui group
(or at the end of the run)."""
import re

from .core import Skip, grep, test

# ADC rails (hwmon gowin_adc, labels in src/rtl/sensor/README.md): nominal volts
RAILS = {"in0": 0.9, "in1": 1.0, "in2": 0.9, "in4": 1.8, "in5": 1.8, "in7": 1.5}


def _clip(ctx, w, h, fps=25, secs=10):
    p = ctx.media.clip(w, h, fps, secs)
    remote = "/tmp/bt/" + p.name
    if ctx.run("[ -s %s ]" % remote)[0]:
        ctx.board.put(str(p), remote)
    return remote


@test("cores", "lcd", "LCD core: framebuffer CRC = panel CRC")
def lcd(ctx, r):
    fb = ctx.tool("fbtest")
    ctx.desktop(False)
    rc, out = ctx.root("for m in bars grad noise write; do %s $m || echo FAILED $m; done\n" % fb, timeout=120)
    lines = re.findall(r"^FBTEST .*$", out, re.M)
    for l in lines:
        r.check("-> MATCH" in l, l)
        und = grep(r"underruns (\d+)", l, conv=int, default=0)
        if und:
            r.warn("%s: %d underrun lines" % (l.split()[1], und))
    r.check(len(lines) == 4 and "FAILED" not in out, "fbtest did not run all four patterns")
    return "%d of 4 patterns bit-exact on the panel" % sum("-> MATCH" in l for l in lines)


@test("cores", "yuv", "LCD core: YUV 4:2:0 scan-out (both ranges)")
def yuv(ctx, r):
    t = ctx.tool("yuvtest")
    ctx.desktop(False)
    rc, out = ctx.root("%s; echo RC $?; %s -l; echo RC $?\n" % (t, t), timeout=120)
    lines = re.findall(r"^YUVTEST .*$", out, re.M)
    for l in lines:
        r.check(re.search(r"-> (MATCH|OK|PASS)", l), l)
    r.check(out.count("RC 0") == 2, "yuvtest exit status: %s" % re.findall(r"RC \d+", out))
    return "full and limited range: %s" % ", ".join(grep(r"-> (\w+)", l, default="?") for l in lines)


@test("cores", "scaler", "LCD core: scaler + OSD scenes")
def scaler(ctx, r):
    t = ctx.tool("scaletest")
    ctx.desktop(False)
    rc, out = ctx.root("%s; echo RC $?\n" % t, timeout=180)
    r.check("SCALETEST PASSED" in out and "RC 0" in out, grep(r"^(SCALETEST .*)$", out, default="scaletest did not finish"))
    return grep(r"^(SCALETEST .*)$", out, default="?")


@test("cores", "idct", "JPEG core: IDCT against FFmpeg's integer IDCT")
def idct(ctx, r):
    t = ctx.tool("idcttest")
    ctx.desktop(False)
    rc, out = ctx.root("%s -n %d; echo RC $?\n" % (t, 1 if ctx.quick else 3), timeout=240)
    r.check("IDCTTEST PASSED" in out and "RC 0" in out, grep(r"^(IDCTTEST .*)$", out, default="idcttest did not finish"))
    rate = grep(r"([\d.]+ ?(?:Mblocks|blocks|ms)[^\n]*)", out)
    if rate:
        r.metric("throughput", rate.strip())
    return grep(r"^(IDCTTEST .*)$", out, default="?")


@test("cores", "jpeg", "JPEG core: whole frames bit-exact with FFmpeg (vidplay -C)")
def jpeg(ctx, r):
    n = 30 if ctx.quick else 100
    res = []
    for w, h in ((852, 480), (1280, 720)):
        clip = _clip(ctx, w, h)
        rc, out = ctx.root("vidplay -n -C %d %s 2>&1 | grep -a 'JPEGCHECK\\|check:'; echo RC $?\n" % (n, clip), timeout=300)
        line = grep(r"^(JPEGCHECK .*)$", out)
        if not r.check(line and " 0 differ" in line, "%dx%d: %s" % (w, h, line or out.strip()[-160:])):
            continue
        hw = grep(r"gateware ([\d.]+) ms", line, conv=float)
        sw = grep(r"CPU ([\d.]+) ms", line, conv=float)
        r.metric("%dx%d_gateware_ms" % (w, h), hw)
        r.metric("%dx%d_cpu_ms" % (w, h), sw)
        res.append("%dx%d %s ms (CPU %s)" % (w, h, hw, sw))
    return "%d frames each, bit-exact: %s" % (n, "; ".join(res))


@test("cores", "audio", "audio core: frames + CRC of what reached the DAC")
def audio(ctx, r):
    wavs = ctx.media.wavs()
    names = ["lr440_880_48k_2s.wav", "sine1k_44k1_3s.wav"] if ctx.quick else sorted(wavs)
    script = ""
    for n in names:
        p = wavs[n][0]
        ctx.board.put(str(p), "/tmp/bt/" + n)
        script += "wavplay /tmp/bt/%s 2>&1 | tail -1\n" % n
    rc, out = ctx.root(script + "rm -f /tmp/bt/*.wav\n", timeout=300)
    ok = 0
    for n in names:
        _, rate, frames, crc = wavs[n]
        line = grep(r"^(.*%s.*)$" % re.escape(n), out, default="")
        good = "MATCH" in line and "MISMATCH" not in line and crc.lower() in line.lower()
        if r.check(good, "%s: %s (expected %d frames, CRC %s)" % (n, line.strip() or "no result", frames, crc)):
            ok += 1
        xr = grep(r"(\d+) xruns", line, conv=int, default=0)
        if xr:
            r.warn("%s: %d xruns" % (n, xr))
    return "%d of %d files bit-exact (frames + CRC)" % (ok, len(names))


def _play(ctx, r, path, fps, secs_max, label):
    """vidplay -v with lcdmon watching the panel (the vtest approach); returns a summary."""
    lm = ctx.tool("lcdmon")
    rc, out = ctx.root("""%s -t %d -f %s -w 30 > /tmp/bt/lcdmon.out 2>&1 &
m=$!
s0=$(head -1 /proc/stat)
timeout -s INT %d vidplay -v %s 2> /tmp/bt/vidplay.out
s1=$(head -1 /proc/stat)
wait $m
echo "$s0" "$s1" | awk '{b=0; for (k=2;k<=8;k++) b+=$(k+11)-$k; i=$(16)-$5; printf "CPU %%.0f\\n", 100*(b-i)/b}'
grep -a 'VIDPLAY\\|skipped\\|decoded by\\|scaled by' /tmp/bt/vidplay.out
cat /tmp/bt/lcdmon.out
""" % (lm, secs_max + 30, fps, secs_max, path), timeout=secs_max + 120)
    decoded = grep(r"VIDPLAY .*?: (\d+) frames decoded", out, conv=int, default=0)
    shown = grep(r"shown (\d+)", out, conv=int, default=0)
    skipped = grep(r"(\d+) packets skipped", out, conv=int, default=0)
    xruns = grep(r"(\d+) xruns", out, conv=int, default=0)
    pictures = grep(r"(\d+) pictures", out, conv=int, default=0)
    longest = grep(r"longest hold (\d+) refreshes \((\d+) ms\)", out, 2, int, 0)
    late = grep(r"holds longer than \d+ refreshes[^:]*: (\d+)", out, conv=int, default=0)
    under = grep(r"underrun lines \+(\d+)", out, conv=int, default=0)
    cpu = grep(r"^CPU (\d+)", out, conv=int)
    hw = "gateware" in out
    for k, v in (("decoded", decoded), ("pictures", pictures), ("skipped", skipped), ("late_holds", late),
                 ("longest_hold_ms", longest), ("underrun_lines", under), ("xruns", xruns), ("cpu_pct", cpu)):
        r.metric("%s_%s" % (label, k), v)
    if not r.check(decoded > 0 and pictures > 0, "%s: nothing played (%s)" % (label, out.strip()[-160:])):
        return "%s: nothing played" % label
    r.check(hw, "%s: not decoded by the gateware" % label)
    r.check(skipped == 0, "%s: %d packets skipped to keep up" % (label, skipped))
    r.check(late == 0, "%s: %d pictures held a refresh or more too long (longest %d ms)" % (label, late, longest))
    r.check(under == 0, "%s: %d LCD underrun lines" % (label, under))
    r.check(xruns == 0, "%s: %d audio xruns" % (label, xruns))
    if shown - pictures > 2:
        r.warn("%s: %d frames flipped but never on the panel" % (label, shown - pictures))
    return "%s %d/%d frames on the panel, longest hold %d ms, CPU %s%%" % (label, pictures, decoded, longest, cpu)


@test("cores", "video", "video playback timing on the panel (vidplay + lcdmon)", slow=True)
def video(ctx, r):
    ctx.desktop(False)
    out = []
    for w, h in ((852, 480), (1280, 720)):
        out.append(_play(ctx, r, _clip(ctx, w, h, 25, 10), 25, 15, "%dx%d" % (w, h)))
    return "; ".join(out)


@test("cores", "sd_clips", "the SD card's MJPEG clips, 40 s each with lcdmon", optional=True)
def sd_clips(ctx, r):
    rc, out = ctx.run("ls /mnt/sd/video/ 2>/dev/null")
    names = [n for n in out.split("\n") if re.search(r"\.(mp4|avi|mkv)$", n, re.I)]
    if not names:
        raise Skip("no clips in /mnt/sd/video")
    ctx.desktop(False)
    res = []
    for n in names:
        rc, info = ctx.root("vidplay -n -C 1 '/mnt/sd/video/%s' 2>&1 | grep -a 'JPEGCHECK\\|not for\\|fps'\n" % n.replace("'", "'\\''"))
        if "JPEGCHECK" not in info:
            r.warn("%s: not an MJPEG stream for the gateware, skipped" % n)
            continue
        fps = grep(r"([\d.]+) fps", info, conv=float, default=25.0)
        res.append(_play(ctx, r, "'/mnt/sd/video/%s'" % n.replace("'", "'\\''"), fps, 40, re.sub(r"\W+", "_", n)[:40]))
    return "%d clips: %s" % (len(res), "; ".join(res))


@test("cores", "sensors", "ADC: die temperature and supply rails")
def sensors(ctx, r):
    rc, out = ctx.run("cd /sys/class/hwmon && for h in hwmon*; do [ \"$(cat $h/name)\" = gowin_adc ] && "
                      "for f in $h/temp1_input $h/in*_input $h/*_fault; do echo $(basename $f) $(cat $f); done; done")
    v = dict(re.findall(r"^(\w+) (-?\d+)$", out, re.M))
    if "temp1_input" not in v:
        r.fail("no gowin_adc hwmon")
        return "no ADC"
    t = int(v["temp1_input"]) / 1000
    r.metric("temp_c", t)
    r.check(10 <= t <= 85, "die temperature %.1f C" % t)
    for k, nominal in RAILS.items():
        mv = int(v.get(k + "_input", 0))
        r.metric(k + "_mv", mv)
        r.check(abs(mv / 1000 - nominal) <= 0.1 * nominal, "%s %d mV, nominal %.2f V +-10%%" % (k, mv, nominal))
    for k in list(RAILS) + ["temp1"]:
        r.check(v.get(k + "_fault", "0") == "0", "%s_fault is set" % k)
    return "die %.1f C, rails %s" % (t, " ".join("%.2f" % (int(v.get(k + "_input", 0)) / 1000) for k in RAILS))


@test("cores", "fan", "fan: tacho")
def fan(ctx, r):
    rc, out = ctx.run("cd /sys/class/hwmon && for h in hwmon*; do [ \"$(cat $h/name)\" = gowin_fan ] && "
                      "echo $(cat $h/fan1_input) $(cat $h/pwm1) $(cat $h/fan1_fault 2>/dev/null); done")
    f = out.split()
    if not f:
        r.fail("no gowin_fan hwmon")
        return "no fan"
    rpm, pwm = int(f[0]), int(f[1])
    r.metric("rpm", rpm)
    r.metric("pwm", pwm)
    if rpm == 0:
        r.warn("no tacho pulses: fan stopped or not connected")
    return "%d rpm at PWM %d" % (rpm, pwm)


@test("cores", "sd", "SD host: card, read and write speed, md5 round trip", slow=True)
def sd(ctx, r):
    rc, out = ctx.run("grep -c ' /mnt/sd ' /proc/mounts; d=/sys/block/mmcblk0/device; "
                      "echo $(cat $d/name) $(cat $d/manfid) $(cat $d/date) $(cat $d/ssr | cut -c17-18); cat /sys/block/mmcblk0/size")
    lines = out.split("\n")
    if not lines[0].strip().isdigit() or int(lines[0]) == 0:
        raise Skip("no microSD card mounted at /mnt/sd")
    ident = lines[1].split()
    cls = {"00": "0", "01": "2", "02": "4", "03": "6", "04": "10"}.get(ident[-1] if ident else "", "?")
    r.metric("card", " ".join(ident[:3]))
    r.metric("speed_class", cls)
    mb = 8 if ctx.quick else 32
    rc, out = ctx.root("""up() { cut -d' ' -f1 /proc/uptime; }
sync; echo 3 > /proc/sys/vm/drop_caches
t0=$(up); dd if=/dev/mmcblk0 of=/dev/null bs=1M count=%d 2>/dev/null; t1=$(up); echo READ $t0 $t1
dd if=/dev/urandom of=/tmp/bt/sd.bin bs=1M count=%d 2>/dev/null; md5sum /tmp/bt/sd.bin
t0=$(up); cp /tmp/bt/sd.bin /mnt/sd/bt_sd.bin; sync; t1=$(up); echo WRITE $t0 $t1
echo 3 > /proc/sys/vm/drop_caches; md5sum /mnt/sd/bt_sd.bin
rm -f /mnt/sd/bt_sd.bin /tmp/bt/sd.bin; sync
""" % (mb, mb), timeout=900)
    sums = re.findall(r"^([0-9a-f]{32})\s", out, re.M)
    rd = re.search(r"READ ([\d.]+) ([\d.]+)", out)
    wr = re.search(r"WRITE ([\d.]+) ([\d.]+)", out)
    rs = mb / max(0.01, float(rd.group(2)) - float(rd.group(1))) if rd else 0
    ws = mb / max(0.01, float(wr.group(2)) - float(wr.group(1))) if wr else 0
    r.metric("read_mb_per_s", round(rs, 2))
    r.metric("write_mb_per_s", round(ws, 2))
    r.check(len(sums) == 2 and sums[0] == sums[1], "the file read back from the card differs")
    if rs < 4:
        r.warn("read %.1f MB/s (the host reads ~6 MB/s at 25 MHz)" % rs)
    if ws < 1:
        r.warn("write %.2f MB/s: a slow card (see src/rtl/sdhost/README.md, 'Slow cards')" % ws)
    return "%s class %s: read %.1f MB/s, write %.1f MB/s, %d MB md5 ok" % (" ".join(ident[:1]), cls, rs, ws, mb)


DDRP = "/sys/bus/platform/devices/f8000000.ddr-perf"


def _ddrp_stats(text):
    """the driver's counters file ('name value' lines, one sample) -> {counter: value}"""
    return {m.group(1): int(m.group(2)) for m in re.finditer(r"^([a-z]\w+) (\d+)$", text, re.M)}


@test("cores", "ddr_perf", "DDR bus counters (gowin-ddr-perf sysfs) against a known workload")
def ddr_perf(ctx, r):
    if ctx.run("[ -f %s/counters ]" % DDRP)[0]:
        raise Skip("no %s (kernel #97+)" % DDRP)
    mb = 16
    rc, out = ctx.run("S=%s; cat $S/clock_hz $S/config $S/mode $S/interval_ms; echo @@0; cut -d' ' -f1 /proc/uptime; "
                      "cat $S/counters; dd if=/dev/zero of=/tmp/bt/ddrp bs=1M count=%d 2>/dev/null; "
                      "md5sum /tmp/bt/ddrp >/dev/null; echo @@1; cut -d' ' -f1 /proc/uptime; cat $S/counters; "
                      "rm -f /tmp/bt/ddrp" % (DDRP, mb), timeout=120)
    head, a, b = out.split("@@0")[0].split(), out.split("@@0")[1].split("@@1")[0], out.split("@@1")[1]
    hz, config, mode, interval = int(head[0]), head[1], head[2], int(head[3])
    t0, t1 = float(a.split()[0]), float(b.split()[0])
    c0, c1 = _ddrp_stats(a), _ddrp_stats(b)
    r.check(len(c0) == 44 and len(c1) == 44, "%d / %d counters, expected 44" % (len(c0), len(c1)))
    if len(c0) != 44 or len(c1) != 44:
        return "counters missing"
    # one sample: the transfers by burst type and by size add up to the transfer counts
    for rw in ("rd", "wr"):
        n = c1[rw + "_bursts"]
        by_burst = sum(c1["%s_%s" % (rw, b)] for b in ("single", "incr", "wrap4", "incr4", "wrap8", "incr8", "wrap16", "incr16"))
        by_size = sum(c1["%s_size%d" % (rw, z)] for z in (8, 16, 32, 64))
        r.check(n == by_burst == by_size, "%s_bursts %d, by burst type %d, by size %d: not one sample"
                % (rw, n, by_burst, by_size))
    # the statistics/ files hold the same totals
    rc, one = ctx.run("cat %s/statistics/cycles" % DDRP)
    r.check(one.strip().isdigit() and int(one) >= c1["cycles"], "statistics/cycles: %r" % one.strip()[:40])
    d = {k: c1[k] - c0[k] for k in c1}
    back = [k for k in d if d[k] < 0 and not k.endswith("_max")]
    r.check(not back, "totals went backwards: %s" % ", ".join(back))
    # the cycle counter against wall time, over the workload and since boot (lost wraps)
    rate = d["cycles"] / max(t1 - t0, 0.01)
    r.metric("cycles_per_s", int(rate))
    r.check(abs(rate / hz - 1) < 0.05, "cycles count %.1f MHz, clock_hz says %.1f" % (rate / 1e6, hz / 1e6))
    if t1 > 60:
        boot = c1["cycles"] / hz
        r.check(t1 - 20 < boot <= t1 + 1, "%.0f s of cycles since boot, uptime %.0f s (a lost 43 s wrap?)" % (boot, t1))
    rd, wr = d["rd_beats"] * 8, d["wr_beats"] * 8
    r.metric("rd_mb", round(rd / 2**20, 1))
    r.metric("wr_mb", round(wr / 2**20, 1))
    r.check(wr >= (mb - 1) * 2**20, "%d MB written to tmpfs, the bus wrote only %.1f MB" % (mb, wr / 2**20))
    r.check(rd >= (mb - 1) * 2**20, "%d MB read back by md5sum, the bus read only %.1f MB" % (mb, rd / 2**20))
    r.check(d["mc_rd_cmds"] > 0 and d["br_demand"] > 0, "the bridge counters did not move: %s"
            % {k: d[k] for k in ("mc_rd_cmds", "br_demand", "br_prefetch", "mc_wr_cmds")})
    r.check(c1["rd_wait_max"] > 0, "rd_wait_max is 0")
    r.metric("read_wait_per_beat", round(d["rd_wait"] / max(d["rd_beats"], 1), 2))
    if mode != "0x00010000":
        r.warn("bridge MODE %s, the default is 0x00010000 (src/rtl/ddr_bridge/README.md)" % mode)
    r.check(interval == 1000, "interval_ms %d, default 1000" % interval)
    # the transfer trace: armed around a file read (far more than 1024 line fills), DDR addresses
    rc, tout = ctx.root("S=%s\necho 1 > $S/trace_arm\nmd5sum /usr/bin/vidplay >/dev/null\necho 0 > $S/trace_arm\n"
                        "cat $S/trace_count\nod -An -v -tx4 -N 128 $S/trace\n" % DDRP)
    words = [int(w, 16) for w in re.findall(r"\b[0-9a-f]{8}\b", tout)]
    n = grep(r"^(\d+)\s*$", tout, conv=int, default=0)
    addrs = words[0::2]
    r.check(n == 1024, "trace_count %d after reading a file armed, expected 1024 (full)" % n)
    r.check(len(addrs) == 16 and all(x < 0x40000000 for x in addrs) and any(addrs),
            "trace entries are not DDR addresses: %s" % " ".join("%08x" % x for x in addrs))
    return "%.1f MHz bus clock; %d MB through tmpfs: bus read %.1f MB, wrote %.1f MB, %.2f wait/read beat; trace %d entries" % (
        rate / 1e6, mb, rd / 2**20, wr / 2**20, r.metrics["read_wait_per_beat"], n)


@test("cores", "ddr", "DDR3 bridge: memory patterns, latency, bandwidth", slow=True)
def ddr(ctx, r):
    t = ctx.tool("ddr_memtest")
    mb = 16 if ctx.quick else 64
    rc, out = ctx.run("%s %d 1; echo RC $?" % (t, mb), timeout=600)
    r.check("RC 0" in out, "ddr_memtest: %s" % (re.findall(r"MISMATCH.*", out)[:3] or out.strip()[-160:]))
    for k, pat in (("seq_read", r"seq read\s+([\d.]+) MB/s"), ("memcpy", r"memcpy\s+([\d.]+) MB/s"),
                   ("memset", r"memset\s+([\d.]+) MB/s")):
        v = grep(pat, out, conv=float)
        if v is not None:
            r.metric(k + "_mb_per_s", v)
    lat = grep(r"([\d.]+) ns", out, conv=float)
    if lat:
        r.metric("miss_latency_ns", lat)
    return "%d MB, %s; seq read %s MB/s, memcpy %s MB/s" % (
        mb, "no mismatches" if "RC 0" in out else "MISMATCHES", r.metrics.get("seq_read_mb_per_s"), r.metrics.get("memcpy_mb_per_s"))
