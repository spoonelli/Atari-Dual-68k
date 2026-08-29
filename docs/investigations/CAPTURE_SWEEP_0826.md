# Atari Dual 68k core — five-build capture sweep (b124–b128)

Source captures (Analogue Pocket via Genki Arcade, 1920x1080@60 CFR, build stamp verified on-screen):

| build | file | length |
|---|---|---|
| 124 | Genki Arcade - 2026-08-26 102750.mp4 | 208 s |
| 125 | Genki Arcade - 2026-08-26 141912.mp4 | 61 s |
| 126 | Genki Arcade - 2026-08-26 144648.mp4 | 229 s |
| 127 | Genki Arcade - 2026-08-26 160136.mp4 | 106 s |
| 128 | Genki Arcade - 2026-08-26 165302.mp4 | 134 s |

Sampling performed: 1 frame/2 s over all five videos (370 frames, content segmentation);
24 targeted 60 fps windows (2–4 s each, ~3,100 frames); ~350 additional targeted frames
(transitions, maps, CRT footage). Analysis at native resolution 336x240 (game area
x240..1679, y0..1079). Developer-HUD regions (top "ATARI DUAL 68K ALPHA OK" line,
mid-screen yellow-on-navy hex band — seen at native rows ~76–96 in some scenes and
~94–130 in others, detected per-stack by navy-row fraction — bottom bars, cyan build
stamp) were masked out of all detectors.

## Scorecard

| # | Defect family | b124 | b125 | b126 | b127 | b128 | Confidence |
|---|---|---|---|---|---|---|---|
| 1 | Left-edge strip | n/d | n/d | n/d | n/d | n/d | UNVALIDATED DETECTOR — no result |
| 2 | Static-sprite blink | 0 episodes | 0 | 0 | 0 | 0 | medium (~10 s/build eligible coverage) |
| 3 | Door plain-wall | — | — | — | — | — | no door cycles captured; unmeasurable |
| 4 | Stall rate (dup frames during scrolling) | 11.5 % (30/262) | 1.2 % (5/408) | 2.0 % (11/560) | 1.2 % (6/488) | 5.9 % (24/405) | med-high b124, med b128 |
| 5 | Map grey-out specks | untestable | untestable | PRESENT | untestable | untestable | high for b126; others lack greyed-map coverage |

## 1. Left-edge strip — detector calibration FAILED, results not usable

Ground truth for calibration: strip present in 124/125/126, fixed in 127/128. Six detector
variants were tried on 236 coarse gameplay frames plus ~1,500 60 fps frames:

1. Column statistics x1..6 vs x10..15 (fraction of divergent rows) — no separation
   (medians 0.31–0.42; b128 scored highest, contradicting ground truth).
2. Temporal motion ratio (strip vs reference columns during scroll) — ratio ~1.0 everywhere.
3. Spatial discontinuity profile E(x), x=0..24, averaged per build — no systematic spike.
4. Scroll-consistency (strip must follow estimated global dx) — strip error consistently
   BELOW reference in all builds.
5. Floor-continuity (floor rows must extend into x1..8) — b127 scored worst (0.31);
   premise invalid for isometric scenery.
6. Column-variance smear test — no separation.

Visual inspection at full capture resolution (magnified up to 4x NN) of every coarse frame
of b124/b126/b127 (alledges_*.png), Level-2 canal scenes (lvl2_edges.png), and 60 fps
scroll sequences (strip_*.png, b125w1_strips.png) found no visible wrong-pixel strip in
any build, including the known-bad ones.

Conclusion: the artifact is either scene/condition-specific in a way not present in the
sampled frames, or below what the 4.3x-scaled Genki capture reveals. Since the detector
cannot reproduce known ground truth, no per-build strip claims are made. Evidence:
crops/leftedge_sidebyside_builds.png, crops/leftedge_zoom_builds.png.

## 2. Static-sprite blink — no episodes found

Method: 4 s @60 fps windows on dark rooms with captive figures at consoles (b124 t96–100,
b125 t52–56, b126 t54–58, b127 t58–62, b128 t30–34) plus ten 2.5 s scroll windows.
Detector: 8x8 blocks (stride 4) toggling between two well-separated (>30 grey) states,
off-runs 4–14 frames flanked by >=4-frame on-runs, >=2 episodes, surrounding 8-px ring
static (<1.5 mean diff), HUD masked.

Result: 2 raw candidates, both rejected on visual review (crops/blink_candidates_falsepos.png):
b125_w0 (24,212) = level-start screen reveal; b127_w0 (204,272) = the normally-blinking
"PRESS JUMP TO JOIN IN" panel. Captives visible in b125/b128 windows stay continuously
rendered. Legitimate look-alikes excluded: room lights-off cycles (whole-room dimming) and
the player's post-spawn color flash.

Zero blink episodes in ~50 s of 60 fps footage across five builds. Coverage is ~10 s per
build of eligible scenes, so a rare blink cannot be excluded, but no evidence of this
defect exists in any build sampled.

## 3. Door plain-wall — no door cycles captured

In-place-animation detector (sustained localized change, stationary centroid, camera
static) over all 24 stacks; manual review of every event >=80 px. Everything found was
robot transform animations, the electro-stairs fold/unfold, the player color flash, or the
HUD hex band. Doorways appear only as static dark openings; no sliding-door animation was
ever on screen. 0 plain-wall frames observed, but also 0 door cycles observed — family
unmeasurable from these captures. Nothing contradicts or confirms MAME's zero-plain-wall
ground truth.

## 4. Slowdown / stalls

Metric: at 60 fps, game-area content diff (HUD masked). Scrolling frames = local median
(±5) diff > 3; stall = instantaneous diff < 0.5 inside a scrolling segment. Totals over
24 windows (~62 s):

| build | stalls / scrolling frames | rate |
|---|---|---|
| 124 | 30 / 262 | 11.5 % |
| 125 | 5 / 408 | 1.2 % |
| 126 | 11 / 560 | 2.0 % |
| 127 | 6 / 488 | 1.2 % |
| 128 | 24 / 405 | 5.9 % |

b124 shows textbook halved-rate stretches — alternating diff series during active scroll
(b124_w1 f4–16: 30.2, 0.7, 30.6, 0.4, 30.1, 0.4, 28.8, 0.4, 26.3, 0.2 …): logic updated
every other 60 Hz frame in ~0.5 s bursts. Independently corroborated by scroll vectors:
only 27–50 % of frames moved the camera in b124_w1 vs 100 % in b125_w1/b126_w0 during
comparable walks. b128 shows shorter dup bursts (b128_d1 f0–17); part of its 5.9 % may be
legitimate sub-pixel walk cadence (diagonal walk = 0.8 px/frame → zero-shift frames are
expected), so treat b128 as an upper bound. 1–2 % in b125/126/127 is the measurement
floor. Ranking: b124 clearly worst; b128 possibly mildly affected; b125/126/127 clean.
Caveat: scenes are not matched across builds.

## 5. Map grey-out specks — PRESENT in b126, untestable elsewhere

The between-level map is the "FACTORY MAP OF PLANET X" screen. All five builds show a
clean fully-drawn Level-1 start map (b124 t24.5 partial-wipe but clean, b125 t19–23,
b126 t23–24.5, b127 t3–9, b128 t12–16) — crops/maps_all_builds.png.

Only b126's capture reaches a later map with greyed-out (completed) regions (t221–226,
Level-3 select). There the greyed lower-left region renders as scattered isolated 1–2 px
colored specks and stray single-pixel yellow columns instead of intact dimmed node
graphics, while the lit upper-right path renders correctly. The corruption is stable for
>2 s (t222 and t224 identical character), so it is not the map-assembly animation.

Evidence: crops/b126_map_lvl3_specks_t222.png, crops/b126_map_lvl3_specks_t224.png,
crops/b126_map_lvl3_full_t223.png; clean comparators crops/b125_map_lvl1_clean_t20.png,
crops/b127_map_lvl1_clean_t7.png, crops/b128_map_lvl1_clean_t14.png; side-by-side
crops/map_speck_zoom_compare.png.

Verdict: PRESENT in b126 (high confidence). Other builds' captures contain no greyed-out
map regions — untestable, absence of evidence only.

## Real-arcade-PCB reference footage

All 90 IMG_* videos sampled (1–2 frames each; imgsheet_0.png, imgsheet_1.png):
84 Pocket-handheld shots, 1 portable monitor (ARZOPA, IMG_3795), 3 dark/indeterminate,
and 2 genuine CRT arcade-cabinet videos of this game:

- IMG_4549.MOV (portrait, ~4 min, 30 fps): dedicated cabinet — curved CRT glass, cabinet
  instruction card, "INTERPLANETARY SWAT TEAM" panel art; attract pages plus a full live
  1-player game (JAKE score 800 → 16700). Best gameplay reference.
- IMG_4625 2.MOV (landscape, >=2 min, 30 fps): same cabinet wider — two joysticks +
  buttons, side art, attract and demo gameplay.

Evidence: crops/crt_IMG_4549_gameplay_t120.png, crops/crt_IMG_4625_2_cabinet_t20.png,
crops/crt_IMG_4625_2_attract_t60.png, crtsheet.png, crtscan.png.

## Walk-cycle comparison (CRT reference vs Pocket b128)

- Pocket b128 (t87–90, 60 fps, player-tracked sprite crops,
  crops/b128_walkcycle_strip_60fps.png): clean autocorrelation minima at lags 12 and 24
  frames → animation loop = 12 frames @60 Hz (5.0 loops/s); at the standard 2 steps/loop
  that is ~10 steps/s (if the true full stride is the 24-frame secondary period,
  5 steps/s — the 12-frame dip is deeper). Walk translation: camera-follow scroll =
  (0.79, 0.81) native px per 60 Hz frame diagonal (~68 px/s); b125 footage shows
  2.0 px/frame for straight walks.
- CRT (IMG_4549, 30 fps handheld): jitter-aligned diff tracking of the walking player
  (t115.4–117.6, crops/crt_walkcycle_strip_30fps.png) gives a shallow autocorrelation dip
  at lag 6 @30 fps = 12 frames @60 Hz — the same 5.0 loops/s — LOW confidence (dip ~2 %
  below neighbours; handheld jitter + CRT flicker). Corroboration: CRT camera scroll
  during a straight-left walk is a rock-steady 2.0 native px per 60 Hz frame
  (110–124 px/s) with no dropped updates, matching the Pocket's straight-walk speed.

Conclusion: no walk-cadence or game-speed difference detectable between the real PCB/CRT
and Pocket build 128 (outside b124-style stall bursts, which the CRT footage never shows).

## Honest limitations

- Family 1 results are void: the mandated calibration could not be reproduced by six
  detectors nor close visual inspection; per instructions the detector is declared
  unvalidated and no strip conclusions are drawn.
- Families 2 and 3 are bounded by coverage: ~10 s/build of eligible blink scenes; zero
  door cycles on screen in any capture.
- Stall rates are not scene-matched across builds; b128's rate is an upper bound.
- Family 5 could only be exercised on b126, the sole capture reaching a greyed-out map.
- CRT walk-cycle period rests on a shallow dip; the speed corroboration is the stronger leg.

## Key evidence files (kept)

- /tmp/sweep/crops/ — probative crops (map specks, clean maps, CRT cabinet, walk strips, left-edge nulls)
- /tmp/sweep/sheet1.png, transsheet_a.png, transsheet_b.png — content segmentation proof
- /tmp/sweep/alledges_b124.png, alledges_b126.png, alledges_b127.png — left-edge survey
- /tmp/sweep/blinkstrips_all.png, blinkcands.png — blink candidates and rejections
- /tmp/sweep/doorcycles.png, doorregion.png, inplace_events.png — door-search nulls
- /tmp/sweep/imgsheet_0.png, imgsheet_1.png, crtsheet.png, crtscan.png — IMG classification
- /tmp/sweep/coarse_stats.json — per-frame features of the coarse pass
