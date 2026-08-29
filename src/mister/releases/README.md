# Escape from the Planet of the Robot Monsters — MiSTer core

A MiSTer (DE10-Nano) port of the
[Atari Dual 68k](https://github.com/spoonelli/Atari-Dual-68k) core,
implementing Atari Games' 1989 arcade release (MAME set `eprom`).

**What you get:** both 68010s genuinely concurrent (68000 selectable — the
dedicated cabinet shipped a 68010, the JAMMA version a 68000; both are
authentic), full three-layer video with the schematic's paired line-buffer
sprite engine, JSA-I audio (YM2151 + TMS5220 speech), and the hall-effect
joystick model. The machine RTL is identical to the Analogue Pocket
release — a fix on one platform is a fix on both.

**Measured accuracy** (details in the project
[README](https://github.com/spoonelli/Atari-Dual-68k#readme) and
[docs/DEVIATIONS.md](https://github.com/spoonelli/Atari-Dual-68k/blob/main/docs/DEVIATIONS.md)):
attract-loop period within 0.35% of MAME; walk cadence locked at 8
frames/phase against real-cabinet captures; the core never runs faster than
authentic. These figures were measured on the shared machine RTL; the
MiSTer port is still accumulating its own device hours — treat these as
field-testing builds.

## Install

1. Copy `escape_YYYYMMDD.rbf` (dated per MiSTer's naming convention) to
   `_Arcade/cores/` on your MiSTer SD card. **Delete any older
   `escape*.rbf`** — the framework matches by prefix and may load the
   stale one.
2. Copy `Escape from the Planet of the Robot Monsters (set 1).mra` to `_Arcade/`.
3. Put your own MAME `eprom.zip` romset in `games/mame/`. **No ROM data is
   included** — the MRA assembles the game from your verified dumps.
4. Launch the game from the Arcade menu.

## First boot

A splash page shows for a few seconds at core load — check that its
**MISTER BUILD number** matches the build you installed. It is the only
guard against a cached or stale `.rbf`, and it has caught that more than
once.

## Controls

Run **Define eprom buttons** in the OSD the first time (new buttons do not
appear in previously saved maps): Jump, Fire, Duck, Bomb, Start, Coin, and
Credits.

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

Include the splash's build number (a photo of the splash is ideal) and a
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
