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
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

lv_obj_t *g_content;
lv_display_t *g_disp;

static lv_obj_t *s_bar, *s_bar_clock, *s_bar_ip, *s_bar_cpu, *s_bar_temp, *s_bar_fan, *s_bar_mem, *s_bar_title;
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

/* ---- status bar ------------------------------------------------------- */
static void bar_update(lv_timer_t *t)
{
    (void)t;
    sysinfo_sample(&s_si);
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    lv_label_set_text_fmt(s_bar_clock, "%02d:%02d:%02d", tm.tm_hour, tm.tm_min, tm.tm_sec);
    lv_label_set_text_fmt(s_bar_ip, LV_SYMBOL_WIFI " %s", s_si.ip[0] ? s_si.ip : "no ip");
    lv_label_set_text_fmt(s_bar_cpu, "CPU %d%%", s_si.cpu_pct);
    if (s_si.temp_mc != INT32_MIN)
        lv_label_set_text_fmt(s_bar_temp, "%d.%d" "\xC2\xB0" "C", s_si.temp_mc / 1000, (abs(s_si.temp_mc) % 1000) / 100);
    else
        lv_label_set_text(s_bar_temp, "");
    lv_label_set_text_fmt(s_bar_mem, "%lu MB free", s_si.mem_avail_kb / 1024);
    /* fan: tacho rpm; red warning when the fan should turn but gives no pulses */
    if (!s_si.fan_present) {
        lv_label_set_text(s_bar_fan, "");
    } else if (s_si.fan_fault || s_si.fan_rpm <= 0) {
        lv_label_set_text(s_bar_fan, LV_SYMBOL_WARNING " FAN STOPPED");
        lv_obj_set_style_text_color(s_bar_fan, lv_palette_main(LV_PALETTE_RED), 0);
    } else {
        lv_label_set_text_fmt(s_bar_fan, LV_SYMBOL_REFRESH " %d", s_si.fan_rpm);
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
    lv_obj_set_style_pad_column(s_bar, 18, 0);

    s_bar_title = bar_label(LV_SYMBOL_HOME " AE350");
    lv_obj_set_style_text_font(s_bar_title, &lv_font_montserrat_18, 0);
    lv_obj_set_clickable(s_bar_title, true);
    lv_obj_add_event_cb(s_bar_title, (lv_event_cb_t)desk_go_home, LV_EVENT_CLICKED, NULL);
    s_bar_ip = bar_label("");
    s_bar_cpu = bar_label("");
    s_bar_temp = bar_label("");
    s_bar_fan = bar_label("");
    s_bar_mem = bar_label("");
    lv_obj_set_flex_grow(s_bar_mem, 1);
    s_bar_clock = bar_label("");
    lv_obj_set_style_text_font(s_bar_clock, &lv_font_montserrat_18, 0);

    lv_timer_create(bar_update, 1000, NULL);
    bar_update(NULL);
}

/* ---- home screen: tile grid ------------------------------------------- */
typedef struct {
    const char *icon, *name;
    void (*build)(lv_obj_t *);
    void (*action)(void);
    uint32_t color;
} tile_t;

static const tile_t s_tiles[] = {
    { LV_SYMBOL_CHARGE,   "System",    panel_sysmon,   NULL, 0x3b82f6 },
    { LV_SYMBOL_DIRECTORY,"Files",     panel_files,    NULL, 0xf59e0b },
    { LV_SYMBOL_AUDIO,    "Audio",     panel_audio,    NULL, 0x10b981 },
    { LV_SYMBOL_WIFI,     "Network",   panel_network,  NULL, 0x8b5cf6 },
    { LV_SYMBOL_KEYBOARD, "Console",   panel_console,  NULL, 0x64748b },
    { LV_SYMBOL_SETTINGS, "Settings",  panel_settings, NULL, 0xef4444 },
    { LV_SYMBOL_IMAGE,    "Widgets",   NULL, demo_widgets_start,   0xec4899 },
    { LV_SYMBOL_LIST,     "About",     panel_about,    NULL, 0x0ea5e9 },
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

        lv_obj_t *ic = lv_label_create(b);
        lv_label_set_text(ic, t->icon);
        lv_obj_set_style_text_font(ic, &lv_font_montserrat_32, 0);
        lv_obj_set_style_text_color(ic, lv_color_white(), 0);
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
        uint32_t wait = lv_timer_handler();
        if (wait > 30) wait = 30;
        if (wait < 2) wait = 2;
        usleep(wait * 1000);
    }
    tty_restore();
    return s_exit > 128 ? 0 : s_exit;
}
