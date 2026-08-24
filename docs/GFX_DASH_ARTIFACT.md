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

## 7. Independent confirmation: the killed-playfield capture

`nz/vdbg.raw` (1145 frames) is the RT debug view: flat background
`rgb(75,110,106)`, the alpha layer, and the black index-0 playfield silhouette.
Anything else on that background is unambiguous.

Two cautions first, both learned the hard way in this session:

* A naive "non-background pixel" scan returns **1,496 stray pixels** on frames
  892-903. Those are the **"Tap JUMP to speed up" alpha banner** — legitimate
  game content. Alpha-layer text is the third thing (after our hex bar and the
  status line) that an automated stray-pixel detector will rediscover.
* HUD rows must be excluded **with margin**: status `0-11`, hex bar `96-128`,
  game HUD `192-239`.

What survives both: a small cluster of genuinely black pixels at **native rows
35-40, x 222-227** on frame 900. The flat background sums to 291 across RGB
(75+110+106); those pixels sum to **2, 8, 12, 13, 15, 17**. Compression noise
around a 291 background does not produce 2.

Their persistence against frame 892, for frames 892-903, is

```
1 0 1 0 1 0 1 0 1 0 1 0
```

i.e. **exactly a 2-frame alternation** — identical on even offsets, different
on odd. This is the same 30 Hz parity toggle measured independently in
`nz/v107b.raw` frames 68-73, and it is decisive against corrupt data at rest.

So in a mode where the playfield is disabled, **pen-0 pixels still reach the
screen, on a flat background, toggling with frame parity**. Combined with
section 3(c) — one end world-anchored, the other pinned to the end of the
scanline — the surviving mechanism is the MO/stain path, not playfield tile
data and not the scaler.

## 8. Task 2 note: what BUILD 107 actually runs at

`sim/tools/read_hud.py` over 173 cleanly decoded HUD frames of the BUILD 107
capture (t=30-118 s), HUD page 0:

| | BUILD 107 measured | MAME 1P reference | ratio |
|---|---|---|---|
| video CPU bus cycles/frame | **22,203** (p10 21,673 / p90 22,820) | 25,630 | **0.866** |
| extra CPU bus cycles/frame | **20,509** (p10 19,201 / p90 22,681) | 22,244 | **0.922** |

This reproduces the BUILD 106 figures (22,233 / 20,340) to **-0.1% on the video
CPU and +0.8% on the extra CPU**.

**That answers the open question about the refresh change directly: BUILD 106's
250 -> 160 refresh threshold, which raised refresh occupancy from 4.4% to 6.9%,
cost the CPUs nothing measurable.** There is no case for touching it back, and
doing so would re-open a genuine JEDEC retention violation.

## 9. GFXDASH-3: the gate, and what it found

Section 5 said any work on this must first build a fixture containing stain
markers. That is `sim/run_stain_tb.sh`, and it changed the answer.

### The gate

Two gaps let this artifact through eleven passing checks:

* `sim/run_mob_tb.sh`'s fixture reports **0 special pixels**, so the only gate
  that could have caught a stain bug had no stain in its scene;
* the apply_stain automaton lived **inline in `core_top.v`**, a file no sim
  script compiles, so `sim/tools/check_stain_automaton.py` tests a
  *transcription* of it rather than the shipped instance.

Both are closed. `src/fpga/core/rtl/escape_stain.v` is the automaton, extracted
from `core_top.v` verbatim — same two flip-flops, same reset value, same clear
condition, same equations — and instantiated by `core_top.v` and by
`sim/tb/tb_stain.v`, so the bench drives the gates that ship. Pure logic, M10K
delta structurally zero.

`sim/tools/make_stain_scene.py` builds a six-frame scene whose markers' START/END
pen bits and screen extents are *chosen*, not discovered, and computes the
reference answer with `reference/atarimo.cpp`'s own `apply_stain` loop over the
motion-object bitmap `reference/eprom.cpp` would have produced. The bench diffs
both the stained columns and the drawn MO pixels, and refuses to certify a run
with no markers, no stained pixels, or a short frame count.

**It was verified able to fail, on the real RTL, before it was trusted:** against
BUILD 107 it reports 226 mismatching pixels.

One thing the scene design had to get right, and got wrong first. A marker drawn
entirely in pen 6 carries **both** bits on every pixel, so however many of its
pixels go missing the automaton still breaks one pixel past whatever survives —
it can never run to the end of the line. The unbounded mode needs a START run
with no END bit in it: a pen-2 body terminated by a **separate** pen-6 column.
Losing that terminator is what turns a bounded stain into a stain that reaches
the last screen column. Section 4's "a marker losing its END bit" is right, but
it has to be the *terminator marker*, not just any of the marker's pixels.

### The bug

The line-buffer staleness tag is `{fpar, ly[7:0]}` and **`fpar` is one bit**, so
it separates this frame from last frame and from nothing else. An entry written
**two** frames ago carries this frame's parity; if nothing rewrote that column in
that buffer since, it reads back live. LANE4q fixed the one-frame ghost and left
the two-frame ghost, at half the rate and flickering at 30 Hz — which is exactly
the 2-frame parity measured in sections 3(c) and 7 and independently in the
killed-playfield capture.

It costs pixels twice over:

* the stale entry **displays** — a sprite in two places at once;
* it satisfies `bld_occupied`, so a live sprite arriving at that column has its
  write **refused by a ghost**.

When the refused write is the stain's END terminator, the automaton never sees
it and the stain runs from the marker's world-anchored left edge to the last
screen column. Bench case E, frame 3: **`x 265..335` against a reference that
stops at 264.** One end anchored to world content, the other pinned to x=335, is
the signature measured in section 3(c) to the pixel.

Note what the bench also shows about *when* a ghost can bite. A stale entry only
survives if nothing rewrites that column in that buffer in between — the two
buffers are shared by every line they serve, so the last line to write a column
owns it. A stationary object overwrites its own stale pixels and is immune; the
hazard is a sprite **arriving** at a column it did not occupy last frame, which
is what every moving object in the game does, and which is why the artifact is
intermittent rather than constant.

### The fix

Self-clearing readout — what the real MOHLB does, and what LANE3n's own comment
says it does instead of tagging. While a buffer is being displayed its write port
is idle, because blit writes go to the other one; writing zero there costs no
port, no block and no cycle, and an all-zero entry is unrepresentable as a hit.
Buffers alternate every line, so each is cleared during the line immediately
before it is built: every build starts empty, and staleness is impossible by
construction rather than by an argument about tag width.

Widening the tag was not available. The entry is 20 bits, which is exactly the
native 512x20 M10K geometry; a 21st bit doubles both line buffers.

### Evidence, and its limits

| | |
|---|---|
| `sim/run_stain_tb.sh` | 226 mismatching px before, **0 after** |
| `sim/run_mob_tb.sh` | 10047/10047 = 100.0000%, `wrong_pen=0` |
| `sim/run_mob_order_check.sh` | `b_shorter=0` on all four cells |
| `sim/run_prio_tb.sh` | 507904/507904 |
| `sim/run_psram_tb.sh` | PASS, negative control rejected |
| CI fit | 0 errors — the 308-M10K ceiling is the gate, so this is the M10K delta-0 evidence |
| CI timing | all 64 clock/corner rows non-negative; worst setup **+4.572 ns**, worst hold **+0.124 ns** (BUILD 107: +5.197 / +0.118) |

The 0.625 ns of setup slack is a real number and it is reported rather than
explained away — but it is **two builds**, and Quartus seed variance on this
design is of that order, so it should not be attributed to this change without a
repeat build. Both are comfortably positive and the gate passes.

**What still needs the owner's hardware.** Whether this is the whole of the
artifact they see. Everything above is simulation and CI. The mechanism
reproduces the measured signature exactly — world-anchored left end, right end
pinned to the last screen column, 2-frame parity — but "reproduces the
signature" is not "is the only cause of it", and the FACTORY MAP residual
documented in `docs/mo_priority.md` (a systematic 1-2 px right-displacement) is a
separate, still-open question that this change does not address.
