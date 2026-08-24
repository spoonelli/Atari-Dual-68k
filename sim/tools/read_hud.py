#!/usr/bin/env python3
"""Read the core's on-screen debug HUD out of a 1920x1080 capture frame.

HUD page 0 (dbgmode digit == 0, slot 15) is:
    slots 0-3   = vcyc_fr  -- video-CPU bus cycles in the previous frame
    slots 5-8   = ecyc_fr  -- extra-CPU bus cycles in the previous frame
    slots 10-13 = coincred_fr
    slot 15     = dbgmode
(core_top.v, the hex_digit mux and the per-frame display latches.)

Digits are core_top.v's 4x6 `hexfont`, so the glyphs are decoded exactly
rather than guessed: sample the centre of each font pixel, threshold on the
overlay's yellow, and compare the 24-bit pattern against the 16 templates.
An unmatched cell is reported as '?' rather than being forced to a digit.
"""
import sys, glob, os
import numpy as np
from PIL import Image

FONT = {  # rows top->bottom, MSB = leftmost pixel
 0x0:(0xF,0x9,0x9,0x9,0x9,0xF), 0x1:(0x2,0x6,0x2,0x2,0x2,0x7),
 0x2:(0xF,0x1,0xF,0x8,0x8,0xF), 0x3:(0xF,0x1,0x7,0x1,0x1,0xF),
 0x4:(0x9,0x9,0xF,0x1,0x1,0x1), 0x5:(0xF,0x8,0xF,0x1,0x1,0xF),
 0x6:(0xF,0x8,0xF,0x9,0x9,0xF), 0x7:(0xF,0x1,0x2,0x4,0x4,0x4),
 0x8:(0xF,0x9,0xF,0x9,0x9,0xF), 0x9:(0xF,0x9,0xF,0x1,0x1,0xF),
 0xA:(0x6,0x9,0xF,0x9,0x9,0x9), 0xB:(0xE,0x9,0xE,0x9,0x9,0xE),
 0xC:(0xF,0x8,0x8,0x8,0x8,0xF), 0xD:(0xE,0x9,0x9,0x9,0x9,0xE),
 0xE:(0xF,0x8,0xE,0x8,0x8,0xF), 0xF:(0xF,0x8,0xE,0x8,0x8,0x8),
}
BITS = {d: [(r >> (3 - c)) & 1 for r in rows for c in range(4)] for d, rows in FONT.items()}

def find_box(a):
    """Locate the overlay box: its background is the only wide dark-navy run."""
    navy = (a[:,:,0] < 70) & (a[:,:,1] < 70) & (a[:,:,2] > 60) & (a[:,:,2] < 160)
    yel  = (a[:,:,0] > 170) & (a[:,:,1] > 170) & (a[:,:,2] < 120)
    hud = navy | yel
    rows = hud.sum(axis=1)
    ys = np.where(rows > 900)[0]
    if len(ys) < 40: return None
    y0, y1 = ys.min(), ys.max()
    cols = hud[y0:y1+1].sum(axis=0)
    xs = np.where(cols > (y1 - y0 + 1) * 0.8)[0]
    if len(xs) < 900: return None
    return xs.min(), y0, xs.max(), y1

def read_frame(a):
    box = find_box(a)
    if box is None: return None
    x0, y0, x1, y1 = box
    yel = (a[:,:,0] > 170) & (a[:,:,1] > 170) & (a[:,:,2] < 120)
    sw = (x1 - x0 + 1) / 16.0
    sh = (y1 - y0 + 1) / 6.0
    out = []
    for slot in range(16):
        pat = []
        for fy in range(6):
            yy = int(y0 + (fy + 0.5) * sh)
            for fx in range(4):
                xx = int(x0 + (slot + (fx + 0.5) / 4.0) * sw)
                pat.append(1 if yel[yy, xx] else 0)
        best, bd = None, 99
        for d, b in BITS.items():
            dd = sum(1 for i in range(24) if b[i] != pat[i])
            if dd < bd: bd, best = dd, d
        out.append(best if bd <= 2 else None)
    return out

def fmt(ds):
    return "".join("?" if d is None else "%X" % d for d in ds)

if __name__ == "__main__":
    files = sorted(glob.glob(os.path.join(sys.argv[1], "*.png")))
    print("file,vcyc,ecyc,coincred,mode,raw")
    for f in files:
        a = np.asarray(Image.open(f).convert("RGB")).astype(int)
        d = read_frame(a)
        if d is None:
            print(f"{os.path.basename(f)},,,,,NO-HUD"); continue
        v = fmt(d[0:4]); e = fmt(d[5:9]); c = fmt(d[10:14]); m = fmt(d[15:16])
        print(f"{os.path.basename(f)},{v},{e},{c},{m},{fmt(d)}")
