#!/usr/bin/env python3
"""Fail if the Quartus STA report contains any negative slack.

Project policy: never ship negative timing slack.

The slack lives in the SECOND column of each summary table, formatted as
    ; <clock name> ; <slack> ; <end point TNS> ;
The first version of this check anchored a regex at the start of the line, so
it matched nothing at all and cheerfully passed a build carrying -5.538 ns of
setup and -10.922 ns of hold. Parse the columns instead of pattern-matching.

Usage: check_slack.py src/fpga/output_files/ap_core.sta.rpt
"""
import re
import sys

TABLES = ("Setup Summary", "Hold Summary", "Recovery Summary",
          "Removal Summary", "Minimum Pulse Width Summary")


def main(path: str) -> int:
    txt = open(path, errors="replace").read()
    bad, missing = [], []
    for kind in TABLES:
        m = re.search(r"; %s\s*;(.*?)\n\n" % re.escape(kind), txt, re.S)
        if not m:
            missing.append(kind)
            continue
        for line in m.group(1).splitlines():
            cols = [c.strip() for c in line.split(";")]
            if len(cols) < 3:
                continue
            try:
                slack = float(cols[2])
            except ValueError:
                continue          # header or separator row
            if slack < 0:
                bad.append("%-28s %-70s %8.3f ns" % (kind, cols[1], slack))

    for kind in missing:
        print("WARNING: no '%s' table in %s" % (kind, path))
    if missing and not bad:
        # A missing table means the check did not actually look - say so
        # loudly rather than reporting a clean bill of health.
        print("Refusing to certify timing: %d expected table(s) were absent."
              % len(missing))
        return 1
    if bad:
        print("NEGATIVE SLACK - refusing to publish this bitstream:")
        for b in bad:
            print("  " + b)
        return 1
    print("All analysed clocks have non-negative slack.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
