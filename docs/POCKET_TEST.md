# Running on the Analogue Pocket

What a current build does: boots the full dual-68000 Escape program from your
ROM, runs the complete attract cycle (story, TMS5220 announcer speech, high
scores, demo), takes coins, and plays. Native Escape raster
(456×262 @ ~59.9 Hz, 336×240 visible). High scores and operator settings live
in the emulated 2804 EEPROM and **survive a power cycle** — see
[`EEPROM_SAVE.md`](EEPROM_SAVE.md).

## Install

1. **Get the package**: download `AtariDual68k-pocket-v<version>.zip` from the
   [Releases page](https://github.com/spoonelli/Atari-Dual-68k/releases) and
   merge its `Cores/ Platforms/ Assets/` onto the SD root. It carries no ROM
   data; `build_rom.py` is at the top level of the zip.
   *Testing a development build instead?* Download the `bitstream` artifact
   from the latest green
   [Actions run](https://github.com/spoonelli/Atari-Dual-68k/actions) (or your
   fork's), unzip, then build the SD package (correct Analogue layout, no ROM)
   and merge it the same way:
   ```bash
   ./support/package.sh path/to/bitstream/output/bitstream.rbf_r
   ```
   > **Updating from a build older than EEPROM saves?** Copy the whole
   > `Cores/` folder across, not just `bitstream.rbf_r` — the save slot is
   > declared in `data.json`, and a bitstream-only update leaves the core
   > with nowhere to write high scores.
2. **SD card layout** (Pocket firmware 1.1+, jailbroken for unofficial cores):
   ```
   /Cores/spoonelli.eprom/
       bitstream.rbf_r
       core.json  audio.json  data.json  input.json  interact.json  variants.json  video.json
       info.txt   icon.bin
   /Platforms/eprom.json
   /Platforms/_images/eprom.bin        (text placeholder; swap in your own art)
   /Assets/eprom/common/atari_escape.rom
   /Assets/eprom/common/atari_escape2.rom (set 2, optional)
   /Assets/eprom/spoonelli.eprom/Escape from the Planet of the Robot Monsters (set 1).json
   /Assets/eprom/spoonelli.eprom/_alternatives/Escape from the Planet of the Robot Monsters (set 2).json
   /Saves/eprom/common/atari_escape.sav   (created by the Pocket, 512 bytes)
   /Saves/eprom/common/atari_escape2.sav  (set 2's own, likewise)
   ```
   - `atari_escape.sav` is the EEPROM — high scores and operator settings.
     **You do not create it**: the Pocket writes it the first time the game
     changes anything, and reloads it on every launch. Deleting it resets the
     machine to a factory-fresh EEPROM. If you have a MAME `eprom` nvram dump
     you can drop it in as this file and it will load.
   - The two `.json` files ship in the package (POCKETSET-175): each is an APF
     instance naming one set's ROM and save file, so the launch browser lists
     set 1 at the top and set 2 inside `_alternatives`, and each set keeps its
     own high scores.
   - `atari_escape.rom` is built from your own verified dumps:
     `python3 support/build_rom.py /path/to/eprom` (an `eprom2` dump writes
     `atari_escape2.rom`)
     (see [`ROMS.md`](ROMS.md)). This project never distributes ROM data —
     and no platform artwork either; the shipped image is an original text
     placeholder you can replace on your SD.
3. Insert SD, power on, open **Esc Robot Monst** from the Pocket menu. It lists
   the sets on launch: pick set 1, or open `_alternatives` for set 2. Set 2 is
   a 0.2 test item (passed on RC 3): it must pass self-test (its POST checksums the tenth
   program pair through the A19 remap) and play, and its high scores must land
   in `atari_escape2.sav` without touching set 1's.

## Controls

| Pocket | Game |
|---|---|
| D-pad | Move (emulated hall-effect stick; dock analog takes priority) |
| Y | Jump / Start |
| B | Fire |
| A | Duck |
| X | Bomb (all three buttons at once) |
| Select | Coin |
| Start | Self-test step/continue switch |

### The Interact menu

Pocket **+** button. Twelve entries:

| Entry | |
|---|---|
| Service Mode | the cabinet's operator switch |
| Soft Reset Core | |
| Skip Self-Test | |
| Invert Stick X / Y, Swap Stick Axes, Analog Deadzone | stick options |
| Music Volume, Speech Volume | |
| EEPROM Autosave | on by default; see below |
| ROM Shadow 0x54000 | **leave on** — see [`RELEASE_NOTES.md`](RELEASE_NOTES.md) |
| Developer HUD | off by default; gates the build stamp, the diagnostic HUD and its probes (build 114+) |

> **The Pocket renders only the first 16 interact variables.** Anything past
> index 16 is invisible on device — which is exactly how the ROM Shadow toggle
> came to be unreachable while sitting at index 27 in a 28-entry menu. That cap
> is the reason the menu was trimmed from 28 entries to 11 (Developer HUD, added
> at build 114, makes 12), and the reason
> development controls must not be added back to it. The RTL and its bridge
> decodes are untouched; the controls are simply not exposed.

## Saved data

Operator settings and the high-score table are kept in the emulated 2804
EEPROM and persist across power-offs, exactly as the cabinet did.

- **EEPROM Autosave** (on by default) pushes the EEPROM to the SD card about a
  second after the game finishes writing it, so a score survives an unclean
  power-off, not just a clean core exit. Turn it off and the save still happens
  when you exit the core normally.
- With **Developer HUD** ticked and the debug overlay up (**L1**), the 7th segment of the bottom strip is the
  save indicator: red = virgin EEPROM · teal = save file loaded · amber =
  unsaved change pending · blue = snapshot taken, Pocket has not confirmed ·
  green = written to SD · magenta = the Pocket refused the write.
- To reset the machine to factory defaults, delete
  `/Saves/eprom/common/atari_escape.sav`.

The full test procedure, and what to do if scores do *not* persist, is in
[`EEPROM_SAVE.md`](EEPROM_SAVE.md).

## The build number, and the diagnostic HUD

Every build shows a cyan **build number** in the bottom-right corner once
**Developer HUD** is ticked in the core menu — with the HUD hidden and with it
up alike (from build 115 the stamp follows that gate, so a player's screen
carries no plate). Check it matches the zip you flashed —
this is the only on-device guard against flashing the wrong file. It reads two
hex digits (the low half of `BUILD_ID`); see "Build number" below.

**The HUD is OFF by default and nothing else draws over the picture.** Tick
**Developer HUD** in the core menu, then press **L1** to bring it up. It is a development tool, not a fault, and it is not
removed from release builds — the forensics pages are how problems get
diagnosed from a photo.

With the HUD up:

- **L1** toggles it back off
- **R1** cycles **7 HUD pages** (0-6), shown in the rightmost digit of the hex row:
  - **0** — default: JSA/sound status, coin/credit counters, extra-CPU bus-cycle length
  - **1** — second-processor window: extra-68k PC (frame-latched) + last mailbox response
  - **2** — main-CPU window: video-CPU PC, last main write address, crash forensics
  - **3** — engine window: actor-table head word + game mode bytes
  - **4** — `apply_stain` diagnostic: stained pixels, span first/last line
  - **5** — cadence page: video- and world-CPU logic frames per 256 video frames,
    plus video-CPU bus cycles/frame. `0100` hex = 1.0000 updates/frame;
    MAME's reference is `00FF`/`0100` (see [`PERF_CADENCE.md`](investigations/PERF_CADENCE.md))
  - **6** — MO telemetry (MOTEL-129): line-end truncation count + worst 16-line
    fetch latency, with the video-decodable frame counter
- **R1 (hold)** = hide motion objects · **L2 (hold)** = hide the alpha layer ·
  **R2 (hold)** = video-fetch kill test (screen garbles while held — a probe,
  not a fault)

The three hold-to-act probes above only respond **while the HUD is on**, so a
player cannot blank the sprites or the screen by accident. `R1` still advances
the page counter with the HUD hidden; the page it lands on is whatever appears
when you next press **L1**.

### Build number

The stamp is the **low two hex digits** of the 16-bit `BUILD_ID` — BUILD 112
shows `12`. With the HUD up, the two digits to its left (the debug-page number
and the top `BUILD_ID` digit) are covered by the checksum bit row, so the same
two digits are what you read in both states, and a photo of a clean screen and
a photo of the HUD report the same number.

> Because only two of the four digits are on screen, the stamp distinguishes
> builds within a run of 256, not absolutely: `0x3112` and `0x2112` both read
> `12`. That has been enough so far — consecutive builds differ in the low
> digits — but it is worth knowing when comparing two builds far apart.

Write build NN as `16'h00NN` — the digits are hex nibbles, not ASCII
(`16'h3431` shows `31`, which is how the v0.2.0 release candidate first came
out). `package.sh` guard 6 refuses a package whose `BUILD_ID` disagrees with
its own `shows 'NN'` comment, or with `EXPECT_BUILD=NN` when given.

## The Klax and Guts n' Glory cores (milestone 0.3, test builds)

Two more cores from the same tree, each its own zip: `spoonelli.klaxp`
(platform `klaxp`) and `spoonelli.guts` (platform `guts`). Install exactly as
above, with their own folders and ROM names ([`ROMS.md`](ROMS.md) section 3b).

| Core | Controls | Menu differences from Escape |
|---|---|---|
| Klax | d-pad = paddle; **A** Flip / Start, **B** Flip (2nd) - the same function, as on the cabinet's two Flip buttons; Select = coin | no Skip Self-Test, no ROM-shadow toggle, no analogue-stick options; "Sample Volume" replaces "Speech Volume" (it scales the OKI6295) |
| Guts n' Glory | analogue stick or d-pad; **A** Button 1 (fire), **B** Button 2 (the game's own "Left START"), **X** Button 3; Select = coin | no Skip Self-Test, no ROM-shadow toggle; "Sample Volume" |

Both are single-CPU, so the "Waiting for Second Processor" boot hold does not
appear. The Developer HUD and build number work as on Escape. The device test
plan for the first test builds is K1–K7 / G1–G7 (owner's test plan).

## Reporting problems

Tick **Developer HUD**, press **L1** to bring up the HUD, then **R1** to reach page 2 (main-CPU
forensics) or page 1 (second-processor window). A photo or short video showing
the on-screen build number plus one of those pages usually contains everything
needed to diagnose an issue — the forensics pages latch crash addresses and
checksums precisely so one picture tells the story.

For a **performance** complaint (sluggishness in crowds) photograph **page 5**
instead: it reports the cadence figure directly, in the same units MAME is
quoted in.
