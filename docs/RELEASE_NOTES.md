# Atari Dual 68k — Alpha release notes

An openFPGA core for the **Analogue Pocket** that implements Atari's
*Escape from the Planet of the Robot Monsters* (1989) — the dual-68000 arcade
board, not an emulator port. The RTL is an independent re-implementation
worked out from Atari's SP-332 schematic package, with MAME's `eprom.cpp`
driver as a behavioural cross-check.

**This is an alpha.** It plays the game from the first coin to the end, and it
has real, measured gaps. This document is the honest list. Nothing here is
hidden in a footnote; if you are deciding whether to install it, read the
"Known imperfect" and "Not implemented" sections and decide from those.

> **Hardware status.** Everything below is measured in simulation, from
> instrumented on-device HUD captures, or from CI synthesis reports. The
> figures quoted are real measurements, not estimates. Where something has
> *not* been confirmed on a physical Pocket, it says so explicitly.

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
2. Build `atari_escape.rom` from dumps you own and put it in
   `/Assets/eprom/common/`:
   ```
   python3 support/build_rom.py /path/to/eprom ./atari_escape.rom
   ```
   The builder verifies all 28 chips against known-good CRC32s and refuses
   anything that does not match. Details in [`ROMS.md`](ROMS.md).
3. Launch **Atari Dual 68k** from the Pocket menu. It asks for the ROM on
   startup.

High scores and operator settings save themselves to
`/Saves/eprom/common/atari_escape.sav`. **You do not create that file** — the
Pocket writes it the first time the game changes the EEPROM, and reloads it on
every launch. Delete it to reset the machine to factory-fresh.

Full on-device notes, including the diagnostic HUD:
[`POCKET_TEST.md`](POCKET_TEST.md).

---

## What works

**The whole game.** It boots the full dual-68000 program, runs the complete
attract cycle — story pages, TMS5220 announcer speech, high-score table, demo
play — takes coins, starts, and plays. Jake walks, robots swarm, the JSA-I
sound board delivers music, effects and speech in real time.

| | |
|---|---|
| **Video** | Alpha layer, playfield and motion objects, IRGB palette with authentic attract dimming. Native raster: 456×262 total, 336×240 visible, **59.9227 Hz** — exact, derived from the board's 14.318 MHz colorburst family. |
| **Audio** | Atari JSA-I: 6502 + YM2151 FM + TMS5220 speech, over the board's serial SCOM link. Per-channel FM level sliders and separate music/speech volume in the Interact menu. |
| **CPUs** | Two 68000-family cores running **genuinely concurrently** with shared RAM and the mailbox handshake, as the real board does. (MAME time-slices; this does not.) |
| **Controls** | Emulated hall-effect stick via the ADC0809, including the game's own in-game calibration screens. Dock analog stick takes priority when deflected; invert/swap/deadzone options in the menu. |
| **High scores** | **Persist across a power cycle.** The emulated 2804 EEPROM is snapshotted to the SD card ~1.17 s after the game stops writing it, so a score survives an unclean power-off, not just a clean exit. |
| **Boot** | Clean picture. The diagnostic HUD is off by default (press **L1** for it). |

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

**Sprite dropouts in dense crowds.** Under heavy motion-object load the core
can drop sprite scanlines the real board would draw. This is a bandwidth
problem: the Pocket reaches its graphics data over SDRAM and a PSRAM chip,
where the arcade board had parallel mask ROMs and no contention at all.

The rate is measured, per robot-object-frame:

| Configuration | Dropout rate | 95% CI |
|---|---|---|
| Real arcade board | 0 events in ~7,150 | [0, 5.16e-04] |
| No ROM shadow | 1.252e-03 | [8.51e-04, 1.78e-03] |
| Full 32 KB shadow | 3.222e-04 | [1.47e-04, 6.12e-04] |
| **This release (16 KB partial)** | **2.410e-04** | **[9.69e-05, 4.97e-04]** |

The shipped configuration is **5.19× better than running with no shadow**
(p = 1.0e-05) and statistically indistinguishable from the full 32 KB shadow
(p = 0.62), while using 16 block-RAMs instead of 25 and handing 5.5% of
video-CPU execution back to the more accurate 4-clock fastpath. Its entire
confidence interval sits inside the bound established for the real board.

The *ROM Shadow 0x54000* toggle in the Interact menu is **on by default and
should stay that way** — turning it off is the 1.252e-03 row above. It is
exposed for diagnosis, not as a tuning knob.

**A left-edge artifact.** Native columns 0-1 render stale playfield data on
some screens. MAME convicts it, so it is a real bug rather than a display
quirk. It is **not new** — it is present identically in earlier builds and is
not a regression from anything in this release. It is a known item, deferred
rather than fixed; no fix is imminent. Recorded in
[`DEVIATIONS.md`](DEVIATIONS.md).

**The game runs slightly under arcade speed in places.** Measured, the video
CPU completes **0.973** logic frames per video frame against MAME's **0.9977**.
The median is very nearly right; the whole deficit is in the tail (p10 = 0.703,
minimum 0.313), and that tail is what reads as sluggishness in crowded scenes.
The world CPU is at 0.984 vs 0.9999 and is not worth chasing. You can watch
this live on HUD page 5, in the same units MAME is quoted in. Ruled out as
causes: CPU type, and any constant few-percent overhead — a flat term cannot
produce that tail shape.

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

**"Occasional small sprite artifacts" — reported, not reproduced.** The owner
has seen small blocks that look like sprite cells that failed to write. Three
independent detectors failed to find it: enclosed-black count is 0 in ours
against 11 in MAME, and hole rate is statistically indistinguishable across
builds. It may still be real — a sprite fetching wrong-but-plausibly-coloured
data cannot be caught by any statistical shape test — but at present it is an
observation without a measurement behind it.

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

- **Any game other than `eprom`.** The Escape board family also ran the *Klax*
  and *Guts n' Glory* prototypes, and older versions of this README implied the
  core covered them. It does not: those are single-CPU boards using JSA-II with
  an OKI6295, and there is no OKI6295 in this RTL. `build_rom.py` builds only
  the MAME `eprom` set and rejects chips whose CRCs do not match it.
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

The core boots clean. Press **L1** to bring up the on-screen HUD; press it
again to hide it. **R1** cycles 6 pages (0–5):

| Page | Shows |
|---|---|
| 0 | JSA/sound status, coin and credit counters, bus-cycle length |
| 1 | Second-processor window: extra-68k PC, last mailbox response |
| 2 | Main-CPU window: video-CPU PC, last write address, crash forensics |
| 3 | Engine window: actor-table head, game mode bytes |
| 4 | `apply_stain` diagnostic |
| 5 | **Cadence** — the performance figure described above |

A small cyan **build number** sits in the bottom-right corner at all times,
HUD or no HUD. Check it matches the build you installed — it is the only guard
against flashing the wrong file, and it has caught that mistake before. It
shows the low two hex digits of the build id, so it distinguishes builds within
a run of 256 rather than absolutely.

If you report a problem, a photo showing the build number plus page 2 (or page
5 for a speed complaint) usually contains everything needed to diagnose it.

---

## Notes for this release

**The core still installs as `spoonelli.ataridual68k`.** Renaming it to
`spoonelli.eprom` was considered for this release and **deliberately not done**
— see below.

**Nothing in the package is copyrighted content.** No ROM data, and the
platform image is an original text placeholder, not marquee art. The packaging
script refuses to build if ROM data reaches the staging tree, if the assets
folder contains anything but the placeholder note, or if any file other than
the bitstream exceeds 600 KB. All three checks are tested against deliberately
broken inputs, so they are known to be capable of failing.

### Why the core was not renamed

The Pocket keys its save files by **platform id**, not by core directory name,
and the platform id (`eprom`) would not change in a rename — so on the
repository's own evidence a rename would *not* orphan anyone's high scores, and
old and new installs would in fact share one save file.

That evidence is strong but not conclusive: Analogue's specification is not
vendored here, so the firmware's actual rule cannot be read off a normative
document. What *is* proven is that the core itself cannot influence the path —
the FPGA only ever sends a numeric slot id over the bridge and never a filename.

Given that being wrong means silently destroying somebody's high-score table on
upgrade, the rename waits for one device test: install the renamed core
alongside an existing `.sav` and confirm the scores still appear. It is a
five-line change once that is done.

Two further things to know if it does happen: the old
`/Cores/spoonelli.ataridual68k/` folder will remain on the SD card and show up
as a **second entry** in the Pocket menu until deleted, and the platform's
display name (`Atari Dual 68k`) is a separate string worth deciding on at the
same time.
