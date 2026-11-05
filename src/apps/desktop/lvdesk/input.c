/*
 * input.c -- evdev pointer + keyboard for lvdesk.
 *
 * Finds /dev/input/event* devices by capability (ABS or REL X/Y = pointer,
 * KEY_A = keyboard), reads them non-blocking from LVGL's indev read
 * callbacks (from input_wait() while a video plays) and keeps looking for
 * them if none exist yet (inputd creates them at boot).  The keyboard delivers printable characters (US layout,
 * shift/caps aware) plus LVGL navigation keys, which LVGL's own evdev
 * driver does not do.  Ctrl+Alt+Q asks the desktop to exit (the rc
 * supervisor restarts it).
 */
#define _GNU_SOURCE
#include "lvdesk.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS(n) (((n) + 31) / 32)
#define TEST(a, b) (((a)[(b) / 32] >> ((b) % 32)) & 1)

static int s_mfd = -1, s_kfd = -1;
static char s_mdev[32], s_kdev[32];
static lv_indev_t *s_mouse, *s_kbd;
static int s_mx = SCR_W / 2, s_my = SCR_H / 2, s_mdown;
static int s_abs_max_x = SCR_W - 1, s_abs_max_y = SCR_H - 1;
static int s_shift, s_ctrl, s_alt, s_caps;
static uint32_t s_rescan_tick;
static char s_status[96] = "no input devices";

/* key queue: LVGL takes one key per read */
#define KQ 64
static struct { uint32_t key; uint8_t pressed; } s_kq[KQ];
static int s_kq_r, s_kq_w;

static void kq_push(uint32_t key, int pressed)
{
    int n = (s_kq_w + 1) % KQ;
    if (n == s_kq_r) return;
    s_kq[s_kq_w].key = key;
    s_kq[s_kq_w].pressed = pressed;
    s_kq_w = n;
}

/* US layout: Linux KEY_* -> ASCII (unshifted / shifted) */
static const char s_map_lo[128] = {
    [KEY_1] = '1', [KEY_2] = '2', [KEY_3] = '3', [KEY_4] = '4', [KEY_5] = '5', [KEY_6] = '6', [KEY_7] = '7',
    [KEY_8] = '8', [KEY_9] = '9', [KEY_0] = '0', [KEY_MINUS] = '-', [KEY_EQUAL] = '=',
    [KEY_Q] = 'q', [KEY_W] = 'w', [KEY_E] = 'e', [KEY_R] = 'r', [KEY_T] = 't', [KEY_Y] = 'y', [KEY_U] = 'u',
    [KEY_I] = 'i', [KEY_O] = 'o', [KEY_P] = 'p', [KEY_LEFTBRACE] = '[', [KEY_RIGHTBRACE] = ']',
    [KEY_A] = 'a', [KEY_S] = 's', [KEY_D] = 'd', [KEY_F] = 'f', [KEY_G] = 'g', [KEY_H] = 'h', [KEY_J] = 'j',
    [KEY_K] = 'k', [KEY_L] = 'l', [KEY_SEMICOLON] = ';', [KEY_APOSTROPHE] = '\'', [KEY_GRAVE] = '`',
    [KEY_BACKSLASH] = '\\', [KEY_Z] = 'z', [KEY_X] = 'x', [KEY_C] = 'c', [KEY_V] = 'v', [KEY_B] = 'b',
    [KEY_N] = 'n', [KEY_M] = 'm', [KEY_COMMA] = ',', [KEY_DOT] = '.', [KEY_SLASH] = '/', [KEY_SPACE] = ' ',
    [KEY_KPASTERISK] = '*', [KEY_KPMINUS] = '-', [KEY_KPPLUS] = '+', [KEY_KPDOT] = '.', [KEY_KPSLASH] = '/',
    [KEY_KP0] = '0', [KEY_KP1] = '1', [KEY_KP2] = '2', [KEY_KP3] = '3', [KEY_KP4] = '4', [KEY_KP5] = '5',
    [KEY_KP6] = '6', [KEY_KP7] = '7', [KEY_KP8] = '8', [KEY_KP9] = '9',
};
static const char s_map_hi[128] = {
    [KEY_1] = '!', [KEY_2] = '@', [KEY_3] = '#', [KEY_4] = '$', [KEY_5] = '%', [KEY_6] = '^', [KEY_7] = '&',
    [KEY_8] = '*', [KEY_9] = '(', [KEY_0] = ')', [KEY_MINUS] = '_', [KEY_EQUAL] = '+',
    [KEY_Q] = 'Q', [KEY_W] = 'W', [KEY_E] = 'E', [KEY_R] = 'R', [KEY_T] = 'T', [KEY_Y] = 'Y', [KEY_U] = 'U',
    [KEY_I] = 'I', [KEY_O] = 'O', [KEY_P] = 'P', [KEY_LEFTBRACE] = '{', [KEY_RIGHTBRACE] = '}',
    [KEY_A] = 'A', [KEY_S] = 'S', [KEY_D] = 'D', [KEY_F] = 'F', [KEY_G] = 'G', [KEY_H] = 'H', [KEY_J] = 'J',
    [KEY_K] = 'K', [KEY_L] = 'L', [KEY_SEMICOLON] = ':', [KEY_APOSTROPHE] = '"', [KEY_GRAVE] = '~',
    [KEY_BACKSLASH] = '|', [KEY_Z] = 'Z', [KEY_X] = 'X', [KEY_C] = 'C', [KEY_V] = 'V', [KEY_B] = 'B',
    [KEY_N] = 'N', [KEY_M] = 'M', [KEY_COMMA] = '<', [KEY_DOT] = '>', [KEY_SLASH] = '?', [KEY_SPACE] = ' ',
};

static uint32_t key_translate(int code)
{
    switch (code) {
    case KEY_UP: return LV_KEY_UP;
    case KEY_DOWN: return LV_KEY_DOWN;
    case KEY_LEFT: return LV_KEY_LEFT;
    case KEY_RIGHT: return LV_KEY_RIGHT;
    case KEY_ESC: return LV_KEY_ESC;
    case KEY_DELETE: return LV_KEY_DEL;
    case KEY_BACKSPACE: return LV_KEY_BACKSPACE;
    case KEY_ENTER: case KEY_KPENTER: return LV_KEY_ENTER;
    case KEY_TAB: return s_shift ? LV_KEY_PREV : LV_KEY_NEXT;
    case KEY_HOME: return LV_KEY_HOME;
    case KEY_END: return LV_KEY_END;
    case KEY_PAGEUP: return LV_KEY_PREV;
    case KEY_PAGEDOWN: return LV_KEY_NEXT;
    case KEY_F2: return DESK_KEY_F2;
    case KEY_F5: return DESK_KEY_F5;
    default: break;
    }
    if (code < 0 || code >= 128) return 0;
    char c = s_map_lo[code];
    if (!c) return 0;
    int letter = (c >= 'a' && c <= 'z');
    int upper = s_shift ^ (letter && s_caps);
    if (upper && s_map_hi[code]) c = s_map_hi[code];
    return (uint32_t)(unsigned char)c;
}

/* ---- device discovery ------------------------------------------------- */
static int probe(const char *path, int *is_mouse, int *is_kbd)
{
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    uint32_t ev[BITS(EV_MAX)] = {0}, rel[BITS(REL_MAX)] = {0}, abs[BITS(ABS_MAX)] = {0}, key[BITS(KEY_MAX)] = {0};
    ioctl(fd, EVIOCGBIT(0, sizeof(ev)), ev);
    ioctl(fd, EVIOCGBIT(EV_REL, sizeof(rel)), rel);
    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs)), abs);
    ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key)), key);
    *is_mouse = (TEST(ev, EV_REL) && TEST(rel, REL_X) && TEST(rel, REL_Y)) ||
                (TEST(ev, EV_ABS) && TEST(abs, ABS_X) && TEST(abs, ABS_Y));
    *is_kbd = TEST(ev, EV_KEY) && TEST(key, KEY_A) && TEST(key, KEY_ENTER);
    if (*is_mouse && TEST(ev, EV_ABS)) {
        struct input_absinfo ai;
        if (!ioctl(fd, EVIOCGABS(ABS_X), &ai) && ai.maximum > 0) s_abs_max_x = ai.maximum;
        if (!ioctl(fd, EVIOCGABS(ABS_Y), &ai) && ai.maximum > 0) s_abs_max_y = ai.maximum;
    }
    return fd;
}

static void rescan(void)
{
    DIR *d = opendir("/dev/input");
    if (!d) return;
    struct dirent *de;
    while ((de = readdir(d))) {
        if (strncmp(de->d_name, "event", 5)) continue;
        char path[64];
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
        if ((s_mfd >= 0 && !strcmp(path, s_mdev)) || (s_kfd >= 0 && !strcmp(path, s_kdev))) continue;
        int m, k;
        int fd = probe(path, &m, &k);
        if (fd < 0) continue;
        if (m && s_mfd < 0) { s_mfd = fd; snprintf(s_mdev, sizeof(s_mdev), "%s", path); ioctl(fd, EVIOCGRAB, 1); continue; }
        if (k && s_kfd < 0) { s_kfd = fd; snprintf(s_kdev, sizeof(s_kdev), "%s", path); ioctl(fd, EVIOCGRAB, 1); continue; }
        close(fd);
    }
    closedir(d);
    snprintf(s_status, sizeof(s_status), "mouse %s, keyboard %s", s_mfd >= 0 ? s_mdev : "none", s_kfd >= 0 ? s_kdev : "none");
}

static void drop(int *fd)
{
    close(*fd);
    *fd = -1;
    s_rescan_tick = lv_tick_get();
}

/* ---- reading the devices ------------------------------------------------ */
bool input_ctrl(void) { return s_ctrl; }
bool input_shift(void) { return s_shift; }

/* the right button's press, outside the indev read: the menu it opens is new objects */
static void context_async(void *p)
{
    uintptr_t v = (uintptr_t)p;
    desk_context_click((int)(v & 0xffff), (int)(v >> 16));
}

/* everything queued on the pointer: position, wheel, buttons (a click ends a video;
 * the right button opens context menus) */
static void mouse_drain(void)
{
    struct input_event ev[32];
    ssize_t n;
    while ((n = read(s_mfd, ev, sizeof(ev))) > 0) {
        for (int i = 0; i < n / (int)sizeof(ev[0]); i++) {
            switch (ev[i].type) {
            case EV_ABS:
                if (ev[i].code == ABS_X) s_mx = ev[i].value * (SCR_W - 1) / s_abs_max_x;
                else if (ev[i].code == ABS_Y) s_my = ev[i].value * (SCR_H - 1) / s_abs_max_y;
                break;
            case EV_REL:
                if (ev[i].code == REL_X) s_mx += ev[i].value;
                else if (ev[i].code == REL_Y) s_my += ev[i].value;
                else if (ev[i].code == REL_WHEEL) {
                    /* wheel = scroll the object under the cursor */
                    lv_obj_t *o = lv_indev_search_obj(lv_screen_active(), &(lv_point_t){ s_mx, s_my });
                    while (o && !lv_obj_is_scrollable(o)) o = lv_obj_get_parent(o);
                    if (o) lv_obj_scroll_by_bounded(o, 0, ev[i].value * 40, LV_ANIM_ON);
                }
                break;
            case EV_KEY:
                if (ev[i].code == BTN_LEFT) {
                    if (ev[i].value && video_active()) { video_stop(); break; }   /* click ends a video */
                    s_mdown = ev[i].value != 0;
                } else if (ev[i].code == BTN_RIGHT && ev[i].value == 1) {
                    if (video_active()) { video_stop(); break; }
                    int x = s_mx < 0 ? 0 : s_mx >= SCR_W ? SCR_W - 1 : s_mx, y = s_my < 0 ? 0 : s_my >= SCR_H ? SCR_H - 1 : s_my;
                    lv_async_call(context_async, (void *)(uintptr_t)((unsigned)y << 16 | (unsigned)x));
                }
                break;
            }
        }
    }
    if (n < 0 && errno != EAGAIN) drop(&s_mfd);
    if (s_mx < 0) s_mx = 0;
    if (s_mx >= SCR_W) s_mx = SCR_W - 1;
    if (s_my < 0) s_my = 0;
    if (s_my >= SCR_H) s_my = SCR_H - 1;
}

/* everything queued on the keyboard: modifiers, hotkeys, keys for LVGL (any key ends a video) */
static void kbd_drain(void)
{
    struct input_event ev[32];
    ssize_t n;
    while ((n = read(s_kfd, ev, sizeof(ev))) > 0) {
        for (int i = 0; i < n / (int)sizeof(ev[0]); i++) {
            if (ev[i].type != EV_KEY) continue;
            int c = ev[i].code, v = ev[i].value;     /* 0 up, 1 down, 2 repeat */
            switch (c) {
            case KEY_LEFTSHIFT: case KEY_RIGHTSHIFT: s_shift = v != 0; continue;
            case KEY_LEFTCTRL: case KEY_RIGHTCTRL: s_ctrl = v != 0; continue;
            case KEY_LEFTALT: case KEY_RIGHTALT: s_alt = v != 0; continue;
            case KEY_CAPSLOCK: if (v == 1) s_caps ^= 1; continue;
            default: break;
            }
            if (v == 1 && video_active()) { video_stop(); continue; }   /* any key ends a video */
            if (v == 1 && s_ctrl && s_alt && c == KEY_Q) { desk_request_exit(0); continue; }
            if (v == 1 && s_ctrl && s_alt && c == KEY_H) { desk_go_home(); continue; }
            uint32_t key = key_translate(c);
            if (!key) continue;
            if (v == 2) { kq_push(key, 0); kq_push(key, 1); }   /* repeat: release + press */
            else kq_push(key, v);
        }
    }
    if (n < 0 && errno != EAGAIN) drop(&s_kfd);
}

/* ---- LVGL read callbacks ---------------------------------------------- */
static void mouse_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    if (s_mfd < 0) {
        if (lv_tick_elaps(s_rescan_tick) > 1000) { s_rescan_tick = lv_tick_get(); rescan(); }
    } else {
        mouse_drain();
    }
    data->point.x = s_mx;
    data->point.y = s_my;
    data->state = s_mdown ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void kbd_read(lv_indev_t *indev, lv_indev_data_t *data)
{
    (void)indev;
    static uint32_t last_key;
    if (s_kfd < 0) {
        if (lv_tick_elaps(s_rescan_tick) > 1000) { s_rescan_tick = lv_tick_get(); rescan(); }
    } else {
        kbd_drain();
    }
    if (s_kq_r != s_kq_w) {
        data->key = s_kq[s_kq_r].key;
        data->state = s_kq[s_kq_r].pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
        last_key = data->key;
        s_kq_r = (s_kq_r + 1) % KQ;
        data->continue_reading = s_kq_r != s_kq_w;
    } else {
        data->key = last_key;
        data->state = LV_INDEV_STATE_RELEASED;
    }
}

/* While a video plays the desktop sleeps here instead of in LVGL's timer loop:
 * until input arrives or `ms` pass, then the input is handled as the read
 * callbacks would (a key or click stops the video).  No device = just sleep. */
void input_wait(int ms)
{
    struct pollfd p[2] = { { .fd = s_mfd, .events = POLLIN }, { .fd = s_kfd, .events = POLLIN } };
    if (poll(p, 2, ms) <= 0) return;           /* poll() skips the negative fds */
    if (s_mfd >= 0 && p[0].revents) mouse_drain();
    if (s_kfd >= 0 && p[1].revents) kbd_drain();
}

/* ---- cursor image (ARGB8888 from ASCII art) ---------------------------- */
static const char *s_cursor_art[] = {
    "X...........",
    "XX..........",
    "X#X.........",
    "X##X........",
    "X###X.......",
    "X####X......",
    "X#####X.....",
    "X######X....",
    "X#######X...",
    "X########X..",
    "X#####XXXXX.",
    "X##X##X.....",
    "X#X.X##X....",
    "XX..X##X....",
    "X....X##X...",
    ".....X##X...",
    "......X#X...",
    "......XXX...",
};

static lv_obj_t *cursor_create(void)
{
    int h = sizeof(s_cursor_art) / sizeof(s_cursor_art[0]), w = 12;
    lv_draw_buf_t *db = lv_draw_buf_create(w, h, LV_COLOR_FORMAT_ARGB8888, 0);
    if (!db) return NULL;
    for (int y = 0; y < h; y++) {
        uint32_t *row = (uint32_t *)((uint8_t *)db->data + y * db->header.stride);
        for (int x = 0; x < w; x++) {
            char c = s_cursor_art[y][x];
            row[x] = c == 'X' ? 0xFF000000 : c == '#' ? 0xFFFFFFFF : 0x00000000;
        }
    }
    lv_obj_t *img = lv_image_create(lv_layer_sys());
    lv_image_set_src(img, db);
    return img;
}

bool input_init(lv_display_t *disp)
{
    rescan();
    s_mouse = lv_indev_create();
    lv_indev_set_type(s_mouse, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(s_mouse, mouse_read);
    lv_indev_set_display(s_mouse, disp);
    lv_obj_t *cur = cursor_create();
    if (cur) lv_indev_set_cursor(s_mouse, cur);

    s_kbd = lv_indev_create();
    lv_indev_set_type(s_kbd, LV_INDEV_TYPE_KEYPAD);
    lv_indev_set_read_cb(s_kbd, kbd_read);
    lv_indev_set_display(s_kbd, disp);
    lv_indev_set_group(s_kbd, lv_group_get_default());
    return s_mfd >= 0 || s_kfd >= 0;
}

const char *input_status(void) { return s_status; }
