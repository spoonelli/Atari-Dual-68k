# Where motion objects land

Sprites were misplaced whenever the world scrolled. This document records the
placement rule as the reference defines it, the three things our engine was
doing differently, and the per-scene agreement before and after.

Companion to `docs/investigations/mo_priority.md`, which covers what happens to a sprite pixel
*after* it has been placed.

## The rule

`reference/atarimo.cpp` is the device MAME actually instantiates for this game;
`reference/eprom.cpp`'s `s_mob_config` supplies the constants. For eprom the
motion-object bitmap is 512x512, SLIP bands are 8 pixels tall with no offset,
entries are linked, and **entries render in reverse order**.

`draw()` walks SLIP bands and gives each band a clipping rectangle:

```
startband = ((cliprect.top()    + yscroll) & 0x1ff) >> 3
stopband  = ((cliprect.bottom() + yscroll) & 0x1ff) >> 3
if (startband > stopband) startband -= 512 >> 3

bandclip.min_y = ((band << 3) - yscroll) & 0x1ff
if (bandclip.min_y >= bitmap.height()) bandclip.min_y -= 512
bandclip.set_height(8)
bandclip &= cliprect
```

`render_object()` then places one entry:

```
xpos = xfield - xscroll                     // xfield = w2[15:7], 9 bits
ypos = -yfield - yscroll - (height << 3)    // yfield = w3[15:7], height = (w3&7)+1
xpos &= 0x1ff;  if (xpos >= bitmap.width())  xpos -= 512
ypos &= 0x1ff;  if (ypos >= bitmap.height()) ypos -= 512
```

and blits `width x height` 8x8 tiles from `code + ty*width + tx`, hflip
mirroring both the tile order and the pixels within a tile.

### How much of that a per-line engine already gets for free

`escape_mob.v` builds one scanline at a time rather than walking bands, so two
of the reference's steps are structurally satisfied and need no code:

**The per-band clip is implicit.** Screen line `v` is inside `bandclip(b)`
exactly when `((v + yscroll) & 0x1ff) >> 3 == b`. Proof: `bandclip(b)` covers
`min_y .. min_y+7` with `min_y = ((b<<3) - yscroll) & 0x1ff`, so `v = min_y + k`
for `k` in `0..7` gives `(v + yscroll) & 0x1ff = (b<<3) + k`. The engine picks
its band as `ly[8:3]` with `ly = (v + yscroll) & 0x1ff`, which is that same `b`,
and it draws only onto line `v`. A band whose `min_y` unwraps to a negative
value is one no screen line maps to, and MAME's `bandclip &= cliprect` empties
it — the two agree.

**Both "unwrap into view" steps are implicit**, because the engine works in
differences rather than in absolute unwrapped coordinates.

*Vertically*: the reference's row index is `v - ypos_unwrapped`. The engine
computes `ydiff = (ly + yfield + (height<<3)) & 0x1ff` and accepts the entry
when `ydiff < height<<3`. Since `ypos_unwrapped ≡ -yfield - yscroll -
(height<<3) (mod 512)` and the unwrap only ever subtracts one whole 512, the
mod-512 difference *is* the row index in both the wrapped and unwrapped cases —
the `-= bitmapheight` cancels out of a difference taken mod 512.

*Horizontally*: the engine computes each tile's start as
`blit_x = (xfield + tile_offset - xscroll) & 0x1ff` and then increments
`blit_x` mod 512 across the 8 pixels. A tile the reference places at, say,
`sx = -4` (because `xpos` unwrapped from 508) is placed by the engine at 508,
whose pixels 4..7 wrap to x=0..3 — the same four pixels of the same tile at the
same screen positions. Off-screen tiles land at write addresses the display side
never reads.

So x placement and the band walk were already right, and stayed untouched.

## What was actually wrong

### 0. The bench was not testing the frame it was diffing against

`sim/run_mob_tb.sh` passed the scene's scroll as `-PXSCROLL=224 -PYSCROLL=421`.
**iverilog's `-P` takes a hierarchical name** (`-Ptb_mob.XSCROLL=224`); the bare
form is accepted on the command line and then ignored, with no warning. The
bench ran at `tb_mob.v`'s compiled-in defaults of 123/253 while
`render_scene.py` composited its output against a frame scrolled to 224/421.

This is what produced the "15127 RTL pixels vs 13505 MAME, only 3386
coordinates overlapping, 17 of them with the same pen, 70.86% whole-frame"
picture that made placement look catastrophic. Two different frames were being
compared. With the scroll actually applied, the *unchanged* engine scored
88.72%, and 10412 of its 11096 pixels landed on a coordinate MAME also covered.

The script now builds the hierarchical form from `XSCROLL=`/`YSCROLL=` and
hard-errors on the bare spelling; `tb_mob.v` prints the scroll it was built
with.

### 1. Every sprite was one scanline too high

The line trigger fires at `x_count == 0` of raster line `Y` and starts building
the buffer that will be **displayed on line Y+1**, i.e. at
`visible_y = Y - vbporch + 1`. The playfield row that buffer must carry is
therefore `(Y - vbporch + 1) + yscroll`. The engine used `+2`.

`core_top.v` agrees with the reference on the other layers — its playfield fetch
is `pf_y = visible_y + yscroll`, with no offset — so the motion-object layer was
misregistered against the playfield, the alpha layer and MAME by exactly one
line, everywhere, always.

Cross-correlating the engine's MO pixels against a Python port of `atarimo
draw()` on the reference frame gives a single clean peak: 9728 matches at
`(dx=0, dy=+1)` against 4466 at `(0,0)`, and nothing else close.

### 2. Overlapping sprites resolved to the wrong object

`s_mob_config` sets *render in reverse order*, so `draw()` runs the active list
from its tail back to its head: **the head entry is painted last and wins every
pixel it touches**. Our engine must walk head-first — the list is singly linked
— and it was letting the last entry win. On the reference frame that is 2154 of
13505 MO pixels (16%) showing the wrong sprite.

Walking forward while refusing to overwrite is exactly equivalent: the earliest
entry still wins. The refusal needs to know what is already at the pixel about
to be written, and that read turned out to be free — see below.

## First-write-wins for nothing

Both line buffers were being read at `disp_x` every cycle even though only the
*displayed* one is ever looked at. The buffer being **built** had an idle read
port. Point that one at `blit_x`:

```verilog
wire [8:0] rd_addr0 = build_sel ? disp_x : blit_x;
wire [8:0] rd_addr1 = build_sel ? blit_x : disp_x;
```

and its registered output becomes an occupancy probe. Each buffer still does one
read and one write per cycle, so it stays a 512x20 **simple dual port** M10K.

The timing needs no new stage. The probe read and the `wr_x`/`wr_en` registers
both sample `blit_x` in the same cycle, and the buffer write commits one cycle
after `wr_en` is registered, so the probe is always "what was at `wr_x`
immediately before this write". Consecutive writes never target the same
address: `blit_x` increments within a tile, tiles are 8 apart, and there is at
least one `S_PRIME` cycle between tiles.

Occupancy also requires `pix != 0` alongside the `{fpar, ly}` tag match. `S_BLIT`
only ever writes a non-zero pen, so this cannot reject a real pixel, and it stops
an all-zero entry — what a powered-up or never-written M10K location reads —
from aliasing the tag `{fpar=0, ly=0}`. That was a latent bug in `disp_valid`
too: one scanline every second frame could show phantom pen-0 motion objects.

Only the buffer write enable and one read address changed. The fetch budget, the
SLIP walk, the ring traversal, the A/B fetch handshakes and the blit loop are
untouched, so scheduling and the never-wedge property are bit-identical.

## Results

Whole-frame exact-RGB agreement with MAME 0.289's own snapshot of the same
frame, via `sim/tools/render_scene.py`. "ceiling" is the same measurement with
the motion-object layer supplied by `sim/tools/mame_mo_model.py` instead of the
RTL — it isolates placement from the line engine's throughput and from anything
else in the frame that differs.

| scene | xscroll | yscroll | before | after | ceiling |
|---|---|---|---|---|---|
| `scene108p` (busy, wrapped y) | 224 | 421 | 88.72% | **96.95%** | 99.39% |
| `sc27` | 87 | 228 | 90.82% | **99.39%** | 100.00% |
| `sc55` (x scroll zero) | 0 | 168 | 93.09% | **99.69%** | 100.00% |
| `sc79` (small y scroll) | 234 | 58 | 94.10% | **95.91%** | 95.95% |

(The "before" column is the base engine measured through the *corrected*
harness. Through the broken one, `scene108p` read 70.86%.)

Three of the four scenes are now at or within 0.05–0.6 points of their ceiling.

**The placement algorithm is now bit-exact with `atarimo draw()`.** Running the
engine's rules in Python without a fetch budget reproduces the reference's
motion-object bitmap for `scene108p` exactly: 13505 pixels, same coordinates,
same pens, zero differences.

## What is left

**Scanline-time starvation, not placement.** On `scene108p` the engine emits
11117 of the reference's 13505 MO pixels. 11001 of those land on a coordinate
MAME also covers and 10889 carry an identical pen; 152 of 240 lines are
complete. The 2504 missing pixels are on 88 lines that the build never finishes:
that scene has lines needing 218–441 tile-row fetches, against a 456-cycle
scanline in which the list walk alone costs ~8 cycles per entry.

This is **not** the `fetch_budget` counter. Raising it from 62 to 4000 changes
the output by zero pixels — the line trigger aborts the build first. It is also
not the 64-entry link cap: capping at 34 (the longest real list in this scene)
gives byte-identical output. The lever is traversal throughput, which is
branch `mo-fetch`'s work.

The 116 pixels the RTL draws that MAME does not, and the 112 overlap pixels with
a different pen, are second-order effects of the same truncation: when a
higher-priority (earlier) entry is dropped mid-line, first-write-wins hands the
pixel to a later entry instead.

`sc79`'s ceiling is 95.95%, not 100% — roughly 1600 pixels of that frame differ
even with MAME's own motion-object layer, so something outside the MO path
(most likely the same one-frame update skew `docs/investigations/mo_priority.md` describes for
`scene108p`) accounts for it. The RTL is within 0.04 points of it either way.

Known deviations inherited from `docs/investigations/mo_priority.md` are unchanged: no
`apply_stain` second pass, and a special (`mopriority & 4`) object does not mask
a normal object underneath it.

## Resource impact

`escape_mob.v` synthesized standalone for the Pocket's 5CEBA4, Quartus Lite 18.1:

| | before | after |
|---|---|---|
| Block memory | 2 x altsyncram, Simple Dual Port, 512x20 | identical |
| Block memory bits | 20,480 | 20,480 |
| **M10K delta** | | **0** |
| Dedicated logic registers | 298 | 298 |
| Combinational ALUTs | 323 | 339 (+16) |

The +16 ALUTs are the two 2:1 address muxes and the write-enable gate; the tag
comparators were already there for `disp_valid` and are now shared. Both buffers
still infer as **Simple Dual Port** — pointing the read port at `blit_x` did not
force a second port or a duplicated memory. The simulation-only initial block is
inside `translate_off`, and the RAM summary confirms `MIF: None`.

## Reproducing

```bash
# 1. dump frames at a range of scrolls (SCENE_START moves the shot window;
#    the default keeps the in-game capture docs/investigations/mo_priority.md used)
SCENE_OUT=<dir> SCENE_IDX=27 ./mame eprom -rompath <roms> -video none -sound none \
    -seconds_to_run 62 -autoboot_script sim/tools/scenedump2.lua \
    -snapshot_directory <dir>
cp <dir>/eprom/0000.png <dir>/mame_frame.png

# 2. fixtures, replay, render
python3 sim/tools/make_scene_hex.py <dir> sim/work
XSCROLL=87 YSCROLL=228 ./sim/run_mob_tb.sh
python3 sim/tools/render_scene.py <dir>                   # RTL MO layer
python3 sim/tools/render_scene.py <dir> --mo-source mame  # the ceiling
```

Use several scenes with different scroll. A bug that only bites at one scroll
value — the one-line offset was invisible at yscroll multiples that happened to
align, and the harness bug hid behind a single hard-coded default — is exactly
what a single-frame regression test cannot see.
