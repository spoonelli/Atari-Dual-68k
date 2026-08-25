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

The Interact menu (Pocket **+** button) has 11 entries: Service Mode, Soft Reset
Core, Skip Self-Test, stick options (Invert Stick X / Y, Swap Stick Axes, Analog
Deadzone), **Music / Speech volume** sliders, **EEPROM Autosave**, and ROM
Shadow 0x54000. The developer-only tuning toggles were removed from the menu;
they are still reachable in the RTL but no longer clutter the player-facing
list.

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

## Dev-build diagnostics (expected, not a bug)

Dev builds show a cyan **build number** bottom-right — check it matches the
zip you flashed — plus a diagnostic HUD:

- **L** toggles the debug overlay
- **R** cycles 4 HUD pages: 0 = JSA/sound status · 1 = world-engine (extra
  CPU) PC + restart counter · 2 = main-CPU forensics / CRAM checksums ·
  3 = engine state + frame counter
- **R2 (hold)** = video-fetch kill test (screen garbles while held — a probe,
  not a fault)

The planned release core (`spoonelli.eprom`) will ship with all diagnostics
removed.

## Reporting problems

A photo or short video showing the on-screen build number plus HUD page 1 or
2 usually contains everything needed to diagnose an issue — the forensics
pages latch crash addresses and checksums precisely so one picture tells the
story.
