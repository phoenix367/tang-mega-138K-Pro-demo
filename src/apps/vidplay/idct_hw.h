/* idct_hw.h -- the hardware IDCT core as the MJPEG decoder's block output (idct_hw.c) */
#ifndef IDCT_HW_H
#define IDCT_HW_H
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>

extern int idct_hw_on;                  /* a frame is open: idct_put calls go to the core */
int  idct_hw_open(int fb_fd);           /* /dev/gowin-idct + its ring; -1 = no core / driver */
int  idct_hw_ready(void);
int  idct_hw_frame_begin(int buf, uint8_t *base, uint8_t *y, uint8_t *u, uint8_t *v,
                         int ys, int cs, int cw, int ch, int w, int h);
void idct_hw_frame_end(void);           /* all records to the core, no wait */
int  idct_hw_frame_done(void);          /* wait until the core has written everything */
int  idct_hw_idle(void);                /* the core has finished everything submitted (no wait) */
int  idct_hw_put(uint8_t *dest, ptrdiff_t line_size, int16_t *block);   /* 1 = taken */
void idct_hw_stats(FILE *f);
int  idct_hw_jpeg_capable(void);        /* the core takes JPEG records (Build 70+) */
int  idct_hw_put_record(uint64_t hdr, const uint64_t *param, const void *payload, unsigned len);
void idct_hw_close(void);
#endif
