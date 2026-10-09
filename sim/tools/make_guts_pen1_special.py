#!/usr/bin/env python3
"""GUTS-169 control fixture: a Guts special (MPR2) sprite that contains pen 1.

MOSHADE-162 made special pixels of pen 1 DRAW in Escape (GAL 136069.100V's
extra write term). MAME's screen_update_guts skips every MPR2 object, and the
offline proof (docs/investigations/KLAX_GUTS.md 4c) matched MAME with that
rule, so in Guts mode no special pixel may reach the comparator. No sampled
Guts attract frame actually contains a pen-1 special, which is why the
original GUTS-168 benches could not see the difference. This builds one.

It rewrites the first on-screen special entry of an existing tb_mob fixture
(sim/work/game_mo.hex, made by make_guts_scene_hex.py from a Guts scene) to a
1x1 sprite using the Guts sprite tile with the most pen-1 pixels, and prints
how many pen-1 pixels that tile has.

Expected with tb_mob GUTS=1:  engine drawable pixels from that sprite = 0
Before the GUTS-169 gate:     the pen-1 pixels appear as drawable pixels.

Usage: make_guts_pen1_special.py <guts image .rom> [sim/work/game_mo.hex]
Writes the hex in place and keeps a .orig copy alongside.
"""
import os
import shutil
import sys


def tile_pen1_count(rom, code):
    base = 0x120000 + (code & 0x7FFF) * 32
    n = 0
    for b in rom[base:base + 32]:
        n += ((b >> 4) == 1) + ((b & 15) == 1)
    return n


def main(rom_path, hex_path):
    rom = open(rom_path, 'rb').read()
    ws = [int(l.strip(), 16) for l in open(hex_path) if l.strip()]
    target = None
    for i in range(0, len(ws), 4):
        w0, w1, w2, w3 = ws[i:i + 4]
        if (w1 & 0x7FFF) and (w3 >> 7) and ((w2 >> 4) & 4):
            target = i
            break
    if target is None:
        raise SystemExit('no special (MPR2) entry in %s' % hex_path)
    best = max(range(0x8000), key=lambda c: tile_pen1_count(rom, c))
    count = tile_pen1_count(rom, best)
    if count == 0:
        raise SystemExit('no sprite tile in the image contains pen 1')
    shutil.copyfile(hex_path, hex_path + '.orig')
    ws[target + 1] = (ws[target + 1] & 0x8000) | best   # keep w1[15] (Guts hflip)
    ws[target + 3] = ws[target + 3] & 0xFF80            # 1 tile wide, 1 tile tall
    with open(hex_path, 'w') as f:
        for w in ws:
            f.write('%04x\n' % w)
    e = target // 4
    print('entry %d: code -> 0x%04x (%d pen-1 pixels), 1x1, MPR2 kept (w2=0x%04x)'
          % (e, best, count, ws[target + 2]))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'sim/work/game_mo.hex')
