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
{fpar, tag[8:0], prio[1:0], color[3:0], pix[3:0]}
```

Only `MPR1:MPR0` ride along. `MPR2` — the "special rendering" flag — is resolved
at write time instead: `S_BLIT` suppresses the line-buffer write when
`spr_prio[2]` is set, which is precisely what the reference's first pass does
with `continue`. This keeps the entry at 20 bits, a native M10K geometry
(512x20), so the widening costs **zero extra blocks**. That matters: the
308-M10K ceiling is documented as fully spent (`escape_core.vhd`, "the 308-M10K
ceiling is spent").

Only `wr_en` is gated. The fetch budget, SLIP walk, ring traversal, A/B fetch
handshakes and blit loop are untouched, so MO scheduling and timing are
bit-identical to before.

## What is approximated

**The second MAME pass (`apply_stain`) is not implemented.** After the alpha
layer is drawn, the reference walks the frame again and, for motion objects with
`mopriority & 4` *and* pen bit 1 set, ORs `0x400` into the playfield pen from
that X to the end of the line (or to a matching end-marker sprite), selecting the
STAIN colour bank. This is a horizontally-propagating, order-dependent effect
computed after the whole frame exists; a scanline pipeline that emits a pixel
per clock has no second pass to run it in.

Consequence: screen-wide "stain" tints (the wipe/flash effects the game builds
out of marker sprites) do not appear. This is not a regression — the old
compositor never addressed pens above `0x2FF` at all, so the STAIN bank
(`3E0800-3E0FFF`) was already unreachable. What *does* change for those sprites
is that they no longer draw as opaque blocks: previously a special sprite's
pixels were composited like any other MO pixel, which is wrong in the reference
too. Implementing stain properly would need a per-line "stain active from X"
latch driven by marker sprites during the line build; that is a scheduling
change and was deliberately left out of this one.

**A special sprite no longer masks a normal sprite underneath it.** The
reference keeps one MO bitmap: if a special object is drawn over a normal one,
that pixel's value *is* the special one, so the merge skips it and the playfield
shows through — the special sprite punches a hole in whatever MO pixel it
covered. We resolve MPR2 at line-buffer write time instead, so the special
sprite's pixels are simply never written and the normal sprite underneath
survives. The two differ only where a special object overlaps a normal one.
Special objects are rare (12 list entries across a 150-second attract+demo
capture), and holding MPR2 in the buffer to reproduce the masking would cost a
21st bit per entry — which does not fit the 512x20 M10K geometry and would
double the line-buffer block count. Not worth it at the current ceiling.

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
