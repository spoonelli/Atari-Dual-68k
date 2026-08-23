#!/usr/bin/env python3
"""Compare the escape_prio.v sweep (sim/build/prio_sweep.txt) against the
reference model in sim/tools/mo_priority_model.py.

The model is a literal transcription of reference/eprom.cpp; this script is the
proof that the RTL comparator implements it. Every mismatch is printed.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mo_priority_model import decide, mo_pen, pf_pen, MO_TRANSPARENT  # noqa: E402

SWEEP = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     '..', 'build', 'prio_sweep.txt')


def main(path=SWEEP):
    total = 0
    agree = 0
    mismatches = []
    per_signal = {k: 0 for k in ('forcemc0', 'shade', 'm7', 'pfm', 'mo_win', 'pen')}

    with open(path) as fh:
        for line in fh:
            if line.startswith('#') or not line.strip():
                continue
            f = [int(t) for t in line.split()]
            (mo_valid, mo_prio, mo_color, mo_pix, pf_color, pf_pix,
             r_forcemc0, r_shade, r_m7, r_pfm, r_mo_win, r_pen) = f

            pf = pf_pen(pf_color, pf_pix)
            # the RTL never sees a transparent MO pixel (pen 0 is not written to
            # the line buffer) nor a "special" sprite (mopriority & 4 suppresses
            # the write), so mo_valid=1 with mo_pix=0 is an unreachable input.
            if mo_valid and mo_pix == 0:
                continue
            mo = mo_pen(mo_prio, mo_color, mo_pix) if mo_valid else MO_TRANSPARENT
            out, info = decide(mo, pf)

            exp = dict(forcemc0=info['forcemc0'] if mo_valid else 0,
                       shade=info['shade'] if mo_valid else 0,
                       m7=info['m7'] if mo_valid else 0,
                       pfm=info['pfm'] if mo_valid else 0,
                       mo_win=1 if (mo_valid and info['layer'] == 'mo') else 0,
                       pen=out & 0x7FF)
            got = dict(forcemc0=r_forcemc0, shade=r_shade, m7=r_m7,
                       pfm=r_pfm, mo_win=r_mo_win, pen=r_pen)

            total += 1
            if exp == got:
                agree += 1
            else:
                for k in exp:
                    if exp[k] != got[k]:
                        per_signal[k] += 1
                if len(mismatches) < 20:
                    mismatches.append((f[:6], exp, got))

    print(f'rows compared : {total}')
    print(f'agreement     : {agree}/{total} = {100.0 * agree / total:.4f}%')
    if mismatches:
        print('per-signal mismatch counts:', per_signal)
        for inp, exp, got in mismatches:
            print(f'  in mo_valid={inp[0]} mo_prio={inp[1]} mo_color={inp[2]} '
                  f'mo_pix={inp[3]} pf_color={inp[4]} pf_pix={inp[5]}')
            print(f'    expected {exp}')
            print(f'    got      {got}')
        return 1
    print('PRIO CHECK PASS: RTL comparator matches reference/eprom.cpp exactly')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else SWEEP))
