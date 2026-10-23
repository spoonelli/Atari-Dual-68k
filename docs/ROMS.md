# Building and loading ROMs

This core ships **no ROM data**. You supply your own verified dumps of the Atari
"Escape" set (MAME set `eprom`, or the all-rev-1 clone `eprom2`) and assemble
them into one image the core loads.

You need a clone (or source zip) of this repository for `support/build_rom.py`;
only Python 3 is required, no other dependencies.

## 1. Assemble the combined ROM

Point the tool at your original dumps — either a standard MAME `eprom.zip` or a
folder of the individual `136069-*.xxx` chips:

```bash
python3 support/build_rom.py /path/to/eprom.zip ./atari_escape.rom
```

Both forms produce a byte-identical image, and every MAME set type works
(BUILDROM-176/184): non-merged; split, where a clone zip such as `eprom2.zip`
borrows the shared chips from `eprom.zip` beside it; and merged, where
`eprom.zip` carries set 2 in an `eprom2/` subfolder. With no `--set` the tool
builds every supported set it finds (a merged `eprom.zip` gives both
`atari_escape.rom` and `atari_escape2.rom`); `--set eprom2` builds just one. With no arguments it looks for an
`eprom` folder next to the repository and writes the image next to the script
itself, named for the set it detects: `atari_escape.rom` (set 1),
`atari_escape2.rom` (set 2), or `<setname>.rom` for the prototypes; pass both
paths explicitly if you want them somewhere else. The set is detected from the chips present (`136069-3025.50a` = set 1,
`136069-1025.50a` = set 2). A set-2 folder that lacks the shared
graphics/sound chips may sit next to an `eprom` folder and borrow them, the
way MAME's clone lookup does. Set 2 is device-verified on both platforms. The
tool also assembles the Klax prototype and Guts n' Glory images
(`klaxp1`/`klaxp2`/`guts`, detected from their first main chip; 2.5 MB and
3.5 MB, with the JSA-II ADPCM at `0x240000` and Guts' tile region at
`0x280000`) for their Pocket cores (section 3b). MiSTer runs those games from
MRAs and the MAME zips instead (see [MiSTer](#mister) below and
`investigations/KLAX_GUTS.md`).

Every chip is **CRC32-verified** against MAME's known-good values, and its size
is checked. A missing chip, a short chip, or a wrong/modified dump aborts the
build with a named error and **no output file is written** — the tool never
produces a half-correct image from a bad set.

The output stays local: `.rom` files are git-ignored and the release packager
refuses to include them (see [zero-ROM guarantee](#zero-rom-guarantee) below).

## 2. What the image contains

This produces `atari_escape.rom` (2,228,224 bytes = `0x220000`). Layout (SDRAM
byte offsets):

| Offset     | Size    | Region  | Transform vs the raw chips |
|------------|---------|---------|----------------------------|
| `0x000000` | 512 KB  | maincpu — Video CPU program | 16-bit interleave: even byte = `.50x`, odd = `.40x` (the `0x60000` pair is reversed — see [`ROMMAP.md`](ROMMAP.md)) |
| `0x080000` | 512 KB  | extra — second 68000 | own program at `+0x00000`; MAME's `ROM_COPY` of maincpu `0x60000` at `+0x60000`; `0x0A0000–0x0DFFFF` zero-filled (set 1) |
| `0x0A0000` | 128 KB  | maincpu `0x80000–0x9FFFF` — **set 2 only** | the tenth main pair (`1037.50e`/`1036.40e`), interleaved like the others; the core remaps the video CPU's A19 window here (see [`ROMMAP.md`](ROMMAP.md)) |
| `0x100000` | 64 KB   | JSA 6502 program + TMS5220 speech | none (verbatim) |
| `0x110000` | 16 KB   | alphanumerics (chars) | none (verbatim, padded to 64 KB) |
| `0x120000` | 1024 KB | `spr_tiles` — **playfield tiles _and_ motion objects** | **two** transforms: bit-invert, then 4 bit-planes → chunky 4bpp |

Two things about the last row that you cannot get from a MAME romset alone:

* **It is not the motion-object ROM.** MAME calls the region `spr_tiles` and
  decodes it with a layout literally named `pfmolayout`; both
  `get_playfield_tile_info` and the motion-object device read gfx index 0, i.e.
  this one region. The background tiles and the sprites come out of the same
  1 MB.
* **The image is not a dump of that region.** `ROMREGION_INVERT` bit-inverts
  every byte, and the tool then repacks the four 256 KB bit-planes into chunky
  4bpp so the core can fetch a whole tile row in one SDRAM burst: per tile row,
  4 bytes = 8 pixels, high nibble first, plane 0 → bit 3. So `0x120000` is
  **not** byte-comparable to MAME's `spr_tiles` region, by design.

Region contents were checked against MAME's own `ROM_START(eprom)` offsets and
`pfmolayout`: all 32768 8×8 tiles decode to identical pixel values.

## 3. Put it on the Pocket SD card

Copy `atari_escape.rom` (and, for set 2, `atari_escape2.rom`) to:

```
/Assets/eprom/common/atari_escape.rom
/Assets/eprom/common/atari_escape2.rom
```

The filenames matter. From milestone 0.2 (POCKETSET-175) the core starts by
listing its romsets: the package ships one APF instance JSON per set in
`/Assets/eprom/spoonelli.eprom/` (set 2 inside `_alternatives/`, the layout
jotego's Pocket cores use), and each names its set's file above and its own
save file. Set 1 keeps the original names, so a card set up for 0.1.x works
unchanged. The APF loads the chosen image into SDRAM at boot, where the core's memory controller serves each region to
the CPUs and video. `eprom` is the core's platform id, so the folder name is
fixed too. Full SD layout and the on-device test procedure are in
[`POCKET_TEST.md`](POCKET_TEST.md).

### 3b. The Klax and Guts n' Glory Pocket cores (v0.3.0)

Each is its own core with its own platform folder (POCKETVAR-182):

```
/Assets/klaxp/common/klaxp1.rom   \  python3 build_rom.py <klax set>   (builds both;
/Assets/klaxp/common/klaxp2.rom   /                                  --set picks one)
/Assets/guts/common/guts.rom         python3 build_rom.py <guts set>
```

`<klax set>` can be a merged `klax.zip` / `klax` folder (the prototypes in
`klaxp1/` and `klaxp2/` subfolders; the shared chips live only under
`klaxp1/`, which the tool finds by CRC — BUILDROM-184) or split `klaxp1.zip` /
`klaxp2.zip` next to `klax.zip`. With no `--set` the tool builds every
supported set it finds, each under its own name. The Klax core lists set 1 at launch, set 2 inside
`_alternatives`; saves are per set (`/Saves/klaxp/common/klaxp1.sav`,
`klaxp2.sav`; `/Saves/guts/common/guts.sav`).

## Zero-ROM guarantee

No ROM data enters this repository or any release package, ever. Three
mechanisms, in order of how much they are worth:

1. **`support/package.sh` refuses to build a package containing ROM data.** Four
   guards, three of which assert the *content* of the output rather than
   filenames. Run `support/test_package_guards.sh` to watch each one refuse a
   decoy — the guards are provoked on demand rather than assumed.
2. **`.gitignore`** excludes `*.rom` and `dist/assets/**/*.rom`.
3. **An optional pre-commit hook** blocks staged `.rom`/`.hex` files and
   unexpectedly large files. Git hooks are not versioned, so it is **not
   installed by cloning** — install it yourself if you want it:
   ```bash
   cp support/git-hooks/pre-commit .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
   ```

## MiSTer

The MiSTer front end does not use this tool: it reads the MAME zip directly via
an `.mra` manifest, and its loader applies the same two sprite transforms in
RTL. The MiSTer core is **not part of this release**; it is released
separately and is in the official MiSTer distribution — see
[`MISTER.md`](MISTER.md). Its RTL and MRAs live on the `mister` branch
(milestone 0.2 work, including the set-2, Klax and Guts MRAs, on
`milestone-0.2-mister`).
