# Atari Multi 68k — openFPGA core (Analogue Pocket)

An openFPGA core for Atari Games' **"Escape"** arcade hardware — the dual-68000 board
whose flagship title is *Escape from the Planet of the Robot Monsters* (MAME's initials
gag: **E.P.R.O.M.**). The same board family also ran the *Klax* prototype and
*Guts n' Glory* prototype, which is why this is a "multi" core.

> Built for the [Analogue Pocket](https://www.analogue.co/pocket) via the openFPGA framework.
> This project ships **no ROMs**. You must supply your own dumps.

## Status

🚧 **Early scaffold.** The Analogue Platform Framework (APF) wrapper is in place and will
build a gray test screen. The actual arcade RTL is not yet implemented — see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the hardware map and build plan.

## Hardware being implemented (from MAME `eprom.cpp`)

| Block        | Real chip                              | Plan / building block                     |
|--------------|----------------------------------------|-------------------------------------------|
| Main CPU ×2  | 68000 @ 7.16 MHz, shared RAM           | [fx68k](https://github.com/ijor/fx68k)    |
| Sound        | Atari **JSA-I** board (6502 + YM2151)  | T65 (6502) + [jt51](https://github.com/jotego/jt51) (+ POKEY / TMS5220) |
| Video        | Atari motion objects + 2 tilemaps      | custom RTL (ref: `atarimo`)               |
| Protection   | **SLAPSTIC**                           | custom RTL (ref: `slapstic`)              |
| Palette      | 2048-color, RGB intensity              | custom RTL                                |
| Output       | 336×240, ~57.6 Hz                      | scaled via APF video                      |

## Repo layout

```
core.json, video.json, data.json, ...   openFPGA core metadata
dist/                                    files packaged onto the Pocket SD card
  platforms/atari_escape.json            platform definition
  assets/atari_escape/common/            where the user places ROMs
src/fpga/                                Quartus project
  apf/                                   Analogue Platform Framework (do not edit)
  core/core_top.v                        our core's top level — RTL goes here
reference/                               MAME hardware reference (eprom.cpp, atarijsa, ...)
docs/ARCHITECTURE.md                     hardware map + implementation roadmap
.github/workflows/build.yml              cloud Quartus build (Mac has no local Quartus)
```

## Building

Quartus Prime does **not** run on macOS. This repo is set up to compile the bitstream
in **GitHub Actions** (see `.github/workflows/build.yml`) so you never install Quartus
locally. The workflow produces `bitstream.rbf_r` as a build artifact.

## Legal

This core contains no copyrighted ROM data. Escape from the Planet of the Robot Monsters,
Klax, and Guts n' Glory are trademarks of their respective rights holders. Use only with
software you are legally entitled to.
