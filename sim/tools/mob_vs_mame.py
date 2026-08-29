#!/usr/bin/env python3
"""Score the line engine's motion-object frame against MAME's OWN atarimo
renderer for the same scene.

sim/tools/mob_golden.py scores the engine against a model of its own intended
output, so its coverage number means "time starvation" and nothing else.  That
is the right scoreboard for throughput work, but it is the wrong one for DRAW
ORDER: a model derived from the engine would follow the engine into the same
mistake.

This runs sim/tools/mame_mo_model.py - a transcription of
atari_motion_objects_device::draw() with eprom's s_mob_config - over the same MO
RAM and SLIP fixtures, and diffs it against sim/build/mob_pixels.txt.  MAME
paints the linked list TAIL-first (REVERSE = True), so whichever sprite MAME
leaves on top of an overlap is exactly the sprite a head-first walk with
first-write-wins must also leave on top.  Any change to the order in which the
engine reaches sprites - a prefetch queue that reordered or re-timed the scout's
finds, for instance - shows up here as a wrong pen, and nowhere else.

Unlike sim/tools/render_scene.py this needs no MAME frame dump: MO RAM, SLIP and
the tile ROM are all the reference renderer needs, and they are already in
sim/work.

Usage (after sim/run_mob_tb.sh, which writes sim/build/mob_pixels.txt):
  mob_vs_mame.py --xscroll 123 --yscroll 253
"""
import argparse
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(REPO, 'sim', 'tools'))
import mame_mo_model  # noqa: E402

W, H = 336, 240


def words(path, count):
    out = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('//') or line.startswith('#'):
                continue
            for tok in line.split():
                out.append(int(tok, 16))
    if len(out) < count:
        out.extend([0] * (count - len(out)))
    return out[:count]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xscroll', type=int, default=123)
    ap.add_argument('--yscroll', type=int, default=253)
    ap.add_argument('--work', default=os.path.join(REPO, 'sim', 'work'))
    ap.add_argument('--mo', default=os.path.join(REPO, 'sim', 'build',
                                                 'mob_pixels.txt'))
    a = ap.parse_args()

    if not os.path.exists(a.mo):
        print('no %s - run sim/run_mob_tb.sh first' % a.mo)
        return 1

    moram = words(os.path.join(a.work, 'game_mo.hex'), 4096)
    cfg = words(os.path.join(a.work, 'game_cfg.hex'), 128)
    with open(os.path.join(a.work, 'atari_escape.rom'), 'rb') as fh:
        rom = fh.read()
    bm = mame_mo_model.draw(moram, cfg[0x40:0x80], rom,
                            a.xscroll, a.yscroll, W, H)
    # MOSTAIN-2: split the reference the way the engine reports it. A sprite
    # whose MO priority has bit 2 set is "special": atarimo puts it in the
    # bitmap, but screen_update_eprom `continue`s on it in the merge loop, so
    # it never draws. tb_mob logs those to mob_special.txt, NOT mob_pixels.txt.
    # Scoring them against the drawable log counted every special as "missing"
    # and made scenes built out of specials unscoreable.
    gold, gold_spec = {}, 0
    for y in range(H):
        for x in range(W):
            v = bm[y][x]
            if v == mame_mo_model.TRANSPARENT:
                continue
            if (v >> 12) & 4:
                gold_spec += 1
            else:
                gold[(x, y)] = v & 0xFF

    # Vacuity guard (replaces the old MO-RAM heuristic, which called the
    # FACTORY MAP "no scene" while the reference was drawing 296 pixels of it).
    # Judge the REFERENCE OUTPUT, not the fixture bytes: if the reference draws
    # nothing there is nothing to be right about, and "0 == 0" is not a pass.
    if not gold:
        print('VS-MAME VACUOUS reference draws ZERO drawable MO pixels here '
              '(%d special pixels present)' % gold_spec)
        print('  Nothing was scored. This run is not evidence about the MO '
              'engine either way - do not quote a percentage from it.')
        return 2

    got = {}
    with open(a.mo) as fh:
        for line in fh:
            t = line.split()
            if len(t) >= 3:
                got[(int(t[0]), int(t[1]))] = int(t[2], 16)

    hit = sum(1 for k, v in got.items() if gold.get(k) == v)
    wrong = sum(1 for k, v in got.items() if k in gold and gold[k] != v)
    extra = sum(1 for k in got if k not in gold)
    missing = len(gold) - hit - wrong
    # MOHOLE-116: report BOTH ratios. 'agreement' divides by what the ENGINE
    # produced, so a pixel the engine never drew is not in the denominator and
    # dropping pixels CANNOT lower it - this printed 'agreement=100.0000%'
    # alongside 'missing=832'. 'coverage' divides by the REFERENCE, which is
    # the number that actually moves when the engine loses pixels.
    print('VS-MAME engine_px=%d mame_px=%d (+%d special) agree=%d wrong_pen=%d '
          'not_in_mame=%d missing=%d agreement=%.4f%% coverage=%.4f%%'
          % (len(got), len(gold), gold_spec, hit, wrong, extra, missing,
             100.0 * hit / len(got) if got else 0.0,
             100.0 * hit / len(gold)))
    # The reference drew a layer and the engine drew none: that is a total
    # miss, not a clean sheet. Without this it fell through to wrong==0 = PASS.
    if not got:
        print('VS-MAME FAIL engine produced ZERO pixels while the reference '
              'produced %d - the layer is missing, not matching' % len(gold))
        return 1
    # A wrong pen where both renderers drew something is the draw-order signal:
    # same pixel, different sprite won it.
    if wrong:
        print('VS-MAME FAIL %d pixels went to a different sprite than MAME '
              'gave them - DRAW ORDER CHANGED' % wrong)
        return 1
    # MOHOLE-116: pixels the reference drew and the engine did not.
    #
    # This is the tile-hole artifact (docs/investigations/MO_TILE_HOLES.md) and it was
    # UNGATED until now: `missing` was computed and printed, but the only
    # failure paths were `wrong` and a TOTAL wipeout, so partial pixel loss
    # always passed. It is the same shape of defect as the total-wipeout case
    # someone patched above - caught then, missed for the partial case.
    #
    # This gate is proven to fire in both directions, which is the whole point
    # (see docs/investigations/LESSONS.md on checks that cannot fail):
    #   tb_mob GFX_JIT=0   -> missing=0    PASS
    #   tb_mob GFX_JIT=48  -> missing=26   FAIL
    #   tb_mob GFX_JIT=96  -> missing=832  FAIL
    # The baseline is exact, so the threshold is 0 - not a tolerance someone
    # has to justify later.
    if missing:
        print('VS-MAME FAIL %d pixels the reference drew are MISSING from the '
              'engine output (coverage %.4f%%) - dropped tiles, not draw order'
              % (missing, 100.0 * hit / len(gold)))
        print('  NOTE: agreement% stays at 100 here by construction; it '
              'divides by the engine output. Read coverage%.')
        return 1
    print('VS-MAME PASS no pixel was won by a different sprite than MAME '
          'gave it to, and none went missing')
    return 0


if __name__ == '__main__':
    sys.exit(main())
