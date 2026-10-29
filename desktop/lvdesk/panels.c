/* panels.c -- the desktop's panels. Each build function fills `parent`
 * (the area under the panel header); timers created here are deleted when
 * their objects go (LV_EVENT_DELETE), so leaving a panel is just lv_obj_clean. */
#define _GNU_SOURCE
#include "lvdesk.h"
#include "demos/lv_demos.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void timer_del_on_delete(lv_event_t *e)
{
    lv_timer_delete(lv_event_get_user_data(e));
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
/* Files                                                                   */
/* ====================================================================== */
static void file_clicked(lv_event_t *e)
{
    lv_obj_t *fe = lv_event_get_target(e);
    const char *dir = lv_file_explorer_get_current_path(fe);   /* "A:/path/" */
    const char *name = lv_file_explorer_get_selected_file_name(fe);
    if (!dir || !name || !name[0]) return;
    char path[512];
    snprintf(path, sizeof(path), "%s%s", dir + 2, name);          /* strip the "A:" */
    struct stat st;
    if (stat(path, &st)) return;
    size_t l = strlen(name);
    if (l > 4 && !strcasecmp(name + l - 4, ".wav")) {
        audio_play_file(path);
        char msg[600];
        snprintf(msg, sizeof(msg), "Playing %s\n(%ld KB)", path, (long)(st.st_size / 1024));
        desk_msgbox("Audio", msg);
        return;
    }
    /* text preview for small files */
    char *buf = malloc(4096);
    int n = sysinfo_read_file(path, buf, 4096);
    int printable = 1;
    for (int i = 0; i < n && i < 512; i++)
        if ((unsigned char)buf[i] < 9 || ((unsigned char)buf[i] > 13 && (unsigned char)buf[i] < 32)) { printable = 0; break; }
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, name);
    lv_msgbox_add_close_button(mb);
    if (n > 0 && printable) {
        lv_obj_t *ta = lv_textarea_create(lv_msgbox_get_content(mb));
        lv_obj_set_size(ta, LV_PCT(100), 300);
        lv_obj_set_style_text_font(ta, &lv_font_unscii_8, 0);
        lv_textarea_set_text(ta, buf);
        lv_obj_set_width(mb, 700);
    } else {
        lv_msgbox_add_text_fmt(mb, "%s\n%ld bytes, mode %o", path, (long)st.st_size, st.st_mode & 07777);
        lv_obj_set_width(mb, 420);
    }
    free(buf);
}

/* the quick-access lists are built from plain buttons with their own light
 * colours: recolour everything below `obj` except the section headers */
static void restyle_tree(lv_obj_t *obj, lv_color_t bg, lv_color_t fg)
{
    if (!obj) return;
    if (lv_obj_check_type(obj, &lv_label_class)) lv_obj_set_style_text_color(obj, fg, 0);
    else lv_obj_set_style_bg_color(obj, bg, 0);
    for (uint32_t i = 0; i < lv_obj_get_child_count(obj); i++) restyle_tree(lv_obj_get_child(obj, i), bg, fg);
}

/* rename a quick-access entry (the explorer's labels are fixed) */
static void relabel_tree(lv_obj_t *obj, const char *from, const char *to)
{
    if (!obj) return;
    if (lv_obj_check_type(obj, &lv_label_class) && strstr(lv_label_get_text(obj), from))
        lv_label_set_text(obj, to);
    for (uint32_t i = 0; i < lv_obj_get_child_count(obj); i++) relabel_tree(lv_obj_get_child(obj, i), from, to);
}

void panel_files(lv_obj_t *parent)
{
    lv_obj_t *fe = lv_file_explorer_create(parent);
    lv_obj_set_size(fe, LV_PCT(100), LV_PCT(100));
    lv_file_explorer_set_sort(fe, LV_EXPLORER_SORT_KIND);
    lv_file_explorer_set_quick_access_path(fe, LV_EXPLORER_HOME_DIR, "A:/home/ae350");
    lv_file_explorer_set_quick_access_path(fe, LV_EXPLORER_MUSIC_DIR, "A:/tmp");
    lv_file_explorer_set_quick_access_path(fe, LV_EXPLORER_DOCS_DIR, "A:/etc");
    lv_file_explorer_set_quick_access_path(fe, LV_EXPLORER_VIDEO_DIR, "A:/mnt/sd");   /* microSD (S45sdcard) */
    lv_file_explorer_set_quick_access_path(fe, LV_EXPLORER_FS_DIR, "A:/");
    lv_file_explorer_open_dir(fe, "A:/home/ae350");
    lv_obj_add_event_cb(fe, file_clicked, LV_EVENT_VALUE_CHANGED, NULL);

    /* the explorer hard-codes a light palette; follow the desktop theme */
    lv_color_t bg = desk_is_dark() ? lv_color_hex(0x1e242c) : lv_color_hex(0xf4f6f8);
    lv_color_t bg2 = desk_is_dark() ? lv_color_hex(0x262d36) : lv_color_white();
    lv_color_t fg = desk_is_dark() ? lv_color_white() : lv_color_black();
    lv_obj_t *parts[] = { lv_file_explorer_get_quick_access_area(fe), lv_file_explorer_get_places_list(fe),
                          lv_file_explorer_get_device_list(fe), lv_file_explorer_get_file_table(fe),
                          lv_file_explorer_get_header(fe), fe };
    for (unsigned i = 0; i < sizeof(parts) / sizeof(parts[0]); i++) {
        if (!parts[i]) continue;
        lv_obj_set_style_bg_color(parts[i], i == 3 ? bg2 : bg, 0);
        lv_obj_set_style_text_color(parts[i], fg, 0);
    }
    lv_obj_set_style_text_color(lv_file_explorer_get_file_table(fe), fg, LV_PART_ITEMS);
    lv_obj_set_style_bg_color(lv_file_explorer_get_file_table(fe), bg2, LV_PART_ITEMS);
    lv_obj_set_style_text_color(lv_file_explorer_get_path_label(fe), fg, 0);
    restyle_tree(lv_file_explorer_get_quick_access_area(fe), bg, fg);
    relabel_tree(lv_file_explorer_get_quick_access_area(fe), "Video", LV_SYMBOL_SD_CARD " SD card");
}

/* ====================================================================== */
/* Network                                                                 */
/* ====================================================================== */
typedef struct {
    lv_obj_t *chart, *ip, *mac, *link, *rx, *tx;
    lv_chart_series_t *rx_ser, *tx_ser;
    unsigned long long p_rx, p_tx;
    uint32_t p_tick;
    sysinfo_t si;
} net_t;

static void net_tick(lv_timer_t *t)
{
    net_t *n = lv_timer_get_user_data(t);
    sysinfo_sample(&n->si);
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
    lv_label_set_text_fmt(n->ip, "%s / 24", n->si.ip[0] ? n->si.ip : "none");
    lv_label_set_text(n->mac, n->si.mac);
    if (n->si.link_speed > 0) lv_label_set_text_fmt(n->link, "%s, %d Mbit/s", n->si.operstate, n->si.link_speed);
    else lv_label_set_text(n->link, n->si.operstate);
}

static void net_free(lv_event_t *e) { free(lv_event_get_user_data(e)); }

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
    kv_row(right, "IPv4", &n->ip);
    kv_row(right, "MAC", &n->mac);
    kv_row(right, "Link", &n->link);
    lv_obj_t *l = lv_label_create(right); lv_label_set_text(l, "Received"); lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    n->rx = lv_label_create(right);
    l = lv_label_create(right); lv_label_set_text(l, "Sent"); lv_obj_set_style_text_opa(l, LV_OPA_70, 0);
    n->tx = lv_label_create(right);
    l = lv_label_create(right);
    lv_label_set_text(l, "\nInput bridge: inputd on tcp/5555\nPC side: desktop/host/netinput.py");
    lv_obj_set_style_text_opa(l, LV_OPA_70, 0);

    lv_timer_t *t = lv_timer_create(net_tick, 1000, n);
    lv_obj_add_event_cb(parent, timer_del_on_delete, LV_EVENT_DELETE, t);
    lv_obj_add_event_cb(parent, net_free, LV_EVENT_DELETE, n);
    net_tick(t);
}

/* ====================================================================== */
/* Console: run a shell command, show its output; dmesg tail by default    */
/* ====================================================================== */
static lv_obj_t *s_con_out, *s_con_in;

static void console_run(const char *cmd)
{
    char *out = malloc(16384);
    char full[600];
    snprintf(full, sizeof(full), "%s 2>&1 | tail -n 60", cmd);
    sysinfo_run(full, out, 16384);
    char *txt = malloc(16384 + 600);
    snprintf(txt, 16384 + 600, "# %s\n%s", cmd, out);
    lv_textarea_set_text(s_con_out, txt);
    lv_textarea_set_cursor_pos(s_con_out, LV_TEXTAREA_CURSOR_LAST);
    free(out);
    free(txt);
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

static void console_gone(lv_event_t *e) { (void)e; s_con_out = s_con_in = NULL; }

void panel_console(lv_obj_t *parent)
{
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(parent, 6, 0);

    lv_obj_t *row = lv_obj_create(parent);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(row, 6, 0);
    static const char *quick[] = { "dmesg | tail -n 30", "ps", "free", "df -h", "ifconfig eth0", "cat /proc/interrupts", "cat /proc/cpuinfo" };
    static const char *names[] = { "dmesg", "ps", "free", "df", "ifconfig", "irqs", "cpuinfo" };
    for (unsigned i = 0; i < sizeof(quick) / sizeof(quick[0]); i++) {
        lv_obj_t *b = lv_button_create(row);
        lv_obj_set_style_pad_ver(b, 6, 0);
        lv_obj_add_event_cb(b, console_btn, LV_EVENT_CLICKED, (void *)quick[i]);
        lv_label_set_text(lv_label_create(b), names[i]);
    }

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
    lv_textarea_set_placeholder_text(s_con_in, "shell command (as root), Enter to run");
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
static lv_obj_t *s_desk_scr;

static void demo_scr_deleted(lv_event_t *e)
{
    lv_obj_t *b = lv_obj_get_user_data(lv_event_get_target(e));
    if (b) lv_obj_delete(b);
}

static void demo_back(lv_event_t *e)
{
    (void)e;
    lv_obj_t *demo_scr = lv_screen_active();
    lv_screen_load(s_desk_scr);
    lv_obj_delete_async(demo_scr);      /* we are inside the button's own event */
    desk_set_dark(desk_is_dark());      /* the demo re-initialised the default theme */
    desk_go_home();
}

static void demo_screen(void (*demo)(void))
{
    s_desk_scr = lv_screen_active();
    lv_obj_t *scr = lv_obj_create(NULL);
    lv_screen_load(scr);
    demo();
    /* the button lives on the top layer: removed when the demo screen goes */
    lv_obj_t *b = lv_button_create(lv_layer_top());
    lv_obj_align(b, LV_ALIGN_TOP_RIGHT, -6, 6);
    lv_obj_set_style_bg_color(b, lv_palette_main(LV_PALETTE_RED), 0);
    lv_obj_add_event_cb(b, demo_back, LV_EVENT_CLICKED, NULL);
    lv_label_set_text(lv_label_create(b), LV_SYMBOL_CLOSE " Exit demo");
    lv_obj_set_user_data(scr, b);
    lv_obj_add_event_cb(scr, demo_scr_deleted, LV_EVENT_DELETE, NULL);
}

void demo_widgets_start(void) { demo_screen(lv_demo_widgets); }

void panel_about(lv_obj_t *parent)
{
    lv_obj_t *c = desk_card(parent, "Tang Mega 138K Pro Dock - AE350 Linux");
    lv_obj_set_size(c, LV_PCT(100), LV_PCT(100));
    lv_obj_t *l = lv_label_create(c);
    lv_obj_set_width(l, LV_PCT(100));
    lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
    lv_label_set_text(l,
        "Gowin GW5AST-138B FPGA with the hard Andes AE350 RISC-V SoC (A25 core, 800 MHz)\n"
        "running Linux 6.12 (rv32, single hart, soft atomics) from a 16 MB SPI flash.\n\n"
        "Gateware in this project: 100 MHz AHB-to-DDR3 bridge (1 GB, 256-bit datapath),\n"
        "gigabit Ethernet with DMA, LCD scan-out from DDR3, PT8211 audio, on-die\n"
        "temperature/voltage sensors - all on the SoC's AHB/APB extension ports.\n\n"
        "This desktop: LVGL " LVGL_VERSION_INFO " on /dev/fb0, software rendering.\n"
        "Mouse and keyboard arrive from the PC over Ethernet (desktop/host/netinput.py).\n\n"
        "Source: desktop/ in the mega_138K_test repository.");
}
