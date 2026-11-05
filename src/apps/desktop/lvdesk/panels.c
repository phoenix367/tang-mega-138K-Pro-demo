/* panels.c -- the desktop's panels. Each build function fills `parent`
 * (the area under the panel header); timers created here are deleted when
 * their objects go (LV_EVENT_DELETE), so leaving a panel is just lv_obj_clean. */
#define _GNU_SOURCE
#include "lvdesk.h"
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void timer_del_on_delete(lv_event_t *e)
{
    lv_timer_delete(lv_event_get_user_data(e));
}

static bool sd_mounted(void)              /* the microSD card at /mnt/sd (S45sdcard) */
{
    char buf[4096];
    if (sysinfo_read_file("/proc/mounts", buf, sizeof(buf)) <= 0) return false;
    return strstr(buf, " /mnt/sd ") != NULL;
}

static lv_obj_t *kv_row(lv_obj_t *parent, const char *key, lv_obj_t **val)
{
    lv_obj_t *r = lv_obj_create(parent);
    lv_obj_remove_style_all(r);
    lv_obj_set_width(r, LV_PCT(100));
    lv_obj_set_height(r, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_t *k = lv_label_create(r);
    lv_label_set_text(k, key);
    lv_obj_set_style_text_opa(k, LV_OPA_70, 0);
    *val = lv_label_create(r);
    lv_label_set_text(*val, "-");
    return r;
}

/* ====================================================================== */
/* System monitor                                                          */
/* ====================================================================== */
typedef struct {
    lv_obj_t *chart, *mem_bar, *mem_lbl, *load, *uptime, *temp, *rails[8], *rail_lbl[8], *fan;
    lv_chart_series_t *cpu_ser;
    sysinfo_t si;
} sysmon_t;

static void sysmon_tick(lv_timer_t *t)
{
    sysmon_t *m = lv_timer_get_user_data(t);
    sysinfo_sample(&m->si);
    lv_chart_set_next_value(m->chart, m->cpu_ser, m->si.cpu_pct);
    unsigned long used = m->si.mem_total_kb - m->si.mem_avail_kb;
    lv_bar_set_value(m->mem_bar, m->si.mem_total_kb ? (int)(used * 100 / m->si.mem_total_kb) : 0, LV_ANIM_OFF);
    lv_label_set_text_fmt(m->mem_lbl, "%lu / %lu MB used", used / 1024, m->si.mem_total_kb / 1024);
    lv_label_set_text_fmt(m->load, "%.2f  %.2f  %.2f", m->si.load1, m->si.load5, m->si.load15);
    long u = m->si.uptime_s;
    lv_label_set_text_fmt(m->uptime, "%ldd %02ld:%02ld:%02ld", u / 86400, (u / 3600) % 24, (u / 60) % 60, u % 60);
    if (m->si.temp_mc != INT32_MIN)
        lv_label_set_text_fmt(m->temp, "%d.%02d \xC2\xB0" "C", m->si.temp_mc / 1000, (abs(m->si.temp_mc) % 1000) / 10);
    if (!m->si.fan_present) lv_label_set_text(m->fan, "no fan core");
    else if (m->si.fan_rpm > 0) lv_label_set_text_fmt(m->fan, "%d rpm, PWM %d%%", m->si.fan_rpm, m->si.fan_pwm * 100 / 255);
    else lv_label_set_text_fmt(m->fan, "stopped, PWM %d%%", m->si.fan_pwm * 100 / 255);
    for (int i = 0; i < 8; i++) {
        lv_label_set_text(m->rail_lbl[i], m->si.rail_label[i]);
        if (m->si.rail_mv[i] >= 0) lv_label_set_text_fmt(m->rails[i], "%d.%03d V", m->si.rail_mv[i] / 1000, m->si.rail_mv[i] % 1000);
        else lv_label_set_text(m->rails[i], "n/a");
    }
}

static void sysmon_free(lv_event_t *e) { free(lv_event_get_user_data(e)); }

void panel_sysmon(lv_obj_t *parent)
{
    sysmon_t *m = calloc(1, sizeof(*m));
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(parent, 10, 0);

    lv_obj_t *left = desk_card(parent, "CPU load (A25 @ 800 MHz)");
    lv_obj_set_size(left, LV_PCT(58), LV_PCT(100));
    m->chart = lv_chart_create(left);
    lv_obj_set_width(m->chart, LV_PCT(100));
    lv_obj_set_flex_grow(m->chart, 1);
    lv_chart_set_type(m->chart, LV_CHART_TYPE_LINE);
    lv_chart_set_point_count(m->chart, 60);
    lv_chart_set_axis_range(m->chart, LV_CHART_AXIS_PRIMARY_Y, 0, 100);
    lv_chart_set_div_line_count(m->chart, 5, 6);
    lv_chart_set_update_mode(m->chart, LV_CHART_UPDATE_MODE_SHIFT);
    lv_obj_set_style_size(m->chart, 0, 0, LV_PART_INDICATOR);
    m->cpu_ser = lv_chart_add_series(m->chart, lv_palette_main(LV_PALETTE_LIGHT_BLUE), LV_CHART_AXIS_PRIMARY_Y);
    lv_chart_set_all_values(m->chart, m->cpu_ser, 0);

    lv_obj_t *ml = lv_label_create(left);
    lv_label_set_text(ml, "Memory");
    lv_obj_set_style_text_opa(ml, LV_OPA_70, 0);
    m->mem_bar = lv_bar_create(left);
    lv_obj_set_size(m->mem_bar, LV_PCT(100), 14);
    lv_bar_set_range(m->mem_bar, 0, 100);
    m->mem_lbl = lv_label_create(left);
    kv_row(left, "Load average", &m->load);
    kv_row(left, "Uptime", &m->uptime);

    lv_obj_t *right = desk_card(parent, "On-die sensors (gowin-adc)");
    lv_obj_set_size(right, LV_PCT(41), LV_PCT(100));
    kv_row(right, "Die temperature", &m->temp);
    lv_obj_set_style_text_font(m->temp, &lv_font_montserrat_24, 0);
    kv_row(right, "Fan", &m->fan);
    for (int i = 0; i < 8; i++) {
        lv_obj_t *r = kv_row(right, "", &m->rails[i]);
        m->rail_lbl[i] = lv_obj_get_child(r, 0);
        lv_obj_set_width(m->rail_lbl[i], LV_PCT(68));
        lv_label_set_long_mode(m->rail_lbl[i], LV_LABEL_LONG_DOT);
        lv_obj_set_style_text_font(m->rail_lbl[i], &lv_font_montserrat_14, 0);
    }

    lv_timer_t *t = lv_timer_create(sysmon_tick, 1000, m);
    lv_obj_add_event_cb(parent, timer_del_on_delete, LV_EVENT_DELETE, t);
    lv_obj_add_event_cb(parent, sysmon_free, LV_EVENT_DELETE, m);
    sysmon_tick(t);
}

/* ====================================================================== */
/* Audio: WAV player (wavplay child process)                               */
/* ====================================================================== */
static pid_t s_play_pid;
static char s_play_file[256];
static uint32_t s_play_start, s_play_len_ms;
static lv_obj_t *s_play_lbl, *s_play_bar, *s_play_list;

static int wav_duration_ms(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    unsigned char h[44];
    int n = fread(h, 1, 44, f);
    fclose(f);
    if (n < 44 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) return 0;
    unsigned rate = h[24] | h[25] << 8 | h[26] << 16 | h[27] << 24;
    unsigned bps = h[28] | h[29] << 8 | h[30] << 16 | h[31] << 24;
    struct stat st;
    if (stat(path, &st) || !bps) return 0;
    return (int)((unsigned long long)(st.st_size - 44) * 1000 / bps) + (rate ? 0 : 0);
}

static void audio_stop(void)
{
    if (s_play_pid > 0) {
        kill(s_play_pid, SIGTERM);
        waitpid(s_play_pid, NULL, 0);
        s_play_pid = 0;
    }
}

void audio_play_file(const char *path)
{
    audio_stop();
    snprintf(s_play_file, sizeof(s_play_file), "%s", path);
    s_play_len_ms = wav_duration_ms(path);
    s_play_start = lv_tick_get();
    pid_t p = fork();
    if (p == 0) {
        int nul = open("/dev/null", O_WRONLY);
        if (nul >= 0) { dup2(nul, 1); dup2(nul, 2); }
        execl("/usr/bin/wavplay", "wavplay", path, (char *)NULL);
        _exit(127);
    }
    s_play_pid = p;
}

static void audio_poll(lv_timer_t *t)
{
    (void)t;
    if (!s_play_lbl) return;
    if (s_play_pid > 0) {
        int st;
        if (waitpid(s_play_pid, &st, WNOHANG) == s_play_pid) s_play_pid = 0;
    }
    if (s_play_pid > 0) {
        uint32_t el = lv_tick_elaps(s_play_start);
        lv_label_set_text_fmt(s_play_lbl, LV_SYMBOL_PLAY " %s   %u.%u / %u.%u s", strrchr(s_play_file, '/') ? strrchr(s_play_file, '/') + 1 : s_play_file,
                              el / 1000, (el / 100) % 10, s_play_len_ms / 1000, (s_play_len_ms / 100) % 10);
        lv_bar_set_value(s_play_bar, s_play_len_ms ? (int)(el * 100 / s_play_len_ms) : 0, LV_ANIM_OFF);
    } else {
        lv_label_set_text(s_play_lbl, s_play_file[0] ? LV_SYMBOL_STOP " stopped" : "select a WAV file");
        lv_bar_set_value(s_play_bar, 0, LV_ANIM_OFF);
    }
}

static void audio_item_click(lv_event_t *e)
{
    lv_obj_t *btn = lv_event_get_target(e);
    const char *path = lv_obj_get_user_data(btn);
    audio_play_file(path);
}

static void audio_stop_click(lv_event_t *e) { (void)e; audio_stop(); }

static void audio_free_item(lv_event_t *e) { free(lv_obj_get_user_data(lv_event_get_target(e))); }

static void audio_scan(void)
{
    lv_obj_clean(s_play_list);
    static const char *dirs[] = { "/home/ae350", "/tmp", "/tmp/t", "/root" };
    int count = 0;
    for (unsigned d = 0; d < sizeof(dirs) / sizeof(dirs[0]); d++) {
        DIR *dp = opendir(dirs[d]);
        if (!dp) continue;
        struct dirent *de;
        while ((de = readdir(dp))) {
            size_t l = strlen(de->d_name);
            if (l < 5 || strcasecmp(de->d_name + l - 4, ".wav")) continue;
            char *path = malloc(strlen(dirs[d]) + l + 2);
            sprintf(path, "%s/%s", dirs[d], de->d_name);
            lv_obj_t *b = lv_list_add_button(s_play_list, LV_SYMBOL_AUDIO, path);
            lv_obj_set_user_data(b, path);
            lv_obj_add_event_cb(b, audio_item_click, LV_EVENT_CLICKED, NULL);
            lv_obj_add_event_cb(b, audio_free_item, LV_EVENT_DELETE, NULL);
            count++;
        }
        closedir(dp);
    }
    if (!count) lv_list_add_text(s_play_list, "no .wav files in /home/ae350 or /tmp (scp some over)");
}

/* 3 s 440/880 Hz stereo test tone written to /tmp */
static void audio_tone_click(lv_event_t *e)
{
    (void)e;
    const char *path = "/tmp/tone_440_880.wav";
    const int rate = 48000, secs = 3, frames = rate * secs;
    FILE *f = fopen(path, "wb");
    if (!f) return;
    unsigned data = frames * 4, riff = 36 + data, brate = rate * 4;
    unsigned char h[44];
    memcpy(h, "RIFF", 4); memcpy(h + 8, "WAVEfmt ", 8); memcpy(h + 36, "data", 4);
    unsigned le[][2] = { {4, riff}, {16, 16}, {24, rate}, {28, brate}, {40, data} };
    for (unsigned i = 0; i < 5; i++)
        for (int b = 0; b < 4; b++) h[le[i][0] + b] = (le[i][1] >> (8 * b)) & 0xFF;
    h[20] = 1; h[21] = 0; h[22] = 2; h[23] = 0;          /* PCM, stereo */
    h[32] = 4; h[33] = 0; h[34] = 16; h[35] = 0;         /* block align, bits */
    fwrite(h, 1, 44, f);
    short buf[2 * 480];
    for (int i = 0; i < frames; i += 480) {
        for (int j = 0; j < 480; j++) {
            double t = (double)(i + j) / rate, env = t < 0.05 ? t / 0.05 : (t > secs - 0.05 ? (secs - t) / 0.05 : 1.0);
            buf[2 * j] = (short)(12000 * env * sin(2 * M_PI * 440 * t));
            buf[2 * j + 1] = (short)(12000 * env * sin(2 * M_PI * 880 * t));
        }
        fwrite(buf, sizeof(buf), 1, f);
    }
    fclose(f);
    audio_scan();
    audio_play_file(path);
}

static void audio_rescan_click(lv_event_t *e) { (void)e; audio_scan(); }

static void audio_panel_gone(lv_event_t *e) { (void)e; s_play_lbl = NULL; s_play_bar = NULL; s_play_list = NULL; }

void panel_audio(lv_obj_t *parent)
{
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(parent, 8, 0);

    lv_obj_t *card = desk_card(parent, "PT8211 DAC - WAV player (16-bit PCM, mono/stereo)");
    lv_obj_set_size(card, LV_PCT(100), LV_SIZE_CONTENT);
    s_play_lbl = lv_label_create(card);
    lv_label_set_long_mode(s_play_lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_width(s_play_lbl, LV_PCT(100));
    s_play_bar = lv_bar_create(card);
    lv_obj_set_size(s_play_bar, LV_PCT(100), 10);
    lv_bar_set_range(s_play_bar, 0, 100);

    lv_obj_t *row = lv_obj_create(card);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(row, 10, 0);
    lv_obj_t *b = lv_button_create(row);
    lv_obj_add_event_cb(b, audio_stop_click, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_STOP " Stop");
    b = lv_button_create(row);
    lv_obj_add_event_cb(b, audio_tone_click, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_BELL " Test tone (L 440 / R 880 Hz)");
    b = lv_button_create(row);
    lv_obj_add_event_cb(b, audio_rescan_click, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_REFRESH " Rescan");

    s_play_list = lv_list_create(parent);
    lv_obj_set_width(s_play_list, LV_PCT(100));
    lv_obj_set_flex_grow(s_play_list, 1);
    audio_scan();

    lv_timer_t *t = lv_timer_create(audio_poll, 200, NULL);
    lv_obj_add_event_cb(parent, timer_del_on_delete, LV_EVENT_DELETE, t);
    lv_obj_add_event_cb(parent, audio_panel_gone, LV_EVENT_DELETE, NULL);
    audio_poll(t);
}

/* ====================================================================== */
/* Video: vidplay child process (src/apps/vidplay)                         */
/* ====================================================================== */
/* vidplay draws straight into /dev/fb0, so while it runs the desktop's flushes
 * are swallowed, and the main loop does not run LVGL at all: it sleeps in
 * video_wait() until input arrives (a key or click stops the playback) or the
 * child exits.  Its once-a-second status bar sampling and rendering used to
 * delay the player's frame flips by tens of ms (~1 visible hitch per 10 s at
 * 852x480).  When the child exits the whole screen is invalidated and repainted. */
#include "src/display/lv_display_private.h"      /* disp->flush_cb: no public getter */
static pid_t s_vid_pid;
static lv_display_flush_cb_t s_vid_orig_flush;

static void video_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px)
{
    if (s_vid_pid > 0) lv_display_flush_ready(disp);
    else s_vid_orig_flush(disp, area, px);
}

bool video_active(void) { return s_vid_pid > 0; }

static void video_done(void)
{
    s_vid_pid = 0;
    lv_obj_invalidate(lv_screen_active());
}

void video_stop(void)
{
    if (s_vid_pid <= 0) return;
    kill(s_vid_pid, SIGTERM);
    waitpid(s_vid_pid, NULL, 0);
    video_done();
}

/* the main loop's step while the player runs, instead of lv_timer_handler() */
void video_wait(void)
{
    int st;
    input_wait(200);
    if (s_vid_pid > 0 && waitpid(s_vid_pid, &st, WNOHANG) == s_vid_pid) video_done();
}

void video_play_file(const char *path)
{
    video_stop();
    audio_stop();
    if (!s_vid_orig_flush) {
        s_vid_orig_flush = g_disp->flush_cb;
        lv_display_set_flush_cb(g_disp, video_flush);
    }
    pid_t p = fork();
    if (p == 0) {
        int log = open("/run/vidplay.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log >= 0) { dup2(log, 1); dup2(log, 2); }
        execl("/usr/bin/vidplay", "vidplay", path, (char *)NULL);   /* no -L: skipping the deblocking filter makes P-frames drift */
        _exit(127);
    }
    if (p < 0) return;
    s_vid_pid = p;
}

/* ====================================================================== */
/* Network                                                                 */
/* ====================================================================== */
#define BOARDCFG       "/usr/sbin/boardcfg"   /* board EEPROM settings daemon/CLI */
#define BOARDCFG_CONF  "/etc/board.conf"      /* what it keeps: key=value lines */
#define NET_DEFAULT_IP "192.168.200.2/24"     /* S40network's default when no ip key */

typedef struct {
    lv_obj_t *chart, *ip, *mac, *link, *rx, *tx, *mode, *gw;
    lv_chart_series_t *rx_ser, *tx_ser;
    unsigned long long p_rx, p_tx;
    uint32_t p_tick;
    sysinfo_t si;
} net_t;

/* one value from /etc/board.conf ("" when absent) */
static void conf_get(const char *key, char *out, int cap)
{
    out[0] = 0;
    FILE *f = fopen(BOARDCFG_CONF, "r");
    if (!f) return;
    char line[256];
    size_t kl = strlen(key);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, kl) || line[kl] != '=') continue;
        snprintf(out, cap, "%s", line + kl + 1);
        out[strcspn(out, "\r\n")] = 0;
    }
    fclose(f);
}

/* eth0's default gateway from /proc/net/route, "" when none */
static void net_gateway(char *out, int cap)
{
    out[0] = 0;
    FILE *f = fopen("/proc/net/route", "r");
    if (!f) return;
    char line[256], ifn[32];
    unsigned dst, gw, flags;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "%31s %x %x %x", ifn, &dst, &gw, &flags) != 4 || dst || !(flags & 2)) continue;
        if (strcmp(ifn, "eth0")) continue;
        struct in_addr a = { .s_addr = gw };
        inet_ntop(AF_INET, &a, out, cap);
        break;
    }
    fclose(f);
}

static void net_tick(lv_timer_t *t)
{
    net_t *n = lv_timer_get_user_data(t);
    sysinfo_sample(&n->si);
    char v[64];
    conf_get("net", v, sizeof(v));
    if (access(BOARDCFG, X_OK)) lv_label_set_text(n->mode, "static (no boardcfg)");
    else lv_label_set_text(n->mode, !strcmp(v, "dhcp") ? "DHCP (udhcpc)" : "static IP");
    net_gateway(v, sizeof(v));
    lv_label_set_text(n->gw, v[0] ? v : "none");
    uint32_t now = lv_tick_get(), dt = n->p_tick ? now - n->p_tick : 1000;
    if (n->p_tick && dt) {
        /* kbit/s */
        int rxk = (int)((n->si.rx_bytes - n->p_rx) * 8 / dt), txk = (int)((n->si.tx_bytes - n->p_tx) * 8 / dt);
        lv_chart_set_next_value(n->chart, n->rx_ser, rxk);
        lv_chart_set_next_value(n->chart, n->tx_ser, txk);
        /* autoscale */
        int32_t mx = 1000;
        int32_t *rv = lv_chart_get_series_y_array(n->chart, n->rx_ser), *tv = lv_chart_get_series_y_array(n->chart, n->tx_ser);
        for (uint32_t i = 0; i < lv_chart_get_point_count(n->chart); i++) {
            if (rv[i] != LV_CHART_POINT_NONE && rv[i] > mx) mx = rv[i];
            if (tv[i] != LV_CHART_POINT_NONE && tv[i] > mx) mx = tv[i];
        }
        lv_chart_set_axis_range(n->chart, LV_CHART_AXIS_PRIMARY_Y, 0, mx + mx / 10);
        lv_label_set_text_fmt(n->rx, "%llu MB total,  %d kbit/s", n->si.rx_bytes >> 20, rxk);
        lv_label_set_text_fmt(n->tx, "%llu MB total,  %d kbit/s", n->si.tx_bytes >> 20, txk);
    }
    n->p_rx = n->si.rx_bytes; n->p_tx = n->si.tx_bytes; n->p_tick = now;
    if (n->si.ip[0]) lv_label_set_text_fmt(n->ip, "%s/%d", n->si.ip, n->si.prefix);
    else lv_label_set_text(n->ip, "none");
    lv_label_set_text(n->mac, n->si.mac);
    if (n->si.carrier == 0) lv_label_set_text(n->link, "no carrier (cable unplugged)");
    else if (n->si.link_speed > 0) lv_label_set_text_fmt(n->link, "%s, %d Mbit/s", n->si.operstate, n->si.link_speed);
    else lv_label_set_text(n->link, n->si.operstate);
}

static void net_free(lv_event_t *e) { free(lv_event_get_user_data(e)); }

/* ---- "Configure" dialog: the network keys of boardcfg(8) ----------------
 * Mode / IP / gateway / DNS / hostname / MAC are edited here, checked the
 * same way boardcfg does, then written with `boardcfg set|unset`; the daemon
 * stores them in the EEPROM and re-runs S40network, so eth0 changes within a
 * second. An empty field means "unset" (S40network's default applies). */
typedef struct {
    lv_obj_t *mb, *mode, *ip, *gw, *dns, *host, *mac, *status;
} netcfg_t;

static int ipv4_ok(const char *s, size_t n)
{
    char b[16];
    struct in_addr a;
    if (n == 0 || n >= sizeof(b)) return 0;
    memcpy(b, s, n); b[n] = 0;
    return inet_pton(AF_INET, b, &a) == 1 && a.s_addr != 0;
}

static int cidr_ok(const char *s)
{
    const char *sl = strchr(s, '/');
    if (!ipv4_ok(s, sl ? (size_t)(sl - s) : strlen(s))) return 0;
    if (!sl) return 1;
    char *e;
    long n = strtol(sl + 1, &e, 10);
    return e != sl + 1 && !*e && n >= 1 && n <= 32;
}

static int dns_ok(const char *s)
{
    int n = 0;
    while (*s) {
        while (*s == ' ' || *s == ',') s++;
        if (!*s) break;
        size_t l = strcspn(s, " ,");
        if (!ipv4_ok(s, l) || ++n > 3) return 0;
        s += l;
    }
    return n > 0;
}

static int mac_ok(const char *s)
{
    unsigned v[6];
    char tail;
    if (sscanf(s, "%x:%x:%x:%x:%x:%x%c", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &tail) != 6) return 0;
    int zero = 1;
    for (int i = 0; i < 6; i++) { if (v[i] > 255) return 0; if (v[i]) zero = 0; }
    return !zero && !(v[0] & 1);
}

static int host_ok(const char *s)
{
    if (!*s || strlen(s) > 63) return 0;
    for (; *s; s++) if (!isalnum((unsigned char)*s) && *s != '-') return 0;
    return 1;
}

/* trimmed text of a textarea */
static const char *ta_text(lv_obj_t *ta, char *buf, int cap)
{
    snprintf(buf, cap, "%s", lv_textarea_get_text(ta));
    char *s = buf;
    while (*s == ' ') s++;
    char *e = s + strlen(s);
    while (e > s && e[-1] == ' ') *--e = 0;
    return s;
}

/* boardcfg set KEY VAL (unset when VAL is empty); the value was validated to
 * contain only [0-9A-Za-z.:/ ,-] so single quotes are safe */
static int netcfg_put(const char *key, const char *val, char *err, int cap)
{
    char cmd[300], out[256] = "";
    if (*val) snprintf(cmd, sizeof(cmd), BOARDCFG " set %s '%s' 2>&1", key, val);
    else snprintf(cmd, sizeof(cmd), BOARDCFG " unset %s 2>&1", key);
    int n = sysinfo_run(cmd, out, sizeof(out));
    if (n > 0 && strstr(out, "boardcfg:")) {       /* it only talks on errors */
        snprintf(err, cap, "%s", out);
        err[strcspn(err, "\n")] = 0;
        return -1;
    }
    return 0;
}

static void netcfg_fail(netcfg_t *c, const char *msg)
{
    lv_label_set_text(c->status, msg);
    lv_obj_set_style_text_color(c->status, lv_palette_main(LV_PALETTE_RED), 0);
}

static void netcfg_apply(lv_event_t *e)
{
    netcfg_t *c = lv_event_get_user_data(e);
    char bip[128], bgw[128], bdns[128], bhost[128], bmac[128];
    int dhcp = lv_dropdown_get_selected(c->mode) == 1;
    const char *ip = ta_text(c->ip, bip, sizeof(bip)), *gw = ta_text(c->gw, bgw, sizeof(bgw));
    const char *dns = ta_text(c->dns, bdns, sizeof(bdns)), *host = ta_text(c->host, bhost, sizeof(bhost));
    const char *mac = ta_text(c->mac, bmac, sizeof(bmac));
    const char *all[] = { ip, gw, dns, host, mac };
    for (unsigned i = 0; i < 5; i++)
        for (const char *p = all[i]; *p; p++)
            if (!isalnum((unsigned char)*p) && !strchr(".:/ ,-", *p)) { netcfg_fail(c, "unexpected character in a field"); return; }
    if (!dhcp && *ip && !cidr_ok(ip)) { netcfg_fail(c, "IP address: A.B.C.D or A.B.C.D/N"); return; }
    if (!dhcp && *gw && !ipv4_ok(gw, strlen(gw))) { netcfg_fail(c, "gateway: an IPv4 address"); return; }
    if (!dhcp && *dns && !dns_ok(dns)) { netcfg_fail(c, "DNS: one to three IPv4 addresses, space separated"); return; }
    if (*host && !host_ok(host)) { netcfg_fail(c, "hostname: letters, digits and '-' (1..63)"); return; }
    if (*mac && !mac_ok(mac)) { netcfg_fail(c, "MAC: unicast xx:xx:xx:xx:xx:xx"); return; }

    char err[256];
    /* several `set`s inside the daemon's 300 ms debounce = one EEPROM write and
     * one network restart */
    if (netcfg_put("net", dhcp ? "dhcp" : "", err, sizeof(err)) ||
        netcfg_put("ip", dhcp ? "" : ip, err, sizeof(err)) ||
        netcfg_put("gateway", dhcp ? "" : gw, err, sizeof(err)) ||
        netcfg_put("dns", dhcp ? "" : dns, err, sizeof(err)) ||
        netcfg_put("hostname", host, err, sizeof(err)) ||
        netcfg_put("mac", mac, err, sizeof(err))) { netcfg_fail(c, err); return; }
    lv_msgbox_close_async(c->mb);          /* we are inside one of its children's events */
    desk_msgbox("Network", dhcp ? "Saved to the board EEPROM. eth0 is now asking for a DHCP lease."
                                : "Saved to the board EEPROM. eth0 is being reconfigured.");
}

/* the static-only fields follow the mode */
static void netcfg_sync_mode(netcfg_t *c)
{
    int dhcp = lv_dropdown_get_selected(c->mode) == 1;
    lv_obj_t *f[] = { c->ip, c->gw, c->dns };
    for (int i = 0; i < 3; i++) {
        if (dhcp) lv_obj_add_state(f[i], LV_STATE_DISABLED);
        else lv_obj_remove_state(f[i], LV_STATE_DISABLED);
    }
}

static void netcfg_mode(lv_event_t *e) { netcfg_sync_mode(lv_event_get_user_data(e)); }

static void netcfg_free(lv_event_t *e) { free(lv_event_get_user_data(e)); }

static lv_obj_t *netcfg_field(lv_obj_t *parent, const char *label, const char *val, const char *hint, netcfg_t *c)
{
    lv_obj_t *r = lv_obj_create(parent);
    lv_obj_remove_style_all(r);
    lv_obj_set_size(r, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_t *l = lv_label_create(r);
    lv_label_set_text(l, label);
    lv_obj_set_width(l, 150);
    lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    lv_obj_t *ta = lv_textarea_create(r);
    lv_obj_set_flex_grow(ta, 1);
    lv_textarea_set_one_line(ta, true);
    lv_textarea_set_max_length(ta, 100);
    lv_textarea_set_text(ta, val);
    lv_textarea_set_placeholder_text(ta, hint);
    lv_obj_set_style_pad_ver(ta, 6, 0);
    lv_obj_add_event_cb(ta, netcfg_apply, LV_EVENT_READY, c);      /* Enter = Apply */
    return ta;
}

static void net_configure(lv_event_t *e)
{
    (void)e;
    if (access(BOARDCFG, X_OK)) { desk_msgbox("Network", "boardcfg is not installed: settings cannot be kept."); return; }
    netcfg_t *c = calloc(1, sizeof(*c));
    char net[32], ip[128], gw[128], dns[128], host[128], mac[128];
    conf_get("net", net, sizeof(net));
    conf_get("ip", ip, sizeof(ip));
    conf_get("gateway", gw, sizeof(gw));
    conf_get("dns", dns, sizeof(dns));
    conf_get("hostname", host, sizeof(host));
    conf_get("mac", mac, sizeof(mac));

    c->mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(c->mb, "eth0 configuration (kept in the board EEPROM)");
    lv_msgbox_add_close_button(c->mb);
    lv_obj_set_width(c->mb, 560);
    lv_obj_add_event_cb(c->mb, netcfg_free, LV_EVENT_DELETE, c);
    lv_obj_t *body = lv_msgbox_get_content(c->mb);
    lv_obj_set_flex_flow(body, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(body, 6, 0);

    lv_obj_t *r = lv_obj_create(body);
    lv_obj_remove_style_all(r);
    lv_obj_set_size(r, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(r, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_t *l = lv_label_create(r);
    lv_label_set_text(l, "Mode");
    lv_obj_set_width(l, 150);
    lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    c->mode = lv_dropdown_create(r);
    lv_dropdown_set_options_static(c->mode, "Static IP\nDHCP (udhcpc)");
    lv_dropdown_set_selected(c->mode, !strcmp(net, "dhcp") ? 1 : 0);
    lv_obj_set_flex_grow(c->mode, 1);
    lv_obj_add_event_cb(c->mode, netcfg_mode, LV_EVENT_VALUE_CHANGED, c);

    c->ip   = netcfg_field(body, "IP address / prefix", ip, "empty = " NET_DEFAULT_IP, c);
    c->gw   = netcfg_field(body, "Gateway", gw, "empty = no default route", c);
    c->dns  = netcfg_field(body, "DNS servers", dns, "empty = the gateway; up to three, space separated", c);
    c->host = netcfg_field(body, "Hostname", host, "ae350", c);
    c->mac  = netcfg_field(body, "MAC address", mac, "empty = random at every boot", c);
    c->status = lv_label_create(body);
    lv_label_set_text(c->status, "Empty fields fall back to the defaults. Applying reconfigures eth0 at once\n(an ssh session on the old address is dropped).");
    lv_obj_set_style_text_font(c->status, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_opa(c->status, LV_OPA_70, 0);
    lv_label_set_long_mode(c->status, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(c->status, LV_PCT(100));

    lv_obj_t *b = lv_msgbox_add_footer_button(c->mb, "Apply");
    lv_obj_add_event_cb(b, netcfg_apply, LV_EVENT_CLICKED, c);
    netcfg_sync_mode(c);
    lv_group_focus_obj(c->ip);
}

void panel_network(lv_obj_t *parent)
{
    net_t *n = calloc(1, sizeof(*n));
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(parent, 10, 0);

    lv_obj_t *left = desk_card(parent, "eth0 throughput (kbit/s)");
    lv_obj_set_size(left, LV_PCT(58), LV_PCT(100));
    n->chart = lv_chart_create(left);
    lv_obj_set_width(n->chart, LV_PCT(100));
    lv_obj_set_flex_grow(n->chart, 1);
    lv_chart_set_point_count(n->chart, 60);
    lv_chart_set_update_mode(n->chart, LV_CHART_UPDATE_MODE_SHIFT);
    lv_chart_set_div_line_count(n->chart, 5, 6);
    lv_obj_set_style_size(n->chart, 0, 0, LV_PART_INDICATOR);
    n->rx_ser = lv_chart_add_series(n->chart, lv_palette_main(LV_PALETTE_GREEN), LV_CHART_AXIS_PRIMARY_Y);
    n->tx_ser = lv_chart_add_series(n->chart, lv_palette_main(LV_PALETTE_ORANGE), LV_CHART_AXIS_PRIMARY_Y);
    lv_obj_t *lg = lv_label_create(left);
    lv_label_set_recolor(lg, true);
    lv_label_set_text(lg, "#4caf50 RX#   #ff9800 TX#");

    lv_obj_t *right = desk_card(parent, "Gowin TSE MAC, RTL8211F PHY");
    lv_obj_set_size(right, LV_PCT(41), LV_PCT(100));
    kv_row(right, "Mode", &n->mode);
    kv_row(right, "IPv4", &n->ip);
    kv_row(right, "Gateway", &n->gw);
    kv_row(right, "MAC", &n->mac);
    kv_row(right, "Link", &n->link);
    lv_obj_t *l = lv_label_create(right); lv_label_set_text(l, "Received"); lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    n->rx = lv_label_create(right);
    l = lv_label_create(right); lv_label_set_text(l, "Sent"); lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    n->tx = lv_label_create(right);
    lv_obj_t *b = lv_button_create(right);
    lv_obj_add_event_cb(b, net_configure, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_SETTINGS " Configure");
    l = lv_label_create(right);
    lv_label_set_text(l, "Input bridge: inputd on tcp/5555, PC side: desktop/host/netinput.py");
    lv_obj_set_style_text_font(l, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(l, LV_PCT(100));

    lv_timer_t *t = lv_timer_create(net_tick, 1000, n);
    lv_obj_add_event_cb(parent, timer_del_on_delete, LV_EVENT_DELETE, t);
    lv_obj_add_event_cb(parent, net_free, LV_EVENT_DELETE, n);
    net_tick(t);
}

/* ====================================================================== */
/* Console: run a shell command on a pty, stream its output; dmesg by default */
/* ====================================================================== */
/* The command runs as a child on a pseudo-terminal (so its stdio is line
 * buffered and it behaves as on a console), its output is read without
 * blocking from an LVGL timer and the last CON_MAX bytes are shown. The UI
 * never waits for the command: ping, top -d1, tail -f... just stream, and
 * Stop (or leaving the panel, or the next command) ends them. */
#define CON_MAX 12288
static lv_obj_t *s_con_out, *s_con_in, *s_con_stop;
static lv_timer_t *s_con_timer;
static pid_t s_con_pid;                 /* 0 = nothing running */
static int s_con_fd = -1;               /* pty master */
static char s_con_buf[CON_MAX + 1];
static int s_con_len;

static void console_append(const char *d, int n)
{
    if (n > CON_MAX) { d += n - CON_MAX; n = CON_MAX; }
    while (s_con_len + n > CON_MAX) {   /* drop whole lines from the top */
        char *nl = memchr(s_con_buf, '\n', s_con_len);
        int cut = nl ? (int)(nl - s_con_buf) + 1 : s_con_len;
        memmove(s_con_buf, s_con_buf + cut, s_con_len - cut);
        s_con_len -= cut;
    }
    for (int i = 0; i < n; i++)
        if (d[i] != '\r') s_con_buf[s_con_len++] = d[i];
    s_con_buf[s_con_len] = 0;
}

static void console_show(void)
{
    if (!s_con_out) return;
    lv_textarea_set_text(s_con_out, s_con_buf);
    lv_textarea_set_cursor_pos(s_con_out, LV_TEXTAREA_CURSOR_LAST);
}

/* read whatever the pty has; returns false at EOF/error (child side closed) */
static bool console_drain(void)
{
    char tmp[2048];
    for (;;) {
        int n = read(s_con_fd, tmp, sizeof(tmp));
        if (n > 0) { console_append(tmp, n); continue; }
        if (n < 0 && errno == EINTR) continue;
        return n < 0 && errno == EAGAIN;
    }
}

static void console_finish(int status)
{
    char m[48];
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) snprintf(m, sizeof(m), "[done]\n");
    else if (WIFEXITED(status)) snprintf(m, sizeof(m), "[exit %d]\n", WEXITSTATUS(status));
    else if (WIFSIGNALED(status)) snprintf(m, sizeof(m), "[stopped]\n");
    else m[0] = 0;
    if (s_con_len && s_con_buf[s_con_len - 1] != '\n') console_append("\n", 1);
    console_append(m, strlen(m));
    s_con_pid = 0;
    if (s_con_fd >= 0) { close(s_con_fd); s_con_fd = -1; }
    if (s_con_timer) { lv_timer_delete(s_con_timer); s_con_timer = NULL; }
    if (s_con_stop) lv_obj_add_state(s_con_stop, LV_STATE_DISABLED);
    console_show();
}

static void console_poll(lv_timer_t *t)
{
    (void)t;
    int before = s_con_len;
    bool open = console_drain();
    int st = 0;
    if (!open || waitpid(s_con_pid, &st, WNOHANG) == s_con_pid) {
        if (open) {             /* exited, reaped: pick up what is left */
            console_drain();
        } else {
            waitpid(s_con_pid, &st, 0);
        }
        console_finish(st);
        return;
    }
    if (s_con_len != before) console_show();
}

static void console_stop(void)
{
    if (!s_con_pid) return;
    int st = 0;
    kill(-s_con_pid, SIGTERM);              /* forkpty child = session leader: pgid == pid */
    for (int i = 0; i < 30 && waitpid(s_con_pid, &st, WNOHANG) == 0; i++) usleep(10000);
    if (kill(s_con_pid, 0) == 0 && waitpid(s_con_pid, &st, WNOHANG) == 0) {
        kill(-s_con_pid, SIGKILL);
        waitpid(s_con_pid, &st, 0);
    }
    console_drain();
    console_finish(st);
}

static void console_run(const char *cmd)
{
    console_stop();
    s_con_len = 0;
    s_con_buf[0] = 0;
    char hdr[600];
    snprintf(hdr, sizeof(hdr), "# %s\n", cmd);
    console_append(hdr, strlen(hdr));

    struct winsize ws = { .ws_row = 40, .ws_col = 96 };
    int fd;
    pid_t pid = forkpty(&fd, NULL, NULL, &ws);
    if (pid < 0) {
        console_append("forkpty failed\n", 15);
        console_show();
        return;
    }
    if (pid == 0) {
        setenv("TERM", "dumb", 1);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    s_con_pid = pid;
    s_con_fd = fd;
    s_con_timer = lv_timer_create(console_poll, 100, NULL);
    if (s_con_stop) lv_obj_remove_state(s_con_stop, LV_STATE_DISABLED);
    console_show();
}

static void console_enter(lv_event_t *e)
{
    (void)e;
    const char *cmd = lv_textarea_get_text(s_con_in);
    if (!cmd[0]) return;
    console_run(cmd);
    lv_textarea_set_text(s_con_in, "");
}

static void console_btn(lv_event_t *e)
{
    const char *cmd = lv_event_get_user_data(e);
    lv_textarea_set_text(s_con_in, cmd);
    console_run(cmd);
}

static void console_stop_btn(lv_event_t *e) { (void)e; console_stop(); }

static void console_gone(lv_event_t *e)
{
    (void)e;
    s_con_out = s_con_in = s_con_stop = NULL;   /* widgets are going away */
    console_stop();                              /* the command does not outlive the panel */
}

void panel_console(lv_obj_t *parent)
{
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(parent, 6, 0);

    lv_obj_t *row = lv_obj_create(parent);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(row, 6, 0);
    static const char *quick[] = { "dmesg | tail -n 30", "ps", "free", "df -h", "ifconfig eth0", "cat /proc/interrupts", "ping 192.168.200.1" };
    static const char *names[] = { "dmesg", "ps", "free", "df", "ifconfig", "irqs", "ping" };
    for (unsigned i = 0; i < sizeof(quick) / sizeof(quick[0]); i++) {
        lv_obj_t *b = lv_button_create(row);
        lv_obj_set_style_pad_ver(b, 6, 0);
        lv_obj_add_event_cb(b, console_btn, LV_EVENT_CLICKED, (void *)quick[i]);
        lv_label_set_text(lv_label_create(b), names[i]);
    }
    s_con_stop = lv_button_create(row);
    lv_obj_set_style_pad_ver(s_con_stop, 6, 0);
    lv_obj_set_style_bg_color(s_con_stop, lv_palette_main(LV_PALETTE_RED), 0);
    lv_obj_add_state(s_con_stop, LV_STATE_DISABLED);
    lv_obj_add_event_cb(s_con_stop, console_stop_btn, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(s_con_stop), LV_SYMBOL_STOP " stop");

    s_con_out = lv_textarea_create(parent);
    lv_obj_set_width(s_con_out, LV_PCT(100));
    lv_obj_set_flex_grow(s_con_out, 1);
    lv_obj_set_style_text_font(s_con_out, &lv_font_unscii_8, 0);
    lv_obj_set_style_text_line_space(s_con_out, 2, 0);
    lv_textarea_set_cursor_click_pos(s_con_out, false);
    lv_obj_set_click_focusable(s_con_out, false);

    s_con_in = lv_textarea_create(parent);
    lv_obj_set_width(s_con_in, LV_PCT(100));
    lv_textarea_set_one_line(s_con_in, true);
    lv_textarea_set_placeholder_text(s_con_in, "shell command (as root), Enter to run; long-running ones stream, Stop ends them");
    lv_obj_add_event_cb(s_con_in, console_enter, LV_EVENT_READY, NULL);
    lv_group_focus_obj(s_con_in);
    lv_obj_add_event_cb(parent, console_gone, LV_EVENT_DELETE, NULL);
    console_run("dmesg | tail -n 30");
}

/* ====================================================================== */
/* Settings / About                                                        */
/* ====================================================================== */
static void dark_switch(lv_event_t *e)
{
    desk_set_dark(lv_obj_has_state(lv_event_get_target(e), LV_STATE_CHECKED));
}

static void fps_switch(lv_event_t *e)
{
#if LV_USE_PERF_MONITOR
    if (lv_obj_has_state(lv_event_get_target(e), LV_STATE_CHECKED)) lv_sysmon_show_performance(g_disp);
    else lv_sysmon_hide_performance(g_disp);
#else
    (void)e;
#endif
}

static void power_do(lv_event_t *e)
{
    int cmd = (int)(intptr_t)lv_event_get_user_data(e);
    sync();
    if (cmd == 1) execl("/sbin/reboot", "reboot", (char *)NULL);
    else execl("/sbin/poweroff", "poweroff", (char *)NULL);
}

static void power_ask(lv_event_t *e)
{
    int cmd = (int)(intptr_t)lv_event_get_user_data(e);
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, cmd == 1 ? "Reboot" : "Power off");
    lv_msgbox_add_text(mb, cmd == 1 ? "Reboot the board now?" : "Halt the board now? (power-cycle to restart)");
    lv_msgbox_add_close_button(mb);
    lv_obj_t *b = lv_msgbox_add_footer_button(mb, cmd == 1 ? "Reboot" : "Power off");
    lv_obj_add_event_cb(b, power_do, LV_EVENT_CLICKED, (void *)(intptr_t)cmd);
}

static void exit_click(lv_event_t *e) { (void)e; desk_request_exit(0); }

/* fan: "auto" = the S80fan curve runs; off = the slider sets pwm1 directly */
static lv_obj_t *s_fan_slider, *s_fan_lbl;
static void fan_auto_switch(lv_event_t *e)
{
    bool on = lv_obj_has_state(lv_event_get_target(e), LV_STATE_CHECKED);
    char out[64];
    sysinfo_run(on ? "/etc/init.d/S80fan start" : "/etc/init.d/S80fan stop", out, sizeof(out));
    if (on) lv_obj_add_state(s_fan_slider, LV_STATE_DISABLED);
    else { lv_obj_remove_state(s_fan_slider, LV_STATE_DISABLED); sysinfo_fan_set(lv_slider_get_value(s_fan_slider)); }
}
static void fan_slider(lv_event_t *e)
{
    int v = lv_slider_get_value(lv_event_get_target(e));
    lv_label_set_text_fmt(s_fan_lbl, "PWM %d%%", v * 100 / 255);
    if (lv_event_get_code(e) == LV_EVENT_RELEASED || lv_event_get_code(e) == LV_EVENT_VALUE_CHANGED) sysinfo_fan_set(v);
}

void panel_settings(lv_obj_t *parent)
{
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(parent, 10, 0);

    lv_obj_t *c = desk_card(parent, "Appearance");
    lv_obj_set_size(c, LV_PCT(49), LV_PCT(100));
    lv_obj_t *v;
    lv_obj_t *r = kv_row(c, "Dark theme", &v);
    lv_obj_delete(v);
    lv_obj_t *sw = lv_switch_create(r);
    if (desk_is_dark()) lv_obj_add_state(sw, LV_STATE_CHECKED);
    lv_obj_add_event_cb(sw, dark_switch, LV_EVENT_VALUE_CHANGED, NULL);
    r = kv_row(c, "Show FPS / CPU overlay", &v);
    lv_obj_delete(v);
    sw = lv_switch_create(r);
    lv_obj_add_event_cb(sw, fps_switch, LV_EVENT_VALUE_CHANGED, NULL);

    lv_obj_t *l = lv_label_create(c);
    lv_label_set_text(l, "Keyboard: Ctrl+Alt+H home, Ctrl+Alt+Q restart, Tab/Shift+Tab focus");
    lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_14, 0);

    /* fan */
    if (sysinfo_fan_dir()[0]) {
        l = lv_label_create(c);
        lv_label_set_text(l, "\nFan");
        lv_obj_set_style_text_font(l, &lv_font_montserrat_18, 0);
        lv_obj_set_style_text_color(l, lv_palette_main(LV_PALETTE_CYAN), 0);
        r = kv_row(c, "Automatic (temperature curve)", &v);
        lv_obj_delete(v);
        sw = lv_switch_create(r);
        char out[64];
        sysinfo_run("[ -f /run/fand.pid ] && echo on", out, sizeof(out));
        bool autofan = strstr(out, "on") != NULL;
        if (autofan) lv_obj_add_state(sw, LV_STATE_CHECKED);
        lv_obj_add_event_cb(sw, fan_auto_switch, LV_EVENT_VALUE_CHANGED, NULL);
        sysinfo_t si;
        sysinfo_sample(&si);
        r = kv_row(c, "Manual speed", &s_fan_lbl);
        lv_label_set_text_fmt(s_fan_lbl, "PWM %d%%", si.fan_pwm > 0 ? si.fan_pwm * 100 / 255 : 0);
        s_fan_slider = lv_slider_create(c);
        lv_obj_set_width(s_fan_slider, LV_PCT(96));
        lv_slider_set_range(s_fan_slider, 0, 255);
        lv_slider_set_value(s_fan_slider, si.fan_pwm > 0 ? si.fan_pwm : 0, LV_ANIM_OFF);
        if (autofan) lv_obj_add_state(s_fan_slider, LV_STATE_DISABLED);
        lv_obj_add_event_cb(s_fan_slider, fan_slider, LV_EVENT_VALUE_CHANGED, NULL);
    }

    c = desk_card(parent, "System");
    lv_obj_set_size(c, LV_PCT(49), LV_PCT(100));
    char buf[256], txt[400];
    sysinfo_read_file("/proc/version", buf, sizeof(buf));
    char *sp = strstr(buf, " (");
    if (sp) *sp = 0;
    snprintf(txt, sizeof(txt), "%s\nLVGL %d.%d.%d, 800x480 RGB565 fbdev\nAE350 A25 800 MHz, 1 GB DDR3-800\nInput: %s",
             buf, LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR, LVGL_VERSION_PATCH, input_status());
    l = lv_label_create(c);
    lv_label_set_text(l, txt);
    lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(l, LV_PCT(100));

    lv_obj_t *row = lv_obj_create(c);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_style_pad_gap(row, 8, 0);
    lv_obj_t *b = lv_button_create(row);
    lv_obj_add_event_cb(b, exit_click, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_REFRESH " Restart desktop");
    b = lv_button_create(row);
    lv_obj_set_style_bg_color(b, lv_palette_main(LV_PALETTE_ORANGE), 0);
    lv_obj_add_event_cb(b, power_ask, LV_EVENT_CLICKED, (void *)(intptr_t)1);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_LOOP " Reboot");
    b = lv_button_create(row);
    lv_obj_set_style_bg_color(b, lv_palette_main(LV_PALETTE_RED), 0);
    lv_obj_add_event_cb(b, power_ask, LV_EVENT_CLICKED, (void *)(intptr_t)2);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_POWER " Power off");
}

/* ====================================================================== */
/* LVGL demos on their own screen with a floating Back button              */
/* ====================================================================== */

void panel_about(lv_obj_t *parent)
{
    lv_obj_t *c = desk_card(parent, "Tang Mega 138K Pro Dock - AE350 Linux");
    lv_obj_set_size(c, LV_PCT(100), LV_PCT(100));
    lv_obj_t *l = lv_label_create(c);
    lv_obj_set_width(l, LV_PCT(100));
    lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
    lv_label_set_text_fmt(l,
        "Gowin GW5AST-138B FPGA with the hard Andes AE350 RISC-V SoC (A25 core, 800 MHz,\n"
        "L1 caches only) running Linux 6.12 (rv32, single hart, soft atomics) from SPI flash.\n\n"
        "Gateware in this project, on the SoC's AHB/APB extension ports:\n"
        LV_SYMBOL_BULLET " DDR3 bridge: 1 GB, 256-bit datapath, a read port for the LCD\n"
        LV_SYMBOL_BULLET " LCD core: RGB565 / YUV 4:2:0 scan-out, scaler, ARGB8888 OSD layer\n"
        LV_SYMBOL_BULLET " hardware JPEG decoder: Huffman decoding, IDCT, frame assembly\n"
        LV_SYMBOL_BULLET " gigabit Ethernet DMA, microSD host with DMA, PT8211 audio with DMA\n"
        LV_SYMBOL_BULLET " die temperature and supply sensors, fan control, board EEPROM\n\n"
        "This desktop: LVGL %d.%d.%d on /dev/fb0, software rendering. Mouse and keyboard\n"
        "come from the PC over Ethernet (src/apps/desktop/host/netinput.py).\n\n"
        "Source: github.com/phoenix367/tang-mega-138K-Pro-demo",
        LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR, LVGL_VERSION_PATCH);
}

/* ====================================================================== */
/* Date & Time: set the clock and the time zone                           */
/* ====================================================================== */
/* Zones come from the slim tzdata subset in /usr/share/zoneinfo (zone1970.tab
 * lists them). Applying a zone copies its TZif file to /etc/localtime (what
 * musl reads in every new process), points this process's TZ at it and saves
 * the name on the SD card when one is mounted: the rootfs is an initramfs, so
 * nothing else survives a reboot. The clock is set with clock_settime(). */
#define ZONEINFO  "/usr/share/zoneinfo"
#define TZ_NAME   "/etc/timezone"             /* name of the zone in /etc/localtime */
#define TZ_SAVE   "/mnt/sd/ae350/timezone"    /* persisted copy (SD card, legacy) */

static char **s_zones;
static int s_nzones;

static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void zones_load(void)
{
    if (s_zones) return;
    int cap = 400;
    s_zones = malloc(cap * sizeof(char *));
    s_zones[s_nzones++] = strdup("Etc/UTC");
    FILE *f = fopen(ZONEINFO "/zone1970.tab", "r");
    char line[512];
    while (f && fgets(line, sizeof(line), f)) {
        if (line[0] == '#') continue;
        char *save = NULL, *col = strtok_r(line, "\t", &save);
        col = col ? strtok_r(NULL, "\t", &save) : NULL;
        col = col ? strtok_r(NULL, "\t\n", &save) : NULL;
        if (!col || !*col) continue;
        if (s_nzones == cap) s_zones = realloc(s_zones, (cap *= 2) * sizeof(char *));
        s_zones[s_nzones++] = strdup(col);
    }
    if (f) fclose(f);
    qsort(s_zones + 1, s_nzones - 1, sizeof(char *), cmp_str);
}

static void write_text(const char *path, const char *txt)
{
    FILE *f = fopen(path, "w");
    if (f) { fputs(txt, f); fputc('\n', f); fclose(f); }
}

/* current zone name: /etc/timezone, else UTC */
static const char *tz_current(char *buf, int len)
{
    if (sysinfo_read_file(TZ_NAME, buf, len) > 0) {
        buf[strcspn(buf, "\n")] = 0;
        if (buf[0]) return buf;
    }
    snprintf(buf, len, "Etc/UTC");
    return buf;
}

/* apply a zone system-wide; returns 0 on success */
int datetime_set_zone(const char *zone)
{
    char src[300];
    snprintf(src, sizeof(src), ZONEINFO "/%s", zone);
    FILE *in = fopen(src, "rb");
    if (!in) return -1;
    FILE *out = fopen("/etc/localtime.new", "wb");
    if (!out) { fclose(in); return -1; }
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), in)) > 0) fwrite(buf, 1, n, out);
    fclose(in); fclose(out);
    if (rename("/etc/localtime.new", "/etc/localtime")) return -1;
    write_text(TZ_NAME, zone);
    setenv("TZ", zone, 1);     /* musl re-reads the zone when the TZ string changes */
    tzset();
    /* persist: the board EEPROM through boardcfg(8) when it is there (the
     * daemon restores it at boot, S35boardcfg), else the SD card */
    if (access(BOARDCFG, X_OK) == 0) {
        char cmd[400];
        snprintf(cmd, sizeof(cmd), BOARDCFG " set tz '%s' >/dev/null 2>&1", zone);
        system(cmd);
    } else if (sd_mounted()) { mkdir("/mnt/sd/ae350", 0755); write_text(TZ_SAVE, zone); }
    return 0;
}

/* at start-up: the zone saved on the SD card, if any -- only when boardcfg is
 * not managing it (then /etc/timezone is already what the EEPROM says) */
void datetime_restore(void)
{
    char z[128];
    if (access(BOARDCFG, X_OK) == 0) return;
    if (sysinfo_read_file(TZ_SAVE, z, sizeof(z)) <= 0) return;
    z[strcspn(z, "\n")] = 0;
    if (z[0] && !strstr(z, "..")) datetime_set_zone(z);
}

typedef struct {
    lv_obj_t *cal, *hour, *min, *now, *region, *city, *zone_lbl, *status, *ntp;
    lv_calendar_date_t sel;                 /* date picked on the calendar */
    char *regions;                          /* dropdown option strings */
    char *cities;
    int *city_idx;                          /* city dropdown row -> s_zones index */
    int ncity;
} dt_t;

/* the clock's source: busybox ntpd, started by /etc/init.d/S41ntp; its state
 * (key=value words) is in /run/ntp.state, kept by ntpd's event hook */
#define NTP_STATE "/run/ntp.state"
static const char *kv_word(const char *s, const char *key, char *out, size_t cap)
{
    size_t kl = strlen(key);
    for (const char *p = s; (p = strstr(p, key)); p++)
        if ((p == s || p[-1] == ' ') && p[kl] == '=') {
            size_t n = strcspn(p + kl + 1, " \n");
            if (n >= cap) n = cap - 1;
            memcpy(out, p + kl + 1, n);
            out[n] = 0;
            return out;
        }
    out[0] = 0;
    return NULL;
}

static int ntp_synced(void)
{
    char s[512], st[32];
    return sysinfo_read_file(NTP_STATE, s, sizeof(s)) > 0 && kv_word(s, "state", st, sizeof(st)) && !strcmp(st, "synced");
}

static void dt_ntp_status(dt_t *d)
{
    char s[512], st[32], srv[128], v[64], txt[256];
    lv_palette_t col = LV_PALETTE_ORANGE;
    if (sysinfo_read_file(NTP_STATE, s, sizeof(s)) <= 0) {
        snprintf(txt, sizeof(txt), "ntpd is not running (/etc/init.d/S41ntp start)");
    } else {
        kv_word(s, "state", st, sizeof(st));
        kv_word(s, "servers", srv, sizeof(srv));
        for (char *c = srv; *c; c++) if (*c == ',') *c = ' ';
        if (!strcmp(st, "off")) {
            snprintf(txt, sizeof(txt), "off (boardcfg set ntp off): set the clock on the left");
            col = LV_PALETTE_GREY;
        } else if (!strcmp(st, "synced")) {
            double off = kv_word(s, "offset", v, sizeof(v)) ? atof(v) * 1000.0 : 0;
            time_t last = kv_word(s, "last", v, sizeof(v)) ? (time_t)atoll(v) : 0;
            char stratum[16], when[32] = "?";
            kv_word(s, "stratum", stratum, sizeof(stratum));
            struct tm tm;
            if (last && localtime_r(&last, &tm)) strftime(when, sizeof(when), "%H:%M:%S", &tm);
            kv_word(s, "event", v, sizeof(v));
            if (!strcmp(v, "step") || !strcmp(stratum, "16"))      /* just stepped: the offset was the step */
                snprintf(txt, sizeof(txt), "clock set from %s at %s, refining", srv[0] ? srv : "the network", when);
            else
                snprintf(txt, sizeof(txt), "synchronized with %s: stratum %s, offset %+.1f ms, last update %s",
                         srv[0] ? srv : "the network", stratum[0] ? stratum : "?", off, when);
            col = LV_PALETTE_GREEN;
        } else if (!strcmp(st, "unsynced")) {
            snprintf(txt, sizeof(txt), "lost the server, retrying (%s)", srv);
        } else {
            snprintf(txt, sizeof(txt), "waiting for %s (no route to the internet yet?)", srv[0] ? srv : "a server");
        }
    }
    lv_label_set_text(d->ntp, txt);
    lv_obj_set_style_text_color(d->ntp, lv_palette_main(col), 0);
}

static void dt_now_tick(lv_timer_t *t)
{
    dt_t *d = lv_timer_get_user_data(t);
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char b[96];
    strftime(b, sizeof(b), "%Y-%m-%d  %H:%M:%S  %Z (UTC%z)", &tm);
    lv_label_set_text(d->now, b);
    dt_ntp_status(d);
}

static void dt_cal_changed(lv_event_t *e)
{
    dt_t *d = lv_event_get_user_data(e);
    lv_calendar_date_t p;
    if (lv_calendar_get_pressed_date(d->cal, &p) == LV_RESULT_OK) {
        d->sel = p;
        lv_calendar_set_highlighted_dates(d->cal, &d->sel, 1);
    }
}

static void dt_set_clock(lv_event_t *e)
{
    dt_t *d = lv_event_get_user_data(e);
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    tm.tm_year = d->sel.year - 1900;
    tm.tm_mon = d->sel.month - 1;
    tm.tm_mday = d->sel.day;
    tm.tm_hour = lv_roller_get_selected(d->hour);
    tm.tm_min = lv_roller_get_selected(d->min);
    tm.tm_isdst = -1;                       /* let the zone rules decide */
    time_t t = mktime(&tm);
    struct timespec ts = { .tv_sec = t, .tv_nsec = 0 };
    if (t == (time_t)-1 || clock_settime(CLOCK_REALTIME, &ts)) {
        lv_label_set_text_fmt(d->status, "clock: %s", strerror(errno));
        lv_obj_set_style_text_color(d->status, lv_palette_main(LV_PALETTE_RED), 0);
        return;
    }
    lv_calendar_set_today_date(d->cal, d->sel.year, d->sel.month, d->sel.day);
    lv_label_set_text(d->status, ntp_synced() ? "clock set; NTP will correct it at its next poll"
                                              : "clock set (not kept over a reboot: no battery RTC)");
    lv_obj_set_style_text_color(d->status, lv_palette_main(LV_PALETTE_GREEN), 0);
}

/* fill the city dropdown for the region selected in the region dropdown */
static void dt_fill_cities(dt_t *d, const char *want_zone)
{
    char region[64];
    lv_dropdown_get_selected_str(d->region, region, sizeof(region));
    size_t rl = strlen(region);
    free(d->cities); free(d->city_idx);
    d->cities = malloc(64 * s_nzones + 1); d->cities[0] = 0;
    d->city_idx = malloc(s_nzones * sizeof(int));
    d->ncity = 0;
    int sel = 0;
    char *w = d->cities;
    for (int i = 0; i < s_nzones; i++) {
        const char *z = s_zones[i];
        bool match = strncmp(z, region, rl) == 0 && z[rl] == '/';
        if (!match && strcmp(region, "UTC") == 0 && strcmp(z, "Etc/UTC") == 0) match = true;
        if (!match) continue;
        if (want_zone && strcmp(z, want_zone) == 0) sel = d->ncity;
        d->city_idx[d->ncity++] = i;
        const char *city = strchr(z, '/') ? strchr(z, '/') + 1 : z;
        if (w != d->cities) *w++ = '\n';
        for (; *city; city++) *w++ = *city == '_' ? ' ' : *city;
        *w = 0;
    }
    lv_dropdown_set_options(d->city, d->cities);
    lv_dropdown_set_selected(d->city, sel);
}

static void dt_region_changed(lv_event_t *e) { dt_fill_cities(lv_event_get_user_data(e), NULL); }

static void dt_show_zone(dt_t *d)
{
    char z[128], b[200];
    tz_current(z, sizeof(z));
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    strftime(b, sizeof(b), "%Z, UTC%z", &tm);
    lv_label_set_text_fmt(d->zone_lbl, "%s  (%s)", z, b);
}

static void dt_apply_zone(lv_event_t *e)
{
    dt_t *d = lv_event_get_user_data(e);
    int row = lv_dropdown_get_selected(d->city);
    if (row < 0 || row >= d->ncity) return;
    const char *z = s_zones[d->city_idx[row]];
    if (datetime_set_zone(z)) {
        lv_label_set_text_fmt(d->status, "zone %s: %s", z, strerror(errno));
        lv_obj_set_style_text_color(d->status, lv_palette_main(LV_PALETTE_RED), 0);
        return;
    }
    dt_show_zone(d);
    lv_label_set_text_fmt(d->status, sd_mounted() ? "zone %s applied and saved on the SD card" : "zone %s applied (no SD card: not kept over a reboot)", z);
    lv_obj_set_style_text_color(d->status, lv_palette_main(LV_PALETTE_GREEN), 0);
    /* local time changed: refresh the pickers */
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    lv_roller_set_selected(d->hour, tm.tm_hour, LV_ANIM_OFF);
    lv_roller_set_selected(d->min, tm.tm_min, LV_ANIM_OFF);
}

static void dt_free(lv_event_t *e)
{
    dt_t *d = lv_event_get_user_data(e);
    free(d->regions); free(d->cities); free(d->city_idx); free(d);
}

static lv_obj_t *dt_roller(lv_obj_t *parent, int n, int sel)
{
    char *opts = malloc(n * 3 + 1), *w = opts;
    for (int i = 0; i < n; i++) w += sprintf(w, i ? "\n%02d" : "%02d", i);
    lv_obj_t *r = lv_roller_create(parent);
    lv_roller_set_options(r, opts, LV_ROLLER_MODE_INFINITE);   /* copied */
    free(opts);
    lv_roller_set_visible_row_count(r, 3);
    lv_obj_set_style_text_font(r, &lv_font_montserrat_20, 0);
    lv_obj_set_width(r, 64);
    lv_roller_set_selected(r, sel, LV_ANIM_OFF);
    return r;
}

void panel_datetime(lv_obj_t *parent)
{
    zones_load();
    dt_t *d = calloc(1, sizeof(*d));
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(parent, 10, 0);

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    if (tm.tm_year + 1900 < 2000) { tm.tm_year = 2026 - 1900; tm.tm_mon = 0; tm.tm_mday = 1; }   /* 1970 epoch at boot */
    d->sel.year = tm.tm_year + 1900; d->sel.month = tm.tm_mon + 1; d->sel.day = tm.tm_mday;

    /* ---- left: date + time ---- */
    lv_obj_t *left = desk_card(parent, "Date and time");
    lv_obj_set_size(left, LV_PCT(54), LV_PCT(100));
    d->now = lv_label_create(left);
    lv_obj_set_style_text_font(d->now, &lv_font_montserrat_16, 0);
    d->cal = lv_calendar_create(left);
    lv_obj_set_size(d->cal, LV_PCT(100), 218);
    lv_obj_set_style_text_font(d->cal, &lv_font_montserrat_14, 0);
    lv_calendar_set_today_date(d->cal, d->sel.year, d->sel.month, d->sel.day);
    lv_calendar_set_showed_date(d->cal, d->sel.year, d->sel.month);
    lv_calendar_set_highlighted_dates(d->cal, &d->sel, 1);
    lv_calendar_add_header_arrow(d->cal);
    lv_obj_add_event_cb(d->cal, dt_cal_changed, LV_EVENT_VALUE_CHANGED, d);

    lv_obj_t *row = lv_obj_create(left);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(row, 8, 0);
    d->hour = dt_roller(row, 24, tm.tm_hour);
    lv_obj_t *colon = lv_label_create(row);
    lv_label_set_text(colon, ":");
    lv_obj_set_style_text_font(colon, &lv_font_montserrat_24, 0);
    d->min = dt_roller(row, 60, tm.tm_min);
    lv_obj_t *b = lv_button_create(row);
    lv_obj_add_event_cb(b, dt_set_clock, LV_EVENT_CLICKED, d);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_OK " Set clock");

    /* ---- right: time zone ---- */
    lv_obj_t *right = desk_card(parent, "Time zone");
    lv_obj_set_size(right, LV_PCT(45), LV_PCT(100));
    d->zone_lbl = lv_label_create(right);
    lv_obj_set_style_text_font(d->zone_lbl, &lv_font_montserrat_16, 0);
    dt_show_zone(d);

    /* regions: unique first path components, UTC first */
    d->regions = malloc(32 * s_nzones + 8);
    strcpy(d->regions, "UTC");
    char last[64] = "";
    int nreg = 1, cur_reg = 0;
    char curz[128];
    tz_current(curz, sizeof(curz));
    for (int i = 1; i < s_nzones; i++) {
        const char *sl = strchr(s_zones[i], '/');
        if (!sl) continue;
        char r[64];
        snprintf(r, sizeof(r), "%.*s", (int)(sl - s_zones[i]), s_zones[i]);
        if (strcmp(r, last)) { strcat(d->regions, "\n"); strcat(d->regions, r); strcpy(last, r); nreg++; }
        if (strncmp(curz, r, strlen(r)) == 0 && curz[strlen(r)] == '/') cur_reg = nreg - 1;
    }
    lv_obj_t *l = lv_label_create(right); lv_label_set_text(l, "Region"); lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    d->region = lv_dropdown_create(right);
    lv_obj_set_width(d->region, LV_PCT(100));
    lv_dropdown_set_options(d->region, d->regions);
    lv_dropdown_set_selected(d->region, cur_reg);
    lv_obj_add_event_cb(d->region, dt_region_changed, LV_EVENT_VALUE_CHANGED, d);
    l = lv_label_create(right); lv_label_set_text(l, "City"); lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    d->city = lv_dropdown_create(right);
    lv_obj_set_width(d->city, LV_PCT(100));
    dt_fill_cities(d, curz);
    b = lv_button_create(right);
    lv_obj_add_event_cb(b, dt_apply_zone, LV_EVENT_CLICKED, d);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_OK " Apply zone");

    d->status = lv_label_create(right);
    lv_label_set_long_mode(d->status, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(d->status, LV_PCT(100));
    lv_label_set_text(d->status, access(BOARDCFG, X_OK) == 0
        ? "The zone is kept in the board EEPROM (boardcfg)."
        : "The zone is kept only on an SD card (/mnt/sd/ae350/timezone).");
    lv_obj_set_style_text_opa(d->status, LV_OPA_70, 0);

    /* internet time: no battery RTC, so the clock comes from NTP when a server answers */
    l = lv_label_create(right);
    lv_label_set_text(l, "Internet time (NTP)");
    lv_obj_set_style_text_font(l, &lv_font_montserrat_18, 0);
    lv_obj_set_style_text_color(l, lv_palette_main(LV_PALETTE_CYAN), 0);
    lv_obj_set_style_pad_top(l, 6, 0);
    d->ntp = lv_label_create(right);
    lv_label_set_long_mode(d->ntp, LV_LABEL_LONG_WRAP);
    lv_obj_set_width(d->ntp, LV_PCT(100));

    lv_timer_t *t = lv_timer_create(dt_now_tick, 1000, d);
    lv_obj_add_event_cb(parent, timer_del_on_delete, LV_EVENT_DELETE, t);
    lv_obj_add_event_cb(parent, dt_free, LV_EVENT_DELETE, d);
    dt_now_tick(t);
}
