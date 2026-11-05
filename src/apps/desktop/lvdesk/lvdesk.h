/* lvdesk -- LVGL desktop for the AE350 board (800x480 LCD on /dev/fb0). */
#ifndef LVDESK_H
#define LVDESK_H

#include "lvgl.h"
#include <stdbool.h>
#include <stdint.h>

#define SCR_W 800
#define SCR_H 480
#define BAR_H 36

/* main.c */
extern lv_obj_t *g_content;        /* panel area below the status bar */
extern lv_display_t *g_disp;
void desk_go_home(void);
void desk_open_panel(const char *title, void (*build)(lv_obj_t *parent));
void desk_set_dark(bool dark);
bool desk_is_dark(void);
void desk_request_exit(int code);
lv_obj_t *desk_card(lv_obj_t *parent, const char *title);
lv_obj_t *desk_msgbox(const char *title, const char *text);
/* context menus: a right click goes to the object under the pointer, then to its
 * parents, as DESK_EVENT_CONTEXT (param: lv_point_t *, the screen point) until one
 * of them calls desk_context_take().  desk_menu() pops a menu up there: items with a
 * NULL text are separators; the menu closes on a click outside it or on an item
 * (then the item's cb runs). */
extern uint32_t DESK_EVENT_CONTEXT;
void desk_context_click(int x, int y);
void desk_context_take(void);
typedef struct {
    const char *text, *hint;           /* hint: a shortcut shown on the right, or NULL */
    void (*cb)(void *ud);
    void *ud;
    bool disabled;
} desk_menu_item_t;
void desk_menu(int x, int y, const desk_menu_item_t *items, int n);
bool desk_menu_close(void);            /* true if a menu was open */
/* wired-network icon (two boxes joined by a cable, GNOME "network-wired" style);
 * state: 1 = link up (white), 0 = cable unplugged (grey + red slash), -1 = unknown (grey) */
lv_obj_t *desk_clock_icon(lv_obj_t *parent, int size);   /* tile icon: a clock face */
lv_obj_t *desk_wired_icon(lv_obj_t *parent, int size);
void desk_wired_icon_set(lv_obj_t *icon, int state);
/* fan icon (three blades around a hub); rpm > 0 = white, else red */
lv_obj_t *desk_fan_icon(lv_obj_t *parent, int size);
void desk_fan_icon_set(lv_obj_t *icon, int rpm);

/* panels.c: video playback (vidplay child owns the framebuffer while it runs; the
 * desktop does not run LVGL meanwhile, only video_wait(); any key or click stops it) */
void video_play_file(const char *path);
void video_stop(void);
bool video_active(void);
void video_wait(void);

/* input.c */
bool input_init(lv_display_t *disp);
const char *input_status(void);
void input_wait(int ms);              /* sleep until input or ms, then handle it (video playback) */
bool input_ctrl(void);                /* modifier state, for Ctrl+click / Shift+click */
bool input_shift(void);
#define DESK_KEY_F2 0xF702            /* keys LVGL has no code for (private-use code points) */
#define DESK_KEY_F5 0xF705

/* sysinfo.c */
typedef struct {
    int cpu_pct;                   /* 0..100 since the previous sample */
    unsigned long mem_total_kb, mem_avail_kb;
    double load1, load5, load15;
    long uptime_s;
    int temp_mc;                   /* die temperature, milli-C (INT32_MIN = n/a) */
    int rail_mv[8];                /* hwmon in0..in7, -1 = n/a */
    char rail_label[8][24];
    int link_speed;                /* Mbit/s, -1 = down/unknown */
    int carrier;                   /* /sys/class/net/eth0/carrier: 1 = cable + link, 0 = no link, -1 = n/a */
    char ip[20], mac[20], operstate[12];
    int prefix;                    /* IPv4 prefix length of eth0's address, 0 = none */
    unsigned long long p_busy, p_total;   /* this sampler's previous /proc/stat reading */
    unsigned long long rx_bytes, tx_bytes;
    int fan_rpm, fan_pwm, fan_present, fan_fault;   /* gowin-fan hwmon (-1 / 0 if absent) */
} sysinfo_t;
int  sysinfo_fan_set(int pwm);           /* pwm 0..255, <0 = leave; returns 0 on success */
const char *sysinfo_fan_dir(void);       /* hwmon dir of the fan or "" */
void sysinfo_sample(sysinfo_t *si);  /* cheap; call ~1/s */
int  sysinfo_read_file(const char *path, char *buf, int len);  /* returns len or -1 */
int  sysinfo_run(const char *cmd, char *out, int len);          /* popen, returns len */

/* panels.c */
void panel_sysmon(lv_obj_t *parent);
void panel_files(lv_obj_t *parent);      /* files.c */
void panel_audio(lv_obj_t *parent);
void panel_network(lv_obj_t *parent);
void panel_console(lv_obj_t *parent);
void panel_settings(lv_obj_t *parent);
void panel_about(lv_obj_t *parent);
void panel_datetime(lv_obj_t *parent);
int  datetime_set_zone(const char *zone);   /* /etc/localtime + TZ + SD copy; 0 on success */
void datetime_restore(void);               /* apply the zone saved on the SD card, if any */
void audio_play_file(const char *path);   /* used by the file browser */

#endif
