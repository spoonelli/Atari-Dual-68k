# Atari Dual 68k — v0.1.x release notes

An openFPGA core for the **Analogue Pocket** that implements Atari's
*Escape from the Planet of the Robot Monsters* (1989) — the dual-68010 arcade
board, not an emulator port. The RTL is an independent re-implementation
worked out from Atari's SP-332 schematic package, with MAME's `eprom.cpp`
driver as a behavioural cross-check.

**This is v0.1.x: v0.1.0 was the first public release, and v0.1.1 (the current
release) is a metadata patch on it** — see "Notes for this release". It plays
the game from the first coin to the end, and it has real, measured gaps. This document is the honest
list. Nothing here is
hidden in a footnote; if you are deciding whether to install it, read the
"Known imperfect" and "Not implemented" sections and decide from those.

> **Hardware status.** Everything below is measured in simulation, from
> instrumented on-device HUD captures, or from CI synthesis reports. The
> figures quoted are real measurements, not estimates. Where something has
> *not* been confirmed on a physical Pocket, it says so explicitly.

---

## Unreleased — Pocket 0.3: the Klax and Guts n' Glory cores

Nothing in this section is released. Branch `milestone-0.3`; test builds for
the owner's device checks. Two new Pocket cores, each its own zip (owner):
`spoonelli.klaxp` (platform `klaxp`: Klax prototype set 1, set 2 under
`_alternatives`) and `spoonelli.guts` (platform `guts`). Escape's core is
untouched.

| Build | Adds |
|---|---|
| 42 | First Klax and Guts Pocket cores (POCKETVAR-182): one tree, a build macro per game (`GAME_KLAX` / `GAME_GUTS`; none = Escape), the same constants the MiSTer core selects at runtime — single 68010, JSA-II sound with the OKI6295, Guts' video mode and its own playfield tile ROM at `0x280000`. Controls as on MiSTer: Klax d-pad + Flip/Start (A) + Flip 2nd (B); Guts analogue stick + Button 1/2/3 (A/B/X). 268/308 M10K each; timing positive (Klax hold +0.008 ns, Guts +0.020 ns). |
| 43 | Klax missing sprites on build 42 (SHADBASE-185): the video CPU's three zero-wait ROM shadows sat on Escape's hot code and covered only 12% of Klax's program reads (8% of Guts'), so the CPU's SDRAM traffic starved the motion-object fetches. The shadow bases are now per game, chosen from a MAME read profile: Klax `0x04000/0x08000/0x10000` (98.8% of reads), Guts `0x20000/0x00000/0x3C000` (92.2%), third shadow enabled on both (+16 M10K: 284/308 each). Timing positive (Klax hold +0.066 ns, Guts hold +0.027 ns). Escape and MiSTer unchanged. |
| 44 | Not sent (superseded by 45 before device test). |
| 45 | Klax sprite blackouts and Guts/Klax OKI grit, from the build-43 capture (paddle 90% visible, but ~5% of frames lost every sprite below some line; OKI output 20-35 dB noisier than MiSTer/MAME). **MOSELF-188**: Klax ends many sprite chains on a self-linked entry (MAME dumps: 8-24 of 64 SLIP chains per frame); the walker only stopped on a return to the chain start or after 64 entries, so it re-queued that sprite ~60 times on every line it covered - identical pixels, but floods of redundant fetches and line aborts. It now also stops on a self-link (MAME stops on any revisit). MO replay bench: same pixels, truncations 83 -> 0, aborts 258 -> 0. **OKICACHE-186**: the OKI's one-entry cache thrashed between jt6295's ctrl and ADPCM addresses (8 SDRAM reads per sample, forever) and filed late fills under the wrong address: at a 40-clock fetch latency 48% of latched ADPCM bytes were wrong. Now a phrase-table entry + 16 ADPCM entries with next-group prefetch: 0.5 reads per sample, no wrong bytes (new gate `tb_escape_okicache`). **SHADFAST-187**: shadow reads close in 4 clocks (the real board's ROM cycle) instead of 5 - Klax/Guts only; Escape unchanged. Timing positive (Klax hold +0.013 ns, Guts hold +0.051 ns); 284/308 M10K. |
| 46 | Not sent (superseded by 47). |
| 47 | Pocket audio hash/warble (owner: Guts samples warble; build-45 capture: sample content identical to MiSTer below 3 kHz, but 98% of sample-step edges landed as hard jumps on the 48 kHz grid - a hash floor ~25 dB above MiSTer, on OKI and YM sounds alike). **AUDCDC-189**: the I2S path sampled the live mixer bus at moments unrelated to the source's steps (and could tear a changing word). Now two gentle one-pole low-passes in the 7.16 MHz domain (~23 kHz overall) and a request/acknowledge handshake that takes each pair once per 48 kHz frame. Shared Pocket audio path; Escape picks it up at its next release. Klax: blackouts 0 and paddle 95.5-98.8% on build 45 (MiSTer 97-99.9%), DC hold/clicks gone. Timing positive (Klax hold +0.072 ns, Guts hold +0.074 ns); 284/308 M10K. |
| 48 | Build 47 measured within 1 dB of MiSTer below 17 kHz but 7-12 dB more hash above (OKI notches 49-51 dB vs 56-61). **AUDFLT-190**: the Pocket audio path now uses MiSTer's own default filter - Sorgelig's 3-tap IIR (`rtl/iir_filter.v`, vendored from MiSTer sys, GPLv2+; NOTICE updated) with MiSTer's default coefficients, one instance per channel at 7.16 MHz (MiSTer: 7.056 MHz, so the response sits 1.5% higher), still sampled on request once per 48 kHz frame. iverilog sweep: -0.2/-0.6/-1.2/-2.7 dB at 10/15/17/20 kHz (MiSTer -0.0/-0.4/-1.0/-2.6). Also includes LASTROW-190 (sprites on row 239; since build 46). Timing positive (Klax hold +0.098 ns, Guts hold +0.083 ns); 284/308 M10K. |
| 49 | Build 48 + **MOTEL-191**: HUD page 6's truncation counter also counts a line cut while the blitter is still mid-sprite (the Klax replay bench lost up to 128 px a frame that way at GFX_LAT 28-31 with the counter reading 0; at device latency nothing is cut). Telemetry only. Zips now carry the T65 and psram.sv licence texts in NOTICE.md. Timing positive (Klax hold +0.071 ns, Guts hold +0.085 ns); 284/308 M10K. |

## 0.2 — MiSTer v0.2.0 and Pocket v0.2.0 (2026-10-19)

**MiSTer v0.2.0** is build 172 (2026-10-19, `Arcade-Escape_20261019.rbf`,
published by the official distribution as `Escape_20261019.rbf`), built from
the release branch (fitter SEED 9; the 170 RTL plus Klax's second Flip button). It is in the distribution repo's
`releases/` and reaches the official MiSTer distribution when MiSTer-devel
merges the release pull request. **Pocket v0.2.0** is release build 41: RC 3 rebuilt
from the release commit (on-screen build number 41), with the fixed
`build_rom.py`. The
sections after this one describe the v0.1.x core. Build numbers and work tags are different series (KLAX-165
is in MiSTer 164, GUTS-166 in 165, GUTS-169 in 167, NVRAM-170 in 168,
NVRAM-171 and ALT-172 in 169, MISTER-174 in 170, POCKETSET-175 in Pocket
40).

**Pocket** — Pocket 0.2 is Escape set 2 (with a set picker) plus the
factory-map fix. The owner's device tests passed on RC 3 (2026-10-19).

| Build | Adds |
|---|---|
| 37 | **Factory-map halftone** (H8, MOSHADE-162): travelled routes and the START box dim on the between-level map, as on the owner's PCB capture, where MAME leaves them bright ([`DEVIATIONS.md`](DEVIATIONS.md) C6/C7, [`MAP_HALFTONE.md`](investigations/MAP_HALFTONE.md)). |
| 38 | **Escape set 2** (`eprom2`, EPROM2-163): `build_rom.py` builds a set-2 image; the core serves set 2's tenth program pair. |
| 39 | Rebuilt from the current shared RTL (the Klax/Guts/JSA-II work of MiSTer 164–169, all tied off on the Pocket); no intended Pocket-visible change. |
| 41 | **Release build of Pocket v0.2.0**: RC 3 rebuilt from the release commit with `BUILD_ID` 41, so the Developer HUD shows **41** (the RC builds showed 38); `build_rom.py` with merged/split-set support (BUILDROM-176/181) |
| 40 (RC 1–3) | **Set picker** (POCKETSET-175): the core lists its romsets at launch through APF instance JSONs in `Assets/eprom/spoonelli.eprom/` (set 2 under `_alternatives/`, jotego's layout); set 2 loads `atari_escape2.rom` and saves to `atari_escape2.sav`; set 1 keeps its 0.1.x file names. `build_rom.py` names its output for the set it detects. `core.json` 0.2.0. |

The Klax and Guts n' Glory Pocket cores (`spoonelli.klaxp`, `spoonelli.guts`)
come later, as separate packages from the same tree.

**MiSTer** — MiSTer 0.2 comes first. One rbf (`Escape_YYYYMMDD.rbf`, MRA tag
`<rbf>Escape</rbf>`) serves all five sets, the MRA selecting the game.

| Build | Adds |
|---|---|
| 162 | Factory-map halftone (as Pocket 37) |
| 163 | Escape set 2 MRA |
| 164 | Klax prototypes `klaxp1`/`klaxp2` (single CPU, JSA-II with the OKI6295 via `jt6295`) |
| 165 | Guts n' Glory video mode |
| 166 | Per-game button mapping |
| 167 | Guts special-sprite fix (GUTS-169); MRAs say `<rbf>Escape</rbf>`; rbf named `Escape_YYYYMMDD.rbf` |
| 168 | High scores saved on MiSTer (NVRAM-170, MRA `<nvram index="4" size="512"/>`); fixes a clock-crossing bug that made 164–167 usually boot Klax and Guts as Escape; `jt6295` licence notice |
| 172 | Klax **Flip (2nd)** (a second Flip button, KLAXFLIP2-178); Guts MRA button list fixed (Start/Coin/Pause had each landed one bit low since 166, MRABTN-177); Start hidden on every game: the machine has no Start button and no game reads the core's Start input (STARTHIDE-179; Escape's self-test steps on Jump, confirmed on the device); CI gates for MRA button lists and for both players' input mapping |
| 171 | Release build of the 170 RTL — superseded by 172 before publishing |
| 170 | Klax prototypes get one **Flip/Start** button (KLAXBTN-174: MAME declares four, the programs read only the first); Pause now freezes the whole sound board (6502, TMS5220, OKI), not only the YM2151 (PAUSE-174); NVRAM rows above Service Mode, the Cave order |
| 169 | Arcade-Cave-style saving (NVRAM-171): "Autosave NVRAM" (default Off) and "Save NVRAM" in the OSD root menu, and *Save settings* also saves; file `config/nvram/<MRA name>.nvm`. Clone MRAs in the MiSTer family layout (ALT-172): set 1 and Guts at the top level, set 2 and both Klax prototypes under `_alternatives/` |

**Device status:** the owner's first run of MiSTer 168 booted and played all
five MRAs. A MiSTer capture of the level-3 factory map (2026-10-17) matches the
PCB reference capture: the same nodes dimmed, the "you are here" marker blinks
every 10 frames, identical to the PCB capture, and the screen timing agrees.
Colour differences between those two captures are not attributed to the core
(different capture paths); a same-path comparison is a post-0.2 palette item.
The owner ran the full MiSTer test plan (T1–T10) on 169 (2026-10-18): all pass
except two notes — Klax showed four buttons (fixed in 170), the canal-stage
"STAND BY" panel differs from the PCB capture (resolved: a ROM-revision
difference — set 1's HUD code has a canal-only branch that prints STAND BY;
set 2 and the owner's board, an undumped revision closest to set 2, have no
such branch; confirmed on MiSTer 170 with set 2). Pocket RC 3 (build 40) passed the
owner's device tests (2026-10-19). The final MiSTer plan on 172
(2026-10-19) passed M1–M7: Escape set 1 regression, Pause mid-music resume,
Start hidden (the machine has none; Escape's self-test steps on Jump), set 2,
Klax with both Flip buttons, Guts coin / start / pause (broken before 172),
two players on all three games, and NVRAM persistence (Escape's coin audit
survived a save).

ThunderJaws remains future work; the research is in
[`investigations/THUNDERJAWS.md`](investigations/THUNDERJAWS.md).

---

## What you need

- An Analogue Pocket on firmware 1.1+, set up to run unofficial cores.
- **Your own ROM.** This project does not distribute ROM data and never will.
  The download below contains **no ROM data and no arcade artwork** — the
  packaging script refuses to build if either reaches it.

## Install

1. Download the zip attached to this release and unzip it onto your Pocket SD
   card. It merges into the existing `Cores/`, `Platforms/` and `Assets/`
   folders.
2. Build `atari_escape.rom` from dumps you own. The builder ships **in the
   zip** (`build_rom.py` at the top level; also
   [`support/build_rom.py`](https://github.com/spoonelli/Atari-Dual-68k/blob/main/support/build_rom.py)
   in the source repository):
   ```
   python3 build_rom.py /path/to/eprom.zip
   ```
   It writes `atari_escape.rom` next to the script — move it to
   `/Assets/eprom/common/` on the SD card. All 28 chips are verified against
   known-good CRC32s; anything that does not match is refused. Details in
   [`ROMS.md`](ROMS.md).
3. Launch **Esc Robot Monst** from the Pocket menu. It asks for the ROM on
   startup.

High scores and operator settings save themselves to
`/Saves/eprom/common/atari_escape.sav`. **You do not create that file** — the
Pocket writes it the first time the game changes the EEPROM, and reloads it on
every launch. Delete it to reset the machine to factory-fresh.

Full on-device notes, including the diagnostic HUD:
[`POCKET_TEST.md`](POCKET_TEST.md).

---

## What works

**The whole game.** It boots the full dual-CPU program, runs the complete
attract cycle — story pages, TMS5220 announcer speech, high-score table, demo
play — takes coins, starts, and plays. Jake walks, robots swarm, the JSA-I
sound board delivers music, effects and speech in real time.

| | |
|---|---|
| **Video** | Alpha layer, playfield and motion objects, IRGB palette with authentic attract dimming. Native raster: 456×262 total, 336×240 visible, **59.9227 Hz** — exact, derived from the board's 14.318 MHz colorburst family. |
| **Audio** | Atari JSA-I: 6502 + YM2151 FM + TMS5220 speech, over the board's serial SCOM link. Separate music and speech volume in the Interact menu. |
| **CPUs** | Two 68000-family cores running **genuinely concurrently** with shared RAM and the mailbox handshake, as the real board does. (MAME time-slices; this does not.) |
| **Controls** | Emulated hall-effect stick via the ADC0809, including the game's own in-game calibration screens. Dock analog stick takes priority when deflected; invert/swap/deadzone options in the menu. |
| **High scores** | **Persist across a power cycle.** The emulated 2804 EEPROM is snapshotted to the SD card ~1.17 s after the game stops writing it, so a score survives an unclean power-off, not just a clean exit. |
| **Boot** | Clean picture. The diagnostic HUD is off by default and, from build 114, is gated behind **Developer HUD** in the core menu -- L1 does nothing until that is ticked. |
| **Build ID** | From build 115 the on-screen build stamp follows the HUD gate, so a clean screen carries no plate. Tick **Developer HUD** to see it. |

### Verified exactly against the reference

These are not "looks right" — they are exhaustive or near-exhaustive
comparisons against MAME's own implementation:

| Subsystem | Result |
|---|---|
| Motion-object / playfield priority comparator | **507,904 / 507,904 = 100.0000%** |
| Motion-object renderer | **10,047 / 10,047**, `wrong_pen = 0` |
| Stain second pass (`apply_stain`) | matches on every scored frame, all cases |
| Sprite draw order | prefix-compatible in all 9 latency/scene cells |
| Pixel clock / refresh rate | 7.159091 MHz, 59.9227 Hz — exact |
| ROM contents | 28 / 28 CRC-verified against MAME known-good |

---

## Known imperfect

**Resolved since the alpha list was first written** — kept here because the
alpha circulated with these as open items:

- **Sprite dropouts in dense crowds** — closed by MOPAIR-131/MOPF2-132. The
  root cause was architectural, not bandwidth-tuning: the real board fills a
  *pair* of line buffers at two pixels per clock (SP-332 sheet 9), and the
  engine now does the same, plus a second prefetch lane for each sprite's
  second tile. The crowd-scene fixture went from 527 missing pixels to 0,
  worst-case fetch latency from 153 to 34, and two full device playthroughs
  show no dropouts. The dropout-rate table this section used to carry
  described the single-buffer engine and is preserved in
  [`investigations/MO_TILE_HOLES.md`](investigations/MO_TILE_HOLES.md).
  The *ROM Shadow 0x54000* toggle remains **on by default and should stay
  that way**; it is exposed for diagnosis, not as a tuning knob.
- **"Occasional small sprite artifacts — reported, not reproduced"** — it was
  real, and the statistical detectors were right that the shipped builds'
  holes would not reproduce on a bench: the failure needed real-traffic fetch
  latency. Same fix, same evidence, as above.
- **The left-edge stale strip** (native columns 0-1 showing old playfield
  content on transition screens) — closed at build 125: every layer sat
  2 px right of MAME's window (`VID_H_BPORCH` 60 → 62), so the leftmost
  columns showed the 512-px tilemap wrapping around from its far side.
  The owner's own hypothesis — "is that line just phase shifted from the
  other side?" — was exactly right, from the tilemap's other side.
- **Slightly under arcade speed in places** — the measured tail (video CPU at
  0.973 logic frames per video frame, p10 0.703) was the same line-buffer
  fill contention, and closed with it. The end-to-end benchmark now reads:
  a full attract cycle within **0.35%** of MAME's frame count, walk cadence
  locked at exactly 8 frames per animation phase against four real-cabinet
  captures, and under the heaviest crowd load this core slows *less* than
  MAME's 68000 model — consistent with the dedicated cabinet's 68010 — while
  never running faster than authentic. HUD page 5 still shows the live
  cadence figure. Current gap list: [`DEVIATIONS.md`](DEVIATIONS.md) §D.

**Shimmer on 1-pixel diagonals.** The Pocket scales 336×240 up to 1440×1080,
which is not an integer ratio, so every 1-pixel feature is drawn 4 or 5 pixels
thick depending on where it lands (measured: period-9 fold contrast 12.3×).
This game has a lot of 1-pixel diagonals, and they crawl. **This happens in the
Pocket's scaler, after the core has emitted its pixels — no change to this core
can fix it.** It is a property of the display path, not a bug we are putting
off.

**A 33-pixel horizontal deviation from MAME at scroll positions 50 and 157.**
Reproduces identically across builds, so it is not a regression. Probably an
un-wrapped coordinate in off-screen sprite rejection.

**Timing margin is thin, structurally.** Hold slack sits at roughly +0.10 ns
and the design is at a floor: the SDRAM clock is exactly 5× the pixel clock and
the two are phase-aligned, so every fifth SDRAM edge coincides with a pixel
edge and hold is decided purely by routing skew. Changing *any* logic re-rolls
the placement lottery — even bumping the build number alone has moved it by
0.157 ns. CI gates every build on this, and it has caught a genuine failure
(−0.054 ns) before it shipped. The build being released passes at all four
timing corners, and the corners it passes *are* the worst corners for hold, so
there is no operating condition worse than the one signed off.

---

## Not implemented

- **Any game other than `eprom`** (in v0.1.1). `eprom2` (the set-2 program-ROM revisions
  on identical hardware) is the next supported-set target. The *Klax* and
  *Guts n' Glory* prototype romsets are documented and remain under future
  evaluation: those configurations are single-CPU and use JSA-II with an
  OKI6295, a device not present in this RTL. `build_rom.py` builds only the
  MAME `eprom` set and rejects chips whose CRCs do not match it.
  *(As of v0.1.1. Milestone 0.2, unreleased, implements all four — see
  "Unreleased — milestone 0.2" above.)*
- **Save states / sleep.** None. `core.json` declares `sleep_supported: false`.
  Closing the core loses your position; only the EEPROM (high scores and
  operator settings) survives.
- **The 2804 EEPROM's write-lock sequence.** Writes are accepted without it.
  No known game behaviour depends on this.
- **The SLAPSTIC security chip.** Deliberately absent, and this is a
  considered decision rather than a gap: MAME's `eprom` driver instantiates no
  slapstic device, the game code references the full address space with no
  banked-window discipline, and the board's address-decode GALs contain no bank
  multiplexer. See [`SLAPSTIC.md`](SLAPSTIC.md).
- **YM2151 CT1 gating of speech volume.** The gain law is understood but
  deliberately not applied, pending a hardware check of the signal polarity.
- **Common-bus contention between the two CPUs.** The real board's shared-RAM
  arbiter costs each CPU an estimated 0.8–1.9% of every frame in collisions.
  Neither this core nor MAME models that, so if anything both run slightly
  *faster* than real hardware here. Instruction-level indivisibility (the part
  that actually matters for correctness) **is** implemented and verified: 114
  ownerless locks in 306 trials without the interlock, **0 in 514** with it.

Full deviation list, including the structural ones that are unavoidable on this
target: [`DEVIATIONS.md`](DEVIATIONS.md).

---

## Using the diagnostic HUD

The core boots clean. From build 114 the diagnostic layer is behind
**Developer HUD** in the core's menu (default off); tick it first, or L1 does
nothing. With it on, press **L1** to bring up the on-screen HUD; press it
again to hide it. **R1** cycles 7 pages (0–6):

| Page | Shows |
|---|---|
| 0 | JSA/sound status, coin and credit counters, bus-cycle length |
| 1 | Second-processor window: extra-68k PC, last mailbox response |
| 2 | Main-CPU window: video-CPU PC, last write address, crash forensics |
| 3 | Engine window: actor-table head, game mode bytes |
| 4 | `apply_stain` diagnostic |
| 5 | **Cadence** — the performance figure described above |
| 6 | **MO telemetry** (MOTEL-129): line-end truncation count + worst 16-line fetch latency, with the frame counter |

A small cyan **build number** sits in the bottom-right corner once
**Developer HUD** is ticked (from build 115 it follows that gate; before that it
showed at all times), with the HUD up or not. Check it matches the build you installed — it is the only guard
against flashing the wrong file, and it has caught that mistake before. It
shows the low two hex digits of the build id, so it distinguishes builds within
a run of 256 rather than absolutely.

If you report a problem, a photo showing the build number plus page 2 (or page
5 for a speed complaint) usually contains everything needed to diagnose it.

---

## Notes for this release

**Version mapping:** v0.1.1 = `BUILD_ID` 36; v0.1.0 = `BUILD_ID` 35 (the
two cyan digits on the diagnostic HUD). A HUD photo identifies a release
exactly. v0.1.1 is a metadata patch: corrected `date_release`, 68010 in
the core description - no RTL change.

**The core installs as `spoonelli.eprom`** as of v0.1.0 — the rename this
section recommended ("if it passes, rename before tagging") is done. Two
consequences for anyone upgrading from a development build:
1. The old `/Cores/spoonelli.ataridual68k/` folder stays on your SD card and
   appears as a second menu entry until you delete it.
2. Saves are keyed by platform id (`eprom`), which did not change — your high
   scores carry over. **Device-confirmed 2026-08-29** on the release
   candidate; the analysis below explains why the risk was accepted at 0.1.0
   rather than at 1.0.

**Nothing in the package is copyrighted content.** No ROM data, and the
platform image is an original text placeholder, not marquee art. The packaging
script refuses to build if ROM data reaches the staging tree, if the assets
folder contains anything but the placeholder note, or if any file other than
the bitstream exceeds 600 KB. All three checks are tested against deliberately
broken inputs, so they are known to be capable of failing.

### Why the rename happened at v0.1.0 (the original analysis, kept)

The Pocket keys its save files by **platform id**, not by core directory name,
and the platform id (`eprom`) would not change in a rename — so on the
repository's own evidence a rename would *not* orphan anyone's high scores, and
old and new installs would in fact share one save file.

That evidence is strong but not conclusive: Analogue's specification is not
vendored here, so the firmware's actual rule cannot be read off a normative
document. What *is* proven is that the core itself cannot influence the path —
the FPGA only ever sends a numeric slot id over the bridge and never a filename.

Being wrong would mean silently destroying somebody's high-score table on
upgrade, so this release does not make the change on inference alone. One
device test settles it: install the renamed core alongside an existing `.sav`
and confirm the scores still appear.

**But the timing argument runs the other way, and it is the stronger one.**
This is the first public release. If the rename is going to happen at all,
*now* is when it costs least — right now almost nobody has an install or a
save to orphan, and every release from here makes that population larger. Note
that this holds under **both** answers to the open question: if saves are
platform-keyed the rename is free, and if they are core-keyed the rename
orphans a set of saves that is currently close to empty and will never be
smaller. Deferring to 1.0 is the one option that is worse under both branches.

The recommendation is therefore: **do the device test, and if it passes, rename
before tagging** — not after. It is a five-line change (`core.json` shortname,
two lines in `package.sh`, two doc references); `platform_ids` stays `eprom`
and `data.json` must not be touched.

Two further things if it happens: the old `/Cores/spoonelli.ataridual68k/`
folder stays on the SD card and shows up as a **second entry** in the Pocket
menu until deleted — worth a line in the release notes when it does — and the
platform's display name (`Atari Dual 68k`) is a separate string worth deciding
on at the same time.
