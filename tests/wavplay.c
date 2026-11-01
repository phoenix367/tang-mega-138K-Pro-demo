/*
 * wavplay -- play a 16-bit mono/stereo WAV through the kernel's ALSA PCM ioctl API
 * (no alsa-lib) and check the gateware's bit-exactness counters.
 *
 *   wavplay [-D /dev/snd/pcmC1D0p] file.wav
 *
 * Default device: the first card in /proc/asound/cards whose name contains
 * "PT8211".  After snd_pcm drain it reads the audio core's FRAMES / CRC /
 * UNDERRUN / OVERRUN registers (0xE8002000) through /dev/mem and prints
 *   WAVPLAY <file>: frames N/N, crc XXXXXXXX/YYYYYYYY -> MATCH|MISMATCH, ...
 * where the first value is the core's and the second the file's (zlib CRC-32
 * of the data chunk).  MATCH means every sample the DAC was given is the
 * file's, in order, with nothing lost or repeated.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>
#include <sound/asound.h>

#define AUD_BASE 0xE8002000u
#define AUD_UNDERRUN (0x14 / 4)
#define AUD_OVERRUN  (0x18 / 4)
#define AUD_FRAMES   (0x1C / 4)
#define AUD_CRC      (0x20 / 4)

static uint32_t crc_table[256];
static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (c & 1 ? 0xEDB88320u : 0);
        crc_table[i] = c;
    }
}
static uint32_t crc_update(uint32_t c, const uint8_t *p, size_t n)
{
    c = ~c;
    while (n--) c = crc_table[(c ^ *p++) & 0xff] ^ (c >> 8);
    return ~c;
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return p[0] | p[1] << 8; }

/* ---- hw_params helpers (sound/asound.h) ---- */
static struct snd_mask *hw_mask(struct snd_pcm_hw_params *p, int var)
{
    return &p->masks[var - SNDRV_PCM_HW_PARAM_FIRST_MASK];
}
static struct snd_interval *hw_ival(struct snd_pcm_hw_params *p, int var)
{
    return &p->intervals[var - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
}
static void hw_init(struct snd_pcm_hw_params *p)
{
    memset(p, 0, sizeof(*p));
    for (int i = SNDRV_PCM_HW_PARAM_FIRST_MASK; i <= SNDRV_PCM_HW_PARAM_LAST_MASK; i++)
        memset(hw_mask(p, i)->bits, 0xff, sizeof(hw_mask(p, i)->bits));
    for (int i = SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL; i++) {
        hw_ival(p, i)->min = 0;
        hw_ival(p, i)->max = ~0u;
    }
    p->rmask = ~0u;
}
static void hw_set_mask(struct snd_pcm_hw_params *p, int var, unsigned bit)
{
    struct snd_mask *m = hw_mask(p, var);
    memset(m->bits, 0, sizeof(m->bits));
    m->bits[bit >> 5] = 1u << (bit & 31);
}
static void hw_set_ival(struct snd_pcm_hw_params *p, int var, unsigned v)
{
    struct snd_interval *i = hw_ival(p, var);
    i->min = i->max = v;
    i->integer = 1;
}

static int find_device(char *buf, size_t n)
{
    FILE *f = fopen("/proc/asound/cards", "r");
    char line[256];
    if (!f) return -1;
    while (fgets(line, sizeof(line), f)) {
        int idx;
        if (sscanf(line, " %d [", &idx) == 1 && strstr(line, "PT8211")) {
            fclose(f);
            snprintf(buf, n, "/dev/snd/pcmC%dD0p", idx);
            return 0;
        }
    }
    fclose(f);
    return -1;
}

int main(int argc, char **argv)
{
    char dev[64] = "";
    const char *file = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-D") && i + 1 < argc) snprintf(dev, sizeof(dev), "%s", argv[++i]);
        else file = argv[i];
    }
    if (!file) { fprintf(stderr, "usage: wavplay [-D /dev/snd/pcmCxD0p] file.wav\n"); return 2; }
    if (!dev[0] && find_device(dev, sizeof(dev)) < 0) { fprintf(stderr, "no PT8211 card in /proc/asound/cards\n"); return 1; }

    /* ---- WAV header ---- */
    FILE *wf = fopen(file, "rb");
    if (!wf) { perror(file); return 1; }
    uint8_t hdr[12], ch[8];
    if (fread(hdr, 1, 12, wf) != 12 || memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4)) {
        fprintf(stderr, "%s: not a RIFF/WAVE file\n", file); return 1;
    }
    unsigned rate = 0, channels = 0, bits = 0;
    uint32_t data_len = 0;
    long data_off = -1;
    while (fread(ch, 1, 8, wf) == 8) {
        uint32_t len = le32(ch + 4);
        if (!memcmp(ch, "fmt ", 4)) {
            uint8_t fmt[16];
            if (len < 16 || fread(fmt, 1, 16, wf) != 16) { fprintf(stderr, "bad fmt chunk\n"); return 1; }
            if (le16(fmt) != 1) { fprintf(stderr, "%s: not PCM (format %u)\n", file, le16(fmt)); return 1; }
            channels = le16(fmt + 2); rate = le32(fmt + 4); bits = le16(fmt + 14);
            fseek(wf, (len - 16 + (len & 1)), SEEK_CUR);
        } else if (!memcmp(ch, "data", 4)) {
            data_off = ftell(wf); data_len = len; break;
        } else {
            fseek(wf, len + (len & 1), SEEK_CUR);
        }
    }
    if (data_off < 0 || (channels != 1 && channels != 2) || bits != 16) {
        fprintf(stderr, "%s: need 16-bit mono/stereo PCM with a data chunk (got %u ch, %u bit)\n", file, channels, bits);
        return 1;
    }
    unsigned fbytes = channels * 2;     /* bytes per frame in the file; mono is duplicated to L and R */
    uint32_t frames_total = data_len / fbytes;
    crc_init();

    /* ---- open + hw_params ---- */
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror(dev); return 1; }
    int ver = 0;
    ioctl(fd, SNDRV_PCM_IOCTL_PVERSION, &ver);

    struct snd_pcm_hw_params hp;
    hw_init(&hp);
    hw_set_mask(&hp, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
    hw_set_mask(&hp, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
    hw_set_mask(&hp, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
    hw_set_ival(&hp, SNDRV_PCM_HW_PARAM_CHANNELS, 2);
    hw_set_ival(&hp, SNDRV_PCM_HW_PARAM_RATE, rate);
    hw_set_ival(&hp, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 4096);
    hw_set_ival(&hp, SNDRV_PCM_HW_PARAM_BUFFER_SIZE, 16384);
    if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hp) < 0) { perror("HW_PARAMS"); return 1; }
    unsigned period = hw_ival(&hp, SNDRV_PCM_HW_PARAM_PERIOD_SIZE)->min;
    unsigned bufsz = hw_ival(&hp, SNDRV_PCM_HW_PARAM_BUFFER_SIZE)->min;

    struct snd_pcm_sw_params sw;
    memset(&sw, 0, sizeof(sw));
    sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
    sw.period_step = 1;
    sw.avail_min = period;
    sw.start_threshold = bufsz;         /* start when the buffer is full (or at drain) */
    sw.stop_threshold = bufsz;
    sw.silence_threshold = 0;
    sw.silence_size = 0;
    sw.boundary = bufsz;
    if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw) < 0) { perror("SW_PARAMS"); return 1; }
    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) { perror("PREPARE"); return 1; }

    printf("wavplay: %s: %u Hz %s, %u frames (%.2f s) -> %s (proto %d.%d.%d, period %u, buffer %u)\n",
           file, rate, channels == 1 ? "mono" : "stereo", frames_total, (double)frames_total / rate, dev,
           ver >> 16, (ver >> 8) & 0xff, ver & 0xff, period, bufsz);

    /* ---- play ---- */
    uint8_t *buf = malloc(period * 4);
    uint32_t crc_file = 0, done = 0, xruns = 0;
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    fseek(wf, data_off, SEEK_SET);
    while (done < frames_total) {
        unsigned n = frames_total - done < period ? frames_total - done : period;
        if (fread(buf, fbytes, n, wf) != n) { fprintf(stderr, "short read\n"); break; }
        if (channels == 1)                  /* expand in place, last frame first */
            for (unsigned i = n; i-- > 0;) {
                buf[4 * i + 0] = buf[4 * i + 2] = buf[2 * i + 0];
                buf[4 * i + 1] = buf[4 * i + 3] = buf[2 * i + 1];
            }
        crc_file = crc_update(crc_file, buf, n * 4);
        unsigned off = 0;
        while (off < n) {
            struct snd_xferi x = { .result = 0, .buf = buf + off * 4, .frames = n - off };
            if (ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &x) < 0) {
                if (errno == EPIPE) {
                    xruns++;
                    fprintf(stderr, "wavplay: xrun at frame %u\n", done + off);
                    if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) { perror("PREPARE"); return 1; }
                    continue;
                }
                perror("WRITEI_FRAMES");
                return 1;
            }
            off += x.result;
        }
        done += n;
    }
    if (ioctl(fd, SNDRV_PCM_IOCTL_DRAIN) < 0) perror("DRAIN");
    gettimeofday(&t1, NULL);
    double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) / 1e6;
    close(fd);
    fclose(wf);

    /* ---- the core's view ---- */
    int mfd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *regs = mfd < 0 ? NULL :
        mmap(NULL, 4096, PROT_READ, MAP_SHARED, mfd, AUD_BASE);
    if (!regs || regs == MAP_FAILED) { perror("/dev/mem"); return 1; }
    uint32_t frames_hw = regs[AUD_FRAMES], crc_hw = regs[AUD_CRC];
    uint32_t ur = regs[AUD_UNDERRUN], ov = regs[AUD_OVERRUN];
    int ok = frames_hw == frames_total && crc_hw == crc_file;
    printf("WAVPLAY %s: frames %u/%u, crc %08X/%08X -> %s, underruns %u, overruns %u, xruns %u, %.2f s\n",
           file, frames_hw, frames_total, crc_hw, crc_file, ok ? "MATCH" : "MISMATCH", ur, ov, xruns, secs);
    return ok ? 0 : 1;
}
