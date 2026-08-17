#!/usr/bin/env python3
"""Golden checker for tb_pf_cram: reconstructs each displayed 8px cell's
32-bit word from the dumped nibbles and verifies it equals the CRAM words
of the tile the map assigns to that cell (searching one global column
offset, then requiring it to hold everywhere). Reports mismatches per
display column - the accumulating-rightward latency signature seen on
hardware shows up directly as rising counts toward the right edge."""
import sys
from collections import defaultdict

PIX = "sim/build/pf_pixels.txt"

def cram_word(a21):          # matches tb: word[a] = low16(a * 2654435761)
    return (a21 * 2654435761) & 0xFFFF

def map_vdata(vaddr):        # matches tb map model
    return (((vaddr & 0xFFF) << 2) | (vaddr & 0xFFF)) & 0xFFFF

def tile_words(code15, row3):
    byte = 0x120000 + (code15 << 5) + (row3 << 2)
    wa = (byte >> 1) - 0x88000
    return (cram_word(wa & 0x1FFFFF) << 16) | cram_word((wa | 1) & 0x1FFFFF)

def main():
    grid = {}
    xpix = 0
    for line in open(PIX):
        x, y, v = line.split()
        if 'x' in v or 'z' in v:
            grid[(int(x), int(y))] = -1     # undefined pixel: always mismatches
            xpix += 1
        else:
            grid[(int(x), int(y))] = int(v, 16)
    if xpix:
        print(f"undefined (x/z) pixels: {xpix}")

    xs = max(x for x, _ in grid) + 1
    ys = max(y for _, y in grid) + 1
    cells_x, rows = xs // 8, ys

    def observed(cx, y):
        w = 0
        for i in range(8):
            w = (w << 4) | grid.get((cx * 8 + i, y), 0)
        return w

    def expected(cx, y, doff):
        vaddr = ((y >> 3) << 6) | ((cx + doff) & 0x3F)
        code = map_vdata(vaddr) & 0x7FFF
        return tile_words(code, y & 7)

    # find the single global column offset on a mid-frame sample
    best, best_hits = None, -1
    for d in range(0, 6):
        hits = sum(1 for cx in range(4, cells_x - 1) for y in range(64, 72)
                   if observed(cx, y) == expected(cx, y, d))
        if hits > best_hits:
            best, best_hits = d, hits
    print(f"global column offset: +{best} (sample hits {best_hits})")

    colerr = defaultdict(int)
    total = bad = 0
    for y in range(rows):
        for cx in range(2, cells_x):     # skip 2 line-start settling cells
            total += 1
            if observed(cx, y) != expected(cx, y, best):
                bad += 1
                colerr[cx] += 1
    print(f"cells checked {total}, mismatches {bad} ({100.0*bad/total:.3f}%)")
    if bad:
        print("per-column mismatch counts (col: count):")
        for cx in sorted(colerr):
            print(f"  {cx:3d}: {colerr[cx]}")
    ok = bad == 0
    print("TB_PF_CRAM " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
