# Atari Dual 68k — openFPGA core (Analogue Pocket)

An LLM-assisted openFPGA core for Atari Games' **"Escape"** arcade hardware — the dual-68000 board
whose flagship title is *Escape from the Planet of the Robot Monsters* (**E.P.R.O.M.**).

The core implements the **`eprom` configuration only** — two 68000s and JSA-I
audio. See [Other games on this hardware](#other-games-on-this-hardware).

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
| Hot-code BRAM shadows + speculative prefetch | ✅ shipped — shadow hit rate 61% video / 37% extra CPU |
| Video: alpha / playfield / motion objects, IRGB palette + intensity | ✅ components pixel-verified vs MAME scene replay (compositor itself has no bench) |
| Sound (JSA-I: 6502 + YM2151 + **TMS5220 speech**) | ✅ full pipeline, bench-verified; no audio bus-trace diff vs MAME |
| Inputs (buttons, hall-stick via ADC0809, dock analog) | ✅ incl. in-game calibration screens |
| Watchdog, freeze-rescue, on-device forensics HUD | ✅ 6 debug pages behind L / R — **off by default**, all builds |
| EEPROM (2804) | ✅ high scores and settings persist across a power cycle |

**Known issues:** dense sprite crowds can drop scanlines (bandwidth work in
progress); speech phrase tails clip slightly; some scenes run marginally under
arcade speed (video-CPU cadence median 0.973 vs MAME 0.9977 — the gap is in
the tail, not the median). A non-integer 240→1080 scale draws every 1-pixel
feature 4 or 5 pixels thick, causing visible shimmer on this game's diagonals:
that is in the Pocket's scaler and **no RTL change can fix it**. Hold-timing
margin is at a structural floor (~+0.10 ns) and any edit re-rolls it. The
measured gap list is [`docs/DEVIATIONS.md`](docs/DEVIATIONS.md) §D, not the
issue tracker.

> Previously listed here: "occasional small sprite artifacts". Three
> independent detectors failed to reproduce it (enclosed-black: 0 ours vs 11
> MAME; hole rate indistinguishable across builds). It may still be real — a
> sprite fetching wrong-but-plausible data defeats every statistical shape
> test — but it is an unreproduced observation, not a measured defect. See
> §D3.

**Core identity:** the core currently installs as `spoonelli.ataridual68k`.
Renaming it to `spoonelli.eprom` is proposed but **not done** — see
[`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md). The platform id is `eprom`
either way, so the ROM goes in `Assets/eprom/common/` and saves in
`Saves/eprom/common/`. Platform art is an original text placeholder; real
marquee art is user-supplied and not distributed, like the ROMs.

Full hardware map, roadmap, and schematic findings: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Other games on this hardware

MAME's `eprom.cpp` driver covers five sets on this board family.
**Only `eprom` is supported.** The core has never been run against any of the
others — the rows below describe what they would require, not partial support.

| Set | Title | Status |
|---|---|---|
| **`eprom`** | Escape from the Planet of the Robot Monsters (set 1) | **the target — this is what the core runs** |
| `eprom2` | Escape … (set 2) | Not supported. Same machine config and same hardware; differs only in program-ROM revisions (all rev 1, plus a `.40e`/`.50e` pair set 1 lacks). Plausibly a small step rather than a project — but nobody has tried it, so that is a guess. |
| `klaxp1` | Klax (prototype set 1) | Not supported. Future target. |
| `klaxp2` | Klax (prototype set 2) | Not supported. Future target. |
| `guts` | Guts n' Glory (prototype) | Not supported. Future target. |

Two structural differences make the Klax and Guts prototypes future work
rather than near-misses:

- **They are single-CPU.** The second 68000 is `eprom`/`eprom2` only
  (`docs/ARCHITECTURE.md`). The shared-RAM mailbox, the TAS interlock and the
  dual-CPU arbitration — most of this project's hard-won machinery — simply go
  unused. So they are *simpler* than Escape, but they exercise a configuration
  this core has never run.
- **They use JSA-II, which adds an OKI6295.** Escape uses JSA-I (YM2151 +
  TMS5220). The OKI6295 is a device that does not exist in this RTL at all;
  `jotego/jt6295` is earmarked for it.

`support/build_rom.py` builds only the `eprom` set and refuses any chip whose
CRC32 does not match, so a Klax or Guts romset cannot currently be assembled
into a core image even to try.

**Not an alpha target.** This section is a roadmap note, not a promise.

## Related: the MiSTer port

A MiSTer port of this core exists on the `mister-112` branch (`mister-port`
brought up to the Pocket line at BUILD 112). It boots, but it has had **far
less hardware validation** than the Pocket core and is not part of this
release: it has been flashed **once**, at BUILD 105, and everything fixed or
added since — including the playfield fix that flash found — is simulated and
CI-verified only. Treat it as work in progress rather than something to install
alongside this. Details and a three-way simulated / CI-verified / on-hardware
split: [`docs/MISTER.md`](docs/MISTER.md).

## Hardware being implemented

Primary reference is the original Atari SP-332 schematic package (see
`reference/schematics/README.md` — the PDF itself is not redistributed); MAME's
`eprom.cpp` driver family is the behavioral cross-check. Notably, the schematics
corrected MAME on several points (autovectored IRQs, SLAPSTIC
present, serial SCOM sound link).

| Block        | Real chip                               | Implementation |
|--------------|-----------------------------------------|----------------|
| CPUs ×2      | Both drawings specify **68010**; production shipped **68000 and 68010 alike**, @ 7.16 MHz, shared RAM | TG68K, either selectable, defaults to 68010 (see C5) |
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
across SDRAM, a dedicated CRAM chip for graphics, and BRAM shadows holding hot code,
with a speculative prefetch fastpath for everything else. **These are not zero-wait**:
measured, a shadow fetch costs **5.015 CPU clocks** per bus cycle and a fastpath hit
**4.015** — so on its hottest code a shadow costs the CPU a clock rather than saving
one. Net throughput is ~0.87 of MAME's bus rate on the video CPU and ~0.92 on the
world CPU. See [`docs/VSHAD3.md`](docs/VSHAD3.md));
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
third_party/                             Arcade-Atari-system1_MiSTer submodule (RTL base),
                                         jt51 submodule, analogue-pocket-utils (vendored)
```

## MiSTer (DE10-Nano)

There is a second front end in `src/mister/` that runs the **same machine RTL**
on a DE10-Nano, loaded from a community-standard `.mra`.

**It has been flashed exactly once**, at BUILD 105: it booted, played, and drew
a completely flat playfield. That was diagnosed (the playfield fetch channel
did not reset with the core) and fixed, **and the fixed build has still never
been flashed** — nor has anything added since, including the BUILD 112 merge
that brings this port up to the Pocket line. Everything past BUILD 105 is
simulated and CI-verified only.

Requirements, SD-card layout, the ROM-mapping rationale, the BUILD 112
inventory and an explicit three-way simulated / CI-verified / on-hardware split
are in [`docs/MISTER.md`](docs/MISTER.md). Read that before assuming any of it
works.

## Get it

Download the packaged zip from the
[**Releases page**](https://github.com/spoonelli/Atari-Dual-68k/releases).
That is the supported route; building from source is for contributors.

1. Unzip onto your Pocket SD card — it merges `Cores/`, `Platforms/` and
   `Assets/` into the existing folders.
2. Put **your own** `atari_escape.rom` in `/Assets/eprom/common/`. This project
   distributes no ROM data; build the image from dumps you own per
   [`docs/ROMS.md`](docs/ROMS.md).
3. Launch the core. It asks for the ROM on startup. High scores save
   themselves to `/Saves/eprom/common/` — you do not create that file.

Requires Pocket firmware 1.1+ set up for unofficial cores. The core boots to a
clean picture; the diagnostic HUD is off until you press **L1**. What works,
what is known-imperfect and what is missing:
[`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md).

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

Every build shows a small cyan build number in the bottom-right corner — check it
matches the zip you flashed. The diagnostic HUD is **off by default**; press **L1**
to bring it up, **R1** to cycle its 6 pages (0-5), **L2** to toggle the trace view.
While the HUD is up, **R1/L2/R2 held** are layer-isolation and video-kill probes;
they do nothing with the HUD off.

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
  format, the two-CPU mailbox handshake). **No MAME source code is compiled into the
  core**: the RTL is an independent re-implementation from the driver's documented
  behavior. Nine unmodified MAME source files *are* checked in under `reference/` as
  reading material, under their own BSD-3-Clause terms — see
  [`reference/NOTICE.md`](reference/NOTICE.md), which reproduces the full licence.
  The schematics take precedence where the two references
  disagree (autovectored IRQs, SLAPSTIC, serial SCOM). **On CPU type they never
  actually disagreed.** Both schematic packages — SP-332 (rev **D** of drawing
  `A046145-01`) and the JAMMA manual TM-336 (rev **E** of the *same* drawing) —
  draw `U68010` at designators **45J** (`VCPU`) and **20P** (`ECPU`). The
  assembly drawing (Fig 4-3, `A046147-01 F`) calls out Atari house number
  **`137414-002`** at both CPU positions rather than a Motorola part number:
  **one BOM line, either chip.** That is how a 68010 drawing and 68000-stuffed
  boards coexist with nobody being wrong.

  Production shipped **both parts across both cabinet types** — 68000 and 68010
  have each now been photographed in a dedicated cabinet *and* in a JAMMA one,
  all four combinations. **It is not a cabinet distinction.** The distribution
  is **unknown**, and four boards cannot establish one, so this project states
  no pattern. Service swap-outs over 37 years plausibly mixed them further,
  which costs nothing: the game uses no 68010 feature, so a 68000 is a
  symptom-free substitute.

  Worth naming because every performance comparison in this repo rests on it:
  **MAME instantiates `M68000`, so MAME matches a 68000-stuffed board.** This
  core defaults to `CPU_TYPE = 1` (68010 — the specified part, and the one on
  the owner's board), with 68000 selectable in one place. Both are
  configurations real boards shipped in.

  It is safe rather than lucky either way — the ROM contains no
  68010-only instruction on any reachable path, all four handlers are
  stack-balanced, VBR is provably 0, and 68010 loop mode is never entered
  (measured: 0.0000% of the video CPU's per-frame work sits in a
  loop-mode-eligible `DBcc` loop). See
  [`docs/CPU_AND_ARBITER.md`](docs/CPU_AND_ARBITER.md).

  > **This claim has now inverted four times**, and the sequence is kept
  > visible because the pattern is the lesson: *"production boards carry
  > 68000s, verified from a real board"* (which traced to one unphotographed
  > inspection) → refuted by photograph → *"JAMMA 68000 / dedicated 68010"* →
  > refuted by two more photographs → the present form. Every turn came from
  > someone generalising past their evidence. The current statement is
  > deliberately the weakest one the photographs support.

  Thank you to the MAME developers for decades of preservation work that made
  this core possible.
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
- **Daniel Wallner**, **Mike Johnson (fpgaarcade)**, **Wolfgang Scherr** and
  **Morten Leikvoll** for the **T65** 6502 core (BSD-style licence, via OpenCores /
  the System 1 tree), reused for the JSA-I sound board's 6502. T65's licence carries
  the OpenCores *"redistributions in synthesized form"* clause, which covers an FPGA
  bitstream: this section is the accompanying documentation that clause requires.
- **Adam Gastineau (agg23)** for
  [`analogue-pocket-utils`](https://github.com/agg23/analogue-pocket-utils) — the
  `psram.sv` controller driving the Pocket's CRAM, vendored at
  `third_party/analogue-pocket-utils/psram.sv` and compiled into the bitstream
  (MIT, © 2022 Adam Gastineau; the licence text is preserved in the file header,
  and MIT requires it accompany all copies including binary releases).
- **Jose Tejada (jotego)** for [`jt51`](https://github.com/jotego/jt51), the
  YM2151 FM synthesis core used by the JSA-I audio subsystem (GPL-3.0). Most of it
  builds from the git submodule with licence and history intact; **two files are
  modified vendored copies** — `src/fpga/core/rtl/jt51v/jt51.v` and `jt51_acc.v`,
  carrying this project's per-channel user-gain change (MIX-100) — and the build
  compiles those in place of the submodule's. Jotego's FPGA arcade
  work is foundational to this whole scene — support it at
  [Patreon](https://www.patreon.com/jotego).

Speech: `src/fpga/core/rtl/TMS5220.vhd` is © 2020 d18c7db under GPL-3.0-or-later and
states in its header that it is based primarily on MAME's `tms5220.cpp`. If its
coefficient tables derive from that file, the BSD-3 notice for MAME's speech-chip
authors (Frank Palazzolo, Jarek Burczynski, Jonathan Gevaryahu, Aaron Giles) is
owed alongside it. This is inherited from upstream rather than introduced here, and
**has not been resolved** — flagged rather than fixed.

## License

**GPL-3.0** for this project's own RTL and tooling — see [`LICENSE`](LICENSE).
The tree is not uniformly GPL-3.0, and downstream users keep the weaker terms on
these files:

| Component | Licence |
|---|---|
| [`MiSTer-devel/Arcade-Atari-system1_MiSTer`](https://github.com/MiSTer-devel/Arcade-Atari-system1_MiSTer) (RTL base) | GPL-3.0 |
| [`jotego/jt51`](https://github.com/jotego/jt51) (submodule + 2 modified files) | GPL-3.0 |
| **TG68K** (`rtl/tg68kv/`, plus 2 files from the submodule) | **LGPL-3.0**-or-later |
| **T65** (`third_party/.../lib/T65/`) | **BSD-3**-style (OpenCores) |
| **`psram.sv`** (`third_party/analogue-pocket-utils/`) | **MIT** |
| **APF framework** (`src/fpga/apf/*`, from [`open-fpga/core-template`](https://github.com/open-fpga/core-template)) | **Proprietary** — Analogue Software License Agreement, see the header of `src/fpga/apf/apf_top.v`. Not an OSI licence. Unavoidable for a Pocket core, and explicitly carved out of the GPL-3.0 claim above. |

## Legal

This core contains no copyrighted ROM data, and no copyrighted schematics. Escape from the
Planet of the Robot Monsters, Klax, and Guts n' Glory are trademarks of their respective
rights holders. Use only with software you are legally entitled to.
