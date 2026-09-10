# Klax prototypes and Guts n' Glory on the Escape core — exact deltas

Written 2026-09-09 for milestone 0.2. Everything below is read from MAME
0.289 `src/mame/atari/eprom.cpp` and `atarijsa.cpp` (the only references
that exist — both games are unreleased prototypes; no PCB, no schematics,
no reference video) and from this repo's RTL. **No klaxp1/klaxp2/guts
romset is on the development machine**, so nothing here has been run;
the plan is bench-first with synthetic stimulus, then device tests when
sets exist.

## 1. What the driver says

| | `eprom` (shipped) | `klaxp1` / `klaxp2` | `guts` |
|---|---|---|---|
| Main 68000 | 7.159 MHz, `main_map` | 7.159 MHz, **same `main_map`** | 7.159 MHz, `guts_map` |
| Extra 68000 | yes (`extra_map`) | **none** | **none** |
| Sound board | JSA-I (YM2151 + TMS5220, no POKEY fitted) | **JSA-II** (YM2151 + OKI6295) | **JSA-II** |
| ADC0809 | yes, 260020 | not fitted (`adc_r` returns FF) | yes, 4 channels (two sticks) |
| Latch 360011 | extra reset / intensity / video off | write ignored (no extra) | not mapped |
| Video | `screen_update_eprom`, `s_mob_config` | **identical** | `screen_update_guts`, `s_guts_mob_config` |
| Playfield | 64×64, code 15 b + flip, colour from ext RAM | identical | identical format, **gfx from its own 1 MB `tiles` region** |
| Video RAM | 3F0000–3F9FFF | identical | **FF0000–FFFFFF** (see §4) |
| Sync | 14.318/2, 456×262, 336×240 | identical | identical |
| Main ROM | 512 KB (+128 KB set 2) | 128 KB (one pair) | 256 KB (two pairs) |
| spr_tiles | 1 MB planar ×4 | **256 KB** planar ×4 | sprites 1 MB + tiles 1 MB (12 of 16 chips) |
| chars | `136069-1007.125d` | `klax125d` — **same CRC `409d818e`** | `guts-alpha.bin` (different) |
| OKI ADPCM | — | 128 KB (2 × 64 KB) | 128 KB |
| Inputs 260000/260010 | buttons D8–D11 | **joystick D12–D15 + 4 buttons D8–D11**, per player | buttons D8/D9/D11 + sticks on ADC |

Klax is therefore Escape with the second CPU unpopulated, the sound board
swapped and smaller ROMs. Guts is a genuine video-map variant.

## 2. JSA-II versus our JSA-I (`src/fpga/core/rtl/escape_jsa.vhd`)

6502 map, from `atarijsa2_map` vs `atarijsa1_map` (mirror mask 0x01F9 on
both; our decode already matches it):

| Address | JSA-I (ours) | JSA-II |
|---|---|---|
| 2000/2001 | YM2151 | YM2151 |
| 2800 read | N/C | **OKI6295 status** (`/RDV`) |
| 2802 read | command from 68k | same |
| 2804 read | RDIO | RDIO — bit layout differs, see below |
| 2806 r/w | IRQ ack | same |
| 2A00 write | TMS5220 voice | **OKI6295 command** (`/WRV`) |
| 2A02 write | response to 68k | same |
| 2A04 write | WRIO | WRIO — bit layout differs |
| 2A06 write | MIX | MIX — bit layout differs |
| 2C00–2FFF | POKEY (absent) | **not decoded** |
| 3000–3FFF | ROM bank (WRIO D7:6) | same |
| 4000–FFFF | ROM | same |

WRIO (`atari_jsa_oki_base_device::wrio_w`): D7:6 CPU bank (same as ours),
D5/D4 coin counters, **D3 OKI pin 7** (sample-rate select; the game can
retune it), **D2 OKI reset, active low**, D1 unused on JSA-II, D0 YM2151
reset active low (same as ours). Our JSA-I WRIO uses D3 for the TMS
"squeak" clock and D2/D1 for the TMS strobes — those become the OKI bits.

MIX (`mix_w`): D3:1 YM2151 volume 0–7 (same idea as ours), **D0 OKI volume
(1 = unity, 0 = half)**, D5 low-pass enable (MAME does not model it), D4
OKI bank bit — JSA-III only, ignore.

RDIO (`atari_jsa_ii_device::rdio_r` + `jsa_ii_ioports`): D0 coin 1, D1
coin 2, D2 coin 3, D5 response-full, D6 command-full (active low), D7 self
test. JSA-I has the TMS ready bit at D4; JSA-II's D4:3 read as +5 V.

Timers and interrupts are unchanged: the periodic 6502 IRQ is still
`JSA_MASTER_CLOCK/4/16/16/14`, the YM IRQ still ORs in, the 68k link still
NMI/IRQ6. OKI clock: `JSA_MASTER_CLOCK/3` = 1.193 MHz, `PIN7_HIGH` → 9.04 kHz
sample rate at reset.

**Implementation:** `escape_jsa` gains a generic `BOARD` (1 = JSA-I,
2 = JSA-II). In JSA-II mode the TMS5220 is not instantiated; `jotego/jt6295`
(GPL-3.0, added as `third_party/jt6295`, commit `7d76b0b`) takes 2800 reads
and 2A00 writes, `cen` = board clock / 6 = 1.193 MHz, `ss` = WRIO D3, `rst`
= NOT WRIO D2. The OKI's ROM port (18-bit byte address, `rom_ok` handshake)
becomes a second client of the sound board's existing ROM request port,
arbitrated with the 6502 fetch; the ADPCM region sits at combined-image
**0x240000–0x27FFFF** (a new 256 KB-aligned slot after the sprite region so
the chip's 18-bit address drops straight in — Escape's image does not change). jt6295 is Verilog, so like jt51 it is bound by Quartus and
stubbed under GHDL; its own behaviour is checked by an iverilog bench
(`sim/tb/tb_jt6295.v`, Docker `hdlc/iverilog`) with a synthetic phrase table.

## 3. Klax: everything else

- **No extra CPU.** `escape_core` generic `EXTRA_EN` (new) = 0: the second
  TG68K, its ROM shadow and its arbiter slot are not built; `extra_release`
  is forced low; the 360011 latch write is accepted and ignored, exactly as
  MAME (`eprom_latch_w` returns early when `m_extra` is absent — so on Klax
  neither intensity nor video-disable exist). Note the shared-RAM flag
  address `16CCD6` special case in `escape_core` (comment already says
  "revisit for the Klax/Guts variants") — with no extra CPU it is inert.
- **Inputs.** 260000/260010 high bytes are joystick U/D/L/R at D15..D12 and
  buttons 4..1 at D11..D8 (active low), per player; ADC reads return FF.
  Klax proto uses two buttons in play (MAME maps four).
- **Video: none.** Same tilemaps, same MO config, same priority PAL
  transcription (MOSHADE-162 included), same alpha ROM.
- **ROM image.** `build_rom.py` gains a `klaxp` table: main pair 128 KB at
  0; JSA CPU at 0x100000; chars at 0x110000; sprites at 0x120000 from four
  64 KB planes (`RGN_FRAC(1,4)` over 0x40000 — the chunky repack takes the
  plane stride as a parameter); ADPCM at 0x240000 (`klaxadp0.1f`,
  `klaxadp1.1e`). MiSTer: `Klax (prototype set N).mra` interleaving the four
  sprite chips as one 32-bit group, exactly as the Escape MRA does per slice.
- **Set detection:** by the main-pair filename (`klax_ft1.50a` /
  `klax_ft2.50a`); the two sets differ only in the main pair.

## 4. Guts: the video-map variant

`guts_map` moves every video RAM block into the top 64 KB:

| Guts | Escape | Size | Contents |
|---|---|---|---|
| FF0000–FF1FFF | 3F8000–3F9FFF | 8 KB | playfield ext (colour attribute, D15:8) |
| FF8000–FF9FFF | 3F0000–3F1FFF | 8 KB | playfield picture |
| FFA000–FFBFFF | 3F2000–3F3FFF | 8 KB | motion objects |
| FFC000–FFCF7F | 3F4000–3F4EFF | ~4 KB | alphanumerics (+ MOB config at the end of the alpha block? — MAME maps 3F4F00–3F4F7F inside the alpha share on Escape; **verify** where Guts keeps scroll/MOB config; MAME's guts_map has no separate mobconfig, so `write16` on the alpha share covers FFCF00–FFCF7F too) |
| FFCF80–FFCFFF | 3F4F80–3F4FFF | 128 B | SLIP |
| FFD000–FFFFFF | 3F5000–3F7FFF | 12 KB | work RAM |
| 3E0000–3E0FFF | same | 4 KB | colour RAM |

So the decoder (`escape_decode.vhd`) needs a `VARIANT` generic that swaps
the 3Fxxxx block for FFxxxx with the ext RAM at the bottom instead of the
top; the RAM blocks themselves are the same sizes. 160000–16FFFF shared RAM
still exists (single CPU), EEPROM and unlock unchanged, ADC at 260020 as
Escape.

Motion objects (`s_guts_mob_config` vs `s_mob_config`): **height is 4 bits**
(word 3 mask 0x000F, up to 16 tiles tall — Escape: 3 bits), **H-flip is
word 1 bit 15** (Escape: word 3 bit 3), and the list is rendered in
**forward** order (Escape: reverse). Link, code (15 b), colour, X, width and
priority masks are unchanged. In `escape_mob.v` these are three
parameterised points, but the render-order change interacts with the line
buffer's write policy (who wins when two objects overlap) — that is the item
to bench first, against MAME's `atarimo` semantics, because MAME is the only
reference.

Priority (`screen_update_guts`): a **plain comparator** — MO drawn when
`!(pf & 8) || mopriority >= pfpriority` (pfpriority = pf bits 6:5), MPR2
objects skipped in the first pass, then the second pass applies the stain
exactly as Escape (`mo & 2` → `apply_stain`). No shade path, no colour-RAM
bank tricks. Our `escape_prio.v` is the GAL 100T transcription for Escape's
board; Guts, a prototype on the same board family, may have had different
PAL equations — MAME's simpler rule is all there is. Implement as a
`VARIANT`-selected rule in `escape_prio.v`.

Playfield tiles come from the separate `tiles` region: **playfield fetches
address 0x280000+ (new slot, 1 MB), MO fetches stay at 0x120000+**. Both
are planar ×4, inverted, so the same repack applies. Four `tiles` chips are
absent from the dump (pf3/7/b/f): those 64 KB slices are zero-filled, as in
MAME.

Inputs: P1/P2 button 1 at D9, button 2 at D8, button 3 at D11 (note the swap
versus Escape's ordering), sticks on ADC0–3 (P1 Y/X, P2 Y/X; X reversed).

Image layout (Guts): main 256 KB @0, JSA @0x100000, chars @0x110000,
sprites @0x120000 (1 MB), ADPCM @0x240000 (128 KB), tiles @0x280000 (1 MB)
→ 0x380000 = 3.5 MB. Comfortably inside SDRAM on both platforms.

## 4a. Romsets arrived (2026-09-09 evening) — what MAME and the benches say

The owner's `~/Downloads` now holds `klax` (a merged folder: production
Klax `136075-*` plus `klaxp1/` and `klaxp2/` subfolders holding exactly the
`eprom.cpp` prototype chips), `guts`, and `thunderj` (with its seven GAL
dumps). `mame -verifyroms` passes for `guts`, `klax`, `thunderj`, and — via
a scratch folder that gives `klaxp2` its shared chips — `klaxp1` and
`klaxp2`. **Nothing was copied into the repo; images and scene dumps live in
`/tmp` and the gitignored `sim/work/`.**

- `build_rom.py` assembles `klaxp1` (2,621,440 B), `klaxp2` and `guts`
  (3,670,016 B) with every CRC matching.
- MAME 0.289 boots both prototypes headless: Klax to its attract/how-to-play
  screen, Guts into an attract gameplay scene (planes, explosions, ground
  guns — the priority cases). Scene dumps at frame 2400 (PF, PF-ext, MO,
  alpha/cfg/SLIP, palette, work RAM + screenshot) sit in
  `sim/work/scenes/{guts,klaxp1}_f2400/`, made by `sim/tools/mame_scene_dump.lua`.
- The dumped MO lists confirm §4's format reading from live data: in the
  Guts scene 105 entries, **w3[3] set in none, w1[15] set in 8** (hflip
  lives in word 1; word 3's low nibble is a 4-bit height); in the Klax scene
  w3[3] is set on 4 flipped sprites, as on Escape. Guts' PF-ext colour byte
  uses values 0/1/2/5 and 15 flipped tiles.
- Reset vectors: Klax `$632`, Guts `$45C` (stack in Guts' FFxxxx work RAM,
  SSP `FFFFFF00`). The core's debug "reached reset PC" flag now derives the
  PC from the vector fetch, so the boot bench needs no per-game list.
- GHDL, real programs: `tb_escape_jsa` with `G_BOARD=2` boots **Klax's and
  Guts' actual 6502 firmware** on the JSA-II board mode (reset vector →
  execution → response latch written after 3281 opcodes in both — their
  upper 32 KB, Atari's JSA-II kernel, is byte-identical; the game halves
  differ); `tb_escape_core` with `G_EXTRA=0 G_JSA=2` boots the **Klax
  main program** to its reset PC, and with `G_VMAP=1` added the **Guts main
  program** too.

## 4c. Guts video reading proven offline, pixel-exact (2026-09-10)

Before any RTL for §4's MO/priority items, the reading was checked on real
frames: `sim/tools/mame_scene_dump.lua` (MAP=guts, twelve attract frames
2400…5700, RAM grabbed in the same `frame_done` as the snapshot —
`video:snapshot()` re-renders from current RAM, so the previous-frame
buffer that Escape's `scenedump2.lua` needed pairs *worse* here, 94 % vs
99 %) and `sim/tools/guts_render.py`, a transcription of
`screen_update_guts` + `s_guts_mob_config` on top of the Escape tooling's
playfield/alpha/palette decode and `apply_stain`. `sim/tools/guts_sweep.py`
scores it against four alternatives per frame:

| frame | documented | reverse order | Escape MO format | pf priority bits 5:4 | MO always on top |
|---|---|---|---|---|---|
| 2400 | 99.40 | 99.20 | 99.35 | 99.23 | 99.40 |
| 2700 | 99.84 | 99.61 | 99.84 | 99.76 | 99.84 |
| 3000 | 99.90 | 99.72 | **99.40** | 99.89 | 99.90 |
| 3300 | 99.99 | 99.93 | **99.68** | 99.94 | 99.99 |
| 3600 | **100.00** | 99.80 | 100.00 | 99.95 | 100.00 |
| 3900 | **100.00** | 99.85 | 100.00 | 99.97 | 100.00 |
| 4200 | **100.00** | 100.00 | 100.00 | 92.57* | **92.11** |
| 4500 | **100.00** | 100.00 | 100.00 | 92.57* | **92.11** |
| 4800 | 99.94 | 99.94 | 99.87 | 99.94 | 99.91 |
| 5100 | **100.00** | 100.00 | 100.00 | 100.00 | 99.96 |
| 5400 | 99.95 | 99.95 | 99.95 | 99.95 | **99.47** |
| 5700 | **100.00** | 100.00 | 100.00 | 100.00 | 99.92 |

(\* that control runs without the stain pass, so its menu-frame numbers are
confounded; it still loses on 3600/3900.) Six frames are pixel-exact; the
sub-1 % residue on the others sits under moving sprites (MAME's partial
updates within the frame). Every alternative loses somewhere the
documented reading does not: forward render order (2400–3900), hflip in
w1[15] with a 4-bit height (3000, 3300), the comparator's priority bits
(3600, 3900) and the comparator itself (4200–5700). Frames 4200/4500 are
the Combat Assignment menu: the highlighted panel is **the stain** from two
MPR2 objects — the same `apply_stain` as Escape's map, so `escape_stain.v`
serves Guts unchanged. Fixtures: `sim/work/scenes/` (gitignored), results
in `sweep_results.txt` beside them.

## 4b. One rbf, three games: the runtime selector (GAMESEL-167)

MiSTer ships one `Escape` rbf serving all three games, MRA-selected, the
way other family cores do (top-level MRA per game, clones under
`_alternatives/_<Game>/`, a config byte in `<rom index="1">`). The Pocket
ships one core per game. Both come from the same RTL through one selector:

- `escape_core` port `game_sel` (00 Escape either set, 01 Klax prototype,
  10 Guts). It holds the second CPU in reset for the single-CPU games,
  drives the decoder's runtime `vmap` (ORed with the `VIDEO_MAP` generic),
  switches the sound board to JSA-II behaviour, gates the joystick nibble
  (Klax only — Escape and Guts leave D15:12 open) and makes the ADC read
  FF for Klax (no ADC0809 fitted, MAME `adc_r`).
- `escape_jsa` generic `BOARD_RT=1` builds both the TMS5220 and the OKI and
  follows the `board2` port; the unselected device is held in reset and
  muted. `BOARD_RT=0` (Pocket) builds only `BOARD`.
- On the Pocket the wrapper ties `game_sel` to a constant beside
  `EXTRA_EN` / `JSA_BOARD` / `VIDEO_MAP`, so synthesis prunes the rest and
  the Escape build is unchanged.
- **OKI ADPCM reads** cannot come from the 64 KB `jshad` BRAM that serves the
  6502 program; requests to image `0x24xxxx` are routed to the core's SDRAM
  arbiter as a new lowest-priority owner (`OWN_J`), a few kB/s and
  latency-tolerant behind the two CPUs.
- MiSTer loader: the planar→chunky repack now covers exactly the two
  graphics slots (`0x120000–0x21FFFF`, `0x280000–0x37FFFF`); the ADPCM slot
  is written raw. `Arcade-Escape.sv` latches the index-1 byte into
  `game_sel` (absent in old Escape MRAs → 00).
- MRAs: `Klax (prototype set 1).mra`, `Klax (prototype set 2).mra` (byte
  01, `zip="klaxpN.zip|klax.zip"`), `Guts n' Glory (prototype).mra` (byte 02).

## 5. Order of work and what can be proven without ROMs

1. `jt6295` submodule + iverilog smoke bench — **done 2026-09-09** (see
   `sim/tb/tb_jt6295.v`).
2. `escape_jsa` `BOARD=2`: decode, WRIO/MIX/RDIO bit maps, OKI glue, ROM
   client arbitration — **done 2026-09-09**; `tb_escape_jsa2` (purpose-built
   6502 program, no game data) proves 2800/2A00 routing, WRIO→OKI reset and
   pin 7, the status read, and both ROM clients sharing the port; the JSA-I
   bench is unchanged.
3. `escape_core` `EXTRA_EN=0` + Klax inputs — **done 2026-09-09
   (KLAX-165)**: the extra TG68K and its two shadows are generate-gated,
   the extra bus idles with AS high, `p1_joy`/`p2_joy` feed D15:12 of
   260000/260010 (Escape wrappers leave them at F). `tb_escape_core` boots
   the Escape set with `G_EXTRA=0` and with the default.
4. `build_rom.py` `klaxp1`/`klaxp2`/`guts` tables (CRCs from `eprom.cpp`),
   region-sized planar repack, ADPCM slot at 0x240000, Guts tiles at
   0x280000 — **done 2026-09-09** (Escape images byte-identical before and
   after; the new paths cannot be exercised without the sets). MRAs for the
   Klax sets wait on the packaging decision below.
5. Guts, one variable at a time:
   - decoder variant — **done 2026-09-09 (GUTS-166)**: `escape_decode`
     `VIDEO_MAP=1` (threaded as `escape_core` `VIDEO_MAP`), `tb_escape_vmap`
     probes every block edge of both maps (the original Escape-only
     `tb_escape_decode` still passes); the block RAMs index on the same
     low address bits in both maps so nothing else moved.
   - MO entry format: `escape_mob.v` takes height from `q_w3[0][2:0]` and
     hflip from `q_w3[0][3]` (line ~1093); Guts needs height `w3[3:0]` (so
     `height_t` becomes 4 bits through `ydiff`/`ymatch`/`code_row`) and hflip
     from **w1[15]**, which the scout no longer carries (MOCOV-1 dropped w1
     from the queue) — a queue bit has to come back for it.
   - render order: the scout walks from the SLIP head and the line buffer's
     write policy reproduces MAME's *reverse* order for Escape (`escape_mob.v`
     header and line ~444). Guts renders *forward*; in a line buffer that is
     the opposite overwrite rule, which touches the blit-write policy and
     `tb_mob`'s fixtures.
   - priority: `escape_prio.v` is the GAL 100T transcription; Guts wants
     MAME's plain rule (`!(pf & 8) || mopriority >= pfpriority`, stain pass
     unchanged) behind the same generic.
   - tile region: playfield tile fetches address the sprite slot base
     (`0x120000`, `core_top.v` / `escape_mister.v`); Guts fetches playfield
     rows from `0x280000` while MOs stay at `0x120000`.
   **All four done 2026-09-10 (GUTS-168)**, after §4c proved the reading
   offline: `escape_mob` takes a `guts` input (height from w3[3:0], hflip
   from a new queue bit carrying w1[15], line-buffer writes "last writer
   wins"), `escape_prio` takes `guts` (MO wins iff !PFX3 or mo_prio >=
   pf_color[2:1]; no SHADE/FORCEMC0/M7), the MiSTer wrapper fetches
   playfield tiles from 0x280000 when the MRA byte says Guts. Proof:
   `tb_prio` now also sweeps the Guts comparator against the MAME rule on
   all 524,288 rows; `tb_mob` with `GUTS=1` on the frame-3600 fixture
   (`sim/tools/make_guts_scene_hex.py`, `mob_vs_mame.py --guts`) agrees with
   the Guts model on every logged pixel, 0 wrong pens, 0 extras (the 68
   "missing" are raster line 239, which the bench never logs); with `GUTS=0`
   the Escape fixture's engine output is byte-identical to the committed
   tree, and `tb_prio` / `tb_stain` pass unchanged. Device verification
   pending (MiSTer 165).
6. Device tests need the romsets. Until then the README keeps both games
   at "not supported".

Platform packaging decision (owner's call, not made here): compile-time
`VARIANT` means one bitstream per game — a separate Pocket core per game
(`spoonelli.klaxp`, `spoonelli.guts`) and separate MiSTer rbfs — versus a
runtime variant byte (MRA `<rom index="1">` / Pocket data slot) in one
bitstream. The Pocket is at the 308/308 M10K ceiling, so anything that adds
RAM (Guts adds none, but the extra CPU's shadows come out only at compile
time) argues for compile-time on the Pocket; the MiSTer has room for either.
