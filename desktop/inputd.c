/*
 * inputd -- network keyboard/mouse bridge for the AE350 board.
 *
 * The board has no USB host, PS/2 or touch, so a PC feeds it input events
 * over TCP (default port 5555).  inputd creates two virtual input devices
 * through /dev/uinput:
 *
 *   "netinput mouse"    -- EV_ABS X/Y (0..W-1 / 0..H-1), EV_REL X/Y/WHEEL,
 *                          BTN_LEFT/RIGHT/MIDDLE
 *   "netinput keyboard" -- EV_KEY for every key code below BTN_MISC
 *
 * and copies each received event into the matching device, so anything
 * reading /dev/input/event* (the LVGL desktop, or the console) sees a
 * normal mouse and keyboard.
 *
 * Wire protocol (one client at a time, host/netinput.py is the reference):
 *   client -> board:  "NETINPUT1" (9 bytes), then 8-byte records
 *                     { u16 type, u16 code, i32 value } big-endian
 *                     type 0xFFFF code 1 = request one framebuffer frame:
 *                       value 0 = raw, value 1 = changed rows + RLE,
 *                       value 2 = all rows + RLE (keyframe / resync)
 *   board  -> client: 8-byte header { u16 width, u16 height, u16 bpp, u16 fmt }
 *                     fmt 0: the raw /dev/fb0 contents (w*h*bpp/8 bytes)
 *                     fmt 1: u32 payload length, then for each row that differs
 *                            from the previous frame sent to THIS client:
 *                            { u16 row, u16 len } + len bytes of RLE pixels:
 *                            byte n < 0x80: n+1 copies of the following RGB565
 *                            pixel (LE); n >= 0x80: n-127 literal pixels follow.
 *                            The first frame of a connection carries all rows.
 *
 * Every key/button pressed by a client is released when it disconnects.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

#define MAGIC "NETINPUT1"
#define REQ_TYPE 0xFFFF
#define REQ_FRAME 1

static int scr_w = 800, scr_h = 480;
static int verbose;

static int uinput_open(const char *name, int is_mouse)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) { perror("/dev/uinput"); return -1; }

    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    if (is_mouse) {
        ioctl(fd, UI_SET_EVBIT, EV_REL);
        ioctl(fd, UI_SET_RELBIT, REL_X);
        ioctl(fd, UI_SET_RELBIT, REL_Y);
        ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
        ioctl(fd, UI_SET_EVBIT, EV_ABS);
        ioctl(fd, UI_SET_ABSBIT, ABS_X);
        ioctl(fd, UI_SET_ABSBIT, ABS_Y);
        ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
        ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
        ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);
    } else {
        for (int k = 1; k < BTN_MISC; k++) ioctl(fd, UI_SET_KEYBIT, k);
        ioctl(fd, UI_SET_EVBIT, EV_REP);
    }

    struct uinput_user_dev ud;
    memset(&ud, 0, sizeof(ud));
    snprintf(ud.name, UINPUT_MAX_NAME_SIZE, "%s", name);
    ud.id.bustype = BUS_VIRTUAL;
    ud.id.vendor = 0xae35;
    ud.id.product = is_mouse ? 1 : 2;
    ud.id.version = 1;
    if (is_mouse) {
        ud.absmin[ABS_X] = 0; ud.absmax[ABS_X] = scr_w - 1;
        ud.absmin[ABS_Y] = 0; ud.absmax[ABS_Y] = scr_h - 1;
    }
    if (write(fd, &ud, sizeof(ud)) != sizeof(ud)) { perror("uinput setup"); close(fd); return -1; }
    if (ioctl(fd, UI_DEV_CREATE) < 0) { perror("UI_DEV_CREATE"); close(fd); return -1; }
    return fd;
}

static void emit(int fd, uint16_t type, uint16_t code, int32_t value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type; ev.code = code; ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != sizeof(ev) && verbose)
        fprintf(stderr, "inputd: uinput write: %s\n", strerror(errno));
}

static int write_all(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        p += r; n -= r;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t n)
{
    char *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        p += r; n -= r;
    }
    return 0;
}

/* ---- framebuffer access ------------------------------------------------ */
static int fb_fd = -1;
static uint8_t *fb_map;                 /* mmap of /dev/fb0 (or NULL) */
static size_t fb_size, fb_stride;
static unsigned fb_w, fb_h, fb_bpp;

static int fb_open(void)
{
    if (fb_fd >= 0) return 0;
    fb_fd = open("/dev/fb0", O_RDONLY);
    if (fb_fd < 0) return -1;
    struct fb_var_screeninfo v;
    struct fb_fix_screeninfo f;
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &v) || ioctl(fb_fd, FBIOGET_FSCREENINFO, &f)) { close(fb_fd); fb_fd = -1; return -1; }
    fb_w = v.xres; fb_h = v.yres; fb_bpp = v.bits_per_pixel; fb_stride = f.line_length;
    fb_size = fb_stride * fb_h;
    fb_map = mmap(NULL, fb_size, PROT_READ, MAP_SHARED, fb_fd, 0);
    if (fb_map == MAP_FAILED) fb_map = NULL;
    return 0;
}

/* read the whole framebuffer into buf (mmap copy, or read()) */
static int fb_grab(uint8_t *buf)
{
    if (fb_map) { memcpy(buf, fb_map, fb_size); return 0; }
    if (lseek(fb_fd, 0, SEEK_SET) < 0) return -1;
    size_t got = 0;
    while (got < fb_size) {
        ssize_t r = read(fb_fd, buf + got, fb_size - got);
        if (r <= 0) return -1;
        got += r;
    }
    return 0;
}

/* raw frame: header + pixels */
static int send_frame_raw(int sock, uint8_t *cur)
{
    uint16_t hdr[4] = { htons(fb_w), htons(fb_h), htons(fb_bpp), 0 };
    if (fb_grab(cur)) return -1;
    if (write_all(sock, hdr, sizeof(hdr))) return -1;
    return write_all(sock, cur, fb_size);
}

/* RLE one RGB565 row: n<0x80 = run of n+1, n>=0x80 = n-127 literals */
static unsigned rle_row(const uint16_t *px, unsigned w, uint8_t *out)
{
    unsigned i = 0, o = 0;
    while (i < w) {
        unsigned r = 1;
        while (i + r < w && r < 128 && px[i + r] == px[i]) r++;
        if (r >= 2) {
            out[o++] = r - 1;
            out[o++] = px[i] & 0xFF; out[o++] = px[i] >> 8;
            i += r;
            continue;
        }
        /* literals until a run of >= 3 starts (or 128 pixels) */
        unsigned n = 1;
        while (i + n < w && n < 128) {
            if (i + n + 2 < w && px[i + n] == px[i + n + 1] && px[i + n] == px[i + n + 2]) break;
            n++;
        }
        out[o++] = 0x80 | (n - 1);
        for (unsigned k = 0; k < n; k++) { out[o++] = px[i + k] & 0xFF; out[o++] = px[i + k] >> 8; }
        i += n;
    }
    return o;
}

/* changed rows vs. prev (invalid = all rows), RLE encoded.  Rows are compared
 * and encoded straight from the mmap when there is one, and only the changed
 * rows are copied into prev: the A25 reads memory at ~60 MB/s, so every extra
 * pass over the 768 KB framebuffer costs ~13 ms. */
static int send_frame_delta(int sock, uint8_t *cur, uint8_t *prev, int prev_valid, uint8_t *enc)
{
    if (fb_bpp != 16) return send_frame_raw(sock, cur);
    const uint8_t *src = fb_map;
    if (!src) { if (fb_grab(cur)) return -1; src = cur; }
    size_t o = 0;
    for (unsigned y = 0; y < fb_h; y++) {
        const uint8_t *row = src + y * fb_stride;
        uint8_t *prow = prev + y * fb_stride;
        if (prev_valid && !memcmp(row, prow, fb_w * 2)) continue;
        memcpy(prow, row, fb_w * 2);               /* encode from the stable copy */
        uint8_t *rh = enc + o;
        unsigned len = rle_row((const uint16_t *)prow, fb_w, rh + 4);
        rh[0] = y >> 8; rh[1] = y & 0xFF; rh[2] = len >> 8; rh[3] = len & 0xFF;
        o += 4 + len;
    }
    uint16_t hdr[4] = { htons(fb_w), htons(fb_h), htons(fb_bpp), htons(1) };
    uint32_t n = htonl(o);
    if (write_all(sock, hdr, sizeof(hdr)) || write_all(sock, &n, 4) || write_all(sock, enc, o)) return -1;
    return 0;
}

static void serve(int sock, int kfd, int mfd)
{
    char magic[sizeof(MAGIC) - 1];
    if (read_all(sock, magic, sizeof(magic)) || memcmp(magic, MAGIC, sizeof(magic))) {
        fprintf(stderr, "inputd: bad handshake\n");
        return;
    }
    uint8_t pressed[KEY_MAX + 1];
    memset(pressed, 0, sizeof(pressed));
    unsigned long n_ev = 0;
    uint8_t *cur = NULL, *prev = NULL, *enc = NULL;   /* frame buffers, on first request */
    int prev_valid = 0;

    for (;;) {
        uint8_t rec[8];
        if (read_all(sock, rec, sizeof(rec))) break;
        uint16_t type = (rec[0] << 8) | rec[1];
        uint16_t code = (rec[2] << 8) | rec[3];
        int32_t value = (int32_t)(((uint32_t)rec[4] << 24) | (rec[5] << 16) | (rec[6] << 8) | rec[7]);

        if (type == REQ_TYPE) {
            if (code != REQ_FRAME) continue;
            if (fb_open()) break;
            if (!cur) {
                /* worst-case RLE row: 800 px -> 1600 B + 7 control bytes, + 4 B row header */
                cur = malloc(fb_size); prev = malloc(fb_size); enc = malloc(fb_h * (fb_w * 2 + fb_w / 128 + 8));
                if (!cur || !prev || !enc) break;
            }
            int r = value ? send_frame_delta(sock, cur, prev, prev_valid && value == 1, enc) : send_frame_raw(sock, cur);
            if (r) break;
            prev_valid = value != 0;
            continue;
        }
        n_ev++;
        switch (type) {
        case EV_KEY:
            if (code > KEY_MAX) break;
            pressed[code] = value ? 1 : 0;
            emit(code < BTN_MISC ? kfd : mfd, EV_KEY, code, value);
            break;
        case EV_REL:
        case EV_ABS:
            emit(mfd, type, code, value);
            break;
        case EV_SYN:
            emit(kfd, EV_SYN, SYN_REPORT, 0);
            emit(mfd, EV_SYN, SYN_REPORT, 0);
            break;
        default:
            break;
        }
    }
    /* never leave a key or button stuck down */
    for (int k = 0; k <= KEY_MAX; k++)
        if (pressed[k]) emit(k < BTN_MISC ? kfd : mfd, EV_KEY, k, 0);
    emit(kfd, EV_SYN, SYN_REPORT, 0);
    emit(mfd, EV_SYN, SYN_REPORT, 0);
    free(cur); free(prev); free(enc);
    if (verbose) fprintf(stderr, "inputd: client gone after %lu events\n", n_ev);
}

int main(int argc, char **argv)
{
    int port = 5555;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-p") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) sscanf(argv[++i], "%dx%d", &scr_w, &scr_h);
        else { fprintf(stderr, "usage: inputd [-p port] [-s WxH] [-v]\n"); return 2; }
    }
    signal(SIGPIPE, SIG_IGN);

    /* the mouse is created first so it is the lower /dev/input/eventN */
    int mfd = uinput_open("netinput mouse", 1);
    int kfd = uinput_open("netinput keyboard", 0);
    if (mfd < 0 || kfd < 0) return 1;

    int ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = INADDR_ANY };
    if (bind(ls, (struct sockaddr *)&sa, sizeof(sa)) || listen(ls, 1)) { perror("listen"); return 1; }
    printf("inputd: uinput mouse+keyboard ready, listening on :%d\n", port);
    fflush(stdout);

    for (;;) {
        struct sockaddr_in ca; socklen_t cl = sizeof(ca);
        int s = accept(ls, (struct sockaddr *)&ca, &cl);
        if (s < 0) { if (errno == EINTR) continue; perror("accept"); break; }
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        if (verbose) fprintf(stderr, "inputd: client %s\n", inet_ntoa(ca.sin_addr));
        serve(s, kfd, mfd);
        close(s);
    }
    return 0;
}
