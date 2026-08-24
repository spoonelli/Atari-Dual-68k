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
    bad, missing, found = [], [], 0
    for kind in TABLES:
        # Multi-corner Quartus prefixes the table with the timing model, e.g.
        # "; Slow 1100mV 85C Model Setup Summary ;", so the name cannot be
        # anchored to the ';'. It also emits one table PER CORNER, so search
        # for every occurrence rather than the first -- checking only the
        # first corner would pass a design that fails at another. Missing
        # this cost a build: the bare-name version refused to certify the
        # Pocket report entirely.
        hits = list(re.finditer(r";[^;\n]*\b%s\s*;(.*?)\n\n"
                                % re.escape(kind), txt, re.S))
        if not hits:
            missing.append(kind)
            continue
        for m in hits:
            label = m.group(0).split(";")[1].strip()
            for line in m.group(1).splitlines():
                cols = [c.strip() for c in line.split(";")]
                if len(cols) < 3:
                    continue
                try:
                    slack = float(cols[2])
                except ValueError:
                    continue          # header or separator row
                found += 1
                if slack < 0:
                    bad.append("%-46s %-46s %8.3f ns"
                               % (label, cols[1], slack))

    for kind in missing:
        print("WARNING: no '%s' table in %s" % (kind, path))
    if missing:
        # A missing table means the check did not actually look - say so
        # loudly rather than reporting a clean bill of health.
        print("Refusing to certify timing: %d expected table(s) were absent."
              % len(missing))
        return 1
    if not found:
        # Tables present but not one parseable row: the format changed under
        # us and this check is no longer measuring anything.
        print("Refusing to certify timing: tables found but no slack rows "
              "parsed - the report format has changed.")
        return 1
    if bad:
        print("NEGATIVE SLACK - refusing to publish this bitstream:")
        for b in bad:
            print("  " + b)
        return 1
    # Print the evidence. A gate that says "pass" without showing what it
    # measured is indistinguishable from a gate that matched nothing.
    print("All %d analysed clock/corner rows have non-negative slack." % found)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1]))
