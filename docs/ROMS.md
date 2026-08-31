# Building and loading ROMs

This core ships **no ROM data**. You supply your own verified dumps of the Atari
"Escape" set (MAME set `eprom`) and assemble them into one image the core loads.

You need a clone (or source zip) of this repository for `support/build_rom.py`;
only Python 3 is required, no other dependencies.

## 1. Assemble the combined ROM

Point the tool at your original dumps — either a standard MAME `eprom.zip` or a
folder of the individual `136069-*.xxx` chips:

```bash
python3 support/build_rom.py /path/to/eprom.zip ./atari_escape.rom
```

Both forms produce a byte-identical image. With no arguments it looks for an
`eprom` folder next to the repository and writes `atari_escape.rom` next to
the script itself; pass both paths explicitly if you want them somewhere
else.

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
| `0x080000` | 512 KB  | extra — second 68000 | own program at `+0x00000`; MAME's `ROM_COPY` of maincpu `0x60000` at `+0x60000`; `0x0A0000–0x0DFFFF` zero-filled |
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

Copy `atari_escape.rom` to:

```
/Assets/eprom/common/atari_escape.rom
```

The filename matters — `data.json` declares a required data slot (id 1,
`atari_escape.rom`) and the Pocket will ask for that exact file; the APF loads
it into SDRAM at boot, where the core's memory controller serves each region to
the CPUs and video. `eprom` is the core's platform id, so the folder name is
fixed too. Full SD layout and the on-device test procedure are in
[`POCKET_TEST.md`](POCKET_TEST.md).

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
RTL. The MiSTer core is **not part of this release**; its docs (`docs/MISTER.md`)
and the `.mra` live on the `mister-port` branch.
