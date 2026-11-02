/*
 * boardcfg -- board settings kept in the Dock's 1 KB EEPROM (nvmem) so they
 * survive a reboot of the initramfs rootfs.
 *
 *   boardcfg                     show the settings file
 *   boardcfg get KEY             print one value
 *   boardcfg set KEY VALUE       change a value (the daemon writes it to the
 *                                EEPROM and applies it; without the daemon,
 *                                set does both itself)
 *   boardcfg unset KEY
 *   boardcfs show -e             decode what is in the EEPROM
 *   boardcfg load                EEPROM -> /etc/board.conf, apply  (boot)
 *   boardcfg sync                /etc/board.conf -> EEPROM, apply
 *   boardcfg erase               invalidate the EEPROM block
 *   boardcfg -d                  load, then stay as a daemon watching
 *                                /etc/board.conf (inotify) and SIGHUP
 *
 * Keys the daemon applies: mac (eth0, also read by the kernel at boot through
 * the nvmem cell in the device tree), hostname, tz (zone name under
 * /usr/share/zoneinfo -> /etc/localtime + /etc/timezone).  Any other key is
 * stored and restored verbatim (serial, ...).
 *
 * EEPROM layout (offsets in the 1 KB part; 0x000..0x0FF is left to the
 * vendor, byte 0 reads 0x89 from the factory):
 *   0x100  header  "AE35", version 1, flags, text length (LE16),
 *                  CRC-32 (LE32) over the fixed block + text, 4 reserved
 *   0x110  fixed   MAC address (6 bytes; DT nvmem cell mac-address@110),
 *                  10 reserved
 *   0x120  text    "key=value\n" lines, up to 736 bytes
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <ctype.h>
#include <poll.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/inotify.h>
#include <net/if.h>
#include <net/if_arp.h>

/* paths can be overridden with -D for a host-side test against a 1 KB file */
#ifndef NVMEM
#define NVMEM    "/sys/bus/nvmem/devices/board-eeprom0/nvmem"
#endif
#ifndef CONF
#define CONF     "/etc/board.conf"
#define CONF_DIR "/etc"
#endif
#ifndef PIDFILE
#define PIDFILE  "/run/boardcfg.pid"
#endif
#ifndef ZONEINFO
#define ZONEINFO "/usr/share/zoneinfo"
#endif
#define IFNAME   "eth0"

#define BASE      0x100
#define END       0x400
#define REGION    (END - BASE)          /* 768 */
#define HDR_LEN   16
#define FIXED_LEN 16
#define TEXT_OFF  (HDR_LEN + FIXED_LEN) /* 0x20 within the region */
#define TEXT_MAX  (REGION - TEXT_OFF)   /* 736 */
#define MAGIC     "AE35"
#define VERSION   1

#define MAX_KV   64
#define KEY_MAX  31
#define VAL_MAX  127

typedef struct { char key[KEY_MAX + 1]; char val[VAL_MAX + 1]; } kv_t;
typedef struct { kv_t kv[MAX_KV]; int n; } cfg_t;

static int g_daemon;
static volatile sig_atomic_t g_hup, g_term;

static void logmsg(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (g_daemon) {
        int fd = open("/dev/kmsg", O_WRONLY);
        if (fd >= 0) { dprintf(fd, "boardcfg: %s\n", buf); close(fd); }
    } else {
        fprintf(stderr, "boardcfg: %s\n", buf);
    }
}

static uint32_t crc32_calc(const uint8_t *p, size_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    while (n--) {
        c ^= *p++;
        for (int i = 0; i < 8; i++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
    }
    return ~c;
}

/* ---- key/value set ------------------------------------------------------ */

static const char *cfg_get(const cfg_t *c, const char *key)
{
    for (int i = 0; i < c->n; i++)
        if (!strcmp(c->kv[i].key, key)) return c->kv[i].val;
    return NULL;
}

static int cfg_set(cfg_t *c, const char *key, const char *val)
{
    if (!*key || strlen(key) > KEY_MAX || strlen(val) > VAL_MAX) return -1;
    for (const char *p = key; *p; p++)
        if (!isalnum((unsigned char)*p) && *p != '_' && *p != '-' && *p != '.') return -1;
    if (strchr(val, '\n')) return -1;
    for (int i = 0; i < c->n; i++)
        if (!strcmp(c->kv[i].key, key)) { strcpy(c->kv[i].val, val); return 0; }
    if (c->n == MAX_KV) return -1;
    strcpy(c->kv[c->n].key, key);
    strcpy(c->kv[c->n].val, val);
    c->n++;
    return 0;
}

static void cfg_unset(cfg_t *c, const char *key)
{
    for (int i = 0; i < c->n; i++)
        if (!strcmp(c->kv[i].key, key)) { c->kv[i] = c->kv[--c->n]; return; }
}

/* parse "key=value" lines from a buffer; '#' comments and blanks ignored */
static void cfg_parse(cfg_t *c, char *text)
{
    char *save = NULL;
    for (char *line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        while (isspace((unsigned char)*line)) line++;
        if (!*line || *line == '#') continue;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = line, *v = eq + 1;
        char *e = k + strlen(k);
        while (e > k && isspace((unsigned char)e[-1])) *--e = 0;
        e = v + strlen(v);
        while (e > v && isspace((unsigned char)e[-1])) *--e = 0;
        cfg_set(c, k, v);
    }
}

static int cfg_text(const cfg_t *c, char *out, size_t cap, int with_mac)
{
    size_t len = 0;
    for (int i = 0; i < c->n; i++) {
        if (!with_mac && !strcmp(c->kv[i].key, "mac")) continue;
        int n = snprintf(out + len, cap - len, "%s=%s\n", c->kv[i].key, c->kv[i].val);
        if (n < 0 || len + n >= cap) return -1;
        len += n;
    }
    return (int)len;
}

static int cmp_kv(const void *a, const void *b)
{
    const kv_t *x = a, *y = b;
    int xm = !strcmp(x->key, "mac"), ym = !strcmp(y->key, "mac");
    if (xm != ym) return ym - xm;           /* mac first */
    return strcmp(x->key, y->key);
}

/* ---- validation --------------------------------------------------------- */

static int parse_mac(const char *s, uint8_t mac[6])
{
    unsigned v[6];
    char tail;
    if (sscanf(s, "%x:%x:%x:%x:%x:%x%c", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &tail) != 6) return -1;
    int zero = 1;
    for (int i = 0; i < 6; i++) { if (v[i] > 255) return -1; mac[i] = v[i]; if (v[i]) zero = 0; }
    if (zero || (mac[0] & 1)) return -1;    /* all-zero or multicast */
    return 0;
}

static int validate(const char *key, const char *val)
{
    if (!strcmp(key, "mac")) {
        uint8_t m[6];
        if (parse_mac(val, m)) { logmsg("mac must be a unicast xx:xx:xx:xx:xx:xx"); return -1; }
    } else if (!strcmp(key, "hostname")) {
        if (!*val || strlen(val) > 63) { logmsg("hostname: 1..63 characters"); return -1; }
        for (const char *p = val; *p; p++)
            if (!isalnum((unsigned char)*p) && *p != '-') { logmsg("hostname: letters, digits and '-' only"); return -1; }
    } else if (!strcmp(key, "tz")) {
        char path[300];
        struct stat st;
        if (strstr(val, "..") || *val == '/') return -1;
        snprintf(path, sizeof(path), ZONEINFO "/%s", val);
        if (stat(path, &st) || !S_ISREG(st.st_mode)) { logmsg("tz: no such zone under " ZONEINFO); return -1; }
    }
    return 0;
}

/* ---- the settings file -------------------------------------------------- */

static int read_file(const char *path, char *buf, size_t cap)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, cap - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = 0;
    return (int)n;
}

static int conf_read(cfg_t *c)
{
    char buf[4096];
    memset(c, 0, sizeof(*c));
    if (read_file(CONF, buf, sizeof(buf)) < 0) return -1;
    cfg_parse(c, buf);
    return 0;
}

static int conf_write(cfg_t *c)
{
    qsort(c->kv, c->n, sizeof(kv_t), cmp_kv);
    char text[4096];
    if (cfg_text(c, text, sizeof(text), 1) < 0) return -1;
    char tmp[] = CONF ".tmp";
    FILE *f = fopen(tmp, "w");
    if (!f) return -1;
    fputs("# /etc/board.conf -- board settings kept in the Dock's EEPROM by boardcfg(8).\n"
          "# Change with `boardcfg set KEY VALUE`; this file is rewritten from the\n"
          "# EEPROM at boot.  Applied keys: mac (eth0), hostname, tz.\n", f);
    fputs(text, f);
    if (fclose(f)) { unlink(tmp); return -1; }
    chmod(tmp, 0644);
    return rename(tmp, CONF);
}

/* ---- the EEPROM --------------------------------------------------------- */

static int eeprom_read(uint8_t *img)
{
    int fd = open(NVMEM, O_RDONLY);
    if (fd < 0) { logmsg("cannot open %s: %s", NVMEM, strerror(errno)); return -1; }
    ssize_t n = pread(fd, img, REGION, BASE);
    close(fd);
    if (n != REGION) { logmsg("short read from %s", NVMEM); return -1; }
    return 0;
}

static int eeprom_write(const uint8_t *img, size_t len)
{
    int fd = open(NVMEM, O_WRONLY);
    if (fd < 0) { logmsg("cannot open %s for writing: %s", NVMEM, strerror(errno)); return -1; }
    size_t done = 0;
    while (done < len) {
        ssize_t n = pwrite(fd, img + done, len - done, BASE + done);
        if (n <= 0) { logmsg("write to %s failed: %s", NVMEM, strerror(errno)); close(fd); return -1; }
        done += n;
    }
    close(fd);
    return 0;
}

/* decode a region image; returns 0 and fills cfg (mac as a key) when valid */
static int image_decode(const uint8_t *img, cfg_t *c)
{
    memset(c, 0, sizeof(*c));
    if (memcmp(img, MAGIC, 4) || img[4] != VERSION) return -1;
    unsigned len = img[6] | (img[7] << 8);
    if (len > TEXT_MAX) return -1;
    uint32_t crc = img[8] | (img[9] << 8) | (img[10] << 16) | ((uint32_t)img[11] << 24);
    if (crc32_calc(img + HDR_LEN, FIXED_LEN + len) != crc) return -1;
    const uint8_t *mac = img + HDR_LEN;
    char text[TEXT_MAX + 1];
    memcpy(text, img + TEXT_OFF, len);
    text[len] = 0;
    cfg_parse(c, text);
    int zero = 1, ff = 1;
    for (int i = 0; i < 6; i++) { if (mac[i]) zero = 0; if (mac[i] != 0xFF) ff = 0; }
    if (!zero && !ff) {
        char s[18];
        snprintf(s, sizeof(s), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
        cfg_set(c, "mac", s);
    }
    return 0;
}

/* build the region image from cfg; returns the number of meaningful bytes */
static int image_encode(const cfg_t *c, uint8_t *img)
{
    memset(img, 0, REGION);
    memcpy(img, MAGIC, 4);
    img[4] = VERSION;
    char text[TEXT_MAX + 1];
    int len = cfg_text(c, text, sizeof(text), 0);
    if (len < 0) { logmsg("settings do not fit in the EEPROM (%d bytes max)", TEXT_MAX); return -1; }
    const char *m = cfg_get(c, "mac");
    if (m && parse_mac(m, img + HDR_LEN)) return -1;
    memcpy(img + TEXT_OFF, text, len);
    img[6] = len & 0xFF;
    img[7] = len >> 8;
    uint32_t crc = crc32_calc(img + HDR_LEN, FIXED_LEN + len);
    img[8] = crc; img[9] = crc >> 8; img[10] = crc >> 16; img[11] = crc >> 24;
    return TEXT_OFF + len;
}

/* write cfg to the EEPROM if it differs from what is there */
static int eeprom_store(const cfg_t *c)
{
    uint8_t cur[REGION], img[REGION];
    int n = image_encode(c, img);
    if (n < 0) return -1;
    if (eeprom_read(cur)) return -1;
    if (!memcmp(cur, img, n)) return 0;
    if (eeprom_write(img, n)) return -1;
    if (eeprom_read(cur) || memcmp(cur, img, n)) { logmsg("EEPROM verify failed"); return -1; }
    logmsg("EEPROM updated (%d bytes)", n);
    return 0;
}

/* ---- applying settings -------------------------------------------------- */

static int apply_mac(const char *s)
{
    uint8_t mac[6];
    if (parse_mac(s, mac)) return -1;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, IFNAME, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFHWADDR, &ifr)) { close(fd); return -1; }   /* no eth0 (yet) */
    if (!memcmp(ifr.ifr_hwaddr.sa_data, mac, 6)) { close(fd); return 0; }
    struct ifreq fl = ifr;
    if (ioctl(fd, SIOCGIFFLAGS, &fl)) { close(fd); return -1; }
    int was_up = fl.ifr_flags & IFF_UP;
    if (was_up) { fl.ifr_flags &= ~IFF_UP; ioctl(fd, SIOCSIFFLAGS, &fl); }
    ifr.ifr_hwaddr.sa_family = ARPHRD_ETHER;
    memcpy(ifr.ifr_hwaddr.sa_data, mac, 6);
    int rc = ioctl(fd, SIOCSIFHWADDR, &ifr);
    if (rc) logmsg("set " IFNAME " address: %s", strerror(errno));
    else logmsg(IFNAME " address %s", s);
    if (was_up) { fl.ifr_flags |= IFF_UP; ioctl(fd, SIOCSIFFLAGS, &fl); }
    close(fd);
    return rc;
}

static int apply_hostname(const char *h)
{
    char cur[256] = "";
    gethostname(cur, sizeof(cur) - 1);
    if (!strcmp(cur, h)) return 0;
    if (sethostname(h, strlen(h))) return -1;
    FILE *f = fopen("/etc/hostname", "w");
    if (f) { fprintf(f, "%s\n", h); fclose(f); }
    logmsg("hostname %s", h);
    return 0;
}

static int apply_tz(const char *zone)
{
    char cur[128] = "";
    if (read_file("/etc/timezone", cur, sizeof(cur)) > 0) cur[strcspn(cur, "\n")] = 0;
    if (!strcmp(cur, zone)) return 0;
    char src[300];
    snprintf(src, sizeof(src), ZONEINFO "/%s", zone);
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    int out = open("/etc/localtime.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) { close(in); return -1; }
    char buf[4096];
    ssize_t n;
    while ((n = read(in, buf, sizeof(buf))) > 0)
        if (write(out, buf, n) != n) { n = -1; break; }
    close(in); close(out);
    if (n < 0 || rename("/etc/localtime.tmp", "/etc/localtime")) { unlink("/etc/localtime.tmp"); return -1; }
    FILE *f = fopen("/etc/timezone", "w");
    if (f) { fprintf(f, "%s\n", zone); fclose(f); }
    logmsg("time zone %s", zone);
    return 0;
}

static void apply_all(const cfg_t *c)
{
    const char *v;
    if ((v = cfg_get(c, "mac")))      apply_mac(v);
    if ((v = cfg_get(c, "hostname"))) apply_hostname(v);
    if ((v = cfg_get(c, "tz")))       apply_tz(v);
}

/* ---- operations --------------------------------------------------------- */

/* boot: EEPROM -> file (when valid), apply */
static int op_load(void)
{
    uint8_t img[REGION];
    cfg_t c;
    if (eeprom_read(img)) return -1;
    if (image_decode(img, &c) == 0) {
        if (conf_write(&c)) logmsg("cannot write " CONF ": %s", strerror(errno));
        logmsg("%d setting(s) restored from the EEPROM", c.n);
    } else {
        logmsg("EEPROM holds no settings; using " CONF " as shipped");
        if (conf_read(&c)) return 0;
    }
    apply_all(&c);
    return 0;
}

/* file -> EEPROM, apply */
static int op_sync(void)
{
    cfg_t c;
    if (conf_read(&c)) { logmsg("cannot read " CONF); return -1; }
    for (int i = 0; i < c.n; i++)
        if (validate(c.kv[i].key, c.kv[i].val)) { logmsg("ignoring invalid %s=%s", c.kv[i].key, c.kv[i].val); cfg_unset(&c, c.kv[i].key); i--; }
    apply_all(&c);
    return eeprom_store(&c);
}

static int daemon_alive(void)
{
    char buf[32];
    if (read_file(PIDFILE, buf, sizeof(buf)) <= 0) return 0;
    pid_t pid = atoi(buf);
    return pid > 0 && pid != getpid() && kill(pid, 0) == 0;
}

static int op_set(const char *key, const char *val)
{
    cfg_t c;
    if (conf_read(&c)) memset(&c, 0, sizeof(c));
    if (val) {
        if (validate(key, val)) return -1;
        if (cfg_set(&c, key, val)) { logmsg("bad key or value too long"); return -1; }
    } else {
        cfg_unset(&c, key);
    }
    if (conf_write(&c)) { logmsg("cannot write " CONF ": %s", strerror(errno)); return -1; }
    if (daemon_alive()) return 0;            /* the daemon picks the change up */
    return op_sync();
}

static int op_erase(void)
{
    uint8_t img[HDR_LEN];
    memset(img, 0xFF, sizeof(img));
    if (eeprom_write(img, sizeof(img))) return -1;
    logmsg("EEPROM settings block erased");
    return 0;
}

static int op_show(int from_eeprom)
{
    if (!from_eeprom) {
        char buf[4096];
        if (read_file(CONF, buf, sizeof(buf)) < 0) { logmsg("no " CONF); return -1; }
        fputs(buf, stdout);
        return 0;
    }
    uint8_t img[REGION];
    cfg_t c;
    if (eeprom_read(img)) return -1;
    if (image_decode(img, &c)) { printf("EEPROM: no valid settings block\n"); return 1; }
    char text[4096];
    cfg_text(&c, text, sizeof(text), 1);
    fputs(text, stdout);
    return 0;
}

/* ---- daemon ------------------------------------------------------------- */

static void on_signal(int sig)
{
    if (sig == SIGHUP) g_hup = 1; else g_term = 1;
}

static int op_daemon(void)
{
    if (daemon_alive()) { logmsg("already running"); return 1; }
    op_load();                                  /* synchronous: settings are applied when we return */
    int ifd = inotify_init1(IN_CLOEXEC);
    if (ifd < 0 || inotify_add_watch(ifd, CONF_DIR, IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE) < 0) {
        logmsg("inotify: %s", strerror(errno));
        return 1;
    }
    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid > 0) return 0;
    setsid();
    g_daemon = 1;
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) { dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2); if (devnull > 2) close(devnull); }
    FILE *pf = fopen(PIDFILE, "w");
    if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); }
    signal(SIGHUP, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    char ev[4096] __attribute__((aligned(8)));
    int pending = 0;
    time_t quiet_until = 0;
    while (!g_term) {
        struct pollfd p = { .fd = ifd, .events = POLLIN };
        int r = poll(&p, 1, pending ? 300 : -1);
        if (r < 0 && errno != EINTR) break;
        if (r > 0) {
            ssize_t n = read(ifd, ev, sizeof(ev));
            for (ssize_t off = 0; off < n;) {
                struct inotify_event *e = (struct inotify_event *)(ev + off);
                if (e->len && !strcmp(e->name, "board.conf")) pending = 1;
                off += sizeof(*e) + e->len;
            }
            if (pending) continue;              /* debounce: wait for a quiet 300 ms */
        }
        if (g_hup) { g_hup = 0; pending = 1; }
        if (pending && time(NULL) >= quiet_until) {
            pending = 0;
            op_sync();
            quiet_until = time(NULL) + 1;       /* our own conf_write is not a new change */
        }
    }
    unlink(PIDFILE);
    return 0;
}

/* ---- main --------------------------------------------------------------- */

static void usage(void)
{
    fputs("usage: boardcfg [show [-e] | get KEY | set KEY VALUE | unset KEY | load | sync | erase | -d]\n", stderr);
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "show";
    if (!strcmp(cmd, "show"))  return op_show(argc > 2 && !strcmp(argv[2], "-e")) ? 1 : 0;
    if (!strcmp(cmd, "get")) {
        if (argc != 3) { usage(); return 2; }
        cfg_t c;
        if (conf_read(&c)) return 1;
        const char *v = cfg_get(&c, argv[2]);
        if (!v) return 1;
        printf("%s\n", v);
        return 0;
    }
    if (!strcmp(cmd, "set"))   { if (argc != 4) { usage(); return 2; } return op_set(argv[2], argv[3]) ? 1 : 0; }
    if (!strcmp(cmd, "unset")) { if (argc != 3) { usage(); return 2; } return op_set(argv[2], NULL) ? 1 : 0; }
    if (!strcmp(cmd, "load"))  return op_load() ? 1 : 0;
    if (!strcmp(cmd, "sync"))  return op_sync() ? 1 : 0;
    if (!strcmp(cmd, "erase")) return op_erase() ? 1 : 0;
    if (!strcmp(cmd, "-d") || !strcmp(cmd, "daemon")) return op_daemon();
    usage();
    return 2;
}
