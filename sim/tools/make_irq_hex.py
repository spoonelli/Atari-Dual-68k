#!/usr/bin/env python3
"""Build sim/work/irq_words.hex: reset stub enables IRQs (SR=$2000) and runs a
heartbeat loop; each iteration writes an incrementing counter to alpha[2]
(0x3F4004). VBLANK IRQ4 then exercises the game's REAL ISR (autovector 0x5CC,
jsr $20006, movem/rte) on TG68K in 68010 mode. If exception frames are correct,
the heartbeat keeps counting across many IRQs; if TG68K's 68010 frame push/RTE
is broken, the CPU derails and the heartbeat stops.
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
src = os.path.join(repo, "sim", "work", "combined_words.hex")
dst = os.path.join(repo, "sim", "work", "irq_words.hex")

words = [int(l, 16) for l in open(src)]

def poke(byte_addr, *ws):
    for i, w in enumerate(ws):
        words[byte_addr // 2 + i] = w & 0xFFFF

# reset PC -> 0x7F000
poke(0x4, 0x0007, 0xF000)

# IRQ4 autovector (0x70) -> minimal ISR at 0x7F020, isolating the CPU's own
# exception stacking/RTE from the game ISR's (uninitialized) state machine
poke(0x70, 0x0007, 0xF020)
poke(0x7F020,
     0x33FC, 0x0000, 0x0036, 0x0000,  # move.w #0,$360000.l  (ack VBLANK latch)
     0x4E73)                          # rte

poke(0x7F000,
     0x4FF9, 0x003F, 0x7F00,          # lea $3F7F00.l,a7       (game's boot SP)
     0x4247,                          # clr.w d7
     0x46FC, 0x2000,                  # move.w #$2000,SR       (enable all IRQs)
     # loop:
     0x33C7, 0x003F, 0x4004,          # move.w d7,$3F4004.l    (heartbeat -> alpha[2])
     0x5247,                          # addq.w #1,d7
     0x60F6)                          # bra.s loop (disp -10 -> 0x7F00C)

with open(dst, "w") as f:
    for w in words:
        f.write(f"{w:04x}\n")
print(f"wrote {dst} (reset -> IRQ-enabled heartbeat, real game ISR)")
