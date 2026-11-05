/* files.c -- the Files panel: a small file manager in the manner of Ubuntu's Files
 * (Nautilus) in list view.
 *
 *   microSD row (Mount / Unmount)
 *   places | Up  /current/path
 *          | Name                    Size      Modified
 *          | ...
 *          | status (items, selection, free space) or the progress of a copy
 *
 * Mouse: click selects, Ctrl+click toggles, Shift+click extends from the last click,
 * double click opens (folders in place; .avi/.mp4/.mkv/.mp3/.m4a through vidplay, .wav
 * through wavplay, anything small and printable in a text preview).  Right click opens
 * a context menu: on the selection Open, Cut, Copy, Paste Into Folder, Rename, Delete,
 * Properties; on the background New Folder, Paste, Select All, Show Hidden Files,
 * Properties.  Keys: arrows (Shift extends), Home/End, Enter opens, Backspace goes up,
 * Ctrl+A / C / X / V, Delete, F2 renames, F5 reloads, Ctrl+H hidden files, Esc.
 *
 * Copy, move and delete run in a child process (busybox cp -a, mv, rm -rf, one item
 * after the other) with a progress bar and Cancel, so a 300 MB copy onto the SD card
 * (over a minute) leaves the desktop usable.  Nothing is overwritten: a taken name
 * becomes "name (copy).ext", "name (copy 2).ext", ... as in Nautilus.  There is no
 * trash: Delete asks first and removes for good.  The desktop runs as root, so the
 * confirmation is the only guard.
 */
#define _GNU_SOURCE
#include "lvdesk.h"
#include "src/widgets/table/lv_table_private.h"   /* row heights, for hit-testing a point */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define HOME_DIR  "/home/ae350"
#define SD_DIR    "/mnt/sd"
#define DCLICK_MS 450
#define JOB_ERR   "/tmp/lvdesk-files.err"

typedef struct {
    char *name;
    bool dir;                       /* a folder, or a link to one */
    bool lnk;
    long long size;
    time_t mtime;
    mode_t mode;
} fent_t;

/* the panel while it is open (fm.root == NULL otherwise) */
static struct {
    lv_obj_t *root, *table, *path, *status, *sd_lbl, *sd_btn, *sd_btn_lbl;
    lv_obj_t *job_row, *job_lbl, *job_bar;
    lv_timer_t *timer;
    char cwd[PATH_MAX];
    time_t cwd_mtime;
    fent_t *e;
    int n;
    bool *sel;
    int nsel, anchor, cursor;       /* anchor: Shift+click / Shift+arrow extend from it */
    int click_row;                  /* double click: the last clicked entry and when */
    uint32_t click_tick;
    lv_color_t row_bg, head_bg, sel_bg;
} fm;

static bool s_hidden;               /* show dot files (Ctrl+H), kept across visits */
static char s_last_dir[PATH_MAX] = HOME_DIR;

/* the clipboard (Cut / Copy), kept across visits */
static struct { char **paths; int n; bool cut; } clip;

/* the background operation */
enum { JOB_COPY, JOB_MOVE, JOB_DELETE };
static struct {
    pid_t pid;
    int fd;                         /* read end: the child writes the index of the item it starts */
    int kind, n, cur;
    char **src, **dst;
    long long *size, total;
    char dir[PATH_MAX];             /* destination folder (copy / move) */
    bool cancelled;
    lv_timer_t *timer;
} job;

static void fm_reload(bool keep_selection);
static void fm_open_dir(const char *path);
static void update_status(void);

/* ---- small helpers ------------------------------------------------------ */
static void join(char *o, size_t n, const char *dir, const char *name)
{
    snprintf(o, n, "%s%s%s", dir, strcmp(dir, "/") ? "/" : "", name);
}

static const char *base_name(const char *p)
{
    const char *s = strrchr(p, '/');
    return s && s[1] ? s + 1 : p;
}

static void parent_dir(char *o, size_t n, const char *p)
{
    snprintf(o, n, "%s", p);
    char *s = strrchr(o, '/');
    if (!s) snprintf(o, n, ".");
    else if (s == o) o[1] = 0;
    else *s = 0;
}

static const char *ext_of(const char *name)
{
    const char *d = strrchr(name, '.');
    return d && d != name ? d + 1 : "";
}

static bool ext_in(const char *name, const char *list)   /* list: "avi mp4 mkv" */
{
    const char *e = ext_of(name);
    size_t l = strlen(e);
    if (!l) return false;
    for (const char *p = list; *p; ) {
        const char *q = strchr(p, ' ');
        size_t k = q ? (size_t)(q - p) : strlen(p);
        if (k == l && !strncasecmp(p, e, l)) return true;
        if (!q) break;
        p = q + 1;
    }
    return false;
}

#define EXT_VIDEO "avi mp4 mkv"
#define EXT_AUDIO "mp3 m4a wav"
#define EXT_IMAGE "bmp png jpg jpeg gif"

/* sizes as Nautilus shows them: SI units */
static void human(char *o, size_t n, long long b)
{
    if (b < 1000) snprintf(o, n, "%lld byte%s", b, b == 1 ? "" : "s");
    else if (b < 1000000) snprintf(o, n, "%.1f kB", b / 1e3);
    else if (b < 1000000000) snprintf(o, n, "%.1f MB", b / 1e6);
    else snprintf(o, n, "%.1f GB", b / 1e9);
}

static void grouped(char *o, size_t n, long long v)   /* 184,727,565 */
{
    char t[32];
    int l = snprintf(t, sizeof(t), "%lld", v), k = 0;
    for (int i = 0; i < l && k + 2 < (int)n; i++) {
        o[k++] = t[i];
        if ((l - i - 1) % 3 == 0 && i < l - 1) o[k++] = ',';
    }
    o[k] = 0;
}

/* Modified: the time today, the day this year, else the date */
static void when(char *o, size_t n, time_t t)
{
    time_t now = time(NULL);
    struct tm a, b;
    localtime_r(&t, &a);
    localtime_r(&now, &b);
    if (a.tm_year == b.tm_year && a.tm_yday == b.tm_yday) strftime(o, n, "%H:%M", &a);
    else if (a.tm_year == b.tm_year) strftime(o, n, "%e %b %H:%M", &a);
    else strftime(o, n, "%e %b %Y", &a);
}

/* bytes and entries below a path (links not followed); *budget entries at most */
static long long tree_size(const char *path, long *count, long *budget)
{
    struct stat st;
    if (*budget <= 0 || lstat(path, &st)) return 0;
    (*budget)--;
    if (!S_ISDIR(st.st_mode)) return S_ISREG(st.st_mode) ? st.st_size : 0;
    long long sum = 0;
    DIR *d = opendir(path);
    if (!d) return 0;
    struct dirent *de;
    char p[PATH_MAX];
    while ((de = readdir(d)) && *budget > 0) {
        if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
        join(p, sizeof(p), path, de->d_name);
        (*count)++;
        sum += tree_size(p, count, budget);
    }
    closedir(d);
    return sum;
}

static int dir_count(const char *path)
{
    DIR *d = opendir(path);
    if (!d) return -1;
    int n = 0;
    struct dirent *de;
    while ((de = readdir(d)))
        if (de->d_name[0] != '.' || (s_hidden && strcmp(de->d_name, ".") && strcmp(de->d_name, ".."))) n++;
    closedir(d);
    return n;
}

static const char *type_of(const char *name, const struct stat *st)
{
    if (S_ISDIR(st->st_mode)) return "Folder";
    if (S_ISLNK(st->st_mode)) return "Link";
    if (!S_ISREG(st->st_mode)) return S_ISCHR(st->st_mode) ? "Character device" : S_ISBLK(st->st_mode) ? "Block device" :
                                      S_ISFIFO(st->st_mode) ? "Pipe" : S_ISSOCK(st->st_mode) ? "Socket" : "Special file";
    if (ext_in(name, EXT_VIDEO)) return "Video";
    if (ext_in(name, EXT_AUDIO)) return "Audio";
    if (ext_in(name, EXT_IMAGE)) return "Image";
    if (ext_in(name, "txt md log conf cfg ini sh py c h")) return "Text";
    if (st->st_mode & 0111) return "Program";
    return "File";
}

/* "name.ext" taken in dir -> "name (copy).ext", "name (copy 2).ext", ... */
static void unique_name(char *o, size_t n, const char *dir, const char *base, bool is_dir)
{
    char p[PATH_MAX];
    struct stat st;
    join(p, sizeof(p), dir, base);
    if (lstat(p, &st)) { snprintf(o, n, "%s", base); return; }
    const char *dot = is_dir ? NULL : strrchr(base, '.');
    if (dot == base) dot = NULL;
    int stem = dot ? (int)(dot - base) : (int)strlen(base);
    for (int k = 1; k < 1000; k++) {
        if (k == 1) snprintf(o, n, "%.*s (copy)%s", stem, base, dot ? dot : "");
        else snprintf(o, n, "%.*s (copy %d)%s", stem, base, k, dot ? dot : "");
        join(p, sizeof(p), dir, o);
        if (lstat(p, &st)) return;
    }
}

static void focus_table(void)
{
    if (fm.root && fm.table) lv_group_focus_obj(fm.table);
}

/* ---- listing ------------------------------------------------------------ */
static int ent_cmp(const void *a, const void *b)
{
    const fent_t *x = a, *y = b;
    if (x->dir != y->dir) return x->dir ? -1 : 1;
    return strcasecmp(x->name, y->name);
}

static void free_entries(void)
{
    for (int i = 0; i < fm.n; i++) free(fm.e[i].name);
    free(fm.e);
    free(fm.sel);
    fm.e = NULL;
    fm.sel = NULL;
    fm.n = fm.nsel = 0;
}

static const char *icon_of(const fent_t *f)
{
    if (f->dir) return LV_SYMBOL_DIRECTORY;
    if (ext_in(f->name, EXT_VIDEO)) return LV_SYMBOL_VIDEO;
    if (ext_in(f->name, EXT_AUDIO)) return LV_SYMBOL_AUDIO;
    if (ext_in(f->name, EXT_IMAGE)) return LV_SYMBOL_IMAGE;
    return LV_SYMBOL_FILE;
}

static void fill_table(void)
{
    lv_obj_t *t = fm.table;
    char buf[PATH_MAX + 16], sz[32], tm[32];
    lv_table_set_row_count(t, fm.n + 1);
    lv_table_set_cell_value(t, 0, 0, "Name");
    lv_table_set_cell_value(t, 0, 1, "Size");
    lv_table_set_cell_value(t, 0, 2, "Modified");
    for (int i = 0; i < fm.n; i++) {
        fent_t *f = &fm.e[i];
        snprintf(buf, sizeof(buf), "%s  %s", icon_of(f), f->name);
        lv_table_set_cell_value(t, i + 1, 0, buf);
        if (f->dir) {
            /* item counts, as Nautilus shows them (skipped in huge folders: one opendir each) */
            int c = fm.n <= 200 ? (join(buf, sizeof(buf), fm.cwd, f->name), dir_count(buf)) : -1;
            if (c >= 0) snprintf(sz, sizeof(sz), "%d item%s", c, c == 1 ? "" : "s");
            else sz[0] = 0;
        } else
            human(sz, sizeof(sz), f->size);
        lv_table_set_cell_value(t, i + 1, 1, sz);
        when(tm, sizeof(tm), f->mtime);
        lv_table_set_cell_value(t, i + 1, 2, tm);
    }
    for (int r = 0; r <= fm.n; r++)
        for (int c = 0; c < 3; c++) lv_table_set_cell_ctrl(t, r, c, LV_TABLE_CELL_CTRL_TEXT_CROP);
}

/* read fm.cwd again; keep_selection: reselect by name (also the cursor) */
static void fm_reload(bool keep_selection)
{
    char **keep = NULL, *cur = NULL;
    int nkeep = 0;
    if (keep_selection && fm.nsel) {
        keep = malloc(fm.nsel * sizeof(*keep));
        for (int i = 0; i < fm.n; i++) if (fm.sel[i]) keep[nkeep++] = strdup(fm.e[i].name);
    }
    if (keep_selection && fm.cursor >= 0 && fm.cursor < fm.n) cur = strdup(fm.e[fm.cursor].name);
    free_entries();
    fm.anchor = fm.cursor = fm.click_row = -1;

    struct stat st;
    if (!stat(fm.cwd, &st)) fm.cwd_mtime = st.st_mtime;
    DIR *d = opendir(fm.cwd);
    int cap = 0;
    if (d) {
        struct dirent *de;
        char p[PATH_MAX];
        while ((de = readdir(d))) {
            if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, "..")) continue;
            if (de->d_name[0] == '.' && !s_hidden) continue;
            join(p, sizeof(p), fm.cwd, de->d_name);
            if (lstat(p, &st)) continue;
            if (fm.n == cap) {
                cap = cap ? cap * 2 : 64;
                fm.e = realloc(fm.e, cap * sizeof(*fm.e));
            }
            fent_t *f = &fm.e[fm.n++];
            f->name = strdup(de->d_name);
            f->lnk = S_ISLNK(st.st_mode);
            struct stat t2;
            if (f->lnk && !stat(p, &t2)) st = t2;          /* a link shows its target */
            f->dir = S_ISDIR(st.st_mode);
            f->size = st.st_size;
            f->mtime = st.st_mtime;
            f->mode = st.st_mode;
        }
        closedir(d);
    }
    if (fm.n) qsort(fm.e, fm.n, sizeof(*fm.e), ent_cmp);
    fm.sel = calloc(fm.n ? fm.n : 1, sizeof(*fm.sel));
    for (int k = 0; k < nkeep; k++) {
        for (int i = 0; i < fm.n; i++)
            if (!strcmp(fm.e[i].name, keep[k])) { fm.sel[i] = true; fm.nsel++; if (fm.anchor < 0) fm.anchor = i; }
        free(keep[k]);
    }
    free(keep);
    if (cur) {
        for (int i = 0; i < fm.n; i++) if (!strcmp(fm.e[i].name, cur)) fm.cursor = i;
        free(cur);
    }
    fill_table();
    update_status();
    lv_obj_invalidate(fm.table);
}

static void select_names(char **names, int n)   /* after a paste / rename / new folder */
{
    for (int i = 0; i < fm.n; i++) fm.sel[i] = false;
    fm.nsel = 0;
    for (int k = 0; k < n; k++)
        for (int i = 0; i < fm.n; i++)
            if (!strcmp(fm.e[i].name, names[k])) { fm.sel[i] = true; fm.nsel++; fm.anchor = fm.cursor = i; }
    lv_obj_invalidate(fm.table);
    update_status();
}

static void fm_open_dir(const char *path)
{
    char rp[PATH_MAX];
    if (!realpath(path, rp) || access(rp, R_OK | X_OK)) {
        char msg[PATH_MAX + 64];
        snprintf(msg, sizeof(msg), "Cannot open %s:\n%s", path, strerror(errno ? errno : EACCES));
        desk_msgbox("Files", msg);
        return;
    }
    snprintf(fm.cwd, sizeof(fm.cwd), "%s", rp);
    snprintf(s_last_dir, sizeof(s_last_dir), "%s", rp);
    lv_label_set_text(fm.path, rp);
    fm_reload(false);
    lv_obj_scroll_to_y(fm.table, 0, LV_ANIM_OFF);
}

static void go_up(void)
{
    if (!strcmp(fm.cwd, "/")) return;
    char from[NAME_MAX + 1], up[PATH_MAX];
    snprintf(from, sizeof(from), "%s", base_name(fm.cwd));
    parent_dir(up, sizeof(up), fm.cwd);
    fm_open_dir(up);
    char *names[1] = { from };
    select_names(names, 1);                          /* land on the folder we came from */
}

/* ---- selection ---------------------------------------------------------- */
static void sel_clear(void)
{
    for (int i = 0; i < fm.n; i++) fm.sel[i] = false;
    fm.nsel = 0;
}

static void sel_set(int i, bool on)
{
    if (i < 0 || i >= fm.n || fm.sel[i] == on) return;
    fm.sel[i] = on;
    fm.nsel += on ? 1 : -1;
}

static void sel_range(int a, int b)
{
    if (a > b) { int t = a; a = b; b = t; }
    for (int i = a; i <= b; i++) sel_set(i, true);
}

static void sel_changed(void)
{
    lv_obj_invalidate(fm.table);
    update_status();
}

static void select_all(void)
{
    for (int i = 0; i < fm.n; i++) sel_set(i, true);
    sel_changed();
}

/* table row under a screen point (0 = the header), -1 = none */
static int row_at(const lv_point_t *p)
{
    lv_table_t *tb = (lv_table_t *)fm.table;
    lv_area_t a;
    lv_obj_get_coords(fm.table, &a);
    if (p->x < a.x1 || p->x > a.x2 || p->y < a.y1 || p->y > a.y2) return -1;
    int32_t y = p->y + lv_obj_get_scroll_y(fm.table) - a.y1 - lv_obj_get_style_pad_top(fm.table, LV_PART_MAIN);
    int32_t acc = 0;
    for (uint32_t r = 0; r < tb->row_cnt; r++) {
        acc += tb->row_h[r];
        if (y < acc) return (int)r;
    }
    return -1;
}

/* keep entry i in view */
static void scroll_to_entry(int i)
{
    lv_table_t *tb = (lv_table_t *)fm.table;
    if (i < 0 || (uint32_t)i + 1 >= tb->row_cnt) return;
    int32_t top = 0;
    for (int r = 0; r <= i; r++) top += tb->row_h[r];          /* rows above entry i, header included */
    int32_t bot = top + tb->row_h[i + 1];
    int32_t sy = lv_obj_get_scroll_y(fm.table), h = lv_obj_get_content_height(fm.table);
    if (top - tb->row_h[0] < sy) lv_obj_scroll_to_y(fm.table, top - tb->row_h[0], LV_ANIM_OFF);
    else if (bot > sy + h) lv_obj_scroll_to_y(fm.table, bot - h, LV_ANIM_OFF);
}

static void update_status(void)
{
    if (!fm.root) return;
    char a[64], b[96], txt[PATH_MAX + 160];
    if (!fm.nsel) {
        struct statvfs vs;
        b[0] = 0;
        if (!statvfs(fm.cwd, &vs) && vs.f_blocks) {
            human(a, sizeof(a), (long long)vs.f_bavail * vs.f_frsize);
            snprintf(b, sizeof(b), ", free space %s", a);
        }
        snprintf(txt, sizeof(txt), "%d item%s%s", fm.n, fm.n == 1 ? "" : "s", b);
    } else if (fm.nsel == 1) {
        int i = 0;
        while (!fm.sel[i]) i++;
        if (fm.e[i].dir) snprintf(txt, sizeof(txt), "\"%s\" selected", fm.e[i].name);
        else {
            human(a, sizeof(a), fm.e[i].size);
            snprintf(txt, sizeof(txt), "\"%s\" selected (%s)", fm.e[i].name, a);
        }
    } else {
        long long sum = 0;
        int dirs = 0;
        for (int i = 0; i < fm.n; i++) if (fm.sel[i]) { if (fm.e[i].dir) dirs++; else sum += fm.e[i].size; }
        human(a, sizeof(a), sum);
        if (dirs == fm.nsel) snprintf(txt, sizeof(txt), "%d folders selected", fm.nsel);
        else snprintf(txt, sizeof(txt), "%d items selected (%s%s)", fm.nsel, a, dirs ? " in files" : "");
    }
    lv_label_set_text(fm.status, txt);
}

/* ---- opening ------------------------------------------------------------ */
static void preview_text(const char *path, const char *name, const struct stat *st)
{
    char *buf = malloc(4097);
    int n = sysinfo_read_file(path, buf, 4096);
    int printable = 1;
    for (int i = 0; i < n && i < 512; i++)
        if ((unsigned char)buf[i] < 9 || ((unsigned char)buf[i] > 13 && (unsigned char)buf[i] < 32)) { printable = 0; break; }
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, name);
    lv_msgbox_add_close_button(mb);
    if (n > 0 && printable) {
        buf[n] = 0;
        lv_obj_t *ta = lv_textarea_create(lv_msgbox_get_content(mb));
        lv_obj_set_size(ta, LV_PCT(100), 300);
        lv_obj_set_style_text_font(ta, &lv_font_unscii_8, 0);
        lv_textarea_set_text(ta, buf);
        lv_obj_set_width(mb, 700);
    } else {
        lv_msgbox_add_text_fmt(mb, "%s\n%lld bytes, mode %o", path, (long long)st->st_size, st->st_mode & 07777);
        lv_obj_set_width(mb, 420);
    }
    free(buf);
}

static void open_entry(int i)
{
    if (i < 0 || i >= fm.n) return;
    char p[PATH_MAX];
    join(p, sizeof(p), fm.cwd, fm.e[i].name);
    if (fm.e[i].dir) { fm_open_dir(p); return; }
    struct stat st;
    if (stat(p, &st)) { desk_msgbox("Files", strerror(errno)); return; }
    const char *name = fm.e[i].name;
    if (ext_in(name, "avi mp4 mkv mp3 m4a")) { video_play_file(p); return; }   /* takes the screen until a key/click */
    if (ext_in(name, "wav")) {
        audio_play_file(p);
        char msg[PATH_MAX + 64];
        snprintf(msg, sizeof(msg), "Playing %s\n(%lld KB)", p, (long long)st.st_size / 1024);
        desk_msgbox("Audio", msg);
        return;
    }
    preview_text(p, name, &st);
}

static void open_selection(void)
{
    if (fm.nsel != 1) return;
    for (int i = 0; i < fm.n; i++) if (fm.sel[i]) { open_entry(i); return; }
}

/* ---- the background operation ------------------------------------------- */
static void strv_free(char **v, int n)
{
    if (!v) return;
    for (int i = 0; i < n; i++) free(v[i]);
    free(v);
}

static void job_show(void)
{
    if (!fm.root) return;
    bool on = job.pid > 0;
    if (on) { lv_obj_remove_flag(fm.job_row, LV_OBJ_FLAG_HIDDEN); lv_obj_add_flag(fm.status, LV_OBJ_FLAG_HIDDEN); }
    else { lv_obj_add_flag(fm.job_row, LV_OBJ_FLAG_HIDDEN); lv_obj_remove_flag(fm.status, LV_OBJ_FLAG_HIDDEN); }
}

static void job_finish(int status)
{
    lv_timer_delete(job.timer);
    job.timer = NULL;
    close(job.fd);
    job.pid = 0;
    bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    if (job.cancelled) {
        /* the item in progress is half there: removed as Nautilus does -- but only while its
         * source still exists (a copy, or a move cp had not finished), so nothing is lost */
        char msg[PATH_MAX + 96];
        struct stat st;
        if (job.kind == JOB_DELETE) snprintf(msg, sizeof(msg), "Delete cancelled.");
        else if (job.cur < job.n && !lstat(job.src[job.cur], &st) && !lstat(job.dst[job.cur], &st)) {
            pid_t c = fork();
            if (c == 0) { execlp("rm", "rm", "-rf", job.dst[job.cur], (char *)NULL); _exit(127); }
            if (c > 0) waitpid(c, NULL, 0);
            snprintf(msg, sizeof(msg), "Cancelled. The partly %s \"%s\" was removed.",
                     job.kind == JOB_COPY ? "copied" : "moved", base_name(job.dst[job.cur]));
        } else
            snprintf(msg, sizeof(msg), "Cancelled.");
        desk_msgbox("Files", msg);
    } else if (!ok) {
        char err[512] = "";
        int n = sysinfo_read_file(JOB_ERR, err, sizeof(err) - 1);
        if (n > 0) err[n] = 0;
        char msg[700];
        snprintf(msg, sizeof(msg), "%s failed:\n%s", job.kind == JOB_COPY ? "Copying" : job.kind == JOB_MOVE ? "Moving" : "Deleting",
                 err[0] ? err : "unknown error");
        desk_msgbox("Files", msg);
    }
    if (job.kind == JOB_MOVE && !job.cancelled) {          /* a cut is pasted once, as in Nautilus */
        strv_free(clip.paths, clip.n);
        clip.paths = NULL;
        clip.n = 0;
    }
    unlink(JOB_ERR);
    if (fm.root) {
        job_show();
        fm_reload(job.kind == JOB_DELETE);
        if (job.kind != JOB_DELETE && !strcmp(job.dir, fm.cwd)) {   /* select what arrived */
            char **names = malloc(job.n * sizeof(*names));
            for (int i = 0; i < job.n; i++) names[i] = (char *)base_name(job.dst[i]);
            select_names(names, job.n);
            free(names);
        }
    }
    strv_free(job.src, job.n);
    strv_free(job.dst, job.n);
    free(job.size);
    job.src = job.dst = NULL;
    job.size = NULL;
}

static void job_tick(lv_timer_t *t)
{
    (void)t;
    int idx, st;
    while (read(job.fd, &idx, sizeof(idx)) == sizeof(idx)) job.cur = idx;
    if (waitpid(job.pid, &st, WNOHANG) == job.pid) { job_finish(st); return; }
    if (!fm.root) return;
    long long done = 0;
    for (int i = 0; i < job.cur && i < job.n; i++) done += job.size[i];
    if (job.kind != JOB_DELETE && job.cur < job.n) {        /* how far the current item got */
        long cnt = 0, budget = 2000;
        done += tree_size(job.dst[job.cur], &cnt, &budget);
    }
    if (done > job.total) done = job.total;
    int pct = job.total > 0 ? (int)(done * 100 / job.total) : job.n ? job.cur * 100 / job.n : 0;
    char a[32], b[32];
    human(a, sizeof(a), done);
    human(b, sizeof(b), job.total);
    const char *verb = job.kind == JOB_COPY ? "Copying" : job.kind == JOB_MOVE ? "Moving" : "Deleting";
    const char *what = job.cur < job.n ? base_name(job.src[job.cur]) : "";
    if (job.kind == JOB_DELETE) lv_label_set_text_fmt(fm.job_lbl, "%s \"%s\" (%d of %d)", verb, what, job.cur + 1, job.n);
    else lv_label_set_text_fmt(fm.job_lbl, "%s \"%s\" (%d of %d), %s of %s", verb, what, job.cur + 1, job.n, a, b);
    lv_bar_set_value(fm.job_bar, pct, LV_ANIM_OFF);
}

/* takes ownership of src / dst (dst NULL for a delete) */
static void job_start(int kind, char **src, char **dst, int n, const char *dir)
{
    if (job.pid > 0) {
        desk_msgbox("Files", "Another copy, move or delete is still running.");
        strv_free(src, n);
        strv_free(dst, n);
        return;
    }
    int pfd[2];
    if (pipe2(pfd, O_CLOEXEC)) { desk_msgbox("Files", strerror(errno)); strv_free(src, n); strv_free(dst, n); return; }
    memset(&job, 0, sizeof(job));
    job.kind = kind;
    job.n = n;
    job.src = src;
    job.dst = dst;
    snprintf(job.dir, sizeof(job.dir), "%s", dir ? dir : "");
    job.size = calloc(n, sizeof(*job.size));
    for (int i = 0; i < n; i++) {                           /* for the progress bar */
        long cnt = 0, budget = 50000;
        job.size[i] = kind == JOB_DELETE ? 0 : tree_size(src[i], &cnt, &budget);
        job.total += job.size[i];
    }
    pid_t p = fork();
    if (p == 0) {
        /* own process group (Cancel kills cp too); drop the desktop's descriptors -- the
         * instance lock among them, or a restarted desktop would find it still held */
        setpgid(0, 0);
        for (int fd = 3; fd < 1024; fd++) if (fd != pfd[1]) close(fd);
        int nul = open("/dev/null", O_RDWR);
        if (nul >= 0) { dup2(nul, 0); dup2(nul, 1); if (nul > 2) close(nul); }
        int err = open(JOB_ERR, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (err >= 0) { dup2(err, 2); if (err > 2) close(err); }
        int fail = 0;
        for (int i = 0; i < n; i++) {
            if (write(pfd[1], &i, sizeof(i)) < 0) { /* the desktop went away: carry on */ }
            pid_t c = fork();
            if (c == 0) {
                if (kind == JOB_COPY) execlp("cp", "cp", "-a", src[i], dst[i], (char *)NULL);
                else if (kind == JOB_MOVE) execlp("mv", "mv", src[i], dst[i], (char *)NULL);
                else execlp("rm", "rm", "-rf", src[i], (char *)NULL);
                _exit(127);
            }
            int st = 0;
            if (c < 0 || waitpid(c, &st, 0) < 0 || !WIFEXITED(st) || WEXITSTATUS(st)) fail = 1;
        }
        _exit(fail);
    }
    close(pfd[1]);
    if (p < 0) {
        close(pfd[0]);
        desk_msgbox("Files", strerror(errno));
        strv_free(job.src, n);
        strv_free(job.dst, n);
        free(job.size);
        memset(&job, 0, sizeof(job));
        return;
    }
    fcntl(pfd[0], F_SETFL, O_NONBLOCK);
    job.pid = p;
    job.fd = pfd[0];
    job.timer = lv_timer_create(job_tick, 250, NULL);
    job_show();
    job_tick(job.timer);
}

static void job_cancel(lv_event_t *e)
{
    (void)e;
    if (job.pid <= 0) return;
    job.cancelled = true;
    kill(-job.pid, SIGTERM);
}

/* ---- clipboard and operations ------------------------------------------- */
static char **selected_paths(int *n)
{
    char **v = malloc((fm.nsel ? fm.nsel : 1) * sizeof(*v)), p[PATH_MAX];
    *n = 0;
    for (int i = 0; i < fm.n; i++)
        if (fm.sel[i]) { join(p, sizeof(p), fm.cwd, fm.e[i].name); v[(*n)++] = strdup(p); }
    return v;
}

static void clip_set(bool cut)
{
    if (!fm.nsel) return;
    strv_free(clip.paths, clip.n);
    clip.paths = selected_paths(&clip.n);
    clip.cut = cut;
    lv_label_set_text_fmt(fm.status, "%d item%s %s: paste with Ctrl+V or the context menu", clip.n,
                          clip.n == 1 ? "" : "s", cut ? "cut" : "copied");
}

static void do_paste(const char *dir)
{
    if (!clip.n) return;
    char **src = malloc(clip.n * sizeof(*src)), **dst = malloc(clip.n * sizeof(*dst));
    char name[NAME_MAX + 32], par[PATH_MAX], p[PATH_MAX];
    int m = 0;
    for (int i = 0; i < clip.n; i++) {
        const char *s = clip.paths[i];
        struct stat st;
        if (lstat(s, &st)) continue;                        /* gone meanwhile */
        parent_dir(par, sizeof(par), s);
        if (clip.cut && !strcmp(par, dir)) continue;         /* moved onto itself: nothing to do */
        size_t l = strlen(s);
        if (S_ISDIR(st.st_mode) && !strncmp(dir, s, l) && (dir[l] == '/' || !dir[l])) {
            char msg[PATH_MAX + 64];
            snprintf(msg, sizeof(msg), "\"%s\" cannot be %s into itself.", base_name(s), clip.cut ? "moved" : "copied");
            desk_msgbox("Files", msg);
            continue;
        }
        unique_name(name, sizeof(name), dir, base_name(s), S_ISDIR(st.st_mode));
        join(p, sizeof(p), dir, name);
        src[m] = strdup(s);
        dst[m] = strdup(p);
        m++;
    }
    if (!m) { free(src); free(dst); return; }
    job_start(clip.cut ? JOB_MOVE : JOB_COPY, src, dst, m, dir);
}

static void delete_confirmed(lv_event_t *e)
{
    lv_obj_t *mb = lv_event_get_user_data(e);
    int n;
    char **v = selected_paths(&n);
    lv_msgbox_close(mb);
    if (n) job_start(JOB_DELETE, v, NULL, n, NULL);
    else free(v);
    focus_table();
}

static void msgbox_cancel(lv_event_t *e)
{
    lv_msgbox_close(lv_event_get_user_data(e));
    focus_table();
}

static void ask_delete(void)
{
    if (!fm.nsel) return;
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_title(mb, "Delete permanently?");
    if (fm.nsel == 1) {
        int i = 0;
        while (!fm.sel[i]) i++;
        lv_msgbox_add_text_fmt(mb, "\"%s\" will be deleted for good: there is no trash on this board.", fm.e[i].name);
    } else
        lv_msgbox_add_text_fmt(mb, "%d selected items will be deleted for good: there is no trash on this board.", fm.nsel);
    lv_obj_t *c = lv_msgbox_add_footer_button(mb, "Cancel");
    lv_obj_add_event_cb(c, msgbox_cancel, LV_EVENT_CLICKED, mb);
    lv_obj_t *d = lv_msgbox_add_footer_button(mb, LV_SYMBOL_TRASH " Delete");
    lv_obj_set_style_bg_color(d, lv_palette_main(LV_PALETTE_RED), 0);
    lv_obj_add_event_cb(d, delete_confirmed, LV_EVENT_CLICKED, mb);
    lv_obj_set_width(mb, 440);
    lv_group_focus_obj(c);
}

/* ---- name dialog (Rename, New Folder) ----------------------------------- */
typedef struct {
    lv_obj_t *mb, *ta, *err;
    bool rename;
    char old[NAME_MAX + 1];
    int stem;                       /* chars of the name before its extension */
    bool fresh;                     /* the stem is still highlighted: the first key replaces it */
} namedlg_t;

static void name_dlg_free(lv_event_t *e) { free(lv_event_get_user_data(e)); }

static void name_dlg_ok(lv_event_t *e)
{
    namedlg_t *d = lv_event_get_user_data(e);
    const char *nn = lv_textarea_get_text(d->ta);
    char p[PATH_MAX], np[PATH_MAX], keep[NAME_MAX + 1];
    struct stat st;
    if (!nn[0] || strchr(nn, '/') || !strcmp(nn, ".") || !strcmp(nn, "..") || strlen(nn) > NAME_MAX) {
        lv_label_set_text(d->err, "Not a valid name (no \"/\", not \".\" or \"..\").");
        return;
    }
    if (d->rename && !strcmp(nn, d->old)) { lv_msgbox_close(d->mb); focus_table(); return; }
    join(np, sizeof(np), fm.cwd, nn);
    if (!lstat(np, &st)) { lv_label_set_text(d->err, "That name is taken in this folder."); return; }
    if (d->rename) {
        join(p, sizeof(p), fm.cwd, d->old);
        if (rename(p, np)) { lv_label_set_text_fmt(d->err, "Renaming failed: %s", strerror(errno)); return; }
    } else if (mkdir(np, 0755)) {
        lv_label_set_text_fmt(d->err, "Creating the folder failed: %s", strerror(errno));
        return;
    }
    snprintf(keep, sizeof(keep), "%s", nn);
    lv_msgbox_close(d->mb);
    fm_reload(false);
    char *names[1] = { keep };
    select_names(names, 1);
    if (fm.cursor >= 0) scroll_to_entry(fm.cursor);
    focus_table();
}

/* as in Nautilus: the name without its extension starts highlighted, and typing
 * replaces it (LVGL's textarea does not replace a selection by itself) */
static void name_dlg_unfresh(namedlg_t *d)
{
    lv_obj_t *l = lv_textarea_get_label(d->ta);
    d->fresh = false;
    lv_label_set_text_selection_start(l, LV_DRAW_LABEL_NO_TXT_SEL);
    lv_label_set_text_selection_end(l, LV_DRAW_LABEL_NO_TXT_SEL);
    lv_obj_invalidate(d->ta);
}

static void name_dlg_prekey(lv_event_t *e)
{
    namedlg_t *d = lv_event_get_user_data(e);
    if (!d->fresh) return;
    uint32_t k = lv_event_get_key(e);
    bool printable = k >= 32 && k != LV_KEY_DEL && k < 0xF700;
    name_dlg_unfresh(d);
    if (printable || k == LV_KEY_BACKSPACE || k == LV_KEY_DEL) {
        char rest[NAME_MAX + 1];
        snprintf(rest, sizeof(rest), "%s", lv_textarea_get_text(d->ta) + d->stem);
        lv_textarea_set_text(d->ta, rest);
        lv_textarea_set_cursor_pos(d->ta, 0);
        if (!printable) lv_event_stop_processing(e);       /* the stem is gone: that was the delete */
    }
}

static void name_dlg_press(lv_event_t *e)
{
    namedlg_t *d = lv_event_get_user_data(e);
    if (d->fresh) name_dlg_unfresh(d);
}

static void name_dlg_key(lv_event_t *e)
{
    if (lv_event_get_key(e) == LV_KEY_ESC) { namedlg_t *d = lv_event_get_user_data(e); lv_msgbox_close(d->mb); focus_table(); }
}

static void name_dialog(bool rename)
{
    namedlg_t *d = calloc(1, sizeof(*d));
    d->rename = rename;
    if (rename) {
        int i = 0;
        while (i < fm.n && !fm.sel[i]) i++;
        if (i == fm.n || fm.nsel != 1) { free(d); return; }
        snprintf(d->old, sizeof(d->old), "%s", fm.e[i].name);
    }
    d->mb = lv_msgbox_create(NULL);
    lv_obj_add_event_cb(d->mb, name_dlg_free, LV_EVENT_DELETE, d);
    lv_msgbox_add_title(d->mb, rename ? "Rename" : "New Folder");
    lv_obj_t *c = lv_msgbox_get_content(d->mb);
    lv_obj_set_flex_flow(c, LV_FLEX_FLOW_COLUMN);
    lv_obj_t *l = lv_label_create(c);
    lv_label_set_text(l, rename ? "New name" : "Folder name");
    d->ta = lv_textarea_create(c);
    lv_textarea_set_one_line(d->ta, true);
    lv_obj_set_width(d->ta, LV_PCT(100));
    lv_textarea_set_text(d->ta, rename ? d->old : "Untitled Folder");
    const char *t = lv_textarea_get_text(d->ta), *dot = strrchr(t, '.');
    struct stat st;
    char op[PATH_MAX];
    join(op, sizeof(op), fm.cwd, d->old);
    bool isdir = rename && !stat(op, &st) && S_ISDIR(st.st_mode);
    d->stem = dot && dot != t && rename && !isdir ? (int)(dot - t) : (int)strlen(t);
    d->fresh = true;
    lv_obj_t *lbl = lv_textarea_get_label(d->ta);
    lv_label_set_text_selection_start(lbl, 0);
    lv_label_set_text_selection_end(lbl, d->stem);
    lv_textarea_set_cursor_pos(d->ta, d->stem);
    lv_obj_add_event_cb(d->ta, name_dlg_prekey, LV_EVENT_KEY | LV_EVENT_PREPROCESS, d);
    lv_obj_add_event_cb(d->ta, name_dlg_press, LV_EVENT_PRESSED, d);
    lv_obj_add_event_cb(d->ta, name_dlg_ok, LV_EVENT_READY, d);     /* Enter */
    lv_obj_add_event_cb(d->ta, name_dlg_key, LV_EVENT_KEY, d);
    d->err = lv_label_create(c);
    lv_label_set_text(d->err, "");
    lv_obj_set_style_text_color(d->err, lv_palette_main(LV_PALETTE_RED), 0);
    lv_obj_t *b = lv_msgbox_add_footer_button(d->mb, "Cancel");
    lv_obj_add_event_cb(b, msgbox_cancel, LV_EVENT_CLICKED, d->mb);
    b = lv_msgbox_add_footer_button(d->mb, rename ? "Rename" : "Create");
    lv_obj_add_event_cb(b, name_dlg_ok, LV_EVENT_CLICKED, d);
    lv_obj_set_width(d->mb, 460);
    lv_group_focus_obj(d->ta);
}

/* ---- properties --------------------------------------------------------- */
static void prop_row(lv_obj_t *parent, const char *k, const char *v)
{
    lv_obj_t *r = lv_obj_create(parent);
    lv_obj_remove_style_all(r);
    lv_obj_set_size(r, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(r, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(r, 10, 0);
    lv_obj_t *a = lv_label_create(r);
    lv_label_set_text(a, k);
    lv_obj_set_width(a, 110);
    lv_obj_set_style_text_opa(a, LV_OPA_70, 0);
    lv_obj_t *b = lv_label_create(r);
    lv_label_set_text(b, v);
    lv_label_set_long_mode(b, LV_LABEL_LONG_WRAP);
    lv_obj_set_flex_grow(b, 1);
}

static void fmt_tree(char *o, size_t n, const char *path)
{
    long cnt = 0, budget = 20000;
    char a[32], b[40];
    long long sz = tree_size(path, &cnt, &budget);
    human(a, sizeof(a), sz);
    grouped(b, sizeof(b), sz);
    snprintf(o, n, "%s%ld item%s, totalling %s (%s bytes)", budget <= 0 ? "more than " : "", cnt, cnt == 1 ? "" : "s", a, b);
}

static void properties(void)
{
    char v[PATH_MAX + 64], a[32], b[40];
    lv_obj_t *mb = lv_msgbox_create(NULL);
    lv_msgbox_add_close_button(mb);
    lv_obj_t *c = lv_msgbox_get_content(mb);
    lv_obj_set_flex_flow(c, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(c, 4, 0);
    lv_obj_set_width(mb, 560);

    if (fm.nsel > 1) {                                       /* several items: a summary */
        lv_msgbox_add_title(mb, "Properties");
        snprintf(v, sizeof(v), "%d items", fm.nsel);
        prop_row(c, "Selected", v);
        long long sum = 0;
        long cnt = 0, budget = 20000;
        char p[PATH_MAX];
        for (int i = 0; i < fm.n; i++)
            if (fm.sel[i]) { join(p, sizeof(p), fm.cwd, fm.e[i].name); sum += tree_size(p, &cnt, &budget); }
        human(a, sizeof(a), sum);
        grouped(b, sizeof(b), sum);
        snprintf(v, sizeof(v), "%s%s (%s bytes)", budget <= 0 ? "more than " : "", a, b);
        prop_row(c, "Total size", v);
        prop_row(c, "Location", fm.cwd);
        return;
    }
    char path[PATH_MAX];
    if (fm.nsel == 1) {
        int i = 0;
        while (!fm.sel[i]) i++;
        join(path, sizeof(path), fm.cwd, fm.e[i].name);
    } else
        snprintf(path, sizeof(path), "%s", fm.cwd);          /* the background: this folder */
    struct stat ls, st;
    if (lstat(path, &ls)) { lv_msgbox_add_title(mb, "Properties"); prop_row(c, "Error", strerror(errno)); return; }
    st = ls;
    bool lnk = S_ISLNK(ls.st_mode);
    if (lnk) stat(path, &st);
    const char *name = strcmp(path, "/") ? base_name(path) : "/";
    lv_msgbox_add_title(mb, name);
    prop_row(c, "Name", name);
    if (lnk) {
        char t[PATH_MAX];
        ssize_t k = readlink(path, t, sizeof(t) - 1);
        t[k > 0 ? k : 0] = 0;
        snprintf(v, sizeof(v), "Link to %s (%s)", t, type_of(name, &st));
        prop_row(c, "Type", v);
    } else
        prop_row(c, "Type", type_of(name, &st));
    if (S_ISDIR(st.st_mode)) {
        fmt_tree(v, sizeof(v), path);
        prop_row(c, "Contents", v);
    } else {
        human(a, sizeof(a), st.st_size);
        grouped(b, sizeof(b), st.st_size);
        snprintf(v, sizeof(v), "%s (%s bytes)", a, b);
        prop_row(c, "Size", v);
    }
    char par[PATH_MAX];
    parent_dir(par, sizeof(par), path);
    prop_row(c, "Location", strcmp(path, "/") ? par : "-");
    struct tm tm;
    localtime_r(&st.st_mtime, &tm);
    strftime(v, sizeof(v), "%a %e %B %Y, %H:%M:%S", &tm);
    prop_row(c, "Modified", v);
    localtime_r(&st.st_atime, &tm);
    strftime(v, sizeof(v), "%a %e %B %Y, %H:%M:%S", &tm);
    prop_row(c, "Accessed", v);
    char rwx[10];
    const char *bits = "rwxrwxrwx";
    for (int k = 0; k < 9; k++) rwx[k] = (st.st_mode & (0400 >> k)) ? bits[k] : '-';
    rwx[9] = 0;
    snprintf(v, sizeof(v), "%s (%04o)", rwx, st.st_mode & 07777);
    prop_row(c, "Permissions", v);
    struct passwd *pw = getpwuid(st.st_uid);
    struct group *gr = getgrgid(st.st_gid);
    snprintf(v, sizeof(v), "%s (%u), group %s (%u)", pw ? pw->pw_name : "?", (unsigned)st.st_uid,
             gr ? gr->gr_name : "?", (unsigned)st.st_gid);
    prop_row(c, "Owner", v);
    if (S_ISDIR(st.st_mode)) {
        struct statvfs vs;
        if (!statvfs(path, &vs) && vs.f_blocks) {
            human(a, sizeof(a), (long long)vs.f_bavail * vs.f_frsize);
            human(b, sizeof(b), (long long)vs.f_blocks * vs.f_frsize);
            snprintf(v, sizeof(v), "%s free of %s", a, b);
            prop_row(c, "Free space", v);
        }
    }
}

/* ---- context menus ------------------------------------------------------ */
static void act_open(void *u) { (void)u; open_selection(); }
static void act_cut(void *u) { (void)u; clip_set(true); }
static void act_copy(void *u) { (void)u; clip_set(false); }
static void act_paste(void *u) { (void)u; do_paste(fm.cwd); }
static void act_paste_into(void *u)
{
    (void)u;
    for (int i = 0; i < fm.n; i++)
        if (fm.sel[i] && fm.e[i].dir) { char p[PATH_MAX]; join(p, sizeof(p), fm.cwd, fm.e[i].name); do_paste(p); return; }
}
static void act_rename(void *u) { (void)u; name_dialog(true); }
static void act_delete(void *u) { (void)u; ask_delete(); }
static void act_props(void *u) { (void)u; properties(); }
static void act_new_folder(void *u) { (void)u; name_dialog(false); }
static void act_select_all(void *u) { (void)u; select_all(); }
static void act_hidden(void *u) { (void)u; s_hidden = !s_hidden; fm_reload(true); }

static void context_menu(lv_event_t *e)
{
    lv_point_t *p = lv_event_get_param(e);
    desk_context_take();
    int r = row_at(p), i = r - 1;
    if (i >= 0 && i < fm.n) {
        if (!fm.sel[i]) { sel_clear(); sel_set(i, true); fm.anchor = fm.cursor = i; sel_changed(); }
        bool one = fm.nsel == 1, onedir = one && fm.e[i].dir;
        desk_menu_item_t it[] = {
            { onedir ? LV_SYMBOL_DIRECTORY "  Open" : LV_SYMBOL_PLAY "  Open", "Enter", act_open, NULL, !one },
            { NULL },
            { LV_SYMBOL_CUT "  Cut", "Ctrl+X", act_cut, NULL, false },
            { LV_SYMBOL_COPY "  Copy", "Ctrl+C", act_copy, NULL, false },
            { LV_SYMBOL_PASTE "  Paste Into Folder", NULL, act_paste_into, NULL, !(onedir && clip.n) },
            { NULL },
            { LV_SYMBOL_EDIT "  Rename...", "F2", act_rename, NULL, !one },
            { LV_SYMBOL_TRASH "  Delete...", "Delete", act_delete, NULL, false },
            { NULL },
            { LV_SYMBOL_LIST "  Properties", NULL, act_props, NULL, false },
        };
        desk_menu(p->x, p->y, it, sizeof(it) / sizeof(it[0]));
    } else {
        if (fm.nsel) { sel_clear(); sel_changed(); }
        desk_menu_item_t it[] = {
            { LV_SYMBOL_DIRECTORY "  New Folder...", NULL, act_new_folder, NULL, false },
            { LV_SYMBOL_PASTE "  Paste", "Ctrl+V", act_paste, NULL, clip.n == 0 },
            { NULL },
            { LV_SYMBOL_OK "  Select All", "Ctrl+A", act_select_all, NULL, fm.n == 0 },
            { s_hidden ? LV_SYMBOL_EYE_CLOSE "  Hide Hidden Files" : LV_SYMBOL_EYE_OPEN "  Show Hidden Files", "Ctrl+H", act_hidden, NULL, false },
            { NULL },
            { LV_SYMBOL_LIST "  Properties", NULL, act_props, NULL, false },
        };
        desk_menu(p->x, p->y, it, sizeof(it) / sizeof(it[0]));
    }
}

/* ---- table input -------------------------------------------------------- */
static bool pointer_event(void)
{
    lv_indev_t *in = lv_indev_active();
    return in && lv_indev_get_type(in) == LV_INDEV_TYPE_POINTER;
}

static void table_pressed(lv_event_t *e)
{
    (void)e;
    if (!pointer_event()) return;                             /* Enter arrives as a keypad press too */
    lv_point_t p;
    lv_indev_get_point(lv_indev_active(), &p);
    int r = row_at(&p), i = r - 1;
    if (r == 0) return;                                       /* the header */
    if (i < 0 || i >= fm.n) {                                 /* below the last row: clear */
        fm.click_row = -1;
        if (!input_ctrl() && !input_shift() && fm.nsel) { sel_clear(); sel_changed(); }
        return;
    }
    if (input_ctrl()) { sel_set(i, !fm.sel[i]); fm.anchor = i; }
    else if (input_shift() && fm.anchor >= 0) { sel_clear(); sel_range(fm.anchor, i); }
    else { sel_clear(); sel_set(i, true); fm.anchor = i; }
    fm.cursor = i;
    sel_changed();
}

static void table_clicked(lv_event_t *e)
{
    (void)e;
    if (!pointer_event() || input_ctrl() || input_shift()) return;
    int i = fm.cursor;
    uint32_t now = lv_tick_get();
    if (i >= 0 && i == fm.click_row && lv_tick_diff(now, fm.click_tick) < DCLICK_MS) {
        fm.click_row = -1;
        open_entry(i);
        return;
    }
    fm.click_row = i;
    fm.click_tick = now;
}

static void move_cursor(int to, bool extend)
{
    if (!fm.n) return;
    if (to < 0) to = 0;
    if (to >= fm.n) to = fm.n - 1;
    if (extend && fm.anchor >= 0) { sel_clear(); sel_range(fm.anchor, to); }
    else { sel_clear(); sel_set(to, true); fm.anchor = to; }
    fm.cursor = to;
    scroll_to_entry(to);
    sel_changed();
}

/* keys reach the table first (preprocess) and stop there: its own cell navigation stays out */
static void table_key(lv_event_t *e)
{
    uint32_t k = lv_event_get_key(e);
    lv_event_stop_processing(e);
    if (k == LV_KEY_ESC && desk_menu_close()) return;
    if (input_ctrl()) {
        switch (k) {
        case 'a': case 'A': select_all(); return;
        case 'c': case 'C': clip_set(false); return;
        case 'x': case 'X': clip_set(true); return;
        case 'v': case 'V': do_paste(fm.cwd); return;
        case 'h': case 'H': act_hidden(NULL); return;
        case 'r': case 'R': fm_reload(true); return;
        default: return;
        }
    }
    int cur = fm.cursor >= 0 ? fm.cursor : -1;
    switch (k) {
    case LV_KEY_DOWN: move_cursor(cur + 1, input_shift()); break;
    case LV_KEY_UP: move_cursor(cur < 0 ? 0 : cur - 1, input_shift()); break;
    case LV_KEY_HOME: move_cursor(0, input_shift()); break;
    case LV_KEY_END: move_cursor(fm.n - 1, input_shift()); break;
    case LV_KEY_ENTER: if (fm.nsel == 1) open_selection(); else if (cur >= 0) open_entry(cur); break;
    case LV_KEY_BACKSPACE: go_up(); break;
    case LV_KEY_DEL: ask_delete(); break;
    case DESK_KEY_F2: name_dialog(true); break;
    case DESK_KEY_F5: fm_reload(true); break;
    case LV_KEY_ESC: if (fm.nsel) { sel_clear(); sel_changed(); } break;
    default: break;
    }
}

/* selected rows painted in the theme's colour, whatever state the table gives a cell */
static void table_draw(lv_event_t *e)
{
    lv_draw_task_t *t = lv_event_get_draw_task(e);
    lv_draw_dsc_base_t *b = lv_draw_task_get_draw_dsc(t);
    if (b->part != LV_PART_ITEMS) return;
    uint32_t row = b->id1;
    bool sel = row > 0 && row - 1 < (uint32_t)fm.n && fm.sel[row - 1];
    lv_draw_task_type_t ty = lv_draw_task_get_type(t);
    if (ty == LV_DRAW_TASK_TYPE_FILL) {
        lv_draw_fill_dsc_t *f = lv_draw_task_get_fill_dsc(t);
        f->color = row == 0 ? fm.head_bg : sel ? fm.sel_bg : fm.row_bg;
        f->opa = LV_OPA_COVER;
    } else if (ty == LV_DRAW_TASK_TYPE_LABEL) {
        lv_draw_label_dsc_t *l = lv_draw_task_get_label_dsc(t);
        if (sel) l->color = lv_color_white();
        if (row == 0) l->opa = LV_OPA_70;
    }
}

/* ---- microSD row and places --------------------------------------------- */
static bool sd_present(void) { return access("/dev/mmcblk0", F_OK) == 0; }
static bool sd_mounted(void)
{
    char buf[4096];
    if (sysinfo_read_file("/proc/mounts", buf, sizeof(buf)) <= 0) return false;
    return strstr(buf, " " SD_DIR " ") != NULL;
}

static void sd_update(void)
{
    if (!sd_present()) {
        lv_label_set_text(fm.sd_lbl, LV_SYMBOL_SD_CARD " microSD: no card");
        lv_obj_add_state(fm.sd_btn, LV_STATE_DISABLED);
    } else if (sd_mounted()) {
        struct statvfs st;
        if (statvfs(SD_DIR, &st) == 0)
            lv_label_set_text_fmt(fm.sd_lbl, LV_SYMBOL_SD_CARD " microSD: mounted at " SD_DIR ", %llu MB, %llu MB free",
                                  ((unsigned long long)st.f_blocks * st.f_frsize) >> 20,
                                  ((unsigned long long)st.f_bavail * st.f_frsize) >> 20);
        else
            lv_label_set_text(fm.sd_lbl, LV_SYMBOL_SD_CARD " microSD: mounted at " SD_DIR);
        lv_obj_remove_state(fm.sd_btn, LV_STATE_DISABLED);
        lv_label_set_text(fm.sd_btn_lbl, LV_SYMBOL_EJECT " Unmount");
    } else {
        char sz[32] = "";
        if (sysinfo_read_file("/sys/class/block/mmcblk0/size", sz, sizeof(sz)) > 0)
            lv_label_set_text_fmt(fm.sd_lbl, LV_SYMBOL_SD_CARD " microSD: %llu MB card present, not mounted (safe to remove)",
                                  (strtoull(sz, NULL, 10) * 512ULL) >> 20);
        else
            lv_label_set_text(fm.sd_lbl, LV_SYMBOL_SD_CARD " microSD: card present, not mounted");
        lv_obj_remove_state(fm.sd_btn, LV_STATE_DISABLED);
        lv_label_set_text(fm.sd_btn_lbl, LV_SYMBOL_DOWNLOAD " Mount");
    }
}

static bool in_sd(const char *p) { return !strncmp(p, SD_DIR, strlen(SD_DIR)) && (p[strlen(SD_DIR)] == '/' || !p[strlen(SD_DIR)]); }

static void sd_mount_click(lv_event_t *e)
{
    (void)e;
    char out[256];
    bool was = sd_mounted();
    if (was && job.pid > 0 && (in_sd(job.dir) || (job.n && in_sd(job.src[0])))) {
        desk_msgbox("microSD", "A copy, move or delete on the card is still running.");
        return;
    }
    lv_label_set_text(fm.sd_lbl, was ? "unmounting..." : "mounting...");
    lv_refr_now(NULL);
    if (was) {
        if (in_sd(fm.cwd)) fm_open_dir(HOME_DIR);           /* our cwd would keep the card busy */
        sysinfo_run("sync; /etc/init.d/S45sdcard stop 2>&1; umount " SD_DIR " 2>&1", out, sizeof(out));
    } else
        sysinfo_run("/etc/init.d/S45sdcard start 2>&1", out, sizeof(out));
    sd_update();
    bool now = sd_mounted();
    if (was && now && strstr(out, "busy")) desk_msgbox("microSD", "Unmount failed: the card is busy.");
    else if (!was && !now && strstr(out, "not mountable")) desk_msgbox("microSD", out);
    if (!was && now) fm_open_dir(SD_DIR);
}

static void place_click(lv_event_t *e)
{
    const char *p = lv_event_get_user_data(e);
    if (!strcmp(p, SD_DIR) && !sd_mounted()) {
        desk_msgbox("microSD", sd_present() ? "The card is not mounted: press Mount first." : "No card inserted.");
        return;
    }
    fm_open_dir(p);
    focus_table();
}

static void up_click(lv_event_t *e) { (void)e; go_up(); focus_table(); }

/* every 2 s: the card's state, and the folder reloaded if something changed it */
static void fm_tick(lv_timer_t *t)
{
    (void)t;
    sd_update();
    struct stat st;
    if (job.pid <= 0 && !stat(fm.cwd, &st) && st.st_mtime != fm.cwd_mtime) fm_reload(true);
}

static void fm_deleted(lv_event_t *e)
{
    (void)e;
    desk_menu_close();
    if (fm.timer) lv_timer_delete(fm.timer);
    free_entries();
    memset(&fm, 0, sizeof(fm));                               /* the job keeps running; fm.root = NULL */
}

static lv_obj_t *place_button(lv_obj_t *parent, const char *text, const char *path, lv_color_t fg)
{
    lv_obj_t *b = lv_obj_create(parent);
    lv_obj_remove_style_all(b);
    lv_obj_set_size(b, LV_PCT(100), 30);
    lv_obj_set_style_pad_left(b, 8, 0);
    lv_obj_set_style_radius(b, 4, 0);
    lv_obj_set_style_bg_opa(b, LV_OPA_30, LV_STATE_PRESSED);
    lv_obj_set_style_bg_color(b, lv_palette_main(LV_PALETTE_BLUE), LV_STATE_PRESSED);
    lv_obj_add_flag(b, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_t *l = lv_label_create(b);
    lv_label_set_text(l, text);
    lv_obj_set_style_text_color(l, fg, 0);
    lv_obj_align(l, LV_ALIGN_LEFT_MID, 0, 0);
    lv_obj_add_event_cb(b, place_click, LV_EVENT_CLICKED, (void *)path);
    return b;
}

void panel_files(lv_obj_t *parent)
{
    bool dark = desk_is_dark();
    lv_color_t bg = dark ? lv_color_hex(0x1e242c) : lv_color_hex(0xf4f6f8);
    lv_color_t bg2 = dark ? lv_color_hex(0x262d36) : lv_color_white();
    lv_color_t fg = dark ? lv_color_white() : lv_color_black();
    memset(&fm, 0, sizeof(fm));
    fm.root = parent;
    fm.row_bg = bg2;
    fm.head_bg = bg;
    fm.sel_bg = lv_palette_main(LV_PALETTE_BLUE);
    fm.anchor = fm.cursor = fm.click_row = -1;
    lv_obj_add_event_cb(parent, fm_deleted, LV_EVENT_DELETE, NULL);
    /* the labels (card row, path, status, progress) inherit this: the containers below are
     * unstyled, and without it the text came out near-black on the dark theme */
    lv_obj_set_style_text_color(parent, fg, 0);
    lv_obj_set_flex_flow(parent, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(parent, 6, 0);

    /* microSD: state + Mount / Unmount */
    lv_obj_t *row = lv_obj_create(parent);
    lv_obj_remove_style_all(row);
    lv_obj_set_size(row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(row, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    fm.sd_lbl = lv_label_create(row);
    lv_label_set_long_mode(fm.sd_lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_flex_grow(fm.sd_lbl, 1);
    fm.sd_btn = lv_button_create(row);
    lv_obj_set_style_pad_ver(fm.sd_btn, 6, 0);
    fm.sd_btn_lbl = lv_label_create(fm.sd_btn);
    lv_obj_add_event_cb(fm.sd_btn, sd_mount_click, LV_EVENT_CLICKED, NULL);

    /* places | folder */
    lv_obj_t *main = lv_obj_create(parent);
    lv_obj_remove_style_all(main);
    lv_obj_set_width(main, LV_PCT(100));
    lv_obj_set_flex_grow(main, 1);
    lv_obj_set_flex_flow(main, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(main, 6, 0);

    lv_obj_t *places = lv_obj_create(main);
    lv_obj_set_size(places, 150, LV_PCT(100));
    lv_obj_set_style_bg_color(places, bg, 0);
    lv_obj_set_style_pad_all(places, 4, 0);
    lv_obj_set_style_pad_row(places, 2, 0);
    lv_obj_set_flex_flow(places, LV_FLEX_FLOW_COLUMN);
    place_button(places, LV_SYMBOL_HOME "  Home", HOME_DIR, fg);
    place_button(places, LV_SYMBOL_SD_CARD "  SD card", SD_DIR, fg);
    place_button(places, LV_SYMBOL_FILE "  /tmp", "/tmp", fg);
    place_button(places, LV_SYMBOL_SETTINGS "  /etc", "/etc", fg);
    place_button(places, LV_SYMBOL_DRIVE "  File System", "/", fg);

    lv_obj_t *right = lv_obj_create(main);
    lv_obj_remove_style_all(right);
    lv_obj_set_height(right, LV_PCT(100));
    lv_obj_set_flex_grow(right, 1);
    lv_obj_set_flex_flow(right, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(right, 4, 0);

    lv_obj_t *bar = lv_obj_create(right);
    lv_obj_remove_style_all(bar);
    lv_obj_set_size(bar, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(bar, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(bar, 8, 0);
    lv_obj_t *up = lv_button_create(bar);
    lv_obj_set_style_pad_ver(up, 4, 0);
    lv_obj_set_style_pad_hor(up, 10, 0);
    lv_label_set_text(lv_label_create(up), LV_SYMBOL_UP);
    lv_obj_add_event_cb(up, up_click, LV_EVENT_CLICKED, NULL);
    fm.path = lv_label_create(bar);
    lv_label_set_long_mode(fm.path, LV_LABEL_LONG_DOT);
    lv_obj_set_flex_grow(fm.path, 1);

    fm.table = lv_table_create(right);
    lv_obj_set_width(fm.table, LV_PCT(100));
    lv_obj_set_flex_grow(fm.table, 1);
    lv_table_set_column_count(fm.table, 3);
    lv_obj_set_style_bg_color(fm.table, bg2, 0);
    lv_obj_set_style_pad_all(fm.table, 0, 0);
    lv_obj_set_style_border_width(fm.table, 0, LV_PART_ITEMS);
    lv_obj_set_style_pad_ver(fm.table, 5, LV_PART_ITEMS);
    lv_obj_set_style_pad_hor(fm.table, 8, LV_PART_ITEMS);
    lv_obj_set_style_text_color(fm.table, fg, LV_PART_ITEMS);
    lv_obj_add_flag(fm.table, LV_OBJ_FLAG_SEND_DRAW_TASK_EVENTS);
    lv_obj_add_event_cb(fm.table, table_draw, LV_EVENT_DRAW_TASK_ADDED, NULL);
    lv_obj_add_event_cb(fm.table, table_pressed, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(fm.table, table_clicked, LV_EVENT_CLICKED, NULL);
    lv_obj_add_event_cb(fm.table, table_key, LV_EVENT_KEY | LV_EVENT_PREPROCESS, NULL);
    lv_obj_add_event_cb(fm.table, context_menu, (lv_event_code_t)DESK_EVENT_CONTEXT, NULL);

    /* one line each, cut with "..." (LONG_DOT needs a fixed height) */
    int32_t line_h = lv_font_get_line_height(lv_obj_get_style_text_font(right, LV_PART_MAIN));
    fm.status = lv_label_create(right);
    lv_label_set_long_mode(fm.status, LV_LABEL_LONG_DOT);
    lv_obj_set_size(fm.status, LV_PCT(100), line_h);
    lv_obj_set_style_text_opa(fm.status, LV_OPA_80, 0);

    fm.job_row = lv_obj_create(right);
    lv_obj_remove_style_all(fm.job_row);
    lv_obj_set_size(fm.job_row, LV_PCT(100), LV_SIZE_CONTENT);
    lv_obj_set_flex_flow(fm.job_row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(fm.job_row, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(fm.job_row, 8, 0);
    lv_obj_t *col = lv_obj_create(fm.job_row);
    lv_obj_remove_style_all(col);
    lv_obj_set_height(col, LV_SIZE_CONTENT);
    lv_obj_set_flex_grow(col, 1);
    lv_obj_set_flex_flow(col, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_style_pad_row(col, 3, 0);
    fm.job_lbl = lv_label_create(col);
    lv_label_set_long_mode(fm.job_lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_size(fm.job_lbl, LV_PCT(100), line_h);
    fm.job_bar = lv_bar_create(col);
    lv_obj_set_size(fm.job_bar, LV_PCT(100), 8);
    lv_obj_t *cancel = lv_button_create(fm.job_row);
    lv_obj_set_style_pad_ver(cancel, 4, 0);
    lv_label_set_text(lv_label_create(cancel), "Cancel");
    lv_obj_add_event_cb(cancel, job_cancel, LV_EVENT_CLICKED, NULL);

    /* column widths from the space the layout gives the table */
    lv_obj_update_layout(parent);
    int32_t w = lv_obj_get_content_width(fm.table);
    lv_table_set_column_width(fm.table, 1, 100);
    lv_table_set_column_width(fm.table, 2, 130);
    lv_table_set_column_width(fm.table, 0, w - 230 > 120 ? w - 230 : 120);

    sd_update();
    job_show();
    if (job.pid > 0) job_tick(NULL);
    struct stat st;
    fm_open_dir(!stat(s_last_dir, &st) && S_ISDIR(st.st_mode) ? s_last_dir : HOME_DIR);
    fm.timer = lv_timer_create(fm_tick, 2000, NULL);
    focus_table();
}
