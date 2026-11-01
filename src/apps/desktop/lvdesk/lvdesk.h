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
/* wired-network icon (two boxes joined by a cable, GNOME "network-wired" style);
 * state: 1 = link up (white), 0 = cable unplugged (grey + red slash), -1 = unknown (grey) */
lv_obj_t *desk_wired_icon(lv_obj_t *parent, int size);
void desk_wired_icon_set(lv_obj_t *icon, int state);

/* input.c */
bool input_init(lv_display_t *disp);
const char *input_status(void);

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
void panel_files(lv_obj_t *parent);
void panel_audio(lv_obj_t *parent);
void panel_network(lv_obj_t *parent);
void panel_console(lv_obj_t *parent);
void panel_settings(lv_obj_t *parent);
void panel_about(lv_obj_t *parent);
void demo_widgets_start(void);
void audio_play_file(const char *path);   /* used by the file browser */

#endif
