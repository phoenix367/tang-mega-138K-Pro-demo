"""net: link, ping, TCP both ways with an md5 check, error counters, scp round trip."""
import http.server, os, re, socketserver, subprocess, threading, time, urllib.request

from .core import Skip, grep, test
from .media import md5

COUNTERS = ["rx_errors", "rx_crc_errors", "rx_dropped", "rx_fifo_errors", "rx_frame_errors", "tx_errors"]


def host_ip(board_ip):
    """The host's address on the route to the board (what the board connects back to)."""
    out = subprocess.run(["ip", "route", "get", board_ip], capture_output=True, text=True).stdout
    m = re.search(r"\bsrc (\S+)", out)
    if not m:
        raise Skip("no route to the board from this host")
    return m.group(1)


def counters(ctx):
    rc, out = ctx.run("cd /sys/class/net/eth0/statistics && for f in %s; do echo $f $(cat $f); done" % " ".join(COUNTERS))
    return {k: int(v) for k, v in re.findall(r"^(\w+) (\d+)$", out, re.M)}


@test("net", "link", "eth0 link and address")
def link(ctx, r):
    rc, out = ctx.run("cat /sys/class/net/eth0/carrier /sys/class/net/eth0/operstate /sys/class/net/eth0/mtu; "
                      "cat /run/network.state")
    lines = out.split("\n")
    r.check(lines[0].strip() == "1", "no carrier")
    r.check(lines[1].strip() == "up", "eth0 is %s" % lines[1].strip())
    ip = grep(r"ip=(\S+)", out, default="?")
    r.metric("ip", ip)
    r.metric("mode", grep(r"net=(\S+)", out, default="?"))
    r.check(ip.split("/")[0] == ctx.board.host, "network.state says %s, the board answers at %s" % (ip, ctx.board.host))
    ctx.net0 = counters(ctx)
    return "carrier, up, MTU %s, %s (%s)" % (lines[2].strip(), ip, r.metrics["mode"])


@test("net", "ping", "ICMP round trip")
def ping(ctx, r):
    n = 20 if ctx.quick else 50
    out = subprocess.run(["ping", "-c", str(n), "-i", "0.2", "-q", ctx.board.host], capture_output=True, text=True).stdout
    ctx.log(out)
    loss = grep(r"([\d.]+)% packet loss", out, conv=float, default=100.0)
    rtt = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)", out)
    r.metric("loss_pct", loss)
    if rtt:
        r.metric("rtt_avg_ms", float(rtt.group(2)))
        r.metric("rtt_max_ms", float(rtt.group(3)))
    if loss >= 5:
        r.fail("%.0f%% loss" % loss)
    elif loss > 0:
        r.warn("%.1f%% loss" % loss)
    return "%d pings, %.1f%% loss, rtt avg %s ms max %s ms" % (n, loss, rtt.group(2) if rtt else "?", rtt.group(3) if rtt else "?")


class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


@test("net", "tcp_to_board", "TCP host -> board (wget), md5 checked", slow=True)
def tcp_to_board(ctx, r):
    hip = host_ip(ctx.board.host)
    mb = 8 if ctx.quick else 32
    big, big_md5 = ctx.media.blob(mb)
    small, small_md5 = ctx.media.blob(8)
    handler = lambda *a, **k: _Quiet(*a, directory=str(ctx.media.dir), **k)
    srv = socketserver.ThreadingTCPServer((hip, 0), handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    url = "http://%s:%d/" % (hip, srv.server_address[1])
    try:
        rc, out = ctx.run("t0=$(cut -d' ' -f1 /proc/uptime); wget -q -O /dev/null %s%s; echo RC $?; "
                          "t1=$(cut -d' ' -f1 /proc/uptime); echo T $t0 $t1; wget -q -O - %s%s | md5sum"
                          % (url, big.name, url, small.name), timeout=300)
    finally:
        srv.shutdown()
        srv.server_close()
    if not r.check("RC 0" in out, "wget failed: " + out.strip()[-160:]):
        return "wget failed (a host firewall in the way?)"
    t = re.search(r"T ([\d.]+) ([\d.]+)", out)
    secs = float(t.group(2)) - float(t.group(1)) if t else 0
    speed = mb / secs if secs > 0 else 0
    r.metric("mb_per_s", round(speed, 2))
    r.check(small_md5 in out, "8 MB download md5 differs")
    if speed < 3:
        r.warn("%.1f MB/s (the driver did ~8 MB/s, 65 Mbit/s, kernel #48)" % speed)
    return "%d MB in %.1f s = %.1f MB/s (%.0f Mbit/s), md5 ok" % (mb, secs, speed, speed * 8.39)


@test("net", "tcp_from_board", "TCP board -> host (busybox httpd), md5 checked", slow=True)
def tcp_from_board(ctx, r):
    mb = 8 if ctx.quick else 32
    rc, out = ctx.root("mkdir -p /tmp/bt/www\ndd if=/dev/urandom of=/tmp/bt/www/blob bs=1M count=%d 2>/dev/null\n"
                       "md5sum /tmp/bt/www/blob\nsetsid httpd -f -p 8081 -h /tmp/bt/www </dev/null >/dev/null 2>&1 &\n"
                       "echo PID $!\nsleep 1\n" % mb, timeout=120)
    want = grep(r"^([0-9a-f]{32})\s", out)
    pid = grep(r"PID (\d+)", out)
    if not want or not pid:
        r.fail("could not start httpd on the board: " + out.strip()[-160:])
        return "no httpd"
    local = ctx.out / "logs" / "blob_from_board.bin"
    try:
        t0 = time.time()
        urllib.request.urlretrieve("http://%s:8081/blob" % ctx.board.host, local)
        secs = time.time() - t0
    finally:
        ctx.root("kill %s\nrm -rf /tmp/bt/www\n" % pid)
    got = md5(local)
    os.unlink(local)
    speed = mb / secs
    r.metric("mb_per_s", round(speed, 2))
    r.check(got == want, "md5 differs: board %s, received %s" % (want, got))
    if speed < 2.5:
        r.warn("%.1f MB/s (the driver did ~5 MB/s, 40 Mbit/s, kernel #48)" % speed)
    return "%d MB in %.1f s = %.1f MB/s (%.0f Mbit/s), md5 ok" % (mb, secs, speed, speed * 8.39)


@test("net", "errors", "eth0 error counters during the transfers")
def errors(ctx, r):
    if not hasattr(ctx, "net0"):
        raise Skip("needs net.link first")
    now = counters(ctx)
    delta = {k: now.get(k, 0) - ctx.net0.get(k, 0) for k in COUNTERS}
    for k, v in delta.items():
        r.metric(k, v)
        if v:
            r.warn("%s +%d (residual RX CRC errors ~2e-6 per frame are known)" % (k, v))
    return ", ".join("%s +%d" % (k, v) for k, v in delta.items() if v) or "no errors"


@test("net", "scp", "scp round trip, md5 checked")
def scp(ctx, r):
    p, want = ctx.media.blob(4)
    t0 = time.time()
    ctx.board.put(str(p), "/tmp/bt/scp.bin")
    up = time.time() - t0
    back = ctx.out / "logs" / "scp_back.bin"
    t0 = time.time()
    ctx.board.get("/tmp/bt/scp.bin", str(back))
    down = time.time() - t0
    ctx.run("rm -f /tmp/bt/scp.bin")
    got = md5(back)
    os.unlink(back)
    r.check(got == want, "the file came back different")
    r.metric("up_mb_per_s", round(4 / up, 2))
    r.metric("down_mb_per_s", round(4 / down, 2))
    return "4 MB up %.1f MB/s, down %.1f MB/s (dropbear's cipher on the A25), md5 ok" % (4 / up, 4 / down)
