/* jpeg_hw.h -- MJPEG frames through the IDCT core's entropy decoder (jpeg_hw.c) */
#ifndef JPEG_HW_H
#define JPEG_HW_H
#include <stdint.h>

typedef struct {
    unsigned w, h, ri;                  /* picture size, restart interval (MCUs) */
    unsigned td[3], ta[3], tq[3];       /* per component: DC / AC Huffman table, quantisation table */
    const uint8_t *ecs;                 /* the entropy-coded data, as in the packet */
    unsigned ecs_len;
} jpeg_frame_t;

void jpeg_hw_reset(void);               /* tables back to FFmpeg's defaults, nothing sent to the core */
int  jpeg_hw_parse(const uint8_t *p, unsigned n, jpeg_frame_t *f);   /* 0 = the core can decode it */
int  jpeg_hw_submit(const jpeg_frame_t *f);                         /* tables + scan into the open frame */
#endif
