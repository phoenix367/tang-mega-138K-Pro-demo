/* puff.h -- tiny inflate + gzip wrapper (see puff.c). */
#ifndef PUFF_H
#define PUFF_H

/* Inflate a raw DEFLATE stream. Returns 0 on success, <0 on format error,
 * >0 if it ran out of output room (1) or input (2). */
int puff(unsigned char *dest, unsigned long *destlen,
         const unsigned char *source, unsigned long *sourcelen);

/* Gunzip a gzip (RFC1952) blob `src` (srclen = upper bound) into `dst`;
 * *dstlen is the buffer size on entry, the decompressed size on success. */
int gunzip(unsigned char *dst, unsigned long *dstlen,
           const unsigned char *src, unsigned long srclen);

#endif
