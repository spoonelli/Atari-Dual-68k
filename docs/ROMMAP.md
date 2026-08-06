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

## spr_tiles — motion-object graphics (region 0x100000, ROMREGION_INVERT)

In order @ 0x10000 stride: 1020.47s, 1013.43s, 1018.38s, 1023.32s, 1016.76s, 1011.70s,
1017.64s, 1022.57s, 1012.47u, 1010.43u, 1015.38u, 1021.32u, 1008.76u, 1009.70u,
1014.64u, 1019.57u. **Note the INVERT** — bytes are bit-inverted vs file contents.

## chars — alphanumerics (region 0x04000)

`136069-1007.125d` @ `0x00000` (16 KB).

## plds — GAL16V8 decode (not loaded as data)

`100t, 100v, 50f, 50p, 55p, 70j` — these are the address-decode/logic PALs; we
reimplement their equations in RTL rather than load them.

## eprom2 (clone)

Same layout, all-rev-1 program ROMs: 1025.50a/1024.40a, 1027.50b/1026.40b,
1029.50d/1028.40d, 1033.40k/1032.50k (main); 1035.10s/1034.10u (extra);
1037.50e/1036.40e present. Graphics/sound shared with parent.

## openFPGA loading plan

Concatenate regions into data-slot payload(s) in the order the RTL expects (an
`.mra`-style manifest builds this from the individual chips). Sprite region must apply
the INVERT. Final mapping finalized alongside the memory-decode RTL (see ARCHITECTURE.md).
