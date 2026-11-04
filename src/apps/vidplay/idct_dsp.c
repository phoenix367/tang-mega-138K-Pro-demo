/*
 * idct_dsp.c -- FFmpeg's simple_idct (int16 input, 8-bit output, "put") on the
 * Andes DSP extension of the AE350's A25: the eight 16x16 multiply-accumulates
 * of every 1-D butterfly become four KMDA dual dot products (rs1.H*rs2.H +
 * rs1.L*rs2.L), the same shape as FFmpeg's ARMv6 SMUAD version.  Same
 * constants, shifts, rounding terms and DC-only row shortcut as
 * libavcodec/simple_idct_template.c (IN_IDCT_DEPTH 16, BIT_DEPTH 8), so the
 * output is bit-exact with the C code (VIDPLAY_IDCTTEST=1 checks that on the
 * board).
 *
 * Compiled by the Andes GCC (-mext-dsp; the musl toolchain does not know the
 * instructions) and linked into the musl static binary with
 * -Wl,--wrap=ff_simple_idct_put_int16_8bit, which leaves the FFmpeg tree
 * untouched: every call of the original, including the one through
 * idctdsp's function table, lands here.
 */
#include <stdint.h>
#include <stddef.h>
#include <nds_intrinsic.h>

/* freestanding: a word-wise copy of whole lines (both sides 32-byte aligned here) */
static void memcpy_fast(uint8_t *d, const uint8_t *s, size_t n)
{
    uint32_t *dw = (uint32_t *)d; const uint32_t *sw = (const uint32_t *)s;
    for (size_t i = 0; i < n / 4; i += 8) {
        dw[i] = sw[i]; dw[i+1] = sw[i+1]; dw[i+2] = sw[i+2]; dw[i+3] = sw[i+3];
        dw[i+4] = sw[i+4]; dw[i+5] = sw[i+5]; dw[i+6] = sw[i+6]; dw[i+7] = sw[i+7];
    }
}

#define W1 22725
#define W2 21407
#define W3 19266
#define W4 16383
#define W5 12873
#define W6 8867
#define W7 4520
#define ROW_SHIFT 11
#define COL_SHIFT 20
#define DC_SHIFT 3

/* packed {high, low} 16-bit lanes */
#define P(h, l) ((uint32_t)((uint16_t)(int16_t)(h)) << 16 | (uint16_t)(int16_t)(l))
/* dual dot product of signed 16-bit lanes */
#define DOT(a, b) ((int32_t)__nds__kmda((a), (b)))

/* Even part factored the classic way so it needs 2 dot products + 2 multiplies
 * and three constants (t0 = W4*(x0+x4), t1 = W4*(x0-x4), t2 = W2*x2 + W6*x6,
 * t3 = W6*x2 - W2*x6; a0 = t0+t2, a1 = t1+t3, a2 = t1-t3, a3 = t0-t2): the
 * same integers as FFmpeg's sums, no rounding difference.  Odd part: 8 dot
 * products.  Eleven packed constants in all, so everything stays in registers
 * (the first version with 16 constants spilled half of them to the stack in
 * every iteration and was slower than the C code).  Rows and columns with no
 * high-frequency terms (x4..x7 all zero, the usual case in JPEG data) skip the
 * second half of the products, as FFmpeg does. */
#define C26  P( W6,  W2)       /* dot with {x6, x2} -> W6*x6 + W2*x2 */
#define C62  P(-W2,  W6)       /* -W2*x6 + W6*x2 */
#define CB0O0 P( W3,  W1)
#define CB0O1 P( W7,  W5)
#define CB1O0 P(-W7,  W3)
#define CB1O1 P(-W5, -W1)
#define CB2O0 P(-W1,  W5)
#define CB2O1 P( W3,  W7)
#define CB3O0 P(-W5,  W7)
#define CB3O1 P(-W1,  W3)

static inline void idct_row(int16_t *row)
{
    uint32_t w0 = *(uint32_t *)(row + 0);       /* {x1, x0} */
    uint32_t w1 = *(uint32_t *)(row + 2);       /* {x3, x2} */
    uint32_t w2 = *(uint32_t *)(row + 4);       /* {x5, x4} */
    uint32_t w3 = *(uint32_t *)(row + 6);       /* {x7, x6} */
    int32_t x0 = (int16_t)w0, x2 = (int16_t)w1, x4 = (int16_t)w2;
    const int32_t rnd = 1 << (ROW_SHIFT - 1);
    int32_t t0, t1, t2, t3, b0, b1, b2, b3;
    uint32_t o0 = __nds__pktt16(w1, w0);        /* {x3, x1} */

    if (((w0 >> 16) | w1 | w2 | w3) == 0) {     /* DC only: row = x0 << DC_SHIFT */
        uint32_t t = (uint16_t)(x0 * (1 << DC_SHIFT));
        t |= t << 16;
        *(uint32_t *)(row + 0) = t; *(uint32_t *)(row + 2) = t;
        *(uint32_t *)(row + 4) = t; *(uint32_t *)(row + 6) = t;
        return;
    }
    if ((w2 | w3) == 0) {                       /* x4..x7 zero */
        t0 = t1 = W4 * x0 + rnd;
        t2 = W2 * x2; t3 = W6 * x2;
        b0 = DOT(o0, CB0O0); b1 = DOT(o0, CB1O0); b2 = DOT(o0, CB2O0); b3 = DOT(o0, CB3O0);
    } else {
        uint32_t e26 = __nds__pkbb16(w3, w1);   /* {x6, x2} */
        uint32_t o1 = __nds__pktt16(w3, w2);    /* {x7, x5} */
        t0 = W4 * (x0 + x4) + rnd; t1 = W4 * (x0 - x4) + rnd;
        t2 = DOT(e26, C26); t3 = DOT(e26, C62);
        b0 = DOT(o0, CB0O0) + DOT(o1, CB0O1);
        b1 = DOT(o0, CB1O0) + DOT(o1, CB1O1);
        b2 = DOT(o0, CB2O0) + DOT(o1, CB2O1);
        b3 = DOT(o0, CB3O0) + DOT(o1, CB3O1);
    }
    int32_t a0 = t0 + t2, a1 = t1 + t3, a2 = t1 - t3, a3 = t0 - t2;
    *(uint32_t *)(row + 0) = P((a1 + b1) >> ROW_SHIFT, (a0 + b0) >> ROW_SHIFT);
    *(uint32_t *)(row + 2) = P((a3 + b3) >> ROW_SHIFT, (a2 + b2) >> ROW_SHIFT);
    *(uint32_t *)(row + 4) = P((a2 - b2) >> ROW_SHIFT, (a3 - b3) >> ROW_SHIFT);
    *(uint32_t *)(row + 6) = P((a0 - b0) >> ROW_SHIFT, (a1 - b1) >> ROW_SHIFT);
}

static inline void idct_col_put(uint8_t *dest, ptrdiff_t ls, const int16_t *col)
{
    int32_t x0 = col[0], x2 = col[16], x4 = col[32];
    uint32_t o0 = __nds__pkbb16(col[24], col[8]);          /* {x3, x1} */
    uint32_t hi = (uint16_t)col[32] | (uint16_t)col[40] | (uint16_t)col[48] | (uint16_t)col[56];
    const int32_t rnd = W4 * ((1 << (COL_SHIFT - 1)) / W4);   /* FFmpeg's rounding term */
    int32_t t0, t1, t2, t3, b0, b1, b2, b3;

    if (hi == 0) {                              /* x4..x7 zero */
        t0 = t1 = W4 * x0 + rnd;
        t2 = W2 * x2; t3 = W6 * x2;
        b0 = DOT(o0, CB0O0); b1 = DOT(o0, CB1O0); b2 = DOT(o0, CB2O0); b3 = DOT(o0, CB3O0);
    } else {
        uint32_t e26 = __nds__pkbb16(col[48], col[16]);    /* {x6, x2} */
        uint32_t o1 = __nds__pkbb16(col[56], col[40]);     /* {x7, x5} */
        t0 = W4 * (x0 + x4) + rnd; t1 = W4 * (x0 - x4) + rnd;
        t2 = DOT(e26, C26); t3 = DOT(e26, C62);
        b0 = DOT(o0, CB0O0) + DOT(o1, CB0O1);
        b1 = DOT(o0, CB1O0) + DOT(o1, CB1O1);
        b2 = DOT(o0, CB2O0) + DOT(o1, CB2O1);
        b3 = DOT(o0, CB3O0) + DOT(o1, CB3O1);
    }
    int32_t a0 = t0 + t2, a1 = t1 + t3, a2 = t1 - t3, a3 = t0 - t2;
    dest[0 * ls] = __nds__uclip32((a0 + b0) >> COL_SHIFT, 8);
    dest[1 * ls] = __nds__uclip32((a1 + b1) >> COL_SHIFT, 8);
    dest[2 * ls] = __nds__uclip32((a2 + b2) >> COL_SHIFT, 8);
    dest[3 * ls] = __nds__uclip32((a3 + b3) >> COL_SHIFT, 8);
    dest[4 * ls] = __nds__uclip32((a3 - b3) >> COL_SHIFT, 8);
    dest[5 * ls] = __nds__uclip32((a2 - b2) >> COL_SHIFT, 8);
    dest[6 * ls] = __nds__uclip32((a1 - b1) >> COL_SHIFT, 8);
    dest[7 * ls] = __nds__uclip32((a0 - b0) >> COL_SHIFT, 8);
}

int idct_use_c;                                 /* VIDPLAY_CIDCT=1: FFmpeg's C IDCT, for A/B runs */
int idct_no_stage;                              /* VIDPLAY_NOSTAGE=1: write blocks straight into the frame */
void __real_ff_simple_idct_put_int16_8bit(uint8_t *dest, ptrdiff_t line_size, int16_t *block);

static inline void idct_put(uint8_t *dest, ptrdiff_t line_size, int16_t *block)
{
    if (idct_use_c) { __real_ff_simple_idct_put_int16_8bit(dest, line_size, block); return; }
    for (int i = 0; i < 8; i++) idct_row(block + 8 * i);
    for (int i = 0; i < 8; i++) idct_col_put(dest + i, line_size, block + i);
}

/* ---- band staging: software write-combining for the decoded planes ---------
 * Measured on the A25: an 8x8 block written into a cold frame costs ~2 us more
 * than the same block into cache-resident memory -- eight scattered cache-line
 * fills at this SoC's memory latency -- which is more than the IDCT's own
 * arithmetic and ~18 ms of an 800x480 frame.  So blocks are assembled in a
 * small staging buffer per plane (one MCU band: 16 luma or 8 chroma lines) and
 * the band is copied into the frame in one sequential memcpy, which the DDR
 * bridge streams at several times the rate of block-order writes.  vidplay
 * registers the target planes of each frame (idct_stage_setup) and flushes
 * after the decode (idct_stage_flush); a block outside the registered planes
 * (any other frame, or a non-interleaved scan jumping bands) goes direct. */
#define STAGE_MAXW 1024
static struct {
    uint8_t *base; int stride, w, h, band_h;    /* the plane in the frame */
    int valid, y0;                              /* the staged band (y0 = its first line) */
    uint8_t *stage;                             /* band_h * stride bytes, hot */
} planes[3];
static uint8_t stage_mem[16 * STAGE_MAXW + 2 * 8 * (STAGE_MAXW / 2)];

static void stage_flush_plane(int p)
{
    if (!planes[p].valid) return;
    int n = planes[p].h - planes[p].y0;
    if (n > planes[p].band_h) n = planes[p].band_h;
    if (n > 0) memcpy_fast(planes[p].base + (size_t)planes[p].y0 * planes[p].stride, planes[p].stage,
                           (size_t)n * planes[p].stride);
    planes[p].valid = 0;
}

void idct_stage_setup(uint8_t *y, uint8_t *u, uint8_t *v, int ys, int cs, int w, int h)
{
    uint8_t *b[3] = { y, u, v };
    int st[3] = { ys, cs, cs }, ww[3] = { w, w / 2, w / 2 }, hh[3] = { h, h / 2, h / 2 }, bh[3] = { 16, 8, 8 };
    uint8_t *sm = stage_mem;
    for (int p = 0; p < 3; p++) {
        stage_flush_plane(p);
        planes[p].base = (st[p] > STAGE_MAXW || !b[p]) ? 0 : b[p];
        planes[p].stride = st[p]; planes[p].w = ww[p]; planes[p].h = hh[p]; planes[p].band_h = bh[p];
        planes[p].stage = sm; sm += bh[p] * (p ? STAGE_MAXW / 2 : STAGE_MAXW);
    }
}

void idct_stage_flush(void)
{
    for (int p = 0; p < 3; p++) stage_flush_plane(p);
}

extern int idct_hw_on;                  /* idct_hw.c: the hardware core has the frame */
int idct_hw_put(uint8_t *dest, ptrdiff_t line_size, int16_t *block);

void __wrap_ff_simple_idct_put_int16_8bit(uint8_t *dest, ptrdiff_t line_size, int16_t *block)
{
    if (idct_hw_on && idct_hw_put(dest, line_size, block)) return;
    if (!idct_no_stage)
        for (int p = 0; p < 3; p++) {
            if (!planes[p].base || dest < planes[p].base || line_size != planes[p].stride) continue;
            size_t off = dest - planes[p].base;
            int y = off / planes[p].stride, x = off % planes[p].stride;
            if (y >= planes[p].h) continue;
            int y0 = y - y % planes[p].band_h;
            if (planes[p].valid && planes[p].y0 != y0) stage_flush_plane(p);
            if (!planes[p].valid) { planes[p].valid = 1; planes[p].y0 = y0; }
            idct_put(planes[p].stage + (y - y0) * planes[p].stride + x, planes[p].stride, block);
            return;
        }
    idct_put(dest, line_size, block);
}
