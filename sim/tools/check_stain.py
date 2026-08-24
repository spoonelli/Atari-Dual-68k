#!/usr/bin/env python3
"""GFXDASH-3: score sim/build/stain_actual.txt against the reference answer.

Reference is sim/build/stain_expect.txt, written by make_stain_scene.py from
reference/atarimo.cpp's own apply_stain loop over the motion-object bitmap
reference/eprom.cpp would have produced. Two independent things are diffed:

    P   which MO pixels DRAW           (catches stale line-buffer content
                                        directly, as a sprite in two places)
    S   which pixels are STAINED       (catches a lost END marker, as a stain
                                        that runs to the last screen column)

This check is designed to be able to fail, and is verified to fail: run it
against the RTL as of BUILD 107 and cases D and E both mismatch (see
docs/GFX_DASH_ARTIFACT.md). It also refuses to certify a run in which the
bench saw no markers, no stained pixels, or fewer frames than the scene has -
the three ways a broken fixture turns a diff clean.

Usage: check_stain.py [expect.txt] [actual.txt]
"""
import collections
import sys

# make_stain_scene.CASE_ROWS, repeated so a failure names the case that failed
CASES = [('A', 24), ('B', 40), ('C', 56), ('D', 72), ('E', 88)]
FIRST_SCORED = 2          # must match tb_stain.v's FIRST_SCORED parameter


def case_of(ly):
    for name, top in CASES:
        if top <= ly < top + 8:
            return name
    return '-'


def load(path):
    stain = set()
    pix = {}
    frames = set()
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        f = line.split()
        if f[0] == 'S':
            stain.add((int(f[1]), int(f[2]), int(f[3])))
            frames.add(int(f[1]))
        elif f[0] == 'P':
            pix[(int(f[1]), int(f[2]), int(f[3]))] = int(f[4])
            frames.add(int(f[1]))
    return stain, pix, frames


def spans(keys):
    """Collapse (frame, ly, x) keys into per-row x-spans, for readable output."""
    rows = collections.defaultdict(list)
    for fr, ly, x in keys:
        rows[(fr, ly)].append(x)
    out = []
    for (fr, ly), xs in sorted(rows.items()):
        xs.sort()
        lo = prev = xs[0]
        for x in xs[1:] + [None]:
            if x is None or x != prev + 1:
                out.append((fr, ly, lo, prev))
                if x is not None:
                    lo = x
            prev = x if x is not None else prev
    return out


def report(title, keys, limit=12):
    sp = spans(keys)
    print('  %s: %d px in %d spans' % (title, len(keys), len(sp)))
    for fr, ly, lo, hi in sp[:limit]:
        print('    case %s  frame %d  ly %3d  x %3d..%-3d (%d px)'
              % (case_of(ly), fr, ly, lo, hi, hi - lo + 1))
    if len(sp) > limit:
        print('    ... %d more spans' % (len(sp) - limit))


def main(exp_path='sim/build/stain_expect.txt',
         act_path='sim/build/stain_actual.txt'):
    e_stain, e_pix, e_frames = load(exp_path)
    a_stain, a_pix, a_frames = load(act_path)

    # ---- the checks that stop this from being another gate that cannot fail
    # tb_stain.v's FIRST_SCORED: frames 0..1 warm the line buffers, and the
    # reference covers every frame, so trim it to what the bench reports on.
    scored = sorted(f for f in e_frames if f >= FIRST_SCORED)
    e_stain = {k for k in e_stain if k[0] >= FIRST_SCORED}
    e_pix = {k: v for k, v in e_pix.items() if k[0] >= FIRST_SCORED}
    if not scored:
        print('CHECK_STAIN FAIL: reference contains no scored frames')
        return 2
    missing_frames = [f for f in scored if f not in a_frames]
    if missing_frames:
        print('CHECK_STAIN FAIL: bench produced nothing for frames %s - '
              'a short run is not a pass' % missing_frames)
        return 2
    if not a_stain:
        print('CHECK_STAIN FAIL: bench stained zero pixels. Either the '
              'fixtures are missing or the special path is dead; either way '
              'this is not a pass.')
        return 2

    # ---- the diffs
    s_missing = e_stain - a_stain          # reference stains, we do not
    s_extra   = a_stain - e_stain          # we stain, reference does not
    p_missing = set(e_pix) - set(a_pix)
    p_extra   = set(a_pix) - set(e_pix)
    p_wrong   = {k for k in set(e_pix) & set(a_pix) if e_pix[k] != a_pix[k]}

    print('frames scored              : %s' % scored)
    print('stained px  reference/bench: %d / %d' % (len(e_stain), len(a_stain)))
    print('MO px       reference/bench: %d / %d' % (len(e_pix), len(a_pix)))

    bad = 0
    if s_missing:
        report('STAIN MISSING (reference stains, bench does not)', s_missing)
        bad += len(s_missing)
    if s_extra:
        report('STAIN EXTRA (bench stains, reference does not)', s_extra)
        bad += len(s_extra)
    if p_missing:
        report('MO PIXEL MISSING', p_missing)
        bad += len(p_missing)
    if p_extra:
        report('MO PIXEL EXTRA (stale line-buffer content)', p_extra)
        bad += len(p_extra)
    if p_wrong:
        report('MO PIXEL WRONG PEN', p_wrong)
        bad += len(p_wrong)

    # per-case verdict, so a regression names the mode it broke
    by_case = collections.Counter()
    for fr, ly, x in list(s_missing) + list(s_extra):
        by_case[case_of(ly)] += 1
    for fr, ly, x in list(p_missing) + list(p_extra) + list(p_wrong):
        by_case[case_of(ly)] += 1
    print('per-case mismatches        : '
          + (', '.join('%s=%d' % (n, by_case.get(n, 0))
                       for n, _ in CASES) or 'none'))

    if bad:
        print('CHECK_STAIN FAIL: %d mismatching pixels' % bad)
        return 1
    print('CHECK_STAIN PASS: stain and MO coverage match the reference '
          'on every scored frame')
    return 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
