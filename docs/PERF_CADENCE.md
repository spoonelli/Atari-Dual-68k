# Does the original slow down in busy areas?

The question this answers, verbatim: *"how about raw gameplay speed and memory
handling in busy areas: does the original/mame drop frames or have enough
headroom to not get slowdown"*.

Short answer: **the original has a lot of headroom on the world CPU and a
little on the video CPU. It does miss logic deadlines, but rarely and on the
video CPU rather than the world CPU: 0.23% of frames with one player, 2.4%
with two — and, importantly, the misses are NOT caused by sprite crowding.** On the numbers below, the world engine is not
where our remaining gap is, and chasing it further is chasing a phantom.

Everything here is measured in MAME 0.289 against romset `eprom`, with
`sim/tools/logic_cadence.lua` and `sim/tools/cadence_report.py`. Raw CSVs are
not committed; the commands to regenerate them are at the bottom.

## 1. What "slowdown" is on this board, and how to see it

A fixed-raster arcade board cannot drop a video frame: the raster free-runs at
59.9227 Hz = 7,159,090 / (456 x 262), which is 119,318 68000 clocks per frame.
What it does under load is **miss its logic deadline**, so the world updates
every 2nd or 3rd video frame. The number to measure is therefore *logic
updates per video frame*, and it has to come off the game's code, not off the
picture.

Both CPUs turned out to have the same structure, and both announce their own
logic frame in shared RAM:

| CPU | handler | "already running?" flag | logic-frame counter |
|---|---|---|---|
| extra ("world") | `$08F6` via `$0308` | `$16CCD6` | `$16C992` (and `$16C996` in `$F792`) |
| main ("video")  | `$404E0` via `$05CC` -> `$20006` | `$16CCD4` | `$16C990` |

```
    ; extra CPU                          ; main CPU
    08fa  tas    $16cc00                 404e4  tas    $16cc00
    090e  tst.b  $16ccd6 / bne -> exit    40510  tst.b  $16ccd4 / bne -> exit
    0916  move.b #$50,$16ccd6   START     40518  move.b #$50,$16ccd4   START
    091e  addq.w #1,$16c992               404fe  addq.w #1,$16c990   (before the gate)
    0932  jsr    $f792                    4052e  jsr $5673e / jsr $56120
    0938  clr.b  $16ccd6       END        4053a  clr.b  $16ccd4       END
```

A write of `$50` to the flag starts a logic frame; a write of `$00` ends it.
Tapping those two writes gives both the cadence *and* the exact duration of
every logic frame, with no ROM patching.

**The deadline rule** (fitted and then confirmed, see section 3): the vblank
IRQ is acked early in the frame by whichever CPU reaches the ack first, so a
body that overruns does not restart the instant it RTEs — it waits for the
next vblank. A body of duration D therefore occupies `ceil(D / 16688.15us)`
video frames, and `updates/frame = n_bodies / sum(frames_consumed)`.

## 2. What the original does

10 minutes of scripted level-1 play each, 35,953 video frames per run.

| | 1 player | 2 players |
|---|---|---|
| sprite load (objects, p50 / p99 / max) | 8 / 24 / 26 | 22 / 35 / 36 |
| **world CPU updates per video frame** | **0.9999** | **0.9989** |
| world logic frame, mean | 8,014 us = **48.0%** of the frame (57,376 of 119,318 clocks) | 8,859 us = **53.1%** (63,420 clocks) |
| world logic frame, p99 / max | 12,482 / 18,483 us | 13,906 / 28,428 us |
| **video CPU updates per video frame** | **0.9977** | **0.9758** |
| video logic frame, mean | 10,298 us = **61.7%** (73,724 clocks) | 11,193 us = **67.1%** (80,128 clocks) |
| video logic frame, p99 / p99.9 | 13,895 / 14,343 us | 16,498 / 17,261 us |

For scale at the other end: on the title/story screens the world CPU's logic
frame is 1,761 us — **10.6%** of the budget. In the attract demo it is
4,652 us (27.9%) and the video CPU's is 6,497 us (38.9%).

Two things matter in that table.

* **The world engine is not the bottleneck on the original.** It uses about
  half its frame and misses 2 deadlines in 35,953 frames with one player.
* **The video CPU is the tighter of the two**, and it is the one that actually
  drops frames: 0.23% of frames with one player, 2.4% with two, worst
  one-second window 0.92 updates/frame.

### Answering "busy areas" directly

Sorting all 35,953 frames of the one-player run by the number of sprite tiles
actually on screen that frame:

| sprite-tile band | frames | mean tiles | world updates/frame | video updates/frame | video body |
|---|---|---|---|---|---|
| quietest 10% | 3,481 | 104 | 1.0000 | 0.9989 | 10,317 us |
| 25-50%       | 8,547 | 151 | 0.9999 | 0.9999 | 10,327 us |
| 75-90%       | 5,551 | 206 | 1.0000 | 0.9998 |  9,947 us |
| **busiest 10%** | 3,700 | **322** | **0.9997** | **0.9822** | 10,676 us |

So the original *does* slow down in its busiest scenes, and by a precisely
small amount: in the top decile of sprite load the video CPU misses about 1.8%
of its logic frames instead of 0.1%, which is roughly one held frame per
second at the very worst, and its logic frame grows by 3.7%. The world engine
does not move at all. With two players the sprite-load trend disappears
entirely (busiest decile 0.9970 / 0.9631 against quietest 0.9988 / 0.9575) —
the second player's cost is a fixed addition, not a crowd effect.

**Crowding is not what costs the CPUs.** Correlation between logic-frame
duration and on-screen sprite tiles is +0.07 for the world CPU and -0.03 for
the video CPU. The frames the video CPU missed carry a mean sprite load of 421
tiles against 427 for all frames — statistically the same picture. What does
move the cost is *which part of the game is running* (the video CPU's mean
body grows from 10.7 ms to 11.8 ms over ten minutes as the run reaches later
sectors), and the number of players.

## 3. Proving the metric can see slowdown

A metric that reads 1.00 everywhere is broken. `PERF_INJECT=N` /
`PERF_VINJECT=N` retarget one `JSR` inside the logic frame through a stub in
unused ROM space that burns N `DBRA` iterations (10 clocks each) before
falling through to the real routine, so a **known** number of 68000 cycles
enters every logic frame. The stub is installed after the ROM self-test has
passed, so the checksum test still sees the unmodified ROM.

```
world CPU, cycles injected into $f792        video CPU, injected into $4052e
 inject  +us/frame  measured    model         inject  +us/frame  measured    model
      0          0    1.0000   1.0000              0          0    0.9911   1.0000
   2000       2794    1.0000   1.0000           1000       1397    0.9680   0.9431
   4000       5587    0.9928   0.9928           2000       2794    0.9107   0.9422
   5000       6984    0.8999   0.8998           3000       4190    0.8153   0.8124
   6000       8381    0.6951   0.6948           4000       5587    0.6142   0.6161
   8000      11175    0.4999   0.5000           5000       6984    0.5021   0.5000
  14000      19556    0.4999   0.4999           8000      11175    0.4999   0.5000
```

* The metric runs the whole range, 1.0000 down to the 0.5000 floor where the
  world updates on every second frame. It is not saturated.
* The `ceil(D/T)` deadline rule reproduces the **measured** cadence from the
  **measured** duration distribution to four decimal places on the world CPU
  (mean error 0.0001, zero free parameters). The video CPU needs one fitted
  parameter — 875 us/frame of work outside the bracketed body, which is the
  `$05CC` wrapper and the `TAS` — and then matches to 0.009.
* Timing is calibrated: 2,794 us injected moved the measured mean body from
  8,717 to 10,702 us; 5,587 us injected moved it to 13,402 us.

Two tooling bugs were found and fixed while doing this, both of which had
produced confident wrong numbers first:

* splitting a straddling body's busy time across the frame boundary was
  overwriting the body's start timestamp, which silently **capped every
  measured duration at one frame** — so bodies that overran looked like bodies
  that just fitted;
* the warm-up branch cleared some accumulators and not others, so the first
  CSV row carried 40 s of counts and every per-frame mean was wrong (this is
  what produced a nonsense "1.9 video logic frames per video frame").

## 4. Reading the same numbers off our core

The core's HUD page 0 already reports `dbg_vcyc` / `dbg_ecyc` = completed bus
cycles per frame per CPU (AS falling edges, latched at vblank). MAME can be
made to count exactly the same thing: a **wide** read/write tap over the whole
address space does see the m68k's opcode fetches (a narrow one does not — a
2-byte tap on the ISR entry counted zero while the handler ran every frame).
Verified against arithmetic: in a frame dominated by a pure `DBRA` loop, which
a real 68000 executes as 2 bus cycles per 10 clocks, MAME counted 23,893
cycles/frame against the predicted 119,318/10 x 2 = 23,864 — 0.12%.

`sim/tools/hudscan.swift` OCRs the HUD out of a capture (it decodes
`core_top.v`'s own 4x6 `hexfont`, and reports `?` rather than guessing).
From the BUILD 106 hardware capture, 2,759 cleanly decoded gameplay frames:

| bus cycles per frame | our core (BUILD 106) | MAME (zero waitstates) | ratio |
|---|---|---|---|
| video CPU | 22,233 | 25,630 / 25,760 / 25,796 (1P / 2P / demo) | **86-87%** |
| extra CPU | 20,340 | 22,244 / 22,543 / 21,271 (1P / 2P / demo) | **90-96%** |

The video CPU's reference is essentially scene-independent across all three
gameplay states, so its ~13% deficit does not hinge on matching scenes. The
extra CPU's reference moves by 6% between states, so its ratio is only pinned
to 90-96% — i.e. anywhere from "a small deficit" to "no deficit worth naming".
(The capture is a real one-player game, which makes 22,244 the closest
reference and 91% the best single number.)

**On hardware the CPUs are not being starved more in crowded scenes.** Split
the capture's frames by how much the picture changed: the busiest quartile
gives vcyc 22,036 / ecyc 20,277 and the quietest gives 22,301 / 20,609 — a
1.2-1.6% difference. Whatever the MO engine costs the CPUs, it is not a
crowd-dependent stall.

Feeding those ratios through the validated deadline model, against the same
workload the original was measured on:

| | world updates/frame | video updates/frame |
|---|---|---|
| original (1P), measured | 0.9999 | 0.9977 |
| ours at 91% world / 86% video (1P) | 0.9994 | 0.9748 |
| original (2P), measured | 0.9989 | 0.9763 |
| ours at 91% world / 86% video (2P) | 0.9971 | 0.9413 |

(The model run at 100% speed on the same durations returns 0.9999 / 0.9982 and
0.9989 / 0.9763, i.e. it reproduces the measured baselines to 0.0005, so the
"ours" rows differ from the "original" rows only because of the speed factor.)

**Caveat, and it is a real one.** That is an *estimate*, not a measurement of
execution speed. Bus cycles per frame is a proxy: TG68K and MAME's Musashi are
different implementations and need not issue identical prefetches for the same
code, and a slower CPU also shifts its own mix of work-code and idle-spin,
which have different bus densities. Treat the ratios as +/- 5 points.

### The measurement that would end the argument

Both counters the game keeps for itself live in shared RAM, which the core can
already read: **`$16C992` (world) and `$16C990` (video)**. Sample either one
at vblank, subtract, and show "logic frames per 256 video frames" on the HUD.
That number is *directly* comparable to the 0.9999 / 0.9977 above, needs no
proxy and no assumption about prefetch models, and is worth more than any
amount of further inference from bus-cycle counts.

## 5. What the videos can and cannot support

**The BUILD 106 capture (60.000 fps, 1920x1080) can support the HUD reading in
section 4, and nothing about cadence.** Frame-differencing the picture to look
for held frames does not work on this game, and there is a control experiment
that says so: two MAME sequences of the same scene, one at exactly 1.0000
world updates/frame and one at exactly 0.5000, give 14% pixel-identical frame
pairs for the *fast* one and 0% for the *slow* one. The reasons are that the
video CPU keeps animating the display even when the world CPU has missed, and
that a great many frames of this game genuinely have nothing moving. The test
has both a large false-positive and a large false-negative rate; it cannot
bear a cadence claim.

**The real-cabinet phone video (29.999 fps, portrait, handheld, through glass)
can support nothing quantitative at all.** Sampling a 59.92 Hz CRT at 30 fps
sits exactly at Nyquist for the 59.92-vs-29.96 Hz distinction we would be
trying to make, the beat is 0.04 Hz, and the frames show rolling-shutter bands
across the picture plus glare and perspective. It confirms the cabinet exists
and is running level 1 of the same game. That is all it can say.

## Reproducing

```
MAME=/path/to/mame0289          # needs romset "eprom" on the rompath
WT=$(pwd)
mkdir -p /tmp/cad
# 10 min of one-player and two-player level 1
for M in play1 play; do
  PERF_OUT=/tmp/cad PERF_TAG=final_$M PERF_T0=35 PERF_TEND=635 PERF_MODE=$M \
  $MAME/mame eprom -rompath <romdir> -video none -sound none -nothrottle \
     -skip_gameinfo -autoboot_delay 0 -autoboot_script $WT/sim/tools/logic_cadence.lua
done
# the validation sweeps
for N in 0 2000 4000 5000 6000 8000 14000; do
  PERF_OUT=/tmp/cad PERF_TAG=inj$N  PERF_T0=45 PERF_TEND=105 PERF_MODE=play \
  PERF_INJECT=$N  PERF_INJECT_AT=40 $MAME/mame eprom ... -autoboot_script .../logic_cadence.lua
  PERF_OUT=/tmp/cad PERF_TAG=vinj$N PERF_T0=45 PERF_TEND=105 PERF_MODE=play \
  PERF_VINJECT=$N PERF_INJECT_AT=40 $MAME/mame eprom ... -autoboot_script .../logic_cadence.lua
done
python3 sim/tools/cadence_report.py /tmp/cad /tmp/cad/final_play1.csv
# HUD off a capture (box coords from sim/tools/read_hud.py on one frame)
swiftc -O -o /tmp/hudscan sim/tools/hudscan.swift
/tmp/hudscan capture.mp4 430,450,1525,556 > /tmp/hud.csv
```
