# Architecture & Implementation Roadmap

Hardware references, in order of authority:

1. **Original schematics** — `reference/schematics/` (Atari SP-332, 1989). Ground truth
   for clocking, sync generation, memory decode, and custom-chip wiring. See that folder's
   `README.md` for the sheet→module index (main PCB = sheets 2–10, audio = 11–14,
   memory map = sheet 16).
2. **MAME** — `reference/eprom.cpp` and device deps (`atarijsa`, `atarimo`, `slapstic`,
   `atarigen`). C++ *software emulation*: excellent for behavior and register semantics.

We use both to re-implement the hardware in Verilog for the Cyclone V. Nothing from MAME
is compiled into the core. Consult the schematic sheet(s) listed per roadmap step below.

## System overview (Atari "Escape" board)

- **Main CPU**: 68000 @ 7.159 MHz (14.31818 MHz / 2)
- **Extra CPU**: second 68000 @ 7.159 MHz (eprom/eprom2 only; klaxp & guts are single-CPU)
- **Shared RAM** between the two 68000s, with a sync register
- **Sound**: Atari JSA-I audio board — 6502 + YM2151 (+ POKEY, + TMS5220 speech).
  klaxp/guts use JSA-II which adds an OKI6295.
- **Video**: Atari motion-object (sprite) engine + two tilemaps (playfield 64×64,
  alpha/text 64×31), 2048-color palette with RGB intensity, SLAPSTIC bank protection.
- **Display**: 336×240 active, ~57.6 Hz (456×262 total).

## Main-CPU memory map (eprom / eprom2)

| Range              | Function                 |
|--------------------|--------------------------|
| `0x000000–0x09FFFF`| Program ROM (640 KB)     |
| `0x0E0000–0x0E03FF`| EEPROM                   |
| `0x160000–0x16FFFF`| Shared RAM               |
| `0x16CC00`         | Sync register            |
| `0x260000–0x260027`| I/O ports                |
| `0x2E0000`         | Watchdog                 |
| `0x360000–0x360031`| Video control            |
| `0x3E0000–0x3E0FFF`| Palette RAM              |
| `0x3F0000–0x3F1FFF`| Playfield VRAM           |
| `0x3F2000–0x3F3FFF`| Motion-object VRAM       |
| `0x3F4000–0x3F4F7F`| Alpha VRAM               |
| `0x3F8000–0x3F9FFF`| Playfield extension      |

(`guts` uses an inverted layout with video RAM at `0xFF8000–0xFFCFFF`.)

## Building blocks (open cores to vendor as submodules)

| Need            | Core            | Source                                  |
|-----------------|-----------------|-----------------------------------------|
| 68000 ×2        | `fx68k`         | https://github.com/ijor/fx68k           |
| 6502 (JSA)      | `T65`           | (opencores / MiSTer)                    |
| YM2151          | `jt51`          | https://github.com/jotego/jt51          |
| OKI6295 (JSA-II)| `jt6295`        | https://github.com/jotego/jt6295        |
| POKEY           | `pokey`         | (MiSTer Atari cores)                     |

## Roadmap

1. **[done]** APF scaffold — builds a gray screen, packages for the Pocket.
2. **CI build** — confirm a working Quartus image in GitHub Actions; produce `.rbf_r`.
3. **CPU bring-up** — integrate fx68k, wire program ROM (via APF data slot) + work RAM;
   get the main 68000 running with a stub video.
4. **Video** — playfield tilemap → alpha layer → motion objects → palette; hit 336×240.
5. **Dual-CPU** — second 68000 + shared RAM + sync register.
6. **Sound** — JSA-I: 6502 + jt51 (YM2151); then POKEY / TMS5220.
7. **SLAPSTIC** — protection state machine (needed to boot correctly).
8. **ROM loading** — define `data.json` slots + an `.mra`-style ROM manifest so users
   supply their own dumps; map them to the correct address spaces.
9. **Variants** — expose eprom / eprom2 / klaxp / guts selection.

## ROM strategy

The Pocket loads user-supplied ROMs through APF **data slots** (`data.json`). We define a
manifest that concatenates/orders the individual ROM chips into the layout the RTL expects
(mirroring how MAME's `ROM_START(eprom)` maps regions). No ROM data is stored in this repo.
