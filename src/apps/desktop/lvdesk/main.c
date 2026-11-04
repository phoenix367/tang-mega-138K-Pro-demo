/*
 * lvdesk -- a small LVGL desktop for the AE350 Linux board.
 *
 * Display: LVGL's Linux fbdev driver on /dev/fb0 (800x480 RGB565; the
 * gowin-lcdfb driver writes mmap()ed pages back for the video core).
 * Input:   /dev/input/event* -- the virtual mouse + keyboard that inputd
 *          creates from the network (input.c).  No local input exists.
 * VT:      the console on tty1 is switched to graphics mode and its
 *          keyboard is turned off while we run, restored on exit.
 *
 * Layout: a status bar (clock, IP, CPU, temperature, memory) over a
 * content area that shows either the home tile grid or one panel with a
 * title row and a Back button.
 */
#define _GNU_SOURCE
#include "lvdesk.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/kd.h>
#include <linux/vt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define LOCK_FILE "/run/lvdesk.lock"
#define EXIT_ALREADY_RUNNING 3   /* S70desktop stops its restart loop on this */

lv_obj_t *g_content;
lv_display_t *g_disp;

static lv_obj_t *s_bar, *s_bar_clock, *s_bar_ip, *s_bar_net_icon, *s_bar_cpu, *s_bar_temp, *s_bar_fan, *s_bar_fan_icon, *s_bar_fan_box, *s_bar_mem, *s_bar_title;
static lv_obj_t *s_home;
static bool s_dark = true;
static int s_tty_fd = -1;
static long s_tty_kbmode = -1;
static volatile int s_exit = -1;
static sysinfo_t s_si;

/* ---- tick ------------------------------------------------------------- */
static uint32_t tick_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL);
}

/* ---- single instance -------------------------------------------------- */
/* Two desktops would fight over /dev/fb0 and the input devices (it happened:
 * the supervisor loop in S70desktop restarted lvdesk after a stray killall and
 * a second "S70desktop start" added another).  An exclusive flock on a file in
 * /run makes any later copy exit at once.  The lock lives with the open file
 * description, so it is released whenever this process ends, crash included;
 * the fd is close-on-exec, so the children we spawn (wavplay, reboot, popen)
 * do not inherit it.  The pid is written for diagnostics only. */
static int single_instance(void)
{
    int fd = open(LOCK_FILE, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        fprintf(stderr, "lvdesk: cannot open %s: %s\n", LOCK_FILE, strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        char buf[32] = "";
        ssize_t n = (errno == EWOULDBLOCK) ? read(fd, buf, sizeof buf - 1) : 0;
        if (n > 0) buf[n] = '\0';
        for (char *p = buf; *p; p++) if (*p == '\n') *p = '\0';
        fprintf(stderr, "lvdesk: already running%s%s\n", *buf ? ", pid " : "", buf);
        close(fd);
        return -1;
    }
    if (ftruncate(fd, 0) == 0) {
        char buf[32];
        int n = snprintf(buf, sizeof buf, "%d\n", (int)getpid());
        if (write(fd, buf, n) < 0) { /* diagnostics only */ }
    }
    return fd;   /* kept open for the lifetime of the process */
}

/* ---- VT handling ------------------------------------------------------ */
static void tty_restore(void)
{
    if (s_tty_fd < 0) return;
    if (s_tty_kbmode >= 0) ioctl(s_tty_fd, KDSKBMODE, s_tty_kbmode);
    ioctl(s_tty_fd, KDSETMODE, KD_TEXT);
    close(s_tty_fd);
    s_tty_fd = -1;
}

static void tty_graphics(void)
{
    s_tty_fd = open("/dev/tty1", O_RDWR | O_NOCTTY);
    if (s_tty_fd < 0) { fprintf(stderr, "lvdesk: /dev/tty1: %s (fbcon may paint over us)\n", strerror(errno)); return; }
    ioctl(s_tty_fd, VT_ACTIVATE, 1);
    ioctl(s_tty_fd, VT_WAITACTIVE, 1);
    if (ioctl(s_tty_fd, KDGKBMODE, &s_tty_kbmode) < 0) s_tty_kbmode = -1;
    ioctl(s_tty_fd, KDSKBMODE, K_OFF);        /* keys must not reach the console */
    if (ioctl(s_tty_fd, KDSETMODE, KD_GRAPHICS) < 0)
        fprintf(stderr, "lvdesk: KDSETMODE: %s\n", strerror(errno));
    atexit(tty_restore);
}

static void on_signal(int sig)
{
    s_exit = 128 + sig;
}

/* ---- theme ------------------------------------------------------------ */
void desk_set_dark(bool dark)
{
    s_dark = dark;
    lv_theme_t *th = lv_theme_default_init(g_disp, lv_palette_main(LV_PALETTE_BLUE),
                                           lv_palette_main(LV_PALETTE_CYAN), dark, &lv_font_montserrat_16);
    lv_display_set_theme(g_disp, th);
    lv_obj_set_style_bg_color(lv_screen_active(), dark ? lv_color_hex(0x14181f) : lv_color_hex(0xe8ecf0), 0);
    lv_obj_set_style_bg_color(s_bar, dark ? lv_color_hex(0x1f2630) : lv_color_hex(0x2b3a4a), 0);
}

bool desk_is_dark(void) { return s_dark; }

void desk_request_exit(int code) { s_exit = code; }

/* ---- small helpers ---------------------------------------------------- */
lv_obj_t *desk_card(lv_obj_t *parent, const char *title)
{
    lv_obj_t *c = lv_obj_create(parent);
    lv_obj_set_style_pad_all(c, 10, 0);
    lv_obj_set_style_radius(c, 8, 0);
    lv_obj_set_flex_flow(c, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(c, 6, 0);
    if (title) {
        lv_obj_t *l = lv_label_create(c);
        lv_label_set_text(l, title);
        lv_obj_set_style_text_font(l, &lv_font_montserrat_18, 0);
        lv_obj_set_style_text_color(l, lv_palette_main(LV_PALETTE_CYAN), 0);
    }
    return c;
}

lv_obj_t *desk_msgbox(const char *title, const char *text)
{
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, title);
    lv_msgbox_add_text(mb, text);
    lv_msgbox_add_close_button(mb);
    lv_obj_set_width(mb, 420);
    return mb;
}

/* ---- wired-network icon ----------------------------------------------- */
/* LVGL's symbol font has Wi-Fi but no Ethernet glyph, so the icon is drawn: two
 * boxes (top-left, bottom-right) joined by a stepped cable, like GNOME's
 * network-wired-symbolic. Children: 0 cable, 1 box, 2 box, 3 red slash. */
typedef struct { lv_point_precise_t cable[4], slash[2]; } wired_pts_t;

static void wired_free(lv_event_t *e) { lv_free(lv_event_get_user_data(e)); }

lv_obj_t *desk_wired_icon(lv_obj_t *parent, int size)
{
    int w = size * 5 / 4, b = size * 9 / 20, lw = size >= 24 ? size / 8 : 2;
    wired_pts_t *p = lv_malloc(sizeof(*p));
    p->cable[0] = (lv_point_precise_t){ b / 2, b / 2 };
    p->cable[1] = (lv_point_precise_t){ w / 2, b / 2 };
    p->cable[2] = (lv_point_precise_t){ w / 2, size - b / 2 };
    p->cable[3] = (lv_point_precise_t){ w - b / 2, size - b / 2 };
    p->slash[0] = (lv_point_precise_t){ 1, size - 1 };
    p->slash[1] = (lv_point_precise_t){ w - 1, 1 };

    lv_obj_t *ic = lv_obj_create(parent);
    lv_obj_remove_style_all(ic);
    lv_obj_set_size(ic, w, size);
    lv_obj_add_event_cb(ic, wired_free, LV_EVENT_DELETE, p);

    lv_obj_t *cable = lv_line_create(ic);
    lv_line_set_points(cable, p->cable, 4);
    lv_obj_set_style_line_width(cable, lw, 0);
    lv_obj_set_style_line_rounded(cable, true, 0);
    for (int i = 0; i < 2; i++) {
        lv_obj_t *box = lv_obj_create(ic);
        lv_obj_remove_style_all(box);
        lv_obj_set_size(box, b, b);
        lv_obj_set_pos(box, i ? w - b : 0, i ? size - b : 0);
        lv_obj_set_style_radius(box, b / 4, 0);
        lv_obj_set_style_bg_opa(box, LV_OPA_COVER, 0);
    }
    lv_obj_t *slash = lv_line_create(ic);
    lv_line_set_points(slash, p->slash, 2);
    lv_obj_set_style_line_width(slash, lw, 0);
    lv_obj_set_style_line_rounded(slash, true, 0);
    lv_obj_set_style_line_color(slash, lv_palette_main(LV_PALETTE_RED), 0);
    desk_wired_icon_set(ic, -1);
    return ic;
}

void desk_wired_icon_set(lv_obj_t *icon, int state)
{
    lv_color_t c = state == 1 ? lv_color_white() : lv_palette_lighten(LV_PALETTE_GREY, 1);
    lv_obj_set_style_line_color(lv_obj_get_child(icon, 0), c, 0);
    lv_obj_set_style_bg_color(lv_obj_get_child(icon, 1), c, 0);
    lv_obj_set_style_bg_color(lv_obj_get_child(icon, 2), c, 0);
    lv_obj_t *slash = lv_obj_get_child(icon, 3);
    if (state == 0) lv_obj_remove_flag(slash, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(slash, LV_OBJ_FLAG_HIDDEN);
}

/* ---- fan icon --------------------------------------------------------- */
/* Three blade arcs around a hub (children 0..2 arcs, 3 hub). Static: white
 * while the fan turns, red when it should but does not. */
#define FAN_BLADES 3

lv_obj_t *desk_fan_icon(lv_obj_t *parent, int size)
{
    lv_obj_t *ic = lv_obj_create(parent);
    lv_obj_remove_style_all(ic);
    lv_obj_set_size(ic, size, size);
    for (int i = 0; i < FAN_BLADES; i++) {
        lv_obj_t *a = lv_arc_create(ic);
        lv_obj_remove_style_all(a);
        lv_obj_set_size(a, size, size);
        lv_obj_center(a);
        lv_obj_remove_flag(a, LV_OBJ_FLAG_CLICKABLE);
        lv_arc_set_bg_angles(a, i * 120, i * 120 + 75);
        lv_arc_set_value(a, 0);                               /* no indicator arc */
        lv_obj_set_style_arc_width(a, size * 7 / 20, LV_PART_MAIN);
        lv_obj_set_style_arc_rounded(a, false, LV_PART_MAIN);
        lv_obj_set_style_arc_opa(a, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_set_style_arc_opa(a, LV_OPA_TRANSP, LV_PART_INDICATOR);
        lv_obj_set_style_bg_opa(a, LV_OPA_TRANSP, LV_PART_KNOB);
    }
    lv_obj_t *hub = lv_obj_create(ic);
    lv_obj_remove_style_all(hub);
    lv_obj_set_size(hub, size * 3 / 10, size * 3 / 10);
    lv_obj_center(hub);
    lv_obj_set_style_radius(hub, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_opa(hub, LV_OPA_COVER, 0);
    desk_fan_icon_set(ic, 0);
    return ic;
}

void desk_fan_icon_set(lv_obj_t *icon, int rpm)
{
    lv_color_t c = rpm > 0 ? lv_color_white() : lv_palette_main(LV_PALETTE_RED);
    for (int i = 0; i < FAN_BLADES; i++) lv_obj_set_style_arc_color(lv_obj_get_child(icon, i), c, LV_PART_MAIN);
    lv_obj_set_style_bg_color(lv_obj_get_child(icon, FAN_BLADES), c, 0);
}

/* ---- clock icon (tile) ------------------------------------------------ */
/* a ring with an hour hand at 2 and a minute hand at 12, white */
typedef struct { lv_point_precise_t hour[2], min[2]; } clock_pts_t;
static void clock_free(lv_event_t *e) { lv_free(lv_event_get_user_data(e)); }

lv_obj_t *desk_clock_icon(lv_obj_t *parent, int size)
{
    int lw = size >= 24 ? size / 9 : 2, c = size / 2;
    clock_pts_t *p = lv_malloc(sizeof(*p));
    p->hour[0] = (lv_point_precise_t){ c, c };
    p->hour[1] = (lv_point_precise_t){ c + size * 22 / 100, c - size * 13 / 100 };
    p->min[0] = (lv_point_precise_t){ c, c };
    p->min[1] = (lv_point_precise_t){ c, c - size * 32 / 100 };
    lv_obj_t *ic = lv_obj_create(parent);
    lv_obj_remove_style_all(ic);
    lv_obj_set_size(ic, size, size);
    lv_obj_set_style_radius(ic, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(ic, lw, 0);
    lv_obj_set_style_border_color(ic, lv_color_white(), 0);
    lv_obj_add_event_cb(ic, clock_free, LV_EVENT_DELETE, p);
    lv_obj_t *h = lv_line_create(ic);
    lv_line_set_points(h, p->hour, 2);
    lv_obj_t *m = lv_line_create(ic);
    lv_line_set_points(m, p->min, 2);
    for (lv_obj_t *l = h;; l = m) {
        lv_obj_set_style_line_width(l, lw, 0);
        lv_obj_set_style_line_rounded(l, true, 0);
        lv_obj_set_style_line_color(l, lv_color_white(), 0);
        if (l == m) break;
    }
    return ic;
}

/* ---- status bar ------------------------------------------------------- */
/* follow /etc/timezone (written by the Date & Time panel, or by hand) so this
 * process's clock never disagrees with `date` in a shell */
static void tz_follow(void)
{
    static char cur[128] = "";
    char z[128] = "";
    if (sysinfo_read_file("/etc/timezone", z, sizeof(z)) > 0) z[strcspn(z, "\n")] = 0;
    if (strcmp(z, cur) == 0) return;
    strcpy(cur, z);
    if (z[0]) setenv("TZ", z, 1); else unsetenv("TZ");
    tzset();
}

static void bar_update(lv_timer_t *t)
{
    (void)t;
    sysinfo_sample(&s_si);
    tz_follow();
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    /* date and HH:MM; the label is only touched when the minute changes (no redraw per second) */
    char mon[8], clk[32];
    strftime(mon, sizeof(mon), "%b", &tm);
    snprintf(clk, sizeof(clk), "%d %s  %02d:%02d", tm.tm_mday, mon, tm.tm_hour, tm.tm_min);
    if (strcmp(clk, lv_label_get_text(s_bar_clock))) lv_label_set_text(s_bar_clock, clk);
    /* the IP stays configured when the cable is pulled: show the link, not the address */
    desk_wired_icon_set(s_bar_net_icon, s_si.carrier);
    if (s_si.carrier == 0) {
        lv_label_set_text(s_bar_ip, "no link");
        lv_obj_set_style_text_color(s_bar_ip, lv_palette_lighten(LV_PALETTE_GREY, 1), 0);
    } else {
        lv_label_set_text(s_bar_ip, s_si.ip[0] ? s_si.ip : "no ip");
        lv_obj_set_style_text_color(s_bar_ip, lv_color_white(), 0);
    }
    lv_label_set_text_fmt(s_bar_cpu, "CPU %d%%", s_si.cpu_pct);
    if (s_si.temp_mc != INT32_MIN)
        lv_label_set_text_fmt(s_bar_temp, "%d.%d" "\xC2\xB0" "C", s_si.temp_mc / 1000, (abs(s_si.temp_mc) % 1000) / 100);
    else
        lv_label_set_text(s_bar_temp, "");
    lv_label_set_text_fmt(s_bar_mem, "%lu MB free", s_si.mem_avail_kb / 1024);
    /* fan: tacho rpm; red warning when the fan should turn but gives no pulses */
    if (!s_si.fan_present) {
        lv_obj_add_flag(s_bar_fan_box, LV_OBJ_FLAG_HIDDEN);
        desk_fan_icon_set(s_bar_fan_icon, 0);
    } else if (s_si.fan_fault || s_si.fan_rpm <= 0) {
        lv_obj_remove_flag(s_bar_fan_box, LV_OBJ_FLAG_HIDDEN);
        desk_fan_icon_set(s_bar_fan_icon, 0);
        lv_label_set_text(s_bar_fan, "FAN STOPPED");
        lv_obj_set_style_text_color(s_bar_fan, lv_palette_main(LV_PALETTE_RED), 0);
    } else {
        lv_obj_remove_flag(s_bar_fan_box, LV_OBJ_FLAG_HIDDEN);
        desk_fan_icon_set(s_bar_fan_icon, s_si.fan_rpm);
        lv_label_set_text_fmt(s_bar_fan, "%d rpm", s_si.fan_rpm);
        lv_obj_set_style_text_color(s_bar_fan, lv_color_white(), 0);
    }
}

static lv_obj_t *bar_label(const char *txt)
{
    lv_obj_t *l = lv_label_create(s_bar);
    lv_label_set_text(l, txt);
    lv_obj_set_style_text_color(l, lv_color_white(), 0);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    return l;
}

static void bar_create(lv_obj_t *scr)
{
    s_bar = lv_obj_create(scr);
    lv_obj_remove_style_all(s_bar);
    lv_obj_set_size(s_bar, SCR_W, BAR_H);
    lv_obj_set_pos(s_bar, 0, 0);
    lv_obj_set_style_bg_opa(s_bar, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_hor(s_bar, 12, 0);
    lv_obj_set_flex_flow(s_bar, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_bar, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(s_bar, 14, 0);

    s_bar_title = bar_label(LV_SYMBOL_HOME " AE350");
    lv_obj_set_style_text_font(s_bar_title, &lv_font_montserrat_18, 0);
    lv_obj_set_clickable(s_bar_title, true);
    lv_obj_add_event_cb(s_bar_title, (lv_event_cb_t)desk_go_home, LV_EVENT_CLICKED, NULL);
    /* network: wired icon + address / "no link" */
    lv_obj_t *net = lv_obj_create(s_bar);
    lv_obj_remove_style_all(net);
    lv_obj_set_size(net, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(net, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(net, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(net, 6, 0);
    s_bar_net_icon = desk_wired_icon(net, 16);
    s_bar_ip = lv_label_create(net);
    lv_label_set_text(s_bar_ip, "");
    lv_obj_set_style_text_color(s_bar_ip, lv_color_white(), 0);
    lv_obj_set_style_text_font(s_bar_ip, &lv_font_montserrat_16, 0);
    s_bar_cpu = bar_label("");
    s_bar_temp = bar_label("");
    /* fan: icon + rpm (hidden when there is no fan hwmon device) */
    s_bar_fan_box = lv_obj_create(s_bar);
    lv_obj_remove_style_all(s_bar_fan_box);
    lv_obj_set_size(s_bar_fan_box, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(s_bar_fan_box, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_bar_fan_box, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(s_bar_fan_box, 6, 0);
    s_bar_fan_icon = desk_fan_icon(s_bar_fan_box, 16);
    s_bar_fan = lv_label_create(s_bar_fan_box);
    lv_label_set_text(s_bar_fan, "");
    lv_obj_set_style_text_color(s_bar_fan, lv_color_white(), 0);
    lv_obj_set_style_text_font(s_bar_fan, &lv_font_montserrat_16, 0);
    s_bar_mem = bar_label("");
    lv_obj_set_flex_grow(s_bar_mem, 1);
    /* it gets what the row leaves: one line, clipped, never wrapped under the bar */
    lv_label_set_long_mode(s_bar_mem, LV_LABEL_LONG_MODE_CLIP);
    s_bar_clock = bar_label("");
    lv_obj_set_style_text_font(s_bar_clock, &lv_font_montserrat_18, 0);

    lv_timer_create(bar_update, 1000, NULL);
    bar_update(NULL);
}

/* ---- home screen: tile grid ------------------------------------------- */
typedef struct {
    const char *icon, *name;                 /* icon: symbol text, or NULL to use icon_fn */
    void (*build)(lv_obj_t *);
    void (*action)(void);
    uint32_t color;
    lv_obj_t *(*icon_fn)(lv_obj_t *parent, int size);
} tile_t;

static const tile_t s_tiles[] = {
    { LV_SYMBOL_CHARGE,   "System",      panel_sysmon,   NULL, 0x3b82f6, NULL },
    { LV_SYMBOL_DIRECTORY,"Files",       panel_files,    NULL, 0xf59e0b, NULL },
    { LV_SYMBOL_AUDIO,    "Audio",       panel_audio,    NULL, 0x10b981, NULL },
    { NULL,               "Network",     panel_network,  NULL, 0x8b5cf6, desk_wired_icon },
    { LV_SYMBOL_KEYBOARD, "Console",     panel_console,  NULL, 0x64748b, NULL },
    { LV_SYMBOL_SETTINGS, "Settings",    panel_settings, NULL, 0xef4444, NULL },
    { NULL,               "Date & Time", panel_datetime, NULL, 0xec4899, desk_clock_icon },
    { LV_SYMBOL_LIST,     "About",       panel_about,    NULL, 0x0ea5e9, NULL },
};

static void tile_click(lv_event_t *e)
{
    const tile_t *t = lv_event_get_user_data(e);
    if (t->build) desk_open_panel(t->name, t->build);
    else if (t->action) t->action();
}

static void home_create(void)
{
    s_home = lv_obj_create(g_content);
    lv_obj_remove_style_all(s_home);
    lv_obj_set_size(s_home, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_pad_all(s_home, 18, 0);
    lv_obj_set_style_pad_gap(s_home, 16, 0);
    lv_obj_set_flex_flow(s_home, LV_FLEX_FLOW_ROW_WRAP);
    lv_obj_set_flex_align(s_home, LV_FLEX_ALIGN_SPACE_EVENLY, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_SPACE_EVENLY);

    for (unsigned i = 0; i < sizeof(s_tiles) / sizeof(s_tiles[0]); i++) {
        const tile_t *t = &s_tiles[i];
        lv_obj_t *b = lv_button_create(s_home);
        lv_obj_set_size(b, 168, 170);
        lv_obj_set_style_radius(b, 14, 0);
        lv_obj_set_style_bg_color(b, lv_color_hex(t->color), 0);
        lv_obj_set_style_bg_color(b, lv_color_lighten(lv_color_hex(t->color), 40), LV_STATE_PRESSED);
        lv_obj_set_style_shadow_width(b, 12, 0);
        lv_obj_set_style_shadow_opa(b, LV_OPA_30, 0);
        lv_obj_add_event_cb(b, tile_click, LV_EVENT_CLICKED, (void *)t);

        lv_obj_t *ic;
        if (t->icon) {
            ic = lv_label_create(b);
            lv_label_set_text(ic, t->icon);
            lv_obj_set_style_text_font(ic, &lv_font_montserrat_32, 0);
            lv_obj_set_style_text_color(ic, lv_color_white(), 0);
        } else {
            ic = t->icon_fn(b, 34);
            if (t->icon_fn == desk_wired_icon) desk_wired_icon_set(ic, 1);
        }
        lv_obj_align(ic, LV_ALIGN_CENTER, 0, -22);

        lv_obj_t *nm = lv_label_create(b);
        lv_label_set_text(nm, t->name);
        lv_obj_set_style_text_font(nm, &lv_font_montserrat_20, 0);
        lv_obj_set_style_text_color(nm, lv_color_white(), 0);
        lv_obj_align(nm, LV_ALIGN_BOTTOM_MID, 0, -6);
    }
}

void desk_go_home(void)
{
    lv_obj_clean(g_content);
    home_create();
    lv_label_set_text(s_bar_title, LV_SYMBOL_HOME " AE350");
}

static void back_click(lv_event_t *e) { (void)e; desk_go_home(); }

void desk_open_panel(const char *title, void (*build)(lv_obj_t *parent))
{
    lv_obj_clean(g_content);
    lv_label_set_text_fmt(s_bar_title, LV_SYMBOL_LEFT " %s", title);

    lv_obj_t *p = lv_obj_create(g_content);
    lv_obj_remove_style_all(p);
    lv_obj_set_size(p, LV_PCT(100), LV_PCT(100));
    lv_obj_set_style_pad_all(p, 10, 0);
    lv_obj_set_flex_flow(p, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(p, 8, 0);

    lv_obj_t *hdr = lv_obj_create(p);
    lv_obj_remove_style_all(hdr);
    lv_obj_set_size(hdr, LV_PCT(100), 40);
    lv_obj_set_flex_flow(hdr, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(hdr, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(hdr, 12, 0);

    lv_obj_t *back = lv_button_create(hdr);
    lv_obj_add_event_cb(back, back_click, LV_EVENT_CLICKED, NULL);
    lv_obj_t *bl = lv_label_create(back);
    lv_label_set_text(bl, LV_SYMBOL_LEFT " Back");
    lv_obj_t *tl = lv_label_create(hdr);
    lv_label_set_text(tl, title);
    lv_obj_set_style_text_font(tl, &lv_font_montserrat_24, 0);

    lv_obj_t *body = lv_obj_create(p);
    lv_obj_remove_style_all(body);
    lv_obj_set_width(body, LV_PCT(100));
    lv_obj_set_flex_grow(body, 1);
    build(body);
}

/* ---- main ------------------------------------------------------------- */
int main(int argc, char **argv)
{
    const char *fb = "/dev/fb0", *panel = NULL;
    bool use_tty = true;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-f") && i + 1 < argc) fb = argv[++i];
        else if (!strcmp(argv[i], "-p") && i + 1 < argc) panel = argv[++i];   /* open a panel at start */
        else if (!strcmp(argv[i], "-T")) use_tty = false;      /* leave the VT alone (debug) */
        else { fprintf(stderr, "usage: lvdesk [-f /dev/fbN] [-p panel] [-T]\n"); return 2; }
    }
    if (single_instance() < 0) return EXIT_ALREADY_RUNNING;
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGCHLD, SIG_DFL);

    lv_init();
    lv_tick_set_cb(tick_ms);

    g_disp = lv_linux_fbdev_create();
    if (g_disp) lv_linux_fbdev_set_skip_unblank(g_disp, true);   /* gowin-lcdfb has no blanking */
    if (!g_disp || lv_linux_fbdev_set_file(g_disp, fb) != LV_RESULT_OK) {
        fprintf(stderr, "lvdesk: cannot open %s\n", fb);
        return 1;
    }
    if (use_tty) tty_graphics();
#if LV_USE_PERF_MONITOR
    lv_sysmon_hide_performance(g_disp);
#endif

    lv_group_t *grp = lv_group_create();
    lv_group_set_default(grp);
    input_init(g_disp);

    lv_obj_t *scr = lv_screen_active();
    lv_obj_remove_style_all(scr);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
    datetime_restore();            /* time zone saved on the SD card, before the clock shows */
    bar_create(scr);
    desk_set_dark(true);

    g_content = lv_obj_create(scr);
    lv_obj_remove_style_all(g_content);
    lv_obj_set_pos(g_content, 0, BAR_H);
    lv_obj_set_size(g_content, SCR_W, SCR_H - BAR_H);
    home_create();
    if (panel) {
        for (unsigned i = 0; i < sizeof(s_tiles) / sizeof(s_tiles[0]); i++)
            if (!strcasecmp(s_tiles[i].name, panel)) {
                if (s_tiles[i].build) desk_open_panel(s_tiles[i].name, s_tiles[i].build);
                else if (s_tiles[i].action) s_tiles[i].action();
            }
    }

    printf("lvdesk: LVGL %d.%d.%d on %s, input: %s\n", LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR,
           LVGL_VERSION_PATCH, fb, input_status());
    fflush(stdout);

    while (s_exit < 0) {
        if (video_active()) { video_wait(); continue; }   /* the player gets the CPU */
        uint32_t wait = lv_timer_handler();
        if (wait > 30) wait = 30;
        if (wait < 2) wait = 2;
        usleep(wait * 1000);
    }
    tty_restore();
    return s_exit > 128 ? 0 : s_exit;
}
