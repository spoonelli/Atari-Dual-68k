#!/usr/bin/env python3
"""Offline render of a Guts n' Glory scene dump against MAME's own screenshot.

Purpose: prove the Guts video reading in docs/investigations/KLAX_GUTS.md
section 4 (MO entry format, priority rule, separate tile region) on real
data BEFORE any RTL is written for it. Everything here is transcribed from
MAME eprom.cpp (screen_update_guts, guts_get_playfield_tile_info,
s_guts_mob_config) and atarimo.cpp, with the Escape tooling's palette and
alpha decode reused unchanged.

Inputs: a folder written by sim/tools/mame_scene_dump.lua with MAP=guts
(pf.bin, pfext.bin, mo.bin, alpha_cfg_slip.bin, palette.bin, scene.png)
and the Guts combined image from support/build_rom.py.
Usage: guts_render.py sim/work/scenes/guts_f2400 --rom /tmp/guts.rom
Writes render.png, diff.png and prints the match statistics.

Differences from the eprom model, each a line in KLAX_GUTS.md section 4:
  * MO hflip is w1 bit 15 (eprom: w3 bit 3); MO height is w3 bits 3:0 (eprom: 2:0)
  * the active list renders FORWARD (eprom: reversed)
  * priority: MO drawn iff !(pf & 8) or mopriority >= pfpriority, pfpriority =
    (pf >> 5) & 3; MPR2 objects are skipped (then stain pass, not modelled here)
  * playfield tiles come from the image's 0x280000 slot, MOs from 0x120000
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_scene import build_alpha, palette_rgb, to_image, apply_stain, W, H  # noqa: E402
from mo_priority_model import pf_pen  # noqa: E402
import mame_mo_model as M  # noqa: E402

PF_TILES = 0x280000
MO_TILES = 0x120000


def words(path):
    b = open(path, 'rb').read()
    return [(b[i] << 8) | b[i + 1] for i in range(0, len(b), 2)]


def build_playfield(pf, pfx, rom, xscroll, yscroll):
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        py = (y + yscroll) & 0x1FF
        row, ty = py >> 3, py & 7
        for x in range(W):
            px = (x + xscroll) & 0x1FF
            idx = ((px >> 3) << 6) | row
            d1 = pf[idx]
            code = d1 & 0x7FFF
            flip = (d1 >> 15) & 1
            color = (pfx[idx] >> 8) & 0x0F
            n = px & 7
            if flip:
                n = 7 - n
            byte = rom[PF_TILES + code * 32 + ty * 4 + (n >> 1)]
            pix = (byte >> 4) if (n & 1) == 0 else (byte & 0x0F)
            out[y][x] = pf_pen(color, pix)
    return out


def guts_mo_draw(mo_ram, slip_ram, rom, xscroll, yscroll):
    """atarimo draw() with s_guts_mob_config: forward order, hflip w1[15], 4-bit height."""
    M.REVERSE = False
    M.TILES_BASE = MO_TILES
    orig_render = M._render

    def render(bm, e, rom_, xs, ys, ctop, cbottom, width, height):
        w0, w1, w2, w3 = e
        # rewrite the entry into eprom's field positions for the shared blitter:
        # hflip -> w3[3], height (4 bits) handled by our own loop below
        code = w1 & 0x7FFF
        color = w2 & 0x000F
        xpos = ((w2 & 0xFF80) >> 7)
        ypos = -((w3 & 0xFF80) >> 7)
        hflip = (w1 & 0x8000) != 0
        twidth = ((w3 & 0x0070) >> 4) + 1
        theight = (w3 & 0x000F) + 1
        priority = (w2 & 0x0070) >> 4
        color = (color * M.GRANULARITY) | (priority << 12)
        color += M.PALETTEBASE
        xpos -= xs; ypos -= ys
        ypos -= theight << M.TILEYSHIFT
        xpos &= M.XMASK; ypos &= M.YMASK
        if xpos >= width: xpos -= M.BITMAPW
        if ypos >= height: ypos -= M.BITMAPH
        xadv = M.TILEW
        sx0 = xpos
        if hflip:
            sx0 += (twidth - 1) << M.TILEXSHIFT
            xadv = -xadv
        sy = ypos
        for _ in range(theight):
            if sy <= ctop - M.TILEH:
                code += twidth; sy += M.TILEH; continue
            if sy > cbottom:
                break
            sx = sx0
            for _ in range(twidth):
                if not (sx <= -M.TILEW or sx > width - 1):
                    M._blit(bm, rom_, code, color, hflip, sx, sy, ctop, cbottom, width)
                code += 1; sx += xadv
            sy += M.TILEH
    M._render = render
    try:
        return M.draw(mo_ram, slip_ram, rom, xscroll, yscroll)
    finally:
        M._render = orig_render


def composite(pfmap, alpha, mobm, stain=True):
    """screen_update_guts: playfield, MO merge (MPR2 objects skipped), alpha,
    then the second pass that applies atarimo's stain from MPR2 objects whose
    pixel has bit 1 set - identical to Escape's pass, so render_scene's
    apply_stain is reused with START = pen bit 1, END = pen bit 2."""
    out = [[0] * W for _ in range(H)]
    spc = {}
    for y in range(H):
        for x in range(W):
            pf = pfmap[y][x]
            mo = mobm[y][x]
            pen = pf
            if mo != M.TRANSPARENT:
                mopriority = (mo >> 12) & 7
                pfpriority = (pf >> 5) & 3
                if mopriority & 4:
                    spc[(x, y)] = (1 if (mo & 2) else 0, 1 if (mo & 4) else 0)
                elif (not (pf & 8)) or mopriority >= pfpriority:
                    pen = mo & 0x0FFF
            a = alpha[y][x]
            out[y][x] = a if a is not None else pen
    if stain:
        apply_stain(out, spc)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dump')
    ap.add_argument('--rom', default='/tmp/guts.rom')
    ap.add_argument('--old-rule', action='store_true', help='use eprom priority instead (control)')
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read()
    pf = words(os.path.join(a.dump, 'pf.bin'))
    pfx = words(os.path.join(a.dump, 'pfext.bin'))
    mo = words(os.path.join(a.dump, 'mo.bin'))
    acs = words(os.path.join(a.dump, 'alpha_cfg_slip.bin'))
    al, cfg, slip = acs[:0x780], acs[0x780:0x7C0], acs[0x7C0:0x800]
    pal = words(os.path.join(a.dump, 'palette.bin'))
    xs = (cfg[0] >> 7) & 0x1FF
    ys = (cfg[1] >> 7) & 0x1FF
    print(f'scroll x={xs} y={ys}')
    pfmap = build_playfield(pf, pfx, rom, xs, ys)
    alpha = build_alpha(al, rom)
    mobm = guts_mo_draw(mo, slip, rom, xs, ys)
    idx = composite(pfmap, alpha, mobm)
    rgb = palette_rgb(pal, 0)
    im = to_image(idx, rgb)
    im.save(os.path.join(a.dump, 'render.png'))
    from PIL import Image, ImageChops
    ref = Image.open(os.path.join(a.dump, 'scene.png')).convert('RGB')
    if ref.size != (W, H):
        print('MAME snapshot size', ref.size, '- resizing to compare'); ref = ref.resize((W, H))
    diff = ImageChops.difference(im, ref)
    bbox = diff.getbbox()
    px = diff.load(); refpx = ref.load(); ourpx = im.load()
    bad = 0; mo_bad = 0
    for y in range(H):
        for x in range(W):
            if px[x, y] != (0, 0, 0):
                bad += 1
                if mobm[y][x] != M.TRANSPARENT: mo_bad += 1
    total = W * H
    print(f'pixel match: {100.0 * (total - bad) / total:.2f}%  mismatches {bad} (under MO pixels: {mo_bad})  bbox {bbox}')
    Image.eval(diff, lambda v: 255 if v else 0).save(os.path.join(a.dump, 'diff.png'))
    both = Image.new('RGB', (W * 2, H)); both.paste(im, (0, 0)); both.paste(ref, (W, 0)); both.save(os.path.join(a.dump, 'render_vs_mame.png'))


if __name__ == '__main__':
    main()
