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

### Bandwidth budget, and why it is the headline risk

One scanline is 456 pixel clocks = **2280 SDRAM clocks** at 35.795455 MHz.

Cost of one read, counted out of `sdram_simple`'s FSM (not estimated):

| | states | + handshake teardown | total |
|---|---|---|---|
| Armored (`rd_pre=1`, CPU and MO) | 15 | ~3 | **~18 clocks** |
| Video fast path (`rd_pre=0`, PF) | 11 | ~3 | **~14 clocks** |

Structural ceilings per line:

| Client | Fetches/line (max) | Clocks | Share of the line |
|---|---|---|---|
| Playfield (new on this bus) | 42 | 588 | 26% |
| Motion objects, **BUILD 104 4-channel** | 57 | 1026 | **45%** |
| **Video total** | | **1614** | **71%** |

**BUILD 104 changed this materially, and not in our favour.** MOCHAN-4's own
note says per-tile cost is `max(8 blit, round_trip/NCH)`: at NCH=2 the engine
was fetch-concurrency-bound at 15.5 pixel clocks per tile, so it could ask for
at most ~29 fetches per line; at NCH=4 it is blit-bound at 8, so its ceiling
roughly **doubles to ~57**. On the Pocket that is affordable — the playfield is
on the PSRAM chip, so SDRAM video load goes from ~23% to ~45% and the CPUs keep
the rest. Here the playfield is on the *same* bus, so the two changes compound:
video's worst-case demand goes from the Pocket's ~23% to **~71%**, leaving under
30% of the line for two 68000s.

**So: does the arbiter hold? Honestly — in the average case yes, at the peak
no.** The ~6%/frame average rise BUILD 104 measured is absorbable. A dense
sprite line is not: the two video clients can now request more than the bus can
deliver, and the CPUs outrank both, so what gets dropped is sprite and tile
fetches. The Pocket already lists "dense sprite crowds can drop scanlines" as a
known issue *at a third of this pressure*. **Expect that symptom here, earlier
and more often.** It is the first thing to look for on hardware.

What is genuinely protective in the current design:

* CPUs strictly outrank both video clients, so starvation degrades the picture
  rather than the machine (a starved CPU is a watchdog reboot; a starved fetch
  is a wrong tile row for one frame).
* PF and MO alternate round-robin, so neither can lock the other out — the
  Pocket's strict PF-over-MO ordering lived on the CRAM chain where MO was not
  a client at all, and copying it here would have starved sprites outright.
* The 64 KB per-CPU hot-code shadows keep most instruction fetches off SDRAM
  entirely, which is the only reason ~30% is a workable CPU budget.

Levers, cheapest first, if the artefacts show up:

1. **Drop the motion-object armor** — `rd_pre_q <= 1'b0` in the MO grant arm of
   `rtl/escape_mister.v`. Saves 4 clocks × 57 = **228 clocks/line, 10% of the
   bus**. The armor exists because of the v39/v42 *wrong-row* bug, which was
   diagnosed on CPU fetches where a wrong word is a wrong instruction; on MO
   graphics a wrong row is one bad sprite row for one frame and self-heals.
   Deliberately **not** done in this first build: it diverges from the Pocket
   for a benefit nobody has measured, and this project's history is unkind to
   unmeasured changes. It is a one-line experiment with an obvious A/B.
2. Reduce playfield prefetch depth (`pfq_count` ceiling) to trade latency
   tolerance for bus time.
3. Spend the 168 spare M10K blocks on a tile-row cache. Playfield and motion
   objects read the *same* 1 MB graphics region, and a scanline re-reads
   neighbouring rows heavily, so this is the structurally right fix and the one
   the Pocket cannot afford.
4. Raise the SDRAM clock — **blocked**, see the CL2 capture-phase note above.
   Do not reach for this one first just because it looks like the big lever.

**None of the four levers is applied in this build.** Levers 1 and 2 are single
lines and would probably help, but each diverges from the Pocket for a benefit
nobody has measured, and this project's history is specifically unkind to
unmeasured changes — that is why they are written down with their locations
instead of silently applied. Lever 1 in particular has an obvious A/B: flip it,
reflash, look at the same dense scene.

**The falsifiable prediction**, so first flash is a test and not just a vibe:

> Dense sprite crowds will drop scanlines *sooner and more often here than on
> the Pocket* — the same symptom already on the Pocket's known-issues list, at
> roughly three times the bus pressure. Because the CPUs strictly outrank both
> video clients, this should degrade the **picture** (missing or stale sprite
> rows, tile rows repeating from the previous line) and **not** the machine: no
> boot loops, no wrong behaviour, no audio disruption. If instead you see boot
> loops or the game misbehaving, the cause is *not* bandwidth and this analysis
> is wrong — look at SDRAM read integrity instead.

All of the above is arithmetic from the RTL, not measurement. Nobody has run
this on hardware.

---

## Resources and timing

Quartus 18.1 Lite, 5CSEBA6U23I7, whole design including the MiSTer framework:

| Resource | Used | Available | % |
|---|---|---|---|
| Logic (ALMs) | 17,954 | 41,910 | 43% |
| Registers | 20,698 | — | — |
| Block memory (M10K) | 385 | 553 | 70% |
| Block memory bits | 2,942,544 | 5,662,720 | 52% |
| DSP blocks | 76 | 112 | 68% |
| PLLs | 3 | 6 | 50% |
| Pins | 145 | 314 | 46% |

**Headroom versus the Pocket.** On the Pocket's 5CEBA4 this design sits at the
308-M10K ceiling with nothing to spare. Here it uses 385 of 553, leaving **168
free M10K blocks (~1.68 Mbit)** plus ~24,000 spare ALMs. That is enough to
consider things the Pocket cannot afford — a larger slice of graphics in BRAM
to take load off the SDRAM bus being the obvious candidate, since bandwidth is
this port's weak point. Note the DSP figure: 76 blocks, more than the Pocket
device even has (66), because the MiSTer scaler and `ascal` use multipliers the
APF path does not.

### Timing: two real bugs, found and fixed

The first CI build reported **success while carrying -5.538 ns of setup and
-10.922 ns of hold slack** on the 35.8 MHz SDRAM domain. Both the violation and
the fact that it got through are worth recording.

**The gate was broken.** The workflow's "fail on negative slack" step grepped
for `^; *-[0-9]` in the STA report. The slack lives in the *second* column of
the Setup/Hold Summary tables, so the pattern matched nothing and the step
passed vacuously — a check that could never fire, reporting success. It is now
`src/mister/check_slack.py`, which parses the table columns, covers setup, hold,
recovery, removal and minimum pulse width, and **fails if an expected table is
missing** rather than reporting a clean bill of health for a table it never
found. It was verified by running it against the failing report, where it
correctly flags both violations.

> This is the `docs/LESSONS.md` pattern again, in a new place: a measurement
> that cannot fail is worse than no measurement, because it manufactures
> confidence. Any new gate should be tested against a known-bad input before it
> is trusted.

**The hold violation was self-inflicted.** `escape.sdc` carried
`set_multicycle_path -setup -end 2` from `SDRAM_CLK` to the controller clock,
copied from the reference core. A setup multicycle with `-end` also pushes the
*hold* check out by one destination period, so the analyser demanded that SDRAM
read data still be in flight 27.9 ns after launch. Adding the matching
`set_multicycle_path -hold -end 1` puts the hold check back on the edge it
belongs to. (The reference core omits it too, so it likely carries the same
latent violation.)

---

## Tracking the Pocket branch (BUILD 103-105)

This port is rebased on `tas-atomic` at **BUILD 105**. Three changes landed
after the branch point and all three touch the MiSTer glue.

**BUILD 103 - EEPROM persistence (`rtl/ee_save.vhd`).** Not wired here.
`ee_save.vhd` talks to the APF bridge and Analogue data slots directly
(`bridge_addr`, `dataslot_requestread_ack`), so it is Pocket-only; it is not in
`src/mister/files.qip`. `escape_core`'s new `ee_saddr` / `ee_sdin` / `ee_swe`
inputs all carry defaults and its `ee_sq` / `ee_wrpulse` outputs are left open,
so the core compiles unchanged and the EEPROM behaves exactly as it did before
BUILD 103 — **in-session only, high scores and operator settings do not survive
a power cycle on MiSTer.** The MiSTer-native route is an
`<nvram index="4" size="512"/>` element in the `.mra` plus the matching hps_io
index-4 wiring; that is a small, well-trodden job, but it is new scope and save
functionality was explicitly deferred for this port.

*On the MLAB attributes:* `ee_save.vhd`'s two staging buffers carry
`attribute ramstyle ... "MLAB"` because the Pocket has zero spare M10K. This
build has 168 spare blocks so the attribute is unnecessary here — but since the
file is not compiled into the MiSTer project at all, it costs nothing, and
forking a shared file to remove a no-op would buy nothing and add a permanent
divergence to maintain. Left alone deliberately.

**BUILD 104 - `mo-depth`, 4-channel fetch + 3-deep prefetch queue.**
`escape_mob.v`'s fetch interface changed from an A/B ping-pong to four packed
channels (`gfx_req[3:0]`, `gfx_addr[95:0]`, `gfx_done[3:0]`, `gfx_data[127:0]`).
The glue here follows, and — importantly — also reproduces core_top's
**registered arbitration pre-decode** rather than widening the grant condition.
That pre-decode (`mo_pend_q` / `mo_nch_q` / `mo_naddr_q`) presents the grant a
single flop bit where four channels would otherwise put an XOR/OR tree in front
of the eight-term AND that also gates both CPUs. The playfield client got the
same treatment for the same reason. On the Pocket that was an optimisation; on
MiSTer the first build *missed setup on this exact clock domain*, so keeping
combinational depth off the shared grant is a timing requirement here.

The bandwidth consequence is analysed above under
[Bandwidth budget](#bandwidth-budget-and-why-it-is-the-headline-risk) — short
version: MO's per-line ceiling roughly doubles, and combined with the playfield
being on the same bus, worst-case video demand goes from the Pocket's ~23% of a
scanline to ~71%. **The arbiter holds on average and not at the peak.**

**BUILD 105 - `gfx-artifacts`, the `apply_stain` second pass.** Ported. Special
(MPR2) sprites now occupy the line buffer with a flag instead of being dropped,
and `disp_stain_s` / `disp_stain_e` drive a one-flip-flop automaton along the
scanline that ORs `0x400` into the colour-RAM index. Colour RAM bit 10 is
therefore live. **Nothing in this port's loader or memory map assumed the top
half of colour RAM was unused** — `color_vaddr` has been 11 bits wide since the
first commit and `escape_core`'s colour RAM is the full 2048 entries — so the
only change needed was the OR into the pen. The line tag narrowing to `ly[7:0]`
is entirely inside `escape_mob.v` and needs nothing from the glue.

**PSRAM / `CLOCK_SPEED`: untouched, and unreachable from here.** MiSTer does not
use the PSRAM path at all — `third_party/analogue-pocket-utils/psram.sv` is not
in `src/mister/files.qip`, there is no `psram` instance in the MiSTer hierarchy,
and the DE10-Nano has no such device. The held one-variable experiment on the
Pocket side is unaffected by anything in this port.

### Can the fastpath come back on this device?

**Yes — it is not structurally Pocket-only.** Nothing about the DE10-Nano
prevents it; the blocker is the shape of the crossing, and the same shape exists
on the Pocket.

The correct re-enable moves the *comparison* rather than the address:

* Keep a registered, one-CPU-clock-stale copy of `fast_v_addr` for the **issue**
  path only. Staleness there is harmless — the worst case is a speculative read
  of an address the CPU has already moved past, and ROM is read-only.
* Cross `fpv_tag` and `fpv_valid` the other way, into the CPU clock domain, and
  compute `fast_v_ready` **there**, combinationally against the *live*
  `fast_v_addr`. Those two signals change only at grant and completion, so their
  crossing is slow and easy to time.

That keeps the invariant the design depends on — "ready means this data is for
the address you are asking for *right now*" — while removing the deep cone from
the timed cross-domain path. It is maybe thirty lines. It is also new logic in
the most safety-critical path in the machine, so it wants a bench and a
hardware A/B, not a late-session edit.

Worth noting for whoever picks this up: the same cone exists on the Pocket at
the same 27.939 ns budget on *slower* silicon (5CEBA4 speed grade 8 versus this
board's grade 7), and the Pocket's CI has **no timing gate at all** — it
compiles, bit-reverses and uploads. So the Pocket build may well be carrying
this violation too, unmeasured. `src/mister/check_slack.py` is not
MiSTer-specific and can be pointed at `src/fpga/output_files/ap_core.sta.rpt`
as-is.

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

### Top three things most likely broken on first flash

Ordered by likelihood, with what to actually look at rather than which
subsystem to suspect.

**1. Sprite and tile rows dropping out in busy scenes** — the bandwidth
prediction above. *Where to look:* play past the attract mode into a crowded
level and watch sprites specifically, not the whole screen. The signature is
sprite rows that vanish or repeat the previous line's content, worst on the
right-hand side of the screen (the deficit accumulates rightward as a line runs
out of fetch slots), and worse the more robots are on screen. The playfield may
show the same thing as horizontal bands of stale tile rows. *What it is not:*
if the machine boot-loops, misbehaves, or the sound breaks up, it is not this.
*Cheapest response:* lever 1 in the bandwidth section — one line, obvious A/B.

**2. No picture, or a picture the scaler will not lock to** — sync generation
is the least-transcribed part of this port. The Pocket emitted one-clock HS/VS
pulses because the APF scaler tolerates them; MiSTer's scandoubler and `ascal`
need real widths, so this port invents a 32-clock HSync and a 3-line VSync
placed in the front porch. **Those positions are a reasonable guess, not
transcribed from the SP-332 schematic.** *Where to look:* try `direct_video`
first, and try the analog/VGA output as well as HDMI — if one works and the
other does not, it is sync placement, not the core. Adjust `HS_START` /
`HS_END` / `VS_START` / `VS_END` in `rtl/escape_mister.v`. A picture that is
present but off-centre or shifted is the same cause and is cosmetic.

**3. Nothing loads, or the machine sits at a black screen after the ROM
download** — the loader is new code on this platform even though its *output*
is byte-verified. *Where to look:* the LED_USER activity during load, then
whether the picture ever changes from black. The ROM contents are proven
correct offline, so a failure here is the *delivery*, not the data: most likely
`ioctl_wait` backpressure (the writer accepts three bytes of slack by
construction; a slower or faster HPS transfer than assumed would break that) or
the SDRAM read-capture phase on a DE10-Nano SDRAM module that differs from the
Pocket's part. The core holds itself in reset until its own SDRAM self-check
passes, so a permanent black screen means that check is failing, which points
at read capture rather than at the download.

Two things that are *unlikely* to be the problem, so as not to waste time on
them: the ROM mapping (verified byte-exact against a CRC-verified image) and
the button/stick mapping (untested, but a wrong mapping produces a game that
responds oddly, not one that fails to start).

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
