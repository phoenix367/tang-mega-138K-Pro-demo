#!/usr/bin/env python3
"""jpeg_ref.py -- reference for the IDCT core's JPEG records (src/rtl/idct/).

    jpeg_ref.py OUTDIR [--corrupt] FILE.jpg [FILE.jpg ...]

Parses baseline 4:2:0 JPEGs, decodes them the way FFmpeg's mjpegdec.c does
(its SOS unescaping, handle_rstn(), decode_block() and simple_idct_put, all
ported literally, so this is an independent model of the bit semantics, not
of the hardware's algorithm) and writes into OUTDIR:

    ring.hex          the records for the core, one 64-bit word per line:
                      for every file DQT + DHT + scan records, then three
                      flush-only records (the last one with the irq bit)
    exp_y.hex ...     the last file's planes, one byte per line, coded size
                      (whole MCUs; the testbench compares inside the picture)
    params.txt        W H CW NWORDS FIRST_BAD

--corrupt flips bytes in the entropy-coded data of every file but the last
(the core must flag them, skip the rest, and decode the next frame right).
"""
import os
import random
import sys

ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34,
      27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
      58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
W1, W2, W3, W4, W5, W6, W7 = 22725, 21407, 19266, 16383, 12873, 8867, 4520


def s16(v):
    v &= 0xFFFF
    return v - 65536 if v >= 32768 else v


def clip8(v):
    return 0 if v < 0 else 255 if v > 255 else v


def idct_put(blk):
    """FFmpeg ff_simple_idct_put_int16_8bit: 64 int16 (natural order) -> 8x8 pixels."""
    t = [0] * 64
    for r in range(8):
        x = blk[r * 8:r * 8 + 8]
        if not any(x[1:]):
            v = s16(x[0] * 8)
            t[r * 8:r * 8 + 8] = [v] * 8
            continue
        a0 = W4 * x[0] + W2 * x[2] + W4 * x[4] + W6 * x[6] + 1024
        a1 = W4 * x[0] + W6 * x[2] - W4 * x[4] - W2 * x[6] + 1024
        a2 = W4 * x[0] - W6 * x[2] - W4 * x[4] + W2 * x[6] + 1024
        a3 = W4 * x[0] - W2 * x[2] + W4 * x[4] - W6 * x[6] + 1024
        b0 = W1 * x[1] + W3 * x[3] + W5 * x[5] + W7 * x[7]
        b1 = W3 * x[1] - W7 * x[3] - W1 * x[5] - W5 * x[7]
        b2 = W5 * x[1] - W1 * x[3] + W7 * x[5] + W3 * x[7]
        b3 = W7 * x[1] - W5 * x[3] + W3 * x[5] - W1 * x[7]
        t[r * 8:r * 8 + 8] = [s16((a0 + b0) >> 11), s16((a1 + b1) >> 11), s16((a2 + b2) >> 11), s16((a3 + b3) >> 11),
                              s16((a3 - b3) >> 11), s16((a2 - b2) >> 11), s16((a1 - b1) >> 11), s16((a0 - b0) >> 11)]
    out = [[0] * 8 for _ in range(8)]
    for c in range(8):
        x = [t[8 * i + c] for i in range(8)]
        a0 = W4 * x[0] + W2 * x[2] + W4 * x[4] + W6 * x[6] + 524256
        a1 = W4 * x[0] + W6 * x[2] - W4 * x[4] - W2 * x[6] + 524256
        a2 = W4 * x[0] - W6 * x[2] - W4 * x[4] + W2 * x[6] + 524256
        a3 = W4 * x[0] - W2 * x[2] + W4 * x[4] - W6 * x[6] + 524256
        b0 = W1 * x[1] + W3 * x[3] + W5 * x[5] + W7 * x[7]
        b1 = W3 * x[1] - W7 * x[3] - W1 * x[5] - W5 * x[7]
        b2 = W5 * x[1] - W1 * x[3] + W7 * x[5] + W3 * x[7]
        b3 = W7 * x[1] - W5 * x[3] + W3 * x[5] - W1 * x[7]
        col = [(a0 + b0) >> 20, (a1 + b1) >> 20, (a2 + b2) >> 20, (a3 + b3) >> 20,
               (a3 - b3) >> 20, (a2 - b2) >> 20, (a1 - b1) >> 20, (a0 - b0) >> 20]
        for r in range(8):
            out[r][c] = clip8(col[r])
    return out


class Jpeg:
    """The subset the core takes: baseline/extended Huffman, 8-bit, Y 2x2 + Cb 1x1 + Cr 1x1."""

    def __init__(self, data):
        self.data = data
        self.dqt, self.dht, self.dri = {}, {}, 0
        assert data[0:2] == b'\xff\xd8', 'no SOI'
        pos = 2
        while True:
            assert data[pos] == 0xFF, 'marker expected at %d' % pos
            m = data[pos + 1]
            pos += 2
            if m == 0xFF:
                pos -= 1
                continue
            if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:
                continue
            ln = (data[pos] << 8) | data[pos + 1]
            seg = data[pos + 2:pos + ln]
            if m == 0xDB:
                i = 0
                while i < len(seg):
                    pq, tq = seg[i] >> 4, seg[i] & 15
                    assert pq == 0, '16-bit DQT'
                    self.dqt[tq] = list(seg[i + 1:i + 65])
                    i += 65
            elif m == 0xC4:
                i = 0
                while i < len(seg):
                    tc, th = seg[i] >> 4, seg[i] & 15
                    bits = list(seg[i + 1:i + 17])
                    n = sum(bits)
                    self.dht[(tc, th)] = (bits, list(seg[i + 17:i + 17 + n]))
                    i += 17 + n
            elif m in (0xC0, 0xC1):
                assert seg[0] == 8, 'precision'
                self.h, self.w = (seg[1] << 8) | seg[2], (seg[3] << 8) | seg[4]
                nf = seg[5]
                assert nf == 3, 'components'
                self.comp = []
                for c in range(3):
                    cid, hv, tq = seg[6 + 3 * c], seg[7 + 3 * c], seg[8 + 3 * c]
                    self.comp.append((cid, hv, tq))
                assert [c[1] for c in self.comp] == [0x22, 0x11, 0x11], '4:2:0 only'
            elif m == 0xDD:
                self.dri = (seg[0] << 8) | seg[1]
            elif m == 0xDA:
                ns = seg[0]
                assert ns == 3
                self.sos = []
                for c in range(3):
                    cid, t = seg[1 + 2 * c], seg[2 + 2 * c]
                    assert cid == self.comp[c][0], 'scan component order'
                    self.sos.append((t >> 4, t & 15))
                assert seg[7] == 0 and seg[8] == 63 and seg[9] == 0, 'not sequential'
                self.ecs_start = pos + ln
                break
            elif 0xC2 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
                raise AssertionError('SOF%d not supported' % (m - 0xC0))
            pos += ln
        # the entropy-coded segment: up to the first marker that is not RSTn
        i = self.ecs_start
        while i < len(data) - 1:
            if data[i] == 0xFF:
                n = data[i + 1]
                if n == 0x00 or 0xD0 <= n <= 0xD7:
                    i += 2
                    continue
                if n == 0xFF:
                    i += 1
                    continue
                break
            i += 1
        self.ecs_end = i
        self.mcux, self.mcuy = (self.w + 15) // 16, (self.h + 15) // 16

    # ---- FFmpeg's decoding, literally ----
    def unescape(self):
        buf, start, end = self.data, self.ecs_start, len(self.data)
        out = bytearray()
        st = {'src': start, 'ptr': start}

        def copy(skip):
            length = (st['ptr'] - st['src']) - skip
            if length > 0:
                out.extend(buf[st['src']:st['src'] + length])
                st['src'] = st['ptr']

        while st['ptr'] < end:
            x = buf[st['ptr']]
            st['ptr'] += 1
            if x == 0xFF:
                skip = 0
                while st['ptr'] < end and x == 0xFF:
                    x = buf[st['ptr']]
                    st['ptr'] += 1
                    skip += 1
                if skip > 1:
                    copy(skip)
                    st['src'] -= 1
                if x < 0xD0 or x > 0xD7:
                    copy(1)
                    if x:
                        break
        if st['src'] < st['ptr']:
            copy(0)
        return bytes(out)

    def decode(self):
        """-> (Y, U, V) planes of the coded size, lists of rows"""
        gb = self.unescape()
        nbits = len(gb) * 8
        padded = gb + bytes(64)
        self.pos = 0

        def show(n):
            p = self.pos
            v = int.from_bytes(padded[p >> 3:(p >> 3) + 5], 'big')
            return (v >> (40 - (p & 7) - n)) & ((1 << n) - 1) if n else 0

        def get(n):
            v = show(n)
            self.pos += n
            return v

        def xbits(n):
            v = get(n)
            return v if v >> (n - 1) else v - (1 << n) + 1

        tables = {}
        for (tc, th), (bits, vals) in self.dht.items():
            t, code, k = {}, 0, 0
            for l in range(1, 17):
                for _ in range(bits[l - 1]):
                    t[(l, code)] = vals[k]
                    code += 1
                    k += 1
                code <<= 1
            tables[(tc, th)] = t

        def vlc(t):
            for l in range(1, 17):
                c = show(l)
                if (l, c) in t:
                    self.pos += l
                    return t[(l, c)]
            raise ValueError('bad code')

        cw, ch = self.mcux * 16, self.mcuy * 16
        planes = [[[0] * cw for _ in range(ch)], [[0] * (cw // 2) for _ in range(ch // 2)],
                  [[0] * (cw // 2) for _ in range(ch // 2)]]
        last_dc = [1024, 1024, 1024]
        restart_count = 0
        self.nblocks = 0
        for my in range(self.mcuy):
            for mx in range(self.mcux):
                if self.dri and not restart_count:
                    restart_count = self.dri
                for c in range(3):
                    td, ta = self.sos[c]
                    q = self.dqt[self.comp[c][2]]
                    for b in range(4 if c == 0 else 1):
                        blk = [0] * 64
                        code = vlc(tables[(0, td)])
                        if code > 16:
                            raise ValueError('dc')
                        val = xbits(code) if code else 0
                        val = (val * q[0] + last_dc[c]) & 0xFFFFFFFF
                        val = val - (1 << 32) if val >> 31 else val
                        last_dc[c] = val
                        blk[0] = max(-32768, min(32767, val))
                        i = 0
                        while True:
                            sym = vlc(tables[(1, ta)])
                            code = 16 * 256 if sym == 0 else sym + 16
                            i += code >> 4
                            code &= 15
                            if code:
                                level = xbits(code)
                                if i > 63:
                                    raise ValueError('count')
                                blk[ZZ[i]] = s16(level * q[i])
                            if i >= 63:
                                break
                        px = idct_put(blk)
                        self.nblocks += 1
                        if hasattr(self, 'blocklog'):
                            self.blocklog.append((c, (mx * 2 + (b & 1)) * 8 if c == 0 else mx * 8,
                                                  (my * 2 + (b >> 1)) * 8 if c == 0 else my * 8, list(blk)))
                        x0 = (mx * 2 + (b & 1)) * 8 if c == 0 else mx * 8
                        y0 = (my * 2 + (b >> 1)) * 8 if c == 0 else my * 8
                        for r in range(8):
                            planes[c][y0 + r][x0:x0 + 8] = px[r]
                # handle_rstn()
                if self.dri:
                    restart_count -= 1
                    i = 8 + ((-self.pos) & 7)
                    if restart_count == 0 and (show(i) == (1 << i) - 1 or show(i) == 0xFF):
                        p0 = self.pos
                        self.pos = (self.pos + 7) & ~7
                        while nbits - self.pos >= 8 and show(8) == 0xFF:
                            self.pos += 8
                        if nbits - self.pos >= 8 and (get(8) & 0xF8) == 0xD0:
                            last_dc = [1024, 1024, 1024]
                        else:
                            self.pos = p0
        return planes

    # ---- records for the core ----
    def records(self, corrupt=None):
        words = []

        def payload(b):
            b = bytes(b) + bytes(-len(b) % 8)
            return [int.from_bytes(b[i:i + 8], 'little') for i in range(0, len(b), 8)]

        for tq in sorted(self.dqt):
            words.append((2 << 36) | (tq << 8) | (64 << 40))
            words += payload(self.dqt[tq])
        for (tc, th), (bits, vals) in sorted(self.dht.items()):
            p = bits + vals
            words.append((1 << 36) | ((tc * 2 + th) << 8) | (len(p) << 40))
            words += payload(p)
        ecs = bytearray(self.data[self.ecs_start:self.ecs_end])
        if corrupt is not None:
            rnd = random.Random(corrupt)
            for _ in range(max(4, len(ecs) // 40)):
                ecs[rnd.randrange(len(ecs))] = rnd.randrange(256)
        param = self.mcux | (self.mcuy << 8) | (self.dri << 16)
        for c in range(3):
            td, ta = self.sos[c]
            param |= (td << (32 + 2 * c)) | (ta << (33 + 2 * c)) | (self.comp[c][2] << (38 + 2 * c))
        words.append((3 << 36) | (len(ecs) << 40))
        words.append(param)
        words += payload(ecs)
        return words


def main():
    args = sys.argv[1:]
    out = args.pop(0)
    corrupt = '--corrupt' in args
    files = [a for a in args if not a.startswith('--')]
    os.makedirs(out, exist_ok=True)
    words = []
    for n, f in enumerate(files):
        j = Jpeg(open(f, 'rb').read())
        bad = corrupt and n < len(files) - 1
        words += j.records(corrupt=n if bad else None)
    words += [(1 << 35) | (0 << 8), (1 << 35) | (1 << 8), (1 << 35) | (2 << 8) | (1 << 34)]
    j.blocklog = []
    planes = j.decode()
    with open(os.path.join(out, 'blocks.txt'), 'w') as fh:
        for c, x, y, blk in j.blocklog:
            fh.write('%d %d %d %s\n' % (c, x, y, ' '.join(str(v) for v in blk)))
    with open(os.path.join(out, 'ring.hex'), 'w') as fh:
        fh.write(''.join('%016x\n' % w for w in words))
    for name, p in zip('yuv', planes):
        with open(os.path.join(out, 'exp_%s.hex' % name), 'w') as fh:
            fh.write(''.join('%02x\n' % v for row in p for v in row))
    with open(os.path.join(out, 'params.txt'), 'w') as fh:
        fh.write('%d %d %d %d %d\n' % (j.w, j.h, j.mcux * 16, len(words), 1 if corrupt else 0))
    print('%s: %dx%d, %d MCUs, restart %d, %d blocks, ECS %d bytes, %d ring words%s' % (
        os.path.basename(files[-1]), j.w, j.h, j.mcux * j.mcuy, j.dri, j.nblocks, j.ecs_end - j.ecs_start,
        len(words), ' (after %d corrupted frame(s))' % (len(files) - 1) if corrupt else ''))


if __name__ == '__main__':
    main()
