#!/usr/bin/env python3
"""Build sim/work/tasrace_words.hex - the TAS-RACE image for
tb_escape_tasrace, the reproduction bench for the build-101 freeze
(scratchpad/FREEZE-101-ANALYSIS.md).

WHAT IT REPRODUCES.  Both CPUs take inter-CPU mutexes with `tas.b` over the
shared RAM.  On the real 68000 that works because /AS stays asserted across
the whole read-modify-write (M68000UM Rev 9 s5.1.3 p.53), and the board's
shared RAM is two SINGLE-PORTED SRAMs behind one /AS-level ownership mux
(SP-332 sheet 5).  TG68K releases /AS between the two halves and our shared
RAM is true dual-port, so the other CPU's `clr.b` release can land between
the TAS read and the TAS write-back - and TAS writes bit 7 back
unconditionally (TG68K_ALU.vhd:215).  The release is swallowed, the lock is
left SET WITH NO OWNER, and both CPUs then spin on it forever.

THE TRIAL.  The MAIN (video) CPU plays the lock holder and releaser; the
EXTRA CPU plays the acquirer, spinning in the REAL shape of the ROM's
acquire loop ($9C8 `tas.b $16CCCC` / $9CC `bmi` retry) against the REAL
lock byte:

  main                                  extra
  ----                                  -----
  $16CCCC = $80   (main holds it)       idle, IDLE=1, polling ARM
  ARM = 1                               starts hammering `tas.b $16CCCC`
  ...phase sled...
  clr.b $16CCCC   (THE RELEASE)         should now see $00 and acquire
  wait for DONE, bounded                on acquire: ACQ=1, DONE=1, releases

  ORACLE: after the release the extra MUST get in.  If it does not - if the
  bounded wait times out - the lock byte is set with nobody owning it and
  the extra is spinning on it forever.  That is not a proxy for the freeze;
  it IS the freeze, in miniature.  The main then retries the release until
  the extra gets in (each retry has a fresh chance of landing outside the
  window) so the bench can keep sampling, and counts the trial as a swallow.

Because the extra hammers TAS continuously, the release lands at a
uniformly random phase of the TAS loop; the small sled just adds variety.
Counters are published to shared RAM where the bench snoops them:
  $16E000 trials  $16E002 swallows  $16E004 unrecoverable  $16E006 clean
  $16E008 current phase

Layout matches the other benches: video CPU at image 0x000000, extra CPU at
image 0x080000 (the ROM arbiter adds 0x080000 to extra-side addresses).

Options (env):
  PHASES=n   nop-sled phases (default 8)
  TMO=n      bounded wait iterations before declaring a swallow (default 32)
"""
import os

here = os.path.dirname(os.path.abspath(__file__))
repo = os.path.abspath(os.path.join(here, "..", ".."))
dst = os.path.join(repo, "sim", "work", "tasrace_words.hex")
os.makedirs(os.path.dirname(dst), exist_ok=True)

PHASES  = int(os.environ.get("PHASES", "8"))
TMO     = int(os.environ.get("TMO", "32"))
RETRIES = int(os.environ.get("RETRIES", "12"))

AWIDTH = 19
words = [0] * (1 << AWIDTH)
E = 0x080000                      # extra-CPU image base

LOCKB = 0x16CCCC                  # THE real lock byte (semaphore #6)
ARM   = 0x16C000
ACQ   = 0x16C002
DONE  = 0x16C004
IDLE  = 0x16C006
R_TRI = 0x16E000
R_SWA = 0x16E002
R_STK = 0x16E004
R_AQQ = 0x16E006
R_PHA = 0x16E008


class Asm:
    """Tiny two-pass hand-assembler (same shape as make_worldwake_hex.py)."""
    def __init__(self, base):
        self.base = base
        self.pc = 0
        self.out = {}
        self.labels = {}
        self.fixups = []

    def org(self, addr):
        self.pc = addr

    def label(self, name):
        self.labels[name] = self.pc

    def w(self, *ws):
        for x in ws:
            assert self.pc % 2 == 0
            assert self.pc not in self.out, f"overlap at {self.pc:#x}"
            self.out[self.pc] = x & 0xFFFF
            self.pc += 2

    def _bs(self, op, target):
        self.fixups.append((self.pc, "bs", target)); self.w(op)

    def bra_s(self, t): self._bs(0x6000, t)
    def bne_s(self, t): self._bs(0x6600, t)
    def beq_s(self, t): self._bs(0x6700, t)
    def bmi_s(self, t): self._bs(0x6B00, t)

    def bra_w(self, t):
        self.fixups.append((self.pc, "bw", t)); self.w(0x6000, 0)

    def dbra(self, reg, t):               # 51C8|reg, disp16
        self.fixups.append((self.pc, "db", t)); self.w(0x51C8 | reg, 0)

    def imm32(self, op, target):          # e.g. movea.l #label,a0
        self.fixups.append((self.pc, "i32", target)); self.w(op, 0, 0)

    def resolve(self):
        for at, kind, tgt in self.fixups:
            t = self.labels[tgt] if isinstance(tgt, str) else tgt
            if kind == "bs":
                disp = t - (at + 2)
                assert -128 <= disp <= 127 and disp != 0, \
                    f"short branch out of range at {at:#x} -> {t:#x}"
                self.out[at] |= (disp & 0xFF)
            elif kind in ("bw", "db"):
                disp = t - (at + 2)
                assert -32768 <= disp <= 32767
                self.out[at + 2] = disp & 0xFFFF
            elif kind == "i32":
                self.out[at + 2] = (t >> 16) & 0xFFFF
                self.out[at + 4] = t & 0xFFFF

    def commit(self):
        self.resolve()
        for a, x in self.out.items():
            gi = (self.base + a) // 2
            assert words[gi] == 0, f"image collision at {self.base + a:#x}"
            words[gi] = x


def lw(a):                        # split a 32-bit address into two words
    return ((a >> 16) & 0xFFFF, a & 0xFFFF)


# ---------------------------------------------------------------- video CPU
m = Asm(0)
m.org(0x0); m.w(0x003F, 0x7F00)                       # SSP = $3F7F00 (work RAM)
m.org(0x4); m.w(0x0000, 0x0400)                       # PC  = $400

m.org(0x400)
m.w(0x46FC, 0x2700)                                   # move.w #$2700,sr
m.w(0x4FF9, 0x003F, 0x7F00)                           # lea $3F7F00.l,a7
m.w(0x4282, 0x4283, 0x4284, 0x4285, 0x4286)           # clr.l d2..d6
m.w(0x13FC, 0x0001, 0x0036, 0x0011)                   # move.b #1,$360011 (release extra)
m.w(0x323C, 0x0400)                                   # move.w #1024,d1
m.label("SETTLE")
m.dbra(1, "SETTLE")

m.label("TOP")
m.w(0x4279, *lw(ACQ))                                 # clr.w ACQ
m.w(0x4279, *lw(DONE))                                # clr.w DONE
m.w(0x13FC, 0x0080, *lw(LOCKB))                       # move.b #$80,LOCKB (main holds)
m.w(0x33FC, 0x0001, *lw(ARM))                         # move.w #1,ARM -> extra hammers TAS
m.imm32(0x207C, "SLED")                               # movea.l #SLED,a0
m.w(0x3006)                                           # move.w d6,d0
m.w(0xD040)                                           # add.w  d0,d0
m.w(0x4EF0, 0x0000)                                   # jmp (a0,d0.w)
m.label("SLED")
for _ in range(PHASES):
    m.w(0x4E71)                                       # nop
m.w(0x4239, *lw(LOCKB))                               # clr.b LOCKB  <-- THE RELEASE
m.w(0x323C, TMO)                                      # move.w #TMO,d1
m.label("W1")
m.w(0x4A79, *lw(DONE))                                # tst.w DONE
m.bne_s("FIRSTOK")
m.dbra(1, "W1")
m.bra_s("SWAL")
m.label("FIRSTOK")
m.w(0x5245)                                           # addq.w #1,d5  (clean acquire)
m.bra_s("EVDONE")
m.label("SWAL")
m.w(0x5243)                                           # addq.w #1,d3  *** SWALLOW ***
m.w(0x3E3C, RETRIES)                                  # move.w #RETRIES,d7
m.label("RTRY")
m.w(0x4239, *lw(LOCKB))                               # clr.b LOCKB (retry the release)
m.w(0x323C, TMO)                                      # move.w #TMO,d1
m.label("W2")
m.w(0x4A79, *lw(DONE))                                # tst.w DONE
m.bne_s("EVDONE")
m.dbra(1, "W2")
m.dbra(7, "RTRY")
m.w(0x5244)                                           # addq.w #1,d4  (unrecoverable)
m.label("EVDONE")
m.w(0x4279, *lw(ARM))                                 # clr.w ARM (extra abandons/finishes)
m.label("WIDLE")
m.w(0x4A79, *lw(IDLE))                                # tst.w IDLE
m.beq_s("WIDLE")
m.w(0x4239, *lw(LOCKB))                               # lock is now certainly free
m.w(0x5242)                                           # addq.w #1,d2   (trials)
m.w(0x33C2, *lw(R_TRI))
m.w(0x33C3, *lw(R_SWA))
m.w(0x33C4, *lw(R_STK))
m.w(0x33C5, *lw(R_AQQ))
m.w(0x33C6, *lw(R_PHA))
m.w(0x5246)                                           # addq.w #1,d6
m.w(0x0C46, PHASES)                                   # cmpi.w #PHASES,d6
m.bne_s("NEXT")
m.w(0x4246)                                           # clr.w d6
m.label("NEXT")
m.bra_w("TOP")
m.commit()

# ---------------------------------------------------------------- extra CPU
x = Asm(E)
x.org(0x0); x.w(0x0016, 0xFF00)                       # SSP = $16FF00
x.org(0x4); x.w(0x0000, 0x0400)                       # PC  = $400

x.org(0x400)
x.w(0x46FC, 0x2700)                                   # move.w #$2700,sr
x.w(0x4FF9, 0x0016, 0xFF00)                           # lea $16FF00.l,a7
x.label("ELOOP")
x.w(0x33FC, 0x0001, *lw(IDLE))                        # move.w #1,IDLE
x.label("EP")
x.w(0x4A79, *lw(ARM))                                 # tst.w ARM
x.beq_s("EP")
x.w(0x4279, *lw(IDLE))                                # clr.w IDLE
x.label("SPIN")                                       # --- the real acquire loop ---
x.w(0x4AF9, *lw(LOCKB))                               # tas.b LOCKB
x.bmi_s("SPINCHK")                                    # already held -> retry
x.w(0x33FC, 0x0001, *lw(ACQ))                         # move.w #1,ACQ
x.w(0x33FC, 0x0001, *lw(DONE))                        # move.w #1,DONE
x.w(0x4239, *lw(LOCKB))                               # clr.b LOCKB (extra's own release)
x.bra_s("ELOOP")
x.label("SPINCHK")
x.w(0x4A79, *lw(ARM))                                 # tst.w ARM
x.bne_s("SPIN")                                       # keep hammering while armed
x.bra_s("ELOOP")                                      # main gave up -> abandon
x.commit()

with open(dst, "w") as f:
    for v in words:
        f.write("%04X\n" % v)
print("wrote %s (%d words, %d phases)" % (dst, len(words), PHASES))
