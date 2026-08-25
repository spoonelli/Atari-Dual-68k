#!/usr/bin/env python3
"""CADENCE-107: the image for sim/tb/tb_escape_cadence.vhd.

The cadence meter in escape_core.vhd is a new HUD counter, and this project's
history is a list of HUD counters that could not be wrong because nothing ever
made them wrong. So the image is a directed test with negative controls: the
video CPU executes an EXACTLY KNOWN number of the write the meter is supposed
to count, plus three writes it must ignore, and then spins.

  counted     move.b #$50,$16CCD4      x N_GOOD   (the main CPU's logic-frame
                                                   START, PERF_CADENCE sec. 1)
  ignored     move.b #$51,$16CCD4      x N_BAD    wrong data
  ignored     move.b #$50,$16CCD6      x N_BAD    the WORLD flag - written here
                                                   by the MAIN CPU, so it must
                                                   not land on either counter
                                                   (the world tap is port B)
  ignored     move.b #$50,$16CCD5      x N_BAD    odd address: low byte, LDS

The bench then reads the live counter through an external name and requires it
to equal N_GOOD exactly - not "roughly", and not "non-zero". A meter that
double-counts a multi-clock write strobe, decodes the wrong byte lane, or
matches too loosely fails on one of those four numbers.

Writes sim/work/cadence_words.hex (2^19 words, the escape_core image map).
"""
import os
import sys

AW_WORDS = 1 << 19
SSP = 0x00168000
FLAG_V = 0x0016CCD4        # main/video logic-frame flag
FLAG_W = 0x0016CCD6        # extra/world logic-frame flag

N_GOOD = 137               # deliberately not a round number
N_BAD = 41

MOVE_B_IMM_ABSL = 0x13FC   # move.b #imm,(xxx).L


def emit_move_b(img, wi, imm, addr):
    img[wi + 0] = MOVE_B_IMM_ABSL
    img[wi + 1] = imm & 0xFF
    img[wi + 2] = (addr >> 16) & 0xFFFF
    img[wi + 3] = addr & 0xFFFF
    return wi + 4


def build(loop_base):
    img = [0] * AW_WORDS
    img[0] = (SSP >> 16) & 0xFFFF
    img[1] = SSP & 0xFFFF
    img[2] = (loop_base >> 16) & 0xFFFF
    img[3] = loop_base & 0xFFFF

    wi = loop_base // 2
    for _ in range(N_GOOD):
        wi = emit_move_b(img, wi, 0x50, FLAG_V)
    for _ in range(N_BAD):
        wi = emit_move_b(img, wi, 0x51, FLAG_V)          # wrong data
        wi = emit_move_b(img, wi, 0x50, FLAG_W)          # world flag, wrong port
        wi = emit_move_b(img, wi, 0x50, FLAG_V + 1)      # odd byte -> LDS
    # spin forever: BRA.S to itself (displacement -2 from the byte after the
    # opcode word, which is this instruction's own address + 2)
    img[wi] = 0x60FE
    return img


def main(loop_base='0x001000'):
    base = int(loop_base, 0)
    img = build(base)
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.abspath(os.path.join(here, '..', '..'))
    dst = os.path.join(repo, 'sim', 'work', 'cadence_words.hex')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, 'w') as f:
        for w in img:
            f.write('%04x\n' % w)
    print('cadence image: code at 0x%06X, %d counted writes, %d x 3 decoys -> %s'
          % (base, N_GOOD, N_BAD, dst))
    print('EXPECT_GOOD=%d' % N_GOOD)
    return 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
