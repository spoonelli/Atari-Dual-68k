# Atari Dual 68k — openFPGA core (Analogue Pocket)

An LLM-assisted openFPGA core for Atari Games' **"Escape"** arcade hardware — the dual-68000 board
whose flagship title is *Escape from the Planet of the Robot Monsters* (**E.P.R.O.M.**). The same board also ran the *Klax* prototype and *Guts n' Glory*
prototype, so the core covers all three.

> Built for the [Analogue Pocket](https://www.analogue.co/pocket) via the openFPGA framework.
> This project ships **no ROMs**. You must supply your own dumps.

## Status

🕹️ **The game is playable.** From a user-supplied ROM, the core boots the real
dual-68000 program, runs the full attract cycle (story, announcer speech, high
scores, demo), takes coins, starts, and plays: Jake walks, robots swarm, the
JSA-I sound board delivers music, effects and TMS5220 speech in real time.
Development continues on visual polish and final timing feel.

| Subsystem | State |
|---|---|
| Build (CI, Quartus in Docker) | ✅ ~15 min per push, `bitstream.rbf_r` artifact |
| Native simulation (GHDL + iverilog) | ✅ boot, march, JSA, speech-chip and sprite-scene replay benches |
| ROM loading (data slot → SDRAM + CRAM + BRAM shadows) | ✅ verified, self-checked |
| Dual 68000s + shared RAM + mailbox handshake | ✅ genuinely concurrent on hardware |
| Hot-code BRAM shadows + speculative prefetch | ✅ ~98% of profiled gameplay execution at zero-wait |
| Video: alpha / playfield / motion objects, IRGB palette + intensity | ✅ pixel-verified vs MAME scene replay |
| Sound (JSA-I: 6502 + YM2151 + **TMS5220 speech**) | ✅ full pipeline, MAME-bus-trace verified |
| Inputs (buttons, hall-stick via ADC0809, dock analog) | ✅ incl. in-game calibration screens |
| Watchdog, freeze-rescue, on-device forensics HUD | ✅ (debug pages behind L/R, dev builds) |
| EEPROM (2804) | ✅ in-session; persistence via Pocket save: planned |

**Known issues:** dense sprite crowds can drop scanlines (bandwidth work in
progress); occasional small sprite artifacts; speech phrase tails clip slightly;
some scenes run marginally under arcade speed. See the issue tracker.

**Core identities:** dev builds install as `spoonelli.ataridual68k`; the
release core will ship as `spoonelli.eprom` (platform `eprom`, ROM goes in
`Assets/eprom/common/`). Platform art is user-supplied (not distributed),
like the ROMs.

Full hardware map, roadmap, and schematic findings: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Hardware being implemented

Primary reference is the original Atari SP-332 schematic package (see
`reference/schematics/README.md` — the PDF itself is not redistributed); MAME's
`eprom.cpp` driver family is the behavioral cross-check. Notably, the schematics
corrected MAME on several points (autovectored IRQs, SLAPSTIC
present, serial SCOM sound link).

| Block        | Real chip                               | Implementation |
|--------------|-----------------------------------------|----------------|
| CPUs ×2      | **68010** dedicated cab / **68000** JAMMA, @ 7.16 MHz, shared RAM | TG68K, our decode/arbitration (see C5) |
| Sound        | Atari **JSA-I** (6502 + YM2151 + TMS5220) via serial SCOM | ✅ T65 + [jt51](https://github.com/jotego/jt51) + TMS5220 (System 1 core, patched) |
| Video        | Atari motion objects + playfield + alpha | ✅ re-architected line engine, MAME-scene verified |
| Protection   | **SLAPSTIC** (present on board)          | watch-item; MAME boots without it |
| Palette      | 2048-color, per-layer color RAM + intensity | ✅ incl. authentic attract dimming |
| Output       | 336×240 visible, 456×262 @ ~59.9 Hz      | ✅ native timing via APF scaler |

## Accuracy

This is a **behaviorally accurate** core with authentic timing anchors — not a
cycle-exact replica. Honest classification:

**Authentic (schematic-verified):** clock frequencies (7.159 MHz CPUs, true pixel
clock, all clocks derived from the board's 14.318 MHz colorburst family); raster
geometry (456×262 total, 336×240 visible, ~59.92 Hz); complete memory map, register
and latch semantics (sheet 16 + MAME cross-checked); genuinely concurrent dual CPUs
(the real board's architecture — MAME time-slices); IRGB palette math with intensity;
autovectored interrupt scheme.

**Approximate:** per-instruction CPU cycle counts (TG68K is instruction-accurate, not
cycle-exact to a 68000); bus-cycle timing (the
original used zero-wait parallel EPROM buses per subsystem; this core splits memory
across SDRAM, a dedicated CRAM chip for graphics, and BRAM shadows holding the
profiled hot code — ~98% of gameplay execution runs zero-wait, the rest via
speculative prefetch);
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
  core/core_top.v                        top level: SDRAM/CRAM services, download, video, HUD
  core/rtl/                              our core: escape_core, decode, SDRAM ctrl, BRAMs
src/mister/                              MiSTer (DE10-Nano) Quartus project
  Arcade-Escape.sv                       MiSTer top level (hps_io, arcade_video, PLL)
  rtl/escape_mister.v                    machine assembly: same escape_core, MiSTer glue
  releases/*.mra                         ROM manifest (MAME CRCs only, zero ROM bytes)
  sys/                                   vendored MiSTer framework (do not edit)
sim/                                     GHDL simulation harness + testbenches
support/build_rom.py                     assemble user ROM dumps -> atari_escape.rom
support/package.sh                       build a Pocket SD-layout release zip (no ROMs)
reference/                               MAME driver sources; schematics stay local-only
docs/PIPELINES.md                        how the data/processing pipelines should work
docs/RETROSPECTIVE.md                    how it was debugged, incl. the false turns
docs/ARCHITECTURE.md                     hardware map, roadmap, schematic findings
docs/DEVIATIONS.md                       where this core is not the board, measured
docs/ROMS.md, docs/POCKET_TEST.md        ROM building; on-device test guide
third_party/                             Arcade-Atari-system1_MiSTer submodule (RTL base)
```

## MiSTer (DE10-Nano)

There is a second front end in `src/mister/` that runs the **same machine RTL**
on a DE10-Nano, loaded from a community-standard `.mra`. It compiles, and that
is all anyone can honestly claim so far — it has never been run on hardware.
Requirements, SD-card layout, the ROM-mapping rationale, and an explicit
verified/unverified list are in [`docs/MISTER.md`](docs/MISTER.md).

## Get it

**Recommended:** grab the latest package from the
[**Releases page**](https://github.com/spoonelli/Atari-Dual-68k/releases) —
unzip onto your Pocket SD, add your own ROM per
[`docs/ROMS.md`](docs/ROMS.md), play. (Alpha pre-releases are dev builds:
build number + diagnostic HUD on screen, see
[`docs/POCKET_TEST.md`](docs/POCKET_TEST.md).)

## Build it yourself (contributors)

No local FPGA toolchain needed — GitHub Actions compiles the bitstream for you.

1. **Fork** this repo on GitHub and enable Actions on your fork
   (Actions tab → "I understand… enable").
2. **Trigger a build**: Actions → *Build core (Quartus)* → *Run workflow* on
   `main` (or just push any commit). Takes ~15 minutes.
3. **Download** the `bitstream` artifact from the finished run.
4. **Clone locally** (submodules are required — a plain clone will not build):
   ```bash
   git clone --recursive https://github.com/<you>/Atari-Dual-68k
   ```
5. **Package** the Pocket SD zip (contains no ROMs, by design):
   ```bash
   ./support/package.sh path/to/bitstream/output/bitstream.rbf_r
   ```
6. **ROM**: build `atari_escape.rom` from your own verified dumps per
   [`docs/ROMS.md`](docs/ROMS.md) and place it at `Assets/eprom/common/` on the SD.
7. Unzip the package onto the SD, launch **Atari Dual 68k** on the Pocket.

Dev builds show a build number bottom-right and diagnostic HUD pages on
L / R / R2 — that is expected; the clean-screen release core comes later.

## Building & testing

- **Bitstream**: GitHub Actions compiles every push inside
  `theypsilon/quartus-lite-c5:18.1` (Quartus never runs locally on macOS) and uploads
  `bitstream.rbf_r`. Package for the Pocket with `./support/package.sh <rbf_r>`.
- **Simulation**: `./sim/run_tb.sh tb_escape_core` runs the full core boot under GHDL
  (Docker), no FPGA toolchain needed. See `sim/README.md`.
- **ROMs**: build your own image per [`docs/ROMS.md`](docs/ROMS.md); nothing is downloaded
  or distributed by this repo, and `support/package.sh` refuses to package ROM data.
- **On device**: follow [`docs/POCKET_TEST.md`](docs/POCKET_TEST.md).

## Credits & acknowledgements

Thanks: LMSS, DJS, LCS, TBPL, EG

- **MAME** and **Aaron Giles**, author of the Atari Escape driver
  ([`src/mame/atari/eprom.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/atari/eprom.cpp),
  `license:BSD-3-Clause`, `copyright-holders: Aaron Giles`) and the supporting device
  models (`atarijsa`, `atarimo`, `slapstic`). This project used the MAME driver purely as a
  **behavioral reference** for understanding the hardware (memory map, video/motion-object
  format, the two-CPU mailbox handshake). **No MAME source code is copied into this
  repository**; the RTL is an independent re-implementation from the driver's documented
  behavior cross-checked against the original schematics, which take precedence where they
  disagree (autovectored IRQs, SLAPSTIC, serial SCOM). On CPU type the two references
  appeared to differ for weeks, and **both turned out to be right about different
  boards**: Escape shipped in two cabinet variants, and the dedicated cabinet is a
  **68010** (`MC68010P8`, Motorola, date code `A71R8813`, photographed — matching the
  schematic's `U68010` at 45J and 20P, since SP-332 *is* the dedicated-cabinet package)
  while the **JAMMA** version is a **68000**, which is what MAME models. This core
  supports both, and it is safe rather than lucky either way — the ROM contains no
  68010-only instruction, no handler reads an exception-frame format word or does
  pointer arithmetic around the frame, and 68010 loop mode is never entered (measured:
  0.0000% of the video CPU's per-frame work sits in a loop-mode-eligible `DBcc` loop).
  See [`docs/CPU_AND_ARBITER.md`](docs/CPU_AND_ARBITER.md). Thank you to the
  MAME developers for decades of preservation work that made this core possible.
- The **openFPGA** community and **Analogue** for the Pocket core framework
  ([`open-fpga/core-template`](https://github.com/open-fpga/core-template)).
- **d18c7db (Alex)** and **MiSTer-devel** for
  [`Arcade-Atari-system1_MiSTer`](https://github.com/MiSTer-devel/Arcade-Atari-system1_MiSTer)
  (GPL-3.0), the schematic-based Atari System 1 core this project's RTL base was
  derived from — including the MAME-faithful **TMS5220** speech chip model
  (vendored at `src/fpga/core/rtl/TMS5220.vhd` with a lattice-filter arithmetic
  fix, provenance noted in the file header).
- **Tobias Gubener (TobiFlex)** for the **TG68K.C** 68000 soft-CPU core (LGPL-3.0,
  with patches by MikeJ, Till Harbaum, Rok Krajnc and others) — both of this core's
  68000s are TG68K instances, via the System 1 tree.
- **Daniel Wallner** for the **T65** 6502 core (BSD-style license, via OpenCores /
  the System 1 tree), reused for the JSA-I sound board's 6502.
- **Jose Tejada (jotego)** for [`jt51`](https://github.com/jotego/jt51), the
  YM2151 FM synthesis core used by the JSA-I audio subsystem (GPL-3.0, included
  as a git submodule with license and history intact). Jotego's FPGA arcade
  work is foundational to this whole scene — support it at
  [Patreon](https://www.patreon.com/jotego).

## License

**GPL-3.0** — see [`LICENSE`](LICENSE). The RTL base is
[`MiSTer-devel/Arcade-Atari-system1_MiSTer`](https://github.com/MiSTer-devel/Arcade-Atari-system1_MiSTer)
(GPL-3.0); the YM2151 core is [`jotego/jt51`](https://github.com/jotego/jt51)
(GPL-3.0, submodule); the openFPGA APF framework is from
[`open-fpga/core-template`](https://github.com/open-fpga/core-template).

## Legal

This core contains no copyrighted ROM data, and no copyrighted schematics. Escape from the
Planet of the Robot Monsters, Klax, and Guts n' Glory are trademarks of their respective
rights holders. Use only with software you are legally entitled to.
