# Atari Dual 68k — Development History (v1–v78)

A field log of bringing Atari's dual-68000 "Escape" hardware (E.P.R.O.M.) to
the Analogue Pocket: what broke, what we measured, and what each era taught.

## Era 1 — Scaffold to first light (v1–v13)
Dual TG68K 68000s, address decode from the SP-332 schematics, BRAM for the
small RAMs, SDRAM for the 2.2MB combined ROM image, APF download path.
Reached "Waiting for Second Processor" early (v13), then lost it for a dozen
builds — the first taste of a lesson that would take 60 more builds to fully
learn: **identical logic did not produce identical hardware behavior.**
- Schematic says 68010; real boards carry 68000s (photo-verified). TG68K CPU="00".
- v14–v19 per-boot corruption traced to a same-edge arbiter collision: two
  grant gates firing together served sprite pixels as CPU instructions.

## Era 2 — The SDRAM wars (v14–v53)
Every symptom pointed at ROM reads; every fix moved the symptom.
- **v38 forensics**: CPU received a valid word from the *wrong row*
  (PC=1B24 got 0x51C9; truth 0x6800; XOR of addresses = one row bit).
- **v40 black screens**: precharge-all armor on *writes* starved the
  bridge download (no backpressure). Armor became read-only (v41).
- **v44 root cause #1**: `S_PREALL=4'd8` collided with `S_WR2=4'd8` in the
  controller FSM — every download since v40 was corrupted. *Lesson: grep
  your localparams; a Verilog half with no lint gate is a minefield.*
- **v45 root cause #2**: SDRAM chip-clock phase wrong for capture; 180°→90°
  killed the wrong-row serve.
- **v46–v53**: word-1 of the 2-word burst stayed marginal through spread-burst
  and no-auto-precharge experiments. Cure: CPUs consume word-0 only, prefetch
  off. v52 regression taught the process rule: **fetch-path experiments live
  on branches**; v53 restored the proven controller byte-for-byte.
- **v23–v24 scrubber**: continuous full-image re-read vs download checksums —
  the instrument that later exonerated memory content for good. Its first
  lesson: a polite scrubber starves forever behind busy CPUs; give it a
  guaranteed slot.

## Era 3 — Speed is part of the machine (v54–v60)
Game booted further but wedged in self-test; phantom march failures.
- All error-screen digits turned out to be **ROM templates** — the game never
  patches them. Reading screens as data was a dead end; instrument instead.
- Boot flow fully disassembled: self-test → mailbox handshake between CPUs →
  march → soft reboot → attract. Exception vectors all route to a
  die-and-let-watchdog-reboot STOP.
- **v58 root cause #3**: MAME fetches in zero time; the real board fetches in
  ~4 cycles; our SDRAM cost 15–25. The vblank ISR ate whole frames and the
  main loop starved. Fix: 64KB BRAM "hot code" shadows per 68000, filled
  during download, verified by checksum on the HUD (v59: 11E9/8318 exact).
  **Memory speed is architecture, not implementation detail.**
- v60: real erased EEPROMs read 0xFF, not 0x00. Virgin state matters.

## Era 4 — The sound board that never booted (v61–v63)
Coins raced, sound was one blip in an hour, start never fired.
- Built a local MAME lab (Lua taps, watchpoints, unidasm) — ground truth on
  demand. Found the credit counter ($3F7F55), the response protocol (68k
  polls the JSA byte every frame, credits on *change*), and that the JSA
  port coins are **active-high** with a third coin line we'd pinned high.
- The schematic package (SP-332) validated the port bit-for-bit and revealed
  the comm link is a serial SCOM ASIC pair — which MAME models as instant,
  proving instant is fine.
- **v62 probes**: response bytes were all 0xFF with the 6502's PC in zero
  page — the sound CPU was *crashing*. It fetched every opcode from SDRAM;
  the 68ks had shadows, it didn't.
- **v63**: whole 64KB sound ROM into BRAM; JSA off the SDRAM arbiter
  entirely. Fixed the crashes; coins still dead.

## Era 5 — Measurement carousel (v64–v70)
- v64 (video word-0-only) and the arbiter relief didn't change the playfield
  corruption. **v65 scrubber verdict on the HUD: one full 2.2MB sweep, zero
  errors.** Memory content and the read path formally innocent.
- v66 "PF Map Debug" (flat color per tile code): the tilemap the game writes
  is **sane** — corruption was in code→pixels.
- ROM assembly re-audited against MAME's loader: INVERT flag, plane quarters,
  all 16 sprite ROMs in exact order — byte-perfect.
- **v68 root cause #4**: the playfield fetch/show pipeline had **no
  handshake** — any late SDRAM return displayed the previous cell's pixels.
  With the handshake, corruption changed signature (repeat streaks), the
  attract demo ran for the first time, and service mode + on-device ROM
  checksums (matching MAME value-for-value) came alive.
- v69/v70: prefetch 3 cells deep bought margin; dropping the read armor for
  speed brought self-test errors back within one build. Armor restored.

## Era 6 — The sound CPU's stuck boot & the input decode (v71–v75)
- **Root cause #5, found in sim**: 2804 bit D4 (TMS5220 /ready) held constant
  kept the 6502's *boot init* polling forever with interrupts masked — no
  coin scan, no commands, no music, ever. MAME showed the bit toggling; one
  ~1.7kHz toggle unstuck everything. **Coins credited 1:1 on hardware.**
- Runtime prefetch-depth slider sent the fitter into twin 90-minute spirals —
  reverted. Not every knob deserves to be runtime.
- Input probe (raw controller word on the HUD) + user's own decode of 0x01B0:
  face buttons at documented bits, **X alone arrives on bit 8**. One-bit fix;
  a wholesale-shift misread (v73) reverted same day.
- v75: R button cycles all debug modes on-device. Startup now pristine;
  degradation only after minutes of warm-up.

## Era 7 — The foundation, finally (v76–v78)
- **The audit that ended the mystery: the SDRAM interface had *zero* timing
  constraints.** Quartus never analyzed the DQ capture window; every build's
  read margin was placement and temperature luck. First constrained build
  measured the truth: **setup violated by 1.171ns.**
- v76 (constrained, still negative): the violation *moved* — extra CPU read
  zeros, playfield went dark. v77 (unconstrained again): both CPUs failed
  ROM checksums with values changing per boot. Three builds, three failure
  landscapes, identical logic. **Negative slack is placement roulette;
  never ship it.**
- v78: DQ capture in the IO cell (FAST_INPUT_REGISTER) + fixed fitter seed —
  placement-invariant read timing, reproducible builds. The structural exit
  from six weeks of lottery.

## Era 6 — The freeze, and the atom that wasn't (build 101–102)
An intermittent, reboot-only freeze survived eight refuted theories and
roughly twenty builds: address-qualified waitstates, registered read
capture, six different vblank-interrupt schemes, the CDC parity gap, a
mailbox deadlock, and finally shared-bus arbitration. Build 85's flight
recorder ended it: at the build-101 freeze the extra CPU's last 17 bus
cycles decoded, byte-exact against the ROM, as one pass of the inter-CPU
spin-lock acquire at `$9B4`, retrying `tas.b $16CCCC` forever.
- **Root cause: TAS is not atomic in our machine.** TG68K decodes TAS through
  the ordinary MOVE path, writes bit 7 back unconditionally, and has no bus
  lock, so `/AS` is released between the read and the write-back. Our shared
  RAM is true dual-port with zero interlock. One CPU's `clr.b` release landing
  in that gap is overwritten with `$80`: the mutex ends up **set with no
  owner**, and every later acquirer on both CPUs spins forever.
- The real board cannot do this. `/AS` stays asserted across the whole
  read-modify-write (M68000UM Rev 9 §5.1.3), and the shared RAM is two
  *single-ported* SRAMs behind one `/AS`-level ownership mux (SP-332 sheet 5,
  40M/50M via 30M LS158A on EWAI, loser held in waits by 30D/30L). Atomicity
  was a property of the *memory fabric*, not of a lock signal — and replacing
  it with dual-port BRAM deleted it silently. Era-1's lesson again, at the
  hardest possible altitude.
- **Fix (102)**: export the CPU kernel's existing `exec_write_back` as a real
  LOCK output (vendored TG68K, `rtl/tg68kv/`) and let escape_core serialise
  the other port off that exact byte for the duration — write strobe *and*
  DTACK, because the strobes assert on every clock of a stalled cycle by
  design. Bounded by a 64-clock watchdog with a re-arm inhibit, so a stuck
  LOCK costs the peer one window and never another.
- **And the fix carries its own proof**: saturating counters of the cycles the
  interlock actually held off, plus the first colliding address, on HUD page 2.
  Freezes stop with a non-zero count = mechanism confirmed and cured in one
  session. Freezes stop with a zero count = the fix is not what helped.
- Bench: `tb_escape_tasrace` reproduces the swallowed release on the real RTL
  with both real CPUs and fails the run if it did not actually construct the
  race; `tb_escape_taswedge` forces a permanently stuck LOCK and proves
  neither CPU can be starved. Measured (foreign stores landing inside a TAS /
  trials that ended with the lock set and no owner):

  | release | interlock | stores inside a TAS | wedged |
  |---|---|---|---|
  | `clr.b`  | off        | 152 | 114 / 306 |
  | `clr.b`  | on         |   0 |   0 / 305 |
  | `move.b` | off        |  50 |  25 / 202 |
  | `move.b` | DTACK-only |  52 |   0 / 209 |
  | `move.b` | on         |   0 |   0 / 209 |

- **The DTACK-only row is the lesson of the era, repeated.** It wedged nothing
  and would have looked like a pass — but 52 stores still landed mid-TAS. They
  did not wedge only because a DTACK-stalled write strobe keeps re-asserting
  every clock and happened to re-write the byte *after* the TAS write-back,
  clobbering that write-back instead: two owners rather than none. Same defect,
  different corruption, luck deciding which. Test the property, not the
  symptom — a bench judged on freezes would have shipped the broken variant.
- The `tas.b` read-modify-write measures 13 clocks wide here, with `/AS` HIGH
  for 3 of them. That 3-clock gap is the entire bug, as a number.

## The five root causes, in one list
1. FSM state-encoding collision corrupting downloads (v44)
2. SDRAM chip-clock capture phase (v45)
3. Fetch latency starving the game's frame architecture → BRAM shadows (v58)
4. Unhandshaked video fetch/show pipeline (v68)
5. Sound CPU boot spin on a constant status bit (v71/v72)
…all sitting on the true foundation issue: an unconstrained SDRAM interface
(v76–v78).

## Process lessons that outlived any single bug
- Instrument, then fix: every guessed fix cost a build; every probe paid for
  itself in one photo. HUD checksums, edge counters, and the game's own
  self-test became the lab bench.
- MAME + schematics + disassembly agree or someone is wrong — twice the
  "docs" were wrong (68010 label, "+5V" pins that were coin inputs) and the
  measurement was right.
- Ship one variable per build; bundle only instruments.
- Keep ROMs out of the repo with mechanical guards, not vigilance.
- The emulator's shortcuts (zero-time fetches, instant links) hide the exact
  class of bug an FPGA core must solve.
