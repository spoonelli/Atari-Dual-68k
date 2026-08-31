# Atari Dual 68k — Development History (v1–v78, builds 101–153, releases v0.1.x)

A field log of bringing Atari's dual-68000 "Escape" hardware (E.P.R.O.M.) to
the Analogue Pocket: what broke, what we measured, and what each era taught.

## Era 1 — Scaffold to first light (v1–v13)
Dual TG68K 68000s, address decode from the SP-332 schematics, BRAM for the
small RAMs, SDRAM for the 2.2MB combined ROM image, APF download path.
Reached "Waiting for Second Processor" early (v13), then lost it for a dozen
builds — the first taste of a lesson that would take 60 more builds to fully
learn: **identical logic did not produce identical hardware behavior.**
- Schematic says 68010; we followed MAME and built TG68K CPU="00" (68000).
  *(Corrected 2026-08-24: there are TWO boards. The dedicated cabinet is a 68010
  (`MC68010P8`, date code `A71R8813`, photographed) and the JAMMA version is a
  68000 — both photographed, both authentic. SP-332 is the dedicated-cabinet
  package, so the schematic and MAME were describing different machines, not
  contradicting each other. Every build through 109 therefore shipped a faithful
  JAMMA machine. The claim that stood here — "real boards carry 68000s
  (photo-verified)" — was still wrong as written: it generalised one board to all
  production, and there was never a photo. See CPU_AND_ARBITER.md §1.6.)*
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

## Era 8 — The freeze, and the atom that wasn't (build 101–102)
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

## Era 9 — Persistence, sprites, and the wrong constant (builds 103–106)
- **103** put EEPROM persistence on the TAS-fix base. It also failed to fit
  (Quartus 170048): two 128x32 buffers inferred M10K against a 308-block
  ceiling that was already full. Fixed with an explicit `ramstyle = "MLAB"`.
  The M10K ceiling is the binding constraint on this part and has shaped every
  decision since.
- **104** took the sprite engine to a 4-channel fetch with a 3-deep prefetch
  queue.
- **105** added the `apply_stain` second pass and special-sprite masking. The
  map marker came back — and the episode that followed is the one worth
  keeping. I first called the residual a hardware failure, then "under-applied
  at 27%". Both were wrong. The owner pointed at 1:23 of the CRT reference,
  where the marker plainly **blinks**; my single-frame readings had been phase-
  mixed across the blink. **A still frame cannot measure a blinking thing**,
  and the 100% coverage target it implied never existed.
- **106** corrected everything derived from a wrong SDRAM clock constant. The
  PSRAM controller was parameterised at **85.909 MHz** while the clock is
  **35.795455 MHz**, so every derived value was wrong at once: wait states, and
  a refresh interval that was **out of JEDEC spec**. One constant, wrong,
  silently poisoning a whole subsystem — and nothing failed loudly enough to
  find it until someone read the parameter.

## Era 10 — Diagnostics that can fail (builds 107–112)
The theme of this era is not a bug; it is the discovery of how many of our
checks could not have failed.
- **107** put stain diagnostics on HUD page 4 "plus gates that can fail" — the
  first build where provoking the check was part of shipping it.
- **108** fixed the two-frame line-buffer ghost, confirmed on hardware.
- **109** was a one-word A/B: `VSHAD3_EN=0`, which fits at **283/308** M10K
  against the shipping branch's **308/308**. 25 blocks, measured rather than
  estimated.
- **110** added 68010 mode. Its lasting contribution was `HOLD-110`: BUILD 110
  and the `cpu-68010` branch are **byte-identical RTL differing only in the
  `BUILD_ID` constant**, and their worst-case hold slack differs by **0.157 ns**.
  The timing gate's 0.050 ns margin floor could not survive that, and was
  raised to 0.150. **On this design a placement perturbation moves hold more
  than most real changes do** — so no hold number may be attributed to the last
  edit without naming the path.
- **111** found that the playfield fetch channel had no reset (the MiSTer
  wedge). `PFSIM-113` then found the PF-CRAM rig **had never passed** — three
  faults in the rig, none in the RTL.
- **112** shipped a 16 KB partial ROM shadow at 0x54000 with a runtime toggle,
  after a correction worth recording: I had advised shadowing
  `0x50000-0x53FFF`, **wrong by 18:1** — three of those four pages are read
  *exactly zero* times. The 16 KB partial measured indistinguishable from the
  full 32 KB shadow at 9 fewer M10K.
- Two more of my own claims were falsified in this era. I reported the desk
  dropouts as playfield; the bench falsified the playfield's own prediction
  **30/30 and 20/20** — they are motion objects. And I claimed "64 blocks of
  M10K waste" when **86% of an M10K's bits are parity** and the design is
  **96.5% efficient**. Both were relayed confidently and neither was measured.

## Era 11 — Toward a release candidate (builds 113–114)
- The SDRAM re-architecture was taken to three branches — clock (50.1 MHz),
  open-row, and banking — and **both levers independently clear the dropout
  knee**: MO latency 21.2 px baseline, 10.1 px on clock alone, 3.7 px with
  open-row plus banking; 11 partial lines to 0 either way. My sequencing advice
  had been backwards: I said open-row before banking, but **banking creates the
  opportunity and open-row cashes it** (all three clients sat in bank 0, so
  every client switch was necessarily a row miss).
- **113** shipped open-row + banking, and fixed the P2 bomb: `.p2_buttons` read
  `cont2_key[8]` (**L1**) where P1 reads `cont1_key[6]` (**X**) and
  `input.json` declares X. A declared-vs-actual mismatch, and the same
  bit-8-is-L1 confusion that produced the original P1 report.
- **114** put the whole diagnostic layer behind a menu toggle (`Developer HUD`,
  default off), so a player never meets it while anyone debugging a report can
  enable it without a toolchain.
- **The packaging guard did not hold.** Staged as `gfxdata.bin`, the real ROM
  **packaged** — byte-identical, past a guard that only knew filenames. There
  are now five guards constraining the *output by content*, each provoked by
  `support/test_package_guards.sh`. Guard 5 pins the platform image by hash,
  because the marquee is under the same rule as ROM data and guards 3 and 4
  both pass it.
- **The fill rate that the SDRAM analysis rested on was never measured.** The
  39% -> 70% figures are estimates; `tb_vfill` was written to replace them with
  a count and could not, because the bench never leaves boot: **1831 of 1831
  fastpath-eligible cycles land in the first 16 KB, across 7 distinct pages in
  480 us**. Not a 0% fill rate — a spin loop. The number remains unmeasured,
  and the case for the rework rests on measured *latency*, not on starvation.

## Era 12 — The schematic's fill rate (builds 115–133)
- The cadence hunt that consumed this era ended by dissolving its own premise.
  The video CPU's 0.973-vs-0.9977 tail was chased through CPU type (68010 loop
  mode: worth **0.0000%**), constants, and shadows — and turned out to be the
  motion-object engine eating the bus. The clock explorations bracketed the
  answer first: **123** took SDRAM to 7× (50.1 MHz) and got *slower* (tRAS
  needs three clocks there); **124** settled on 6× (42.95 MHz) where every
  timing improves at once, and shipped the open-row controller the Pocket
  still runs.
- **125** closed the left-edge strip the owner had already diagnosed in one
  sentence — "is that line just phase shifted from the other side?" It was:
  every layer sat 2 px right of MAME's window (`VID_H_BPORCH` 60→62), so
  columns 0–1 showed the 512-px tilemap wrapping around. Two earlier "fixes"
  had been reasoned from the wrong edge.
- **129** added MOTEL: per-line truncation and worst-fetch-latency counters on
  HUD page 6, video-decodable. For the first time sprite starvation was a
  number in a capture instead of an impression.
- **131** was the era's payoff: the crowd-scene fixture failed even at zero
  latency, which meant *fill rate*, not fetch latency — and SP-332 sheet 9
  had the answer drawn all along: the real board fills a **pair** of line
  buffers, two pixels per DCLK. MOPAIR-131 rebuilt the engine that way
  (crowd fixture 527 missing pixels → 0). **132** removed the residual stall
  (71% of it was every sprite's *second* tile: the MOPF2 prefetch lane) and
  fixed the two accepted cosmetics (ALPHAEQ: the alpha layer led by one
  clock). **133** fenced the one unreproducible field failure — a wedged
  sound 6502 — with a watchdog that self-heals in 0.75 s and freezes the
  first-fault PC for later.
- Era lesson: the emulator hid this class of bug perfectly. MAME has no fill
  rate; the schematic did. When a fixture fails with every latency knob at
  zero, stop tuning and re-read the drawings.

## Era 13 — Release engineering (v0.1.0 / v0.1.1, BUILD_ID 34–36)
- Shipping was its own engineering arc: the core identity renamed to
  `spoonelli.eprom` *before* first release (platform-keyed saves proved on
  device); the marquee blob and 34 MB of committed `output/` purged in one
  history rewrite; 53 branches pruned to three; NOTICE.md written as a
  per-component compliance inventory; five content-based packaging guards
  (each provoked by a test that proves it can fail).
- The docs got the same discipline as the RTL: reference split from
  investigation record, an accuracy sweep against code and measurement, and
  a benchmark section with numbers instead of adjectives — attract cycle
  within 0.35% of MAME, walk cadence exactly 8 frames/phase against four
  real-cabinet captures, crowd slowdown *less* than MAME's.
- **v0.1.0** (BUILD_ID 34→35 after the RC2 metadata round) shipped
  2026-08-29 with `build_rom.py` bundled in the zip; **v0.1.1** (36)
  followed as a metadata patch after the cores inventory displayed the
  file-authoring date as the release date. The lesson now lives next to the
  version bump: `date_release` is the *release* date.
- Stale claims kept surfacing days after their fixes — the left-edge strip
  was still listed as open four builds after 125 closed it. The sweep habit
  ("check the claim against the history, not against another document")
  caught it, and B5/B6-style TODOs fell to five-minute audits.

## Era 14 — The MiSTer arbiter saga (builds 134–153)
- One SDRAM, three hungry clients, and six weeks of lessons compressed into
  twenty builds. **135**: fixed-sprite streaks were the *playfield* starving
  behind CPU vblank bursts — PF takes the top of the arbiter. **136**: bit-soup
  garble was a missing two-edge CDC settle on fetch returns (the Pocket had
  it; the port didn't).
- Then the crowd-dropout campaign, where every intuition failed on hardware:
  **137** ported the Pocket's blanket MO-over-fastpath rule — catastrophic;
  **139/140** rationed it with an age boost — under-served dense lines;
  **143** blanket again with the standoff fixed — *controls died in-game*;
  **145** burst credits — same death; **148** a 2:1 weighted interleave —
  watchdog reboots. The root cause, finally read out of `escape_core`
  rather than theorized: a blocked fastpath has **16 CPU clocks** before
  every ROM fetch degrades to timeout-plus-fallback. Any policy that blocks
  the fastpath for long collapses both 68ks; the Pocket's rule only works
  because on its two-client bus it *produces strict alternation*.
- **146/147** implemented that property directly — a turn bit interleaving
  contested cycles, plus the demand-fetch escape the turn variant needed —
  and the bench grew gates **calibrated on hardware verdicts**: the working
  arbiter measures 4% fastpath timeout-share, the reboot-looping one 27%,
  the fence sits at 10%. No arbiter change reaches Quartus without passing
  the gauntlet that would have caught every prior regression.
- **150** ended the war by refusing to fight it: the Pocket's real advantage
  was topological (playfield on its own PSRAM), so the port rebuilt the
  separation inside one SDRAM — the sprite tiles written twice at download,
  motion objects fetching their own bank's copy. Every metric improved at
  once; worst-case MO latency fell 91%. **151** fixed the download race the
  mirror introduced (the FSM read a live register the next byte could
  clobber). **152/153** were release polish: the owner's button defaults and
  a credits accuracy pass.
- **mister-v0.1.1** shipped 2026-08-30 at measured performance parity with
  the Pocket — identical crowd scroll-velocity distributions, zero slowdown
  dips where MAME dips in 19–28% of samples.

## Era 15 — Going public (2026-08-29 → 31)
- Both platforms released and auto-updating within 48 hours: the Pocket
  listed in the openFPGA cores inventory (pupdate-verified end to end), the
  MiSTer served by a custom update_all database pinned by md5 — later
  unified onto a standard-layout distribution repo
  (`Arcade-Escape_MiSTer`) built for MiSTer-devel submission, which went
  out 2026-08-31.
- The first community interaction arrived within a day of the repo going
  public: a licensing-diligence issue (NOTICE paths that didn't resolve in
  the standalone tree, the missing `sys/` framework credit) — fixed
  same-day. The documentation discipline paid for itself on first contact.
- The remaining open set at submission: rare one-frame sprite-row flickers
  on the heaviest MiSTer scanlines (fetch-cost work queued, bench-first),
  the Pocket's 33-px scroll-position deviation, the unmeasured speech-tail
  claim, and the section-F `DIAG_EN` decision. All enumerated, none hidden.

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
- MAME + schematics + disassembly agree or someone is wrong — the "+5V" pins
  that were really coin inputs were a genuine case of the docs being wrong and
  the measurement being right. The 68010 label was **not**, and it taught a
  better lesson: the schematic said 68010, MAME said 68000, and *both were
  right about different cabinet variants*. Two sources contradicting each other
  can mean you have not identified what each is describing. The actual error
  was writing one board up as "production" — and recording it as
  "photo-verified" when there was no photo.
- Ship one variable per build; bundle only instruments.
- Keep ROMs out of the repo with mechanical guards, not vigilance.
- The emulator's shortcuts (zero-time fetches, instant links) hide the exact
  class of bug an FPGA core must solve.
- **A check that cannot fail is worse than no check**, because it also consumes
  the attention that would have found the problem. This project has recorded
  **sixteen** such instances, and the deepest form arrived late: a
  proof-it-can-fail control is *itself calibrated*, and its calibration goes
  stale exactly like the constant it guards. The SDRAM refresh gate's negative
  controls correctly FAIL at 35.795455 MHz and correctly-looking **PASS** at
  50.11 MHz, because the JEDEC limit in clocks moves 279.7 -> 391.5 — green,
  banner printed, measuring nothing, at the precise moment someone raising the
  clock needs it most. See `LESSONS.md`.
