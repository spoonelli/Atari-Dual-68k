# MiSTer (DE10-Nano) port

A second front end for the same machine. `src/mister/` holds a MiSTer top level
that instantiates **the identical RTL the Pocket build uses** — `escape_core`,
`escape_mob`, `escape_prio`, `hall_stick`, `sdram_simple` — with MiSTer-shaped
glue around it. Nothing in the machine is forked; if you fix a bug in
`src/fpga/core/rtl/`, both platforms get it.

> **Status: first compilable port, never run on hardware by its author.**
> Read [What is verified / what is not](#what-is-verified--what-is-not) before
> you assume anything works.

---

## What you need

* A DE10-Nano running MiSTer.
* **The MiSTer SDRAM module.** This core cannot run without it: the game's ~2.2 MB
  of ROM lives in SDRAM and both 68000s fetch from it every frame.
* Your own dump of the MAME `eprom` romset. **No ROM data ships with this
  project, in any form, ever.** The `.mra` is XML that names MAME chips by
  CRC32 — that is the whole point of the format.

## SD card layout

```
/_Arcade/Escape from the Planet of the Robot Monsters (set 1).mra
/_Arcade/cores/escape.rbf
/games/mame/eprom.zip
```

`games/mame/` is the current, primary location: MiSTer's `mra_loader.cpp`
locates a `games/mame` directory and builds `<mame_root>/mame/<zip>/<file>`
from it. If no `games/mame` exists anywhere it falls back to the directory
holding the `.mra`, so `_Arcade/mame/eprom.zip` also works — but ship and
document `games/mame`.

Rename the built `.rbf` to `escape.rbf`; that is the name the `.mra`'s `<rbf>`
element asks for. (The Quartus output is `output_files/Arcade-Escape.rbf`.)

## Building

```bash
cd src/mister
quartus_sh --flow compile Arcade-Escape
```

Or in the project's Quartus container:

```bash
docker run --rm -v "$PWD":/work -w /work/src/mister \
  theypsilon/quartus-lite-c5:18.1 quartus_sh --flow compile Arcade-Escape
```

Submodules must be checked out (`git submodule update --init --recursive`) —
the build pulls jt51, T65 and TG68K from them.

**Quartus version.** MiSTer officially builds with Quartus **17.0.2 Standard**.
This project's container is **18.1 Lite**, so `src/mister/sys/` carries a
`pll_q18.qip` (a copy of the upstream `pll_q17.qip`) because `sys/sys.qip`
picks its PLL flavour from the running Quartus version string. If you build
with 17.0.2 nothing changes — `pll_q17.qip` is still there and still used.

`src/mister/sys/` is a **vendored copy** of the MiSTer framework from
`third_party/Arcade-Atari-system1_MiSTer/sys` (GPL). It is vendored rather than
referenced because `sys/sys.qip` resolves paths relative to the project
directory and because of the `pll_q18` addition above.

### Vendored-vs-submodule file rules

Identical to `src/fpga/ap_core.qsf`, and `src/mister/files.qip` repeats the
reasoning in comments:

* `jt51.v` and `jt51_acc.v` come from `src/fpga/core/rtl/jt51v/`; the rest of
  jt51 from the pristine submodule. The submodule's own `jt51.qip` is **not**
  included — it would redefine the two vendored modules.
* `TG68K.vhd` and `TG68KdotC_Kernel.vhd` come from `src/fpga/core/rtl/tg68kv/`
  (they carry the added `LOCK` output for the TASLOCK-102 read-modify-write
  interlock). Only `TG68K_ALU.vhd` and `TG68K_Pack.vhd` come from the submodule.
* T65 comes from the Arcade-Atari-system1 submodule untouched.

---

## ROM mapping

### The stream the `.mra` produces

2,228,224 bytes (0x220000) — the same size and, after the loader's one
transform, the same content as the Pocket's `atari_escape.rom`.

| Stream offset | Size     | MAME region | Notes |
|---------------|----------|-------------|-------|
| `0x000000`    | 0x80000  | `maincpu`   | four 68000 even/odd pairs |
| `0x080000`    | 0x20000  | `extra`     | second 68000's own program |
| `0x0A0000`    | 0x40000  | —           | zero filler (MAME loads nothing here) |
| `0x0E0000`    | 0x20000  | `extra`     | `ROM_COPY` of `maincpu` 0x60000 |
| `0x100000`    | 0x10000  | `jsa:cpu`   | 6502 program **and** TMS5220 speech LPC |
| `0x110000`    | 0x04000  | `chars`     | alphanumerics |
| `0x114000`    | 0x0C000  | —           | zero filler |
| `0x120000`    | 0x100000 | `spr_tiles` | **four interleaved bit-planes** |

The core writes every byte below `0x120000` into SDRAM unchanged, at the same
address. It is the same layout `support/build_rom.py` produces for the Pocket.

### 68000 byte order

`<interleave output="16">` with `map="01"` / `map="10"`. `map="01"` is the
**first** byte of each output word — MAME's *even* address — i.e. D15–D8 of the
big-endian 68000 word. Confirmed three ways: MiSTer's own
`Main_MiSTer/support/arcade/mra_loader.cpp` (`map` is parsed as hex nibbles,
rightmost nibble emitted first); the `sebdel/mra-tools-c` source
(`get_pattern_from_map` assigns `map_index = n-i-1`, parts are then sorted
ascending and emitted in that order); and cross-checking real MRAs against
MAME's `ROM_LOAD16_BYTE` offsets in the Atari System 1 and Gauntlet cores.

Watch the `0x60000` pair: Atari swapped the suffix convention there, so
`136069-2033.**40**k` is the even byte and `136069-2032.**50**k` is the odd one.
`docs/ROMMAP.md` flags the same exception.

### The sprite region: `ROMREGION_INVERT` and planar→chunky

MAME declares `spr_tiles` as `ROM_REGION( 0x100000, "spr_tiles",
ROMREGION_INVERT )` and decodes it as `RGN_FRAC(1,4)` — four 256 KB bit-planes,
plane 0 the MSB. Our motion-object and playfield engines read **chunky 4bpp**
(one 32-bit burst = one 8-pixel tile row), so two transforms are needed:

1. **invert** every byte (the `ROMREGION_INVERT`), and
2. **repack** four planar bytes into four chunky bytes.

MRA has no primitive for either, and the repack is not an interleave — it moves
*bits*, not bytes. Surveying MiSTer practice (see *Sources* below), MAME-derived
cores do this in the loader RTL and merely document it in the MRA; Atari System
2's `sys2_rom_loader.sv` is the clean precedent (`data_c = ~ioctl_dout;  // the
only load transform`). Schematic-accurate cores usually ignore `ROMREGION_INVERT`
altogether, because it is a MAME `gfxdecode` convenience, not a property of the
silicon — but our engines were written against the MAME-decoded form, so we
follow it.

So the split is:

* **The `.mra` interleaves the four planes** with `<interleave output="32">`,
  four blocks of 256 KB, so that plane0/1/2/3 for the same source index arrive
  byte-adjacent. This is exactly what interleave is for and needs no extensions.
* **The loader RTL inverts and repacks**, in the `SPRITE REPACK` block of
  `src/mister/rtl/escape_mister.v`, with no buffering — it already has all four
  planes in hand by the fourth byte of each group.

The Pocket does the same two transforms offline in `support/build_rom.py`.

### Pocket vs MiSTer: do the layouts differ?

**The SDRAM contents are identical. The download stream is not, and it cannot
be.** The Pocket loads a pre-transformed `.rom` built by a Python tool that can
do arbitrary bit shuffling; an `.mra` cannot express a planar→chunky repack, so
the MiSTer stream carries the sprite region in interleaved-planar form and the
FPGA finishes the job. Everything below `0x120000` is byte-identical in both.

This was **verified**, not assumed: the `.mra` was assembled with the real
`sebdel/mra-tools-c` tool against a local `eprom.zip`, the loader's transform
was replayed over the result, and the output compared to
`support/build_rom.py`'s image — **byte for byte identical across all
0x220000 bytes**. `build_rom.py` in turn CRC32-verifies all 28 chips against
MAME's known-good values.

### Why there is no `eprom2` (set 2) MRA

MAME's `eprom2` loads an **extra** `maincpu` pair at region offset `0x80000`
(`136069-1037.50e` / `136069-1036.40e`) that the parent set does not have. The
combined image both platforms use packs only `0x80000` bytes of `maincpu`, and
the machine's decode was built for set 1, so there is nowhere for that pair to
go. Shipping an `eprom2.mra` today would ship a knowingly-incomplete set.
Adding it means widening the image layout and the decode first.

---

## SDRAM — the highest-risk area

The Pocket has **two** external memories: SDRAM (CPU program ROM + motion-object
graphics) and a CRAM/PSRAM chip that serves **playfield graphics on its own bus**.
The DE10-Nano has one SDRAM. So on MiSTer the playfield graphics channel
(`vg` A/B) was moved onto the SDRAM arbiter, and playfield and motion objects
now share the lowest-priority tier round-robin, below both CPUs.

**Clocking is deliberately unchanged**: 7.159091 MHz CPU/pixel, 35.795455 MHz
SDRAM (5:1), SDRAM chip clock the same 35.795455 MHz at +90° (6984 ps). Those
are bit-for-bit the Pocket's settings after commits *"v22: SDRAM 42.95 → 35.8 MHz
(5x CPU)"* and *"v45: SDRAM chip clock phase 180 → 90 degrees"*.

An earlier draft of this port raised the SDRAM clock to 57.27 MHz (8:1) to pay
for the added playfield traffic. **That was reverted.** `sdram_simple` captures
CL2 read data on a *fixed cycle count* after issuing the command; whether that
capture lands inside the data window depends on the chip-clock phase and on
absolute chip delays (tAC ≈ 6 ns) that do not scale with the clock. The margin
at 35.8 MHz with a quarter-period shift is roughly `T/4 − tAC ≈ 1 ns`; at
57.27 MHz the same quarter-period shift makes it negative. Changing frequency
therefore requires re-tuning the phase *and proving reads on hardware* — the
opposite of a same-day change. The proven configuration was kept and the
bandwidth risk accepted instead, because a starved video fetch degrades into
visible artefacts while a mistimed read returns plausible-looking wrong data.

### Timing assumptions that were changed

* **Playfield reads use `rd_pre = 0`** (the controller's documented "video read"
  fast path, no precharge-all before the ACTIVATE). CPU and motion-object reads
  keep `rd_pre = 1`, exactly as the Pocket ships them. Rationale: a wrong-row
  serve on a playfield read is one wrong tile row for one frame; on a CPU read
  it is a wrong *instruction*, which is why the Pocket added the armor in the
  first place (v39/v42). This buys back ~4 clocks per playfield fetch.
* **Playfield and motion objects arbitrate round-robin** rather than the
  Pocket's strict PF-over-MO (which lived on the CRAM chain, where MO was not a
  client at all). Motion objects have hard per-line deadlines; the playfield
  prefetches cells ahead and tolerates sharing.
* Nothing inside `sdram_simple` was modified. Refresh interval, tRCD/tRP/tRFC
  waits and the CL2 mode word are as validated on the Pocket.

### Rough budget

One scanline is 456 pixel clocks = 2280 SDRAM clocks. A playfield line needs
~42 tile-row fetches; an unarmored fetch is ~10 clocks, so ~420 clocks, about
18% of the line. The remaining ~82% is what the two CPUs and the motion-object
engine already share on the Pocket. The 64 KB per-CPU hot-code shadows inside
`escape_core` keep most instruction fetches off SDRAM entirely, which is why
that budget closes at all. **This is an arithmetic estimate, not a measurement.**

And it starts from a bus that is *already* tight: the Pocket build's own known
issues list "dense sprite crowds can drop scanlines (bandwidth work in
progress)" — with the playfield on a separate chip. Adding the playfield to
the same bus can only make that worse, not better. Expect the MiSTer build to
show the Pocket's sprite-bandwidth artefacts sooner and more often, and treat
that as the first thing to measure rather than a surprise.

---

## Video

456 × 262 total, 336 × 240 active, 7.159091 MHz pixel clock → 59.9227 Hz. Same
geometry as the Pocket build.

`arcade_video` edge-detects `CE_PIXEL`, so `CLK_VIDEO` runs at the 35.8 MHz
SDRAM clock with one enable pulse per 7.159 MHz pixel, derived from a toggle in
the pixel domain (the two clocks are 5:1 PLL siblings, so it is a timed path).

The Pocket emitted one-clock HS/VS pulses, which the APF scaler accepts. MiSTer's
scandoubler and `ascal` need real widths, so this port generates a 32-clock
HSync and a 3-line VSync placed in the front porch. **These positions are a
reasonable guess, not transcribed from the schematic** — if the picture is
off-centre on HDMI, that is the first thing to adjust
(`HS_START`/`HS_END`/`VS_START`/`VS_END` in `rtl/escape_mister.v`).

---

## Controls

Per `docs/CONTROLS.md`, the cabinet has a 2-axis **hall-effect analog** stick per
player (no switches) read through an ADC0809, plus three buttons on CD11–CD8:
Jump (D8), Fire (D9), Duck (D11).

| MiSTer | Game |
|--------|------|
| D-pad / left analog stick | Hall-effect joystick |
| Button 1 | Jump |
| Button 2 | Fire |
| Button 3 | Duck |
| Button 4 | **Bomb** (asserts Jump + Fire + Duck together) |
| Start | Start / self-test step-continue |
| Coin | Coin |

`hall_stick` turns the d-pad into absolute stick deflections with a ~4.6 ms
slew; a deflected analog stick takes priority automatically. hps_io's analog
axes are signed with 0x00 centred, so the top level flips the sign bit to the
unsigned 0x80-centred form `hall_stick` wants.

**The three-simultaneous-buttons history.** The in-game smart bomb is
Jump+Fire+Duck pressed together. On the Pocket this was repeatedly mis-diagnosed:
a probe concluded the macro belonged on bit 8, but bit 8 is the L shoulder
button, so the "presses" in that test were L being mislabelled. The L macro then
had to be removed when L became the debug-overlay toggle — at which point every
overlay toggle injected a phantom Jump+Fire+Duck — and the bomb was orphaned
("bomb does nothing"). The Pocket build settled on the X face button (APF bit 6,
no other binding). MiSTer has no such conflict: Button 4 is a dedicated,
unshared bomb macro. Keyboard: left shift.

Keyboard also maps arrows, left ctrl (Fire), left alt (Jump), space (Duck),
1/2 (Start), 5/6 (Coin).

## OSD options

Aspect ratio, scandoubler FX, **Service Mode** (the cabinet's self-test lever)
and **Skip Self-Test** (forces the boot's tests-passed branch). The game has no
DIP switches — the real cabinet is configured through its 93C46 EEPROM — so
there is no `<switches>` block in the `.mra` and no `ioctl_index == 254` path.

**EEPROM contents are not persisted.** `escape_core` holds the EEPROM in BRAM
and it resets with the core, so bookkeeping and high scores do not survive a
power cycle. Save states are explicitly out of scope for this port.

---

## What is verified / what is not

### Verified here

* **The ROM path, end to end and byte-exact.** The `.mra` was assembled with the
  real `mra` tool against a real `eprom.zip`; the loader's invert + planar→chunky
  transform was replayed over the output in Python; the result matched
  `support/build_rom.py`'s CRC-verified image across all 2,228,224 bytes.
* **The MRA conventions** (`map="01"` byte lane, index numbering, SD-card paths,
  file naming) against MiSTer's firmware source and the reference core's shipped
  MRAs — see *Sources*.
* **Which clock configuration the Pocket actually ships** — 35.795455 MHz, 5× CPU.
  Several comments in `core_top.v`, `sdram_simple.v` and the project brief say
  "85.909 MHz, 12:1". That is **stale**; the PLL IP has said 5× since commit
  *"v22: SDRAM 42.95 → 35.8 MHz"*. Read the PLL, not the comments.

### Not verified — nobody has run this on a DE10-Nano

* That it boots, draws, or makes a sound on real hardware.
* SDRAM bandwidth with the playfield added (see above) — the estimate is
  arithmetic only.
* SDRAM read capture on the DE10-Nano's SDRAM module. The clock/phase pair is
  the Pocket's, but it is a different board and a different memory module.
* HSync/VSync placement, and therefore HDMI centring and 15 kHz output.
* Any control mapping. None of it has been pressed.
* Audio levels through the MiSTer audio path.

### If it does not work, look here first

1. **Playfield/sprite corruption or tearing** — SDRAM starvation from the added
   playfield client. Try dropping the motion-object armor to `rd_pre = 0` as
   well, or reducing playfield prefetch depth.
2. **Black screen / no sync on HDMI** — sync pulse placement, or `CE_PIXEL`
   generation. Check `direct_video` and the scandoubler path first.
3. **Boot loop** — the watchdog / freeze-rescue path is active (it reboots the
   machine on a watchdog timeout, a dead extra CPU, or a wedged inter-CPU
   mailbox). A loop means one of those is firing, which usually means the CPUs
   are being starved of SDRAM or fed bad data.

---

## Sources

* MRA format: <https://mister-devel.github.io/MkDocs_MiSTer/developer/mra/>
* The authoritative parser: `MiSTer-devel/Main_MiSTer`,
  `support/arcade/mra_loader.cpp`
* Offline assembler: <https://github.com/sebdel/mra-tools-c>
* Reference core and `sys/` framework:
  `third_party/Arcade-Atari-system1_MiSTer` (GPL), especially
  `releases/*.mra` and `Arcade-atarisys1.sv`
* Loader-side `ROMREGION_INVERT` precedent:
  `MiSTer-devel/Arcade-AtariSystem2_MiSTer`, `rtl/rom/sys2_rom_loader.sv`
* ROM contents: `reference/eprom.cpp` (MAME `ROM_START(eprom)`) — CRCs were
  taken from there, never invented.

> Documentation-quality note, in the spirit of `docs/LESSONS.md`: the "85.909 MHz
> / 12:1" figure appears in the brief, in `core_top.v` comments, in
> `sdram_simple.v`'s header, and in a `psram` instantiation parameter. All four
> are wrong. The PLL IP file is the only thing that was right. When a number
> matters, read the source that generates it.
