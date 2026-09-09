# The FACTORY MAP "halftone" — how the board dims travelled routes (MOSHADE-162)

**Status (2026-09-09):** root cause found and fixed in RTL on branch
`milestone-0.2`; device verification at a level ≥ 2 map still pending.
Checklist item H8. Both platforms (shared machine RTL).

## The symptom

On the between-level FACTORY MAP the routes already travelled — and the START
box — are **dimmed** on the original PCB: same hue, roughly 0.38× the bright
value in the capture (reference capture `Genki Arcade - 2026-09-01
234201.mp4`, t406–t410, frame 24402). On this core they were **erased to
black with 1-px slivers** (the owner's August diagnosis in `MO_TILE_HOLES.md`);
MAME's own render leaves them **bright**. Three different answers.

The level-1 map is *not* affected: PCB (t180–t183), MAME and this core all
draw the whole network bright there. An earlier reading of "far routes dim at
t181" was a misread of the beige track blend; the measurement that settled it
is in section 4.

## 1. What the game does (MAME as an instrument, not a reference)

Palette dump on the level-1 map (MAME 0.289, scripted harness, frame 3000),
colour-RAM bank occupancy per playfield colour attribute:

| bank | index | colour 0 | colours 1–2 | others |
|---|---|---|---|---|
| playfield | `0x200 + c·16 + pen` | 15 | 16 / 15 | 0 |
| playfield + SHADE (+0x100) | `0x300 + c·16 + pen` | **16 — I=4 copies of the colour-0 palette** (`4FF0` dim yellow, `4F80` dim orange…) | 0 | 0 |
| playfield + STAIN (+0x400) | `0x600 + c·16 + pen` | 16 — greys (`F888`) and dark primaries | 0 | 0 |
| any bank with the M7 bit (+0x080) | `…380`, `…280`, `…680` | **0** | 0 | 0 |

In gameplay the +0x400 region is populated for every colour (a whole-screen
alternate palette) and the SHADE bank is still colour-0-only; **no +0x080
bank is ever written.**

All map tiles have colour attribute 0 (playfield ext RAM is entirely zero on
that screen), so a bright node is `0x20E` (`FFF0`), its dim twin `0x30E`
(`4FF0`), and its grey twin `0x60E` (`F888`).

The motion-object list on the map holds one live sprite: the START marker,
alternating between code `0x22A0` (1×1) and `0x22AB` (3×3), colour 0,
priority 7 (MPR2 = special). The sprite frame table at ROM `0x6A938` lists
the map markers as 6-byte records `(code, attr, size)`:

```
22A0 00FC 00FC   22A1 02F4 2200   22A2 02F4 2200   22AB 03E0 3300
22B4 02F4 2200   22C4 02F4 2200   ...
```

`attr & 0x7F` = colour | priority<<4: `02F4` → **colour 4, priority 7
(special)**; `03E0` → colour 0, priority 6. The tiles (sprite ROM,
`sim/work/atari_escape.rom`, `0x120000 + code·32`):

| tiles | shape | pen |
|---|---|---|
| `22A2–22AA` | the 3×3 START-box silhouette | **1** |
| `22AB–22B3` | the same silhouette | **6** (START+END stain marker) |
| `22B4–22C3` | a second (route-node) shape | **6** |
| `22C4–22CC` | the same second shape | **1** |

The game keeps a **pen-1 twin of every pen-6 marker**. Pen 6 is the stain
form (grey START-box blink, `0x60X`); pen 1 in a non-zero colour is the
*shadow* form — and the shadow form is the only thing that can address the
`0x30X` bank the game so carefully populates.

## 2. What the hardware does (the GAL fuse maps)

Both PALs are in the romset (`gal16v8-136069.100t/.100v`). Decoded with
`sim/tools/gal16v8.py` (MAME's `jedutil` does the same; it would not launch
here). Pin names from SP-332 sheet 9.

**100T — priority / shade (PAL16L8).** Inputs: 1=MPX1, 2=MPX0, 3=/MPX2,
4=/MPX3, 5–8=MPX4..7, 9=MPR0, 11=MPR1, 13–16=PFX6/5/3/4 (inputs; their OE
terms are empty). Outputs 17=PF/M, 18=/FORCEMC0, 19=M7, 12=SHADE. The
equations are **exactly MAME's transcription** — `M7 = MPX0·/MPX1·/MPX2·/MPX3`,
`/SHADE = /MPX0 + MPX1 + MPX2 + MPX3 + /MPX4·/MPX5·/MPX6·/MPX7 + FORCEMC0`,
FORCEMC0 and PF/M term for term. Nothing about MPR2 reaches this PAL.

**100V — line-buffer write / stain markers (PAL16L8).** Inputs: 11=MCKR,
9=RCLKA, 8=/LMPD, 7=RB1, 6=MAT6 (= MPR2, "special"), 2–5=/MSD0..3 (the
pixel pen). Outputs:

```
/STOFF (pin 19) = MSD2 · MAT6
/STON  (pin 18) = MSD1 · MAT6
/WE0, /WE1      = (MSDn · … · /MAT6 · /LMPD · /MCKR)  for any pen bit  — normal pixels, pen != 0, not special
                + MSD0 · /MSD1 · /MSD2 · /MSD3 · MAT6 · /LMPD · /MCKR   — SPECIAL, PEN == 1  ← the term MAME misses
                + (/)RB1 · /MCKR                                         — the erase pass
```

So: special pixels with pen bit 1 / bit 2 pulse the stain start/stop and are
**not** written; a special pixel whose pen is **exactly 1 is written** like any
sprite pixel. It reaches 100T as MPX = 1 → M7 (playfield wins) and, with MO
colour ≠ 0 and no FORCEMC0, SHADE → colour-RAM A8 → `pf | 0x100`.

Sheet 9 also confirms MAME's address model: 100M Q5 (latched stain FF 60M)
→ 112M → RAM A10 (+0x400); latched SHADE·CL10 + CL9 → A8 (+0x100); CL10 → A9
(+0x200). Only the *contents* of the PAL, not the wiring, were misread.

## 3. The two MAME inaccuracies we had inherited

1. `screen_update_eprom`: `if (mopriority & 4) continue;` **before** SHADE is
   computed. Special pen-1 pixels therefore never shade in MAME; its maps stay
   bright. `escape_mob.v` transcribed it as `hit = occ && !special`.
2. `if (m7) pf[x] |= 0x080;` — M7 folded into the playfield colour bit 3.
   The game never populates the bank that selects (`0x38X` / `0x28X` for
   colour 0), so with (1) fixed alone every shadowed pixel would be black.
   `escape_prio.v` transcribed it as `pf_color[3] | m7`. That is the
   "erased to black" — and the 1-px slivers were the un-shadowed edge column.

MAME's `apply_stain` (+0x400 from pen-bit-1/bit-2 special markers) is right
and unchanged.

## 4. Measurements

- PCB level-2 map, travelled node vs untravelled (`(54,60,0)` vs `(140,179,0)`
  in capture space): ratio 0.33–0.39 per channel; the START box holds steady
  at `(48,56,0)/(56,40,0)` through the blink phases. Capture gain vs MAME's
  linear render is ≈0.58 R / 0.75 G, which puts the dim nodes at MAME-space
  ≈`(75–90, 75–80, 0)` — the `4FF0` entry (I=4 → 75) within capture gamma.
- PCB level-1 map: far-route bright-yellow count 482 for the whole 3.5 s —
  identical to the level-2 map's *untravelled* routes. No dimming at level 1.
- MAME level-1 map: yellow count constant 1562/1644 across the map; the only
  stain is the START box, 19×15 px grey, bounded (pen 6 carries START+END).

## 5. The fix and its proof

- `src/fpga/core/rtl/escape_mob.v`: `hit = occ && (!special || pen == 1)`.
- `src/fpga/core/rtl/escape_prio.v`: playfield pen bit 7 = `pf_color[3]`
  (no `| m7`).
- `sim/tools/mo_priority_model.py`: the same two rules.
- `sim/run_prio_tb.sh`: RTL vs model exhaustive, **507,904 / 507,904**.
- `sim/run_mob_tb.sh` on the level-1 map scene with the START box switched to
  its pen-1 twin in colour 4 (`sim/tools/make_shadow_twin_scene.py`): all
  296 covered pixels M7=1, SHADE=1, playfield wins, output pens
  `0x300 / 0x30D / 0x30E` — the game's dim bank. Before the fix: 0 pixels
  reached the comparator (specials rejected); with (1) alone: pens `0x38X`
  (black).
- `sim/run_stain_tb.sh`: unchanged, PASS (pens 2/4/6 behave as before).

## 6. What remains

- **Device verification** at a level ≥ 2 map on both platforms against the
  PCB capture t406–t410: travelled nodes and START box dim same-hue, no black,
  no slivers; level-1 map unchanged (all bright); gameplay shadows unchanged.
- Report both inaccuracies upstream (`eprom.cpp`) with the GAL equations.
- The `reference/map_level3_mame.png` render shows black nodes rather than
  MAME's bright ones; its provenance is unknown — do not cite it.

## Appendix — reproducing the evidence

```
# palette / MO / ext dumps on the level-1 map (harness in "Lloyd Projects/eprom-rev3-analysis")
SCRIPT=play3.txt ENDFRAME=3300 mame eprom -autoboot_script harness.lua ...   # map at frames ~2940-3120
python3 sim/tools/gal16v8.py gal16v8-136069.100v '{"11":"MCKR","9":"RCLKA","8":"/LMPD","7":"RB1","6":"MAT6","5":"/MSD3","4":"/MSD2","3":"/MSD1","2":"/MSD0","16":"/WE1","17":"/WE0","18":"/STON","19":"/STOFF"}'
python3 sim/tools/gal16v8.py gal16v8-136069.100t '{"1":"MPX1","2":"MPX0","3":"/MPX2","4":"/MPX3","5":"MPX4","6":"MPX5","7":"MPX6","8":"MPX7","9":"MPR0","11":"MPR1","12":"SHADE","13":"PFX6","14":"PFX5","15":"PFX3","16":"PFX4","17":"PF/M","18":"/FORCEMC0","19":"M7"}'
```
