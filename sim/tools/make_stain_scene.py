#!/usr/bin/env python3
"""GFXDASH-3: build a synthetic MO scene that actually CONTAINS stain markers.

Why this exists
---------------
`sim/run_mob_tb.sh` passes 100.0000% on a real dumped frame that reports
"0 special pixels" and "SHADE pixels=0".  The gate that would catch a stain bug
has no stain in its scene, so the apply_stain path has never been exercised by
anything.  A dumped frame cannot fix that on demand - specials only appear on
the FACTORY MAP screen - so this builds the scene instead, with markers whose
START/END pen bits and screen extents are chosen, not discovered.

It emits, into sim/work/:
    stain_mo_f<N>.hex   MO RAM (4096 words), one file per frame
    stain_cfg.hex       SLIP/config RAM (128 words), same for every frame
    stain_gfx.hex       tile-row gfx, 8192 x 32-bit (code*8 + row)
and, into sim/build/:
    stain_expect.txt    the reference answer, from MAME's own apply_stain loop

The scene changes BETWEEN FRAMES on purpose.  A line buffer that keeps stale
pixels can only be caught by a scene where something moves, and the artifact
this bench was written for toggles at 2-frame parity (docs/investigations/GFX_DASH_ARTIFACT.md
sections 3c and 7), which needs at least three frames to see.

RTL contract this file encodes (src/fpga/core/rtl/escape_mob.v)
--------------------------------------------------------------
  entry i occupies MO words 4i..4i+3
    w0 = link[9:0]                      next entry; list ends when it points
                                        back at the SLIP head, or after 64
    w1 = code[14:0]
    w2 = color[3:0] | prio[6:4] | x[15:7]
    w3 = y[15:7] | width[6:4] | hflip[3] | height[2:0]
  SLIP  : cfg word 0x40 + (ly >> 3) holds the head link for that band
  Y     : ydiff = (ly + y + (height+1)*8) & 0x1FF, drawn while ydiff < (h+1)*8
  X     : blit_x = (x + tile*8 - xscroll) & 0x1FF, one pixel per column
  gfx   : byte 0x120000 + (code + ty*(width+1) + tx)*32 + row*4, four bytes,
          high nibble first, pen 0 transparent
  prio  : bit 2 (MPR2) = "special": the pixel occupies its slot but never
          draws; pen bit 1 is START_MARKER, pen bit 2 is END_MARKER
Everything above is read back out of the RTL by sim/tb/tb_stain.v driving the
real escape_mob.v, so a mistake here shows up as a bench that cannot fail
rather than as a silently wrong answer - which is why check_stain.py also
asserts that the scene it built produces a non-trivial number of stained
pixels and at least one marker of each kind.
"""
import os
import sys

MO_WORDS  = 4096
CFG_WORDS = 128
NCODE     = 1024          # tile codes we define gfx for
NFRAMES   = 6             # frames 0..5; the bench scores 2..5

VID_H_ACTIVE = 336
XSCROLL = 0
YSCROLL = 0

# ---------------------------------------------------------------- tile gfx
# Tile codes are handed out by pen: pen p owns the 64-code block starting at
# 64*p, every code in it a solid 8x8 block of that pen.  A block rather than a
# single code because a sprite's tile tx reads code + ty*(width+1) + tx, so a
# multi-tile sprite walks CONSECUTIVE codes - defining only the base code left
# every sprite one tile wide with the rest transparent, which is exactly the
# kind of quietly-half-empty fixture this bench exists to stop.
CODE_BLOCK = 64
PEN_USED = set()


def code_for_pen(pen):
    """Base code of pen `pen`'s solid-tile block.  Pen 0 is never art."""
    assert 1 <= pen <= 15
    PEN_USED.add(pen)
    return CODE_BLOCK * pen


def gfx_words():
    """8192 32-bit tile rows, indexed code*8 + row."""
    rows = [0] * (NCODE * 8)
    for pen in PEN_USED:
        w = 0
        for n in range(8):
            w |= (pen & 0xF) << (28 - 4 * n)
        base = CODE_BLOCK * pen
        for c in range(base, base + CODE_BLOCK):
            for r in range(8):
                rows[c * 8 + r] = w
    return rows


# ---------------------------------------------------------------- entries
class Sprite:
    """One MO list entry, in screen terms rather than register terms."""

    def __init__(self, x, ly_top, wtiles, htiles, pen, prio, color=3, hflip=0):
        assert 1 <= wtiles <= 8 and 1 <= htiles <= 8
        self.x = x
        self.ly_top = ly_top
        self.wt = wtiles - 1           # width_t  (tiles-1)
        self.ht = htiles - 1           # height_t (tiles-1)
        self.pen = pen
        self.prio = prio
        self.color = color
        self.hflip = hflip
        self.code = code_for_pen(pen)

    @property
    def yfield(self):
        # ydiff = ly + y + (h+1)*8  ==  ly - ly_top   =>   y = -ly_top - (h+1)*8
        return (-self.ly_top - (self.ht + 1) * 8) & 0x1FF

    def words(self, link):
        w0 = link & 0x3FF
        w1 = self.code & 0x7FFF
        w2 = (self.color & 0xF) | ((self.prio & 7) << 4) | ((self.x & 0x1FF) << 7)
        w3 = ((self.yfield & 0x1FF) << 7) | ((self.wt & 7) << 4) \
             | ((self.hflip & 1) << 3) | (self.ht & 7)
        return [w0, w1, w2, w3]

    def rows(self):
        return range(self.ly_top, self.ly_top + (self.ht + 1) * 8)

    def pixels(self, ly):
        """(screen_x, pen) this sprite paints on playfield row ly."""
        if ly not in self.rows():
            return
        for tx in range(self.wt + 1):
            for n in range(8):
                sx = (self.x + tx * 8 + n - XSCROLL) & 0x1FF
                if self.pen != 0:
                    yield sx, self.pen


# ---------------------------------------------------------------- the scene
# Each case owns a disjoint band of playfield rows (one 8-row SLIP band each),
# so one case can never explain another's result.
#
# The shape of the bug this bench exists for matters to the scene design.  A
# marker drawn entirely in pen 6 carries BOTH bits on every pixel, so however
# many of its pixels go missing the automaton still breaks one pixel past
# whatever survives - it can never run to the end of the line.  The unbounded
# mode needs a START run with NO end bit in it, i.e. a pen-2 body terminated by
# a SEPARATE pen-6/pen-4 column.  Losing that terminator is what turns a
# bounded stain into a stain that runs to the last screen column, which is the
# measured signature in docs/investigations/GFX_DASH_ARTIFACT.md section 3(c).
#
#   A  solid pen-6 marker, static           -> silhouette + one pixel
#   B  pen-2-only marker, static            -> to the end of the line (legit)
#   C  pen-2 body + pen-6 terminator        -> bounded at terminator + 1
#   D  a pen-6 marker that MOVES each frame -> only at its current position
#   E  C's shape, with a normal sprite that
#      occupied the terminator's columns
#      TWO frames ago and is long gone      -> still bounded at terminator + 1
CASE_ROWS = {'A': 24, 'B': 40, 'C': 56, 'D': 72, 'E': 88}
# Case D's marker position per frame.  Frames two apart differ, so a buffer
# that remembers two frames back shows the marker in two places at once.
D_X = [40, 140, 40, 140, 240, 40]


def scene(frame):
    """The MO list for one frame, head-first within each SLIP band."""
    bands = {}

    def add(sp):
        # A sprite belongs to the list of EVERY 8-row SLIP band it touches -
        # that is how the hardware's band lists work, and case E needs a
        # sprite that straddles two of them.
        for b in sorted({ly >> 3 for ly in sp.rows()}):
            bands.setdefault(b, []).append(sp)

    # A: solid pen 6 = START|END on every pixel, 2 tiles wide at x=100.
    add(Sprite(x=100, ly_top=CASE_ROWS['A'], wtiles=2, htiles=1, pen=6, prio=4))

    # B: pen 2 = START with no END anywhere on the line.  A legitimate mode,
    #    not a bug: it must stain to the end of the line before AND after any
    #    fix, which is what stops "just bound the stain" passing as a fix.
    add(Sprite(x=60, ly_top=CASE_ROWS['B'], wtiles=1, htiles=1, pen=2, prio=4))

    # C: pen-2 body, then a pen-6 terminator column immediately after it.
    add(Sprite(x=200, ly_top=CASE_ROWS['C'], wtiles=2, htiles=1, pen=2, prio=4))
    add(Sprite(x=216, ly_top=CASE_ROWS['C'], wtiles=1, htiles=1, pen=6, prio=4))

    # D: the same marker at a different column on frames two apart.
    add(Sprite(x=D_X[frame], ly_top=CASE_ROWS['D'], wtiles=2, htiles=1,
               pen=6, prio=4))

    # E: THE CASE THIS BENCH EXISTS FOR - a lost END marker.
    #    A stale line-buffer entry only survives if NOTHING rewrites that
    #    column in that buffer in between (the two buffers are shared by every
    #    line they serve, so the LAST line to write a column owns it). A marker
    #    that sits still therefore overwrites its own stale pixels and is
    #    immune; the hazard is a sprite ARRIVING at a column it did not occupy
    #    last frame, which is what every moving object in the game does.
    #
    #    So: an ordinary sprite holds the terminator's columns on frame 1 and
    #    only frame 1. The marker arrives there on frame 3, by which time the
    #    reference has had that sprite gone for two whole frames. A buffer
    #    whose staleness test is one frame-parity bit still calls frame 1's
    #    pixel live on frame 3 - it re-displays it AND refuses the marker's
    #    write - so the terminator never lands, and the stain runs from the
    #    marker's world-anchored left edge to the last screen column. That is
    #    the shape measured on hardware in docs/investigations/GFX_DASH_ARTIFACT.md section 3c.
    #    N's rows are chosen so that the LAST line it writes in each of the
    #    two line buffers is the FIRST line the marker will write there.
    #    Anything else and the marker's own earlier line overwrites the
    #    stale entry before the tag can collide with it - which is why a
    #    stationary object is immune and a moving one is not.
    if frame == 1:
        add(Sprite(x=256, ly_top=CASE_ROWS['E'] - 6, wtiles=1, htiles=1,
                   pen=5, prio=1))
    if frame >= 3:
        add(Sprite(x=240, ly_top=CASE_ROWS['E'], wtiles=2, htiles=1,
                   pen=2, prio=4))
        add(Sprite(x=256, ly_top=CASE_ROWS['E'], wtiles=1, htiles=1,
                   pen=6, prio=4))

    return bands


# ---------------------------------------------------------------- reference
def mo_bitmap(bands, ly):
    """MAME's motion-object bitmap for one row: {x: (pen, prio)}.

    atarimo draws the band's list in REVERSE order, so the head entry is
    painted last and wins every pixel it touches; walking head-first and
    refusing to overwrite is the same thing (escape_mob.v, S_BLIT).
    """
    out = {}
    for sp in bands.get(ly >> 3, []):
        for sx, pen in sp.pixels(ly):
            if sx < VID_H_ACTIVE and sx not in out:
                out[sx] = (pen, sp.prio)
    return out


def apply_stain_row(mo):
    """reference/atarimo.cpp apply_stain, restarted at every START marker by
    reference/eprom.cpp's second iterate_dirty_rects pass.

        START_MARKER = (4 << PRIORITY_SHIFT) | 2
        END_MARKER   = (4 << PRIORITY_SHIFT) | 4
    so BOTH halves must match: priority bit 2 AND the pen bit.
    """
    def is_s(x):
        e = mo.get(x)
        return e is not None and (e[1] & 4) and (e[0] & 2)

    def is_e(x):
        e = mo.get(x)
        return e is not None and (e[1] & 4) and (e[0] & 4)

    stained = set()
    for x0 in range(VID_H_ACTIVE):
        if not is_s(x0):
            continue
        offnext = False
        x = x0
        while x < VID_H_ACTIVE:
            stained.add(x)
            if offnext and not is_s(x):
                break
            offnext = is_e(x)
            x += 1
    return stained


# ---------------------------------------------------------------- emit
def write_hex(path, values, count, width=4):
    values = list(values)[:count]
    values += [0] * (count - len(values))
    with open(path, 'w') as f:
        for v in values:
            f.write('%0*x\n' % (width, v))


def main(out='sim/work', build='sim/build'):
    os.makedirs(out, exist_ok=True)
    os.makedirs(build, exist_ok=True)

    cfg = [0] * CFG_WORDS
    expect = []
    n_s = n_e = n_stain = 0

    for frame in range(NFRAMES):
        bands = scene(frame)
        mo = [0] * MO_WORDS
        link = 1                       # entry 0 is left as a null/idle entry
        for band, sprites in sorted(bands.items()):
            head = link
            cfg[0x40 + band] = head
            for i, sp in enumerate(sprites):
                nxt = head if i == len(sprites) - 1 else link + 1
                mo[link * 4:link * 4 + 4] = sp.words(nxt)
                link += 1
        assert link * 4 <= MO_WORDS
        write_hex(os.path.join(out, 'stain_mo_f%d.hex' % frame), mo, MO_WORDS)

        # the reference answer for every scored row of this frame
        for ly in range(240):
            bm = mo_bitmap(bands, ly)
            st = apply_stain_row(bm)
            for x in sorted(st):
                expect.append('S %d %d %d' % (frame, ly, x))
                n_stain += 1
            for x, (pen, prio) in sorted(bm.items()):
                if prio & 4:
                    if pen & 2:
                        n_s += 1
                    if pen & 4:
                        n_e += 1
                else:
                    # a special pixel occupies its slot but never draws
                    expect.append('P %d %d %d %d' % (frame, ly, x, pen))

    write_hex(os.path.join(out, 'stain_cfg.hex'), cfg, CFG_WORDS)
    write_hex(os.path.join(out, 'stain_gfx.hex'), gfx_words(), NCODE * 8, 8)
    with open(os.path.join(build, 'stain_expect.txt'), 'w') as f:
        f.write('# GFXDASH-3 reference: MAME apply_stain over the MO bitmap\n')
        f.write('# S <frame> <ly> <x>      pixel is stained (colour RAM |0x400)\n')
        f.write('# P <frame> <ly> <x> <pen> non-special MO pixel that draws\n')
        f.write('\n'.join(expect) + '\n')

    # A scene that contains no markers would make every check below vacuous.
    # Refuse to emit one, the same way dash_detect.py refuses to print a rate
    # when its positive control fails.
    if n_s == 0 or n_e == 0 or n_stain == 0:
        raise SystemExit('make_stain_scene: scene is vacuous '
                         '(S=%d E=%d stained=%d)' % (n_s, n_e, n_stain))
    print('stain scene: %d frames, %d START px, %d END px, %d stained px'
          % (NFRAMES, n_s, n_e, n_stain))
    print('case rows: ' + ', '.join('%s=%d' % kv for kv in sorted(CASE_ROWS.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
