# Building and loading ROMs

This core ships **no ROM data**. You supply your own verified dumps of the Atari
"Escape" set (MAME set `eprom`) and assemble them into one image the core loads.

## 1. Assemble the combined ROM

Point the tool at your original dumps — either a folder of the individual
`136069-*.xxx` chips or a standard MAME `eprom.zip`:

```bash
python3 support/build_rom.py /path/to/eprom.zip dist/assets/atari_escape/common/atari_escape.rom
```

Every chip is **CRC32-verified** against known-good values; wrong or modified dumps
are refused. The output stays local: `.rom` files are git-ignored, the release
packager refuses to include them, and a pre-commit hook blocks them outright.

This produces `atari_escape.rom` (2,228,224 bytes). Layout (SDRAM byte offsets):

| Offset     | Size    | Region  |
|------------|---------|---------|
| `0x000000` | 512 KB  | maincpu (Video CPU program) |
| `0x080000` | 512 KB  | extra (Extra CPU program + shared copy) |
| `0x100000` | 64 KB   | JSA 6502 program + TMS5220 speech |
| `0x110000` | 16 KB   | alphanumerics (chars) |
| `0x120000` | 1024 KB | motion-object graphics (bit-inverted) |

The tool verifies each chip's size; run it against a set whose CRC32s match MAME's
known-good values (this project's `eprom` set was verified 28/28).

## 2. Put it on the Pocket SD card

Copy `atari_escape.rom` to:

```
/Assets/atari_escape/common/atari_escape.rom
```

The core's `data.json` declares a required data slot (id 1, `atari_escape.rom`); the
APF loads it into SDRAM at boot, where the core's memory controller reads each region.

> ROM assembly and loading are set up; the core-side SDRAM memory controller that serves
> these regions to the CPUs and video is part of the ongoing core_top integration — see
> docs/ARCHITECTURE.md.
