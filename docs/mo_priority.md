# Motion-object vs playfield priority

Before this change the compositor in `core_top.v` was a fixed three-way ladder —
alpha, then motion object, then playfield — so every sprite pixel drew in front
of the playfield. The visible symptom was robots walking *through* scenery that
should hide them: counters, desk fronts and wall edges that the real board draws
over the sprite.

The board decides this per pixel in a PAL/GAL pair feeding the GPC ASIC. This
document records the equations, the bit mapping we derived for our pipeline, and
how both were verified.

## The equations

Verbatim from `reference/eprom.cpp`, `screen_update_eprom()` — the comment
block is marked "verified from the GALs on the real PCB":

```
FORCEMC0 = !PFX3*PFX4*PFX5*!MPR0
         + !PFX3*PFX5*!MPR1
         + !PFX3*PFX4*!MPR0*!MPR1

!SHADE   = !MPX0 + MPX1 + MPX2 + MPX3 + !MPX4*!MPX5*!MPX6*!MPX7 + FORCEMC0

!PF/M    = MPR0*MPR1 + PFX3 + !PFX4*MPR1 + !PFX5*MPR1 + !PFX5*MPR0
         + !PFX4*!PFX5*!MPR0*!MPR1

M7       = MPX0*!MPX1*!MPX2*!MPX3

CRA10 = CL10                (1 if playfield)
CRA9  = SHADE*CL10 + CL9    (1 if motion object, or the shade bank)
```

`PF/M` is 1 when the playfield has priority. The merge then does:

```
if (!pfm && !m7)  pixel = MO pen
else              pixel = PF pen, |0x100 if SHADE, |0x080 if M7
```

and a motion object whose priority has bit 2 set draws nothing at all in this
pass ("upper bit of MO priority signals special rendering", `continue`).

## The bit mapping

This is the part that had to be derived rather than read off, because MAME
expresses `pfpriority` as `(pf[x] >> 4) & 3` on an already-constructed pen.

**Motion object.** `reference/eprom.cpp` `s_mob_config` gives
`{{ 0,0,0x0070,0 }}, // mask for the priority` — word 2, bits 6:4. In
`reference/atarimo.cpp` `render_object()` the pen is built as

```
color = (color * gfx->granularity()) | (priority << PRIORITY_SHIFT);
color += m_palettebase;
```

with `PRIORITY_SHIFT = 12` (`atarimo.h:117`), `granularity() = 16` (gfx 0 is
`pfmolayout`, 4bpp) and `m_palettebase = 0x100`. So

```
MO pen = (mopriority << 12) | 0x100 | (mocolor << 4) | mopix
         MPR2:MPR0            CRA9    MPX7:MPX4        MPX3:MPX0
```

**Playfield.** `get_playfield_tile_info()` sets

```
int const color = 0x10 + (data2 & 0x0f);   // data2 = extmem_read(tile_index) >> 8
tileinfo.set(0, code, color, (data1 >> 15) & 1);
```

gfx 0 is `GFXDECODE_ENTRY("spr_tiles", 0, pfmolayout, 256, 32)` — colour base
256, granularity 16 — so the pen MAME hands the merge loop is

```
PF pen = 256 + (0x10 + c)*16 + pixel = 0x200 | (c << 4) | pixel
         CRA10                          PFX7:PFX4   PFX3:PFX0
```

Therefore, reading the reference's two playfield probes back through that:

| Reference expression | Meaning | Our signal |
|---|---|---|
| `(pf[x] >> 4) & 3` = `PFX5:PFX4` | low two bits of the tile colour attribute | `pf_att[1:0]`, i.e. `pfx_vdata[9:8]` |
| `pf[x] & 8` = `PFX3` | bit 3 of the playfield 4bpp pixel | `pf_pix[3]` |

`pf_att[3:0]` in `core_top.v` is loaded from `pfx_vdata[11:8]` (line ~1768),
which is exactly `data2 & 0x0f`. **The playfield priority bits were already
present in the pixel pipeline** — no extra tile-attribute bits had to be pulled
out of `pfpal_ram`, and no BRAM was widened on the playfield side.

**Independent confirmation from the schematic.** `docs/ARCHITECTURE.md`'s colour
RAM map, taken from Atari SP-332, partitions `3E0000-3E0FFF` as
Alpha `000-1FF`, Motion Object `200-3FF`, Playfield `400-5FF`, Playfield Shadow
`600-7FF`, STAIN `800-FFF` — i.e. pen indices `0x000-0x0FF`, `0x100-0x1FF`,
`0x200-0x2FF`, `0x300-0x3FF`, `0x400-0x7FF`. That matches the pen construction
above exactly, including SHADE landing in the "Playfield Shadow" bank
(`pf |= 0x100`) and `apply_stain` landing in "STAIN" (`pf |= 0x400`). The
schematic outranks MAME in this project's reference hierarchy, and it agrees.

## The rule as implemented

`src/fpga/core/rtl/escape_prio.v` carries the sum-of-products above verbatim.
Two closed forms fall out of them, both machine-checked over the whole input
space (see below):

```
FORCEMC0 == PF/M == !PFX3 && (mo_prio < pf_prio)
MO wins  == (PFX3 || mo_prio >= pf_prio) && !M7
```

So the playfield occludes a sprite exactly when its pixel's bit 3 is clear and
its tile priority is strictly higher than the sprite's. `PFX3` set means "this
playfield pixel never occludes".

Resulting colour RAM index:

```
MO wins  -> 0x100 | mocolor<<4 | mopix
otherwise-> 0x200 | pfcolor<<4 | pfpix, then |0x100 if SHADE, |0x080 if M7
```

### Carrying the priority

`escape_mob.v` now latches `w2[6:4]` into `spr_prio` at `S_MATCH` (it was
previously acknowledged in a comment and discarded). The line-buffer entry grew
from 18 to 20 bits:

```
{fpar, tag[7:0], special, prio[1:0], color[3:0], pix[3:0]}
```

`MPR1:MPR0` ride along for the comparator. **MOSTAIN-1**: `MPR2` — the "special
rendering" flag — rides along too, in the `special` bit. The bit is paid for by
narrowing the line tag from `ly[8:0]` to `ly[7:0]`: one frame spans 240
scanlines, so two lines of the same frame can only collide in `ly[7:0]` if their
`ly` differ by exactly 256, which a 240-line span cannot do; cross-frame
staleness is still caught by `fpar`. The entry therefore stays at 20 bits, a
native M10K geometry (512x20), so this costs **zero extra blocks**. That matters:
the 308-M10K ceiling is documented as fully spent (`escape_core.vhd`).

A special pixel is written like any other, and then:

* it never draws — `disp_valid` requires `special == 0`, so `escape_prio.v` sees
  exactly what it saw before;
* it **owns its column** — `bld_occupied` counts it, so under first-write-wins it
  masks normal sprites beneath it, which is what the reference's single motion
  object bitmap does;
* its pen bits 1 and 2 leave as `disp_stain_s` / `disp_stain_e`, the START and
  END markers `apply_stain` looks for.

Nothing else changed. The fetch budget, SLIP walk, link scout, fetch handshakes
and blit loop are untouched, so MO scheduling and timing are bit-identical to
before — measured: `run_mob_cov.sh` reports the same 215/140/24/117 cycles/line
split for the base and the changed engine on the same scene.

> **PERFDIV-111:** those absolute figures are ~9% high — the bench divided frame
> totals by 240 while accumulating over 262 lines (scale by 240/262 = 0.916 for the
> frame-mean). **The claim made here is unaffected**, because it is an equality
> between two runs through the identical divisor, and the point is that the two
> splits are the *same*, not what they are.

## What is approximated

**`apply_stain` and special-sprite masking used to be omitted here; both are
now implemented (MOSTAIN-1).** See "The stain pass" below.

**`FORCEMC0`'s colour-clearing arm is omitted.** Because `FORCEMC0 == PF/M`, the
signal is never asserted on the branch where the motion object wins, so the
reference's `mo & DATA_MASK & ~0x70` case is unreachable. The equivalence is
proved exhaustively rather than assumed; `escape_prio.v` still exports
`forcemc0` so the benches check it.

## Verification

**Exhaustive, against the spec.** `sim/tb/tb_prio.v` sweeps every input
combination of the comparator (2 x 4 x 16 x 16 x 16 x 16 = 524,288 rows) and
`sim/tools/check_prio.py` replays them through `sim/tools/mo_priority_model.py`,
a literal Python transcription of the equations and the merge loop.

```
$ ./sim/run_prio_tb.sh
rows compared : 507904
agreement     : 507904/507904 = 100.0000%
PRIO CHECK PASS: RTL comparator matches reference/eprom.cpp exactly
```

(The 16,384 skipped rows are `mo_valid=1` with `mo_pix=0`, which the line buffer
cannot produce — pen 0 is transparent and never written.)

**Scene replay, against a real frame.** `sim/tb/tb_mob.v` runs the real
`escape_mob.v` over MO/SLIP RAM dumped from a live MAME gameplay frame, models
the playfield from the same frame's tile maps at the same scroll, and feeds both
into `escape_prio.v`, logging every decision input and the layer that won.
`sim/tools/check_mob_prio.py` replays that log through the same Python model.

```
$ XSCROLL=224 YSCROLL=421 ./sim/run_mob_tb.sh
MO-covered pixels in the replayed frame : 11117
agreement with reference model          : 11117/11117 = 100.0000%
layer census : MO drawn=10707  occluded by playfield=410
MO priority histogram (MPR1:MPR0) : {1: 2068, 2: 1321, 3: 7728}
```

(These counts read 15127/14083/1044 when this was written; that run was at
the bench's DEFAULT scroll, not the scene's — MOPLACE-0. The comparator's
agreement with the reference model is 100% either way, which is what this
bench checks.)

**Screenshot, against MAME.** `sim/tools/render_scene.py` renders the dumped
frame and diffs it against MAME 0.289's own snapshot of that exact frame:

| composite rule | exact-RGB match vs MAME |
|---|---|
| old (MO always in front) | 79419/80640 = 98.49% |
| new (priority comparator) | 80147/80640 = **99.39%** |

(both with `--mo-source mame`, so the comparator is judged on its own. With
the RTL's own MO layer the same two rules read 96.45% and **96.95%** — see
`docs/mo_placement.md` for where the remaining 2.4 points go.)

The 493 remaining pixels are one sprite — a single motion object whose entry the
game updates outside the vblank handler, so it is one animation step ahead in the
dump. No mismatch anywhere else in the frame.

## Reproducing

Capturing a frame needs MAME 0.289 and the autoboot script referenced below;
both live outside the repo.

```bash
# 1. dump a frame's video state + MAME's snapshot of it
#    (scenedump2.lua takes the PREVIOUS frame's RAM: eprom is
#     VIDEO_UPDATE_BEFORE_VBLANK, so a frame notifier already sees the next
#     frame's MO RAM. Skipping this costs ~37% of the pixel match.)
SCENE_OUT=<dir> SCENE_IDX=108 ./mame eprom -rompath <roms> \
    -video none -sound none -seconds_to_run 102 -autoboot_script scenedump2.lua

# 2. turn it into bench fixtures
python3 sim/tools/make_scene_hex.py <dir> sim/work

# 3. replay through the RTL and check the decisions
XSCROLL=224 YSCROLL=421 ./sim/run_mob_tb.sh

# 4. render + diff against MAME's snapshot
python3 sim/tools/render_scene.py <dir>                    # RTL MO layer
python3 sim/tools/render_scene.py <dir> --mo-source mame   # isolate the rule
```

`--mo-source mame` swaps in `sim/tools/mame_mo_model.py`, a Python port of
`atari_motion_objects_device::draw()`, so that the priority rule can be judged
without the line engine's own fidelity (fetch budget, links per line) in the way.

> **Corrected.** This section originally reported that the RTL's own MO layer
> matched MAME on only ~50% of pixels and blamed the fetch budget. Both halves
> were wrong. The bench was not running at the scene's scroll at all — see
> `docs/mo_placement.md`, MOPLACE-0: `sim/run_mob_tb.sh` passed
> `-PXSCROLL=224`, and iverilog ignores that spelling without a warning. With
> the scroll applied and the two placement bugs found underneath it fixed, the
> RTL layer scores 96.95% on this frame, and the fetch budget turns out not to
> be the limiter at all (raising it from 62 to 4000 changes nothing).

## Resource impact

| | before | after |
|---|---|---|
| `escape_mob` line buffers | 2 x 512 x 18 | 2 x 512 x 20 |
| M10K blocks | 2 | 2 |

512x20 is a native M10K simple-dual-port geometry, so the two extra bits per
entry are free. **M10K delta: 0.** The comparator itself is ~20 LUTs of
combinational logic feeding the already-registered `color_vaddr`, replacing a
3-way mux on the same path — no new pipeline stage, no timing risk.


## The stain pass (MOSTAIN-1)

`screen_update_eprom` ends with a pass it introduces as *"now go back and process
the upper bit of MO priority"*: for every motion-object pixel whose priority has
bit 2 set **and** whose pen has bit 1 set, it calls `atarimo::apply_stain`, which
ORs `0x400` into the **finished picture** — after the MO/PF merge and after the
alpha tilemap — from that X rightwards until an end marker.

```c
// reference/atarimo.cpp
const uint16_t START_MARKER = ((4 << PRIORITY_SHIFT) | 2);
const uint16_t END_MARKER   = ((4 << PRIORITY_SHIFT) | 4);
bool offnext = false;
for ( ; x < bitmap.width(); x++) {
    pf[x] |= 0x400;
    if (offnext && ((mo[x] == 0xffff) || (mo[x] & START_MARKER) != START_MARKER))
        break;
    offnext = (mo[x] != 0xffff) && ((mo[x] & END_MARKER) == END_MARKER);
}
```

That `0x400` is colour-RAM bit 10 — the top half of the 2048-entry colour RAM the
core has always addressed (`color_vaddr` is 11 bits) and never used. **The
FACTORY MAP inter-level screen's route markers are drawn entirely by this pass**:
the "you are here" cube is a special sprite over an ordinary playfield block, and
the grey cube MAME shows is that block re-read out of the stained bank. Without
the pass the screen renders the raw un-recoloured art instead.

### Why one flip-flop is enough

The C loop restarts at *every* marker pixel, so what a scanline pipeline has to
produce is the union of those walks. With

* `S(x)` = "special pixel here whose pen has bit 1" (START_MARKER), and
* `E(x)` = "special pixel here whose pen has bit 2" (END_MARKER),

a walk that has reached `x-1` continues into `x` unless it broke, and it breaks
at `x` exactly when `E(x-1) && !S(x)`. Since `pf[x] |= 0x400` happens *before*
the break test, the breaking pixel is still stained. That collapses to

```
stain(x) = S(x) | alive(x-1)
alive(x) = stain(x) & ~( E(x-1) & ~S(x) )
```

i.e. two flip-flops (`alive`, and `E` delayed by one pixel), cleared at the start
of each line. A solid marker (pen 6 = both bits) stains its own silhouette plus
one pixel past its right edge; a pen-2-only marker stains to the end of the line.
Both match the C loop exactly. `core_top.v` runs this immediately before the
colour-RAM address register, so the OR lands after alpha — where the reference
puts it.

### Measured

Scenes are dumped from MAME with `sim/tools/scenedump2.lua` (or the poking
variant in the session scratchpad) and replayed through the real RTL by
`sim/run_mob_tb.sh`, then scored against MAME's own snapshot of the same frame by
`sim/tools/render_scene.py`. `sim/tb/tb_mob.v` writes the special pass's pixels
to `sim/build/mob_special.txt`, and `render_scene.py --no-stain` reproduces the
old behaviour for A/B.

| scene | before | after |
|---|---|---|
| FACTORY MAP inter-level screen | 80440/80640 = **99.75%** | 80640/80640 = **100.00%** |
| same, marker widened to 8x8 tiles (5029 stained pixels) | 79681/80640 = **98.81%** | 80640/80640 = **100.00%** |
| gameplay 79/162 | 98.24% | 98.24% |
| gameplay 126/294 | 100.00% | 100.00% |
| gameplay 337/173 | 99.38% | 99.38% |
| gameplay 290/128 | 98.22% | 98.22% |

The four gameplay frames contain no special sprites and are bit-identical either
way (same MO pixel counts, same `MOB PRIO CHECK` 100.0000%), which is the
regression guard: the tag narrowing and the entry-layout change move nothing.

### Masking

To exercise the masking half — which needs specials *overlapping* normals, a
state the game only reaches on screens the bench cannot drive to — every third
live list entry of a crowded gameplay frame was flipped to MPR2 in MAME, and MAME
asked to render it. The engine is then scored against MAME's own frame:

| scene | engine px | pixels given to the wrong sprite | exact-RGB |
|---|---|---|---|
| 126/294, every 3rd entry special — before | 7493 | **606** | 54661/80640 = 67.78% |
| 126/294, every 3rd entry special — after | 6885 | **0** | 80640/80640 = **100.00%** |
| 291/128, every 2nd entry special — before | 7275 | **244** | 60691/80640 = 75.26% |
| 291/128, every 2nd entry special — after | 7008 | **0** | 79330/80640 = 98.38% |

`sim/run_mob_cov.sh` on the same state scores the base engine at **608 spurious
pixels** against its own golden model and the changed engine at **0**, with an
identical 215/140/24/117 cycles/line split — the masking is free. (PERFDIV-111:
those absolute numbers are ~9% high; the *identity* between the two runs, which is
the actual claim, is unaffected.)
(`sim/tools/mob_golden.py` was updated in the same change: special pixels claim a
column without drawing in it. An oracle that has drifted from the engine it
scores is this project's fourth recorded measurement bug.)

## MOSTAIN-2: the stain pass is under-applied on hardware

BUILD 105 shipped the pass above on the 99.75% -> **100.00%** row in that table.
On a real Pocket it **does fire** — the START marker really does go grey — but
it covers only a fraction of the marker.

### What hardware actually does

Diffing the FACTORY MAP screen between BUILD 102 and BUILD 105 captures,
sampled back down to native resolution (3x3 average per native pixel, to beat
the H.264 blur in a 1920x1080 capture):

```
native pixels changed 102->105 : 34 over 6 rows
  y=168 n=4  x=37,38,39,53
  y=169 n=8  x=37,38,39,40,41,51,52,53
  y=170 n=8  x=39,40,41,42,43,49,50,51
  y=171 n=8  x=41,42,43,44,45,47,48,49
  y=172 n=5  x=43,44,45,46,47
  y=173 n=1  x=45
```

Every changed pixel is inside the marker, and the change is orange -> genuine
grey (R~=G~=B). For comparison, the same measurement on MAME's own frame — the
render with `apply_stain` diffed against `--no-stain` — is:

```
MAME-model VISIBLE stain changes: 200 px over 16 rows   (y=158..173)
```

So hardware converts **34 of ~200**, all of it in rows 168..173, in two runs
per row that converge downward. Rows 158..167 are untouched.

### What that rules out

* **"The game never writes the upper colour bank."** Dead. Grey pixels appear
  at all, so bit 10 reaches `color_vaddr` and the upper bank is populated with
  the right greys by the game itself. (Independently: MAME's `m_paletteram` is
  plain RAM at `$3E0000` with no initialiser, and the FACTORY MAP dump has 118
  non-zero upper-bank words. The greys resolve to entries **1537, 1538, 1539,
  1547, 1549, 1550**, all `0xF888` — exactly `0x400 | 0x201/2/3/B/D/E`, the
  block's playfield pens with bit 10 set. Six pens mapping to one grey is why
  a stained block goes flat rather than shaded.)
* **"Specials never reach the line buffer"** and **"the pen is not 11 bits
  end-to-end."** Both dead for the same reason.
* **"The scanline automaton does not match the C loop."** Dead, and measured
  rather than argued. Replaying the RTL's own 296 special pixels
  (`sim/build/mob_special.txt`) through both the C `apply_stain` union and the
  Verilog recurrence gives **320 stained pixels each, with 0 lines differing**.
  Every special on this screen is pen 6, i.e. `S` and `E` both set.
* **Fetch latency.** `tb_mob` at `GFX_LAT` 8/16/24/31 reports **296 special
  pixels at every latency** — the bench cannot reproduce the shortfall, because
  its gfx model is dedicated and this scene contains exactly one sprite. Real
  SDRAM contention with the CPUs and the playfield is modelled nowhere.

The marker is a single MO entry: every slip band's pointer is `0x0001`, a 3x3
tile special sprite at depth 0 of a one-entry list, spanning rows 150..173.

### BUILD 106: the shortfall was mostly MEMORY TIMING, and the "100%" target was wrong

BUILD 106 changed **no graphics RTL** — the stain path is byte-identical to 105.
It corrected two constants derived from a wrong `clk_sdram` figure (35.795455
MHz, not 85.909): the PSRAM controller's wait states, and an SDRAM refresh
interval that was **out of spec against the 7.8125 us JEDEC retention limit** on
the memory holding sprite graphics.

> **REFRESH-111:** the "8.33 us" quoted here was itself hand arithmetic
> (`INTERVAL + DEFER_CAP`) and understated the violation. Measured against the real
> FSM the original policy's worst case is **8.772 us** — the formula omits the
> transaction still in flight when the deferral cap expires. The conclusion (out of
> spec) was right; the number was optimistic. See `sim/run_sdram_refresh_tb.sh`.
Stain coverage went 0.3% -> 3.2% -> 27% across 102/105/106. An 8.4x change from
memory timing alone says most of the missing stain was **corrupted sprite tile
data**, not a compositor fault.

**The remaining gap is much smaller than it looked, because the target was
wrong.** The marker *blinks*, 10 frames on / 10 frames off, and MAME blinks
identically. Measuring the same 32x23 box, same grey threshold, in the same
blink phase:

| | grey / lit | share |
|---|---|---|
| MAME **phase A** (grey hexagon) | 195 / 292 | **66.8%** |
| MAME **phase B** (coloured cube) | 0 / 292 | **0.0%** |
| hardware 102 | 1 / 292 | 0.3% |
| hardware 105 | 17 / 292 | 5.8% |
| hardware 106 | 179 / 292 | **61.3%** |

MAME never stains the whole box — it also contains the neighbouring blue
canal-maze block and the "START" text, which are never stained. **66.8% is the
ceiling, and BUILD 106 is at 61.3% of 292, a residual of ~16-21 pixels.** Any
comparison that does not match the blink phase is meaningless: a phase-B frame
should contain *no* grey at all, so grey measured there is excess, not
shortfall.

Aligning the two grey masks (best fit `dx=0, dy=0`, overlap 174/195) the
residual is systematic and one-sided:

```
 y    MAME span      HW106 span     dLeft dRight
163   34..52(19)     36..53(18)      +2    +1
164   34..52(19)     36..53(18)      +2    +1
165   34..51(18)     36..51(16)      +2    +0
166   34..51(18)     36..51(16)      +2    +0
167   34..51(18)     36..51(16)      +2    +0
168   34..51(18)     36..51(16)      +2    +0
169   34..51(18)     35..51(17)      +1    +0
171   38..47(10)     40..47( 8)      +2    +0
```

21 pixels are MAME-grey but not hardware-grey, almost all in columns 34-35 and
along the lower-left diagonal; 6 are hardware-grey but not MAME-grey, all on
the right edge. **Each row's stain starts 1-2 pixels late and ends on time.**

### Which candidate explains the residual

* **(d) "the whole silhouette should convert" — WRONG, and it was the biggest
  error.** MAME stains 66.8% of that box, not 100%. Quantify the reference
  before calling something a shortfall.
* **(a) ownership vs coverage — REFUTED.** MAME's `apply_stain` also reads a
  single MO bitmap, so it is ownership-based too; and every slip band on this
  screen points at the same **one-entry** list, so there is nothing that could
  overdraw the special.
* **(b) automaton terminating runs early — REFUTED, measured.** Replaying the
  RTL's own 296 special pixels through the C loop and the recurrence gives
  **320 stained each, 0 lines differing** (`check_stain_automaton.py`).
* **(c) residual data corruption — not excluded, but unlikely to be all of
  it.** The residual is a systematic edge, not random pixels.

That leaves a **1-2 pixel right-displacement of the stain relative to the
playfield**, which is exactly the class of bug no bench here can see:
`tb_mob.v` explicitly compensates the registered line-buffer read with
`pf_sx = visible_x - 1`, and `core_top.v` — where the stain and the colour
address actually live — is in no bench at all. **Do not ship a one-pixel shift
on this evidence:** the same capture shows gameplay frames matching MAME at
**0 differing pixels**, which says the MO layer as a whole is correctly
aligned, so a global shift would break more than it fixes. Bench the
compositor first (see "Still outstanding"), and note that H.264 ringing at a
high-contrast edge is itself worth +-1 px of the measurement.

### What is still open

Why only ~17% converts. The counters below are built to answer exactly that,
because nothing on a workstation can: the shortfall does not reproduce in any
bench we have, and the hardware capture is a different moment of the attract
loop from the dumped scene (the block art sits ~3px right and one row lower),
so per-pixel comparison against the dump is not sound.

### Why the 100.00% never had a chance of catching this

Three things, none of them the shipped code:

1. **`render_scene.py` composites in Python.** The MO/PF merge, the alpha layer
   and `apply_stain` in that script are its own re-implementation. The
   automaton that ships is in `core_top.v`, and `sim/run_mob_tb.sh` compiles
   only `escape_mob.v` and `escape_prio.v`. **`core_top.v` is in no testbench.**
2. **On that scene both RTL gates were inert.** Re-running the BUILD 105
   command verbatim:

   ```
   TB_MOB DONE: 0 pixels, 216 gfx reqs, 296 special pixels
   MO-covered pixels in the replayed frame : 0
   agreement with reference model          : 0/0 = 0.0000%
   MO fixture holds no scene - refusing to score
   exact-RGB match vs MAME (new rule): 80640/80640 = 100.00%
   ```

   `MOB PRIO CHECK` printed **no verdict** and still exited 0; `mob_vs_mame.py`
   **refused to score**. The only surviving number came from the Python.
3. **The zero was legitimate, which is what made it invisible.** MAME's own MO
   model draws 296 pixels on that screen and *every one is special* — the
   FACTORY MAP has no drawable motion objects. The RTL produced exactly 296
   specials and 0 drawable, i.e. it was **right**. A correct engine, a correct
   scene, and a gate that measured nothing.

Even a perfect score there could only have told us the Python agreed with MAME
on a frame whose stain the Python applied. Coverage on silicon was never in it.

### The diagnostic (HUD page 4)

`dbgmode` is now 3 bits and R cycles five pages. Page 4 measures coverage:

| field | contents | MAME truth on the FACTORY MAP |
|---|---|---|
| 1 | stained pixels this frame (16-bit, saturating) | `0140` (320) |
| 2 | special (MPR2) pixels carrying a START/END marker bit (16-bit, saturating) — the same quantity `tb_mob` prints as "special pixels" | `0128` (296) |
| 3 | `{first, last}` scanline carrying a stained pixel | `96AD` (150..173) |

**Field 3 measures where the stain is APPLIED, not where it is VISIBLE**, and on
this screen those differ sharply. The specials span rows 150..173, but rows
150..157 lie over black background where staining changes nothing — MAME's own
visible change is rows 158..173 (200 px) and hardware's is rows 168..173
(34 px). A field3 of `96AD` alongside a full field1 therefore means coverage is
*correct* and the shortfall is in the palette. Do not read field3 against the
six rows the capture shows.

Field 3 is its own liveness witness: `ln_first` resets to `FF` and `ln_last` to
`00`, so a live counter that stained nothing reads **`FF00`**, and **`0000` is
impossible** unless the counter never ran. Read the three together:

| reading | conclusion |
|---|---|
| field3 `0000` | counter never ran — the page means nothing, stop |
| field3 `FF00` | alive, nothing stained this frame |
| field2 `<< 0128` | specials are not reaching the line buffer — `escape_mob` / tile fetch under real SDRAM contention, which no bench models |
| field2 `~0128`, field1 `<< 0140` | specials arrive but runs die early — the automaton or its S/E derivation |
| field2 `~0128`, field1 `~0140`, field3 `96AD` | the compositor applies the stain exactly where MAME does; the shortfall is downstream of `color_vaddr` — the upper bank holds different values here than in MAME for the pens that did **not** turn grey. Grey appearing at all does not refute this: it proves the bank is written for *some* pens, not for all of them. |

Field 3 names the shape independently: a span much shorter than `96AD` with
field2 near `0128` means whole scanlines are dropped rather than runs truncated.

### Gate hardening

The measurement bug is now mechanical rather than remembered — the project's
*ninth* recorded instance:

* `check_mob_prio.py`: `total == 0` is a **VACUOUS failure** (exit 1). It used
  to print no verdict and return 0.
* `mob_vs_mame.py`: judges the **reference output**, not a byte heuristic over
  MO RAM (the old guard called the FACTORY MAP "no scene" while the reference
  was drawing 296 pixels of it). Empty reference -> refuse to score; empty
  engine against a non-empty reference -> **FAIL** instead of falling through
  to `wrong == 0` = PASS. Specials are excluded from the drawable comparison,
  since `tb_mob` logs them to a different file.
* `render_scene.py`: every exact-RGB line now states that the compositor and
  `apply_stain` above it are Python and that `core_top.v` is not exercised at
  any percentage.
* `sim/tools/check_stain_automaton.py` (new) replays the RTL's own
  `mob_special.txt` through both the C `apply_stain` union and the scanline
  recurrence and fails on any per-line difference; an empty input is a VACUOUS
  failure, not a pass. It is **not** wired into `run_mob_tb.sh`, because the
  canonical gate scene contains no special sprites — run it on a scene that
  has them:

  ```
  ./runscene.sh <factory-map-scene> <worktree>
  python3 sim/tools/check_stain_automaton.py
  ```

  Its own docstring states the limitation plainly: the recurrence in it is a
  *transcription* of the one in `core_top.v`, not the shipped instance, so it
  cannot catch a divergence introduced in `core_top.v` itself.

### Resource check: NOT MEASURED in this session

The M10K delta for the HUD page was **not** measured. Quartus 18.1 runs under
x86 emulation on this ARM machine at roughly 60+ minutes for a full compile and
30+ minutes for Analysis & Synthesis alone; neither the base nor the changed
tree finished. Saying so rather than quoting a number is the point of this
whole document.

The static argument is strong but it is an argument, not a measurement: the
change declares **only scalar registers** —

```
reg [15:0] stain_px, stain_px_fr, spc_px, spc_px_fr, lnspan_fr;
reg [ 7:0] ln_first, ln_last;
```

— and no array of any kind, and Quartus can only infer block RAM from an array
indexed by a variable. It also *removes* the last consumers of `cst0_px` /
`cst1_px` and the CRAM-sum path, which can only reduce logic. Expected M10K
delta is therefore 0, but **confirm it before flashing**:

```bash
docker run --rm --platform linux/amd64 \
  -v <worktree>:/work -v <repo>/third_party:/work/third_party:ro -w /work/src/fpga \
  theypsilon/quartus-lite-c5:18.1 \
  bash -c "quartus_sh --flow compile ap_core"
grep -iE "M10K|block memory" src/fpga/output_files/ap_core.fit.rpt
```

and diff that against the same grep on `origin/tas-atomic`. The design sits at
the 308-M10K ceiling, so a single newly inferred block fails the fit outright.

### Still outstanding

**Extract the stain automaton from `core_top.v` into its own module** so that
the thing under test is the thing that ships. Every check in this section
either exercises a Python model or a transcription; `core_top.v` remains
uncompiled by any bench, which is the structural reason BUILD 105 could score
100% and under-apply on silicon. Until that is done, the HUD page above is the
only instrument that observes the shipped compositor at all.
