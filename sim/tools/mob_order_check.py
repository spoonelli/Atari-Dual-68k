#!/usr/bin/env python3
"""MODEPTH-1: prove the park queue did not change the sprite DRAW ORDER.

The renderer reproduces eprom's reverse render order by walking the linked list
head-first and refusing to overwrite a pixel already written for this line
(first-write-wins, MOPLACE-3).  A prefetch queue that reordered or re-timed the
scout's finds would hand an overlapping pixel to a different sprite, and that is
a defect the coverage number alone can hide: a line that is starved either way
scores the same whichever sprite won.

So compare the ORDER directly.  tb_mob_perf's +ord=<path> dump writes one line
per sprite load, "<ly> <link>", in load order.  Both the depth-1 engine and the
depth-N one can emit it (it reads only mo_vaddr and ly at S_WAIT), so the two
runs are directly comparable.

The invariant: for every built line, both engines walk the SAME list from the
SAME head in the SAME direction and stop only when the scanline runs out.  The
shorter sequence must therefore be an exact PREFIX of the longer one.  Any
divergence at all - a swap, a skipped entry, a repeat - means the queue changed
which sprite the renderer reaches first, and therefore which one wins.

Usage:
  mob_order_check.py sim/build/ord_base.txt sim/build/ord_depth.txt
"""
import sys
from collections import OrderedDict


def load(path):
    lines = OrderedDict()
    with open(path) as fh:
        for raw in fh:
            parts = raw.split()
            if len(parts) != 2:
                continue
            ly, link = int(parts[0]), int(parts[1])
            lines.setdefault(ly, []).append(link)
    return lines


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    a = load(sys.argv[1])
    b = load(sys.argv[2])

    common = sorted(set(a) & set(b))
    bad = []
    longer = shorter = same = 0
    n_a = n_b = 0
    for ly in common:
        sa, sb = a[ly], b[ly]
        n_a += len(sa)
        n_b += len(sb)
        n = min(len(sa), len(sb))
        if sa[:n] != sb[:n]:
            first = next(i for i in range(n) if sa[i] != sb[i])
            bad.append((ly, first, sa[first], sb[first]))
        if len(sb) > len(sa):
            longer += 1
        elif len(sb) < len(sa):
            shorter += 1
        else:
            same += 1

    only_a = sorted(set(a) - set(b))
    only_b = sorted(set(b) - set(a))
    print("ORDER lines_compared=%d sprites_a=%d sprites_b=%d "
          "b_longer=%d b_shorter=%d b_same=%d lines_only_a=%d lines_only_b=%d"
          % (len(common), n_a, n_b, longer, shorter, same,
             len(only_a), len(only_b)))
    if bad:
        print("ORDER FAIL divergent_lines=%d" % len(bad))
        for ly, i, x, y in bad[:10]:
            print("  ly=%d position %d: a=link%d b=link%d" % (ly, i, x, y))
        return 1
    if only_a:
        # a line the reference built and this engine did not reach at all is a
        # regression in reach, not in order - report it, do not hide it
        print("ORDER NOTE lines the reference built and this run did not: %s"
              % only_a[:10])
    print("ORDER PASS every line's load sequence is a prefix-compatible match "
          "- draw order is unchanged")
    return 0


if __name__ == '__main__':
    sys.exit(main())
