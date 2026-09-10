#!/usr/bin/env python3
"""Score the documented Guts video reading against alternatives over a folder
of scene dumps (sim/tools/mame_scene_dump.lua, MAP=guts). Prints one row per
frame; the documented column must be >= every control on every frame, and the
frames where the controls fall away are the discriminating fixtures."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import guts_render as G, mame_mo_model as M
from PIL import Image, ImageChops
D = sys.argv[1]; rom = open(sys.argv[2] if len(sys.argv) > 2 else '/tmp/guts.rom', 'rb').read()
def comp_pf4(pfmap, alpha, mobm):
    out = [[0] * G.W for _ in range(G.H)]
    for y in range(G.H):
        for x in range(G.W):
            pf = pfmap[y][x]; m = mobm[y][x]; pen = pf
            if m != M.TRANSPARENT:
                mp = (m >> 12) & 7; pp = (pf >> 4) & 3
                if not (mp & 4) and ((not (pf & 8)) or mp >= pp): pen = m & 0xFFF
            a = alpha[y][x]; out[y][x] = a if a is not None else pen
    return out
def comp_top(pfmap, alpha, mobm):
    out = [[0] * G.W for _ in range(G.H)]
    for y in range(G.H):
        for x in range(G.W):
            m = mobm[y][x]; pen = pfmap[y][x] if m == M.TRANSPARENT else (m & 0xFFF)
            a = alpha[y][x]; out[y][x] = a if a is not None else pen
    return out
orig_draw = M.draw
def draw_rev(*a, **k):
    M.REVERSE = True
    try: return orig_draw(*a, **k)
    finally: M.REVERSE = False
print(f"{'frame':>6} {'documented':>10} {'reverse':>8} {'eprom-fmt':>9} {'pfprio5:4':>9} {'MO-top':>7}   scroll  mismatches(doc)")
for f in sorted(os.listdir(D), key=lambda s: int(s[1:]) if s[1:].isdigit() else 0):
    d = os.path.join(D, f)
    if not os.path.isdir(d) or not os.path.exists(f'{d}/scene.png'): continue
    pf = G.words(f'{d}/pf.bin'); pfx = G.words(f'{d}/pfext.bin'); mo = G.words(f'{d}/mo.bin'); acs = G.words(f'{d}/alpha_cfg_slip.bin'); pal = G.words(f'{d}/palette.bin')
    al, cfg, slip = acs[:0x780], acs[0x780:0x7C0], acs[0x7C0:0x800]; xs = (cfg[0] >> 7) & 0x1FF; ys = (cfg[1] >> 7) & 0x1FF
    ref = Image.open(f'{d}/scene.png').convert('RGB'); rgb = G.palette_rgb(pal, 0)
    pfmap = G.build_playfield(pf, pfx, rom, xs, ys); alpha = G.build_alpha(al, rom)
    def score(mobm, comp=G.composite):
        im = G.to_image(comp(pfmap, alpha, mobm), rgb); px = ImageChops.difference(im, ref).load()
        bad = sum(1 for y in range(G.H) for x in range(G.W) if px[x, y] != (0, 0, 0)); return 100 * (G.W * G.H - bad) / (G.W * G.H), bad
    base = G.guts_mo_draw(mo, slip, rom, xs, ys); s_doc, bad = score(base)
    M.draw = draw_rev; bm = G.guts_mo_draw(mo, slip, rom, xs, ys); M.draw = orig_draw; s_rev, _ = score(bm)
    M.REVERSE = False; M.TILES_BASE = 0x120000; bm = M.draw(mo, slip, rom, xs, ys); s_ep, _ = score(bm)
    s_p4, _ = score(base, comp_pf4); s_top, _ = score(base, comp_top)
    print(f"{f:>6} {s_doc:9.2f}% {s_rev:7.2f}% {s_ep:8.2f}% {s_p4:8.2f}% {s_top:6.2f}%   x={xs} y={ys}  {bad}")
