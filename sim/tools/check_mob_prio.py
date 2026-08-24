#!/usr/bin/env python3
"""Replay sim/build/mob_prio.txt (one row per MO-covered pixel of the replayed
scene) through sim/tools/mo_priority_model.py and report agreement.

Unlike sim/tools/check_prio.py - which sweeps the comparator's whole input space
in isolation - this checks the decision as it is actually reached in a real
frame: the MO fields come from escape_mob.v walking real MO RAM, and the
playfield fields from the real tile maps at the real scroll offset.
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mo_priority_model import decide, mo_pen, pf_pen  # noqa: E402

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '..', 'build', 'mob_prio.txt')


def main(path=LOG):
    if not os.path.exists(path):
        print('no %s - run sim/run_mob_tb.sh first' % path)
        return 1

    total = agree = 0
    bad = []
    census = collections.Counter()
    prio_hist = collections.Counter()

    with open(path) as fh:
        for line in fh:
            if line.startswith('#') or not line.strip():
                continue
            t = line.split()
            (x, y, mo_valid, mo_prio, mo_color, mo_pix, pf_color, pf_pix,
             r_forcemc0, r_shade, r_m7, r_pfm, r_mo_win, r_pen) = \
                [int(v) for v in t[:14]]
            layer = t[14]

            out, info = decide(mo_pen(mo_prio, mo_color, mo_pix),
                               pf_pen(pf_color, pf_pix))
            exp = (info['forcemc0'], info['shade'], info['m7'], info['pfm'],
                   1 if info['layer'] == 'mo' else 0, out & 0x7FF)
            got = (r_forcemc0, r_shade, r_m7, r_pfm, r_mo_win, r_pen)

            total += 1
            if exp == got:
                agree += 1
            elif len(bad) < 20:
                bad.append(((x, y, mo_prio, mo_color, mo_pix, pf_color, pf_pix),
                            exp, got))

            census[layer] += 1
            prio_hist[mo_prio] += 1
            if r_shade:
                census['shade'] += 1
            if r_m7:
                census['m7'] += 1

    print('MO-covered pixels in the replayed frame : %d' % total)
    print('agreement with reference model          : %d/%d = %.4f%%'
          % (agree, total, 100.0 * agree / total if total else 0.0))
    print('layer census : MO drawn=%d  occluded by playfield=%d'
          % (census['mo'], census['pf']))
    print('              SHADE pixels=%d  M7 pixels=%d'
          % (census['shade'], census['m7']))
    print('MO priority histogram (MPR1:MPR0) : %s'
          % dict(sorted(prio_hist.items())))
    if bad:
        for inp, exp, got in bad:
            print('  MISMATCH at x=%d y=%d mo_prio=%d mo_color=%d mo_pix=%d '
                  'pf_color=%d pf_pix=%d' % inp)
            print('    expected (forcemc0,shade,m7,pfm,mo_win,pen)=%s' % (exp,))
            print('    got      %s' % (got,))
        return 1
    # MOSTAIN-2: a run with nothing in it is not a pass. This used to print no
    # verdict at all and still exit 0, so a scene the comparator never touched
    # (the FACTORY MAP has no drawable motion objects - MAME's own MO model
    # draws 296 pixels there and every one is a "special" that never draws)
    # read as success to anything checking the exit code, and the only number
    # left on screen came from a Python model. Say so, and fail.
    if not total:
        print('MOB PRIO CHECK VACUOUS - the comparator saw ZERO MO-covered '
              'pixels, so 0/0 measured nothing at all.')
        print('  Either the fixtures in sim/work are missing/empty, the bench '
              'ran at the wrong scroll, or this scene genuinely has no '
              'drawable motion objects.')
        print('  In every one of those cases this run is NOT evidence that '
              'anything works. Do not quote a percentage from it.')
        return 1
    print('MOB PRIO CHECK PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else LOG))
