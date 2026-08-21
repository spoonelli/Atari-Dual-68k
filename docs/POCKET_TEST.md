# Running on the Analogue Pocket

What a current build does: boots the full dual-68000 Escape program from your
ROM, runs the complete attract cycle (story, TMS5220 announcer speech, high
scores, demo), takes coins, and plays. Native Escape raster
(456×262 @ ~59.9 Hz, 336×240 visible).

## Install

1. **Get the bitstream**: download the `bitstream` artifact from the latest
   green [Actions run](https://github.com/spoonelli/Atari-Dual-68k/actions)
   (or your fork's), unzip, then build the SD package (correct Analogue layout,
   no ROM):
   ```bash
   ./support/package.sh path/to/bitstream/output/bitstream.rbf_r
   ```
   and merge the resulting zip's `Cores/ Platforms/ Assets/` onto the SD root.
2. **SD card layout** (Pocket firmware 1.1+, jailbroken for unofficial cores):
   ```
   /Cores/spoonelli.ataridual68k/
       bitstream.rbf_r
       core.json  audio.json  data.json  input.json  interact.json  variants.json  video.json
       info.txt   icon.bin
   /Platforms/eprom.json
   /Platforms/_images/eprom.bin        (text placeholder; swap in your own art)
   /Assets/eprom/common/atari_escape.rom
   ```
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
stick options (invert/swap/deadzone), World X Align, and **Music / Speech
volume** sliders.

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
