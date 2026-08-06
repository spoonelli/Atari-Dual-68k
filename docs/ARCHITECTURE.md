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

## Memory map — authoritative (schematic SP-332, sheet 16)

Transcribed from the original Atari memory map. This supersedes the MAME-approximated
version; note the differences (EEPROM range, per-layer color RAM, SLIP pointers).

### Video CPU (main 68000) — byte or word

| Range               | R/W | Data    | Function |
|---------------------|-----|---------|----------|
| `000000–05FFFF`     | R   | D15–D0  | Program ROM |
| `080000–09FFFF`     | R   | D15–D0  | Program ROM |
| `0E0001–0E2FFF`     | R/W | D7–D0   | EEPROM |
| `1Fxxxx`            | W   |         | Unlock EEPROM |
| `2E0000`            | W   |         | Watchdog (128 ms timeout) |
| `3E0000–3E01FF`     | R/W | D15–D0  | Color RAM — Alpha |
| `3E0200–3E03FF`     | R/W | D15–D0  | Color RAM — Motion Object |
| `3E0400–3E05FF`     | R/W | D15–D0  | Color RAM — Playfield |
| `3E0600–3E07FF`     | R/W | D15–D0  | Color RAM — Playfield Shadow |
| `3E0800–3E0FFF`     | R/W | D15–D0  | Color RAM — STAIN |
| `3F0000–3F1FFF`     | R/W | D15–D0  | Playfield picture RAM |
| `3F2000–3F3FFF`     | R/W | D15–D0  | Motion Object RAM (link, picture, H/V pos) |
| `3F4000–3F4EFF`     | R/W | D15–D0  | AlphaNumerics RAM |
| `3F4F00–3F4F7F`     | R/W | D15–D0  | Scroll and MOB config |
| `3F4F80–3F4FFF`     | R/W | D9–D0   | SLIP pointers (M.O. link) |
| `3F5000–3F7FFF`     | R/W | D15–D0  | Working RAM |
| `3F8000–3F9FFF`     | R/W | D11–D8  | Playfield palette RAM |

### Extra CPU (second 68000)

| Range           | R/W | Data   | Function |
|-----------------|-----|--------|----------|
| `000000–05FFFF` | R   | D15–D0 | Program ROM |
| (common below)  |     |        |          |

### Common (both processors)

| Range           | R/W | Data   | Function |
|-----------------|-----|--------|----------|
| `060000–07FFFF` | R   | D15–D0 | Program ROM |
| `160000–16FFFF` | R/W | D15–D0 | Program RAM (shared) |

### I/O — word mode only

| Address    | R/W | Bits | Function |
|------------|-----|------|----------|
| `260000`   | R   | D8–D11 | Player 1 input |
| `260010`   | R   | D8–D11 | Player 2 input (D11 duck, D9 fire, D8 start) |
| `260010`   | R   | D0   | VBLANK (active lo) |
| `260010`   | R   | D1   | Self-test |
| `260010`   | R   | D2/D3| Input/Output buffer full (SCOM @260030) |
| `260010`   | R   | D4   | ADEOC end-of-conversion (active hi) |
| `260020/22/24/26` | R | D0–D7 | ADC0–3 (analog Hall-effect joystick) |
| `260030`   | R   | D0–D7 | Read Sound Processor (SCOM) |
| `360000`   | W   |      | VBLANK interrupt ack |
| `360010`   | W   | D5   | Video Off (0=on) |
| `360010`   | W   | D4–D1| Video Intensity (0=full on) |
| `360010`   | W   | D0   | EXTRA CPU reset (lo = reset) |
| `360020`   | W   |      | Sound Processor reset |
| `360030`   | W   | D0–D7 | Write Sound Processor (SCOM) |

**Design notes vs Atari System 1 (our RTL base):**
- Dual 68000 sharing RAM at `160000–16FFFF` + `EXTRA CPU reset` bit — System 1 is single-CPU.
- **Analog** Hall-effect joystick via ADC0–3 → the Pocket d-pad/stick must be mapped to
  analog values (see sheet 16 hall-sensor schematic).
- Sound via **SCOM** mailbox (`260030` read / `360030` write), not a shared audio bus.
- Motion objects use **SLIP pointers** (`3F4F80`); per-layer color RAM (alpha/MO/pf/shadow/stain).
- **No SLAPSTIC** window appears in Escape's map (System 1 has one) — verify, but likely unused.

## Strategy: adapt Arcade-Atari-system1_MiSTer (GPL-3.0)

Rather than build from scratch, base the RTL on **`MiSTer-devel/Arcade-Atari-system1_MiSTer`**
(GPL-3.0, VHDL) — the closest open, complete implementation of Escape's video/sound family.
`MiSTer-devel/Arcade-Gauntlet_MiSTer` is a second reference. Reusing this RTL makes **our
core GPL-3.0** (the `LICENSE` is set accordingly).

Reusable blocks (already in the System 1 core unless noted):

| Need                | Reuse                                             |
|---------------------|---------------------------------------------------|
| Motion objects      | `MOHLB_LSI.vhd` / `MOHLB_TTL.vhd` (adapt to SLIP) |
| Playfield / scroll  | `PFHS.vhd`, `VIDEO.vhd`                            |
| Sync generation     | `SYNGEN.vhd`, `LINECTR.vhd`, `LINEBUF.vhd`         |
| Palette / color     | `CRAMS.vhd`, `RGBI.vhd`                            |
| 6502 (sound)        | `T65/`                                            |
| 68000               | `TG68K/` (or swap in `fx68k`); Escape needs **two** |
| POKEY               | `lib/POKEY.vhd`                                    |
| TMS5220 speech      | `TMS5220.vhd`                                      |
| SLAPSTIC            | `SLAPSTIC.vhd` (likely unused by Escape — verify)  |
| YM2151              | `jotego/jt51` (Pocket-proven)                      |
| OKI6295 (guts/klaxp)| `jotego/jt6295`                                   |
| 93C46 EEPROM        | `jotego/jteeprom`                                 |

## Roadmap

1. **[done]** APF scaffold — builds a gray screen, packages for the Pocket.
2. **CI build** — Quartus image validated (install + Cyclone V download work); blocked only
   by GitHub-hosted-runner acquisition on the account. Local Docker+Quartus fails under
   Apple-Silicon x86 emulation (`quartus_map` crash). Bitstream deferred; not blocking RTL.
3. **[done]** Import base + native sim — System 1 RTL added as submodule; **GHDL** sim
   harness (`sim/`) runs on the Mac with no Quartus. 16/18 base modules elaborate; `SYNGEN`
   verified at **456 clocks/line == Escape's raster**. Verification path secured.
4. **Memory map** — rework decode to Escape's map (sheet 16): ROM/RAM regions, SCOM, ADCs.
5. **CPU** — dual 68000 + shared RAM at `160000–16FFFF` + `EXTRA CPU reset`.
6. **Video** — adapt motion objects to **SLIP pointers**; per-layer color RAM; 336×240.
7. **Sound** — JSA-I via SCOM mailbox: 6502 + jt51 (YM2151) + TMS5220 (+ POKEY if present).
8. **Inputs** — map Pocket d-pad/stick to the analog Hall-effect joystick (ADC0–3).
9. **ROM loading** — `data.json` slots + `.mra`-style manifest; user-supplied dumps only.
10. **Variants** — eprom / eprom2 / klaxp / guts (JSA-II adds OKI6295).

## ROM strategy

The Pocket loads user-supplied ROMs through APF **data slots** (`data.json`). We define a
manifest that concatenates/orders the individual ROM chips into the layout the RTL expects
(mirroring how MAME's `ROM_START(eprom)` maps regions). No ROM data is stored in this repo.
