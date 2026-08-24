# The scrolling horizontal dashes: measurement, not inference

The owner sees *"horizontal artifacts that do appear to scroll"* and pointed at
**:32 s** of the BUILD 107 capture. This file records what was measured, with
frame numbers and pixel coordinates so every claim can be re-checked, and it
retires three explanations that were in circulation.

Everything below is measured on the **native 336x240 decode** of the hardware
captures, or on **MAME 0.289** frames dumped at the same 336x240 through
`sim/tools/mame_framedump.lua`. MAME's screen for `eprom` is 336x240 — the same
grid as our core, so the comparison is pixel-for-pixel with no resampling.

## 1. The artifact is real, and it is in the core's output

Detector: `sim/tools/dash_detect.py`. It looks for a **periodic dark intruder on
a locally uniform background** — dark pixels on row `y` at lag 4/5/6, where rows
`y+/-3..5` are near-uniform. The uniformity term is what keeps the isometric
floor grid out; a detector without it fires on 213/360 pristine MAME frames and
is worthless.

| corpus | exposure windows | detections | rate |
|---|---|---|---|
| MAME 0.289, level-1 gameplay + start area (3,056 frames) | 2,595,892 | **3** (all marginal) | 1.2e-6 |
| MAME, same frames through scaler + JPEG q88 + point-resample | 364,090 | **2** | 5.5e-6 |
| **BUILD 107 capture** (1,857 frames sampled) | 1,468,001 | **63** | **4.3e-5** |

Our rate is **8x the lossy-pipeline control** and 36x pristine MAME, and the
detections are far stronger: median 14 dark pixels and autocorrelation 0.743,
against MAME's 7-8 pixels at 0.42-0.50, which sit on the threshold.

**The controls that make this mean anything:**

* **POSITIVE** — a synthetic 2-row period-4 dash injected onto a uniform MAME
  wall is detected, including after the lossy round-trip.
* **NEGATIVE** — clean MAME frames score 0.
* **LOSSY** — MAME pushed through the measured Pocket scaler kernel and JPEG at
  a quality *noisier* than the real capture (median row-difference 2.86 against
  the capture's 2.59) still scores ~0. This is what rules out H.264 ringing.

The first version of this detector used an **absolute** contrast floor and
scored a perfectly clean negative control **because it could not fire at all on
dark backgrounds** — the threshold demanded "darker than -5". The positive
control caught it. The rate is only reported now because all three controls
behave; `dash_detect.py` refuses to print a rate if the positive control fails.

## 2. What it looks like

Best single example: **native frame 1980 (t=33.0 s), rows 87-88, x 269-335** —
a dashed black line across a flat red wall. The wall is `(207,0,0)`; the dash
pixels are essentially pure black, `(6,0,0)`, `(23,0,0)`, `(17,0,0)`, with
mid-values between them that are H.264 smear, not content.

Clearer still, because no artwork explanation survives it: **frame 1980, rows
141-143, x 102-148** — the same dashed line running **horizontally across the
flat grey-green floor**, cutting straight through the floor's diagonal diamond
grid. Every floor feature in this game is diagonal. A horizontal dashed line on
an isometric floor is not artwork.

Structure: dark **2 on, 2 off, period 4**, two native rows tall, same phase on
both rows (2x2 blocks, not a checkerboard).

## 3. Three explanations that are now dead

### (a) The APF/dock scaler — REFUTED as the cause, but the effect is real

The scaler kernel was measured directly, not assumed, from row-to-row
differences in the 1920x1080 frames (game area x 240-1680):

* 240 rows -> 1080 is **4.5x, replication runs of 4 and 5 alternating**, with
  boundaries at display `y = 3` and `y = 8 (mod 9)`.
* Folding the row-difference profile on period 9 gives contrast **12.3x**;
  control periods 7, 8, 10, 11 and 13 give 1.17-1.46, i.e. nothing.
* The grid is **screen-locked**: over 42 consecutive frames the fitted phase is
  7.82-7.88 of 9, a spread of 0.06 rows.

So the scaler does impose a fixed +/-25% thickness modulation on every
1-pixel horizontal feature, and no RTL change can alter that. **But it is not
this artifact**, because the artifact is present in the native decode before
any scaling, and because it moves with world content while the scaler grid does
not move at all.

### (b) Authentic wall artwork — REFUTED

The real-board video (`IMG_4625 2.MOV`) does show dark horizontal dashes on the
red walls, which looked like artwork confirmation. It is a filming artifact.
On frame `vref2c/g0006_t0146.00.png` the vertical striping period and strength
on four surfaces of the *same frame* are:

| surface | best vertical period | autocorrelation |
|---|---|---|
| flat GREEN "PRESS JUMP" panel | 2 px | **0.95** |
| red wall (left) | 2 px | 0.75 |
| red machinery | 2 px | 0.92 |
| flat grey floor | 4 px | 0.85 |

A flat single-colour panel carries the **strongest** striping of anything on
screen. That can only be the CRT raster beating with the camera sensor. The
board video cannot speak to whether the wall artwork is dashed.

MAME can, and does: it renders the same ROM artwork and scores 1.2e-6.

### (c) Corrupt graphics data at rest — REFUTED

This predicts a shape that is fixed in world coordinates. Measured extent of
the band on the wall, frames 1932-1952:

| frame | row | left end | right end | length |
|---|---|---|---|---|
| 1932 | 73 | 297 | 335 | 39 |
| 1936 | 77 | 289 | 335 | 47 |
| 1940 | 81 | 281 | 328 | 48 |
| 1944 | 85 | 273 | 335 | 63 |
| 1946 | 87 | 269 | 335 | 67 |
| 1950 | 91 | 261 | 328 | 68 |
| 1952 | 93 | 257 | 335 | 79 |

The **left end moves exactly -2 px per frame**, tracking the measured playfield
scroll (dy=+1, dx=-2 per frame, by SSD on pure wall above the band). The
**right end is pinned at the last screen column**, reaching x=335 in 6 of 8
frames. The band therefore **grows from 39 to 79 pixels as the scene scrolls**.
A corrupt tile does not grow.

Second refutation, from the near-static window of the second capture
(`nz/v107b.raw`, frames 68-73, 1.33% of pixels changing per frame): the
detections **alternate with a 2-frame period** — frames 68/70/72 are identical
to each other, 69/71/73 are identical to each other and different. Data at rest
renders the same every frame; this toggles at 30 Hz.

## 4. What it is

One end anchored to world content, the other end running to the end of the
scanline, applied to playfield pixels, toggling with frame parity. That is the
**stain pass**, and the failure mode is already named in `docs/mo_priority.md`:

> A solid marker (pen 6 = both bits) stains its own silhouette plus one pixel
> past its right edge; a **pen-2-only marker stains to the end of the line.**

with the recurrence

```
stain(x) = S(x) | alive(x-1)
alive(x) = stain(x) & ~( E(x-1) & ~S(x) )
```

A stain marker whose **END bit is lost** — pen 6 read as pen 2 — stains from
its own position to the end of the scanline. That is exactly the measured
shape: world-anchored left end, screen-edge right end, growing as it scrolls.

Consistent with this, `docs/mo_priority.md` already records that stain coverage
moved 0.3% -> 3.2% -> 27% across builds 102/105/106 from **memory timing
alone**, and concluded most of the missing stain was *corrupted sprite tile
data*. The same corruption that loses stain elsewhere would drop an END bit
here. The measured artifact rate is highest on BUILD 106 (9.1e-5) — the build
with the highest stain coverage — against 4.3e-5 on 107 and 5.0e-5 on 105.
Different playthroughs, so treat the ordering as suggestive, not proof.

**An RTL fix is therefore possible** — this is our stain/MO path, not the
scaler.

## 5. The gate gap that let this through

`sim/run_mob_tb.sh` passes 100.0000% with `wrong_pen=0`, but its fixture reports
`0 special pixels` and `SHADE pixels=0`. **The gate that would catch a stain bug
has zero stain coverage in its scene.** Any work on this must first build a
fixture containing stain markers, or the gate will keep saying PASS.

## 6. Reproducing

```
MAME=/path/to/mame0289
# native 336x240 frame dump from MAME (screen:pixels() + "336""240" trailer)
$MAME/mame eprom -rompath <romdir> -video none -sound none -nothrottle \
  -skip_gameinfo -autoboot_delay 0 -autoboot_script sim/tools/mame_framedump.lua
# detector + its three controls
python3 sim/tools/dash_detect.py /tmp/pfm/frames.raw
```
