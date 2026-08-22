#!/usr/bin/env python3
"""Build sim/work/vecrace_words.hex: synthetic EXTRA-CPU interrupt-dispatch
stress image for tb_escape_vecrace. Mirrors the real ROM's IRQ4 dispatch chain:

  autovector 0x70 -> 0x0000/0x0308 -> stub 0x308 (jmp $80C) -> trampoline
  table 0x800 (six 4EF9 0000 xxxx slots, exactly the real layout) -> ISR
  0x842 (movem push, read $260020, ack $360000, movem pop, RTE)

plus a recognizable DATA TABLE at 0xA58-0xB80 (repeating 9FF8 01DD like the
real one) so a wild jump parks somewhere the testbench can detect, and a main
loop at 0x6000 (OUTSIDE every shadow range, so with SHAD_EN=1 it fetches over
the SDRAM path while the dispatch chain is BRAM-served - the hardware split)
doing memory-mixed work: shared-RAM read/modify/write, jsr/rts churn so the
stack is active, and reads of $260020.

Image layout (rom service byte offsets): video CPU at 0x000000, extra CPU at
0x080000 (the ROM arbiter adds 0x080000 to extra-side addresses). 2^19 words.
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
dst = os.path.join(repo, "sim", "work", "vecrace_words.hex")
os.makedirs(os.path.dirname(dst), exist_ok=True)

AWIDTH = 19                      # word-address width (2^19 words = 1MB image)
words = [0] * (1 << AWIDTH)

def poke(byte_addr, *ws):
    for i, w in enumerate(ws):
        words[byte_addr // 2 + i] = w & 0xFFFF

E = 0x080000                     # extra-CPU image base

# ---------------------------------------------------------------- video CPU
# SSP = $3F7F00 (work RAM), PC = $400: park in a tight loop, IRQs masked
# (reset SR = 2700, never lowered) - it only exercises bus arbitration.
poke(0x0, 0x003F, 0x7F00)
poke(0x4, 0x0000, 0x0400)
poke(0x400, 0x60FE)                              # bra.s *

# ---------------------------------------------------------------- extra CPU
# reset: SSP = $16FF00 (shared RAM), PC = $6000
poke(E + 0x0, 0x0016, 0xFF00)
poke(E + 0x4, 0x0000, 0x6000)

# autovectors 0x64-0x7F, real-ROM-style values: level 4 -> $308, level 6 ->
# $306, everything else -> $300
poke(E + 0x64, 0x0000, 0x0300)                   # level 1
poke(E + 0x68, 0x0000, 0x0300)                   # level 2
poke(E + 0x6C, 0x0000, 0x0300)                   # level 3
poke(E + 0x70, 0x0000, 0x0308)                   # level 4 (VBLANK)
poke(E + 0x74, 0x0000, 0x0300)                   # level 5
poke(E + 0x78, 0x0000, 0x0306)                   # level 6
poke(E + 0x7C, 0x0000, 0x0300)                   # level 7

# stubs: $300 parks stray levels, $306 branches back, $308 = the real IRQ4
# stub: jmp into the trampoline table (slot 2 -> ISR $842)
poke(E + 0x300, 0x60FE)                          # bra.s *
poke(E + 0x306, 0x60F8)                          # bra.s $300
poke(E + 0x308, 0x4EF9, 0x0000, 0x080C)          # jmp $80C.l

# trampoline table at $800: six jmp slots exactly like the real ROM
poke(E + 0x800, 0x4EF9, 0x0000, 0x0970)          # slot 0
poke(E + 0x806, 0x4EF9, 0x0000, 0x08F6)          # slot 1
poke(E + 0x80C, 0x4EF9, 0x0000, 0x0842)          # slot 2 (IRQ4 path)
poke(E + 0x812, 0x4EF9, 0x0000, 0x0842)          # slot 3
poke(E + 0x818, 0x4EF9, 0x0000, 0x0842)          # slot 4
poke(E + 0x81E, 0x4EF9, 0x0000, 0x0994)          # slot 5

# ISR at $842: movem push, read $260020 (ADC/IO), ack $360000, movem pop, RTE
poke(E + 0x842,
     0x48E7, 0xFFFE,                             # movem.l d0-d7/a0-a6,-(sp)
     0x3039, 0x0026, 0x0020,                     # move.w $260020.l,d0
     0x33FC, 0x0000, 0x0036, 0x0000,             # move.w #0,$360000.l (ack)
     0x4CDF, 0x7FFF,                             # movem.l (sp)+,d0-d7/a0-a6
     0x4E73)                                     # rte

# secondary handlers (trampoline targets that exist in the real ROM): ack+rte
for h in (0x8F6, 0x970, 0x994):
    poke(E + h,
         0x33FC, 0x0000, 0x0036, 0x0000,         # move.w #0,$360000.l
         0x4E73)                                 # rte

# data table $A58-$B80: repeating 9FF8 01DD words like the real one - a wild
# jump into it executes harmless-looking suba encodings and parks
for a in range(0xA58, 0xB82, 4):
    poke(E + a, 0x9FF8, 0x01DD)

# main loop at $6000 (outside eshad1 <$4000 and eshad2 $F000-$FFFF: always
# SDRAM-path fetches). Realistic memory-mixed work with an active stack.
poke(E + 0x6000,
     0x4FF9, 0x0016, 0xFF00,                     # lea $16FF00.l,a7
     0x7E00,                                     # moveq #0,d7
     0x46FC, 0x2000,                             # move.w #$2000,SR (IRQs on)
     # loop (0x600C):
     0x4EB9, 0x0000, 0x6030,                     # jsr sub1
     0x3039, 0x0026, 0x0020,                     # move.w $260020.l,d0
     0x33C0, 0x0016, 0xF020,                     # move.w d0,$16F020.l
     0x5247,                                     # addq.w #1,d7
     0x33C7, 0x0016, 0xF010,                     # move.w d7,$16F010.l (heartbeat)
     0x4EB9, 0x0000, 0x6044,                     # jsr sub2
     0x60DE)                                     # bra.s loop (0x602E-0x22=0x600C)
poke(E + 0x6030,                                 # sub1: stack churn + nested call
     0x2F07,                                     # move.l d7,-(sp)
     0x4EB9, 0x0000, 0x6044,                     # jsr sub2
     0x3039, 0x0016, 0xF010,                     # move.w $16F010.l,d0
     0x2E1F,                                     # move.l (sp)+,d7
     0x4E75,                                     # rts
     0x4E71)                                     # nop (pad)
poke(E + 0x6044,                                 # sub2: shared-RAM rmw
     0x3239, 0x0016, 0xF004,                     # move.w $16F004.l,d1
     0x5241,                                     # addq.w #1,d1
     0x33C1, 0x0016, 0xF006,                     # move.w d1,$16F006.l
     0x4E75)                                     # rts

with open(dst, "w") as f:
    for w in words:
        f.write(f"{w:04x}\n")
print(f"wrote {dst} ({1 << AWIDTH} words: vecrace dispatch-chain image)")
