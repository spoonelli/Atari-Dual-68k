#!/usr/bin/env python3
"""MOSTAIN-2: prove the scanline stain recurrence equals atarimo's C loop.

`apply_stain` in reference/atarimo.cpp restarts its walk at every START marker
pixel, so what a scanline pipeline must produce is the UNION of those walks.
core_top.v implements that union as a two-flip-flop recurrence:

    stain(x) = S(x) | alive(x-1)
    alive(x) = stain(x) & ~( E(x-1) & ~S(x) )

That collapse is not obvious - in particular the C loop stains the breaking
pixel BEFORE testing the break, which is why `alive` and `stain` differ - so it
is worth a standing check rather than an argument in a comment.

This reads the RTL's own special-pass pixels (sim/build/mob_special.txt, written
by sim/tb/tb_mob.v as "<x> <y> <S> <E>") and runs both formulations over them.

    ./sim/run_mob_tb.sh                       # produces mob_special.txt
    python3 sim/tools/check_stain_automaton.py

HONEST LIMITATION, because this project has a history of tools that flatter
themselves: the recurrence below is a TRANSCRIPTION of the one in core_top.v,
not the shipped instance. iverilog never compiles core_top.v (run_mob_tb.sh
builds escape_mob.v + escape_prio.v only), so this check cannot catch a
divergence introduced in core_top.v itself - only a divergence between the
recurrence as written here and the reference C semantics. Extracting the
automaton into its own module so that the tested thing IS the shipped thing is
the real fix and is still outstanding. Do not quote this as evidence that the
hardware stain is correct; it is not.
"""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOG = os.path.join(REPO, 'sim', 'build', 'mob_special.txt')
W = 336


def load(path):
    """{y: {x: (S, E)}}"""
    lines = {}
    with open(path) as fh:
        for line in fh:
            t = line.split()
            if len(t) < 4:
                continue
            x, y, s, e = int(t[0]), int(t[1]), int(t[2]), int(t[3])
            if 0 <= x < W:
                lines.setdefault(y, {})[x] = (s, e)
    return lines


def c_loop(row):
    """reference/atarimo.cpp apply_stain, unioned over every START pixel."""
    out = set()
    for x0 in sorted(row):
        if not row[x0][0]:
            continue
        x, offnext = x0, False
        while x < W:
            out.add(x)
            q = row.get(x)
            if offnext and (q is None or not q[0]):
                break
            offnext = q is not None and bool(q[1])
            x += 1
    return out


def recurrence(row):
    """core_top.v: stain_now / stain_alive / stain_e_q, one pass along the line."""
    out = set()
    alive = e_q = 0
    for x in range(W):
        s = 1 if (x in row and row[x][0]) else 0
        e = 1 if (x in row and row[x][1]) else 0
        now = s | alive
        brk = e_q & (0 if s else 1)
        if now:
            out.add(x)
        alive = now & (0 if brk else 1)
        e_q = e
    return out


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else LOG
    if not os.path.exists(path):
        print('no %s - run sim/run_mob_tb.sh first' % path)
        return 1
    lines = load(path)
    if not lines:
        print('STAIN AUTOMATON VACUOUS - %s holds no special pixels, so nothing '
              'was compared. This is not a pass.' % path)
        return 1

    nc = nv = 0
    bad = []
    for y in sorted(lines):
        a, b = c_loop(lines[y]), recurrence(lines[y])
        nc += len(a)
        nv += len(b)
        if a != b:
            bad.append((y, sorted(a - b)[:8], sorted(b - a)[:8]))

    print('lines with special pixels : %d' % len(lines))
    print('stained px, C loop        : %d' % nc)
    print('stained px, recurrence    : %d' % nv)
    if bad:
        for y, only_c, only_v in bad:
            print('  MISMATCH line %d  only-C=%s  only-recurrence=%s'
                  % (y, only_c, only_v))
        print('STAIN AUTOMATON FAIL %d lines differ' % len(bad))
        return 1
    print('STAIN AUTOMATON PASS recurrence matches the C loop on every line')
    return 0


if __name__ == '__main__':
    sys.exit(main())
