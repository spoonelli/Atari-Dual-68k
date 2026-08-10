#!/usr/bin/env python3
"""Build sim/work/march_words.hex: the combined image with the VIDEO CPU reset
vector redirected to a stub that runs the game's own RAM-march routine (0xAAC)
on a 32-word slice of color RAM, then writes the result to alpha RAM:
  alpha[0] = d0 march result (0000 = pass, else EOR of bad bits)
  alpha[1] = 0xABCD done marker
Everything else (the march code itself, vectors, data) is the real program.
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
src = os.path.join(repo, "sim", "work", "combined_words.hex")
dst = os.path.join(repo, "sim", "work", "march_words.hex")

words = [int(l, 16) for l in open(src)]

def poke(byte_addr, *ws):
    for i, w in enumerate(ws):
        words[byte_addr // 2 + i] = w & 0xFFFF

# reset PC (bytes 4..7) -> 0x0007F000
poke(0x4, 0x0007, 0xF000)

# stub at 0x7F000 (unused top of video ROM window)
poke(0x7F000,
     0x43F9, 0x003E, 0x0000,          # lea $3E0000.l,a1   (march start)
     0x45F9, 0x003E, 0x003E,          # lea $3E003E.l,a2   (march end: 32 words)
     0x49FA, 0x000A,                  # lea 10(pc),a4      (fail/return -> 0x7F018)
     0x4EF9, 0x0000, 0x0AAC,          # jmp $AAC.l         (the game's real march)
     0x4E71)                          # nop
poke(0x7F018,
     0x33C0, 0x003F, 0x4000,          # move.w d0,$3F4000.l   (result -> alpha[0])
     0x33FC, 0xABCD, 0x003F, 0x4002,  # move.w #$ABCD,$3F4002.l (done marker)
     0x60FE)                          # bra.s *

with open(dst, "w") as f:
    for w in words:
        f.write(f"{w:04x}\n")
print(f"wrote {dst}: {len(words)} words (reset PC -> 0x7F000 march stub)")
