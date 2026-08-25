# Tile-shaped holes in motion objects — the alpha blocker

**Status: open. This is the one consistent blocker to alpha.**

Sprites render, in the right place, with the right palette — but with a
**rectangular chunk missing**, edges straight and following no sprite outline.
The severity dropped sharply with the SDRAM rework (build 116: MO service
latency 3.7 px against 21.2 baseline), which moved this from whole-sprite
dropouts to individual tile-sized holes. It did not eliminate it.

## Field evidence (build 116, capture `Genki Arcade - 2026-08-25 110620.mp4`, 60 fps)

Frame numbers are exact; divide by 60 for the timestamp.

| frame | t (s) | what to look at |
|---|---|---|
| **5629** | 93.817 | **Best single example.** Rightmost gold robot: rectangular bite out of its lower-left, clean straight edges, floor showing through. The orange/blue figure beside it is a legitimate sprite, not an artifact. |
| 5636 | 93.933 | the same robot renders correctly again — so it is transient, not a bad tile in ROM |
| 5627, 5628 | 93.783, 93.800 | artifact noise to the left of Jake |
| 5514 → 5515 | 91.900, 91.917 | rectangle visible across a consecutive pair |
| 3829 | 63.817 | dense crowd; owner reads it as "layer offsets aren't matching correctly" |
| 1285 | 21.417 | left-edge strip (separate defect, see below) |

**5629 vs 5636 is the most diagnostic pair**: the same sprite, wrong then right,
~7 frames apart. That rules out static causes — bad ROM data, a wrong tile
index, a palette error — and points at something transient in the fetch or
write path.

## Ruled out, with reasons

* **The first-write-wins occupancy probe is correctly aligned.** Walked the
  cycle timing: `disp_q1` at cycle N+1 holds `buf1[blit_x(N)]`, and the write
  at N+1 targets `wr_x = blit_x(N)` — the same address, so `bld_occupied` is
  genuinely "what is already there before this write", and it stays correct
  across tile jumps (`blit_x <= blit_x_new`) because every path is consistently
  one cycle. `escape_mob.v:134-165`.
* **The MO left-edge clipper is correct.** `spr_dead`, `tile_dead` (344..504)
  and the `blit_x < 344` write clip were walked through the wrap cases: a tile
  starting at 505 correctly writes only its last pixel, at screen x=0.
* **Not the left-edge strip.** That is a separate, now-diagnosed playfield
  defect (see below) and it only affects native columns 0-1.

## Live hypotheses

1. **Channel reuse before consumption.** Tiles are slot-addressed — each tile
   remembers its channel in `tch_v` (`escape_mob.v:506`) and `tile_rdy` waits
   on `pend[ch_cur]`. But with 4 channels and a 3-deep park queue, a channel
   could in principle be handed out again before an earlier tile consumed its
   data. That would drop or corrupt exactly one tile: a rectangular hole.
   Precedent in this codebase is strong — v81b found exactly this class on the
   PLAYFIELD ("a late completion in the shift design landed in the NEXT cell's
   slot") and fixed it by slot-addressing the ring.
2. **Transparency / overlay rule.** `S_BLIT` writes only `pix_val != 0` (pen 0
   is transparent). Anything that makes a tile's fetched word read as zero -
   a completion that never lands, a channel read before its data is valid -
   produces a transparent, tile-shaped hole rather than visible corruption.

## The diagnostic that will actually settle it

`DEVIATIONS.md` D3 already names it, and the reason it was never done is that
we lacked a failing moment to dump: *"a sprite fetching wrong-but-plausibly-
coloured data cannot be caught by any statistical shape test — needs a scene
dump of the exact failing moment."*

**We now have the exact failing moment: frame 5629, and its clean counterpart
5636.** The work is to reproduce that scene in `tb_mob` under realistic SDRAM
latency and add a detector for *a missing tile inside an accepted sprite*,
which is different from every detector we have — all three existing ones test
for whole-sprite dropouts or statistical hole rates, and this artifact passes
all of them because the sprite IS accepted and IS drawn.

Any such detector must be provoked before it is trusted; see `LESSONS.md` on
controls that cannot fail.

## Related but separate: the left-edge strip

Native columns 0-1 carried stale playfield. Diagnosed in build 116:
`pf_show`/`pf_next` were loaded only at `vis_x[2:0]==7`, so the first pixels of
every line came from the previous line's last cell, staged off the pre-resync
`pf_rp`. PFLINE-116 primes them at line start. **Partial fix, measured:**

| build | distinct colours down cols 0-1 | luma sd |
|---|---|---|
| 115 | 62-69 (structured scene content) | ~35 |
| 116 | **1** (a single flat value) | **0.0** |

So the prime takes effect and the columns stop serving per-line scene data —
but the value primed is still the wrong ring slot, leaving a flat 2-px strip.
Next step is the slot index (`pf_wp` vs `pf_wp - 1`) and whether the line-start
queue flush (`pfq_count <= 0` at `x_count == 0`) discards the leading cells'
fetches. **Verify in simulation before building again** — the first attempt was
reasoned from code and shipped without a bench that covers line-start pixels.
