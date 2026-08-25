# Running on the Analogue Pocket

What a current build does: boots the full dual-68000 Escape program from your
ROM, runs the complete attract cycle (story, TMS5220 announcer speech, high
scores, demo), takes coins, and plays. Native Escape raster
(456×262 @ ~59.9 Hz, 336×240 visible). High scores and operator settings live
in the emulated 2804 EEPROM and **survive a power cycle** — see
[`EEPROM_SAVE.md`](EEPROM_SAVE.md).

## Install

1. **Get the bitstream**: download the `bitstream` artifact from the latest
   green [Actions run](https://github.com/spoonelli/Atari-Dual-68k/actions)
   (or your fork's), unzip, then build the SD package (correct Analogue layout,
   no ROM):
   ```bash
   ./support/package.sh path/to/bitstream/output/bitstream.rbf_r
   ```
   and merge the resulting zip's `Cores/ Platforms/ Assets/` onto the SD root.
   > **Updating from a build older than EEPROM saves?** Copy the whole
   > `Cores/` folder across, not just `bitstream.rbf_r` — the save slot is
   > declared in `data.json`, and a bitstream-only update leaves the core
   > with nowhere to write high scores.
2. **SD card layout** (Pocket firmware 1.1+, jailbroken for unofficial cores):
   ```
   /Cores/spoonelli.ataridual68k/
       bitstream.rbf_r
       core.json  audio.json  data.json  input.json  interact.json  variants.json  video.json
       info.txt   icon.bin
   /Platforms/eprom.json
   /Platforms/_images/eprom.bin        (text placeholder; swap in your own art)
   /Assets/eprom/common/atari_escape.rom
   /Saves/eprom/common/atari_escape.sav   (created by the Pocket, 512 bytes)
   ```
   - `atari_escape.sav` is the EEPROM — high scores and operator settings.
     **You do not create it**: the Pocket writes it the first time the game
     changes anything, and reloads it on every launch. Deleting it resets the
     machine to a factory-fresh EEPROM. If you have a MAME `eprom` nvram dump
     you can drop it in as this file and it will load.
   - `atari_escape.rom` is built from your own verified dumps:
     `python3 support/build_rom.py /path/to/eprom ./atari_escape.rom`
     (see [`ROMS.md`](ROMS.md)). This project never distributes ROM data —
     and no platform artwork either; the shipped image is an original text
     placeholder you can replace on your SD.
3. Insert SD, power on, open **Atari Dual 68k** from the Pocket menu. It asks
   for the ROM (required slot) on launch.

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

The Interact menu (Pocket **+** button) has Service Mode, Soft Reset,
stick options (invert/swap/deadzone), World X Align, **Music / Speech
volume** sliders, and **EEPROM Autosave**.

## Saved data

Operator settings and the high-score table are kept in the emulated 2804
EEPROM and persist across power-offs, exactly as the cabinet did.

- **EEPROM Autosave** (on by default) pushes the EEPROM to the SD card about a
  second after the game finishes writing it, so a score survives an unclean
  power-off, not just a clean core exit. Turn it off and the save still happens
  when you exit the core normally.
- With the debug overlay on (**L**), the 7th segment of the bottom strip is the
  save indicator: red = virgin EEPROM · teal = save file loaded · amber =
  unsaved change pending · blue = snapshot taken, Pocket has not confirmed ·
  green = written to SD · magenta = the Pocket refused the write.
- To reset the machine to factory defaults, delete
  `/Saves/eprom/common/atari_escape.sav`.

The full test procedure, and what to do if scores do *not* persist, is in
[`EEPROM_SAVE.md`](EEPROM_SAVE.md).

## The build number, and the diagnostic HUD

Every build shows a cyan **build number** in the bottom-right corner, on a
clean screen and with the HUD up alike. Check it matches the zip you flashed —
this is the only on-device guard against flashing the wrong file. It reads two
hex digits (the low half of `BUILD_ID`); see "Build number" below.

**The HUD is OFF by default and nothing else draws over the picture.** Press
**L** to bring it up. It is a development tool, not a fault, and it is not
removed from release builds — the forensics pages are how problems get
diagnosed from a photo.

With the HUD up:

- **L** toggles it back off
- **R** cycles **6 HUD pages** (0-5), shown in the rightmost digit of the hex row:
  - **0** — default: JSA/sound status, coin/credit counters, extra-CPU bus-cycle length
  - **1** — second-processor window: extra-68k PC (frame-latched) + last mailbox response
  - **2** — main-CPU window: video-CPU PC, last main write address, crash forensics
  - **3** — engine window: actor-table head word + game mode bytes
  - **4** — `apply_stain` diagnostic: stained pixels, span first/last line
  - **5** — cadence page: video- and world-CPU logic frames per 256 video frames,
    plus video-CPU bus cycles/frame. `0100` hex = 1.0000 updates/frame;
    MAME's reference is `00FF`/`0100` (see [`PERF_CADENCE.md`](PERF_CADENCE.md))
- **R (hold)** = hide motion objects · **L2 (hold)** = hide the alpha layer ·
  **R2 (hold)** = video-fetch kill test (screen garbles while held — a probe,
  not a fault)

The three hold-to-act probes above only respond **while the HUD is on**, so a
player cannot blank the sprites or the screen by accident. `R` still advances
the page counter with the HUD hidden; the page it lands on is whatever appears
when you next press **L**.

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

## Reporting problems

Press **L** to bring up the HUD, then **R** to reach page 2 (main-CPU
forensics) or page 1 (second-processor window). A photo or short video showing
the on-screen build number plus one of those pages usually contains everything
needed to diagnose an issue — the forensics pages latch crash addresses and
checksums precisely so one picture tells the story.

For a **performance** complaint (sluggishness in crowds) photograph **page 5**
instead: it reports the cadence figure directly, in the same units MAME is
quoted in.
