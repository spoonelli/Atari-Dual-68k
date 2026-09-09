#!/usr/bin/env python3
"""MOSHADE-162: turn a dumped FACTORY MAP scene into a shadow-marker bench.

The level-1 map (sim/tools/scenedump2.lua at the map, or the harness scene
dump) carries exactly one motion object: the START box, code 0x22AB, a 3x3
SPECIAL sprite (MPR2) drawn in pen 6 - the stain-marker form.  The ROM keeps
a pen-1 TWIN of the same silhouette at 0x22A2 (see docs/investigations/
MAP_HALFTONE.md), and the game's travelled-route markers are 2x2 specials of
that pen-1 family in COLOUR 4 (frame table at ROM 0x6A938: attr 0x02F4).

This rewrites entry 1 of sim/work/game_mo.hex to that form (code 0x22A2,
colour 4) so sim/run_mob_tb.sh exercises the hardware rule GAL 136069.100V
imposes: a special pixel whose pen is exactly 1 IS written to the line
buffer and shades the playfield beneath it.  Expected census after the fix:
every covered pixel M7=1, SHADE=1, playfield wins, pens 0x300..0x30F (the
I=4 dim bank the game populates) - never 0x38X, never 0x6xX.

Usage: make_shadow_twin_scene.py [sim/work/game_mo.hex]
Writes the file in place and keeps a .orig copy alongside.
"""
import os, shutil, sys
p = sys.argv[1] if len(sys.argv) > 1 else 'sim/work/game_mo.hex'
ws = [l.strip() for l in open(p) if l.strip()]
w1, w2 = int(ws[5], 16), int(ws[6], 16)
if (w1 & 0x7FFF) != 0x22AB:
    raise SystemExit('entry 1 is code %04X, not the START box (22AB) - is this the level-1 map scene?' % (w1 & 0x7FFF))
if not os.path.exists(p + '.orig'):
    shutil.copy(p, p + '.orig')
ws[5] = '%04x' % ((w1 & 0x8000) | 0x22A2)
ws[6] = '%04x' % ((w2 & 0xFFF0) | 0x4)
open(p, 'w').write('\n'.join(ws) + '\n')
print('entry 1: code 22AB/colour 0 -> 22A2 (pen-1 twin)/colour 4; original kept as %s.orig' % p)
