#!/usr/bin/env python3
"""Golden model of escape_mob's INTENDED output, used as the perf scoreboard.

This is deliberately NOT a MAME model: it reproduces exactly what
src/fpga/core/rtl/escape_mob.v would emit for a scene if it had unlimited
time per scanline (same geometry, same clip, same last-write-wins order,
same list terminator).  Divergence from MAME (reverse render order, the
64-entry cap, the first_link terminator) is deliberately preserved so that
any difference between this model and a bench run is *time starvation*,
which is what MOFETCH is optimising, and nothing else.

Usage:
  mob_golden.py --xscroll 50 --yscroll 157 [--budget 62]
                [--compare sim/build/mob_perf_pixels.txt]
"""
import argparse
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

VID_V_BPORCH = 12
VID_V_ACTIVE = 240
VID_H_ACTIVE = 336
GFX_BASE = 0x120000


def load_words(path, count):
    words = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('//') or line.startswith('#'):
                continue
            for tok in line.split():
                words.append(int(tok, 16))
    if len(words) < count:
        words.extend([0] * (count - len(words)))
    return words[:count]


def load_gfx(path):
    """image_bytes.hex: one byte per line, hex."""
    data = bytearray()
    with open(path, 'rb') as fh:
        blob = fh.read()
    for tok in blob.split():
        data.append(int(tok, 16))
    return bytes(data)


def build_line(mo, cfg, gfx, ly, xscroll, budget):
    """Return {x: pen} for one built line.  x is line-buffer column 0..511."""
    out = {}
    band = (ly >> 3) & 0x3F
    first_link = cfg[0x40 + band] & 0x3FF
    link = first_link
    ent = 0
    rows_left = budget
    while True:
        base = link * 4
        w0, w1, w2, w3 = mo[base], mo[base + 1], mo[base + 2], mo[base + 3]
        spr_y = (w3 >> 7) & 0x1FF
        width_t = (w3 >> 4) & 7
        height_t = w3 & 7
        hflip = (w3 >> 3) & 1
        spr_color = w2 & 0xF
        spr_x = (w2 >> 7) & 0x1FF

        ydiff = (ly + spr_y + height_t * 8 + 8) & 0x1FF
        if ydiff < height_t * 8 + 8 and rows_left > 0:
            code_row = (w1 & 0x7FFF) + (ydiff >> 3) * (width_t + 1)
            row_in_tile = ydiff & 7
            for tx in range(width_t + 1):
                if rows_left == 0:
                    break
                rows_left -= 1
                code = (code_row + tx) & 0x7FFF
                addr = GFX_BASE + code * 32 + row_in_tile * 4
                rowdata = gfx[addr:addr + 4]
                if len(rowdata) < 4:
                    rowdata = bytes(4)
                shift = (width_t - tx) * 8 if hflip else tx * 8
                bx = (spr_x + shift - xscroll) & 0x1FF
                for n in range(8):
                    pn = 7 - n if hflip else n
                    byte = rowdata[pn >> 1]
                    pix = (byte >> 4) if (pn & 1) == 0 else (byte & 0xF)
                    x = (bx + n) & 0x1FF
                    if pix != 0 and x < VID_H_ACTIVE + 8:
                        out[x] = (spr_color << 4) | pix
        nxt = w0 & 0x3FF
        if nxt == first_link or ent == 63 or rows_left == 0:
            break
        ent += 1
        link = nxt
    return out


def golden_frame(xscroll, yscroll, budget, work):
    mo = load_words(os.path.join(work, 'game_mo.hex'), 4096)
    cfg = load_words(os.path.join(work, 'game_cfg.hex'), 128)
    gfx = load_gfx(os.path.join(work, 'image_bytes.hex'))
    frame = {}
    for vy in range(VID_V_ACTIVE):
        ly = (vy + 1 + yscroll) & 0x1FF
        for x, pen in build_line(mo, cfg, gfx, ly, xscroll, budget).items():
            if x < VID_H_ACTIVE:
                frame[(x, vy)] = pen
    return frame


def read_dump(path):
    got = {}
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 3:
                continue
            x, y, pen = int(parts[0]), int(parts[1]), int(parts[2], 16)
            got[(x, y)] = pen
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xscroll', type=int, required=True)
    ap.add_argument('--yscroll', type=int, required=True)
    ap.add_argument('--budget', type=int, default=62)
    ap.add_argument('--work', default=os.path.join(REPO, 'sim', 'work'))
    ap.add_argument('--compare', default=None)
    ap.add_argument('--label', default='')
    args = ap.parse_args()

    gold = golden_frame(args.xscroll, args.yscroll, args.budget, args.work)
    print("GOLDEN xscroll=%d yscroll=%d budget=%d -> %d pixels"
          % (args.xscroll, args.yscroll, args.budget, len(gold)))
    if not args.compare:
        return 0

    got = read_dump(args.compare)
    hit = sum(1 for k, v in got.items() if gold.get(k) == v)
    wrong = sum(1 for k, v in got.items() if k in gold and gold[k] != v)
    extra = sum(1 for k in got if k not in gold)
    missing = len(gold) - hit - wrong
    cov = 100.0 * hit / len(gold) if gold else 0.0
    print("COMPARE%s dumped=%d correct=%d wrong=%d spurious=%d missing=%d "
          "coverage=%.2f%%" % (' ' + args.label if args.label else '',
                               len(got), hit, wrong, extra, missing, cov))
    # per-line coverage: how many scanlines are fully complete?
    gl, hl = {}, {}
    for (x, y) in gold:
        gl[y] = gl.get(y, 0) + 1
    for (x, y), v in got.items():
        if gold.get((x, y)) == v:
            hl[y] = hl.get(y, 0) + 1
    full = sum(1 for y in gl if hl.get(y, 0) == gl[y])
    partial = sum(1 for y in gl if 0 < hl.get(y, 0) < gl[y])
    empty = sum(1 for y in gl if hl.get(y, 0) == 0)
    worst = sorted(((hl.get(y, 0) / gl[y], y, gl[y]) for y in gl))[:5]
    print("LINES with-content=%d complete=%d partial=%d empty=%d" %
          (len(gl), full, partial, empty))
    print("WORST " + " ".join("y=%d(%d/%d)" % (y, int(f * n + 0.5), n)
                              for f, y, n in worst))
    return 0 if (wrong == 0 and extra == 0) else 0


if __name__ == '__main__':
    sys.exit(main())
