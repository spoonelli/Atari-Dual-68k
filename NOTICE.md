# NOTICE — third-party components and attributions

This project's own RTL and tooling are **GPL-3.0** (see `LICENSE`). The tree
is not uniformly GPL-3.0; this file names every third-party component compiled
into or shipped with a release, its authors, and its licence. File headers are
preserved in place; where a licence requires that its text accompany binary
distributions, that text is reproduced in full under *Licence texts for binary
distribution* below (every release zip carries this file next to
`LICENSE.txt`). The README's *Credits & acknowledgements* section carries the
long-form history; this file is the compliance inventory.

## Compiled into the bitstream

| Component | Author(s) | Licence | Location |
|---|---|---|---|
| Arcade-Atari-system1_MiSTer (RTL base; TMS5220 speech model) | d18c7db (Alex), MiSTer-devel | GPL-3.0 | `third_party/Arcade-Atari-system1_MiSTer/` (submodule); `src/fpga/core/rtl/TMS5220.vhd` (vendored, provenance in header) |
| TG68K.C 68000/68010 soft CPU (both 68ks) | Tobias Gubener (TobiFlex); patches by MikeJ, Till Harbaum, Rok Krajnc, others | LGPL-3.0-or-later (conveyed as part of the GPL-3.0 combined work: LGPL-3.0 is GPL-3.0 plus additional permissions) | `src/fpga/core/rtl/tg68kv/` (2 vendored files, LOCK-output change noted in headers) + submodule |
| T65 6502 soft CPU (JSA-I sound CPU) | Daniel Wallner, Mike Johnson, Wolfgang Scherr, Morten Leikvoll | BSD-style (OpenCores) | `third_party/Arcade-Atari-system1_MiSTer/rtl/lib/T65/` — its "redistributions in synthesized form" clause is met by reproducing its notice, conditions and disclaimer under *Licence texts for binary distribution* below |
| jt51 YM2151 FM core | Jose Tejada (jotego) | GPL-3.0 | `third_party/jt51/` (submodule) + `src/fpga/core/rtl/jt51v/jt51.v`, `jt51_acc.v` (vendored, per-channel gain change MIX-100, noted in headers) |
| jt6295 OKI MSM6295 ADPCM core (JSA-II sound board, used by the Klax prototypes and Guts n' Glory) | Jose Tejada (jotego) | GPL-3.0 | `third_party/jt6295/` (submodule, unmodified). **MiSTer:** compiled into the single rbf since GAMESEL-167 (one bitstream serves every game; held in reset while Escape runs). **Pocket:** listed in the project but pruned from the `spoonelli.eprom` (Escape) bitstream; it is compiled into the Klax (`spoonelli.klaxp`) and Guts n' Glory (`spoonelli.guts`) Pocket cores. |
| IIR_filter 3-tap audio low-pass (Pocket audio output; MiSTer's default audio filter) | Sorgelig (MiSTer framework) | GPL-2.0-or-later (combined here under GPL-3.0) | `src/fpga/core/rtl/iir_filter.v` (vendored from MiSTer `sys/iir_filter.v`, unused `DC_blocker` removed, noted in header). **Pocket:** in the Klax and Guts n' Glory cores from v0.3.0 (AUDFLT-190); the Escape core picks it up at its next release. **MiSTer:** the framework's own copy (`src/mister/sys/`). |
| psram.sv PSRAM controller | Adam Gastineau (agg23) | MIT (© 2022; the notice MIT requires in all copies, binaries included, is reproduced under *Licence texts for binary distribution* below) | `third_party/analogue-pocket-utils/psram.sv` |
| Analogue Platform Framework | Analogue | Proprietary — Analogue Software License Agreement (header of `src/fpga/apf/apf_top.v`). Not OSI; explicitly excluded from this project's GPL-3.0 claim | `src/fpga/apf/` |

## Corresponding source

The complete corresponding source of every released bitstream is the git tag
of that release in <https://github.com/spoonelli/Atari-Dual-68k> (Pocket tags
`v*`, MiSTer tags `mister-v*`), with its submodules at the commits the tag
records. The Analogue Platform Framework files in `src/fpga/apf/` are there
under Analogue's own licence (see above).

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

## Licence texts for binary distribution

Reproduced verbatim from the file headers, as these licences require for
binary (synthesized) distributions. GPL-3.0 is `LICENSE` / `LICENSE.txt`.

### T65 6502 core (`third_party/Arcade-Atari-system1_MiSTer/rtl/lib/T65/`)

```
Copyright (c) 2002...2015
              Daniel Wallner (jesus <at> opencores <dot> org)
              Mike Johnson   (mikej <at> fpgaarcade <dot> com)
              Wolfgang Scherr (WoS <at> pin4 <dot> at>
              Morten Leikvoll ()

All rights reserved

Redistribution and use in source and synthezised forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

Redistributions in synthesized form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

Neither the name of the author nor the names of other contributors may
be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### psram.sv (`third_party/analogue-pocket-utils/psram.sv`)

```
MIT License

Copyright (c) 2022 Adam Gastineau

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
