# Atari Dual 68k — openFPGA core (Analogue Pocket)

An LLM-assisted openFPGA core for Atari Games' **"Escape"** arcade hardware — the dual-68010 board
whose flagship title is *Escape from the Planet of the Robot Monsters* (**E.P.R.O.M.**).

The core implements the **`eprom` configuration only** — two 68000-family
CPUs (68010 by default, 68000 selectable) and JSA-I audio. See [Other games on this hardware](#other-games-on-this-hardware).

> Built for the [Analogue Pocket](https://www.analogue.co/pocket) via the openFPGA framework.
> This project ships **no ROMs**. You must supply your own dumps.

## Status

🕹️ **The game is playable.** From a user-supplied ROM, the core boots the real
dual-CPU program, runs the full attract cycle (story, announcer speech, high
scores, demo), takes coins, starts, and plays: Jake walks, robots swarm, the
JSA-I sound board delivers music, effects and TMS5220 speech in real time.
Development continues on visual polish and final timing feel.

| Subsystem | State |
|---|---|
| Build (CI, Quartus in Docker) | ✅ ~15 min per push, `bitstream.rbf_r` artifact |
| Native simulation (GHDL + iverilog) | ✅ boot, march, JSA, speech-chip and sprite-scene replay benches |
| ROM loading (data slot → SDRAM + CRAM + BRAM shadows) | ✅ verified, self-checked |
| Dual 68010s + shared RAM + mailbox handshake | ✅ genuinely concurrent on hardware |
| Hot-code BRAM shadows + speculative prefetch | ✅ shipped — shadow hit rate 61% video / 37% extra CPU |
| Video: alpha / playfield / motion objects, IRGB palette + intensity | ✅ pixel-verified vs MAME scene replay — crowd, door, spawn-flash and factory-map fixtures all at 100.0000% agreement *and* coverage, draw order proven order-compatible |
| Sound (JSA-I: 6502 + YM2151 + **TMS5220 speech**) | ✅ full pipeline, bench-verified; no audio bus-trace diff vs MAME; liveness watchdog self-heals a wedged sound CPU |
| Inputs (buttons, hall-stick via ADC0809, dock analog) | ✅ incl. in-game calibration screens |
| Watchdog, freeze-rescue, on-device forensics HUD | ✅ 7 debug pages behind L / R — **off by default**, all builds; page 6 is a video-decodable frame counter so slowdown is measurable from any capture |
| EEPROM (2804) | ✅ high scores and settings persist across a power cycle |

**Known issues:** speech phrase tails clip slightly. A non-integer 240→1080
scale draws every 1-pixel feature 4 or 5 pixels thick, causing visible shimmer
on this game's diagonals: that is in the Pocket's scaler and **no RTL change
can fix it**. Hold-timing margin is at a structural floor (~+0.10 ns) and any
edit re-rolls it. A rare (once in hours, not yet root-caused) sound-CPU wedge
is fenced by a liveness watchdog: sound self-heals in under a second and the
diagnostic HUD latches the 6502 address it died at. The measured gap list is
[`docs/DEVIATIONS.md`](docs/DEVIATIONS.md) §D, not the issue tracker.

> Previously listed here: *"dense sprite crowds can drop scanlines"* and
> *"some scenes run marginally under arcade speed."* Both are resolved, and
> both resolutions came from measurement rather than tuning: the crowd
> dropouts were an **architectural fill-rate deficit** — the real board's
> line buffer is a *pair* of LB customs filling two pixels per clock (SP-332
> sheet 9), which this engine now matches (crowd-scene fixture went from 527
> missing pixels to 0) — and the speed gap dissolved under an end-to-end
> benchmark: a full attract cycle runs within 0.35% of MAME's frame count,
> with the residual being MAME slowing *more* than this core under load (see
> **Accuracy**).

**Core identity:** the core installs as `spoonelli.eprom` (renamed from the
development identity `spoonelli.ataridual68k` at v0.1.0 — if you ran dev
builds, delete the old core folder to avoid a duplicate menu entry). The
platform id is `eprom`, so the ROM goes in `Assets/eprom/common/` and saves in
`Saves/eprom/common/`; saves are platform-keyed and carry over. Platform art
is an original text placeholder; real marquee art is user-supplied and not
distributed, like the ROMs.

Full hardware map, roadmap, and schematic findings: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Other games on this hardware

MAME's `eprom.cpp` driver covers five sets on this board family.
**Only `eprom` is supported.** The core has never been run against any of the
others — the rows below describe what they would require, not partial support.

| Set | Title | Status |
|---|---|---|
| **`eprom`** | Escape from the Planet of the Robot Monsters (set 1) | **the target — this is what the core runs** |
| `eprom2` | Escape … (set 2) | **Next target.** Identical machine configuration and hardware; differs only in program-ROM revisions (all rev 1, plus a `.40e`/`.50e` pair absent from set 1). Support requires an additional CRC table in `build_rom.py`; no RTL changes are anticipated. Not yet run or verified. |
| `klaxp1` | Klax (prototype set 1) | Not supported. Documented prototype romset; under future evaluation. |
| `klaxp2` | Klax (prototype set 2) | Not supported. Documented prototype romset; under future evaluation. |
| `guts` | Guts n' Glory (prototype) | Not supported. Documented prototype romset; under future evaluation. |

Two structural differences make the Klax and Guts prototypes future work
rather than near-misses:

- **They are single-CPU.** The second 68000-family CPU is `eprom`/`eprom2` only
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

**Roadmap position:** `eprom2` is the next supported-set target. The Klax and
Guts n' Glory prototype romsets are documented above and remain under future
evaluation; no support timeline is committed for them.

## Related: the MiSTer port

A MiSTer (DE10-Nano) port lives on the `mister` branch and plays on real
hardware, with its own platform work landed: it now runs the same open-row
SDRAM controller as the Pocket (ported after arbiter-level fixes proved the
per-transaction cost was the real constraint — the playfield shares the one
SDRAM there, where the Pocket gives it a separate PSRAM), fetch-return
crossings carry the same settle-stage arrangement the Pocket uses, an
on-screen build stamp shows at every core load, credits render as a
core-drawn overlay (OSD trigger, mappable button, or keyboard C), and the
OSD has music/speech sliders. It still trails the Pocket core in accumulated
device hours and is released separately, not as part of this package.
Details: [`docs/MISTER.md`](docs/MISTER.md).

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
(the real board's architecture — MAME time-slices); **zero-wait ROM fetches**
(traced pin-by-pin on sheets 4/5: neither wait-state generator takes any `/ROM`
input, so the 4-clock fastpath is the *accurate* path, not an overclock); the
motion-object line buffer's **two-pixels-per-clock fill** (sheet 9: a pair of LB
customs taking MOL/MOR); IRGB palette math with intensity; autovectored
interrupt scheme; the 128 ms / 8-vblank watchdog.

**Approximate:** per-instruction CPU cycle counts (TG68K is instruction-accurate,
not cycle-exact); bus-cycle timing off-ROM (the original gave every subsystem its
own parallel bus; this core funnels through SDRAM + a CRAM chip + BRAM shadows —
measured costs and consequences in [`docs/investigations/VSHAD3.md`](docs/investigations/VSHAD3.md) and
[`docs/DEVIATIONS.md`](docs/DEVIATIONS.md)); video internals (same VRAM in, same
pixels out on the same raster grid, but the scanout is a re-architected line
engine, not a gate-level MOHLB/SLAGS netlist clone — its *architecture-level*
properties, like the paired fill rate above, are taken from the schematic).

**Measured end-to-end, on hardware, against references** — the claims above are
checked rather than asserted:

- **Frame-level pacing**: a full attract cycle (the only fully deterministic
  cross-implementation content) completes in 5,992–5,994 frames on this core vs
  6,013 in MAME — **0.35%**, with story-panel timers in exact lockstep and the
  entire residual located in the demo, where **MAME slows down more than this
  core does** (MAME half-rates 1.6% of demo frames; this core 0.0%).
- **Animation cadence**: the walk cycle advances every **8 frames**, a 32-frame
  (534 ms) cycle — identical to MAME's motion-object code stream and to
  real-cabinet footage, whose walk-scroll rate (2.0 native px/frame) this core
  matches exactly.
- **Slowdown character**: in heavy crowds the *game software* drops to 30 Hz
  updates on every platform. Measured with one estimator across sources, a MAME
  longplay spends ~1.5× more of its crowd time slowed than this core does —
  consistent with MAME modelling the 68000 JAMMA variant while this core
  defaults to the 68010 the dedicated cabinet (and the reference machine used
  throughout development) actually carries.
- **Pixels**: motion-object output replays MAME scene dumps at **100.0000%
  agreement and coverage** on crowd, door, spawn-flash and factory-map
  fixtures, with draw order proven prefix-compatible by a dedicated gate.

Escape's game logic is IRQ- and frame-driven rather than cycle-counted, so at
equal frame pacing the gameplay is indistinguishable from the arcade. This
places the core at the accurate end of the class most MiSTer/openFPGA arcade
cores occupy.

## Architectural decisions — for the cycle-accuracy conversation

FPGA arcade cores get asked one question first: *is it cycle accurate?* For
this core the honest answer needs three sentences, so here they are, followed
by the decisions behind them.

**The machine architecture is real, the timing anchors are from the original
schematics, and the remaining gaps are enumerated and measured — not assumed
away.** It is not a netlist reproduction: the CPUs are TG68K, the video
scanout is a re-architected engine, and memory is funnelled through SDRAM
where the board had parallel buses. Where those substitutions could change
observable behavior, the difference has been measured against MAME, against
real-cabinet footage, or against the schematic — and either closed or
documented in [`docs/DEVIATIONS.md`](docs/DEVIATIONS.md).

The decisions, and why:

- **Dual CPUs are genuinely concurrent.** The defining feature of this board
  is two 68000-family CPUs on shared RAM with a mailbox handshake. MAME
  time-slices them; this core runs them as parallel hardware, which is what
  the board did — including a shared-RAM read-modify-write interlock
  (TAS atomicity) that emulation gets for free and hardware has to earn.
- **TG68K over fx68k, deliberately.** fx68k is the cycle-exact core, and it
  was evaluated seriously: it is ~1,000 ALMs cheaper here, but it costs +12
  M10K on a device where this design runs at the 308-block ceiling, its only
  cycle-true microcode is the 68000's (no 68010 microcode dump exists
  anywhere), and the one timing anomaly it was hoped to fix was measured and
  shown not to be per-instruction-timing-shaped. Instruction-accurate TG68K
  plus *measured end-to-end pacing equivalence* (see Accuracy) is the better
  trade on this hardware — and it is the trade that keeps the 68010 variant,
  which the dedicated cabinet actually carries.
- **Schematics outrank MAME; measurements outrank both references.** The
  original SP-332/TM-336 drawings corrected MAME on autovectored IRQs, the
  SLAPSTIC's presence, the serial sound link, zero-wait ROM, and — decisive
  for sprites — the line buffer's paired two-pixels-per-clock fill, which
  turned a long-standing "dropout under load" into a one-word diagnosis:
  the engine had half the board's fill rate. Where the drawings and MAME
  agree, the core still gets checked against scene-level replays and
  on-device captures, because both references have been wrong before.
- **One SDRAM instead of per-subsystem buses is the platform's constraint,
  and it is armored, not ignored.** The board gave the CPUs zero-wait EPROMs
  and the video its own RAM; the Pocket offers one SDRAM, one small PSRAM
  and limited BRAM. The consequences were paid deliberately: hot-code BRAM
  shadows, a speculative fastpath (measured at the schematic's 4-clock ROM
  timing), precharge-all read armor born of a wrong-row-serve hunt that took
  thirty builds to corner, and priority tiers set by which client has a hard
  realtime deadline. Every one of those exists because a measurement said
  so, and the measurement is written down.
- **Verification is the product.** The repo carries pixel-level replay gates
  against MAME's own renderer (agreement *and* coverage, plus a draw-order
  prefix proof), boot/march/IRQ/handshake benches that run the real ROM
  routines, a per-frame video-decodable frame counter so any screen capture
  becomes a pacing measurement, and an on-device forensics HUD. Claims in
  this README link to the numbers they rest on; when a claim inverted (the
  CPU-type saga, chronicled above), the inversion history stays visible.

If "cycle accurate" means *every bus cycle lands on the same clock edge as a
1989 board*, this is not that, and does not claim to be. If it means *the
machine's architecture, timing anchors, pixel output and pacing are the
board's, with the differences known, measured and shrinking* — that is what
this is, and the evidence is one link deep.

## Repo layout

```
core.json, video.json, data.json, ...   openFPGA core definition (APF)
dist/                                    platform art + asset folder skeleton
src/fpga/                                Quartus project
  apf/                                   Analogue Platform Framework (do not edit)
  core/core_top.v                        top level: SDRAM/CRAM services, download, video, HUD
  core/rtl/                              our core: escape_core, decode, SDRAM ctrl, BRAMs
sim/                                     GHDL simulation harness + testbenches
support/build_rom.py                     assemble user ROM dumps -> atari_escape.rom
support/package.sh                       build a Pocket SD-layout release zip (no ROMs)
reference/                               MAME driver sources; schematics stay local-only
docs/PIPELINES.md                        how the data/processing pipelines should work
docs/investigations/RETROSPECTIVE.md                    how it was debugged, incl. the false turns
docs/ARCHITECTURE.md                     hardware map, roadmap, schematic findings
docs/DEVIATIONS.md                       where this core is not the board, measured
docs/ROMS.md, docs/POCKET_TEST.md        ROM building; on-device test guide
third_party/                             Arcade-Atari-system1_MiSTer submodule (RTL base),
                                         jt51 submodule, analogue-pocket-utils (vendored)
```

## Get it

| Platform | Release tag | Package |
|---|---|---|
| **Analogue Pocket** | [`v0.1.0`](https://github.com/spoonelli/Atari-Dual-68k/releases/tag/v0.1.0) (plain `v*` tags) | `AtariDual68k-pocket-v*.zip` |
| **MiSTer (DE10-Nano)** | [`mister-v0.1.1`](https://github.com/spoonelli/Atari-Dual-68k/releases/tag/mister-v0.1.1) (`mister-v*` tags, field-testing pre-releases; [update_all database](docs/DISTRIBUTION.md) available) | `AtariDual68k-mister-*.zip` with a dated `escape_YYYYMMDD.rbf` |

Download the packaged zip from the
[**Releases page**](https://github.com/spoonelli/Atari-Dual-68k/releases).
That is the supported route; building from source is for contributors.
MiSTer field-testing releases are marked *pre-release*, so
[`releases/latest`](https://github.com/spoonelli/Atari-Dual-68k/releases/latest)
always points at the current Pocket release.

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

Every build shows a small cyan build number in the bottom-right corner while the
HUD is up — check it matches the zip you flashed. The diagnostic HUD is **off by
default** and additionally gated behind the 'Developer HUD' menu toggle; with it
enabled, press **L1** to bring it up, **R1** to cycle its 7 pages (0-6; page 6
carries a video-decodable frame counter), **L2** to toggle the trace view.
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
  68ks are TG68K instances, via the System 1 tree.
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
Release zips for both platforms carry `LICENSE.txt` and `NOTICE.md` (the
per-component compliance inventory) alongside the binary, as the GPL and the
MIT-licensed `psram.sv` require. The tree is not uniformly GPL-3.0, and
downstream users keep the weaker terms on these files:

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
