#!/usr/bin/env python3
"""VSHAD3-107: the image for sim/tb/tb_escape_busrate.vhd.

The question this bench answers is narrow on purpose: *how many CPU clocks
does one main-CPU ROM bus cycle take, on the real escape_core, when the
address is shadowed versus when it goes down the zero-wait fastpath?* That is
the whole of the vshad3 argument, and it is measurable without hardware.

So the image is deliberately not a game: it is a straight-line run of NOPs
ending in a short backward branch, placed at a chosen address. NOP touches no
data, so every bus cycle the CPU issues is an instruction fetch from the
region under test and nothing else is mixed into the average. The loop is 128
bytes so it sits inside one page and inside one shadow.

The extra CPU is never released (no 360011 write), so it contributes no bus
traffic and no SDRAM contention - contention is modelled instead by the
bench's G_FP fastpath-fill latency knob, which is the honest place for it,
because the real contention is with the MO engine and refresh, not with a
second CPU running this same silly loop.

Writes sim/work/busrate_words.hex (2^19 words, the escape_core image map).

Usage: make_busrate_hex.py [loop_byte_address=0x050000]
"""
import os
import sys

AW_WORDS = 1 << 19            # 1 MB image, word addressed
SSP = 0x00168000              # anywhere in work RAM; the loop never uses it
LOOP_WORDS = 64               # 128 bytes: 63 NOPs + BRA.S back to the top

NOP = 0x4E71


def build(loop_base):
    assert loop_base % 2 == 0
    assert (loop_base & ~0x7FFF) == ((loop_base + 2 * LOOP_WORDS - 1) & ~0x7FFF), \
        'loop must not straddle a 32 KB shadow boundary'
    img = [0] * AW_WORDS

    # reset vector: SSP then PC
    img[0] = (SSP >> 16) & 0xFFFF
    img[1] = SSP & 0xFFFF
    img[2] = (loop_base >> 16) & 0xFFFF
    img[3] = loop_base & 0xFFFF

    w0 = loop_base // 2
    for i in range(LOOP_WORDS - 1):
        img[w0 + i] = NOP
    # BRA.S with displacement measured from the byte after the opcode word:
    # here that is loop_base + 128, so the displacement back to the top is -128.
    img[w0 + LOOP_WORDS - 1] = 0x6000 | 0x80
    return img


def main(loop_base='0x050000'):
    base = int(loop_base, 0)
    img = build(base)
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, '..', '..'))
    dst = os.path.join(repo, 'sim', 'work', 'busrate_words.hex')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'w') as f:
        for w in img:
            f.write('%04x\n' % w)
    print('busrate image: loop at 0x%06X, %d words, -> %s'
          % (base, LOOP_WORDS, dst))
    return 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
