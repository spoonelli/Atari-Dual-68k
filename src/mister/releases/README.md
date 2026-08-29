# Escape from the Planet of the Robot Monsters — MiSTer core

Atari Games, 1989. A port of the [Atari Dual 68k](https://github.com/spoonelli/Atari-Dual-68k)
core: two 68010s on shared RAM, the schematic's paired line-buffer sprite
engine, full JSA-I audio (YM2151 + TMS5220 speech), and the hall-effect
joystick model. Field-testing builds — see *Reporting problems* below.

## Install

1. Copy `escape.rbf` to `_Arcade/cores/` on your MiSTer SD card.
2. Copy `Escape from the Planet of the Robot Monsters (set 1).mra` to `_Arcade/`.
3. Put your own MAME `eprom.zip` romset in `games/mame/`. **No ROM data is
   included** — the MRA assembles the game from your verified dumps.
4. Launch the game from the Arcade menu.

## First boot

A splash page shows for a few seconds at core load — check that its
**MISTER BUILD number** matches the build you installed. It is the only
guard against an old `.rbf` being cached, and it has caught that more
than once.

## Controls

Run **Define eprom buttons** in the OSD the first time (new buttons do not
appear in previously saved maps): Jump, Fire, Duck, Bomb, Start, Coin, and
Credits. The **C key** on a keyboard also cycles the credits pages.

## OSD options

- **Music Volume / Speech Volume** — independent 8-step sliders.
- **ROM Shadow** — leave On (default); it is a performance feature, not a hack.
- **Reset** — the machine's hard reset.

## Reporting problems

Include the splash's build number (a photo of the splash is ideal) and a
short video if the issue is visual. The full port record — what is verified
on hardware, known behaviors, and how the SDRAM arbitration differs from the
Pocket — lives in
[docs/MISTER.md](https://github.com/spoonelli/Atari-Dual-68k/blob/mister/docs/MISTER.md).

## License

GPL-3.0 — sources at https://github.com/spoonelli/Atari-Dual-68k (branch
`mister`). Third-party components and attributions: NOTICE.md in the repo.
This project distributes no ROM data; use only with software you are legally
entitled to.
