#!/usr/bin/env python3
"""Turn a MAME video-state dump into the fixtures sim/tb/tb_mob.v reads.

The dump is produced by the scenedump.lua autoboot script (see
docs/mo_priority.md): it captures one frame's MO RAM, SLIP RAM, playfield RAM,
playfield "palette"/extmem RAM, alpha RAM and colour RAM, plus the scroll
registers, alongside MAME's own PNG snapshot of that exact frame.

Usage: make_scene_hex.py <dump_dir> [out_dir=sim/work]

Writes game_mo.hex, game_cfg.hex, game_pf.hex, game_pfx.hex and prints the
XSCROLL/YSCROLL values to pass to the bench as MOB_PARAMS.
"""
import os
import sys

# 68000 address ranges of each dumped region (see reference/eprom.cpp main_map)
PF    = (0x3F0000, 0x3F1FFF)
MOB   = (0x3F2000, 0x3F3FFF)
ALPHA = (0x3F4000, 0x3F4F7F)
SLIP  = (0x3F4F80, 0x3F4FFF)
PFEXT = (0x3F8000, 0x3F9FFF)


def words(path):
    b = open(path, 'rb').read()
    return [(b[i] << 8) | b[i + 1] for i in range(0, len(b), 2)]


def write_hex(path, ws, count):
    ws = list(ws)[:count]
    ws += [0] * (count - len(ws))
    with open(path, 'w') as f:
        for w in ws:
            f.write('%04x\n' % (w & 0xFFFF))
    print('wrote %s (%d words)' % (path, count))


def main(dump, out):
    mo    = words(os.path.join(dump, 'scene_mo.bin'))
    alpha = words(os.path.join(dump, 'scene_al.bin'))
    slip  = words(os.path.join(dump, 'scene_slip.bin'))
    pf    = words(os.path.join(dump, 'scene_pf.bin'))
    pfx   = words(os.path.join(dump, 'scene_pfext.bin'))

    os.makedirs(out, exist_ok=True)
    write_hex(os.path.join(out, 'game_mo.hex'), mo, 4096)

    # cfg RAM as the core sees it: words 0x00-0x3F are 3F4F00-3F4F7E (the tail of
    # alpha RAM, which holds the scroll registers at 0x780/0x781 word index), and
    # words 0x40-0x7F are the SLIP table at 3F4F80-3F4FFF.
    tail_start = (0x3F4F00 - ALPHA[0]) // 2
    cfg = alpha[tail_start:tail_start + 0x40] + slip[:0x40]
    write_hex(os.path.join(out, 'game_cfg.hex'), cfg, 128)

    write_hex(os.path.join(out, 'game_pf.hex'),  pf,  4096)
    write_hex(os.path.join(out, 'game_pfx.hex'), pfx, 4096)

    xs = (alpha[0x780] >> 7) & 0x1FF
    ys = (alpha[0x781] >> 7) & 0x1FF
    print('scroll: XSCROLL=%d YSCROLL=%d' % (xs, ys))
    print("run: MOB_PARAMS='-PXSCROLL=%d -PYSCROLL=%d' ./sim/run_mob_tb.sh" % (xs, ys))
    return 0


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'sim/work'))
