#!/usr/bin/env python3
"""Build sim/work/worldwake_words.hex: the WORLD-WAKE image for
tb_escape_worldwake — a faithful synthetic mirror of the real dual-CPU
runtime IRQ contract, built after the 87-91 regression saga proved the
vecrace image was UNFAITHFUL in exactly the ways that mattered:

  1. the real extra ROM's runtime vblank ISR (0x908-0x93C) has NO 360000
     store (flight-recorder truth) — vecrace's synthetic ISR acked 360000,
     hiding the 87/88 IRQ-storm class;
  2. the real extra parks in a critical-section poll loop (0x9B4-0x9D8:
     save SR / mask lvl5 / tst flag $16CCD6 / restore SR from $16CCD0 /
     loop) — the lost-wakeup (build 86 freeze) lives in the interaction
     of that loop's masked windows with the vblank pulse length;
  3. the real MAIN releases the extra (360011 D0), supervises the boot
     handshake with a timeout+restart, and its OWN vblank ISR writes the
     360000 ack ~50-60 CPU clocks after vblank — the shared-latch pulse
     the extra ROM was designed against. vecrace's main parked with IRQs
     masked and never released the extra, so after the 87b release gating
     the bench delivered ZERO extra-CPU interrupts (iack_cyc=0) and every
     'IRQ matrix green' from 88 to 91 was vacuous.

THE POST HAZARD this image reproduces: the extra boots IRQ-MASKED, runs a
POST phase lasting several frames (marches: the image does a small w/r
sweep over 16CCxx + a calibrated masked delay), and only then unmasks.
Its ISR writes 0x50 through a RAM-held pointer ($16CCE0) that during POST
points into POST's workspace (canary $16C800) and is only repointed to
the real flag ($16CCD6) by runtime init. A vblank interrupt delivered AT
THE UNMASK INSTANT (any latched-IRQ design that holds a pending vblank
across the masked POST does this on EVERY boot) tramples the canary, the
POST verify fails, the extra parks at POSTFAIL (0xBAC — the march band
where build 90/91's HUD showed the extra spinning), the main times out
and restarts it: the endless-restart world-death seen on device.

Layout: video CPU at image 0x000000, extra CPU at image 0x080000 (the ROM
arbiter/fastpath adds 0x080000 to extra-side addresses). 2^19 words.

Options (env):
  SLOW=1   pad the poll loop's MASKED section by ~200 clks — models the
           pre-zerowait SDRAM-starved loop whose masked stretches exceeded
           the authentic ~60-clk ack pulse: the build-86 lost-wakeup
           regime (use with a locked vblank period to reproduce the
           permanent phase-locked freeze).
"""
import os, sys

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
dst = os.path.join(repo, "sim", "work", "worldwake_words.hex")
os.makedirs(os.path.dirname(dst), exist_ok=True)

SLOW = os.environ.get("SLOW", "0") == "1"

AWIDTH = 19
words = [0] * (1 << AWIDTH)
E = 0x080000                      # extra-CPU image base


class Asm:
    """Tiny two-pass hand-assembler: emit fixed words + labels + short
    branches, with collision checking so nothing overlaps silently."""
    def __init__(self, base):
        self.base = base          # image byte base (0 or E)
        self.pc = 0               # byte address within CPU space
        self.out = {}             # byte addr -> word
        self.labels = {}
        self.fixups = []          # (byte_addr, kind, target_label)

    def org(self, addr):
        self.pc = addr

    def label(self, name):
        self.labels[name] = self.pc

    def w(self, *ws):
        for x in ws:
            assert self.pc % 2 == 0
            assert self.pc not in self.out, \
                f"overlap at {self.pc:#x} (base {self.base:#x})"
            self.out[self.pc] = x & 0xFFFF
            self.pc += 2

    def bra_s(self, target):      # 60xx
        self.fixups.append((self.pc, "bs", target)); self.w(0x6000)

    def bne_s(self, target):      # 66xx
        self.fixups.append((self.pc, "bs_ne", target)); self.w(0x6600)

    def beq_s(self, target):      # 67xx
        self.fixups.append((self.pc, "bs_eq", target)); self.w(0x6700)

    def dbra(self, target):       # 51C9 disp16 (d1)
        self.fixups.append((self.pc, "db", target)); self.w(0x51C9, 0)

    def jmp(self, target):        # 4EF9 abs.l (label = CPU-space addr)
        self.fixups.append((self.pc, "jl", target))
        self.w(0x4EF9, 0, 0)

    def resolve(self):
        for at, kind, tgt in self.fixups:
            t = self.labels[tgt] if isinstance(tgt, str) else tgt
            if kind in ("bs", "bs_ne", "bs_eq"):
                disp = t - (at + 2)
                assert -128 <= disp <= 127 and disp != 0, \
                    f"short branch out of range at {at:#x} -> {t:#x}"
                self.out[at] |= (disp & 0xFF)
            elif kind == "db":
                disp = t - (at + 2)
                assert -32768 <= disp <= 32767
                self.out[at + 2] = disp & 0xFFFF
            elif kind == "jl":
                self.out[at + 2] = (t >> 16) & 0xFFFF
                self.out[at + 4] = t & 0xFFFF

    def commit(self):
        self.resolve()
        for a, x in self.out.items():
            gi = (self.base + a) // 2
            assert words[gi] == 0, f"image collision at {self.base + a:#x}"
            words[gi] = x


# ---------------------------------------------------------------- video CPU
m = Asm(0)
m.org(0x0); m.w(0x003F, 0x7F00)                     # SSP = $3F7F00 (work RAM)
m.org(0x4); m.w(0x0000, 0x0400)                     # PC  = $400
m.org(0x70); m.w(0x0000, 0x0500)                    # autovector level 4 -> ISR

m.org(0x400)
m.w(0x46FC, 0x2700)                                 # move.w #$2700,SR
m.w(0x4FF9, 0x003F, 0x7F00)                         # lea $3F7F00.l,a7
m.w(0x33FC, 0x0000, 0x0016, 0xFFE2)                 # clr handshake slot
m.w(0x13FC, 0x0001, 0x0036, 0x0011)                 # move.b #1,$360011 RELEASE
m.w(0x46FC, 0x2000)                                 # IRQs on (level 4 live)
m.label("WAIT")
# timeout must comfortably exceed the extra's POST duration (both scale
# together under slower fetch paths): ~2500 poll passes ~= 40 frames
m.w(0x323C, 0x09C4)                                 # move.w #2500,d1 (timeout)
m.label("WLOOP")
m.w(0x3039, 0x0016, 0xFFE2)                         # move.w $16FFE2.l,d0
m.w(0x0C40, 0x4321)                                 # cmpi.w #$4321,d0
m.beq_s("RUN")
m.dbra("WLOOP")
# timeout: authentic supervision - stop, count, clear, re-release
m.w(0x13FC, 0x0000, 0x0036, 0x0011)                 # stop extra
m.w(0x5279, 0x003F, 0x7F20)                         # addq.w #1,$3F7F20 restarts
m.w(0x33FC, 0x0000, 0x0016, 0xFFE2)                 # clear handshake slot
m.w(0x13FC, 0x0001, 0x0036, 0x0011)                 # re-release
m.bra_s("WAIT")
m.label("RUN")
m.w(0x5279, 0x003F, 0x7F10)                         # addq.w #1,$3F7F10 heartbeat
# authentic wave-transition restart, once: at heartbeat 0x2000 (~frame 170)
# stop and re-release the extra (it re-POSTs, re-handshakes, re-enters the
# poll loop) - proves EIRQ_MODE 2's disarm -> re-arm path end to end
m.w(0x3039, 0x003F, 0x7F10)                         # move.w $3F7F10.l,d0
m.w(0x0C40, 0x2000)                                 # cmpi.w #$2000,d0
m.bne_s("RUN")
m.w(0x13FC, 0x0000, 0x0036, 0x0011)                 # stop extra
m.w(0x13FC, 0x0001, 0x0036, 0x0011)                 # re-release
m.bra_s("RUN")

m.org(0x500)                                        # main vblank ISR:
m.w(0x33FC, 0x0000, 0x0036, 0x0000)                 #   ack $360000 (the pulse!)
m.w(0x5279, 0x003F, 0x7F30)                         #   addq.w #1,$3F7F30
m.w(0x4E73)                                         #   rte
m.commit()

# ---------------------------------------------------------------- extra CPU
e = Asm(E)
e.org(0x0); e.w(0x0016, 0xFF00)                     # SSP = $16FF00 (shared RAM)
e.org(0x4); e.w(0x0000, 0x0200)                     # PC  = $200 (POST)

# real-ROM-style vectors: level 4 -> $308 stub
e.org(0x64); e.w(0x0000, 0x0300)                    # level 1
e.org(0x68); e.w(0x0000, 0x0300)
e.org(0x6C); e.w(0x0000, 0x0300)
e.org(0x70); e.w(0x0000, 0x0308)                    # level 4 (VBLANK)
e.org(0x74); e.w(0x0000, 0x0300)
e.org(0x78); e.w(0x0000, 0x0306)
e.org(0x7C); e.w(0x0000, 0x0300)

e.org(0x200)                                        # POST (SR=2700 from reset)
# mini-march over the flag page 16CC00-16CCFF: write/read each word.
# This is the false-arm probe for the EIRQ_MODE 2 detector: POST touches
# the flag address with w/r pairs and must NOT arm delivery.
e.w(0x43F9, 0x0016, 0xCC00)                         # lea $16CC00.l,a1
e.w(0x323C, 0x007F)                                 # move.w #$7F,d1
e.label("MARCH")
e.w(0x3281)                                         # move.w d1,(a1)
e.w(0x3411)                                         # move.w (a1),d2
e.w(0x5489)                                         # addq.l #2,a1
e.dbra("MARCH")
# POST workspace canary + the ISR's RAM pointer left aimed at it
# (models runtime state NOT yet initialized: an ISR firing during POST
# writes 0x50 into POST's own workspace)
e.w(0x33FC, 0xA5A5, 0x0016, 0xC800)                 # canary $16C800 = A5A5
e.w(0x23FC, 0x0016, 0xC800, 0x0016, 0xCCE0)         # ptr $16CCE0 -> canary
# masked delay: with the march above, POST spans ~7 frames at G_FRAME=2500
e.w(0x323C, 0x04B0)                                 # move.w #1200,d1
e.label("DELAY")
e.dbra("DELAY")
# ---- THE HAZARD POINT: first unmask after a multi-frame masked POST.
# Any pending vblank latched across the mask fires HERE, through the
# uninitialized pointer.
e.w(0x46FC, 0x2000)                                 # move.w #$2000,SR
e.w(0x4E71, 0x4E71)                                 # 2 nops: open window
e.w(0x46FC, 0x2700)                                 # re-mask (authentic POSTs
                                                    #   re-mask for later work)
# POST verify: canary intact?
e.w(0x3039, 0x0016, 0xC800)                         # move.w $16C800.l,d0
e.w(0x0C40, 0xA5A5)                                 # cmpi.w #$A5A5,d0
e.bne_s("TOFAIL")
# handshake response + runtime init
e.w(0x33FC, 0x4321, 0x0016, 0xFFE2)                 # respond $4321
e.w(0x23FC, 0x0016, 0xCCD6, 0x0016, 0xCCE0)         # ptr -> real flag $16CCD6
e.w(0x4239, 0x0016, 0xCCD6)                         # clr.b flag
e.w(0x46FC, 0x2000)                                 # runtime unmask baseline
e.jmp(0x9B4)                                        # enter the world loop
e.label("TOFAIL")
e.jmp(0xBAC)                                        # park in the march band

e.org(0x300); e.w(0x60FE)                           # stray levels park
e.org(0x306); e.w(0x60F8)                           # bra.s $300
e.org(0x308); e.w(0x4EF9, 0x0000, 0x080C)           # IRQ4 stub -> trampoline

e.org(0x80C); e.w(0x4EF9, 0x0000, 0x0908)           # trampoline slot -> ISR

# runtime vblank ISR at the REAL address 0x908: sets the wake flag through
# the RAM pointer. NO 360000 STORE (flight-recorder truth: 0x908-0x93C has
# no 36xxxx write - the ROM relied on the main's shared-latch ack).
e.org(0x908)
e.w(0x2F08)                                         # move.l a0,-(sp)
e.w(0x2F00)                                         # move.l d0,-(sp)
e.w(0x2079, 0x0016, 0xCCE0)                         # movea.l $16CCE0.l,a0
e.w(0x10BC, 0x0050)                                 # move.b #$50,(a0)
e.w(0x201F)                                         # move.l (sp)+,d0
e.w(0x205F)                                         # movea.l (sp)+,a0
e.w(0x4E73)                                         # rte

# the critical-section poll loop at the REAL addresses 0x9B4-0x9D8
e.org(0x9B4)
e.label("POLL")
e.w(0x40F9, 0x0016, 0xCCD0)                         # move.w SR,$16CCD0.l
e.w(0x46FC, 0x2500)                                 # move.w #$2500,SR (mask 5)
if SLOW:
    # pre-zerowait regime: masked stretch padded ~200 clks (SDRAM-starved
    # loop) - now the masked window EXCEEDS the ~60-clk authentic pulse
    e.w(0x323C, 0x0012)                             # move.w #18,d1
    e.label("SLOWPAD")
    e.dbra("SLOWPAD")
e.w(0x4A39, 0x0016, 0xCCD6)                         # tst.b $16CCD6.l
e.bne_s("WAKE")
e.w(0x46F9, 0x0016, 0xCCD0)                         # move.w $16CCD0.l,SR (open)
e.bra_s("POLL")
e.label("WAKE")
e.w(0x4239, 0x0016, 0xCCD6)                         # clr.b flag (consume)
e.w(0x5279, 0x0016, 0xF010)                         # addq.w #1,$16F010 WAKES
e.w(0x46F9, 0x0016, 0xCCD0)                         # restore SR (reopen)
e.jmp("POLL")

# POSTFAIL park: the 0xBAC march-band loop the device HUD showed
e.org(0xBAC)
e.w(0x5279, 0x0016, 0xF030)                         # addq.w #1,$16F030 FAILCNT
e.bra_s(0xBAC)
e.commit()

with open(dst, "w") as f:
    for x in words:
        f.write(f"{x:04x}\n")
print(f"wrote {dst} (worldwake image, SLOW={int(SLOW)}; "
      f"extra POLL at {e.labels['POLL']:#x})")
assert e.labels["POLL"] == 0x9B4 or SLOW
