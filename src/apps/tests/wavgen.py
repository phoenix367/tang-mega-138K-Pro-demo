#!/usr/bin/env python3
"""Generate the test WAVs for tests/wavplay (16-bit stereo) and print each
file's frame count and zlib CRC-32 of its data chunk -- the values the audio
core's FRAMES and CRC registers must show after wavplay plays it.

Usage: tests/wavgen.py <outdir>
"""
import math, struct, sys, wave, zlib, os

out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)

def write(name, rate, secs, fl, fr, amp=0.5):
    n = int(rate * secs)
    frames = bytearray()
    for i in range(n):
        t = i / rate
        l = int(amp * 32767 * math.sin(2 * math.pi * fl(t) * t)) if callable(fl) else int(amp * 32767 * math.sin(2 * math.pi * fl * t))
        r = int(amp * 32767 * math.sin(2 * math.pi * fr(t) * t)) if callable(fr) else int(amp * 32767 * math.sin(2 * math.pi * fr * t))
        frames += struct.pack("<hh", l, r)
    path = os.path.join(out, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(bytes(frames))
    print("%-22s rate %6d  frames %8d  crc %08X" % (name, rate, n, zlib.crc32(bytes(frames)) & 0xffffffff))

write("sine1k_48k_5s.wav", 48000, 5, 1000, 1000)
write("lr440_880_48k_2s.wav", 48000, 2, 440, 880)
write("sine1k_44k1_3s.wav", 44100, 3, 1000, 1000)
# linear sweep 200 Hz -> 8 kHz over 4 s (phase = integral of f(t))
def sweep(t, f0=200.0, f1=8000.0, T=4.0):
    return f0 + (f1 - f0) * t / (2 * T)   # instantaneous phase/t for a linear chirp
write("sweep200_8k_48k_4s.wav", 48000, 4, sweep, sweep)
