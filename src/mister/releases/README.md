# Arcade: Escape from the Planet of the Robot Monsters (MiSTer)

Self-contained MiSTer distribution repository to conform to standard core
layout specs (`sys/`, `rtl/`, `releases/`). **Upstream development** — the
shared machine RTL, simulation benches, measurement tooling, and the
Analogue Pocket build — lives at
[spoonelli/Atari-Dual-68k](https://github.com/spoonelli/Atari-Dual-68k);
fixes land there first and are vendored here per release.

A MiSTer (DE10-Nano) port of the
[Atari Dual 68k](https://github.com/spoonelli/Atari-Dual-68k) core,
implementing Atari Games' 1989 arcade release (MAME set `eprom`) and its
`eprom2` clone. Includes support for two unreleased Atari games that ran on the same board:
the Klax prototypes (`klaxp1` / `klaxp2`) and Guts n' Glory (`guts`). One
rbf serves all five (see [Install](#install)).
This LLM-assisted build has been refined extensively through testing and benchmarking against an original dedicated Escape cabinet and PCB, with reference gameplay video captured directly off the PCB.  All architecture decisions default to preserving original gameplay accuracy.  

**Features:** 
- The dual-CPU program boots and runs on two genuinely concurrent 68010s with shared RAM and the mailbox
handshake, as the board does (68000 selectable — the dedicated cabinet that served as a reference shipped a 68010, and also as referenced in both the JAMMA kit and dedicated schematics.  However, the developer has discovered through this process that there are multiple boards evidenced in the wild that carry 68000s; therefore, both are "authentic").

- All three video layers come through the schematic's paired line-buffer sprite engine.

- The prototypes run the board's single-68000 configuration with the
JSA-II sound board (6502 + YM2151 + OKI6295) and their own button sets;
Guts n' Glory also has its own video map. Each MRA carries a one-byte game
select, so older Escape MRAs keep working unchanged. The prototypes have
not been checked against original hardware (no reference board exists to us),
but they run on the same machine that has been: only their JSA-II sound
board, single-CPU setup and Guts' video map are new.

- The hall-effect stick model includes the game's own in-game calibration
screens; high scores and operator settings are saved to the SD card
(see [High scores and settings](#high-scores-and-settings)).

- The machine RTL comes from the same upstream source as the Analogue Pocket core - plan to continue dual path development wherever feasible. The current Pocket release (v0.1.1) is Escape set 1 only; set 2, the prototypes and the factory-map halftone are planned for the Pocket after this MiSTer release.


| Subsystem | State |
|---|---|
| Build (CI, Quartus in Docker) | ✅ per-push compile, timing summary, rbf artifact |
| Native simulation (GHDL + iverilog, upstream) | ✅ boot, march, JSA, sprite-scene replay benches, plus MiSTer-specific gates: playfield fetch service, crowd-load arbiter bench with hardware-calibrated thresholds |
| ROM loading (MRA + ioctl → SDRAM, sprite repack in RTL, BRAM shadows) | ✅ CRC-checked by the MRA; no ROM data distributed |
| Games (one rbf, game byte in each MRA) | ✅ all five: Escape sets 1 and 2, both Klax prototypes, Guts n' Glory (full device test plan passed on MiSTer 169; sets 1 and 2 re-checked on 170) |
| Dual 68010s + shared RAM + mailbox handshake (Escape; the prototypes use one 68000) | ✅ genuinely concurrent on hardware |
| SDRAM subsystem (open-row controller, bank-partitioned MO tile mirror, MO/CPU interleaved arbiter) | ✅ bench-gated; crowd performance measured at Pocket parity |
| Video: alpha / playfield / motion objects, IRGB palette + intensity | ✅ pixel-verified vs MAME scene replay; the factory map's halftone follows the real board (matches the PCB capture on MiSTer 168), where MAME differs |
| Sound, JSA-I (Escape: 6502 + YM2151 + TMS5220 speech) | ✅ full pipeline; liveness watchdog self-heals a wedged sound CPU |
| Sound, JSA-II (prototypes: 6502 + YM2151 + OKI6295) | ✅ bench-proven on the real Klax/Guts firmware; device-tested on MiSTer 169 |
| Inputs (buttons, hall-stick model, keyboard) | ✅ incl. in-game calibration screens; per-game button sets for the prototypes (new in 0.2) |
| OSD (Video / Audio / Pause options / Debug pages; pause, rotate, CRT adjust) | ✅ build identity in the about line `ESCAPE v<date> by spoonelli` |
| High scores / operator settings | ✅ saved per game to `config/nvram/` with Save NVRAM, Save settings, or Autosave NVRAM — see below (new in 0.2; earlier MiSTer builds did not save) |

## Accuracy

This is a **behaviorally accurate** core with authentic timing anchors — not
a cycle-exact replica. Performance references are against actual machine
gameplay. MAME is the secondary reference for Escape and the only reference
for the Klax and Guts prototypes; comparing against a real Escape board, this
project found and documented several places where MAME differs
([docs/DEVIATIONS.md](https://github.com/spoonelli/Atari-Dual-68k/blob/main/docs/DEVIATIONS.md)).
Honest classification:

**Authentic (schematic-verified):** clock frequencies (7.159 MHz CPUs, true
pixel clock, all clocks derived from the board's 14.318 MHz colorburst
family); raster geometry (456x262 total, 336x240 visible, ~59.92 Hz);
complete memory map, register and latch semantics; genuinely concurrent dual
CPUs (the real board's architecture — MAME time-slices); zero-wait ROM
fetches (traced pin-by-pin on the schematic: the 4-clock fastpath is the
*accurate* path, not an overclock); the motion-object line buffer's
two-pixels-per-clock fill (SP-332 sheet 9's paired LB customs); IRGB palette
math with intensity; autovectored interrupts; the 128 ms watchdog.

**Approximate:** per-instruction CPU cycle counts (TG68K is
instruction-accurate, not cycle-exact); bus-cycle timing off-ROM (the
original gave every subsystem its own parallel bus; this port funnels
through one SDRAM with an open-row controller, bank-partitioned so the
playfield and sprites keep separate open rows); video internals (same VRAM
in, same pixels out on the same raster grid, via a re-architected line
engine whose architecture-level properties come from the schematic).

**Measured end-to-end, on hardware, against references:**

- **Frame-level pacing**: attract-loop period accuracy exceeding **99.6%**
  against MAME, story-panel timers in exact lockstep — and the residual is
  MAME slowing *more* than this core in the demo.
- **Animation cadence**: the walk cycle advances every **8 frames**, locked
  against real-cabinet captures.
- **Slowdown character**: in heavy crowds the game software slows on every
  platform; a MAME longplay spends ~1.5x more of its crowd time slowed than
  this core — consistent with MAME modelling the 68000 JAMMA variant while
  this core defaults to the dedicated cabinet's 68010.
- **This port specifically**: crowd-scene scroll-velocity distributions
  measured identical to the Analogue Pocket release, with zero
  sub-half-speed dips where MAME dips in 19-28% of samples.
- **Pixels**: motion-object output replays MAME scene dumps at **100.0000%
  agreement and coverage** on crowd, door, spawn-flash and factory-map
  fixtures. The factory map's halftone shading is the one place the core
  now departs from MAME on purpose: it follows the real board, checked
  against a capture from an original PCB.

Escape's game logic is IRQ- and frame-driven rather than cycle-counted, so
at equal frame pacing the gameplay is indistinguishable from the arcade.
The full deviations ledger and architectural-decisions discussion live
upstream:
[docs/DEVIATIONS.md](https://github.com/spoonelli/Atari-Dual-68k/blob/main/docs/DEVIATIONS.md)
and the
[project README](https://github.com/spoonelli/Atari-Dual-68k#architectural-decisions--for-the-cycle-accuracy-conversation).

## Install

The rbf, the MRAs and the `_alternatives/` folder are in
[`releases/`](releases/) in this repository.

1. Copy `Arcade-Escape_YYYYMMDD.rbf` to `_Arcade/cores/` on your MiSTer
   SD card (the official distribution installs the same file as
   `Escape_YYYYMMDD.rbf`). The MRA references the core as `Escape`, which
   the framework matches against either spelling. **Delete any older
   `escape*.rbf`, `Escape_*.rbf` or `Arcade-Escape*.rbf`**; the framework
   matches by prefix and picks the newest-looking name.
2. Copy the MRAs to `_Arcade/`, keeping the folder layout, and replace
   any earlier copies (older MRAs reference the old rbf name or lack the
   save declaration). One rbf serves every game on this board. The layout
   is MiSTer's family convention: one MRA per distinct game in the main
   list, clones in a folder per parent game under `_alternatives/`, so
   they don't crowd the main list:
   - `Escape from the Planet of the Robot Monsters (set 1).mra` — top
     level. The game this core was built for.
   - `Guts n' Glory (prototype).mra` — top level. Atari's unreleased
     Guts n' Glory (MAME `guts`): same board, JSA-II sound, its own video
     map.
   - `_alternatives/_Escape from the Planet of the Robot Monsters/Escape
     from the Planet of the Robot Monsters (set 2).mra` — MAME's `eprom2`
     clone (all-rev-1 program).
   - `_alternatives/_Klax/Klax (prototype set 1).mra` and `(prototype set
     2).mra` — the two Klax prototypes, which ran on this board with a
     JSA-II sound board (MAME `klaxp1`/`klaxp2`, clones of production
     `klax`). The official distribution's `_Klax` folder also holds the
     production Klax sets, served by a different core; each MRA names its
     own core, so they coexist.
   All five games passed the device test plan; the
   MRA tells the core which game it is loading (a one-byte
   index-1 block), so old Escape MRAs keep working unchanged.
3. Put your own MAME romsets in `games/mame/`: `eprom.zip` (set 2 also
   wants `eprom2.zip` beside it), `klax.zip` for the Klax prototypes (a
   merged set holds both; split `klaxp1.zip` / `klaxp2.zip` beside it work
   too), and `guts.zip`. MiSTer finds every chip by CRC, so split and
   merged MAME sets both work. **No ROM data is included** — each MRA assembles its game
   from your verified dumps.
4. Launch the game from the Arcade menu.

## Self-Test and First boot

On Escape, the core follows the authentic behavior of the original PCB with a "Waiting for Second Processor" screen that will hold for several seconds.  After that, the machine boots clean. To confirm which build is running, open the OSD — the
**version footer** at the bottom reads `ESCAPE v<date> by spoonelli`,
with the date matching the `.rbf` filename you installed. Check they
agree; it is the only guard against a cached or stale `.rbf`, and it
has caught that more than once.

The machine has no Start button, and no game reads the core's Start
input, so Define buttons does not ask for it. In self-test (**Service
Mode** on the root menu) Escape steps through the test screens with
**Jump**; the prototypes use their own buttons.

## Controls

Run **Define eprom buttons** in the OSD the first time (new buttons do
not appear in previously saved maps). MiSTer names that entry, and saves
the map, after each MRA's set name, so 'Escape' set 2, the Klax prototypes and
Guts show *Define eprom2 / klaxp1 / klaxp2 / guts buttons* and each keeps
its own map. Escape's buttons are Jump, Fire, Duck, Bomb,
Coin, and Pause. Jump also starts a game and steps the self-test, as on
the board. Fresh installs default to Jump on the left face button, Fire
on the bottom, Duck on the right, Bomb on top (SNES Y/B/A/X), and Pause
on the left shoulder. The define
flow prompts for all six buttons - answer every prompt before Finish,
or the unanswered ones stay unmapped. Note the framework treats your
global User/Menu button as "Undefine" inside this flow: assigning a
core button to it silently clears the slot instead.

**Prototypes:** Klax has an 8-way stick and one function, **Flip/Start**,
which starts or joins a game and drops tiles, on two buttons: **Flip/Start**
and **Flip (2nd)** (production cabinets have a Flip button on each side of
the stick; MAME lists four buttons, but the program only reads the first).
Guts n' Glory uses the analogue stick and three buttons in MAME's order;
Button 2 is the one its own switch test calls "Left START". Both
prototypes start and join from their game buttons. Coins go
through the sound board as on Escape.

## High scores and settings

The board keeps high scores and operator settings in a 512-byte EEPROM.
The core loads it from `config/nvram/<MRA name>.nvm` when a game starts.
Each MRA has its own file, so Escape, set 2, the Klax prototypes and Guts
n' Glory never share scores. Saving follows the MiSTer arcade convention:

- **Save NVRAM** (root menu) saves it now. MiSTer's own *Save settings*
  also saves it.
- **Autosave NVRAM** (root menu, default **Off**): when On, MiSTer saves
  each time you open the OSD, but only if the game has changed the EEPROM
  since the last save. To keep it on, choose *Save settings* once after
  turning it on.

MiSTer only ever saves while the OSD is open, so after a new high score
open the OSD (with Autosave on) or choose Save NVRAM before switching off.
A first launch with no file starts from a blank EEPROM, exactly like a new
board: the game initialises its own defaults.

## OSD options

- **Video page** — aspect ratio, **Rotate** (No / CCW / CW) and
  **Flip 180** for rotated or flipped cabinets, scandoubler effects, and
  **CRT H/V Adjust** (±8 steps, for positioning the picture on your
  display). Rotation is unavailable under direct video.
- **Audio page** — independent Music / Speech volume sliders.
- **Debug page** — ROM Shadow (leave On, the default; it is a performance
  feature, not a hack) and Skip Self-Test. Future diagnostics will live
  here.
- **Pause options page** — "Pause when OSD is open" (default Off) and
  "Dim video after 10s" (default On; halves brightness against burn-in).
  The mappable **Pause button** (default: left shoulder) toggles pause
  any time. Either way the whole machine freezes coherently — both
  68010s, sound board, speech — and resumes exactly where it stopped.
  Reset cancels a held pause.
- **Autosave NVRAM / Save NVRAM** — high-score saving, on the root menu;
  see [High scores and settings](#high-scores-and-settings).
- **Service Mode** — the operator control, on the root menu.
- **Reset** — the machine's hard reset.

If the pages ever appear "exploded" — every option listed flat under its
page heading — that is MiSTer's own flat-view toggle, not the core: in the
OSD the framework maps the gamepad's **R2** trigger (and the backtick key)
to it. Press R2 again to restore the pages.

Attributions live in `NOTICE.md` (in this zip and the repository).

## Auto-updates (update_all / Downloader)

The core ships in the **official MiSTer distribution** (repository
`MiSTer-devel/Arcade-Escape_MiSTer`, installed as
`_Arcade/cores/Escape_YYYYMMDD.rbf` plus the MRA), so a stock `update_all`
run delivers and updates it — nothing to add.

If you added the earlier custom database (`spoonelli/ataridual68k`) before
adoption, remove it — it now delivers nothing and would only duplicate
paths:

```bash
/media/fat/Scripts/update.sh --uninstall spoonelli/ataridual68k
```

(or delete its stanza from `/media/fat/downloader.ini`), then run
`update_all` again and delete any leftover `_Arcade/cores/Arcade-Escape_*.rbf`.
After an MRA update that changes the button set, run **Define eprom
buttons** (or the other set's entry) once — saved maps do not carry over.

## History

* Arcade-Escape_20261019.rbf
  * **Shared-Hardware Support:** 'Escape' set 2, Atari's unreleased **Klax prototypes** (sets 1 and 2) and **Guts n' Glory**. Each MRA carries a one-byte game select; older Escape MRAs keep working.  
  * **High scores and operator settings are saved**, per game, to `config/nvram/`: *Save NVRAM*, Main's *Save settings*, or *Autosave NVRAM* (default Off), the Arcade-Cave convention.
  * **The factory map now matches the original board:** travelled routes dim instead of staying bright as in MAME, matched against a capture of the original PCB.
  * Klax's one function, **Flip/Start**, on two buttons (Flip/Start and Flip (2nd)), as on a Klax cabinet; Guts n' Glory uses the analogue stick and three buttons.
  * No Start button in Define buttons for any game: the machine has none, and no game reads the core's Start input (Escape's self-test steps on Jump).
  * Pause now freezes the whole sound board (sound CPU, speech and samples), not only the music chip.
  * Clone MRAs moved under `_alternatives/` (set 2 under `_Escape from the Planet of the Robot Monsters`, the Klax prototypes under `_Klax`, shared with the Klax core); all MRAs use `<rbf>Escape</rbf>`.
  * Autosave NVRAM / Save NVRAM sit in the root menu above Service Mode.
  * Adds jotego's `jt6295` (OKI MSM6295) for the prototypes' samples; see `NOTICE.md`.

* Arcade-Escape_20260902.rbf
  * **OSD per the MiSTer-devel conventions:** Video / Audio / Pause options / Debug pages, core id `ESCAPE`, about line `ESCAPE v<date> by spoonelli` (replaces the credits pages).
  * **Pause:** a mappable Pause button (default left shoulder), "Pause when OSD is open" (default Off), "Dim video after 10s" (default On).
  * **Rotate (CCW/CW) and Flip 180**, through the framework framebuffer (HDMI).
  * **CRT H/V Adjust** (±8) and a horizontal sync position calibrated for consumer 15 kHz sets.
  * MRA `<buttons>` corrected: seven buttons including Pause, defaults Jump=Y Fire=B Duck=A Bomb=X. Re-run *Define eprom buttons* once.
  * First release in the official MiSTer distribution (2026-09-03).

* Arcade-Escape_20260830.rbf
  * **Crowd-scene performance at parity with the Analogue Pocket core:** the Pocket's open-row SDRAM controller, a sprite/CPU interleave arbiter, and the sprite tiles mirrored into an idle SDRAM bank.
  * Download race fixed; default buttons Jump/Fire/Duck/Bomb on left/bottom/right/top.

* escape_20260829.rbf
  * First MiSTer release: *Escape from the Planet of the Robot Monsters* (set 1), both 68010s concurrent (68000 selectable), JSA-I sound with TMS5220 speech, hall-effect stick model.

## Reporting problems

Include the OSD footer line (`ESCAPE v<date> by spoonelli`), the rbf
filename and which MRA you launched, plus a short video if the issue is
visual. The full port record — what is verified
on hardware, known behaviors, and how the SDRAM arrangement differs from
the Pocket's — lives in
[docs/MISTER.md](https://github.com/spoonelli/Atari-Dual-68k/blob/mister/docs/MISTER.md).

## License

GPL-3.0 — sources at https://github.com/spoonelli/Atari-Dual-68k (branch
`mister`; the Pocket release is
[v0.1.1](https://github.com/spoonelli/Atari-Dual-68k/releases/tag/v0.1.1)).
Third-party components and attributions: NOTICE.md in the repo. This
project distributes no ROM data and no copyrighted artwork; use only with
software you are legally entitled to.


## Building

Quartus 17.0+ (CI uses Quartus Lite 18.1 in
`theypsilon/quartus-lite-c5:18.1`): open `Arcade-Escape.qpf` and
compile, or see `.github/workflows/build.yml`. All sources are vendored
under `rtl/` — no submodules. Third-party provenance and licences:
`NOTICE.md` (jt51 and jt6295 GPL-3.0, TG68K LGPL-3.0, T65 BSD-style, RTL base
GPL-3.0; two files each of jt51/TG68K are vendored with documented
modifications under `rtl/core/`).
