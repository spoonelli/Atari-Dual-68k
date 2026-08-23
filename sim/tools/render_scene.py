#!/usr/bin/env python3
"""Render a dumped MAME frame using the RTL's motion-object layer plus the
reference priority model, and diff it against MAME's own snapshot.

Inputs
  <dump_dir>   scene_{pf,pfext,al,pal}.bin + scene_info.txt + mame_frame.png
               (produced by the scenedump.lua autoboot script)
  --mo FILE    sim/build/mob_pixels.txt written by sim/tb/tb_mob.v: one line
               "<x> <y> <pen_hex> <prio>" per motion-object pixel the RTL line
               engine produced for this frame.
  --rom FILE   sim/work/atari_escape.rom (chars at 0x110000, tiles at 0x120000)

Outputs (in <dump_dir>)
  render_new.png    playfield + MO composited with the real priority comparator
  render_old.png    the same, composited with the old "MO always in front" rule
  render_diff.png   pixels where the two rules disagree, highlighted
  render_vs_mame.png  side by side with MAME's snapshot

The playfield and alpha layers here are modelled directly from MAME's tilemap
callbacks for eprom (reference/eprom.cpp get_playfield_tile_info /
get_alpha_tile_info and the pfmolayout / anlayout gfx layouts), so that any
disagreement is attributable to the motion-object engine or the priority rule
rather than to a re-derivation of the tile decode.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mo_priority_model import decide, mo_pen, pf_pen, MO_TRANSPARENT  # noqa: E402

W, H = 336, 240
CHARS_BASE = 0x110000
TILES_BASE = 0x120000


def words(path):
    b = open(path, 'rb').read()
    return [(b[i] << 8) | b[i + 1] for i in range(0, len(b), 2)]


def build_playfield(pf, pfx, rom, xscroll, yscroll):
    """MAME: TILEMAP_SCAN_COLS 64x64, 8x8 tiles, gfx 0 (pfmolayout, 4bpp),
    code = data1 & 0x7fff, colour = 0x10 + (data2 & 0x0f) with data2 = ext >> 8,
    flags = (data1 >> 15) & 1 = TILE_FLIPX.  Pen = 0x200 | colour<<4 | pixel."""
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        py = (y + yscroll) & 0x1FF
        row = py >> 3
        ty = py & 7
        for x in range(W):
            px = (x + xscroll) & 0x1FF
            idx = ((px >> 3) << 6) | row          # col*64 + row
            d1 = pf[idx]
            code = d1 & 0x7FFF
            flip = (d1 >> 15) & 1
            color = (pfx[idx] >> 8) & 0x0F
            n = px & 7
            if flip:
                n = 7 - n
            byte = rom[TILES_BASE + code * 32 + ty * 4 + (n >> 1)]
            pix = (byte >> 4) if (n & 1) == 0 else (byte & 0x0F)
            out[y][x] = pf_pen(color, pix)
    return out


def build_alpha(al, rom):
    """MAME: TILEMAP_SCAN_ROWS 64x31, 8x8, gfx 1 (anlayout, 2bpp, planes {0,4},
    xoffsets STEP4(0,1)+STEP4(8,1), yoffsets STEP8(0,16)), colour base 0,
    granularity 4.  code = data & 0x3ff,
    colour = ((data>>10)&0x0f) | ((data>>9)&0x20), opaque = data & 0x8000."""
    out = [[None] * W for _ in range(H)]
    for y in range(H):
        row = y >> 3
        ty = y & 7
        for x in range(W):
            col = x >> 3
            d = al[row * 64 + col]
            code = d & 0x3FF
            color = ((d >> 10) & 0x0F) | ((d >> 9) & 0x20)
            opaque = d & 0x8000
            n = x & 7
            xoff = n if n < 4 else n + 4
            base = CHARS_BASE + code * 16
            b0 = ty * 16 + xoff            # plane 0 (MSB)
            b1 = b0 + 4                    # plane 1 (LSB)
            p0 = (rom[base + (b0 >> 3)] >> (7 - (b0 & 7))) & 1
            p1 = (rom[base + (b1 >> 3)] >> (7 - (b1 & 7))) & 1
            pix = (p0 << 1) | p1
            if pix != 0 or opaque:
                out[y][x] = color * 4 + pix
    return out


def load_mo(path):
    """RTL line-engine output: {(x, y): (pen, prio)}."""
    mo = {}
    with open(path) as fh:
        for line in fh:
            t = line.split()
            if len(t) < 4:
                continue
            x, y = int(t[0]), int(t[1])
            if 0 <= x < W and 0 <= y < H:
                mo[(x, y)] = (int(t[2], 16), int(t[3]))
    return mo


def palette_rgb(pal, intensity=0):
    """reference/eprom.cpp update_palette."""
    out = []
    for data in pal:
        i = (((data >> 12) & 15) + 1) * (4 - intensity)
        if i < 0:
            i = 0
        r = ((data >> 8) & 15) * i // 4
        g = ((data >> 4) & 15) * i // 4
        b = (data & 15) * i // 4
        out.append((min(r, 255), min(g, 255), min(b, 255)))
    return out


def composite(pfmap, alpha, mo, new_rule):
    """Return the 336x240 array of colour RAM indices."""
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            pf = pfmap[y][x]
            hit = mo.get((x, y))
            if hit is None:
                pen = pf
            elif new_rule:
                pen, _ = decide(mo_pen(hit[1], (hit[0] >> 4) & 0xF,
                                       hit[0] & 0xF), pf)
            else:
                # the old compositor: any motion-object pixel wins outright
                pen = 0x100 | hit[0]
            a = alpha[y][x]
            out[y][x] = a if a is not None else pen
    return out


def to_image(idx, rgb):
    from PIL import Image
    im = Image.new('RGB', (W, H))
    px = im.load()
    for y in range(H):
        for x in range(W):
            px[x, y] = rgb[idx[y][x] & 0x7FF]
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dump')
    ap.add_argument('--mo', default='sim/build/mob_pixels.txt')
    ap.add_argument('--rom', default='sim/work/atari_escape.rom')
    ap.add_argument('--intensity', type=int, default=0)
    ap.add_argument('--mo-source', choices=('rtl', 'mame'), default='rtl',
                    help='rtl = the escape_mob.v line engine via --mo; '
                         'mame = a Python port of atarimo draw(), which '
                         'isolates the priority rule from the line engine')
    a = ap.parse_args()

    info = {}
    for line in open(os.path.join(a.dump, 'scene_info.txt')):
        if '=' in line:
            k, v = line.strip().split('=', 1)
            info[k] = v
    xs, ys = int(info['xscroll']), int(info['yscroll'])

    rom = open(a.rom, 'rb').read()
    pf = words(os.path.join(a.dump, 'scene_pf.bin'))
    pfx = words(os.path.join(a.dump, 'scene_pfext.bin'))
    al = words(os.path.join(a.dump, 'scene_al.bin'))
    pal = words(os.path.join(a.dump, 'scene_pal.bin'))

    pfmap = build_playfield(pf, pfx, rom, xs, ys)
    alpha = build_alpha(al, rom)
    rgb = palette_rgb(pal, a.intensity)

    if a.mo_source == 'mame':
        import mame_mo_model
        moram = words(os.path.join(a.dump, 'scene_mo.bin'))
        slip = words(os.path.join(a.dump, 'scene_slip.bin'))
        bm = mame_mo_model.draw(moram, slip, rom, xs, ys, W, H)
        mo = {}
        for y in range(H):
            for x in range(W):
                v = bm[y][x]
                if v != mame_mo_model.TRANSPARENT:
                    mo[(x, y)] = (v & 0xFF, (v >> 12) & 7)
    else:
        mo = load_mo(a.mo)

    new = composite(pfmap, alpha, mo, True)
    old = composite(pfmap, alpha, mo, False)

    from PIL import Image
    im_new = to_image(new, rgb)
    im_old = to_image(old, rgb)
    im_new.save(os.path.join(a.dump, 'render_new.png'))
    im_old.save(os.path.join(a.dump, 'render_old.png'))

    ndiff = 0
    dif = Image.new('RGB', (W, H))
    dpx = dif.load()
    for y in range(H):
        for x in range(W):
            if new[y][x] != old[y][x]:
                ndiff += 1
                dpx[x, y] = (255, 0, 255)
            else:
                g = sum(rgb[new[y][x] & 0x7FF]) // 6
                dpx[x, y] = (g, g, g)
    dif.save(os.path.join(a.dump, 'render_diff.png'))

    print('MO pixels from RTL      : %d' % len(mo))
    print('pixels changed by rule  : %d (%.2f%% of frame, %.2f%% of MO pixels)'
          % (ndiff, 100.0 * ndiff / (W * H),
             100.0 * ndiff / len(mo) if mo else 0.0))

    mame_path = os.path.join(a.dump, 'mame_frame.png')
    if os.path.exists(mame_path):
        ref = Image.open(mame_path).convert('RGB')
        if ref.size != (W, H):
            ref = ref.resize((W, H))
        for tag, im in (('new', im_new), ('old', im_old)):
            same = 0
            rp, ip = ref.load(), im.load()
            for y in range(H):
                for x in range(W):
                    if rp[x, y] == ip[x, y]:
                        same += 1
            print('exact-RGB match vs MAME (%s rule): %d/%d = %.2f%%'
                  % (tag, same, W * H, 100.0 * same / (W * H)))
        sbs = Image.new('RGB', (W * 3, H))
        sbs.paste(ref, (0, 0))
        sbs.paste(im_old, (W, 0))
        sbs.paste(im_new, (W * 2, 0))
        sbs.save(os.path.join(a.dump, 'render_vs_mame.png'))
        print('wrote render_vs_mame.png  (MAME | old rule | new rule)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
