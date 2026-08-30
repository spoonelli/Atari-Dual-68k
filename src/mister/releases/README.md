# Arcade: Escape from the Planet of the Robot Monsters (MiSTer)

Self-contained MiSTer distribution repository to confirm to standard core
layout specs (`sys/`, `rtl/`, `releases/`). **Upstream development** — the
shared machine RTL, simulation benches, measurement tooling, and the
Analogue Pocket build — lives at
[spoonelli/Atari-Dual-68k](https://github.com/spoonelli/Atari-Dual-68k);
fixes land there first and are vendored here per release.

A MiSTer (DE10-Nano) port of the
[Atari Dual 68k](https://github.com/spoonelli/Atari-Dual-68k) core,
implementing Atari Games' 1989 arcade release (MAME set `eprom`).  This LLM-assisted build has been refined extensively through testing and benchmarking against an original dedicated cabinet and PCB, with architecture decisions defaulting to preserving original gameplay accuracy.  

**Features:** 
- The dual-CPU program boots and runs on two genuinely concurrent 68010s with shared RAM and the mailbox
handshake, as the board does (68000 selectable — the dedicated cabinet that served as a reference shipped a 68010, and also as referenced in both the JAMMA kit and dedicated schematics.  However, the developer has discovered through this process that there are multiple boards evidenced in the wild that carry 68000s; therefore, both are "authentic").

- All three video layers come through the schematic's paired line-buffer sprite engine.

- The hall-effect stick model includes the game's own in-game calibration
screens; high scores and operator settings persist.

- The machine RTL is identical to the Analogue Pocket release - plan to continue dual path development wherever feasible.  


| Subsystem | State |
|---|---|
| Build (CI, Quartus in Docker) | ✅ per-push compile, timing summary, rbf artifact |
| Native simulation (GHDL + iverilog, upstream) | ✅ boot, march, JSA, sprite-scene replay benches, plus MiSTer-specific gates: playfield fetch service, crowd-load arbiter bench with hardware-calibrated thresholds |
| ROM loading (MRA + ioctl → SDRAM, sprite repack in RTL, BRAM shadows) | ✅ CRC-checked by the MRA; no ROM data distributed |
| Dual 68010s + shared RAM + mailbox handshake | ✅ genuinely concurrent on hardware |
| SDRAM subsystem (open-row controller, bank-partitioned MO tile mirror, MO/CPU interleaved arbiter) | ✅ bench-gated; crowd performance measured at Pocket parity |
| Video: alpha / playfield / motion objects, IRGB palette + intensity | ✅ pixel-verified vs MAME scene replay |
| Sound (JSA-I: 6502 + YM2151 + TMS5220 speech) | ✅ full pipeline; liveness watchdog self-heals a wedged sound CPU |
| Inputs (buttons, hall-stick model, keyboard) | ✅ incl. in-game calibration screens |
| Credits overlay + OSD (volume sliders, Show Credits) | ✅ build number on credits page 1 |
| High scores / operator settings | ✅ persist across power cycles |

## Accuracy

This is a **behaviorally accurate** core with authentic timing anchors — not
a cycle-exact replica. Performance references are against actual machine
gameplay, with MAME as the secondary reference. Honest classification:

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
  fixtures.

Escape's game logic is IRQ- and frame-driven rather than cycle-counted, so
at equal frame pacing the gameplay is indistinguishable from the arcade.
The full deviations ledger and architectural-decisions discussion live
upstream:
[docs/DEVIATIONS.md](https://github.com/spoonelli/Atari-Dual-68k/blob/main/docs/DEVIATIONS.md)
and the
[project README](https://github.com/spoonelli/Atari-Dual-68k#architectural-decisions--for-the-cycle-accuracy-conversation).

## Install

Both files are in [`releases/`](releases/) in this repository.

1. Copy `Arcade-Escape_YYYYMMDD.rbf` to `_Arcade/cores/` on your MiSTer
   SD card, keeping its name — the MRA references the core as
   `Arcade-Escape`. **Delete any older `escape*.rbf` or
   `Arcade-Escape*.rbf`**; the framework matches by prefix and may load
   a stale one.
2. Copy `Escape from the Planet of the Robot Monsters (set 1).mra` to
   `_Arcade/`, replacing any earlier copy (older MRAs reference the old
   rbf name).
3. Put your own MAME `eprom.zip` romset in `games/mame/`. **No ROM data is
   included** — the MRA assembles the game from your verified dumps.
4. Launch the game from the Arcade menu.

## Self-Test and First boot

Note that this core follows the authentic behavior of the original PCB with a "Waiting for Second Processor" screen that will hold for several seconds.  After that, the machine boots clean. To confirm which build is running, open **Show
Credits** in the OSD (or press the Credits button / keyboard **C**) — the
**MISTER BUILD number** is on page 1. Check it matches the build you
installed; it is the only guard against a cached or stale `.rbf`, and it
has caught that more than once.

## Controls

Run **Define eprom buttons** in the OSD the first time (new buttons do not
appear in previously saved maps): Jump, Fire, Duck, Bomb, Start, Coin, and
Credits. Fresh installs default to Jump on the left face button, Fire on
the bottom, Duck on the right, Bomb on top (SNES Y/B/A/X). The define
flow prompts for all seven buttons - answer every prompt before Finish,
or the unanswered ones stay unmapped. Note the framework treats your
global User/Menu button as "Undefine" inside this flow: assigning a
core button to it silently clears the slot instead.

## OSD options

- **Music Volume / Speech Volume** — independent 8-step sliders.
- **Show Credits** — cycles the credits pages (so does the assignable
  Credits button, or the **C** key on a keyboard).
- **ROM Shadow** — leave On (default); it is a performance feature, not a hack.
- **Reset** — the machine's hard reset.

## Auto-updates (update_all / Downloader)

Add this once to `/media/fat/downloader.ini` and the core updates through
your normal `update_all` run:

```ini
[spoonelli/ataridual68k]
db_url = 'https://github.com/spoonelli/Atari-Dual-68k/releases/download/mister-db/ataridual68k_db.json.zip'
```

## Reporting problems

Include the build number from the credits page (a photo is ideal) and a
short video if the issue is visual. The full port record — what is verified
on hardware, known behaviors, and how the SDRAM arrangement differs from
the Pocket's — lives in
[docs/MISTER.md](https://github.com/spoonelli/Atari-Dual-68k/blob/mister/docs/MISTER.md).

## License

GPL-3.0 — sources at https://github.com/spoonelli/Atari-Dual-68k (branch
`mister`; the Pocket release is
[v0.1.0](https://github.com/spoonelli/Atari-Dual-68k/releases/tag/v0.1.0)).
Third-party components and attributions: NOTICE.md in the repo. This
project distributes no ROM data and no copyrighted artwork; use only with
software you are legally entitled to.


## Building

Quartus 17.0+ (CI uses Quartus Lite 18.1 in
`theypsilon/quartus-lite-c5:18.1`): open `Arcade-Escape.qpf` and
compile, or see `.github/workflows/build.yml`. All sources are vendored
under `rtl/` — no submodules. Third-party provenance and licences:
`NOTICE.md` (jt51 GPL-3.0, TG68K LGPL-3.0, T65 BSD-style, RTL base
GPL-3.0; two files each of jt51/TG68K are vendored with documented
modifications under `rtl/core/`).
