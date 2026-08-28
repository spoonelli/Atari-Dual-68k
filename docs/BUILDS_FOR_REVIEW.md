# Decision builds — for the owner's return (evening 2026-08-27)

Pocket builds and one MiSTer build, each isolating one variable. Flash in
order; every sprite/stain verdict is now a NUMBER on the HUD rather than a
feel.

## The ladder

| build | changes vs previous | what to look at |
|---|---|---|
| **128** (in hand) | baseline: strip fixed, cache out, 6x SDRAM | reference point |
| **129** | + MO/stain ONE-PIXEL ALIGNMENT + telemetry page 6 | map specks GONE; pad-shedding gone; stain-page deficit unchanged-or-better |
| **130** | + MO-over-fastpath ARBITRATION in active lines | page 6 truncation count in crowds; page 4 stain deficit; page 5 cadence cost, if any |
| **131** | + **MOPAIR: 2px/clock MO blit** (the schematic answer) + honest trunc counter | **the headline build** — crowd dropout/blink/door plain-walls should collapse; see below |
| **mister-130** | alignment + stain timing + cache bypass (no clock change) | parity check on the DE10 (packaged: AtariDual68k-mister-130.zip, setup +0.761 / hold +0.246) |

## Why 131 exists (found while you were away)

The crowd-room MAME fixture (xs=473 ys=412) FAILED the vs-MAME gate at ZERO
memory latency: 527 reference pixels missing, whole late-list objects, with
`dbg_trunc` reading 0 and the walk still mid-flight at 85 line-ends per frame.
Per-line arithmetic: worst crowd lines carry ~102 stamps = ~816 blit cycles
against the 456 cycles one scanline has. **The deficit was architectural — no
cache, clock, or arbitration change could ever recover those pixels.**

SP-332 sheet 9 gives the answer: the real line buffer is a PAIR of LB customs
(92U/85U) taking MOL0/1 + MOR0/1 with a 14 MHz DCLK — the board fills TWO
pixels per pixel-clock. MOPAIR-131 restructures the engine's line buffers into
even/odd banks written in one clock, matching that. Result on the fixtures:
crowd 527 missing -> **0** (100.0000% agreement AND coverage), flash-window and
level-3-map scenes 100%/100%, stain automaton all cases 0 mismatches, priority
gate PASS everywhere.

Also in 131: `dbg_trunc` (page 6) now counts TIME truncation — a line-end
firing while unconsumed entries remain — not just budget exhaustion, which
never actually fires. NOTE reading it: a nonzero count is an UPPER BOUND, not
confirmed loss (a truncated tail that is fully occluded by earlier sprites
drops nothing, and MAME agrees pixel-for-pixel while trunc reads 60-80 in
crowds). Trend it against blink episodes: blink with trunc pulsing = confirmed
starvation; blink with trunc steady = look elsewhere.

## How to read the new telemetry (Developer HUD on, R to page 6)

* **Page 6 field1** = {lines truncated this frame, worst gfx fetch latency}.
  Truncations are the walk's OWN count of giving up with work remaining - the
  dropout event itself, as a number.
* **Page 6 field2** = frame counter (hex).
* **Rows 222-227, left**: eight blocks = frame_count[7:0], white=1, MSB left.
  Any capture yields logic-frames-per-video-frame by sampling 8 fixed pixels.
* **Page 4** (stain): field1=stained, field2=specials. The crowd-scene deficit
  (f2-f1 = 32..79 px on 128, load-correlated r=0.46) is the one OBJECTIVE
  load-dependent loss measured in the 128 capture - it is the A/B metric for
  129/130.

## What the 128 census established (so it is not re-litigated)

* **Zero confirmed sprite-dropout events in 115.6 s of human play** - by the
  same detector (with a passed synthetic-erasure control) that found the
  console-cabinet event in the 126 capture. 128 was NOT objectively worse than
  127; the subjective regression decomposed into authentic behaviours:
* **Doors are authentic in STRUCTURE**: the 5627 red tab is part of the
  door-open cycle (pixel-stable ~102 px for 60 frames); 6983's yellow fragment
  is a real door clipped at the screen edge, world-fixed. The mid-cycle
  plain-wall states are NOT authentic - see adjudication verdict 4.
* **Floor "specks" are orphaned SHADOWS of blinking sprites** (strict 4-8
  frame periods, position-stable). Adjudication verdicts 1-3 above settle what
  that blink is: an inauthentic load-dependent MO drop, not a rendering of any
  authentic off-phase.

## MAME adjudication verdicts (in, with data)

1. **The spawn/damage "blink" in MAME is a PALETTE FLASH, drawn every frame.**
   Proven at the data level: per-frame dumps across the flash window
   (t=45.0..45.2 in the replay) show MO RAM **bit-identical for 12 straight
   frames** while 18 CRAM entries (0x125-0x126, 0x148-0x14B, 0x156,
   0x174-0x175, 0x17C-0x17E, 0x1DD-0x1DF, 0x1ED-0x1EF) toggle on an exact
   4-on/4-off cadence - e.g. 0x148: FF0F (bright magenta) <-> FF40 (suit
   orange). The figure never leaves the MO list; only its colours change.
2. **Consequence: the device blink is NOT the flash.** A palette change cannot
   put FLOOR pixels where a sprite is - only MO loss can. And the sprites that
   blink on device (static console slaves, 6-14 frame cadence) **never blink
   in MAME at all**. The device blink is an inauthentic periodic MO drop.
3. **RTL is innocent on static input**: tb_mob MOBLINK check (BLINKCHK=1) on
   the crowd-room fixture (xs=473 ys=412) - 16 consecutive frames from frozen
   RAM, **15504 px every frame**, zero oscillation. So the blink needs
   frame-to-frame VARIATION to happen: SDRAM latency/arbitration phase pushing
   the walk over its fetch budget on some frames. That is precisely what
   **page 6 dbg_trunc** counts and what **MOARB-130** attacks.
   * **Decisive device observation: watch page 6 during a blink episode.
     dbg_trunc pulsing in step with the blink = confirmed; then 130 vs 129 is
     the A/B.**
4. **Doors**: MAME door cycles contain ZERO plain-wall frames. The Pocket's
   2-6 frame plain-wall states during door cycles are a real defect (same
   family as the blink: whole-object loss under load).
5. **Stain semantics ground truth**: apply_stain is unconditional wrt the
   playfield; the only authentic truncation is MO-vs-MO marker clobbering
   (atarimo.cpp:239-252). So a stain-page deficit beyond the clobbering
   baseline is loss, not authenticity.

## Open items

1. Slowdown authenticity vs the real-PCB reference footage (stall metric
   exists; reference comparison queued).
2. The map screen after 129: if residue REMAINS on the between-levels map, it
   is a different defect than the alignment - the MAME level-3 state dump and
   fixture pipeline are ready to chase it.
3. If 130 does NOT cure the blink/door drops while dbg_trunc goes to 0, the
   loss is downstream of the walk (stamp delivery), and the next lever is the
   real 4-word SDRAM burst (controller change - documented in
   escape_mo_cache.v header).

## The walk-cycle clock (slowdown ground truth, from MAME MO RAM)

Tracking the player object through 600 per-frame MO RAM dumps (t=50..60 of the
replay): the walk animation advances its picture code every **8 logic frames**,
alternating base<->step codes in a 4-phase cycle - **32 logic frames = 533 ms
per full cycle** at 60 Hz. That is a wall-clock-measurable signal present in
ANY footage, original CRT included: time the animation phase changes, divide 8
frames by the measured spacing, and you have the local game speed with no
telemetry needed. Complements the MOTEL bit row (which needs the HUD on):
  * phase spacing 8 video frames  -> full speed
  * spacing ~9   -> ~89% (the census's half-rate stretches would show ~16)
Decoder for the bit row + build stamp: sim/tools/capture_decode.py
(stamp decode validated 5/5 on builds 124-128 captures; bit row awaits the
first 129+ capture).

Caveat: the video-side sweep measured a 12-frame visual loop (with a 24-frame
secondary) on a DIAGONAL walk, vs this 32-frame MO-code cycle from the replay's
mixed play - likely different animations (diagonal vs straight, or walk vs
run). Both measurements agree on the conclusion that matters: CRT and Pocket
run at the same rate.

## Autonomous sweep of the 08-26 re-test captures (builds 124-128)

An analysis agent swept the five Genki captures (build stamps decoded
on-screen: 10:27=124, 14:19=125, 14:46=126, 16:01=127, 16:53=128). Findings
(full report /tmp/sweep/REPORT.md, crops in /tmp/sweep/crops/):

* **Stall rate (duplicated frames while scrolling)**: 124 = 11.5% with
  textbook half-rate bursts; 128 = 5.9% (upper bound, some may be walk
  cadence); 125/126/127 = 1.2-2.0% (~measurement floor). NOT scene-matched -
  treat as indicative, and re-measure on 129+ with the bit row, which needs no
  scene matching at all.
* **Map grey-out specks CONFIRMED on 126's level-3 map** (t221-226, stable
  scattered specks + 1px yellow columns in the greyed paths) - the exact
  defect MOALIGN-129 targets. Other captures never reach a greyed map:
  untestable there, not clean.
* **Zero blink episodes and zero door cycles in this footage** - both defect
  families are scene-dependent and simply absent from these sessions; nothing
  to conclude either way.
* **Real-cabinet CRT footage identified: IMG_4549.MOV** (~4 min, dedicated
  cab, live play - the best reference) and IMG_4625 2.MOV (attract+demo).
* **No game-speed difference between the real PCB and build 128**: the CRT
  walk-scroll runs a rock-steady 2.0 native px/frame matching the Pocket
  measurement, and the animation autocorrelation dips line up.

## Standing facts for the decision

* The stain machinery runs constantly in gameplay (~254 specials live in
  ordinary crowd scenes), so stain-path fixes are gameplay fixes, not map-
  screen cosmetics.
* MOARB-130's risk is cadence: it taxes only SPECULATIVE fills, and the CPU
  never-wedge path is untouched, but page 5 on 130 is the honest check.
* MiSTer did NOT get the 6x clock (no hardware to verify; different fabric).
