# Atari Dual 68k — openFPGA core (Analogue Pocket)

An LLM-assisted openFPGA core for Atari Games' **"Escape"** arcade hardware — the dual-68010 board
whose flagship title is *Escape from the Planet of the Robot Monsters* (**E.P.R.O.M.**). The same board also ran the *Klax* prototype and *Guts n' Glory*
prototype, so the core covers all three.

> Built for the [Analogue Pocket](https://www.analogue.co/pocket) via the openFPGA framework.
> This project ships **no ROMs**. You must supply your own dumps.

## Status

🟢 **Boots on real hardware.** Both 68010s execute the genuine Escape program on the
Pocket: the ROM (user-supplied) loads through an APF data slot into SDRAM, a hardware
self-check verifies the download, and the CPU subsystem — memory decode, dual CPUs,
autovectored VBLANK IRQs, control latches — runs the real boot code. Verified on-device
via an 8-band diagnostic status screen (see [`docs/POCKET_TEST.md`](docs/POCKET_TEST.md)).

No game video or sound yet — the screen currently shows diagnostics, not the game.

| Subsystem | State |
|---|---|
| Build (CI, Quartus in Docker) | ✅ ~2 min per push, `bitstream.rbf_r` artifact |
| Native simulation (GHDL, no Quartus) | ✅ full boot verified pre-hardware |
| ROM loading (data slot → SDRAM) | ✅ verified on hardware (self-check green) |
| Video CPU (68010) | ✅ executes real code on hardware |
| Extra CPU (68010) + shared RAM | ✅ both CPUs run concurrently on hardware; handshake verified |
| Video: raster/sync (456×262 native) | ✅ on hardware · game layers (alpha → playfield → motion objects) not started |
| Sound (JSA-I: 6502 + YM2151 + TMS5220) | ⬜ stubbed (SCOM returns buffers-empty) |
| Inputs | ✅ buttons mapped · ADC (Hall stick) stubbed centered |
| EEPROM | stub RAM (no persistence) |

Full hardware map, roadmap, and schematic findings: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Hardware being implemented

Primary reference is the original Atari SP-332 schematic package (see
`reference/schematics/README.md` — the PDF itself is not redistributed); MAME's
`eprom.cpp` driver family is the behavioral cross-check. Notably, the schematics
corrected MAME on several points (68010s not 68000s, autovectored IRQs, SLAPSTIC
present, serial SCOM sound link).

| Block        | Real chip                               | Implementation |
|--------------|-----------------------------------------|----------------|
| CPUs ×2      | **68010** @ 7.16 MHz, shared RAM        | TG68K (`CPU="01"`), our decode/arbitration |
| Sound        | Atari **JSA-I** (6502 + YM2151 + TMS5220) via serial SCOM | T65 + [jt51](https://github.com/jotego/jt51) — planned |
| Video        | Atari motion objects + playfield + alpha | adapt from Atari System 1 core — in progress |
| Protection   | **SLAPSTIC** (present on board)          | watch-item; MAME boots without it |
| Palette      | 2048-color, per-layer color RAM + intensity | planned with video layers |
| Output       | 336×240 visible, 456×262 @ ~59.9 Hz      | ✅ native timing via APF scaler |

## Accuracy

This is a **behaviorally accurate** core with authentic timing anchors — not a
cycle-exact replica. Honest classification:

**Authentic (schematic-verified):** clock frequencies (7.159 MHz 68010s, true pixel
clock, all clocks derived from the board's 14.318 MHz colorburst family); raster
geometry (456×262 total, 336×240 visible, ~59.92 Hz); complete memory map, register
and latch semantics (sheet 16 + MAME cross-checked); genuinely concurrent dual CPUs
(the real board's architecture — MAME time-slices); IRGB palette math with intensity;
autovectored interrupt scheme.

**Approximate:** per-instruction CPU cycle counts (TG68K is instruction-accurate, not
cycle-exact to a 68010 — no cycle-exact open 68010 core exists); bus-cycle timing (the
original used zero-wait parallel EPROM buses per subsystem; this core funnels memory
through one SDRAM with wait states, mitigated by burst reads and sequential prefetch);
video internals (same VRAM in, same pixels out on the same raster grid, but the
scanout is a re-architected line engine, not a gate-level MOHLB/SLAGS clone).

Escape's game logic is IRQ- and frame-driven rather than cycle-counted, so gameplay
behavior should be indistinguishable from the arcade. This places the core in the same
class as most MiSTer/openFPGA arcade cores.

## Repo layout

```
core.json, video.json, data.json, ...   openFPGA core definition (APF)
dist/                                    platform art + asset folder skeleton
src/fpga/                                Quartus project
  apf/                                   Analogue Platform Framework (do not edit)
  core/core_top.v                        top level: SDRAM, ROM download, diagnostics
  core/rtl/                              our core: escape_core, decode, SDRAM ctrl, BRAMs
sim/                                     GHDL simulation harness + testbenches
support/build_rom.py                     assemble user ROM dumps -> atari_escape.rom
support/package.sh                       build a Pocket SD-layout release zip (no ROMs)
reference/                               MAME driver sources; schematics stay local-only
docs/ARCHITECTURE.md                     hardware map, roadmap, schematic findings
docs/ROMS.md, docs/POCKET_TEST.md        ROM building; on-device test guide
third_party/                             Arcade-Atari-system1_MiSTer submodule (RTL base)
```

## Building & testing

- **Bitstream**: GitHub Actions compiles every push inside
  `theypsilon/quartus-lite-c5:18.1` (Quartus never runs locally on macOS) and uploads
  `bitstream.rbf_r`. Package for the Pocket with `./support/package.sh <rbf_r>`.
- **Simulation**: `./sim/run_tb.sh tb_escape_core` runs the full core boot under GHDL
  (Docker), no FPGA toolchain needed. See `sim/README.md`.
- **ROMs**: build your own image per [`docs/ROMS.md`](docs/ROMS.md); nothing is downloaded
  or distributed by this repo, and `support/package.sh` refuses to package ROM data.
- **On device**: follow [`docs/POCKET_TEST.md`](docs/POCKET_TEST.md).

## License

**GPL-3.0** — see [`LICENSE`](LICENSE). The RTL base is
[`MiSTer-devel/Arcade-Atari-system1_MiSTer`](https://github.com/MiSTer-devel/Arcade-Atari-system1_MiSTer)
(GPL-3.0); the openFPGA APF framework is from
[`open-fpga/core-template`](https://github.com/open-fpga/core-template).

## Legal

This core contains no copyrighted ROM data, and no copyrighted schematics. Escape from the
Planet of the Robot Monsters, Klax, and Guts n' Glory are trademarks of their respective
rights holders. Use only with software you are legally entitled to.
