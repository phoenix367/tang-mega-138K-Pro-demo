"""Test media, made on the host and cached across runs:
- WAVs from src/apps/tests/wavgen.py, with the frame count and data CRC the audio
  core's FRAMES / CRC registers must show after wavplay (wavplay prints MATCH);
- MJPEG + AAC clips encoded the way the player's clips are (q 8, yuvj420p, full-range
  4:2:0, AAC 128k in MP4), from FFmpeg's moving testsrc2 pattern and a sine tone;
- random blobs for the network and SD card round trips.
"""
import hashlib, os, re, subprocess, sys
from pathlib import Path

from .core import TOOLS


class Media:
    def __init__(self, dir):
        self.dir = Path(dir)
        self.dir.mkdir(parents=True, exist_ok=True)

    def wavs(self):
        """{name: (path, rate, frames, crc)} for the wavgen.py set."""
        d = self.dir / "wav"
        r = subprocess.run([sys.executable, "-I", str(TOOLS / "wavgen.py"), str(d)],
                           capture_output=True, text=True, check=True)
        out = {}
        for m in re.finditer(r"^(\S+\.wav)\s+rate\s+(\d+)\s+frames\s+(\d+)\s+crc\s+([0-9A-F]+)", r.stdout, re.M):
            out[m.group(1)] = (d / m.group(1), int(m.group(2)), int(m.group(3)), m.group(4))
        return out

    def clip(self, w, h, fps=25, secs=10):
        """An MJPEG clip like the player's: moving test pattern + 440 Hz tone."""
        p = self.dir / ("clip_%dx%d_%dfps_%ds.mp4" % (w, h, fps, secs))
        if not p.exists():
            subprocess.run(["ffmpeg", "-v", "error", "-y",
                            "-f", "lavfi", "-i", "testsrc2=size=%dx%d:rate=%d" % (w, h, fps),
                            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                            "-t", str(secs), "-c:v", "mjpeg", "-q:v", "8", "-pix_fmt", "yuvj420p",
                            "-c:a", "aac", "-b:a", "128k", "-ac", "2", "-movflags", "+faststart", str(p)],
                           check=True)
        return p

    def blob(self, mb):
        """A random file of mb MiB and its md5."""
        p = self.dir / ("random_%dM.bin" % mb)
        if not p.exists() or p.stat().st_size != mb << 20:
            with open(p, "wb") as f:
                f.write(os.urandom(mb << 20))
        return p, md5(p)


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
