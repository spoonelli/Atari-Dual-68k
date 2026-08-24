# Retrospective: the approaches and experiments that got here

An executive summary of how this core was actually debugged, written for someone who
was not here. It includes the false turns, because the false turns are most of the
value: the record of what a plausible theory cost, and what killed it, is worth more
than the list of things that ended up working.

Every figure below is a measurement or a citation. Where a number is soft, confounded,
or contradicted by another number in the tree, this document says so rather than
picking the flattering one. Where a claim in the existing docs turned out to be false,
it is named. **Nothing here is reconstructed from memory.**

Companion documents: [`PIPELINES.md`](PIPELINES.md) (how it is meant to work),
[`HISTORY.md`](HISTORY.md) (the v1–v78 field log), [`LESSONS.md`](LESSONS.md) (the
reusable methods), [`DEVIATIONS.md`](DEVIATIONS.md) (where we are not the board).

---

## 0. Shape of the effort

Roughly 150 builds, in three unequal parts:

- **Bring-up and the memory fabric (v1–v78).** Three-quarters of all builds. The
  68000s, the 6502, the YM2151 and the TMS5220 were donor cores that mostly worked on
  day one. What did not work was replacing a board with a dozen independent zero-wait
  memories with one SDRAM, one PSRAM and a fully-spent block-RAM budget. Five named
  root causes, all sitting on one foundation issue: **the SDRAM interface had no timing
  constraints at all**, so Quartus never analysed the DQ capture window and every
  build's read margin was placement and temperature luck. The first constrained build
  measured setup violated by **1.171 ns**.
- **The freeze (builds ~85–102).** One bug, about 25 builds, eight refuted theories.
  §2.
- **Correctness and polish (builds 103–109).** The sprite engine, the stain pass, a
  wrong clock constant, and the first honest performance measurements. §§3–9.

The dominant theme across all three is not any particular bug. It is §10.

---

## 1. Two decisions made early that paid for themselves

**Instruments before features.** Progress velocity tracked instrument quality, not
effort. The on-screen forensics HUD meant every device failure became a photograph
rather than a description; first-fault latches that survive reset meant one photo could
name a wedge; continuous checksums separated "written wrong" from "read wrong" from
"content fine" at a glance. The single most valuable was the **bus-trace flight
recorder** (BUILD 85, `da9902d`), which ended the freeze hunt in one reading — see §2.

**MAME as a bus-level instrument, not just a reference.** Lua write-taps and PC-sampling
profilers produced ground truth that reading the driver source never could. Three
project-defining discoveries came from traces rather than code: the speech firmware's
real per-byte WS strobing, the exact one-byte width of the CPU-run latch, and the
gameplay hot-code map that sized the BRAM shadows.

The corresponding trap is stated in `LESSONS.md` and is worth repeating here: **the
emulator's shortcuts hide exactly the class of bug an FPGA core must solve.** MAME
fetches in zero time and delivers the sound link instantly. Both of those became bugs.

---

## 2. The freeze — TAS is not atomic in our machine

**Cost: ~25 builds and eight refuted theories. The dominant bug of the project.**

An intermittent, reboot-only freeze survived address-qualified waitstates, registered
read capture, six different vblank-interrupt schemes, the CDC parity gap, a mailbox
deadlock, and shared-bus arbitration. Every one of those was a plausible theory, and
every one cost a build.

**What ended it** was BUILD 85's bus-trace flight recorder (`da9902d`, `bdadd5b`). At
the build-101 freeze, the world CPU's last 17 bus cycles decoded byte-exact against the
ROM as one pass of the inter-CPU spin-lock acquire at `$9B4`, retrying
`tas.b $16CCCC` forever.

**The mechanism.** TG68K decodes `TAS` through the ordinary MOVE path, writes bit 7
back unconditionally, and has no bus-lock output, so `/AS` is released between the read
and the write-back. Our shared RAM is true dual-port with zero interlock. One CPU's
`clr.b` release landing in that gap is overwritten with `$80`: the mutex ends up **set
with no owner**, and every later acquirer on both CPUs spins forever.

The window, as a number: **the `tas.b` read-modify-write measures 13 clocks wide, with
`/AS` HIGH for 3 of them.** That 3-clock gap is the entire bug.

**Why the real board cannot do this, and why that is the interesting part.** `/AS`
stays asserted across the whole read-modify-write (M68000UM Rev 9 §5.1.3), and the
shared RAM is two *single-ported* SRAMs behind one `/AS`-level ownership mux (SP-332
sheet 5, 40M/50M via 30M LS158A on EWAI, loser held in waits by 30D/30L).

> **Atomicity was a property of the memory fabric, not of a lock signal — and replacing
> that fabric with dual-port BRAM deleted it silently.**

That is Era 1's lesson at the hardest possible altitude: *identical logic did not
produce identical hardware behaviour*. There was no line of code to inspect. The
property was in the substitution.

**The fix** (BUILD 102, `99334c5`) exports the CPU kernel's existing
`exec_write_back` as a real `LOCK` output from a vendored TG68K, and lets `escape_core`
serialise the other port off that exact byte for the duration — **write strobe *and*
DTACK**, because the strobes assert on every clock of a stalled cycle by design.
Bounded by a 64-clock watchdog with a re-arm inhibit, so a stuck LOCK costs the peer one
window and never another. Upstream bug report: TobiFlex/TG68K.C issue #22, open since
2021.

**The evidence** (`tb_escape_tasrace`, which fails the run if it did not actually
construct the race):

| release | interlock | stores landing inside a TAS | wedged |
|---|---|---|---|
| `clr.b` | off | 152 | **114 / 306** |
| `clr.b` | on | 0 | 0 / 305 |
| `move.b` | off | 50 | 25 / 202 |
| `move.b` | **DTACK-only** | **52** | **0 / 209** |
| `move.b` | on | 0 | 0 / 209 |

**114 ownerless locks in 306 trials without it; 0 in 514 trials with it.**

### 2.1 The sub-lesson, which is bigger than the bug

**The DTACK-only row would have shipped.**

It wedged *nothing* in 209 trials. Judged on the symptom — freezes — it is
indistinguishable from the real fix. But **52 stores still landed mid-TAS**. They failed
to wedge only because a DTACK-stalled write strobe keeps re-asserting every clock and
happened to re-write the byte *after* the TAS write-back, clobbering that write-back
instead: **two owners rather than none.** Same defect, different corruption, luck
deciding which.

The rule that falls out — *test the property, not the symptom* — is why
`TASLOCK_EN = 2` is still in the shipped source as a selectable mode marked
"**diagnostic, DO NOT SHIP**". Keeping the counter-example executable is what stops the
lesson decaying into a comment.

**The fix also carries its own proof.** `dbg_tas_cnt` and `dbg_tas_addr` on HUD page 2
are saturating counters of the bus cycles the interlock actually held off, plus the
first colliding address, deliberately *not* cleared on reset so they survive a watchdog
reboot. Freezes stopping with a non-zero count means the mechanism was confirmed and
cured in one session. Freezes stopping with a **zero** count would have meant the fix
was not what helped — and that distinction was made available *before* the flash, not
argued about afterwards.

---

## 3. Sprite engine correctness

### 3.1 The priority comparator: "sprites always in front" → 507,904/507,904

The compositor was a fixed alpha > MO > playfield ladder, so **every** sprite pixel drew
over the playfield: robots walked through counters and desk fronts the real board draws
over them (`8c32e6d`).

The replacement, `escape_prio.v`, carries the GAL equations verbatim from the PCB-verified
set quoted in `reference/eprom.cpp`. Two findings made it cheap:

- **No new plumbing was needed on the playfield side.** `PFX5:PFX4` were already
  `pf_att[1:0]` and `PFX3` already `pf_pix[3]` in the pixel pipeline. The only change to
  `escape_mob.v` was to *latch* `w2[6:4]` instead of naming it in a comment and dropping
  it.
- **The line buffer went 18 → 20 bits, which is the native M10K 512×20 geometry, so the
  M10K delta is zero.** The comparator itself is about 20 LUTs.

`sim/tb/tb_prio.v` sweeps all `2 × 4 × 16 × 16 × 16 × 16 = 524,288` input combinations
against `sim/tools/mo_priority_model.py`, a literal transcription of the reference:

```
rows compared : 507904
agreement     : 507904/507904 = 100.0000%
```

The 16,384 rows not compared are exactly `mo_valid=1 && mo_pix=0` — pen 0 is transparent
and the line buffer cannot produce it. The arithmetic checks out.

The sweep also *proves* the two closed forms the RTL relies on
(`FORCEMC0 == PF/M == !PFX3 && mo_prio < pf_prio`), and therefore that the reference's
"force 3 bits of the MO colour to 0" arm is unreachable — so it is deliberately absent
from the hardware, with the equivalence machine-checked rather than asserted.

On a real dumped frame, scoring the *rule* alone (using MAME's own MO layer, so the
comparator is judged in isolation): **98.49% → 99.39% exact-RGB**. The residual 493
pixels are one sprite the game updates outside the vblank handler, so it is one
animation step ahead in the dump.

### 3.2 Special-sprite masking

Initially MPR2 was resolved at line-buffer *write* time, so a special sprite did not
punch a hole in a normal sprite it overlapped — recorded as a known deviation
(`c4e4b04`) rather than hidden. Implemented at MOSTAIN-1 by *carrying* the flag: a
special pixel is written, owns its column via `bld_occupied`, and never draws. Paid for
by narrowing the tag `ly[8:0] → ly[7:0]`; the entry stays 20 bits and the M10K delta
stays zero.

Measured, with MPR2 injected in MAME because the game only reaches that state on screens
the bench cannot drive to:

| scene | pixels given to the wrong sprite, before → after |
|---|---|
| 126/294, every 3rd entry special | **606 → 0** (exact-RGB 67.78% → 100.00%) |
| 291/128, every 2nd entry special | **244 → 0** (75.26% → 98.38%) |

Cycle split unchanged, so the masking is free.

### 3.3 The traversal rebuild

The measurement that made the problem visible (`e531b79`):

```
pixels 10383  coverage 82.20%   lines complete 0 / 240   <- EVERY active line runs out of time
cycles/line   traverse 212  prime 78  blit 166
```

**18,822 entry visits per 3 frames found only 3,858 that intersect their line** — about
26 entries examined per line for 5 hits, at a flat 8 cycles each. Hardware never pays
this: Escape's PAL16L8 at 70J drives a dedicated `/LINK` memory slot (SP-332 sheet 7),
and US4894774 describes the same lookahead cycle.

Five changes, each measured against the revision immediately before it:

| | change | effect |
|---|---|---|
| MOFETCH-1 | pipelined early-reject: read only `w3` and `w0`, issue the next entry's `w0` speculatively in the same cycle this one lands | traversal **8.0 → 2.6 cycles/entry**; lines complete **0 → 109**; coverage 82.20 → 84.65% |
| MOFETCH-2 | discard the fetch still *in flight* at line abort, not just arrived completions | pairing slips **84 → 0**, spurious 164 → 1 |
| MOFETCH-3 | the **link scout** — a second FSM owning the MO RAM port, walking through `S_PRIME`/`S_BLIT` | coverage 86.36 → **92.18%**, traverse 111 → **69** c/l, ghosts 2 → 0, pen mismatches 6 → 0 |
| MOFETCH-4/5 | reject off-screen tile-rows and whole off-screen objects; widen `fetch_budget` | **990 dead tile-rows/frame → 0** (18% of blit cycles), byte-identical output |
| MOFETCH-7 | defensive `S_NEXT` exit on an idle scout | output unchanged |

Across nine sweep cells: **82.20 → 92.18%, 51.15 → 69.94%, 92.21 → 100.00%,
78.26 → 90.02%, 94.50 → 98.81%, 35.66 → 82.36%.** Lines completed per frame 0 → 111–161.
No new M10K, ~47 flops, no new clock-domain crossing.

MOFETCH-2 is worth dwelling on: pairing slips had *risen* from 19 to 84 when MOFETCH-1
landed. **The optimisation amplified a pre-existing race rather than causing one** — a
distinction that is easy to get wrong under bisect pressure, and which the per-channel
counters made unambiguous.

### 3.4 Placement: the +1 line, and first-write-wins

**The +1 line** (`1352fd1`). Every motion object sat one scanline too high relative to
the playfield, the alpha layer and MAME. The line trigger fires at `x_count == 0` of
raster line `Y` and builds the buffer shown on line `Y+1`, so the row it must carry is
`(Y - vbporch + 1) + yscroll`. The engine used `+2`, while `core_top.v`'s playfield
fetch already used `visible_y + yscroll` with no offset.

The evidence is the kind worth copying: cross-correlate the engine's MO pixels against
the reference model and look at the *offset histogram*. It had a single clean peak at
**(dx=0, dy=+1) holding 9,728 matches against 4,466 at (0,0)**, and nothing else close.
Result: whole-frame exact-RGB **88.72% → 95.57%**, for 11 inserted and 3 deleted lines.

**First-write-wins** (`0f13632`). `eprom`'s MO config sets *render in reverse order*, so
`atarimo` draws the list tail→head and the **head** entry is painted last and wins every
pixel it touches. We must walk head-first, so the equivalent is to refuse to overwrite a
pixel already written this line. The engine was letting the *last* entry win, which put
the wrong sprite on **2,154 of 13,505 MO pixels (16%)**.

The fix cost nothing because of an observation about idle resources: both line buffers
were being read at `disp_x` every cycle although only the *displayed* one is looked at,
so the buffer being **built** had a free read port. Point it at `blit_x` and it becomes
an occupancy probe — still one read and one write per cycle, still a 512×20 simple
dual-port M10K. Result: **95.57% → 96.95%**.

A latent bug was found en route: occupancy must also require `pix != 0`, or an all-zero
never-written M10K location aliases the tag `{fpar=0, ly=0}` and one scanline every
second frame shows phantom pen-0 motion objects.

The placement algorithm is now bit-exact with `atarimo draw()`: running the engine's
rules in Python without a fetch budget reproduces the reference bitmap for the busy
scene exactly — 13,505 pixels, same coordinates, same pens, zero differences. What
remains is starvation, not placement.

### 3.5 The measurement error in this area — and a correction to the brief

The brief for this document described "a measurement error where pixel COUNTS were
compared instead of POSITIONS, producing a false negative". **I could not substantiate
that as stated.** No commit or doc in the tree describes a defect in those terms. Three
real defects are close, and one of them is probably the intended memory; all three are
worth recording, because they are different failures:

**(a) The strongest match — count-equality as correctness evidence (`fb80577`,
MOSTAIN-1).** The entire correctness claim for the new `apply_stain` automaton was
count equality: *"RTL special pixels 296 = the MAME model's 296; stain footprint 320 on
both paths."* Both are counts. The tool that actually diffs the *sets* per line
(`check_stain_automaton.py`) was not written until a day later. **This produced a false
negative**: BUILD 105 shipped on that evidence, and on silicon the pass converted ~34
native pixels where MAME changes ~200. See §6.

**(b) The inverse — a false positive, where counts looked close while positions were
catastrophic (`90f9e0d`, MOPLACE-0).** 15,127 RTL pixels against MAME's 13,505 is a 12%
difference and looks survivable; the positions were **3,386 overlapping coordinates, 17
of them with the same pen, 70.86% whole-frame**. That reading produced "catastrophic
placement failure" — which was itself an artifact of the harness bug in §10.1.

**(c) A count-invariance argument still standing in the docs.** `mo_priority.md` lists
"fetch latency — ruled out" on the grounds that *"`tb_mob` at `GFX_LAT` 8/16/24/31
reports 296 special pixels at every latency"*, and then immediately concedes that the
bench cannot reproduce the shortfall because its gfx model is dedicated and the scene
contains exactly one sprite. Listing it beside genuinely dead hypotheses overstates it.

---

## 4. Sprite throughput: two wins and a clean null result

### 4.1 Four fetch channels (MOCHAN-4, `ed8f700`)

The A/B ping-pong left the engine bound by fetch *concurrency* at the measured
worst-case round trip: per-tile cost `max(8 blit, 31/2) = 15.5`. Four channels make the
steady-state term `max(8, 31/4) = 8` — blit-bound, which is the floor. Four is not a
tuning choice; it is the smallest number that reaches the floor.

Measured: **steady-state stall cycles fall 26–48% at lat31** (50/157: 32,068 → 21,383;
123/253: 18,410 → 9,627).

Two structural improvements came with it, and both are the same lesson:

- **One issue port.** There had been *four* separate fetch issuers — the scout's
  prefetch, the blitter's tile-0 issue, its tile-1 issue, and its steady-state refill —
  each with its own address adder, all four writing `gfx_req`/`gfx_addr`/`infl`, kept
  apart *only by an argument about states*. Collapsing them into one arbitrated
  if/else chain removed three adders and made the mutual exclusion structural. The
  commit cites v14–v19 by name: two grant arms on one clock is last-writer-wins address
  corruption.
- **Packed ports**, so `core_top`'s SDRAM grant tests one registered bit rather than a
  widening OR of per-channel comparators. Combinational depth on the CPU-shared grant
  went **down** at four channels.

Two latent bugs were fixed en route: `tx_f` was 3 bits and wrapped to 0 on an 8-tile
sprite, silently suppressing the next sprite's prefetch; and the prefetch window
compared `tx_f > width_t` across **two different sprites** in the load window.

### 4.2 The 3-deep prefetch queue (MODEPTH-1, `c2bbbb5`)

Four channels fixed the steady-state term but barely moved per-sprite **startup**
(14.22 → 12.54 cycles), which then became 42–54% of all fetch stall. Startup is a pure
*latency*, and channel count does not divide a latency. The only thing that hides it is
asking earlier.

Coverage at the worst-case round trip (lat31, scene 50/157), by queue depth:

| slots | 1 | 2 | 3 | 4, 5, 6 |
|---|---|---|---|---|
| coverage | **82.70%** | 90.50% | **93.51%** | reproduce the 3-slot frame *to the pixel* |

Three is the knee. **This is a measured knob, not a guessed one**, and the flatness past
3 is itself the evidence that the queue is no longer the binding constraint.

Depth needed two structural changes, and the first is the more instructive:

- **A channel free list replacing the fixed rotation.** With one prefetch outstanding a
  rotation is safe. With two, a prefetch for the second queued sprite can land on a
  channel the first queued sprite's later tiles will rotate onto — and since the second
  is consumed after the first, **that is a deadlock, not a stall.** Correctness by
  construction replaced correctness by rotation argument.
- **Harvesting.** A completion holds its channel from issue until somebody consumes it,
  so a prefetch parked two sprites ahead pinned a channel across the whole sprite in
  front of it: two pinned channels left the blitter's pump running at `(31+8)/2 = 19.5`
  cycles a tile instead of `(31+8)/4 = 9.75`. Depth was paying for itself out of the
  steady-state term. Copying the landed row into its slot and handing the channel back
  unhooks channel occupancy from queue depth entirely.

Draw order was proved **three independent ways**, which matters because the FIFO
invariant is the thing that keeps first-write-wins reproducing `eprom`'s reverse render
order: `mob_order_check.py` (all 9 cells prefix-compatible, `b_shorter = 0`; at
lat8/50-157 both engines load the identical 1,692 sprites in identical order),
`mob_vs_mame.py` (**10,047/10,047 = 100.0000%, `wrong_pen = 0`**), and an order FIFO
modelled independently inside the bench (`order_slips = 0`).

A tuning detail worth keeping: yielding the MO RAM port for **two** cycles instead of one
cost **8,140 scout cycles a frame** on the sparse scene and showed up as 82 of 174 lines
reaching *fewer* sprites than the depth-1 engine. Narrowed to the single cycle the
blitter actually needs, the yield costs 352 cycles a frame.

### 4.3 The pump-tile harvest — a measured null result, correctly dropped

**This is the most useful experiment in the sprite work, and it shipped nothing.**

The theory was channel starvation: the blitter's own tile fetches also pin channels
until consumed, so harvesting them into an in-order row buffer should free channels and
raise coverage. MOHARV-1 (`afb9cc6`) built it.

**The mechanism worked exactly as designed** — which is what makes this a refutation
rather than a failed implementation:

- 4,383 tile-rows/frame lifted out of their channel the cycle they landed
- 94% then read from the buffer rather than a channel
- mean channel occupancy 2.00 → 1.80 of 4
- the scout starved of channels **42% less often**: 13,604 → 7,931 cycles
- prime stall 33,682 → 33,181, startup 9,395 → 9,230, +17 sprites and +32 tile-rows

**And it moved coverage not at all, in any of the nine sweep cells** — later extended and
still zero at latencies 8, 16, 31, 40, 48 and 62.

The number that explains why is `primewhy`: of **33,181 stall cycles, 55 are waiting for
a tile that has not been issued and 33,126 are waiting for memory on a fetch that
already went out.** The pump was never channel-starved, so releasing channels sooner had
almost nothing to release.

The instrumentation that settled it (MODIAG-1, bench-only, zero RTL delta) reads, on the
shipping engine:

```
unissued 50   inflight 33,632      -> 99.85% of fetch stall is waiting on memory
tx1 17,153    txN 7,134            -> 71% of steady-state is one sprite's SECOND tile
chan_occupancy 2.00 / 4            -> the pump is not channel-starved
```

Two things about how this was handled are the point:

1. **The theory was disproved by building it**, not by arguing about it. The counters
   came *after* the implementation and explained why the implementation could not have
   helped. That is more expensive than reasoning and vastly more conclusive.
2. **The branch was kept, not deleted.** `mo-harvest` is retained explicitly "so the
   refutation is inspectable". A dropped experiment with its measurements attached is an
   asset; a dropped experiment with only a recollection attached is a theory that will
   come back.

The new `out_of_order` guard was itself **proven able to fail** before being trusted:
substituting the naive issued-test gives `out_of_order = 866`, `pairing_slips = 62`,
coverage 93.51% → 49.23%.

The diagnosis also named the *next* lever rather than leaving a vacuum: issue time —
the scout prefetching tiles 1..n of a still-parked sprite — **and it needs the harvest to
come back with it**, because a prefetched later tile would otherwise pin its channel
from issue to blit. The two belong together, in that order.

---

## 5. The wrong clock constant

**A single number, believed for months, with consequences in two subsystems and no
graphics code anywhere near either.**

`clk_sdram` is `mf_pllbase` `outclk_2` = **35.795455 MHz**, exactly 5 × the 7.159091 MHz
core clock. Six comments in `core_top.v`, one comment in `sdram_simple.v`, one `psram`
parameter and one refresh threshold all assumed **85.909 MHz at 12:1**. The figure was
stale from before "v22: SDRAM 42.95 → 35.8 MHz" and was copied forward when the CRAM
path was born — the PLL already read 35.795455 at that commit, so it was never a
deliberate margin.

**The timing analysis was never wrong.** The SDC uses `derive_pll_clocks`, so Quartus
always knew the real frequency. These are the places the stale number was used as
**data**, where nothing checks it. That distinction is the whole reason this survived:
there was no report to read.

Two consequences (`6596423`, BUILD 106):

**PSRAM wait states ~40% too conservative.** `psram.sv` derives every wait as
`CEIL(min_ns / period)`. Believing the period is 11.64 ns rather than 27.94 ns makes
`CEIL(70/11.641) = 7` cycles for the 70 ns read access where `CEIL(70/27.937) = 3`
suffice — **~279 ns per playfield fetch instead of ~168 ns**, i.e. 4 wasted cycles of
10, exactly 40%. CRAM serves the playfield, so this taxed *every* tile fetch.

**An SDRAM refresh interval genuinely out of JEDEC spec.**

```
250 clk / 35.795455 MHz            = 6.984 us typical
+ the SDSCHED-88 deferral (48 clk) = 8.325 us worst case
MT48LC16M16A2 requirement          = 7.8125 us        ->  6.6% OVER
```

A retention violation on the memory holding sprite graphics and CPU RAM. Corrected to a
threshold of 160: 4.47 µs typical, 5.81 µs worst — 26% under spec — at a cost of 14
refreshes per line instead of 9, raising refresh occupancy from 4.4% to 6.9%.

**The measured cost of that extra refresh traffic was nothing.** BUILD 107's bus-cycle
counts reproduce BUILD 106's to −0.1% on the video CPU and +0.8% on the extra CPU, over
173 cleanly decoded HUD frames. There is no case for reverting it, and doing so would
re-open the violation.

### 5.1 "A large visible graphics improvement with zero graphics code changed" — qualified

This claim is half solid and half soft, and the retrospective should say which half.

**Solid:** BUILD 106 changed **no graphics RTL at all** — the stain path is byte-identical
to BUILD 105. Whatever moved, moved because of memory timing.

**Soft, in four ways:**

1. **The A/B is confounded.** Two constants changed at once — PSRAM wait states and the
   refresh threshold. Nothing isolates which produced the improvement, or whether both
   did. The supportable claim is "memory timing", not "the refresh fix".
2. **Two published magnitudes for the same builds.** `GFX_DASH_ARTIFACT.md` cites stain
   coverage moving **0.3% → 3.2% → 27%** across builds 102/105/106;
   `mo_priority.md`'s blink-phase-matched table gives **0.3% → 5.8% → 61.3%** for the
   same three builds. The denominators differ and neither doc says so. The second is the
   better-controlled measurement and should supersede the first — but the first is what
   the "8.4× from memory timing alone" argument is built on (27/3.2 = 8.4;
   61.3/5.8 = 10.6).
3. **A competing metric moves the other way.** On the horizontal-dash artifact rate,
   BUILD 106 is the *worst* of three builds (9.1e-5, against 4.3e-5 on 107 and 5.0e-5 on
   105). Different playthroughs, so the ordering is suggestive rather than proof — but
   "large graphics improvement" is metric-dependent and should be qualified as *stain
   coverage*, not graphics generally.
4. **The regression evidence in the commit is a null, not an improvement** — "MOB PRIO
   100.0000%, VS-MAME 10047/10047 `wrong_pen=0`" says nothing broke, not that anything
   got better.

**Verdict: the mechanism is proven, the direction is well-supported, the magnitude is
soft, and attribution to a specific one of the two constants is unsupported.**

### 5.2 The constant is still not fully corrected, and has now forked

BUILD 106's commit message claims to "correct everything". It does not:

- `core_constraints.sdc:4-5` still reads "85.909MHz = exactly 12 x 7.159MHz" — in the
  timing file, which is where a reader is most likely to look for the clock
  relationship. The constraint itself is fine; only the justification is wrong.
- `sdram_simple.v:3` still says "28.636 MHz SDRAM domain (4x CPU)", contradicting line
  14 of the same header; `:151-156` still argues from "250-clk = 2.9 µs", 33 lines after
  the block that repudiates both numbers.
- **`sim/tb/tb_pf_cram.v:101` still instantiates `psram #(.CLOCK_SPEED(85.909))`** and
  calls it "the real 12:1 clock ratio". That is not a comment. **That bench exercises
  7-cycle PSRAM waits where the shipped core uses 3 — it models a machine this core is
  not.**

And the refresh fix has forked across three branches: `tas-atomic` uses 160,
`mister-port` uses 224 with the deferral intact, `sdram-sched` keeps 250 and deletes the
deferral instead. `6596423` is not an ancestor of `origin/mister-port`, whose
`sdram_simple.v` still carries `// 85.909 MHz`. REFRESH-107 predicted exactly this drift
in its own commit message; it has already happened.

The one durable defence built here is `sim/tb/tb_psram_timing.v`, which carries
`DECLARED_CLOCK_MHZ` and `ACTUAL_CLOCK_MHZ` as **separate knobs** and runs the DUT at
the actual one — turning "the parameter matches the wiring" from an assumption into a
test case. Its own rationale notes why nothing else could catch it: neither SDC puts a
`set_input_delay`/`set_output_delay` on any `cram_*` pin, so **Quartus never times that
interface at all**, and the full-chip slack number says nothing about it.

---

## 6. The stain pass, and the marker that blinks

### 6.1 A correction to the brief

The brief described "the `apply_stain` second pass, never implemented". **That is
false, and the tree refutes it.** `apply_stain` was implemented in BUILD 105
(MOSTAIN-1, `b3926e7`), extracted verbatim from `core_top.v` into
`src/fpga/core/rtl/escape_stain.v` at GFXDASH-3, is instantiated at
`core_top.v:2534-2540`, and its output reaches the palette index at `:2568-2570` as
`| {stain_now, 10'd0}` — literally `| 0x400`, applied over the finished picture exactly
as the reference's second pass does. Live instrumentation for it exists on HUD page 4.

The stale claim lives in **`mo_placement.md:205-207`**, which still lists "no
`apply_stain` second pass, and a special object does not mask a normal object
underneath it" as known deviations. Both halves were implemented by MOSTAIN-1. That
sentence should be struck.

What was *never* done — and this is the substantive point the brief was probably
reaching for — is **benching it against the shipped RTL**. That is §6.2.

### 6.2 The "100% exact-RGB" that never touched the shipped code

BUILD 105 shipped `apply_stain` on "FACTORY MAP 99.75% → 100.00% exact-RGB". On hardware
the pass fired but covered **~34 native pixels where MAME changes ~200**.

The 100% could never have caught it, for three independent reasons:

1. **`render_scene.py` composites in Python.** The MO/PF merge, the alpha layer and
   `apply_stain` in that script are its own re-implementation. The automaton that ships
   was in `core_top.v` — **a file no testbench compiled, then or now.**
   `run_mob_tb.sh` builds `escape_mob.v` + `escape_prio.v` only.
2. **On that scene both RTL gates were inert.** Re-running the BUILD 105 command
   verbatim:
   ```
   TB_MOB DONE: 0 pixels, 216 gfx reqs, 296 special pixels
   MO-covered pixels in the replayed frame : 0
   agreement with reference model          : 0/0 = 0.0000%
   MO fixture holds no scene - refusing to score
   exact-RGB match vs MAME (new rule): 80640/80640 = 100.00%
   ```
   `MOB PRIO CHECK` printed **no verdict at all and still exited 0**; `mob_vs_mame.py`
   **refused to score**. The only surviving number came from the Python.
3. **The zero was legitimate, which is what made it invisible.** The FACTORY MAP has no
   drawable motion objects. MAME's own model draws 296 pixels there and every one is a
   non-drawing special. The RTL produced exactly 296 specials and 0 drawable — it was
   **right**. A correct engine, a correct scene, and a gate that measured nothing.

> **A legitimate zero is the most dangerous zero.** It cannot be caught by sanity-checking
> the engine, because the engine is behaving correctly. It can only be caught by making
> the gate refuse to certify when it did not actually look.

### 6.3 The marker blinks, and two successive wrong conclusions came from not knowing

**First wrong conclusion: "nothing happened."** The initial read of the BUILD 105 capture
was that the change had no visible effect, and three hypotheses were built on it — an
unwritten palette bank, specials never reaching the line buffer, a pen that is not 11
bits. All three were refuted the moment the frame was diffed against the previous build
*at native resolution* instead of eyeballed: **34 pixels had changed, orange to genuine
grey.** "No visible change" and "under-applied" look identical in a scaled video frame.

**Second wrong conclusion: "the target is 100%."** The marker **blinks, 10 frames on and
10 frames off, and MAME blinks identically.** Measuring the same 32×23 box at the same
grey threshold *in the same blink phase*:

| | grey / lit | share |
|---|---|---|
| MAME phase A (grey hexagon) | 195 / 292 | **66.8%** |
| MAME phase B (coloured cube) | 0 / 292 | 0.0% |
| hardware 102 | 1 / 292 | 0.3% |
| hardware 105 | 17 / 292 | 5.8% |
| hardware 106 | 179 / 292 | **61.3%** |

MAME never stains the whole box — it also contains a neighbouring block and the "START"
text, which are never stained. **66.8% is the ceiling, and BUILD 106 sits at 61.3%: a
residual of ~16–21 pixels, not the 83% shortfall the earlier framing implied.** The
biggest error in that investigation was not a hypothesis about the hardware; it was
**failing to quantify the reference before calling something a shortfall.**

Any single-frame comparison that does not match the blink phase is meaningless: a
phase-B frame should contain *no* grey at all, so grey measured there is excess, not
shortfall.

The residual, once measured properly, is systematic and one-sided — each row's stain
starts 1–2 pixels late and ends on time — which points at a stain/playfield alignment
issue rather than a coverage one. The correct call was made: **do not ship a one-pixel
shift on that evidence**, because the same capture shows gameplay frames matching MAME
at 0 differing pixels, so a global shift would break more than it fixes.

`mo_priority.md` still carries a "Still outstanding" section headed *"Why only ~17%
converts"* placed **after** the analysis that revised the answer to 61.3% of a 66.8%
ceiling. Read top to bottom, the document says the gap is 83% and then that it is ~7%.
That section should be retracted, per the project's own "retract loudly" rule.

---

## 7. The two-frame line-buffer ghost

**The clearest single-mechanism bug in the project, and the one whose diagnosis is most
worth copying.**

The owner reported horizontal artifacts that appear to scroll. What made this tractable
was refusing to reason from the video and instead measuring the artifact's *shape*.

**Establishing it was real, in the core's own output** (`dash_detect.py`, with three
controls):

| corpus | exposures | detections | rate |
|---|---|---|---|
| MAME 0.289, pristine (3,056 frames) | 2,595,892 | 3, all marginal | 1.2e-6 |
| MAME through scaler + JPEG q88 + point-resample | 364,090 | 2 | 5.5e-6 |
| **BUILD 107 capture** (1,857 frames) | 1,468,001 | **63** | **4.3e-5** |

**8× the lossy-pipeline control**, which is what rules out H.264 ringing. Detections were
also far stronger — median 14 dark pixels at autocorrelation 0.743, against MAME's 7–8
at 0.42–0.50, which sit on the threshold.

**Three explanations killed by measurement, not argument:**

- **The Pocket scaler.** Real, measured (period-9 fold contrast 12.3× against 1.17–1.46
  for control periods), and **not this**: the artifact is present in the native decode
  before any scaling, and it moves with world content while the scaler grid is
  screen-locked to within 0.06 rows over 42 frames.
- **Authentic wall artwork.** The real-cabinet video *does* show dark horizontal dashes
  on red walls. It is a filming artifact: on one frame, a **flat single-colour green
  panel** carries the strongest 2-px striping on screen (autocorrelation 0.95), stronger
  than the red wall. That can only be the CRT raster beating with the camera sensor.
- **Corrupt graphics data at rest.** Refuted twice. The band's **left end moves exactly
  −2 px per frame, tracking the measured playfield scroll, while its right end is pinned
  at the last screen column**, so the band *grows* from 39 to 79 pixels as the scene
  scrolls — a corrupt tile does not grow. And in a near-static window the detections
  **alternate with a 2-frame period**: frames 68/70/72 identical, 69/71/73 identical and
  different. Data at rest renders the same every frame; this toggles at 30 Hz.

That signature — one end anchored to world content, the other pinned to the end of the
scanline, toggling with frame parity — names the mechanism exactly.

**The bug.** The line-buffer staleness tag is `{fpar, ly[7:0]}` and **`fpar` is one
bit**, so it separates this frame from last frame and from nothing else. An entry written
**two** frames ago carries this frame's parity, and if nothing rewrote that column in
that buffer since, it reads back live. An earlier fix (LANE4q) had closed the *one*-frame
ghost and left the two-frame ghost, at half the rate and flickering at 30 Hz.

**It costs pixels twice over**, and the second cost is the one that produced the visible
artifact:

- the stale entry **displays** — a sprite in two places at once;
- it satisfies `bld_occupied`, so a live sprite arriving at that column has its write
  **refused by a ghost**. When the refused write is the stain's **END terminator**, the
  automaton never sees it and the stain runs from the marker's world-anchored left edge
  to the last screen column.

The bench reproduces exactly that: case E, frame 3, **`x 265..335` against a reference
that stops at 264.**

The bench also explains *when* a ghost can bite, which is why the artifact is
intermittent rather than constant: a stale entry only survives if nothing rewrites that
column in that buffer in between. A stationary object overwrites its own stale pixels
and is immune. **The hazard is a sprite arriving at a column it did not occupy last
frame** — which is what every moving object in the game does.

**The fix is structural rather than wider.** Widening the tag was not available: the
entry is 20 bits, exactly the native 512×20 M10K geometry, and a 21st bit doubles both
line buffers against a fully-spent 308-block ceiling. So the display side **self-clears
on readout** — which is what the real MOHLB does, and what an existing comment in the
same file had already said it does. While a buffer is displayed its write port is idle,
so writing zero there costs no port, no block and no cycle; an all-zero entry is
unrepresentable as a hit because the blitter only ever writes non-zero pens. Buffers
alternate every line, so each is cleared during the line immediately before it is built.

> **Every build now starts from an empty buffer, and staleness is impossible by
> construction rather than by an argument about tag width.**

**Evidence, and its limits:** `run_stain_tb.sh` 226 mismatching pixels → **0**;
`run_mob_tb.sh` 10047/10047; `run_prio_tb.sh` 507904/507904; CI fit M10K **308/308**
with block-memory bits byte-identical to BUILD 107, so the M10K delta is **measured, not
argued**; CI timing all 64 clock/corner rows non-negative.

> **One claim to correct.** The brief described this as "confirmed fixed on hardware in
> BUILD 108". **It is not.** `DEVIATIONS.md` §B2 marks it "Fixed", and BUILD 108 is the
> bitstream containing the fix, but the evidence on record is simulation and CI. The
> GFXDASH-3 commit says so itself: *"What still needs the owner's hardware. Whether this
> is the whole of the artifact they see."* The mechanism reproduces the measured
> signature exactly, which is strong — but "reproduces the signature" is not "is the only
> cause of it", and no post-BUILD-108 hardware capture has been scored with
> `dash_detect.py`. **That measurement is the cheapest open item in the project.**

---

## 8. Performance, and the phantom everyone was optimising

### 8.1 The original's own cadence

The question was whether the original slows down in busy areas. A fixed-raster board
cannot drop a video frame — the raster free-runs at 59.9227 Hz — so what it does under
load is **miss its logic deadline**. The unit that matters is therefore *logic updates
per video frame*, and it has to come off the game's code, not the picture.

Both CPUs announce their own logic frame in shared RAM: a `$50` byte write to `$16CCD4`
(video) or `$16CCD6` (world) starts one, `$00` ends it. Tapping those two writes gives
the cadence *and* the duration of every logic frame, with no ROM patching.

10 minutes of scripted level-1 play, 35,953 video frames per run, MAME 0.289:

| | 1 player | 2 players |
|---|---|---|
| **world CPU updates/frame** | **0.9999** | 0.9989 |
| world logic frame, mean | 8,014 µs = **48.0%** of budget | 8,859 µs = 53.1% |
| **video CPU updates/frame** | **0.9977** | 0.9758 |
| video logic frame, mean | 10,298 µs = **61.7%** of budget | 11,193 µs = 67.1% |

**The world engine — which everyone had been optimising — uses about half its frame and
misses 2 deadlines in 35,953.** The video CPU is the tighter of the two and the one that
actually drops frames. The world-engine "gap" was a phantom.

Two further results that closed off a whole class of theory:

- **Crowding is not what costs the CPUs.** Correlation between logic-frame duration and
  on-screen sprite tiles is **+0.07** for the world CPU and **−0.03** for the video CPU.
  The frames the video CPU missed carry a mean sprite load of 421 tiles against 427 for
  all frames — statistically the same picture. What moves the cost is *which part of the
  game is running*, and the number of players.
- **The metric was proved able to see slowdown before it was believed.**
  `PERF_INJECT=N` retargets one `JSR` inside the logic frame through a stub that burns a
  **known** number of 68000 cycles, installed after the ROM self-test so the checksum
  test still sees unmodified ROM. The metric runs the whole range from 1.0000 down to
  the 0.5000 floor and reproduces the measured cadence from the measured duration
  distribution to four decimal places on the world CPU, with **zero free parameters**.

Two tooling bugs were found and fixed *while* doing this, both of which had produced
confident wrong numbers first: splitting a straddling body's busy time across the frame
boundary overwrote the body's start timestamp, silently **capping every measured
duration at one frame** — so bodies that overran looked like bodies that just fitted;
and the warm-up branch cleared some accumulators and not others, so the first CSV row
carried 40 s of counts and produced a nonsense "1.9 video logic frames per video frame".

### 8.2 Our own cadence, and the tail

Bus cycles per frame is a proxy — TG68K and Musashi need not issue identical prefetches,
and a slower CPU shifts its own mix of work and idle-spin, which have different bus
densities. The docs are explicit that the ratios are ±5 points. What ended the argument
was building the meter the game's own flags support: **HUD page 5 counts those `$50`
writes over 256 video frames**, in the same units the arcade board is quoted in, with no
assumption about clocks, bus cycles or wait states anywhere in it.

Decoded from the BUILD 108 capture, 100 samples across 143 s:

| | median | p10 | min | MAME |
|---|---|---|---|---|
| video updates/frame | **0.973** | **0.703** | **0.313** | 0.9977 |
| world updates/frame | 0.984 | 0.883 | 0.781 | 0.9999 |

**The median is nearly right. The whole gap is in the tail** — and the tail is the
sluggishness reported in crowds. The decode carries its own cross-check: fields 1 and 2
update only every 256 frames and are constant across consecutive frames, while field 3
changes every frame and reads median 22,102 — reproducing the 22,203 bus cycles/frame
measured by a completely different route.

And the low windows **do not** coincide with sprite crowding: correlation +0.07, with
the busiest quartile scoring better than the second. The same conclusion the original
gives about itself.

That is what BUILD 109 is: an A/B that removes `vshad3` so 32 KB of the video CPU's
hottest code takes the 4-clock fastpath instead of the 5-clock shadow. Measured on the
shipped `escape_core`, 5.015 → 4.015 clocks per bus cycle. Predicted effect on the video
logic body's p99.9: **99.3% → 92.6%** of the deadline, i.e. the tail moves from the edge
to a margin. It also frees 25 M10K blocks (308 → 283), measured.

**The risk that could not be measured offline is stated rather than glossed:**
un-shadowing takes the video CPU from issuing fills on ~39% of its bus cycles to ~70%,
and MO is the lowest-priority SDRAM client, so if the extra fill traffic pushes
effective fill latency past one core clock the change is neutral at best and negative
past two — and the cost would land on the graphics path. `core_top.v`'s own budget for
"both CPUs streaming fetches" is an **estimate, not a measurement**. That is precisely
why it is an A/B build and not a merge.

### 8.3 What the captures can and cannot support

Worth recording because it saved several rounds of argument:

- **Frame-differencing the picture cannot bear a cadence claim.** Control experiment:
  two MAME sequences of the same scene, one at exactly 1.0000 world updates/frame and
  one at exactly 0.5000, give **14% pixel-identical frame pairs for the *fast* one and
  0% for the slow one.** The video CPU keeps animating even when the world CPU has
  missed, and many frames genuinely have nothing moving. Large false-positive *and*
  false-negative rate.
- **The real-cabinet phone video can support nothing quantitative at all.** Sampling a
  59.92 Hz CRT at 29.999 fps sits exactly at Nyquist for the distinction being attempted,
  the beat is 0.04 Hz, and the frames carry rolling-shutter bands, glare and perspective.
  It confirms the cabinet exists and is running level 1. That is all it can say.

### 8.4 The sprite "blocks that did not write" — not reproduced

A reported artifact — sprite blocks rendering black — was chased with three independent
detectors and **did not reproduce**:

| detector | v108 result |
|---|---|
| enclosed-black components inside sprites | **0**, against MAME's **11** |
| enclosed floor-coloured holes (blanked tile) | 18.0 per 1000 sprite px vs v107's 18.4, v106's 18.2 — indistinguishable |
| stipple / isolated dark pixels | 2.5× MAME, and **explicitly disowned** |

MAME — the reference — has eleven such blobs, which are legitimate artwork. BUILD 108 has
none. The original sighting is attributed to a 7× nearest-neighbour magnification of an
H.264 frame making a legitimately dark-shaded region of a robot look like a failure.

The floor-hole detector is the best-controlled instrument in the project: **measured
sensitivity 35.5%** (600 synthetic 8×8 blanks injected, 213 recovered), positive control
7/7, negative control 0 false positives over 60 pure-floor regions. Its zero in-robot
detections over 400 frames give a **Poisson 95% upper bound of <0.021 fully-blanked
floor-revealing tiles per frame**. A per-scanline budget running out would also put a
hard plateau in the per-scanline sprite pixel count; there is none (p50 17, p90 37, p99
63, max 78 over 23,551 scanlines).

The stipple detector was **published with its own disownment**, which is the right call:
MAME's own baseline is 68 per 1000 rather than ~0, the corpora are different
playthroughs, and MAME is pristine while ours is H.264 — and a 2-px checkerboard is the
highest-frequency pattern on screen, which compression attacks. Its positive control
does fire (0 → 107 patches on an injected checkerboard), so it is not blind; it is just
not clean enough to carry a claim.

**The honest residual** is stated in `DEVIATIONS.md` D3: *a sprite fetching
wrong-but-plausibly-coloured data cannot be caught by any statistical shape test.* Three
detectors returning null is evidence about the shapes they can see, and the detectors'
excluded HUD rows are 38.8% of the frame. Closing this needs a scene dump of the exact
failing moment, not a better statistic.

---

## 9. The MiSTer port

Two results, one a bug of a class worth memorising and one a measurement worth copying.

**The playfield wedge.** BUILD 105 ran on a real DE10-Nano: it boots, plays, and renders
motion objects and alphanumerics correctly — and drew a **completely flat playfield**.

The mechanism is four steps, and only the third is unusual:

1. `x_count`/`y_count` and the PF pipeline free-run from power-on, not gated by
   `core_reset_n`. During the ~2.2 MB download the pipeline reaches active video and
   issues a fetch on channel A then B, setting `inflA` and `inflB`.
2. The arbiter cannot serve them: its video tier lives inside `chk_state == 4'd10`, and
   `chk_state` is pinned at 0 for the whole download.
3. The reset resync runs every clock reset is low and does `vg_req_last <= vg_req_s` —
   **retiring those two pending edges without ever completing them.** Correct for motion
   objects, which zero their own toggles under reset. Fatal for the playfield, which had
   **no reset at all**.
4. Release happens with both `infl` bits set and the toggles equal. The issue side
   requires `!inflA`/`!inflB`, so neither channel ever toggles again — wedged for the
   session, every tile decoding to pixel index 0.

The Pocket does not show it because its CRAM service arm is not gated by the same reset.
**A toggle-handshake channel with no reset is a latent wedge on every platform**; it
surfaced only where the reset sequence differed. This is precisely the lesson MOFETCH-2
had already taught inside `escape_mob.v` — *retire pending edges by completing them, not
by forgetting them* — arriving a second time in a different module.

A second bug of the same class was fixed alongside: the download teardown dropped
`sd_rd_req` but left the owner flags set, and every grant arm requires all owner flags
clear — so any `ioctl_download` landing while a read was outstanding, *i.e. every `.mra`
load after the first*, wedged the entire read arbiter.

Verification (`sim/run_mister_pf_tb.sh`, wired into CI ahead of Quartus):

| case | granted / completed per frame |
|---|---|
| BUILD 105 as flashed | **0 / 0**, `inflA=1 inflB=1` |
| with PFRESET-107 | **13,794 / 13,794** |
| 2nd `.mra` load, owner-clear reverted | **0 / 0**, `pf_owner` stuck |
| 2nd `.mra` load, fixed | **13,794 / 13,794** |

13,794 is exactly 57 cells × 242 lines — the pipeline's full enqueue rate, **not a
threshold tuned to pass**. The bench also synchronises to `pf_owner == 1` before
asserting `ioctl_download`, because an unsynchronised version passes by luck two runs in
three. And its own limitation is declared: the machine is a stub and the SDRAM
behavioural, so it proves the channel is alive, which is what was broken.

**Killing the bandwidth hypothesis by measurement.** The obvious first theory for a flat
playfield on a platform with one SDRAM instead of two memories is bandwidth starvation.
The discriminator was chosen from the *mechanism* before the data was cut: **bandwidth
starvation degrades with load; a dead client does not.**

Five fixed background patches, 22 frames of a 77.9 s capture:

| | background patch, median | scene complexity across the run |
|---|---|---|
| MiSTer BUILD 105 | **1 distinct colour**, σ 14.9 | 22,115 → 87,227 distinct colours (**3.9×**) |
| Pocket BUILD 106 | 1,241 distinct colours, σ 51.3 | 22,727 → 119,073 (5.2×) |

**The background held exactly one colour while scene complexity swung 3.9×.** Two
corroborators narrowed it to one signal: the stairs appeared as a correctly-shaped black
silhouette — tilemap and colour attributes right, tile *pixels* constant at index 0 —
and motion objects read the **same repacked region at the same byte addresses** while
being pixel-perfect, which clears the ROM image, the `.mra` and the repack in one stroke.

The tooling is fifteen lines of PIL. That is the point: the value was in choosing a
discriminator the mechanism predicts, not in the instrument.

**Current state, stated honestly:** the fixed build has not itself been flashed.
Everything post-PFRESET-107 is CI-green and simulation-green only. EEPROM persistence is
deliberately not wired on MiSTer, there is no `eprom2` MRA, and `sdram_simple`'s
`rd_pre = 0` playfield arm has **never executed on any hardware on either platform** —
it now runs ~13,800 times a frame, with a one-line revert documented if the playfield
comes back speckled.

---

## 10. The through-line: measurement integrity

**This is the most important section of this document.**

This project was burned **at least eleven times** — the project's own running count
reached "the ninth recorded instance" partway through, and has grown since — not by bad
theories but by **tooling that manufactured confidence**. Every entry below is a case
where a check reported success while measuring nothing, or measured the wrong thing
with full precision.

They are catalogued concretely because the general form of the lesson is useless. What
is useful is recognising the specific shapes.

### The catalogue

**1. A slack-check regex that could never match.** The MiSTer gate grepped for
`'^; *-[0-9]'`, but slack sits in the **second** column of the summary tables. The
pattern matched nothing, so the gate passed vacuously and **published a bitstream
carrying −5.538 ns setup and −10.922 ns hold** on the 35.8 MHz SDRAM domain. (Root cause
of the violation itself: a `set_multicycle_path -setup -end 2` copied from a reference
core with no matching hold multicycle, which demanded read data still be in flight
27.9 ns after launch. Fixed: setup −5.538 → **+15.133 ns**, hold −10.922 → **+0.253 ns**.)

**2. Its replacement examined only the first timing corner.** The rewrite used
`re.search` for each table name. Multi-corner Quartus emits **one table per corner**, so
a design failing at any corner but the first would have passed silently. Fixed with
`finditer`.

**3. A `0/0` result reported as a PASS.** `check_mob_prio.py` saw zero MO-covered pixels,
printed **no verdict at all**, and returned 0. `total == 0` is now an explicit
**VACUOUS failure**.

**4. A Python compositor standing in for RTL.** `render_scene.py` implements the MO/PF
merge, the alpha layer and `apply_stain` itself. `core_top.v`, where the shipped
automaton lived, **was in no testbench**. A "100% exact-RGB" number could only ever have
exonerated the model. Every exact-RGB line in that tool now states this on its face.

**5. A stain gate whose fixture contained zero special pixels.** `run_mob_tb.sh` passed
100.0000% with `wrong_pen=0` while its fixture reported `0 special pixels` and
`SHADE pixels=0`. **The only gate that could have caught a stain bug had no stain in its
scene.** Closed by `make_stain_scene.py`, which builds markers whose START/END bits and
screen extents are *chosen, not discovered*.

**6. An oracle derived from the engine it was testing.** `mob_golden.py` had drifted:
still last-write-wins after the engine became first-write-wins, still `+1` on `ly` after
that offset was removed. On the **unchanged** engine it invented **~52 points of phantom
starvation** (39.73% → 92.22%, 49.03% → 100.00%, 39.93% → 98.62% once corrected). And
structurally it can never catch a *reorder* at all, which is why `mob_vs_mame.py` and
`mob_order_check.py` had to exist as independent oracles.

**7. Benches that fail by construction.** `tb_escape_handshake` reports HANDSHAKE
INCOMPLETE at its default budget **on every branch**, because its check process loops a
hard-coded 500,000 clocks and **ignores the `--stop-time` argument**. Anyone bisecting a
boot problem sees it guilty on both sides of the bisect. Documented in `sim/README.md`
under its own heading rather than left as folklore.

**8. Benches that delivered zero interrupts while reporting an IRQ matrix green.** The
vecrace image's main CPU parked in `bra.s *` and never released the extra CPU, so from
one build onward the bench delivered **`iack_cyc 0`**. **Every "IRQ matrix green" from
builds 88 through 91 was vacuous on IRQ semantics** — four builds of experimental data,
and three plausible fixes reached hardware and died there. A second hole in the same
bench: its synthetic ISR self-acked, which the real ROM handler does not do, so every
per-CPU-latch design looked stormproof.

**9. `iverilog` silently ignoring a non-hierarchical `-P`.** `run_mob_tb.sh` passed
scroll as `-PXSCROLL=224`. iverilog's `-P` takes a **hierarchical** name
(`-Ptb_mob.XSCROLL=224`); the bare form is accepted and then **ignored without a
warning**. The bench ran at its compiled-in defaults 123/253 while the output was diffed
against a frame scrolled to 224/421. **Every MO placement number taken before this was
comparing two different frames.** Re-measured correctly, the *unchanged* engine scored
88.72% rather than 70.86%. The runner now builds the hierarchical form and **hard-errors
on the bare spelling**, and the bench prints the scroll it was built with.

**10. Single-frame measurement of a blinking element, twice.** §6.3. First it produced
"nothing happened" and three hypotheses built on it; then it produced a 100% target when
the reference's own ceiling is 66.8%.

**11. Detectors repeatedly rediscovering the core's own debug HUD.** A naive
"non-background pixel" scan returned 1,496 stray pixels that were the game's own
"Tap JUMP to speed up" banner. The doc records the sequence: alpha-layer text is *the
third thing* such a detector rediscovers, after the core's hex debug bar and its status
line. HUD rows must be excluded with margin — status 0–11, hex bar 96–128, game HUD
192–239 — which is **38.8% of the frame** that every such detector is blind to.

### And more, since the count of eleven was reached

- **A detector that could not fire at all on the backgrounds it was pointed at.** The
  first `dash_detect.py` used an *absolute* contrast floor demanding "darker than −5", so
  it scored a perfectly clean negative control on dark backgrounds while being incapable
  of a detection. Its **positive control** caught it. That tool now refuses to print a
  rate if the positive control fails.
- **A HUD read by eye.** A photographed page-5 value transcribed as `0007 0008` actually
  read `00D7 00C8`. At a 4×-scaled 4×6 font, `0` and `D` differ in one column of two
  rows, and so do `0` and `C`. **0.027 instead of 0.840 turns a healthy diagnostic into
  an alarming one, and then the diagnostic gets blamed.** Replaced by
  `read_hud_native.py`, which template-matches each font pixel's middle 2×2.
- **A bench modelling the wrong machine, still live today.** `tb_pf_cram.v` instantiates
  the PSRAM controller at `CLOCK_SPEED(85.909)` and calls it "the real 12:1 clock ratio"
  (§5.2).
- **A per-line cycle statistic inflated ~9%.** `tb_mob_perf.v` divides frame totals by
  240 while accumulating over all 262 lines, so the published `cycles/line` splits sum to
  ~496, not the 456 the runner scripts label them with. The error is common-mode, so
  every *relative* comparison in §§3–4 stands — but absolute statements like "212 of the
  456 cycles in a scanline go to walking the list" overstate the fraction (212/498 =
  42.6%, not 46.5%).
- **`$readmemh` failure is not an error in iverilog.** A cleanup script wiping fixture
  files produced hours of phantom results. Fixtures now live outside any cleaned
  directory.
- **A Verilog sized-literal comparison that was constant-false.** `slot < 4'd16`
  truncates 16 to 0. Lint would have caught it.
- **An FSM state-encoding collision.** `S_PREALL = 4'd8` collided with `S_WR2 = 4'd8` in
  the SDRAM controller, corrupting **every** ROM download for four builds before anyone
  noticed. *Grep your localparams.*
- **`str.replace` in a patch script replacing every occurrence.** Adding a report path to
  the CI artifact list also rewrote an identically-indented path inside another
  command's argument line, splitting its two arguments across lines and **breaking
  bitstream publication** — in the very commit whose purpose was "a check proven able to
  fail".
- **A resource number argued rather than measured.** One M10K delta was recorded as
  *argued, not measured*, because Quartus under x86 emulation would not finish either
  tree. The doc says so explicitly rather than quoting an expected zero. That is the
  correct behaviour and is listed here as an example, not a failure.

### The rules that fall out

These are now enforced mechanically in the checks themselves, not by remembering:

> **1. Prove a check can fail before trusting it.** Run it against a known-bad input and
> confirm it fails, *naming the right row*. `run_stain_tb.sh` was verified to report 226
> mismatching pixels on BUILD 107 RTL before it was believed at 0. The cadence meter's
> bench counts exactly 137 of the target write against 41 each of three decoys — same
> address with wrong data, the world flag written by the wrong CPU, the odd byte of the
> same word — and was verified to fail when the expectation is moved by one. The
> `out_of_order` guard was proven to fire (866 violations) before being trusted at zero.
>
> **2. Make it refuse to certify when it did not actually look.** Missing input, zero
> parsed rows, an empty fixture, a `total == 0` — all are **failures**, not clean bills
> of health. `check_slack.py` has two separate refusal paths before it ever gets to the
> question of whether slack is negative.
>
> **3. Have it print what it measured.** *"All 64 analysed clock/corner rows have
> non-negative slack"* is verifiable. **"PASS" is not distinguishable from matching
> nothing.**
>
> **4. Never let an oracle be derived from the thing under test.** A rig that
> re-implements the thing it validates can only ever exonerate itself. Where a derived
> model is genuinely useful — `mob_golden.py` measures *time starvation*, which nothing
> else can — it must be paired with an independent oracle that can catch what it
> structurally cannot.
>
> **5. Design every counter so its zero is falsifiable.** The stain HUD field reports
> first and last stained scanline as one value, with `ln_first` resetting to `FF` and
> `ln_last` to `00`. A live counter that stained nothing therefore reads `FF00`, and
> **`0000` is unreachable unless the counter never ran**. The page cannot report a zero
> it has not earned.
>
> **6. Policy enforced by attention fails silently the first time attention lapses.**
> "Never ship negative slack" was a human remembering to grep the compile log — checking
> 8 numbers where the report carries 64. The Pocket build had no timing gate at all
> until BUILD 106+.
>
> **7. Diff against the previous build at native resolution before theorising about a
> symptom.** "I looked at it" is not a measurement.
>
> **8. Quantify the reference before calling something a shortfall.** The single largest
> error in the stain investigation was assuming the target was 100% when MAME's own
> ceiling was 66.8%.
>
> **9. Keep refutations inspectable.** `mo-harvest` is retained so a dead theory stays
> dead; `TASLOCK_EN=2` ships as a selectable broken mode so the counter-example remains
> executable. A theory that was disproved and then deleted comes back.

---

## 11. What is still open, and what "alpha" means

### Open, measured, not closed — `DEVIATIONS.md` §D

| # | Gap | Measured |
|---|---|---|
| D1 | **Video-CPU cadence tail** | median 0.973 vs MAME 0.9977; **p10 0.703, min 0.313**. The median is nearly right; the whole gap is in the tail, and it is the perceived sluggishness in crowds. BUILD 109 is the A/B against it, and its own downside risk is unmeasurable offline. |
| D2 | World-CPU cadence | 0.984 vs 0.9999. Near-authentic; the original uses 48% of its budget, so this is not worth chasing. |
| D3 | Sprite "blocks that did not write" | **Not reproduced by three independent detectors.** Enclosed-black 0 ours vs 11 MAME. Needs a scene dump of the exact failing moment; no statistical shape test can reach it. |
| D4 | 33-pixel deviation vs MAME at scroll 50/157 | Identical on builds 105/106/107 — pre-existing, not a regression. Likely an un-wrapped `spr_right` in off-screen rejection. |
| D5 | Hold-slack margin | +0.005 ns on the playfield fetch ring. Placement perturbation, not logic: **changing `BUILD_ID` alone moved it 0.088 ns.** Wants a hold multicycle. |

### Open items this retrospective adds

- **The BUILD 108 ghost fix has never been scored on hardware.** Simulation and CI only.
  Running `dash_detect.py` over a post-108 capture is the cheapest open item in the
  project and would close or reopen §7 in an afternoon.
- **Stain coverage on silicon is 61.3% against a 66.8% ceiling**, and the residual — each
  row starting 1–2 pixels late and ending on time — reproduces in no bench. The
  compositor in `core_top.v` remains uncovered by any testbench.
- **`tb_pf_cram.v` models the wrong clock** and should be corrected before any playfield
  or CRAM timing conclusion is drawn from it.
- **The refresh constant has forked three ways** across `tas-atomic` (160),
  `mister-port` (224) and `sdram-sched` (250, deferral deleted). All three are in spec;
  they should be reconciled deliberately rather than merged by accident.
- **The MiSTer port's fixed build has not been flashed.** Its `rd_pre = 0` playfield arm
  has never executed on any hardware on either platform.
- **YM CT1 gating of the speech volume is deliberately unapplied** pending a polarity
  check on hardware, so `JSA.md`'s gain law and the RTL differ on purpose.
- Several documents carry claims this work found to be false; they are listed at the end
  of this section and should be corrected at the source rather than only here.

### What "alpha" means for this core

It means the game is **playable and behaviourally accurate, with authentic timing
anchors — and is not cycle-exact**, and the difference is measured rather than asserted:

**What is established:**

- Clock frequencies, raster geometry and refresh rate are the board's own
  (7.159091 MHz, 456×262, 59.9227 Hz — exact), all derived from the 14.318 MHz
  colourburst family.
- The complete memory map, register and latch semantics, transcribed from schematic
  sheet 16 and cross-checked against MAME.
- Genuinely concurrent dual CPUs, which is the real board's architecture — MAME
  time-slices.
- The MO/PF priority comparator matches the reference's own equations
  **507,904 / 507,904**.
- The motion-object renderer matches MAME's tail-first `atarimo draw()`
  **10,047 / 10,047**, `wrong_pen = 0`, with draw order prefix-compatible in all nine
  latency/scene cells.
- ROM contents CRC-verified 28/28 against MAME known-good.
- Read-modify-write atomicity restored and proved: **0 ownerless locks in 514 trials.**

**What is approximate, and by how much:**

- **Per-instruction cycle counts.** TG68K is instruction-accurate, not cycle-exact.
- **Bus-cycle timing.** The original used zero-wait parallel EPROM buses per subsystem;
  this core splits memory across SDRAM, one PSRAM and BRAM shadows. The measured result
  is a video CPU at ~0.87 and a world CPU at ~0.92 of MAME's bus rate, and a cadence
  median of 0.973 against 0.9977 — with a tail reaching 0.313.
- **Video internals.** Same VRAM in, same pixels out, same raster grid — but the scanout
  is a re-architected line engine, not a gate-level MOHLB clone.
- **Output scaling.** A non-integer 240→1080 scale draws every 1-pixel horizontal feature
  4 or 5 pixels thick. No RTL change can alter it.

Escape's game logic is IRQ- and frame-driven rather than cycle-counted, which is why
gameplay behaviour is close despite the bus-timing gap — and it is also why the cadence
*tail*, not the mean, is the number that decides whether it feels right.

**Alpha, concretely, is:** the game boots from a user-supplied ROM, runs the full attract
cycle with speech, takes coins, plays, and saves high scores across a power cycle; the
known remaining defects are enumerated with measurements attached in `DEVIATIONS.md` §D;
the gates that certify it have themselves been shown able to fail; and the one thing
this project will not do is claim an accuracy it has not measured.

### Claims in the existing docs found to be false during this work

Listed so they can be corrected at the source:

| Document | Claim | Status |
|---|---|---|
| `PERF_CADENCE.md` §4 | the core "can already read" `$16C990`/`$16C992`, and sampling them gives cadence | **False both ways.** Nothing read either address; and they are incremented *before* the already-running gate, so they count video frames and would read a flat 1.0000 on a core missing every other deadline. `VSHAD3.md` §6 is correct. |
| `mo_placement.md:205-207` | "no `apply_stain` second pass, and a special object does not mask a normal object underneath it" | **Both implemented** at MOSTAIN-1. |
| `mo_priority.md` "Still outstanding" | "Why only ~17% converts" | **Superseded** by the blink-phase measurement in the section above it: 61.3% of a 66.8% ceiling. |
| `mo_priority.md:136-141` | tag narrowing is safe because "cross-frame staleness is still caught by `fpar`" | **Refuted by BUILD 108.** `fpar` is one bit and cannot catch a two-frame ghost. Not yet retracted in that file. |
| `ARCHITECTURE.md:24` | "~57.6 Hz" | **Wrong** — 59.9227 Hz. |
| `ARCHITECTURE.md:89` | "TG68K `CPU=>"01"` throughout" | **Wrong** — both instances are `CPU => "00"`. |
| `ARCHITECTURE.md:111` | "No SLAPSTIC window appears… verify, but likely unused" | **Stale** pre-bring-up note, contradicted by its own findings section 20 lines earlier. `SLAPSTIC.md` is the settled account. |
| `JSA.md` | TMS5220 is a "stub (interface + silence)"; SCOM modelled with latch semantics; `escape_core`'s JSA status a stub | **All three superseded.** The real TMS5220 ships, and the SCOM carries an 80-clock transit model. |
| `README.md` | "Hot-code BRAM shadows … ~98% of profiled gameplay execution at zero-wait"; "EEPROM persistence via Pocket save: planned" | Shadows cost **5 clocks**, not zero-wait — the fastpath costs 4. EEPROM persistence **shipped**. |
| `POCKET_TEST.md` | "R cycles 4 HUD pages" | **Stale** — pages 0–5 exist; page 4 is stain coverage and page 5 the cadence readout. |
| `ROMS.md:43-45` | the memory controller is "part of the ongoing core_top integration" | **Stale** — contradicted by `ARCHITECTURE.md`'s own status section. |
| `ROMMAP.md:53-57` | future-tense "openFPGA loading plan"; an ".mra-style manifest builds this" | **Stale on the Pocket** — it is `support/build_rom.py`. A real `.mra` exists only on the MiSTer branch. |
| `DEVIATIONS.md` §E | "Stain second pass matches `apply_stain` on every scored frame, all cases" | **Narrower than it reads.** True of the automaton offline and of `run_stain_tb.sh`; **not** established end-to-end on silicon, where coverage is 61.3% of a 66.8% ceiling. |
| `DEVIATIONS.md` §B2 | the line-buffer ghost is "Fixed" | Fixed in RTL and proven in simulation; **not confirmed on hardware.** |
| `sim/run_mob_cov.sh`, `run_mob_perf_sweep.sh` | "cycles/line … (456 total)" | **Inflated ~9%** — the bench divides by 240 while accumulating over 262 lines. |

---

*Every number in this document is traceable to a commit, a bench run, or a doc in this
repository. Where two sources disagree, both are cited and the better-controlled one is
named. Where something is unverified, it says so.*
