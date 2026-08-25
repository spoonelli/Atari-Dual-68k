# ROM map (eprom set)

Derived from MAME `ROM_START(eprom)`. All 28 mask ROMs in the user's local `eprom/` set
were **CRC32-verified against MAME known-good** (28/28, 0 mismatches). ROMs are **not**
stored in this repo — users supply their own dumps, loaded via APF data slots.

Chips are 27512-class 64 KB (0x10000) unless noted. `.50x` = even byte (D15–D8),
`.40x` = odd byte (D7–D0) for the 68000 big-endian word, except the `060000` pair
(`.40k` even / `.50k` odd) — follow the offsets below exactly.

## maincpu — Video CPU 68000 (region 0xA0000)

| Offset   | Even (high) | Odd (low)   |
|----------|-------------|-------------|
| `0x00000`| 3025.50a    | 3024.40a    |
| `0x20000`| 4027.50b    | 4026.40b    |
| `0x40000`| 4029.50d    | 4028.40d    |
| `0x60000`| 2033.40k    | 2032.50k    | (shared program, `060000–07FFFF`)

## extra — second 68000 (region 0x80000)

| Offset   | Even (high) | Odd (low)   |
|----------|-------------|-------------|
| `0x00000`| 2035.10s    | 2034.10u    |
| `0x60000`| copy of maincpu `0x60000` (0x20000 bytes) | |

## jsa:cpu — 6502 sound (region 0x10000)

`136069-1040.7b` @ `0x00000`. Holds 6502 program **and** TMS5220 speech LPC data
(JSA-I: YM2151 + TMS5220; no OKI6295, no separate sample ROM).

## spr_tiles — playfield tiles AND motion objects (region 0x100000, ROMREGION_INVERT)

In order @ 0x10000 stride: 1020.47s, 1013.43s, 1018.38s, 1023.32s, 1016.76s, 1011.70s,
1017.64s, 1022.57s, 1012.47u, 1010.43u, 1015.38u, 1021.32u, 1008.76u, 1009.70u,
1014.64u, 1019.57u. **Note the INVERT** — bytes are bit-inverted vs file contents.

**One region serves both layers.** MAME decodes it with a layout named
`pfmolayout` and `GFXDECODE_ENTRY("spr_tiles", 0, pfmolayout, 256, 32)` is gfx
index 0 — which is what `eprom_state::get_playfield_tile_info` sets
(`tileinfo.set(0, ...)`) *and* what the motion-object device is handed. There is
no separate playfield tile ROM on this board. (The `guts` sibling driver does
split them into `sprites`/`tiles`; `eprom` does not.)

Layout: 8×8, 4bpp, `RGN_FRAC(1,4)` — four 256 KB bit-planes, `planeoffset[0]` =
`RGN_FRAC(0,4)` = the MSB of the pixel value. `xoffset = STEP8(0,1)` (bit 7 is
the leftmost pixel), `yoffset = STEP8(0,8)`, 8 bytes per tile per plane, so
32768 tiles.

`support/build_rom.py` does **not** copy this region verbatim: it applies the
INVERT and then repacks the planes into chunky 4bpp. See [`ROMS.md`](ROMS.md).

## chars — alphanumerics (region 0x04000)

`136069-1007.125d` @ `0x00000` (16 KB).

## plds — GAL16V8 decode (not loaded as data)

`100t, 100v, 50f, 50p, 55p, 70j` — these are the address-decode/logic PALs; we
reimplement their equations in RTL rather than load them.

## eprom2 (clone) — **not** the same layout

All-rev-1 program ROMs: 1025.50a/1024.40a, 1027.50b/1026.40b, 1029.50d/1028.40d,
1033.40k/1032.50k (main); 1035.10s/1034.10u (extra). Graphics/sound shared with
the parent.

It is **not** a drop-in layout swap: `eprom2` loads a *tenth* maincpu chip pair,
1037.50e @ `0x80000` / 1036.40e @ `0x80001`, that the parent set does not have,
filling maincpu `0x80000–0x9FFFF`. The parent's maincpu data ends at `0x7FFFF`.
`support/build_rom.py` supports the parent `eprom` set only — its combined image
has the extra CPU at `0x080000`, where `eprom2`'s tenth chip pair would land.

## openFPGA image layout

Implemented, not planned. `support/build_rom.py` concatenates the regions into
one data-slot payload at the offsets in [`ROMS.md`](ROMS.md), applying the
sprite INVERT **and** a planar→chunky 4bpp repack. The MiSTer front end reaches
the same SDRAM contents from an `.mra` manifest plus an RTL-side repack, since
MRA can express neither transform (see `docs/MISTER.md` on the `mister-port`
branch).
