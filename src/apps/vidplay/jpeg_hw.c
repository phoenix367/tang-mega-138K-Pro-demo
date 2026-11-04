/*
 * jpeg_hw.c -- MJPEG frames decoded by the gateware (Build 70+): the IDCT core's
 * entropy decoder takes the Huffman and quantisation tables and the scan's raw
 * entropy-coded bytes as ring records and writes the pixels into the YUV planes;
 * the CPU only parses the headers here and copies the scan into the ring.
 *
 * The subset is what FFmpeg's encoder (and nearly every MJPEG camera) produces:
 * baseline/extended sequential Huffman, 8-bit, three components Y 2x2 + Cb 1x1 +
 * Cr 1x1 in one interleaved scan, 8-bit quantisation tables, at most two DC and two
 * AC tables, optional restart interval.  Anything else returns -1 and the caller
 * falls back to FFmpeg's decoder.  The semantics match FFmpeg's mjpegdec.c bit for
 * bit (src/rtl/idct/tb/run_jpeg_tb.sh; `vidplay -C` checks it on the board):
 * tables persist from frame to frame, the defaults are FFmpeg's (JPEG Annex K).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "gowin-idct.h"
#include "idct_hw.h"
#include "jpeg_hw.h"

/* FFmpeg's default tables (libavcodec/jpegtables.c; bits[] has a dummy entry 0) */
extern const uint8_t ff_mjpeg_bits_dc_luminance[], ff_mjpeg_bits_dc_chrominance[], ff_mjpeg_val_dc[];
extern const uint8_t ff_mjpeg_bits_ac_luminance[], ff_mjpeg_val_ac_luminance[];
extern const uint8_t ff_mjpeg_bits_ac_chrominance[], ff_mjpeg_val_ac_chrominance[];

static struct { uint8_t data[16 + 256]; unsigned len; int sent; } ht[4];   /* slot: DC0 DC1 AC0 AC1 */
static struct { uint8_t q[64]; int valid, sent; } qt[4];
static int tables_init;

static void set_table(int slot, const uint8_t *bits16, const uint8_t *vals)
{
    unsigned n = 0;
    for (int i = 0; i < 16; i++) n += bits16[i];
    unsigned len = 16 + n;
    if (ht[slot].len == len && !memcmp(ht[slot].data, bits16, 16) && !memcmp(ht[slot].data + 16, vals, n)) return;
    memcpy(ht[slot].data, bits16, 16);
    memcpy(ht[slot].data + 16, vals, n);
    ht[slot].len = len;
    ht[slot].sent = 0;
}

void jpeg_hw_reset(void)
{
    memset(ht, 0, sizeof(ht));
    memset(qt, 0, sizeof(qt));
    set_table(0, ff_mjpeg_bits_dc_luminance + 1, ff_mjpeg_val_dc);
    set_table(1, ff_mjpeg_bits_dc_chrominance + 1, ff_mjpeg_val_dc);
    set_table(2, ff_mjpeg_bits_ac_luminance + 1, ff_mjpeg_val_ac_luminance);
    set_table(3, ff_mjpeg_bits_ac_chrominance + 1, ff_mjpeg_val_ac_chrominance);
    tables_init = 1;
}

/* end of the entropy-coded data: the EOI near the packet end, else the first marker
 * that is not RSTn (the data itself only has FF 00, FF D0..D7 and FF FF fill) */
static unsigned ecs_end(const uint8_t *p, unsigned start, unsigned n)
{
    for (unsigned e = n >= 2 ? n - 2 : 0; e >= start && e + 40 >= n; e--) {
        if (p[e] == 0xFF && p[e + 1] == 0xD9) return e;
        if (e == 0) break;
    }
    for (unsigned i = start; i + 1 < n; i++)
        if (p[i] == 0xFF) {
            uint8_t m = p[i + 1];
            if (m == 0x00 || (m >= 0xD0 && m <= 0xD7)) { i++; continue; }
            if (m != 0xFF) return i;
        }
    return n;
}

int jpeg_hw_parse(const uint8_t *p, unsigned n, jpeg_frame_t *f)
{
    if (!tables_init) jpeg_hw_reset();
    if (n < 4 || p[0] != 0xFF || p[1] != 0xD8) return -1;
    unsigned pos = 2;
    int have_sof = 0, cid[3] = { 0 };
    f->ri = 0;
    while (pos + 4 <= n) {
        if (p[pos] != 0xFF) return -1;
        uint8_t m = p[pos + 1];
        pos += 2;
        if (m == 0xFF) { pos--; continue; }                       /* fill */
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) continue;
        if (m == 0xD9) return -1;                                   /* EOI before the scan */
        unsigned L = (unsigned)p[pos] << 8 | p[pos + 1];
        if (L < 2 || pos + L > n) return -1;
        const uint8_t *s = p + pos + 2;
        unsigned sl = L - 2;
        switch (m) {
        case 0xDB:                                                  /* DQT */
            for (unsigned i = 0; i < sl; i += 65) {
                unsigned pq = s[i] >> 4, tq = s[i] & 15;
                if (pq || tq > 3 || i + 65 > sl) return -1;
                if (!qt[tq].valid || memcmp(qt[tq].q, s + i + 1, 64)) { memcpy(qt[tq].q, s + i + 1, 64); qt[tq].sent = 0; }
                qt[tq].valid = 1;
            }
            break;
        case 0xC4:                                                  /* DHT */
            for (unsigned i = 0; i < sl; ) {
                if (i + 17 > sl) return -1;
                unsigned tc = s[i] >> 4, th = s[i] & 15, nv = 0;
                if (tc > 1 || th > 1) return -1;
                for (int k = 1; k <= 16; k++) nv += s[i + k];
                if (nv > 256 || i + 17 + nv > sl) return -1;
                set_table(tc * 2 + th, s + i + 1, s + i + 17);
                i += 17 + nv;
            }
            break;
        case 0xDD:                                                  /* DRI */
            if (sl < 2) return -1;
            f->ri = (unsigned)s[0] << 8 | s[1];
            break;
        case 0xC0: case 0xC1:                                       /* SOF0 / SOF1 */
            if (sl < 15 || s[0] != 8 || s[5] != 3) return -1;
            f->h = (unsigned)s[1] << 8 | s[2];
            f->w = (unsigned)s[3] << 8 | s[4];
            for (int c = 0; c < 3; c++) {
                cid[c] = s[6 + 3 * c];
                if (s[7 + 3 * c] != (c ? 0x11 : 0x22) || s[8 + 3 * c] > 3) return -1;
                f->tq[c] = s[8 + 3 * c];
            }
            if (cid[0] == 'R' && cid[1] == 'G' && cid[2] == 'B') return -1;   /* FFmpeg: RGB */
            have_sof = 1;
            break;
        case 0xEE:                                                  /* APP14 Adobe: colour transform */
            if (sl >= 5 && !memcmp(s, "Adobe", 5)) return -1;
            break;
        case 0xDA: {                                                /* SOS */
            if (!have_sof || sl < 10 || s[0] != 3) return -1;
            for (int c = 0; c < 3; c++) {
                if (s[1 + 2 * c] != cid[c]) return -1;
                f->td[c] = s[2 + 2 * c] >> 4;
                f->ta[c] = s[2 + 2 * c] & 15;
                if (f->td[c] > 1 || f->ta[c] > 1 || !ht[f->td[c]].len || !ht[2 + f->ta[c]].len || !qt[f->tq[c]].valid)
                    return -1;
            }
            if (s[7] != 0 || s[8] != 63 || s[9] != 0) return -1;     /* not sequential */
            unsigned st = pos + L;
            f->ecs = p + st;
            f->ecs_len = ecs_end(p, st, n) - st;
            return f->w && f->h ? 0 : -1;
        }
        default:
            if (m >= 0xC2 && m <= 0xCF && m != 0xC4) return -1;     /* progressive, lossless, arithmetic */
            break;                                                  /* APPn, COM */
        }
        pos += L;
    }
    return -1;
}

/* the frame's tables (only what changed since they were last sent) and its scan;
 * a frame must be open (idct_hw_frame_begin) */
int jpeg_hw_submit(const jpeg_frame_t *f)
{
    unsigned used_ht = 0, used_qt = 0;
    for (int c = 0; c < 3; c++) {
        used_ht |= 1u << f->td[c] | 1u << (2 + f->ta[c]);
        used_qt |= 1u << f->tq[c];
    }
    for (int t = 0; t < 4; t++)
        if ((used_qt >> t & 1) && !qt[t].sent) {
            if (idct_hw_put_record(GOWIN_IDCT_HDR_JPEG(GOWIN_IDCT_REC_QUANT, t, 64), NULL, qt[t].q, 64)) return -1;
            qt[t].sent = 1;
        }
    for (int t = 0; t < 4; t++)
        if ((used_ht >> t & 1) && !ht[t].sent) {
            if (idct_hw_put_record(GOWIN_IDCT_HDR_JPEG(GOWIN_IDCT_REC_HUFF, t, ht[t].len), NULL, ht[t].data, ht[t].len)) return -1;
            ht[t].sent = 1;
        }
    unsigned tsel = 0, tq = 0;
    for (int c = 0; c < 3; c++) {
        tsel |= (unsigned)(f->td[c] | f->ta[c] << 1) << (2 * c);
        tq   |= (unsigned)f->tq[c] << (2 * c);
    }
    uint64_t param = GOWIN_IDCT_SCAN_PARAM((f->w + 15) / 16, (f->h + 15) / 16, f->ri, tsel, tq);
    return idct_hw_put_record(GOWIN_IDCT_HDR_JPEG(GOWIN_IDCT_REC_SCAN, 0, f->ecs_len), &param, f->ecs, f->ecs_len);
}
