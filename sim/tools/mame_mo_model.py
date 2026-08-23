#!/usr/bin/env python3
"""Python port of atari_motion_objects_device::draw() for the eprom config.

Only needed for validation: it lets sim/tools/render_scene.py build the exact
motion-object bitmap MAME would have produced for a dumped frame, so the
priority rule can be compared against MAME's snapshot without the RTL line
engine's own fidelity (fetch budget, links-per-line) confounding the result.

Transcribed from reference/atarimo.cpp (draw, build_active_list,
render_object) with the eprom s_mob_config from reference/eprom.cpp.
"""

TRANSPARENT = 0xFFFF

# --- eprom s_mob_config -----------------------------------------------------
LINKED = True
REVERSE = True
SLIPHEIGHT = 8
SLIPSHIFT = 3
SLIPOFFSET = 0
PALETTEBASE = 0x100
TRANSPEN = 0
GRANULARITY = 16            # gfx 0 is 4bpp
TILEW = TILEH = 8
TILEXSHIFT = TILEYSHIFT = 3
BITMAPW = BITMAPH = 512     # round_to_powerof2(0x1ff)
XMASK = YMASK = 511
MAXPERLINE = 1024
XOFFSET = 0
TILES_BASE = 0x120000


def draw(mo_ram, slip_ram, rom, xscroll, yscroll, width=336, height=240):
    """Return a height x width list of 16-bit MO bitmap values (0xffff = none)."""
    bm = [[TRANSPARENT] * width for _ in range(height)]

    startband = ((0 + yscroll - SLIPOFFSET) & YMASK) >> SLIPSHIFT
    stopband = (((height - 1) + yscroll - SLIPOFFSET) & YMASK) >> SLIPSHIFT
    if startband > stopband:
        startband -= BITMAPH >> SLIPSHIFT

    sliprammask = (BITMAPH >> SLIPSHIFT) - 1

    for band in range(startband, stopband + 1):
        link = slip_ram[band & sliprammask] & 0x03FF

        min_y = ((band << SLIPSHIFT) - yscroll + SLIPOFFSET) & YMASK
        if min_y >= height:
            min_y -= BITMAPH
        max_y = min_y + (1 << SLIPSHIFT) - 1
        # keep within the cliprect
        top = max(min_y, 0)
        bottom = min(max_y, height - 1)
        if top > bottom:
            continue

        # build_active_list
        active = []
        visited = set()
        cur = link
        for _ in range(MAXPERLINE):
            if cur in visited:
                break
            visited.add(cur)
            e = mo_ram[cur * 4:cur * 4 + 4]
            active.append(e)
            cur = e[0] & 0x03FF
        if not active:
            continue

        order = reversed(active) if REVERSE else active
        for e in order:
            _render(bm, e, rom, xscroll, yscroll, top, bottom, width, height)
    return bm


def _render(bm, e, rom, xscroll, yscroll, ctop, cbottom, width, height):
    w0, w1, w2, w3 = e
    code = w1 & 0x7FFF
    color = w2 & 0x000F
    xpos = ((w2 & 0xFF80) >> 7) + XOFFSET
    ypos = -((w3 & 0xFF80) >> 7)
    hflip = (w3 & 0x0008) != 0
    twidth = ((w3 & 0x0070) >> 4) + 1
    theight = (w3 & 0x0007) + 1
    priority = (w2 & 0x0070) >> 4

    color = (color * GRANULARITY) | (priority << 12)
    color += PALETTEBASE

    xpos -= xscroll
    ypos -= yscroll
    ypos -= theight << TILEYSHIFT

    xpos &= XMASK
    ypos &= YMASK
    if xpos >= width:
        xpos -= BITMAPW
    if ypos >= height:
        ypos -= BITMAPH

    xadv = TILEW
    sx0 = xpos
    if hflip:
        sx0 += (twidth - 1) << TILEXSHIFT
        xadv = -xadv

    sy = ypos
    for _ in range(theight):
        if sy <= ctop - TILEH:
            code += twidth
            sy += TILEH
            continue
        if sy > cbottom:
            break
        sx = sx0
        for _ in range(twidth):
            if not (sx <= -TILEW or sx > width - 1):
                _blit(bm, rom, code, color, hflip, sx, sy,
                      ctop, cbottom, width)
            code += 1
            sx += xadv
        sy += TILEH


def _blit(bm, rom, code, color, hflip, sx, sy, ctop, cbottom, width):
    base = TILES_BASE + (code & 0x7FFF) * 32
    for ty in range(TILEH):
        y = sy + ty
        if y < ctop or y > cbottom:
            continue
        row = bm[y]
        rowbase = base + ty * 4
        for tx in range(TILEW):
            x = sx + (TILEW - 1 - tx if hflip else tx)
            if x < 0 or x >= width:
                continue
            byte = rom[rowbase + (tx >> 1)]
            pix = (byte >> 4) if (tx & 1) == 0 else (byte & 0x0F)
            if pix == TRANSPEN:
                continue
            row[x] = color | pix
