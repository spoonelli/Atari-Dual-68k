# Third-party reference sources — attribution & license

The `.cpp` / `.h` files in this directory are **unmodified source files from the
[MAME](https://github.com/mamedev/mame) project**, included here solely as a
**hardware-behavior reference** for the independent RTL re-implementation in
`src/`. They are **not compiled into, linked with, or otherwise part of** the
GPL-3.0-licensed FPGA core; they are documentation of the original arcade
hardware's behavior.

| File | Origin in MAME | License | Copyright |
|------|----------------|---------|-----------|
| `eprom.cpp`    | `src/mame/atari/eprom.cpp`     | BSD-3-Clause | Aaron Giles |
| `atarijsa.cpp` / `.h` | `src/mame/atari/atarijsa.*` | BSD-3-Clause | Aaron Giles |
| `atarimo.cpp` / `.h`  | `src/mame/atari/atarimo.*`  | BSD-3-Clause | Aaron Giles |
| `slapstic.cpp` / `.h` | `src/mame/machine/slapstic.*` | BSD-3-Clause | Aaron Giles |
| `atarigen.cpp` / `.h` | `src/mame/atari/atarigen.*` | BSD-3-Clause | Aaron Giles |

Each file also retains its original `// license:` and `// copyright-holders:`
header. With deep thanks to Aaron Giles and the MAME developers for their
preservation work.

The `reference/schematics/` originals (Atari SP-332) are **not** redistributed
here — see `reference/schematics/README.md`.

---

## BSD-3-Clause License (as applied to the MAME files above)

Copyright (c) Aaron Giles and the MAME development team.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
