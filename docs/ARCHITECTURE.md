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

- **Main CPU**: 68000/68010 @ 7.159 MHz (14.31818 MHz / 2) — production boards carry
  either part (see the CPU finding below)
- **Extra CPU**: second 68000/68010 @ 7.159 MHz (eprom/eprom2 only; klaxp & guts are single-CPU)
- **Shared RAM** between the two CPUs, with a sync register
- **Sound**: Atari JSA-I audio board — 6502 + YM2151 (+ POKEY, + TMS5220 speech).
  klaxp/guts use JSA-II which adds an OKI6295.
- **Video**: Atari motion-object (sprite) engine + two tilemaps (playfield 64×64,
  alpha/text 64×31), 2048-color palette with RGB intensity. A SLAPSTIC is fitted but
  never banked (see the findings below).
- **Display**: 336×240 active, 59.9227 Hz = 7,159,090 / (456×262 total).

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

**Findings from the full schematic re-scan (sheets 2–5), 2026-08-07:**
- **CPU type: 68000 or 68010, in either cabinet.** The schematic labels both CPUs
  **`U68010`** — sheet 4 (package page 5), designator **45J**, `VCPU`; and sheet 5
  (page 6), designator **20P**, `ECPU`. Re-read at 1200 dpi: the label is unambiguous,
  and the JAMMA manual TM-336 (a later revision of the same drawing) draws the same.
  The assembly drawing calls out Atari house number **`137414-002`** at both positions
  rather than a Motorola part number — one BOM line, either chip. The owner's
  dedicated-cabinet board carries **`MC68010P8`** (Motorola, date code **`A71R8813`**),
  and 68000 and 68010 have since each been photographed in a dedicated cabinet *and*
  in a JAMMA one. **It is not a cabinet distinction**, and the distribution across
  production is unknown — the current position, with sources, is in the top-level
  `README.md` acknowledgements. *(An earlier version of this note, 2026-08-07, read the
  two photographs then on hand as "dedicated = 68010, JAMMA = 68000"; the later
  photographs retired that.)* MAME's `eprom.cpp` instantiates `M68000`, so MAME matches
  a 68000-stuffed board. Every build up to and including BUILD 109 ran `CPU=>"00"`
  (68000) — an authentic configuration, not a bug. This core defaults to `CPU_TYPE = 1`
  (68010, the specified part and the one on the owner's board).
  It still does not matter for this core: the ROM uses no 68010-only instruction, no
  handler inspects an exception-frame format word or does pointer arithmetic around the
  frame, and 68010 loop mode is never entered (and TG68K does not implement loop mode
  in any case) — which is what makes supporting both variants free. Full evidence in
  [`CPU_AND_ARBITER.md`](CPU_AND_ARBITER.md) §1.6. Note the variant is **not**
  inferable from the ROM set, so it is a configuration choice — see `DEVIATIONS.md` C5.
- **Interrupts are autovectored** via VPA asserted on FC=111 (sheet 4, 60L/55L). VBLANK
  /VINT hits both CPUs (IRQ4); /SINT is the sound IRQ (IRQ6, main CPU only).
- **SLAPSTIC is physically present** (sheet 4: 60E `SLAPSTK5`, driving ROM bank selects
  BS13/BS14, `/STIK` decode) even though MAME's eprom map shows no slapstic window and
  boots without it. Resolved since: the game never banks through it, and the core
  deliberately does not implement it — see [`SLAPSTIC.md`](SLAPSTIC.md).
- **SCOM is a serial link chip** (sheet 2): sound comms travel over a serial cable
  (JSCM: /DATA /CLK FIN FOUT /SCBSY FULL /SINT) to the stand-alone audio PCB — not a
  parallel latch. Real JSA integration must model or bypass this serializer.
- **I/O details (sheet 3)**: buttons are DUCK/SPARE/FIRE/**JUMP** on CD11–CD8; status
  bits at 260010: D4 ADEOC, D3 /SCBSY, D2 /SINT, D1 S-TEST (1=normal play), D0 /VBLANK;
  ADC is an ADC0809 (IN0–3 = P1-U/D, P1-L/R, P2-U/D, P2-L/R). 360010 latch: CD5 VIDOFF,
  CD4–1 intensity IM3–0, CD0 /ERESET.
- **Common ROM lives on the ECPU side** (sheet 5: `CROM` U27512 pair at 40K/50K), sharing
  the common bus with the shared RAM (`COMRAM`, 32Kx8 pair at 40M/50M = `$160000-$16FFFF`).
  Ownership is a **cross-coupled NOR latch** — `ENOWAI = NOR(/ECOM, EWAI)` at 60N,
  `EWAI = NOR(/COM, ENOWAI)` at 20J — whose `EWAI` output selects the 30M LS158A control
  mux and the address/data buffers. **Wait states come from the 163 counters at 30D (VCPU)
  and 30L (ECPU), not from 50P**; 50P is the ECPU *address decoder* (`/ECOM`, `/COMRAM`,
  `/CROM`, `/CIO`, `/EROM0-2`), the counterpart of 50F PAL20L10 on the VCPU side. The loser
  of the arbitration is stalled by having its `/DTACK` withheld. Both CPUs access it with
  waits; our SDRAM
  request/ack arbitration reproduces the same contract.

**Design notes vs Atari System 1 (our RTL base):**
- Dual 68000 sharing RAM at `160000–16FFFF` + `EXTRA CPU reset` bit — System 1 is single-CPU.
- **Analog** Hall-effect joystick via ADC0–3 → the Pocket d-pad/stick must be mapped to
  analog values (see sheet 16 hall-sensor schematic).
- Sound via **SCOM** mailbox (`260030` read / `360030` write), not a shared audio bus.
- Motion objects use **SLIP pointers** (`3F4F80`); per-layer color RAM (alpha/MO/pf/shadow/stain).
- **No SLAPSTIC** window appears in Escape's map (System 1 has one). The part is on the
  board but never banked; not implemented ([`SLAPSTIC.md`](SLAPSTIC.md)).

## Strategy: adapt Arcade-Atari-system1_MiSTer (GPL-3.0)

Rather than build from scratch, base the RTL on **`MiSTer-devel/Arcade-Atari-system1_MiSTer`**
(GPL-3.0, VHDL) — the closest open, complete implementation of Escape's video/sound family.
`MiSTer-devel/Arcade-Gauntlet_MiSTer` is a second reference. Reusing this RTL makes **our
core GPL-3.0** (the `LICENSE` is set accordingly).

Reusable blocks — **the pre-bring-up plan** (already in the System 1 core unless noted).
The right-hand column records what the shipped core actually uses; the video path and
the EEPROM turned out to be written from scratch.

| Need                | Planned reuse                                     | What shipped |
|---------------------|---------------------------------------------------|--------------|
| Motion objects      | `MOHLB_LSI.vhd` / `MOHLB_TTL.vhd` (adapt to SLIP) | Own RTL: `escape_mob.v`, `escape_mo_cache.v` |
| Playfield / scroll  | `PFHS.vhd`, `VIDEO.vhd`                            | Own RTL: `escape_pf.v` |
| Sync generation     | `SYNGEN.vhd`, `LINECTR.vhd`, `LINEBUF.vhd`         | Own counters in `core_top.v` |
| Palette / color     | `CRAMS.vhd`, `RGBI.vhd`                            | Own RTL: `escape_prio.v`, `escape_stain.v`, colour RAM in `escape_core.vhd` |
| 6502 (sound)        | `T65/`                                            | `T65` from the System 1 tree, unmodified |
| 68000               | `TG68K/` (or swap in `fx68k`); Escape needs **two** | `TG68K`, two kernel files vendored into `rtl/tg68kv/` (TASLOCK-102 `LOCK` output) |
| POKEY               | `lib/POKEY.vhd`                                    | Not used — absent on Escape's JSA-I, not decoded on JSA-II |
| TMS5220 speech      | `TMS5220.vhd`                                      | Vendored into `rtl/` with the LANE3z lattice-filter fix |
| SLAPSTIC            | `SLAPSTIC.vhd` (likely unused by Escape — verify)  | Not implemented ([`SLAPSTIC.md`](SLAPSTIC.md)) |
| YM2151              | `jotego/jt51` (Pocket-proven)                      | `jt51`, two files vendored into `rtl/jt51v/` (per-channel gain) |
| OKI6295 (guts/klaxp)| `jotego/jt6295` (submodule `third_party/jt6295`, wired into `escape_jsa` `BOARD=2`, JSA2-164) | Milestone 0.2: in the MiSTer rbf, where `escape_jsa` builds both boards and picks at runtime (`BOARD_RT`, GAMESEL-167); pruned from the Pocket Escape bitstream |
| 93C46 EEPROM        | `jotego/jteeprom`                                 | Not used — the board's part is a **2804** (512 bytes), modelled as a BRAM in `escape_core.vhd` with `ee_save.vhd` for persistence |

## Status

*Updated 2026-10-17.* Shipped: Pocket **v0.1.1** (build 36) and MiSTer
**mister-v0.1.2** (build 161), both Escape only. Milestone 0.2 (unreleased test builds,
branches `milestone-0.2` and `milestone-0.2-mister`) adds the factory-map halftone
(MOSHADE-162, [`DEVIATIONS.md`](DEVIATIONS.md) C6/C7), Escape set 2 (EPROM2-163), and on
MiSTer the Klax prototypes and Guts n' Glory in one rbf. The MiSTer device check of
build 168 boots and plays all five games; the full test plan is pending and the Pocket
0.2 builds are not yet device-tested.

The 2026-08 status, kept as written: the roadmap below was written before hardware bring-up; every step of it is
now **done** — the core boots, renders all three video layers, speaks through
the full JSA-I sound board, and plays. The polish items that followed are done
too: sprite bandwidth (MOPAIR-131/MOPF2-132 — see
[`PIPELINES.md`](PIPELINES.md) §5.4), EEPROM persistence via the Pocket save
system ([`EEPROM_SAVE.md`](EEPROM_SAVE.md)), and release packaging as
`spoonelli.eprom` at version 0.1.0. Accuracy status lives in
[`DEVIATIONS.md`](DEVIATIONS.md); the MiSTer port in
[`MISTER.md`](MISTER.md).

The engineering history — what the 150+ builds taught, which instruments
cracked which bugs, and what a veteran would have done from day one — is
distilled in [`LESSONS.md`](investigations/LESSONS.md). The on-device debug tooling
(seven forensics HUD pages, crash latches, freeze rescue, scene
replay benches) is a permanent part of **every** build, release included —
it is hidden by default and reachable with L1 once **Developer HUD** is ticked
in the core menu (HUD-118), not compiled out. The CRAM
self-test checksums were retired at TASLOCK-102 and the sim benches cover
them now. See [`POCKET_TEST.md`](POCKET_TEST.md).

## Build variants (milestone 0.2)

One `escape_core` serves every game; what differs is a handful of generics and one
runtime input. All of this is unreleased 0.2 work — the shipped releases are the
Escape configuration only.

| Control | Kind | Meaning |
|---|---|---|
| `CPU_TYPE` | generic | 0 = 68000, 1 = 68010 (default). Set once in `core_top.v`. |
| `EXTRA_EN` | generic | 0 = no second CPU (Klax prototypes, Guts): the extra CPU, its shadows and their M10K are not built (KLAX-165). |
| `JSA_BOARD` | generic | 1 = JSA-I (YM2151 + TMS5220, Escape), 2 = JSA-II (YM2151 + OKI6295, Klax/Guts) (JSA2-164). |
| `JSA_RT` | generic | 1 = build both sound boards and follow `game_sel` at runtime — `escape_jsa`'s `BOARD_RT` (GAMESEL-167, MiSTer). |
| `VIDEO_MAP` | generic | 0 = video block at 3Fxxxx (Escape, Klax), 1 = FFxxxx (Guts) in `escape_decode`; the decoder also has a runtime `vmap` input (GUTS-166). |
| `game_sel` | port | 00 = Escape (either set), 01 = Klax prototype, 10 = Guts. Runtime on MiSTer (MRA game byte); tied to a constant in a Pocket build so synthesis prunes the rest. Inside `escape_core` it drives the extra-CPU reset, video map, JSA-II decode, joystick nibble and ADC presence. |
| `guts` | port | On `escape_mob` / `escape_prio` (GUTS-168): Guts n' Glory's MO format and priority rule. The platform top drives it — from `game_sel` on MiSTer, tied off in the Pocket Escape build. |

Image slots beyond the set-1 layout: Escape set 2's tenth program pair at **0x0A0000**
(`v_img` in `escape_core.vhd`, EPROM2-163); the JSA-II OKI ADPCM ROM at **0x240000**
(JSA2-164); Guts n' Glory's playfield tiles at **0x280000** (MiSTer selects that base when
`game_sel` = 10). Details: [`ROMMAP.md`](ROMMAP.md) and
[`investigations/KLAX_GUTS.md`](investigations/KLAX_GUTS.md).
