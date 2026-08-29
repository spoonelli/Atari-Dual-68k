# The video CPU's third shadow: measured, and why it is not flipped yet

The question: BUILD 107 runs the **video CPU at 22,203 bus cycles/frame against
MAME's 25,630 (0.866)** and the **extra CPU at 20,509 against 22,244 (0.922)**
(`docs/investigations/GFX_DASH_ARTIFACT.md` section 8, 173 decoded HUD frames). The structural
difference between the two CPUs is how much of their hot code is *shadowed*:
80 KB for the video CPU, 20 KB for the extra. Since the zero-wait fastpath
landed, that is the wrong way round.

## 1. The mechanism, measured rather than argued

`sim/run_busrate.sh` runs the **shipped `escape_core`** with a 128-byte NOP loop
at a chosen address and counts `v_as_n` falling edges — the same edge
`escape_core`'s own `vcyc_fr` meter counts, which is the same number the HUD
reports — over 200,000 CPU clocks. NOP touches no data, so every bus cycle is an
instruction fetch from the region under test.

Loop at `0x050000`, i.e. inside `vshad3`:

| configuration | clocks per bus cycle | bus cycles / 200k clocks |
|---|---|---|
| `vshad3` present — BRAM path | **5.015** | 39,878 |
| `vshad3` removed, fastpath fill ready in 1 clk | **4.015** | 49,808 |
| `vshad3` removed, fill takes 2 clks | 5.015 | 39,877 |
| `vshad3` removed, fill takes 3 clks | 6.015 | 33,248 |
| `vshad3` removed, fill takes 4 clks | 7.015 | 28,509 |
| `vshad3` removed, fill takes 6 clks | 9.015 | 22,184 |

Two things are now facts rather than inferences:

* **The shadow BRAM path costs exactly 5 CPU clocks and the fastpath hit costs
  exactly 4.** With `FASTPATH_EN=1`, a shadow *costs* the video CPU a clock on
  its hottest code, and `v_shad_rng` suppresses the fastpath on precisely those
  addresses so it cannot win the clock back.
* **The shadow is insensitive to SDRAM latency and the fastpath is not.** The
  5.015 figure is identical at fill latency 1 and 6. The fastpath is 4.015 only
  while the fill lands inside one CPU clock, and degrades linearly after that —
  past 2 clocks it is *worse* than the shadow it replaced.

So this is not "un-shadowing is free". It trades a guaranteed 5 for a 4-or-worse.

## 2. Where the hardware actually sits on that curve

Not measurable from here, but it can be **cross-checked** against the two
hardware numbers, and the check is unusually clean because the two CPUs have
very different shadow coverage.

Take MAME's bus-busy fraction as the work model — the same code executes the
same instructions, a slower memory system stretches cycles without changing the
instruction mix:

```
b_video = 25630 * 4 / 119318 = 0.859        b_extra = 22244 * 4 / 119318 = 0.746
```

Our measured cycles/frame then give the mean clocks per bus cycle:

```
video : 119318 * 0.859 / 22203 = 4.616      extra : 119318 * 0.746 / 20509 = 4.340
```

With the profiled shadow-hit fractions (61% video, 37% extra) and the measured
5-clock shadow path, solve each for the fastpath cost `c`:

```
video : 0.61*5 + 0.39*c = 4.616  ->  c = 4.02
extra : 0.37*5 + 0.63*c = 4.340  ->  c = 3.95
```

**Two independent CPUs, two very different shadow fractions, both solving to
c = 4.0.** That is strong evidence the fastpath is delivering genuine 4-clock
hits on the device today, i.e. the hardware is at the top row of the table.

## 3. What flipping it would be worth

`vshad3` covers `0x50000-0x57FFF`. The commit that added it (`aca5510`) sized it
off a MAME page profile: *"profiled pages 0x53000 14% + 0x56000 17%"*, so ~31% of
video-CPU gameplay execution. Moving that 31% from 5 clocks to 4:

```
new mean   = 4.616 - 0.31          = 4.306 clocks/bus cycle
new rate   = 119318 * 0.859 / 4.306 = 23,806 bus cycles/frame   (from 22,203)
vs MAME                             = 0.929                     (from 0.866)
```

In cadence terms, which is what the owner actually feels. MAME's video logic
body is 61.7% of the frame budget mean, 83.3% at p99, 86.0% at p99.9
(`docs/investigations/PERF_CADENCE.md`). Scaling by our speed ratio:

| | mean | p99 | p99.9 |
|---|---|---|---|
| MAME | 61.7% | 83.3% | 86.0% |
| BUILD 107 (0.866) | 71.2% | **96.2%** | **99.3%** |
| with `vshad3` removed (0.929) | 66.4% | 89.7% | 92.6% |

That is the shape of the complaint. The mean is not the problem — BUILD 107 has
headroom on an average frame. The **tail** sits at 96-99% of the deadline, so a
crowd tips individual frames over and the game visibly hitches. Recovering a
clock moves the tail from the edge to ~90%.

It also **frees 25 M10K blocks** against the 308-block ceiling — measured, not
estimated: the `vshad3-off` CI build fits at **283/308** against the shipping
branch's **308/308**. (The instance is 32 KB, i.e. 32 blocks' worth of data, but
the fitter repacks; 25 is the number that matters.) That ceiling is the
constraint every other change in this project has to fight.

## 4. Why it is NOT flipped in this branch

`VSHAD3_EN` is a generic on `escape_core`, **defaulting to 1** — BUILD 107
behaviour, bit-identical. Flipping it is one word. It is not flipped because of
one risk I cannot measure and one methodological point.

* **The risk.** `fast_v_spec` fires speculatively on every non-shadow ROM
  address, so un-shadowing 32 KB of the video CPU's *hottest* code moves it from
  issuing fills on ~39% of its bus cycles to ~70%. `core_top.v:1630-1632`
  **Both of those percentages are estimates and neither has ever been measured -
  see section 7; do not cite them as data.**
  budgets for "both CPUs streaming fetches" and estimates MO keeps >=40% of the
  bus — an **estimate, not a measurement**, and the MO engine is the
  lowest-priority SDRAM client. If that extra fill traffic pushes the effective
  fill latency past one CPU clock, section 1's table says the change is neutral
  at best and negative past two. And the cost would land on the graphics path.
* **The methodological point.** This branch also fixes a real graphics bug
  (`docs/investigations/GFX_DASH_ARTIFACT.md`). Shipping a memory-system gamble in the same
  bitstream would make any change the owner sees unattributable.

## 5. How to evaluate it on hardware, in one build

1. In `src/fpga/core/core_top.v`, add `.VSHAD3_EN(0)` to the `escape_core`
   instantiation (or change the generic default in `escape_core.vhd:23`).
2. Build — or just use the `vshad3-off` branch, which is exactly this change
   and has already been through CI: **fit 283/308 M10K**, timing gate green on
   all 64 clock/corner rows, worst setup **+5.031 ns**, worst hold **+0.041 ns**
   (shipping branch: 308/308, +4.903, +0.093). So the fit and the timing are
   known before anyone flashes it; only the speed question is open.
3. On the device, **HUD page 5** (press R to cycle to mode 5 — the mode digit is
   the rightmost slot of the hex row). Field 3 is the video CPU's bus
   cycles/frame, the same proxy as page 0: expect it to rise from ~22,200
   (`56BB`) toward ~23,800 (`5CF0`) if the fastpath is winning, and to *fall* if
   fill pressure is the binding constraint.
4. Fields 1 and 2 on the same page are the number that actually matters —
   see below.

## 6. HUD page 5: the cadence readout (CADENCE-107)

Every speed number this core has ever reported is a proxy: it says how fast the
processors run, not whether the game met its deadline. `docs/investigations/PERF_CADENCE.md`
measures the original in the units that matter — **logic updates per video
frame**, 0.9977 video / 0.9999 world in MAME — by tapping the re-entrancy flag
each vblank ISR writes: `$50` to `$16CCD4` (main/video) and `$16CCD6`
(extra/world) starts a logic frame, `$00` ends it.

HUD page 5 counts those `$50` writes over **256 video frames**:

```
field1 = video-CPU logic frames per 256 video frames
field2 = world-CPU  logic frames per 256 video frames
field3 = video-CPU bus cycles per frame (the old proxy, for comparison)
```

`0100` hex **is** 1.0000 updates/frame. MAME's reference for the same
measurement is 0.9977 / 0.9999, i.e. `00FF` / `0100`. Anything appreciably under
`0100` is a missed-deadline rate, in the units the arcade board is quoted in,
with no assumption about clocks, bus cycles or wait states anywhere in it.

**On `$16C990` / `$16C992`.** The docs describe these as the game's logic-frame
counters and suggest reading them. They are incremented **before** the
already-running gate — see the listing in `PERF_CADENCE.md` section 1, where
`404fe addq.w #1,$16c990` precedes `40510 tst.b $16ccd4 / bne -> exit` — so they
count ISR entries, i.e. video frames, and would read a flat 1.0000 even on a
core missing every other deadline. The flags are the tap that produced MAME's
reference figures, so the flags are what page 5 counts. (Nothing read either
address before this change; the claim that the core "can already read" them was
wrong.)

The meter is register-only — two counters, two latches, an 8-bit frame divider,
two address comparators — so the M10K delta is structurally zero. It is the same
shape as `mbox_snoop`, which is why that was the template.

**It is tested, and the test can fail.** `sim/run_cadence_tb.sh` runs the real
`escape_core` against an image that executes exactly 137 of the counted write
plus 41 each of three decoys — same address with the wrong data, the world flag
written by the wrong CPU, the odd byte of the same word — and requires the
counter to read exactly 137 and the world counter to read exactly 0. A loose
address compare would read up to 260; a double-counted write strobe would
overshoot. Verified to fail when the expectation is moved by one.

## 7. Reproducing

```
# the per-path clock cost, and its sensitivity to fill latency
BASE=0x050000 VS3=1 ./sim/run_busrate.sh          # shadow  -> 5.015 clk/cycle
BASE=0x050000 VS3=0 FP=1 ./sim/run_busrate.sh     # fastpath-> 4.015
BASE=0x050000 VS3=0 FP=3 ./sim/run_busrate.sh     # fastpath-> 6.015

# the cadence meter's own gate
./sim/run_cadence_tb.sh
```

---

# 8. VSHAD3-112: the partial shadow, and re-deriving which half to keep

BUILD 110's capture settled the argument section 4 could not. Un-shadowing is
**not** free: two independent detectors at different scopes put BUILD 110 at
**1.25e-3 sprite dropouts per robot-object-frame** against BUILD 108's
**3.22e-4**, a 3.6-3.9x regression (p=8.1e-5, replicated across two separate
BUILD 108 captures). The real board's 95% upper bound is 1.2e-3 from zero
events in ~7,150 object-frames, so BUILD 110 sits *on* the bound and BUILD 108
sits comfortably inside it. Section 4's unmeasurable risk was the real one: the
extra fill traffic lands on the motion-object engine, the lowest-priority SDRAM
client.

BUILD 108 costs 25 M10K for that (283/308 -> 308/308, completely full). This
build takes the middle: **half the shadow, and a runtime toggle.**

## 8.1 Which half? Measured, and the intuitive answer is wrong

The obvious guess is the low half, and the obvious guess is wrong by 18:1.

The original sizing commit (`aca5510`) profiled "pages 0x53000 14% + 0x56000
17%", one page in each half, which is where the 32 KB span came from. Re-derived
against MAME 0.289 under *gameplay* (not attract), with a **wide** read tap on
`:maincpu` — a narrow tap is blind to opcode fetches in 0.289 and this project
has been bitten by that before — the split inside 0x50000-0x57FFF is:

| page | run 1 (60 s) | run 2 (90 s) | run 3 (90 s, alt input style) |
|---|---|---|---|
| 0x50000 | 0 | 0 | 0 |
| 0x51000 | 0 | 0 | 0 |
| 0x52000 | 0 | 0 | 0 |
| 0x53000 | 247,584 | 401,156 | 483,733 |
| 0x54000 | 24,288 | 37,211 | 96,096 |
| 0x55000 | 0 | 0 | 0 |
| **0x56000** | **4,420,879** | **6,964,578** | **8,016,857** |
| 0x57000 | 0 | 0 | 0 |

| | LOW 0x50000-0x53FFF | HIGH 0x54000-0x57FFF |
|---|---|---|
| run 1 | 5.28% | **94.72%** |
| run 2 | 5.42% | **94.58%** |
| run 3 | 5.63% | **94.37%** |
| independent re-check (see 8.2) | 5.53% | **94.47%** |
| attract-mode control | 38.24% | 61.76% |

**The HIGH half wins ~18:1, so vshad3 is now 16 KB at 0x54000-0x57FFF.**

This is not a marginal call and it is not a single-window artifact: three
gameplay windows, two input styles, plus an attract-mode control all put HIGH
ahead. Three of the four LOW pages are read *exactly zero* times during
gameplay — and the same buckets are non-zero in the attract control (91,506 and
34,049), which proves the buckets work and gameplay simply never goes there.

It also agrees with the disassembly already in this repo. `logic_cadence.lua`
records the video CPU's per-frame body at `$4052E` as `jsr $5673E / jsr $56120`
— **both in page 0x56000**, which is essentially the whole of the HIGH half's
traffic. The measurement and the listing are two independent sources and they
say the same thing.

## 8.2 Proving the measurement could have come out the other way

A profile that can only report one answer is worthless, so:

* **The tap is not blind.** ~23,200-25,400 main-CPU accesses per video frame.
  A narrow tap that misses opcode fetches reads a few hundred. Page 0x000000
  reads 204,486 in the re-check, so the low buckets are live.
* **It reads different things in different states.** The attract-mode control
  gives 38/62, not 5/95, off the same code — a bucket set that always returned
  95% regardless of what the machine was doing would show it here.
* **It was reproduced independently.** A second script, written from scratch
  with 1 KB buckets instead of 4 KB, a different gameplay window and different
  input phasing, returns LOW 5.53% / HIGH 94.47% against the first script's
  5.28-5.63%.
* **Gameplay was confirmed, not assumed.** The alpha tilemap at `$3F4000` reads
  `SECTOR: M / LEVEL: 01 / JAKE / DUKE` with live scores; `$16C990` ticks once
  per video frame and the `$16CCD4=$50` body runs every frame. The attract
  control instead reads `INSERT COIN(S)`.

**Caveats, stated rather than buried.** A Lua tap cannot separate opcode
fetches from table reads inside a ROM region, so these are "bus cycles touching
this page" — which is exactly the right quantity for deciding what to shadow,
but it is not a pure instruction profile. And the scripted player never got
past LEVEL 01 / SECTOR M; a later level could in principle exercise other code,
though it would have to overturn an 18:1 ratio to change the answer.

**A correction to the comment at `escape_core.vhd:528`.** That comment claims
85% of main-CPU time in 0x40000-0x57FFF with "page 0x4E000 alone = 51%".
Neither half reproduces under gameplay: 66.8-67.8% for the region, and 0x4E000
is 20.4-22.2%. The real hot page is **0x4D000** (25-27%). The old figures do
not reproduce under the attract control either (61.6% / 16.1%), so their
provenance is unclear. The comment is left in place — correcting it would touch
code this change has no other reason to touch — but do not build on it.

## 8.3 What shipped

* **`vshad3` is 16 KB at 0x54000-0x57FFF**, `awidth => 13`. The decode is
  `v_addr(23 downto 14) = "0000010101"` in **three** places that must agree —
  `v_shad_rng`, `v_sel_shad3`, `vshad3_we` — and the first two are both keyed
  on the single signal `v_s3_en` precisely so they cannot drift apart. Section
  4's failure mode is real: `v_shad_rng='1'` with `v_sel_shad3='0'` suppresses
  the fastpath *and* never reads the BRAM, so every fetch falls through to the
  16-clock never-wedge watchdog.
* **A runtime toggle**: Interact id 37, `0xA0000150`, "ROM Shadow 0x54000",
  default **ON**. It gates the decode, not the BRAM and not the fill, so the
  M10K is spent either way and the owner can A/B dropouts against cadence on
  the device without a reflash. Inside `escape_core` it is resampled only while
  `v_as_n='1'`, so flipping it cannot change which memory answers a bus cycle
  already in flight.
* **`sim/run_vshad3_tb.sh`** is the gate. See section 8.4.

## 8.4 The gate, and how it was proven able to fail

`sim/run_vshad3_tb.sh` runs the shipped `escape_core` in four configurations
and requires three *different* specific answers, so no single wrong behaviour
passes it:

| BASE | VS3 | VS3ON | expect | what a wrong answer would mean |
|---|---|---|---|---|
| 0x054000 | 1 | 1 | 5.015 clk/cycle | the shadow is not serving the range it claims |
| 0x054000 | 1 | 0 | 4.015 | the runtime toggle does nothing |
| 0x050000 | 1 | 1 | 4.015 | the range was never actually halved |
| 0x054000 | 0 | 1 | 4.015 | the compile-time generic no longer removes it |

Any configuration reading **>= 6 clk/cycle** is failed outright as the
"served by neither" signature — that is what the 16-clock watchdog fallback
looks like from here, and it is the specific bug the file warns about.

**Mutation-tested — the gate was proven able to fail, not assumed to be.** In a
throwaway worktree off the shipped commit, `v_shad_rng`'s third term was
reverted to the old 9-bit `"000001010"` (the full 32 KB) while `v_sel_shad3`
kept the new 10-bit 16 KB compare. That one-line change — the entire diff
against the shipped commit — is exactly the divergence 8.3 describes:
0x50000-0x53FFF gets the fastpath suppressed *and* is never read from BRAM.

| row | clean | mutant |
|---|---|---|
| 0x054000 VS3=1 VS3ON=1 | 5.015 ok | 5.015 ok |
| 0x054000 VS3=1 VS3ON=0 | 4.015 ok | 4.015 ok |
| **0x050000 VS3=1 VS3ON=1** | **4.015 ok** | **25.015 FAIL** |
| 0x054000 VS3=0 VS3ON=1 | 4.015 ok | 4.015 ok |

Clean: `VSHAD3 GATE: PASS (4/4 rows)`, exit 0.
Mutant: `VSHAD3 GATE: FAIL (1 of 4 rows)`, exit 1.

**25.015 clocks per bus cycle against 4.015** — a 6.2x slowdown on the video
CPU, from a single wrong bit in an address compare, with nothing asserting and
nothing mismatching. That is what "served by neither" costs, and it is why the
gate trips on `>= 6.000` by name.

Note that **three of the four rows still passed** under the mutation, and that
they are the right three: the mutation only widened `v_shad_rng` over
0x50000-0x53FFF, so rows aimed at 0x54000 are genuinely unaffected and a gate
that failed them too would be reporting noise. The gate failed exactly the row
whose address the mutation broke. It discriminates; it does not just alarm.

Note also the second signal in that row, which is why the bench reports bus
cycles and not only a rate: `buscycles` collapsed from 49,808 to **7,995** in
the same 200,000-clock window. A rate alone could in principle be argued about;
a CPU that completed one sixth as much work in the same time cannot be.

## 8.5 Fit and timing (CI run 32807811821, branch `vshad3-partial-112`)

| | M10K | ALMs | worst setup | worst hold |
|---|---|---|---|---|
| BUILD 108, full 32 KB shadow | **308 / 308** (full) | — | — | — |
| BUILD 110, no shadow (`tas-atomic`) | **283 / 308** | — | +5.698 | +0.103 |
| **this build, 16 KB partial** | **299 / 308** (97%) | 13,562 / 18,480 (73%) | **+5.604** | **+0.087** |

The partial shadow costs **16 M10K** where the full one cost 25, and leaves
**9 blocks free** where the full one left zero. The `vshad3` instance itself
reads `depth 8192, M10K=16` in the fit report's RAM summary — half the old
`depth 16384, M10K=32` — so the halved decode and the halved instance did move
together, which was the thing worth checking. **This is the number that decides
whether the change was worth making, and at 299/308 it was: had it come back
at 308/308 the change would have failed its purpose.**

Timing: all **64** analysed clock/corner rows non-negative; the bitstream is
publishable. Hold moved from +0.103 to +0.087, i.e. **-0.016 ns**, against this
design's documented **±0.157 ns** perturbation sensitivity — a `BUILD_ID`
constant alone has moved it 0.088 ns — so that movement is noise and **must not
be read as caused by this change**. The sub-0.150 ns margin warning is not new
and is not a failure: the baseline's +0.103 was already under the floor, and
the tightest hold path is inside the PLL output counter
(`altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk`), not in the shadow
or decode path this change touches.

## 7. MEASURED: the fill-rate input to the SDRAM analysis is still unmeasured

`docs/investigations/SDRAM_ARCH.md` models the baseline partly on the video CPU issuing fills on
**~70%** of its bus cycles with the vshad3 shadow off (vs ~39% on). That pair
comes from `docs/investigations/VSHAD3.md:115`, which is honest about its neighbour being "an
estimate, not a measurement" - but the pair itself was then used as an INPUT to a
memory-system decision. `sim/tb/tb_vfill.vhd` was written to replace it with a
count. It could not, and the reason matters more than the number would have.

Over 480 us the video CPU executes **2194 bus cycles touching 7 distinct 256-byte
pages**, lowest 0x000000, highest 0x3E02D0 (that one I/O, not ROM). Of 1831
fastpath-eligible cycles, **1831 are in r1 (0x000000-0x003FFF)** - r2 and r3 are
hit **zero** times, in both the cumulative and post-VBLANK windows.

**That is not a 0% fill rate.** It is a boot spin loop. The video CPU never
leaves the first 16 KB of ROM, so it never executes the code at 0x54000 that the
39%/70% claim is about. Consistent with the SDRAM agent's own note that
`tb_escape_core` never releases the extra CPU in the captured window - the loop
is very likely the boot handshake waiting on exactly that.

Three consequences:

1. **The 70% figure is not merely unmeasured, it is unmeasurable on this bench**,
   and so is the 39%. Neither should be cited as a measurement, and the load
   model resting on them is an assumption, not a finding.
2. **Any measurement taken from `tb_escape_core`'s window is characterising a
   7-page boot loop**, not gameplay. That is a property worth checking before
   trusting any future number sourced from it.
3. The bench's guards did their job in the useful direction: `c_r1 > 0` and
   `c_elig > 0` both passed, so the run is provably counting real cycles - which
   is what makes "r3 = 0" readable as evidence rather than as a dead classifier.
   A bench that had only asserted "fills > 0" would have failed and taught
   nothing; the range guards are what turn an empty bin into information.

**To actually get the number**, the extra CPU has to be released and the video CPU
driven past boot - i.e. a bench that reaches attract mode, not one that reaches
the reset PC. That is the highest-value simulation follow-up on this branch, and
it is a prerequisite for treating the SDRAM starvation case as measured.

