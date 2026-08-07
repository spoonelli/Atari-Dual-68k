# Testing on the Analogue Pocket — hello-world drop

What this build does: boots both 68010s on real Escape code loaded from your ROM via
SDRAM, and shows a **status screen** (no game video yet):

| Screen area   | Meaning |
|---------------|---------|
| Top band      | **green** = Video CPU fetched its reset PC and is executing ROM · **red** = it isn't |
| Middle band   | **green** = Video CPU released the Extra CPU (360010 D0) · **red** = still held in reset |
| Bottom band   | gray reference |

Native Escape raster (456×262 @ ~59.9 Hz, 336×240 visible).

## Install

1. **Get the bitstream**: download the `bitstream` artifact from the latest green
   [Actions run](https://github.com/spoonelli/Atari-Dual-68k/actions) → unzip →
   `bitstream.rbf_r`.
2. **SD card layout** (Pocket firmware 1.1+, jailbroken for unofficial cores):
   ```
   /Cores/spoonelli.Atari Dual 68k/
       bitstream.rbf_r
       core.json  audio.json  data.json  input.json  interact.json  variants.json  video.json
       info.txt   icon.bin
   /Platforms/atari_escape.json
   /Platforms/_images/atari_escape.bin
   /Assets/atari_escape/common/atari_escape.rom
   ```
   - The json/txt/bin files come from this repo (`core.json` etc. at the root,
     `dist/platforms/*` for the two Platforms files, `dist/icon.bin`).
   - `atari_escape.rom` is built from your dumps:
     `python3 support/build_rom.py /path/to/eprom dist/assets/atari_escape/common/atari_escape.rom`
3. Insert SD, power on, open the core from the Pocket menu. It will ask for the ROM
   (required slot) on launch.

## Reading the result

- **Green / green**: both CPUs run real code on hardware — the whole spine works
  (SDRAM download + fetch, decode, dual-CPU, IRQ plumbing). Screenshot it!
- **Green / red**: Video CPU runs but hasn't released the Extra CPU — could simply be
  boot code order (it may wait on things our stubs don't provide yet). Still a pass
  for the main spine.
- **Red / red**: CPU never fetched its reset PC — points at ROM download or SDRAM
  read path on real hardware (works in sim; timing/pin issue would show here).
- **No video at all**: PLL/raster issue — different failure class, also informative.

Whatever it shows, report back the colors — each combination points at a specific
subsystem and that's exactly what this drop is designed to isolate.
