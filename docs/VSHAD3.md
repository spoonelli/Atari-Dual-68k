# The video CPU's third shadow: measured, and why it is not flipped yet

The question: BUILD 107 runs the **video CPU at 22,203 bus cycles/frame against
MAME's 25,630 (0.866)** and the **extra CPU at 20,509 against 22,244 (0.922)**
(`docs/GFX_DASH_ARTIFACT.md` section 8, 173 decoded HUD frames). The structural
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
(`docs/PERF_CADENCE.md`). Scaling by our speed ratio:

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
  budgets for "both CPUs streaming fetches" and estimates MO keeps >=40% of the
  bus — an **estimate, not a measurement**, and the MO engine is the
  lowest-priority SDRAM client. If that extra fill traffic pushes the effective
  fill latency past one CPU clock, section 1's table says the change is neutral
  at best and negative past two. And the cost would land on the graphics path.
* **The methodological point.** This branch also fixes a real graphics bug
  (`docs/GFX_DASH_ARTIFACT.md`). Shipping a memory-system gamble in the same
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
processors run, not whether the game met its deadline. `docs/PERF_CADENCE.md`
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
