#!/usr/bin/env python3
"""tb_mob fixtures from a mame_scene_dump.lua folder (either video map).
Writes game_mo.hex, game_cfg.hex, game_pf.hex, game_pfx.hex to <out> and
image_bytes.hex (one byte per line) from the combined image, and prints the
MOB_PARAMS to pass to the bench. For Guts add GUTS=1 to the parameters.
Usage: make_guts_scene_hex.py <dump_dir> <image.rom> [out=sim/work]
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_scene_hex import write_hex, words  # noqa: E402

def main(dump, rom, out):
    mo  = words(os.path.join(dump, 'mo.bin'))
    acs = words(os.path.join(dump, 'alpha_cfg_slip.bin'))
    pf  = words(os.path.join(dump, 'pf.bin'))
    pfx = words(os.path.join(dump, 'pfext.bin'))
    os.makedirs(out, exist_ok=True)
    write_hex(os.path.join(out, 'game_mo.hex'), mo, 4096)
    cfg = acs[0x780:0x7C0] + acs[0x7C0:0x800]          # MOB config words then SLIP
    write_hex(os.path.join(out, 'game_cfg.hex'), cfg, 128)
    write_hex(os.path.join(out, 'game_pf.hex'),  pf,  4096)
    write_hex(os.path.join(out, 'game_pfx.hex'), pfx, 4096)
    data = open(rom, 'rb').read()
    with open(os.path.join(out, 'image_bytes.hex'), 'w') as f:
        f.write(''.join('%02x\n' % b for b in data))
    print('wrote image_bytes.hex (%d bytes)' % len(data))
    xs = (acs[0x780] >> 7) & 0x1FF
    ys = (acs[0x781] >> 7) & 0x1FF
    print('scroll: XSCROLL=%d YSCROLL=%d' % (xs, ys))
    print("run: MOB_PARAMS='-PXSCROLL=%d -PYSCROLL=%d -PGUTS=1' ./sim/run_mob_tb.sh" % (xs, ys))

if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else 'sim/work')
