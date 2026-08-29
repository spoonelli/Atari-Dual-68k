# NOTICE — third-party components and attributions

This project's own RTL and tooling are **GPL-3.0** (see `LICENSE`). The tree
is not uniformly GPL-3.0; this file names every third-party component compiled
into or shipped with a release, its authors, and its licence. File headers are
preserved in place; where a licence requires that its text accompany binary
distributions, that text is in the named file's header and this NOTICE is the
pointer to it. The README's *Credits & acknowledgements* section carries the
long-form history; this file is the compliance inventory.

## Compiled into the bitstream

| Component | Author(s) | Licence | Location |
|---|---|---|---|
| Arcade-Atari-system1_MiSTer (RTL base; TMS5220 speech model) | d18c7db (Alex), MiSTer-devel | GPL-3.0 | `third_party/Arcade-Atari-system1_MiSTer/` (submodule); `src/fpga/core/rtl/TMS5220.vhd` (vendored, provenance in header) |
| TG68K.C 68000/68010 soft CPU (both 68ks) | Tobias Gubener (TobiFlex); patches by MikeJ, Till Harbaum, Rok Krajnc, others | LGPL-3.0-or-later | `src/fpga/core/rtl/tg68kv/` (2 vendored files, LOCK-output change noted in headers) + submodule |
| T65 6502 soft CPU (JSA-I sound CPU) | Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll | BSD-style (OpenCores) | `third_party/Arcade-Atari-system1_MiSTer/rtl/lib/T65/` — its "redistributions in synthesized form" clause is satisfied by this documentation |
| jt51 YM2151 FM core | Jose Tejada (jotego) | GPL-3.0 | `third_party/jt51/` (submodule) + `src/fpga/core/rtl/jt51v/jt51.v`, `jt51_acc.v` (vendored, per-channel gain change MIX-100, noted in headers) |
| psram.sv PSRAM controller | Adam Gastineau (agg23) | MIT (© 2022; text in file header, which MIT requires accompany all copies including binaries) | `third_party/analogue-pocket-utils/psram.sv` |
| Analogue Platform Framework | Analogue | Proprietary — Analogue Software License Agreement (header of `src/fpga/apf/apf_top.v`). Not OSI; explicitly excluded from this project's GPL-3.0 claim | `src/fpga/apf/` |

## Reference material (not compiled)

| Component | Author(s) | Licence | Location |
|---|---|---|---|
| MAME driver sources (9 unmodified files, reading material) | Aaron Giles and MAME contributors | BSD-3-Clause | `reference/` — full licence reproduced in `reference/NOTICE.md`. **No MAME source is compiled into the core**; the RTL is an independent re-implementation from documented behavior |

## Known open item

`TMS5220.vhd` (© 2020 d18c7db, GPL-3.0-or-later) states it is based primarily
on MAME's `tms5220.cpp`. If its coefficient tables derive from that file, a
BSD-3 notice for MAME's speech-chip authors (Frank Palazzolo, Jarek
Burczynski, Jonathan Gevaryahu, Aaron Giles) is owed alongside it. Inherited
from upstream, flagged rather than silently shipped; it is recorded here and
in the README until resolved.

## Trademarks and content

This project distributes no ROM data and no copyrighted artwork (the platform
image is an original text placeholder). *Escape from the Planet of the Robot
Monsters*, *Klax* and *Guts n' Glory* are trademarks of their respective
rights holders. Use only with software you are legally entitled to.
