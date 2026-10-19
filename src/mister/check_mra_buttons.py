#!/usr/bin/env python3
"""MRABTN-177 gate: every MRA's <buttons names> must mirror the core's J1 line.

Main applies an MRA's button names to the core's J1 positions in order
(joystick bits 4, 5, 6, ...). A list that is one name short shifts every
later function down a bit - the Guts MRA shipped six names against seven
positions in test builds 166-171, so Coin pressed Start and Pause inserted a
coin. Unused positions are written as "-" (Main hides them in Define buttons).
"""
import pathlib, re, sys

here = pathlib.Path(__file__).resolve().parent
sv = (here / "Arcade-Escape.sv").read_text()
m = re.search(r'"J1,([^;"]*);"', sv)
if not m:
    sys.exit("check_mra_buttons: no J1 line in Arcade-Escape.sv")
j1 = m.group(1).split(",")
bad = 0
mras = sorted((here / "releases").rglob("*.mra"))
for p in mras:
    b = re.search(r'<buttons\s+names="([^"]*)"\s+default="([^"]*)"', p.read_text(errors="replace"))
    if not b:
        print(f"FAIL {p.relative_to(here)}: no <buttons names=... default=...>")
        bad += 1
        continue
    names, defaults = b.group(1).split(","), b.group(2).split(",")
    if len(names) != len(j1):
        print(f"FAIL {p.relative_to(here)}: {len(names)} button names, core J1 has {len(j1)} ({','.join(j1)})")
        bad += 1
    if len(defaults) != len(names):
        print(f"FAIL {p.relative_to(here)}: {len(defaults)} defaults for {len(names)} names")
        bad += 1
if not mras:
    sys.exit("check_mra_buttons: no MRAs found")
if bad:
    sys.exit(1)
print(f"MRA BUTTONS PASS: {len(mras)} MRAs mirror J1 ({len(j1)} positions)")
