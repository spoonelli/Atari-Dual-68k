# Decision builds — for the owner's return (evening 2026-08-27)

Three Pocket builds and one MiSTer build, each isolating one variable. Flash in
order; every sprite/stain verdict is now a NUMBER on the HUD rather than a
feel.

## The ladder

| build | changes vs previous | what to look at |
|---|---|---|
| **128** (in hand) | baseline: strip fixed, cache out, 6x SDRAM | reference point |
| **129** | + MO/stain ONE-PIXEL ALIGNMENT + telemetry page 6 | map specks GONE; pad-shedding gone; stain-page deficit unchanged-or-better |
| **130** | + MO-over-fastpath ARBITRATION in active lines | page 6 truncation count -> 0 in crowds; page 4 stain deficit -> <=1; page 5 cadence cost, if any |
| **mister-130** | alignment + stain timing + cache bypass (no clock change) | parity check on the DE10 |

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
* **Doors are authentic**: the 5627 red tab is part of the door-open cycle
  (pixel-stable ~102 px for 60 frames); 6983's yellow fragment is a real door
  clipped at the screen edge, world-fixed. Only the mid-cycle plain-wall
  states await MAME adjudication.
* **Floor "specks" are orphaned SHADOWS of authentically blinking sprites**
  (strict 4-8 frame periods, position-stable). The open question is whether
  the blink OFF phase should render a SHADE silhouette (we render plain
  floor); MAME adjudication running.

## Open items with agents/analysis pending

1. MAME adjudication: blink silhouette, door plain-wall states, stain-vs-
   occlusion semantics (agent running).
2. Slowdown authenticity vs the real-PCB reference footage (stall metric
   exists; reference comparison queued).
3. The map screen after 129: if residue REMAINS on the between-levels map, it
   is a different defect than the alignment - the MAME level-3 state dump and
   fixture pipeline are ready to chase it.

## Standing facts for the decision

* The stain machinery runs constantly in gameplay (~254 specials live in
  ordinary crowd scenes), so stain-path fixes are gameplay fixes, not map-
  screen cosmetics.
* MOARB-130's risk is cadence: it taxes only SPECULATIVE fills, and the CPU
  never-wedge path is untouched, but page 5 on 130 is the honest check.
* MiSTer did NOT get the 6x clock (no hardware to verify; different fabric).
