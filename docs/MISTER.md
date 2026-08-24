# MiSTer (DE10-Nano) port

A second front end for the same machine. `src/mister/` holds a MiSTer top level
that instantiates **the identical RTL the Pocket build uses** — `escape_core`,
`escape_mob`, `escape_prio`, `hall_stick`, `sdram_simple` — with MiSTer-shaped
glue around it. Nothing in the machine is forked; if you fix a bug in
`src/fpga/core/rtl/`, both platforms get it.

> **Status: compiles clean for the DE10-Nano — non-negative setup and hold
> slack on every analysed clock — and has never been run on hardware.**
> Rebased on `tas-atomic` at BUILD 105. Read
> [What is verified / what is not](#what-is-verified--what-is-not) before you
> assume anything works, and
> [Top three things most likely broken on first flash](#top-three-things-most-likely-broken-on-first-flash)
> before you debug it.

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
  **UNEXERCISED UNTIL NOW — read this before the next flash.** Every client on
  the Pocket uses `rd_pre = 1` (all four call sites in `core_top.v`), and this
  port's only `rd_pre = 0` client is the playfield, which until PFRESET-107
  never issued a single fetch. So `sdram_simple`'s no-precharge arm has **never
  executed on any hardware, on either platform**. It now runs ~13 800 times a
  frame. In principle it is safe — every access ends with auto-precharge (A10=1
  on the second beat), so no row should be left open — but v39/v42 added the
  armor because a wrong-row serve was *empirically* observed, which means
  something does leave a row open. **If the playfield comes back textured but
  speckled with individually wrong tile rows, scattered and NOT correlated with
  scene business, change this one line in `rtl/escape_mister.v` and rebuild:**
  `rd_pre_q <= 1'b0;` → `rd_pre_q <= 1'b1;` in the PF grant arm. That costs
  ~4 clocks per playfield fetch (~+10% of a scanline at 57 fetches/line) and
  moves the risk back onto the bandwidth budget, which is the trade being made.
* **Playfield and motion objects arbitrate round-robin** rather than the
  Pocket's strict PF-over-MO (which lived on the CRAM chain, where MO was not a
  client at all). Motion objects have hard per-line deadlines; the playfield
  prefetches cells ahead and tolerates sharing.
* **The refresh interval was out of JEDEC spec and is now fixed (REFRESH-107).**
  This was previously documented here as "nothing inside `sdram_simple` was
  modified", on the strength of a comment in that file reading
  `250 = 2.9us @ 85.909MHz`. That comment referred to a clock this design has
  not used in a long time. The SDRAM domain is 35.795455 MHz on **both**
  platforms, so the real numbers were:

  ```
  interval          250 clk / 35.795455 MHz = 6.984 us
  SDSCHED-88 defer + 48 clk                 = 1.341 us
  worst case                                = 8.325 us
  MT48LC16M16A2 requirement                 = 7.8125 us     -> 6.6% OVER
  ```

  This is the same class of bug the Pocket side found and fixed the same week,
  where it was silently corrupting graphics data. It matters **more** here: the
  deferral only engages under read pressure, and this platform has no PSRAM, so
  the playfield graphics client shares this bus too — and after PFRESET-107 it
  actually uses it. The interval is now `224` (6.258 us); `224 + 48 = 7.599 us`,
  in spec with ~3% margin, with the bounded deferral (which the zero-wait CPU
  fastpath was tuned against) left intact. Average interval refreshes all 8192
  rows in 51.3 ms against the 64 ms `tREF` window.

  **Reconcile deliberately on merge:** the parent project's `sdram-sched` branch
  fixed the same violation by *deleting* the deferral rather than shortening the
  interval. Two platforms must not drift apart here again.
* tRCD/tRP/tRFC waits and the CL2 mode word are otherwise unchanged from the
  Pocket.

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

Quartus 18.1 Lite, 5CSEBA6U23I7, **BUILD 105 rebase**, whole design including
the MiSTer framework:

| Resource | Used | Available | % |
|---|---|---|---|
| Logic (ALMs) | 18,770 | 41,910 | 45% |
| Registers | 21,122 | — | — |
| Block memory (M10K) | 385 | 553 | 70% |
| Block memory bits | 2,942,544 | 5,662,720 | 52% |
| DSP blocks | 76 | 112 | 68% |
| PLLs | 3 | 6 | 50% |

(BUILD 102 was 17,954 ALMs; the 4-channel motion-object engine and the stain
pass cost about 800 ALMs and no extra M10K.)

**Timing — every analysed clock, Slow 1100 mV 100 °C model. Total negative
slack is 0.000 on all of them.**

| Clock | Setup slack | Hold slack |
|---|---|---|
| `general[0]` — 7.159091 MHz CPU + pixel | **+16.042 ns** | +0.259 ns |
| `general[1]` — 35.795455 MHz SDRAM controller | **+14.785 ns** | +0.255 ns |
| `SDRAM_CLK` — 35.795455 MHz @ +90° | +3.434 ns | +17.450 ns |
| `pll_hdmi` — 148.5 MHz (framework) | +0.744 ns | +0.247 ns |
| `pll_audio` — 24.576 MHz (framework) | +14.401 ns | +0.245 ns |
| `FPGA_CLK1_50` | +7.541 ns | +0.406 ns |
| `FPGA_CLK2_50` | +13.462 ns | +0.404 ns |
| `spi_sck` | +6.351 ns | +0.371 ns |

Fmax on the two core clocks: **26.24 MHz** on the 7.159091 MHz CPU/pixel domain
(3.7× headroom) and **76.02 MHz** on the 35.795455 MHz SDRAM domain (2.1×
headroom). The design is not close to its logic limits on this device; its
limit is SDRAM *bandwidth*, not clock speed — and the bandwidth ceiling cannot
be raised by clocking faster, for the CL2 capture reason above.

**These numbers came from a gate that has been proven able to fail.**
`src/mister/check_slack.py` was run against the earlier known-bad report and
correctly named both violations before it was trusted for this one.

**Headroom versus the Pocket.** On the Pocket's 5CEBA4 this design sits at the
308-M10K ceiling with nothing to spare. Here it uses 385 of 553, leaving **168
free M10K blocks (~1.68 Mbit)** plus ~23,000 spare ALMs. That is enough for
things the Pocket cannot afford — a tile-row cache to take load off the SDRAM
bus being the obvious candidate, since bandwidth is this port's weak point.
Note the DSP figure: 76 blocks, more than the Pocket device even has (66),
because the MiSTer scaler and `ascal` use multipliers the APF path does not.

### Timing: one real bug, one broken gate, and a wrong hypothesis

The first CI build reported **success while carrying -5.538 ns of setup and
-10.922 ns of hold slack** on the 35.8 MHz SDRAM domain. Three things are worth
recording: why it got through, what actually caused it, and what nearly got
shipped as a "fix".

**The gate was broken.** The workflow's "fail on negative slack" step grepped
for `^; *-[0-9]` in the STA report. The slack lives in the *second* column of
the Setup/Hold Summary tables, so the pattern matched nothing and the step
passed vacuously — a check that could never fire, reporting success. It is now
`src/mister/check_slack.py`, which parses the table columns, covers setup, hold,
recovery, removal and minimum pulse width, and **fails if an expected table is
missing** rather than reporting a clean bill of health for a table it never
found. It was verified against the failing report, where it correctly names
both violations.

> This is the `docs/LESSONS.md` pattern in a new place: a measurement that
> cannot fail is worse than no measurement, because it manufactures confidence.
> Test every new gate against a known-bad input before trusting it.

**The cause was one line of SDC.** `escape.sdc` carried
`set_multicycle_path -setup -end 2` from `SDRAM_CLK` to the controller clock,
copied from the reference core. A setup multicycle with `-end` also pushes the
*hold* check out by one destination period, so the analyser demanded that SDRAM
read data still be in flight 27.9 ns after launch. That produced the -10.922 ns
hold failure directly — and the -5.538 ns setup failure was **collateral
damage**: the fitter padded routing delay trying to satisfy an impossible hold
requirement, and that padding broke setup elsewhere in the same domain. Adding
the matching `set_multicycle_path -hold -end 1` fixed both at once:

| 35.8 MHz SDRAM domain | before | after |
|---|---|---|
| Setup slack | **-5.538 ns** | **+15.133 ns** |
| Hold slack | **-10.922 ns** | **+0.253 ns** |

(The reference core omits the hold multicycle too, so it likely carries the
same latent violation.)

**The wrong hypothesis, recorded because it was nearly shipped.** Before the
detailed report existed, the setup failure was attributed by elimination to the
zero-wait fastpath's address cone: `escape_core` exports `fast_v_addr`
*combinationally* from the live CPU bus, that cone crosses 7.16 → 35.8 MHz, and
it was the only transfer into that domain with a deep combinational source. The
argument was structurally sound, and a build shipped briefly with
`FASTPATH_EN=0` on the strength of it. The measured path says otherwise:

```
From: escape_core|TG68K:vcpu|TG68KdotC_Kernel:cpu1|RDindex_A[2]
To:   escape_mister|fpv_spec_s
Setup slack: +15.537 ns   (budget 27.939 ns)
```

The cone was never close to failing. `FASTPATH_EN` is back to **1**, and the
zero-wait path is fully enabled on MiSTer. Read the timing report, not the
hypothesis — which is precisely the discipline this project's history is built
on, applied to its own author.

**Where the critical path actually is now:** the worst setup path in the entire
design is inside the MiSTer framework's `ascal` HDMI scaler
(`ascal|o_hcpt[5]` → `ascal|o_vcpt_pre3[5]`, +0.527 ns), not in this core. The
game logic has an order of magnitude more margin than the framework it sits in.

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

### A note for whoever checks the Pocket build

The fastpath cone that was wrongly blamed here exists on the Pocket too, at the
same 27.939 ns budget, on *slower* silicon (5CEBA4 speed grade 8 versus this
board's grade 7). It measures +15.537 ns here, so it is very unlikely to be a
problem there either.

The SDC bug is a different matter. The Pocket's CI has **no timing gate at
all** — it compiles, bit-reverses and uploads — so if `src/fpga/` ever grows the
same setup-multicycle-without-hold-multicycle pattern, nothing would catch it.
`src/mister/check_slack.py` is not MiSTer-specific and can be pointed straight
at `src/fpga/output_files/ap_core.sta.rpt`.

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

* **It compiles for the DE10-Nano with non-negative slack on every analysed
  clock**, checked by a gate that has been **proven able to fail** (see
  "Timing" above — `check_slack.py` was run against the known-bad report and
  correctly named both violations before being trusted).
* **That the playfield graphics channel is served at all** —
  `./sim/run_mister_pf_tb.sh`. This drives the **real** `rtl/escape_mister.v`
  (only the VHDL machine is stubbed, and that stub is regenerated from
  `escape_core.vhd`'s entity on every run so it cannot drift) against a
  behavioural SDRAM chip, through the exact hardware sequence: power-on → ROM
  download with the core held in reset → release → one measured frame. It counts
  playfield grants and completions.

  **Proven able to fail, both ways, by A/B:**

  | | fetches granted / completed in one frame |
  |---|---|
  | BUILD 105 as flashed | **0 / 0**, `inflA=1 inflB=1`, `vg_req == vg_req_last` |
  | with PFRESET-107 | **13 794 / 13 794** |
  | second `.mra` load, owner-clear reverted | **0 / 0**, `pf_owner` stuck at 1 |
  | second `.mra` load, fixed | **13 794 / 13 794** |

  13 794 is exactly 57 cells × 242 lines, i.e. the pipeline's full free-running
  enqueue rate — not a threshold that was tuned to pass. The bench also checks
  **its own SDRAM model** by requiring the core's two power-on readback probes
  to succeed, so a mis-calibrated model latency fails the run rather than
  silently invalidating it. The phase-2 case synchronises to `pf_owner == 1`
  before asserting `ioctl_download`, because an unsynchronised version passes by
  luck roughly two runs in three.

  What this does **not** prove: that the pixels coming back are the right
  pixels. The machine is stubbed and the SDRAM is behavioural. It proves the
  channel is alive, which is the thing that was broken.
* **The ROM path, end to end and byte-exact.** The `.mra` was assembled with the
  real `sebdel/mra-tools-c` tool against a real `eprom.zip`; the loader's
  invert + planar→chunky transform was replayed over the output in Python; the
  result matched `support/build_rom.py`'s CRC-verified image across all
  2,228,224 bytes. Re-verified after the BUILD 105 rebase.
* **The Verilog→VHDL boundary**, mechanically: `check_ports.py` confirms all 57
  connected ports exist on the `escape_core` entity and that no mandatory input
  is unconnected. Also proven able to fail (renaming `.vblank_in` makes it
  name both halves of the mistake).
* **The MRA conventions** (`map="01"` byte lane, index numbering, SD-card paths,
  file naming) against MiSTer's firmware source and the reference core's shipped
  MRAs — see *Sources*.
* **Which clock configuration the Pocket actually ships** — 35.795455 MHz, 5× CPU.
  Several comments in `core_top.v`, `sdram_simple.v` and the original porting
  brief say "85.909 MHz, 12:1". That is **stale**; the PLL IP has said 5× since
  commit *"v22: SDRAM 42.95 → 35.8 MHz"*. Read the PLL, not the comments.

### Not verified — the PFRESET-107 / REFRESH-107 build has NOT been on hardware

BUILD 105 *has* been on a DE10-Nano (see "FIRST FLASH RESULT"): it boots, runs
attract mode, takes coins, plays level 1, and renders motion objects,
alphanumerics and the HUD correctly. Everything in this section is about the
build that fixes the playfield, which **nobody has flashed**.

* **That the playfield actually renders on hardware.** What is proven is that
  the channel now services ~13 800 fetches per frame in simulation where it
  previously serviced zero. Simulation used a *stub* machine and a *behavioural*
  SDRAM: it proves the fetches are issued, granted and completed, and it does
  **not** prove the returned pixels are the right pixels or that the picture is
  correct. The next capture is what confirms that.
* **`sdram_simple`'s `rd_pre = 0` arm**, which the playfield is the only user of
  and which has therefore never run on any hardware on either platform. See the
  "Timing assumptions that were changed" note — this is now the top item to
  watch, with a one-line A/B if it misbehaves.
* **REFRESH-107 on hardware.** The arithmetic is unambiguous and the change is a
  constant, but no capture has been taken with it.
* SDRAM bandwidth with the playfield added and the BUILD 104 4-channel motion
  object engine — the ~71%-of-a-line figure is arithmetic from `sdram_simple`'s
  FSM, not measurement. **The budget has still never been exercised**: until
  PFRESET-107 the playfield client consumed exactly zero bandwidth, so BUILD
  105's clean motion objects say nothing about it. This remains the most likely
  thing to be visibly wrong on the next flash.
* SDRAM read capture on the DE10-Nano's SDRAM module. The clock/phase pair is
  the Pocket's proven one, but it is a different board and a different part.
* HSync/VSync placement, and therefore HDMI centring and 15 kHz output. The
  positions are invented, not transcribed from the schematic.
* Any control mapping. None of it has been pressed.
* Audio levels through the MiSTer audio path.
* EEPROM persistence — deliberately not wired (see BUILD 103 above); high
  scores do not survive a power cycle on MiSTer.

### FIRST FLASH RESULT (BUILD 105 on real hardware) — and what it actually was

BUILD 105 booted, ran attract mode, accepted coins and played level 1. Motion
objects and alphanumerics were pixel-perfect. **The playfield was a flat fill.**

**None of the three predictions below was the cause. The bandwidth prediction,
which this document led with, was wrong.** Recorded here in full because the
elimination argument that produced it was sound and still wrong — the project's
recurring lesson.

**The measurement that killed the bandwidth hypothesis first.** Bandwidth
starvation degrades *with load*; a dead client does not. Five fixed background
patches were sampled across 22 frames of the owner's 77.9 s capture:

| | background patch, median | scene complexity across the run |
|---|---|---|
| MiSTer BUILD 105 | **1 distinct colour**, σ 14.9 | 22 115 → 87 227 distinct colours (3.9×) |
| Pocket BUILD 106 | 1 241 distinct colours, σ 51.3 | 22 727 → 119 073 distinct colours (5.2×) |

The MiSTer playfield is *exactly one colour* per region and stays exactly one
colour while scene complexity moves by 3.9×. That is not starvation. Two further
observations narrowed it to one signal:

* the stairs structure appeared as a **correctly shaped black silhouette** — so
  the tilemap fetch and the per-tile colour attributes were both correct, and
  only the tile *pixels* were constant;
* **motion objects read the same repacked graphics region at the same byte
  addresses** (`escape_mob.v:547` and the PF fetch use the identical
  `0x120000 + code*32 + row*4` formula) and were perfect — which eliminates the
  ROM image, the `.mra`, and the loader's invert/planar→chunky repack outright.

Constant tile pixels with a correct tilemap means `pfring0..3` never got
written, i.e. the playfield graphics channel never completed a fetch.

**Root cause (PFRESET-107).** The playfield fetch pipeline in
`rtl/escape_mister.v` had **no reset**, and the SDRAM arbiter's SDSCHED-75 reset
resync ate its requests:

1. `x_count`/`y_count` and the whole PF pipeline free-run from power-on — they
   are not gated by `core_reset_n`. During the ~2.2 MB ROM download, with the
   machine held in reset, the pipeline reaches active video and issues a fetch
   on channel A and then channel B, setting `inflA` and `inflB`.
2. The arbiter cannot serve them: its entire video tier lives inside the
   `chk_state == 4'd10` steady-state arm, and `chk_state` is pinned at 0 for the
   whole download. `pf_pend_q` is gated by `core_rstn_sd` on top of that.
3. Meanwhile the reset resync runs every clock that `core_rstn_sd` is low and
   does `vg_req_last <= vg_req_s`, **retiring those two pending request edges
   without ever completing them**. That resync is correct for the motion
   objects, because `escape_mob` zeroes its own request toggles and in-flight
   state under reset — the tracker is following a real reset, not eating a real
   request. The playfield channel had no reset, so it was the one client for
   which the resync destroyed work.
4. Reset releases with `inflA = inflB = 1` and `vg_req_last == vg_req_s`. The
   issue side requires `!inflA` / `!inflB`, so it never toggles again and the
   arbiter never sees another pending edge. **Both channels are wedged for the
   rest of the session**, `pfring0..3` keep their power-on zeros, every tile
   decodes to pixel index 0, and the screen shows one flat colour per playfield
   colour attribute — black where that attribute's entry 0 is black.

**Why the Pocket does not show this.** Same resync, same un-reset pipeline — but
`core_top.v`'s CRAM service arm (line ~1470) is **not** gated by `core_rstn_sd`,
where this port's `pf_pend_q` is. On the Pocket a pending PF request is served
as soon as the CRAM chain is free, so the resync only ever rewrites a value that
already matches. Moving the playfield onto the SDRAM arbiter put it behind that
extra gate, and nothing here reset the client to compensate. The divergence was
real, just not the bandwidth one.

**The fix** is to give the playfield channel the same reset the mob gives its
own: while reset is held the request toggles sit at 0, the resync tracks 0, and
release starts both sides in agreement with nothing in flight. Ten lines in the
pixel-domain block.

A second instance of the same bug class was found and fixed alongside it: the
`if (ioctl_download)` teardown dropped `sd_rd_req` but left the client *owner*
flags set, and every grant arm requires `!cpu_owner && !mo_owner && !pf_owner &&
!fpv_owner && !fpe_owner`. Any `ioctl_download` that lands while a read is
outstanding — i.e. every `.mra` load after the first — wedged the **entire** read
arbiter. It was invisible because the first load happens before any client is
active.

**Both are covered by `sim/run_mister_pf_tb.sh`**, which drives the real
`escape_mister.v` through power-on → download-under-reset → release and counts
served fetches. See "Verified here".

### Three things predicted to break on first flash (all wrong — kept for the record)

Ordered by the likelihood assigned *before* the flash, with what to look at.

**1. Sprite and tile rows dropping out in busy scenes** — the bandwidth
prediction. **This did not happen.** *Where to look if it ever does:* play past
the attract mode into a crowded level and watch sprites specifically, not the
whole screen. The signature is sprite rows that vanish or repeat the previous
line's content, worst on the right-hand side of the screen (the deficit
accumulates rightward as a line runs out of fetch slots), and worse the more
robots are on screen. *What it is not:* if the machine boot-loops, misbehaves,
or the sound breaks up, it is not this. *Cheapest response:* lever 1 in the
bandwidth section — one line, obvious A/B. Note that until PFRESET-107 the
playfield client was consuming **zero** bandwidth, so the budget has not yet
been exercised at all: the bandwidth question is still open, not disproved.

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
