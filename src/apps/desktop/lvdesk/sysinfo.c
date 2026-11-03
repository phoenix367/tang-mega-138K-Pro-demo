/* sysinfo.c -- /proc, /sys and hwmon readers for the desktop. */
#define _GNU_SOURCE
#include "lvdesk.h"
#include <arpa/inet.h>
#include <dirent.h>
#include <fcntl.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

int sysinfo_read_file(const char *path, char *buf, int len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { buf[0] = 0; return -1; }
    int n = read(fd, buf, len - 1);
    close(fd);
    if (n < 0) n = 0;
    buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == ' ')) buf[--n] = 0;
    return n;
}

int sysinfo_run(const char *cmd, char *out, int len)
{
    FILE *f = popen(cmd, "r");
    if (!f) { out[0] = 0; return -1; }
    int n = 0;
    while (n < len - 1) {
        int r = fread(out + n, 1, len - 1 - n, f);
        if (r <= 0) break;
        n += r;
    }
    out[n] = 0;
    pclose(f);
    return n;
}

static int read_int(const char *path, int dflt)
{
    char b[32];
    if (sysinfo_read_file(path, b, sizeof(b)) <= 0) return dflt;
    return atoi(b);
}

static char s_hwmon[320], s_fan[320];

static void find_hwmon(void)
{
    if (s_hwmon[0] && s_fan[0]) return;
    DIR *d = opendir("/sys/class/hwmon");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.') continue;
        char p[640], name[32];
        snprintf(p, sizeof(p), "/sys/class/hwmon/%s/name", de->d_name);
        sysinfo_read_file(p, name, sizeof(name));
        if (!strcmp(name, "gowin_fan"))
            snprintf(s_fan, sizeof(s_fan), "/sys/class/hwmon/%s", de->d_name);
        else if (!strncmp(name, "gowin", 5) || !s_hwmon[0])
            snprintf(s_hwmon, sizeof(s_hwmon), "/sys/class/hwmon/%s", de->d_name);
    }
    closedir(d);
}

const char *sysinfo_fan_dir(void) { find_hwmon(); return s_fan; }

int sysinfo_fan_set(int pwm)
{
    find_hwmon();
    if (!s_fan[0] || pwm < 0) return -1;
    char p[400], v[16];
    snprintf(p, sizeof(p), "%s/pwm1_enable", s_fan);
    int fd = open(p, O_WRONLY);
    if (fd < 0) return -1;
    if (write(fd, "1\n", 2) < 0) { close(fd); return -1; }
    close(fd);
    snprintf(p, sizeof(p), "%s/pwm1", s_fan);
    fd = open(p, O_WRONLY);
    if (fd < 0) return -1;
    int n = snprintf(v, sizeof(v), "%d\n", pwm > 255 ? 255 : pwm);
    int r = write(fd, v, n) == n ? 0 : -1;
    close(fd);
    return r;
}

void sysinfo_sample(sysinfo_t *si)
{
    char buf[512];

    /* CPU: first line of /proc/stat, against this sampler's previous reading
     * (the status bar and an open panel each sample once a second: a shared
     * "previous" would make one of them measure a few ticks and read 0/100%) */
    if (sysinfo_read_file("/proc/stat", buf, sizeof(buf)) > 0) {
        unsigned long long v[8] = {0};
        sscanf(buf, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
        unsigned long long total = 0;
        for (int i = 0; i < 8; i++) total += v[i];
        unsigned long long busy = total - v[3] - v[4];
        if (total >= si->p_total + 10) {    /* at least 100 ms of ticks for a meaningful ratio */
            si->cpu_pct = (int)((busy - si->p_busy) * 100 / (total - si->p_total));
            si->p_busy = busy; si->p_total = total;
        }
    }
    if (sysinfo_read_file("/proc/meminfo", buf, sizeof(buf)) > 0) {
        char *p = strstr(buf, "MemTotal:");
        if (p) si->mem_total_kb = strtoul(p + 9, NULL, 10);
        p = strstr(buf, "MemAvailable:");
        if (p) si->mem_avail_kb = strtoul(p + 13, NULL, 10);
    }
    if (sysinfo_read_file("/proc/loadavg", buf, sizeof(buf)) > 0)
        sscanf(buf, "%lf %lf %lf", &si->load1, &si->load5, &si->load15);
    if (sysinfo_read_file("/proc/uptime", buf, sizeof(buf)) > 0)
        si->uptime_s = (long)strtod(buf, NULL);

    /* hwmon: gowin-adc */
    find_hwmon();
    si->temp_mc = INT32_MIN;
    for (int i = 0; i < 8; i++) si->rail_mv[i] = -1;
    if (s_hwmon[0]) {
        char p[400];
        snprintf(p, sizeof(p), "%s/temp1_input", s_hwmon);
        si->temp_mc = read_int(p, INT32_MIN);
        for (int i = 0; i < 8; i++) {
            snprintf(p, sizeof(p), "%s/in%d_input", s_hwmon, i);
            si->rail_mv[i] = read_int(p, -1);
            snprintf(p, sizeof(p), "%s/in%d_label", s_hwmon, i);
            if (sysinfo_read_file(p, si->rail_label[i], sizeof(si->rail_label[i])) <= 0)
                snprintf(si->rail_label[i], sizeof(si->rail_label[i]), "in%d", i);
        }
    }

    /* fan */
    si->fan_present = s_fan[0] != 0;
    si->fan_rpm = si->fan_pwm = -1;
    if (s_fan[0]) {
        char p[400];
        snprintf(p, sizeof(p), "%s/fan1_input", s_fan);
        si->fan_rpm = read_int(p, -1);
        snprintf(p, sizeof(p), "%s/pwm1", s_fan);
        si->fan_pwm = read_int(p, -1);
        snprintf(p, sizeof(p), "%s/fan1_fault", s_fan);
        si->fan_fault = read_int(p, 0);
    } else
        si->fan_fault = 0;

    /* network: eth0 */
    si->link_speed = read_int("/sys/class/net/eth0/speed", -1);
    si->carrier = read_int("/sys/class/net/eth0/carrier", -1);   /* phylib: 0 as soon as the cable goes */
    sysinfo_read_file("/sys/class/net/eth0/address", si->mac, sizeof(si->mac));
    sysinfo_read_file("/sys/class/net/eth0/operstate", si->operstate, sizeof(si->operstate));
    if (sysinfo_read_file("/sys/class/net/eth0/statistics/rx_bytes", buf, sizeof(buf)) > 0) si->rx_bytes = strtoull(buf, NULL, 10);
    if (sysinfo_read_file("/sys/class/net/eth0/statistics/tx_bytes", buf, sizeof(buf)) > 0) si->tx_bytes = strtoull(buf, NULL, 10);
    si->ip[0] = 0;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s >= 0) {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof(ifr));
        snprintf(ifr.ifr_name, IFNAMSIZ, "eth0");
        if (!ioctl(s, SIOCGIFADDR, &ifr))
            inet_ntop(AF_INET, &((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr, si->ip, sizeof(si->ip));
        si->prefix = 0;
        if (si->ip[0] && !ioctl(s, SIOCGIFNETMASK, &ifr)) {
            uint32_t m = ntohl(((struct sockaddr_in *)&ifr.ifr_netmask)->sin_addr.s_addr);
            while (m & 0x80000000u) { si->prefix++; m <<= 1; }
        }
        close(s);
    }
}
