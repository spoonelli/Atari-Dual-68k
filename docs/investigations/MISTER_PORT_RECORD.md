# MiSTer (DE10-Nano) port

A second front end for the same machine. `src/mister/` holds a MiSTer top level
that instantiates **the identical RTL the Pocket build uses** — `escape_core`,
`escape_mob`, `escape_prio`, `escape_stain`, `hall_stick`, `sdram_simple` —
with MiSTer-shaped glue around it. Nothing in the machine is forked; if you fix
a bug in `src/fpga/core/rtl/`, both platforms get it.

> **This is the port's investigation record** — kept as written, wrong
> turns included. Current status, architecture and installation:
> [`../MISTER.md`](../MISTER.md).

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

## Controls, credits overlay, audio (MISTER-132)

* **Buttons** (all remappable in the MiSTer "Define buttons" UI): Jump=A,
  Fire=B, Duck=X, Bomb=Y, Start, Coin=Select, **Credits=R**. Start doubles as
  the self-test step/continue key, exactly like the cabinet (schematic: START
  shares the JUMP line; player 2 joins with Jump). Keyboard: arrows,
  LAlt=Jump, LCtrl=Fire, Space=Duck, LShift=Bomb, 1/2=Start, 5/6=Coin.
* **Credits overlay**: the Credits button cycles page 1 → page 2 → off,
  and a ~3.5 s boot splash of page 1 shows the build number after every
  reset (MISTER-134) — the on-device proof of which rbf is running.
  OWNER DIRECTION (2026-08-28): once the overlay stops earning its keep as
  the debug/version display, credits move back to a MENU presentation —
  either CONF_STR submenu pages on a framework build that renders "Pn-"
  text lines, or an OSD-triggered overlay page. Keep the splash until the
  MiSTer port is stable; then revisit.
  (original bullet continues:)
  drawn by the core itself (`escape_credits.v`, bitmap generated by
  `support/gen_credits_overlay.py`). It replaced CONF_STR About/Credits
  submenu pages, which render empty on some framework builds. This file
  stays the canonical, unabridged attribution text.
* **Audio sliders**: Music Volume and Speech Volume in the OSD (8 steps,
  default full). They drive the JSA mixer's `uvol_ym` / `uvol_tms`.
* **Video-tier arbitration**: the playfield has STRICT priority over the MO
  engine on the shared SDRAM (the Pocket serves PF from PSRAM, MiSTer has no
  second RAM). At 131 the round-robin let crowd-scene MO fetch pressure
  (doubled by MOPAIR) push PF past its scanout deadline — red garbage
  patches over the floor. PF-first fixed it; MO absorbs the loss through
  its fetch budget, visible on MOTEL telemetry.

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
* **The refresh interval was out of JEDEC spec, and REFRESH-107's fix was not
  enough either; it is now reconciled to ONE policy (REFRESH-112).**
  This was originally documented here as "nothing inside `sdram_simple` was
  modified", on the strength of a comment in that file reading
  `250 = 2.9us @ 85.909MHz`. That comment referred to a clock this design has
  not used in a long time. The SDRAM domain is 35.795455 MHz on **both**
  platforms — verified from the PLL IP (`src/mister/rtl/pll/pll_0002.v`
  `output_clock_frequency1`), not from a neighbouring comment.

  REFRESH-107 corrected the clock but kept the same **wrong worst-case model**,
  `INTERVAL + DEFER_CAP`, and picked `224` to land at a believed 7.599 us. That
  model silently drops the transaction still in flight when the deferral cap
  expires: `refresh_due` is only consumed from `S_IDLE`, so the FSM must finish
  a precharge-armored `rd_pre` read (15 clocks) and clear the read ack before it
  can refresh. The true worst case is `INTERVAL + DEFER_CAP + 16`, and it is
  **measured**, not derived:

  ```
  policy (interval/defer)   worst case   % of JEDEC budget   verdict
  250 / 48  (original)      314 clk = 8.7721 us   112.28%    FAIL
  224 / 48  (REFRESH-107)   288 clk = 8.0457 us   102.99%    FAIL  <- still over
  250 / 0   (sdram-sched)   266 clk = 7.4311 us    95.12%    pass, thin margin
  160 / 48  (SHIPPING)      224 clk = 6.2578 us    80.10%    PASS
  ```

  Limit: MT48LC16M16A2, 8192 rows / 64 ms = 7.8125 us per row = 279.7 clocks.
  So `224` was never a fix — it was 3% over spec on the platform where the
  playfield **also** shares this bus (after PFRESET-107 it actually uses it),
  which is the worse place to have a silent, temperature-dependent retention
  violation that manifests as graphics corruption rather than a crash.

  The interval is now **160** with the bounded deferral **unchanged at 48** (the
  zero-wait CPU fastpath was tuned against that 48; changing it would force a
  retune). Both are now **module parameters** on `sdram_simple` rather than
  hardcoded literals, defaulting to 160/48, so the two platforms share one
  source of truth and a divergent value has to be stated at the instantiation,
  in the open.

  **Bandwidth cost, measured:** refresh occupancy goes 4.890% (224) -> 6.831%
  (160) of SDRAM bus clocks, **+1.94 percentage points**, taken from the
  lowest-priority client (sprites). That is a real cost on this platform, whose
  bus is busier than the Pocket's because the playfield moved onto it. It is
  still the right trade: losing ~2% of sprite bandwidth beats corrupting the
  memory the sprites are stored in.

  **What the bandwidth cost actually cost, measured (REFRESH-112).** The +1.94
  pp is occupancy, not lost work, so both affected clients were measured rather
  than argued about:

  * **Playfield: zero.** `sim/run_mister_pf_tb.sh` drives the real
    `escape_mister.v` + `sdram_simple.v` through one frame. At `224/48` and at
    `160/48` it grants **and completes 13,794 fetches** — byte-identical. The
    playfield prefetches and tolerates sharing, and it has enough slack to
    absorb the extra refreshes outright.
  * **Sprites: not directly measurable on this branch, but bounded.** No bench
    here puts the MO client on the real arbiter — `tb_mister_pf.v`'s stub drives
    no MO (it reports `motion-object fetches: 0`), and `sim/run_mob_perf.sh`
    never instantiates `sdram_simple` at all; it takes fetch latency as a free
    parameter `GFX_LAT`. So the sprite cost of this change is **not measured**,
    and this document does not claim it is. What `run_mob_perf.sh` does give is
    a sensitivity curve for how much added latency the MO engine can absorb
    (`XSCROLL=50 YSCROLL=157`):

    ```
    GFX_LAT=8    coverage 99.71%   (12078 px dumped, 2 missing)
    GFX_LAT=16   coverage 99.71%   (12078 px dumped, 2 missing)   <- identical
    GFX_LAT=31   coverage 93.51%   (11329 px dumped, 751 missing)
    ```

    Doubling MO fetch latency from 8 to 16 clocks costs **nothing** — the two
    runs agree pixel for pixel — and starvation only appears somewhere between
    16 and 31. Adding ~1.94 pp of bus occupancy is far short of doubling MO
    fetch latency, so the risk is small; it is bounded, not eliminated. The
    honest next step is a bench that puts MO on the real MiSTer arbiter.

  **Gate:** `sim/run_sdram_refresh_tb.sh` measures worst-case row interval
  against the real FSM and carries both out-of-spec policies (250/48 and this
  branch's own 224/48) as negative controls that must be reported FAIL.
  Note `READ_PRESSURE`: only mode 3 (bursty) reaches the true worst case. Under
  constant pressure the measured gap collapses to `INTERVAL + 1` and every
  policy above looks fine, because `refresh_ctr` resets when a refresh becomes
  *due*, not when it is *serviced*. Do not re-derive this on paper; run the
  bench.
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

## BUILD 112 — catching up to the Pocket line

`mister-port` sat at BUILD 105/107/108 while the Pocket line ran on to BUILD
112. `mister-112` is `mister-port` **merged with** `tas-atomic`, not rebased.
A rebase would have rewritten commits the owner had already pushed to
`mister-port` — including their own REFRESH-112 and CLKFIX-106 work — and
`tas-atomic` moved twice during this session, which a rebase would have had to
absorb by rewriting history again each time. A merge records both lines as they
actually were and leaves the owner's commits with the hashes they were pushed
under.

**Base:** `origin/mister-port` at `02d061d`, which is **byte-identical to
`origin/refresh-112`** — the owner's own session had already pushed REFRESH-112
and CLKFIX-106 onto `mister-port` before this merge started. None of that work
is redone here and none of it is touched. `REFRESH_INTERVAL=160` /
`DEFER_CAP=48` are the owner's values, unchanged.
**Merged from:** `origin/tas-atomic`, first at `d45b884` and then again at
`a2cc5b4` when that branch moved eleven commits underneath this one.

> **Correction to commit `7af144e`'s message.** That merge commit says
> *"tas-atomic still carries `psram #(.CLOCK_SPEED(85.909))`"*. **It does
> not, and did not.** `tas-atomic` fixed that constant in `6596423` (BUILD
> 106) and `mister-port` fixed it independently in `972bbf4` (CLKFIX-106);
> both branches read `35.795455` at the merge point, and the four `core_top.v`
> conflicts actually resolved were **comment text only**, not the parameter.
> The commit message is wrong; the code is right, and the section on CLKFIX-106
> below has always said *"matching `tas-atomic`"*, correctly. Recorded here
> because a pushed commit message cannot be corrected without a force-push on
> a shared branch, and leaving a false claim in the log to avoid a paragraph of
> admission is how this project acquires the errors it later has to hunt.

**Pocket-side delta.** After both merges this branch differs from
`origin/tas-atomic` under `src/fpga/` by **comment text only** — four hunks in
`core_top.v` and one in `sdram_simple.v`, no RTL. The two lines have converged
on everything that synthesises.

### What came across

Everything below `src/fpga/core/rtl/` is shared source that `files.qip`
compiles, so most of this arrives in the MiSTer bitstream without any glue
change at all.

| Item | Where | Lands on MiSTer how |
|---|---|---|
| **Two-frame line-buffer ghost fix** (self-clearing readout) | `escape_mob.v` | Automatically — same file, same module |
| **`escape_stain`** (apply_stain automaton extracted to a module) | `escape_stain.v` | Glue change: `escape_mister.v` had its own inline transcription, now replaced by the module — **equivalence-checked**, see below |
| **VSHAD3-112** 16 KB partial ROM shadow at `0x54000` | `escape_core.vhd` | Automatically. Was a **full 32 KB** shadow here before the merge |
| **`vshad3_on`** runtime toggle | `escape_core.vhd` | Glue change: new `escape_mister.v` port, `CONF_STR` `O[8]`, `~status[8]` |
| **`CPU_TYPE`** generic, default 68010 | `escape_core.vhd` | Automatically; now stated explicitly at the instantiation |
| **CADENCE-107** `dbg_cadv` / `dbg_cadw` meters | `escape_core.vhd` | Compiled, outputs left open (no HUD here) |
| **`support/check_slack.py`** multi-corner slack gate | `support/` | CI change; replaces `src/mister/check_slack.py`, which is deleted |
| **`support/report_hold_paths.tcl`** | `support/` | CI change, plus a fix: it hardcoded `project_open ap_core` and so had never run for MiSTer |
| Benches `run_stain_tb.sh`, `run_sdram_refresh_tb.sh`, `run_vshad3_tb.sh`, `run_cadence_tb.sh`, `run_busrate.sh`, `run_pf_reset_tb.sh` | `sim/` | Three are cheap pre-Quartus steps, one is a parallel job; see below |

### The stain substitution is equivalence-checked, not eyeballed

Replacing `escape_mister.v`'s inline apply_stain automaton with the shared
`escape_stain` module is the one BUILD 112 change that rewrites logic the
MiSTer build actually synthesises, so "it looks the same" is not good enough.
Both were driven from one stimulus stream — 456-column line wrap, markers at
~1 % density like real MPR2 pixels — and compared every cycle:

```
EQ  cycles=2000000  module_high=899235  inline_high=899235
    marker_events=39376  DIFFS=0
EQ PASS: module and pre-BUILD-112 inline automaton agree on every cycle.
```

`module_high` and `inline_high` are printed so a run where the output never
asserts is visibly vacuous rather than a silent pass. **Proven able to fail:**
dropping the `& ~s_in` term from the module's `stain_brk` — a one-token change
— gives `DIFFS=8520`.

**The ghost fix is the highest-value item and it is the one that needed no
work.** It is confirmed on real **Pocket** hardware ("scroll artifacts
disappeared") and it is a change to `escape_mob.v`, which both platforms
compile from one copy. It has **not** been confirmed on MiSTer hardware, for
the simple reason that no BUILD 112 MiSTer bitstream has ever been flashed.

### What did not come across, and why

* **`interact.json`** — Pocket-only. It is an openFPGA/APF manifest; MiSTer
  has no analogue and never reads it. The one entry that matters to both
  platforms, id 37 *"ROM Shadow 0x54000"*, was hand-carried to `CONF_STR` as
  `O[8]`. Note the asymmetry in the other direction too: the Pocket's Interact
  menu has a **hard 16-variable cap** (11 in use). `CONF_STR` has no such cap —
  it is bounded only by `status[]`, 128 bits, of which this core uses 8. A
  future toggle that will not fit on the Pocket can still exist here.
* **`core_top.v` HUD, debug pages, layer isolation, test tone** — Pocket-only
  forensics, deliberately absent (difference 4 at the top of
  `escape_mister.v`). The CADENCE-107 counters therefore compile but have no
  display; reading them on MiSTer would need a `status[]`-driven readback path
  that does not exist.
* **`ee_save.vhd` / EEPROM persistence** — unchanged from BUILD 103. Still
  Pocket-only, still not in `files.qip`, high scores still do not survive a
  power cycle here.
* **`sim/run_pf_reset_tb.sh`** — added to the tree but **not** to this
  workflow. It slices blocks out of `core_top.v`, which `files.qip` does not
  compile; it is a Pocket gate and putting it in a job called *Build MiSTer
  core* would make the name a lie. See the CI gap note below.

### PFRESET: checked for divergence, and converged

PFRESET originated **here** (`dcd1196`, PFRESET-107) and was backported to the
Pocket (`ee46ba1`, PFRESET-111), so the obvious risk was that the two had
drifted. They have not. Both reset the same nine registers —
`vg_reqA_px`, `vg_reqB_px`, `inflA`, `inflB`, `pfq_count`, `pfq_wr`, `pfq_rd`,
`pf_wp`, `pf_rp` — on the same condition (`core_reset_n`, pixel domain), as the
last statement of the playfield pixel-domain `always` block so it wins any
same-cycle collision. The MiSTer version additionally clears
`cpu_owner`/`mo_owner`/`pf_owner`/`fpv_owner`/`fpe_owner` on `ioctl_download`,
which the Pocket does not need and could not use: `pf_owner` does not exist
there (the playfield is on CRAM, not on an SDRAM grant arm) and there is no
`ioctl_download` re-entry path to clear anything for. **MiSTer is a strict
superset; nothing was ported and nothing is missing.**

*Residual gap, symmetric on both platforms and not fixed here:* the
service-side in-flight state is un-reset on both. Pocket does not clear
`cvg_ph` / `cram_read_en` / `cvg_hi` / `cvg_ch` on `core_rstn_sd`; MiSTer does
not clear `pf_owner` on `core_rstn_sd` either (only on `ioctl_download`). Both
rely on the transaction completing naturally. If that is ever hardened it
should be hardened on both ports at once.

### The ROM shadow on MiSTer — what is predicted and what is not

On the Pocket the 16 KB partial shadow measured **2.410e-04 vs 1.252e-03**
sprite dropouts per robot-object-frame — a **5.19x** reduction, p=1.0e-05 —
and was statistically indistinguishable from the old full 32 KB shadow at 9
fewer M10K.

**That number is not claimed here and cannot be inferred from it.** The
mechanism is: shadowing takes main-CPU fetches off the shared bus so the
lowest-priority client (motion objects) gets more of it. On the Pocket the
playfield is served from CRAM and the SDRAM bus is at ~23% of a scanline; here
the playfield is on the *same* bus and the budget is ~71% (see *Bandwidth
budget* above). Both the contention being relieved and the traffic competing
for the freed slots are different. What can honestly be said:

* **Predicted, not measured:** the *direction* is the same. Fewer CPU fetches
  on the bus cannot reduce what is left for the MO client.
* **Not predicted:** the *magnitude*. It could plausibly be larger here
  (the bus is scarcer, so each freed slot is worth more) or smaller (the
  playfield may absorb the freed slots before the MO client sees them,
  since PF and MO share the lowest tier round-robin). Nothing in this tree
  measures it, and no bench on this branch puts MO and PF on the real
  arbiter together under load.
* **Does transfer:** *which* half of `0x50000-0x57FFF` to shadow. That is a
  property of this ROM's access pattern, not of the memory system — 94.5% of
  main-CPU traffic in that range lands in `0x54000-0x57FFF`, and pages
  `0x50000`/`0x51000`/`0x52000` are read **zero** times during gameplay
  (`docs/VSHAD3.md` §8). Same ROM, same CPUs, same code path.
* **The full 32 KB shadow is probably affordable here** where it is not on the
  Pocket — the DE10-Nano had 386/553 M10K at BUILD 108 against the Pocket's
  299/308. It is **not** taken, on purpose: `escape_core.vhd` is shared source
  and forking the shadow width per platform would buy the ~5.5% of in-range
  traffic that lives in the pages measured to be read zero times, in exchange
  for a permanent divergence in the one file both platforms most need to keep
  identical. If the owner wants it, the honest way is a generic, not an edit.

**The M10K prediction, written down before the build reported.** MiSTer has
been carrying the *full* 32 KB shadow since the branch point, so unlike the
Pocket — where the partial shadow was an addition — here it is a **reduction**.
On the Pocket the `vshad3` instance itself measured `depth 16384, M10K=32`
before and `depth 8192, M10K=16` after (`docs/VSHAD3.md` §11), which is exactly
the geometry: 16 384 × 16 bits ÷ 8 192 bits per block in ×16 mode = 32 blocks,
halved to 16. The same instance is compiled here, so **this build should come
in about 16 blocks below BUILD 108's 386/553, i.e. ≈ 370/553.**

Note the Pocket's *total* only moved 308 → 299, a saving of 9 rather than 16,
because BUILD 108 was pinned at 308/308 — completely full — and the fitter had
been packing around that ceiling. The DE10-Nano is at 70 % occupancy with no
such pressure, so the total here should track the instance more closely. **That
is a prediction from geometry, not a measurement**; the measured figure is in
[CI results](#build-112-ci-results-run-32816669942-commit-aef04a7) and if it disagrees, the geometry argument
is what is wrong.

`VSHAD3_EN(1)` and `CPU_TYPE(1)` are now **stated explicitly** at the
`escape_core` instantiation in `escape_mister.v`. Both already defaulted to 1,
so the bitstream is unchanged; the point is that the decisions are visible
where someone would go to change them.

### CI: what the MiSTer workflow now gates on

`.github/workflows/build-mister.yml` has **two jobs**. `build` runs the cheap
shared-RTL benches ahead of Quartus; `vshad3` runs the slow one alongside it.

**Why the split, because it is a mistake worth not repeating.** `tb_vshad3`
was briefly a step in `build`, between the cheap gates and the compile. The
other three cost **0 s, 47 s and 11 s** on the hosted runner; `tb_vshad3` cost
**20+ minutes** (measured, run `32815564898`), because it is a GHDL elaboration
of the whole dual-68000 machine four configurations deep, not a boundary check.
Sitting in the *"fast fail before spending 30 minutes in Quartus"* slot it
roughly doubled the time to a bitstream and contributed nothing to that slot's
purpose. As a parallel job it still blocks the workflow's overall conclusion,
so it gates exactly as hard. **Keep anything over ~2 minutes out of the
pre-Quartus list.**

Each bench drives a file this workflow actually compiles:

| Step | Gates | Proven able to fail by |
|---|---|---|
| `check_ports.py` | the Verilog→VHDL boundary | renaming `.vshad3_on` → names it; deleting `.rom_data` → names it |
| `run_mister_pf_tb.sh` | playfield channel is serviced | the BUILD 105 A/B table above (0/0 vs 13 794/13 794) |
| `run_stain_tb.sh` | line-buffer ghost + stain automaton | reverting the self-clearing readout → 226 mismatching px, all in cases D and E |
| `run_sdram_refresh_tb.sh` | refresh interval vs JEDEC | its own in-run negative controls report 250/48 at 8.7721 µs and 224/48 at 8.0457 µs as FAIL |
| `run_vshad3_tb.sh` (parallel job) | partial shadow decode + runtime toggle | the toggle changes measured fetch cost 5.015 → 4.015 clk; a still-32 KB range would score 5.015 at `0x50000` |
| `support/check_slack.py` | negative slack, any corner | a fixture whose only negative row is at the third corner |
| release ROM-free check | ROM data in the staged release | five provocations, all refused (see the `.mra` section) |

**Run locally on this tree but not wired into CI:**
`sim/run_cadence_tb.sh` — **PASS**, `video_starts=137 expected=137`,
`world_starts=0 expected=0`, *"all three decoys rejected"*. It exercises the
CADENCE-107 counters that BUILD 112 adds to `escape_core.vhd`, which this
platform compiles, and it carries its own decoys so it cannot match nothing.
It is **not** a CI step for the same reason `tb_vshad3` is a separate job — it
is a full-machine GHDL elaboration in the tens of minutes. Worth adding as a
second parallel job if the meters ever get a readout here; today they compile
with nothing to display them, so the gate protects code nobody on this
platform can observe.

**Known CI gap, stated rather than hidden:** `sim/run_pf_reset_tb.sh` — the
Pocket's PFRESET gate — is wired into **no** workflow at all. Neither
`build.yml` nor `ci.yml` references any `sim/run_*` script. The MiSTer side has
had its equivalent gated since PFRESET-107; the Pocket backport did not get the
same treatment, so PFRESET-111 is protected only by someone running the bench
by hand. That is a Pocket-side gap and is deliberately not fixed from this
branch.

### What the gate caught, and two benches that need a hand

**The pre-Quartus step earned its place immediately.** CI run `32814954861`
failed in **56 seconds** with four elaboration errors, both defects introduced
by the commit before it: `escape_stain.v` had been added to `files.qip` (the
synthesis list) but not to `run_mister_pf_tb.sh` (the bench's compile line),
and `support/mk_core_stub.py` derived the stub's *ports* from the entity while
carrying its *generics* as a hardcoded literal, so `VSHAD3_EN` and `CPU_TYPE`
did not exist to be overridden. Both are fixed; generics are now derived like
ports, and the generator hard-errors on a non-integer generic rather than
mistranslating one. Note the structural point: `files.qip` and the bench
compile line are independent transcriptions of the same dependency set and
nothing reconciles them. Adding a shared module means touching both.

**Two benches will not run from a clean checkout.** Neither is an RTL fault
and neither fails open:

* `run_mob_tb.sh` needs MAME-derived fixtures in `sim/work/` (`game_mo.hex`,
  `game_cfg.hex`, `game_pf.hex`, `game_pfx.hex`, `image_bytes.hex`) plus
  `atari_escape.rom`. That directory is gitignored — correctly, it holds ROM
  data — so a fresh worktree has none of it. **The bench detects this and
  refuses**: it printed *"MOB PRIO CHECK VACUOUS — the comparator saw ZERO
  MO-covered pixels, so 0/0 measured nothing at all… Do not quote a percentage
  from it"* and exited 1. That is a gate behaving exactly as this project's
  rules demand. With the fixtures in place it scores **10 047 / 10 047 =
  100.0000 %** MOB PRIO and **VS-MAME 100.0000 %, wrong_pen=0, not_in_mame=0,
  missing=0** — unchanged by the merge, which is the evidence that the
  self-clearing readout is behaviour-preserving on a real scene.
* `run_mob_order_check.sh` exits 128 with `fatal: invalid object name
  'origin/mo-chan4'`. It compares against a branch that exists only as a local
  ref in the owner's main clone and was never pushed. It cannot run in CI or in
  any fresh worktree as written.

Neither is fixed here — they are shared benches, not MiSTer ones, and the
second needs a decision about whether that branch should be pushed or the
comparison re-anchored.

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

**PSRAM / `CLOCK_SPEED`: unreachable from the MiSTer build, but NOT dead code on
this branch (CLKFIX-106, fixed here).** MiSTer does not use the PSRAM path at
all — `third_party/analogue-pocket-utils/psram.sv` is not in
`src/mister/files.qip`, there is no `psram` instance in the MiSTer hierarchy,
and the DE10-Nano has no such device. All of that is true and none of it made
the constant harmless.

This branch carries **both** project trees. `src/fpga/ap_core.qsf` (lines 741 and
813) compiles `core_top.v` and `psram.sv` for the **Pocket**, so a Pocket `.rbf`
built from `mister-port` shipped the BUILD 106 bug: `core_top.v` instantiated
`psram #(.CLOCK_SPEED(85.909))` while `clk_sdram` is really 35.795455 MHz
(`mf_pllbase` `outclk_2`). `psram.sv` derives every wait as
`CEIL(min_ns / (1000/CLOCK_SPEED))`, so it waited **7 cycles for the 70 ns read
access where 3 suffice** — ~279 ns per playfield fetch instead of ~168 ns, on
every tile.

Now `35.795455`, matching `tas-atomic`. Gate: `sim/run_psram_tb.sh`, which runs
the shipping config (PASS, 41.0 ns measured I/O headroom over 172 reads) and a
negative control that declares 35.795455 while the PLL runs 85.909 (must FAIL,
and does — 4 async pulse-width violations).

**The lesson, since this document made the error:** "the MiSTer build does not
compile it" is not the same as "this branch does not ship it." Scope a
dead-code claim to the *build*, not the *branch*.

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

Aspect ratio, scandoubler FX, **Service Mode** (the cabinet's self-test lever),
**Skip Self-Test** (forces the boot's tests-passed branch) and **ROM Shadow
0x54000**. The game has no DIP switches — the real cabinet is configured
through its 93C46 EEPROM — so there is no `<switches>` block in the `.mra` and
no `ioctl_index == 254` path.

### ROM Shadow 0x54000 (BUILD 112)

`O[8]`, the MiSTer equivalent of the Pocket's Interact variable id 37. **On**
is the default. It gates the *decode* of the 16 KB partial ROM shadow, not the
BRAM: the block is instantiated and filled either way, so flipping it costs no
M10K and needs no reflash — which is the whole point, the owner can A/B sprite
dropouts against CPU cadence on the device.

**The menu entry reads `On,Off`, not `Off,On`, and that ordering is
load-bearing.** `hps_io` powers `status[]` up at zero and a fresh SD card has
no saved config, so whichever label sits first is what every first-boot player
gets. The default is On, so On must be first and the wire is `~status[8]`.

The toggle crosses from `clk_ram` (35.795455) to `clk_sys` (7.159091) through
the same 2-flop `sync2` every other slow control here uses. That is the CDC.
The *atomicity* — only resampling between bus cycles, so a mid-cycle flip
cannot change which memory answers a cycle already in flight — is `s3_arm_p`
inside `escape_core.vhd`, shared with the Pocket.

**EEPROM contents are not persisted.** `escape_core` holds the EEPROM in BRAM
and it resets with the core, so bookkeeping and high scores do not survive a
power cycle. Save states are explicitly out of scope for this port.

### About / Credits pages

Three OSD submenu pages — **About**, **Credits 1/2**, **Credits 2/2** — sit
between `Reset` and the joystick entries.

**The mechanic is the stock MiSTer framework's, not something invented here.**
In this framework the FPGA never parses `CONF_STR`: `sys/hps_io.sv` stores it as
a passive byte ROM and streams it to the ARM side one byte per strobe (HPS
command `0x14`, `hps_io.sv` line 394), and `sys/osd.v` is a dumb 256×64 bitmap
framebuffer with no font and no menu logic. All grammar and drawing happen in
`Main_MiSTer`'s C++. A credits screen is therefore pure `CONF_STR`:

* `"Pn,Title;"` declares submenu page *n* (1–9),
* `"Pn-,some text;"` puts a non-selectable text line on that page.

`"-,text;"` is simply the non-empty form of the `"-;"` separator that
`third_party/Arcade-Atari-system1_MiSTer` already uses six times in its own
`CONF_STR` (`Arcade-atarisys1.sv` lines 261–277). No `sys/` change, no new
ports, no new RTL — only the string in `src/mister/Arcade-Escape.sv`.

**Two format limits, and what they cost.** `osd.v` is `OSD_WIDTH = 256` px with
an 8 px font, so 32 columns before the selection gutter; lines here are kept to
about 26 characters and wrapped by hand. More awkwardly, `CONF_STR` uses `,` as
its field separator and `;` as its terminator, so **neither character can appear
inside a label**. That is the only reason the thanks line renders as
`LMSS DJS LCS TBPL EG` rather than the comma-separated original. Nothing is
dropped; the unabridged text is immediately below and in `README.md`.

### Full attribution (unabridged)

The OSD pages are a hand-wrapped rendering of this. This section is normative;
the OSD is a convenience.

> Thanks: LMSS, DJS, LCS, TBPL, EG

* This core is **GPL-3.0**. It requires the user's own MAME `eprom` romset.
  **No ROM data is included** in this repository or in any artifact it builds.

  **Re-verified byte by byte at BUILD 112**, not assumed. The shipped
  `src/mister/releases/Escape from the Planet of the Robot Monsters (set 1).mra`
  is **5 395 bytes**, **0 non-ASCII bytes**, **0 control bytes** outside
  tab/CR/LF, **30 `crc=` references**, **123 lines**, longest line 81 chars,
  and **zero `<part>` elements carrying inline data** of any length — every
  part is a `name=`/`crc=` reference to a chip in the user's own zip, which is
  the entire point of the format. SHA-256
  `9cd7670bbf69ebe57935ae3b764d7953092951a6b92be4303b05c605ecdb3f58`.
  The merge did not touch the file (`git diff origin/mister-port -- ` on it is
  empty); it was re-measured anyway.

  **And it is now gated, not just measured once.** The MiSTer release surface
  is three files — a bitstream, the `.mra`, and a markdown file — which is far
  smaller than the Pocket's (`support/package.sh` copies whole `Assets/` and
  `Platforms/` trees and needs four guards plus `support/test_package_guards.sh`
  to police them). It is checked anyway, because *"it cannot happen"* is
  precisely how the Pocket's zero-ROM hole stayed open: a 2 228 224-byte ROM
  renamed `gfxdata.bin` walked into a release zip past a guard no code path
  could trigger. The new **Release must contain no ROM data** CI step rejects
  any file that is not `.rbf`/`.mra`/`.md`, any non-ASCII byte in the manifest,
  any `<part>` carrying inline payload, an oversized manifest, and a manifest
  with implausibly few `crc=` references. **Provoked, all five:**

  | | |
  |---|---|
  | control — the real staged release | **passes**, 0 non-ASCII, 30 crc refs |
  | a ROM staged as `gfxdata.bin` | refused, *UNEXPECTED FILE IN RELEASE* |
  | ROM bytes appended to the `.mra` | refused, 5 018 non-ASCII bytes |
  | **one** non-ASCII byte in the `.mra` | refused, 1 non-ASCII byte |
  | an inline `<part>` payload | refused, *INLINE `<part>` PAYLOAD* |
  | the `.mra` replaced by a stub | refused, *ONLY 0 crc= REFS* |

  The non-ASCII test uses `tr`, not `grep -P`. BSD grep has no `-P`, so a `-P`
  check errors out and the surrounding `if` reads as "clean" — a gate that
  cannot fail on half the machines anyone would run it on. That was caught by
  provoking it rather than by reading it: the first version of this guard
  refused the appended-ROM case for the *wrong reason* (the crc count), and
  only the byte-level provocation showed why.

  `support/test_package_guards.sh`, which arrived with the second tas-atomic
  merge, also passes here: **7 passed, 0 failed**, including a control asserting
  the happy path still produces a zip — so a guard that refuses *everything*
  cannot pass either.
* **d18c7db (Alex)** and **MiSTer-devel** for
  [`Arcade-Atari-system1_MiSTer`](https://github.com/MiSTer-devel/Arcade-Atari-system1_MiSTer)
  (GPL-3.0), the schematic-based Atari System 1 core this project's RTL base was
  derived from — including the MAME-faithful **TMS5220** speech chip model
  (vendored at `src/fpga/core/rtl/TMS5220.vhd` with a lattice-filter arithmetic
  fix, provenance noted in the file header). **This is the MiSTer-devel lineage
  this port stands on and it is credited first on the Credits pages.**
* **Tobias Gubener (TobiFlex)** for the **TG68K.C** 68000 soft-CPU core
  (LGPL-3.0, with patches by MikeJ, Till Harbaum, Rok Krajnc and others) — both
  of this core's 68000s are TG68K instances, via the System 1 tree.
* **Daniel Wallner** for the **T65** 6502 core (BSD-style license, via OpenCores
  / the System 1 tree), reused for the JSA-I sound board's 6502.
* **Jose Tejada (jotego)** for [`jt51`](https://github.com/jotego/jt51), the
  YM2151 FM synthesis core used by the JSA-I audio subsystem (GPL-3.0, included
  as a git submodule with license and history intact).
* **MAME** and **Aaron Giles**, author of the Atari Escape driver
  (`src/mame/atari/eprom.cpp`, `license:BSD-3-Clause`,
  `copyright-holders: Aaron Giles`) and the supporting device models
  (`atarijsa`, `atarimo`, `slapstic`). The MAME driver was used purely as a
  **behavioral reference**; **no MAME source code is copied into this
  repository**.
* The **openFPGA** community and **Analogue** for the Pocket core framework
  ([`open-fpga/core-template`](https://github.com/open-fpga/core-template)).

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
* **The Verilog→VHDL boundary**, mechanically: `check_ports.py` confirms every
  connected port exists on the `escape_core` entity and that no mandatory input
  is unconnected — 116 entity ports, 58 connected, 49 outputs left open as of
  BUILD 112. Proven able to fail twice over: renaming `.vshad3_on` →
  `"connected but not on the entity: vshad3_onn"`; deleting `.rom_data` →
  `"mandatory inputs (no VHDL default) not connected: rom_data"`.
* **The two-frame line-buffer ghost fix, in simulation** — `run_stain_tb.sh`.
  11 320 / 11 320 stained pixels and 0 / 0 stray MO pixels against the
  reference, per-case mismatches zero across all five cases. **Proven able to
  fail:** reverting `escape_mob.v`'s self-clearing readout to the pre-GFXDASH-3
  tag-only write produces 226 mismatching pixels — 210 px of over-stain in six
  spans plus 16 px of stale line-buffer content — concentrated entirely in
  cases D and E, which are the two-frame-ghost cases. This is the shipped
  `escape_mob.v` and `escape_stain.v`, not a transcription.
  *On hardware this fix is confirmed on the **Pocket** only.*
* **The partial ROM shadow's decode and its runtime toggle, in simulation** —
  `run_vshad3_tb.sh`, 4/4 rows. It measures CPU clocks per fetch, so each row
  is a behavioural discriminator, not an assertion:
  `0x54000` shadowed = 5.015; the same addresses with `vshad3_on=0` = 4.015
  (the toggle does something); `0x50000` = 4.015 (the low half really is
  unshadowed, i.e. the range really is 16 KB and not still 32 KB);
  `VSHAD3_EN=0` = 4.015 whatever the toggle says (the compile-time generic
  removes it, so the range can never be served by neither path).
* **The refresh interval against JEDEC, in simulation** —
  `run_sdram_refresh_tb.sh` against the real FSM. Shipping 160/48 measures a
  worst-case row interval of 224 clk = 6.2578 µs, 80.10 % of the 7.8125 µs
  budget. The bench carries its own out-of-spec **negative controls and
  reported them as FAIL in the same run**: 250/48 at 8.7721 µs and the
  previously-shipped 224/48 at 8.0457 µs. It also prints that the paper model
  understates by 16 clocks, which is the `+16` this branch keeps in
  `sdram_simple.v`.
* **The MRA conventions** (`map="01"` byte lane, index numbering, SD-card paths,
  file naming) against MiSTer's firmware source and the reference core's shipped
  MRAs — see *Sources*.
* **Which clock configuration the Pocket actually ships** — 35.795455 MHz, 5× CPU.
  Several comments in `core_top.v`, `sdram_simple.v` and the original porting
  brief say "85.909 MHz, 12:1". That is **stale**; the PLL IP has said 5× since
  commit *"v22: SDRAM 42.95 → 35.8 MHz"*. Read the PLL, not the comments.

### The three-way split, for BUILD 112 specifically

The MiSTer core has had **far less hardware exercise than the Pocket**. One
flash, at BUILD 105, which found a dead playfield. The fix for that has never
been flashed, and neither has anything added since. Read this table before
deciding what ships.

| | Simulated | CI-verified | Run on a DE10-Nano |
|---|---|---|---|
| Two-frame line-buffer ghost fix | **yes**, gate proven able to fail | **yes** | **never** (confirmed on **Pocket** hardware only) |
| `escape_stain` module substitution | **yes**, same gate | **yes** | **never** |
| 16 KB partial ROM shadow at `0x54000` | **yes**, 4/4 discriminating rows | **yes** | **never** |
| `vshad3_on` runtime toggle (`CONF_STR` `O[8]`) | RTL path yes; the **OSD wiring** no | fit/timing only | **never** — nobody has opened this menu |
| `CPU_TYPE` = 68010 | Pocket A/B over 400 frames | fit/timing only | **never on MiSTer** |
| Refresh interval 160/48 vs JEDEC | **yes**, with failing controls | **yes** | **never** — and the *bandwidth* cost is simulated, not measured on a board |
| PFRESET (playfield channel reset) | **yes**, 13 794/13 794 both phases | **yes** | **never** — this is the BUILD 105 fix, still unflashed |
| Timing / fit / M10K | n/a | **yes** — 370/553 M10K, TNS 0.000 all 8 clocks; but `pll_hdmi` setup is **+0.115 ns**, see below | n/a |
| `.mra` is ROM-free | n/a | **yes** — gated, 5 provocations refused | n/a |

**Things simulation here specifically cannot tell you.** `tb_mister_pf` uses a
*stub* machine and a *behavioural* SDRAM: it proves fetches are issued, granted
and completed, not that the returned pixels are right. `tb_stain` drives the
shipped `escape_mob`/`escape_stain` but against a synthetic scene, not the
game. No bench on this branch puts the MO client and the PF client on the real
arbiter together under load, which is exactly the interaction the shadow is
supposed to improve and the interaction this platform's bandwidth budget is
tightest on.

### Not verified — the PFRESET-107 / REFRESH-112 build has NOT been on hardware

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
* **REFRESH-112 on hardware.** The change is a constant, and the worst-case row
  interval is now measured against the real FSM rather than derived on paper
  (`sim/run_sdram_refresh_tb.sh`) — but no capture has been taken with it.
  REFRESH-107 was listed here as "the arithmetic is unambiguous"; it was in fact
  wrong, in the safe-looking direction, which is exactly why this row now cites
  a bench instead of arithmetic. What is still unverified on hardware is the
  **bandwidth** consequence. In simulation the playfield loses nothing (13,794
  fetches granted and completed at both 224/48 and 160/48), but no bench on this
  branch puts the MO client on the real arbiter, so the sprite cost is bounded
  by a latency sensitivity curve rather than measured — see the refresh section
  above. Sprite throughput under a full playfield load has never been exercised
  on a real board.
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

**Added at BUILD 112, MiSTer-specific and still outstanding:**

* **The `ROM Shadow 0x54000` OSD entry has never been opened.** The RTL path
  it drives is simulated (`run_vshad3_tb.sh`, 4/4), and the CDC and atomicity
  arguments are written down, but the `CONF_STR` string, the `status[8]` bit,
  the inverted `On,Off` ordering and the `sync2` into `clk_sys` are all
  unexercised outside synthesis. **First thing to check on the next flash:
  that the default is ON.** The ordering is inverted specifically because
  `hps_io` powers `status[]` up at zero, and getting that backwards would ship
  every first-boot player the non-default configuration silently.
* **The partial shadow's benefit on this platform is entirely unmeasured.**
  See the section above for what does and does not transfer from the Pocket's
  5.19x. Sprite dropouts under a busy playfield is the observation to make.
* **`CPU_TYPE=1` (68010) has never run on MiSTer hardware.** The A/B that
  showed behaviour identical and interrupt entry ~5 clocks slower was run on
  the Pocket's bench, and the CPU is shared RTL, so the risk is low — but it
  is not zero and it has not been exercised here.
* **The CADENCE-107 meters compile but cannot be read on MiSTer.** There is no
  HUD and no `status[]` readback path, so `dbg_cadv`/`dbg_cadw` are live
  counters with no display. If the owner wants the logic-frame cadence figure
  from a DE10-Nano, that wiring does not exist yet.
* **`escape_stain` is newly a module here.** The substitution is
  equivalence-checked over 2 000 000 cycles with zero differences, so this is
  a low-risk item — but it is a change to synthesised logic that no hardware
  has seen.

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

### How to tell what you flashed (read this before reporting a capture)

A capture attributed to the wrong build is worse than no capture. The identifiers that
actually exist are weaker than the `BUILD nnn` numbering implies:

| where | what it shows | how far it gets you |
|---|---|---|
| MiSTer OSD, `V,v` line | `BUILD_DATE`, auto-generated `%y%m%d` by `sys/build_id.tcl` | the **day** only — two builds on one day are indistinguishable, and it maps to no commit |
| Pocket `core.json` | `version` + `date_release`, **hand-maintained** | only as good as the last person to bump it; it sat at `0.0.1` / `2026-08-06` through BUILD 106 **and** 107 |
| `BUILD nnn` in this file | *(CI run id, commit sha)* | the only real link from a flashed binary to a tree — and it exists only because someone wrote the row |

So the rule: **a build that gets flashed gets a `BUILD nnn` row here, with its CI run id
and commit sha, before the capture is taken.** Nothing in the toolchain enforces this;
the date in the OSD will not save you.

Known weakness, not yet fixed: neither platform embeds its git SHA in the bitstream. The
durable fix is to extend `sys/build_id.tcl` (MiSTer) and the Pocket packaging to bake in
a short SHA, so the binary is self-identifying instead of relying on this table. That
touches shared MiSTer framework code and has not been done.

### BUILD 112 CI results (run 32816669942, commit `aef04a7`)

**Green, every step, both jobs.** All four sim gates, Quartus, the slack gate
and the new ROM-free release check.

| | BUILD 108 | **BUILD 112** | delta |
|---|---|---|---|
| ALMs | 18,846 / 41,910 (45 %) | **18,455 / 41,910 (44 %)** | −391 |
| **M10K** | 386 / 553 (70 %) | **370 / 553 (67 %)** | **−16** |
| Registers | 21,197 | **21,342** | +145 |
| DSP | 76 / 112 | 76 / 112 | 0 |
| Block memory bits | — | 2,822,224 / 5,662,720 (50 %) | — |

**The M10K prediction was right, to the block.** Predicted ≈ 370 from the
`dpram_dc` geometry (`awidth` 14 → 13 halves a 32-block instance to 16);
measured 370. Unlike the Pocket — where the total moved 9 against a 308/308
ceiling — the DE10-Nano's total tracked the instance exactly, which is what the
70 %-occupancy argument predicted. The +145 registers are the CADENCE-107
counters, `escape_stain` and `v_s3_arm`.

**Setup and hold, per clock domain.** TNS **0.000** on all eight clocks, both
checks — unchanged from baseline.

| clock | setup B108 | **setup B112** | hold B108 | **hold B112** |
|---|---|---|---|---|
| `emu\|pll` general[0] — 7.159091 MHz CPU + pixel | +15.831 | **+17.126** | +0.263 | **+0.269** |
| `emu\|pll` general[1] — 35.795455 MHz SDRAM | +14.587 | **+14.152** | +0.254 | **+0.252** |
| `SDRAM_CLK` | +3.442 | **+3.435** | +17.450 | **+17.450** |
| `pll_hdmi` divclk — 148.5 MHz (framework) | +0.880 | **+0.115** | +0.229 | **+0.257** |
| `FPGA_CLK1_50` | +8.636 | **+7.016** | +0.415 | **+0.415** |
| `FPGA_CLK2_50` | +12.556 | **+12.205** | +0.372 | **+0.362** |
| `spi_sck` | +6.061 | **+5.949** | +0.352 | **+0.385** |
| `pll_audio` | +15.976 | **+15.675** | +0.251 | **+0.270** |

**The core's own CPU clock gained 1.295 ns of setup.** That is the largest
movement in the table and it is in the right direction.

#### The one number to look at before shipping: `pll_hdmi` setup +0.115 ns

It was +0.880 at BUILD 108. It is **+0.115** now — the tightest path in the
design, and 1.7 % of its 6.732 ns period.

**It is not noise, and that is measured, not assumed.** Two independent CI runs
(`4933b4e`, run 32815564898, and `aef04a7`, run 32816669942) whose *compiled*
file sets are byte-identical — the commits between them touch only docs —
produced **identical numbers to three decimals on all sixteen rows above**. So
the fitter is deterministic here and the 0.765 ns drop is a real consequence of
the netlist change, not run-to-run variation.

**It is not in this core.** The path is
`ascal:ascal|o_hcpt[1] → ascal:ascal|o_vcpt[7]`, entirely inside the MiSTer
framework's vendored `ascal` HDMI scaler (clock skew −0.492, data delay 5.925,
relationship 6.732). The mechanism is indirect: freeing 16 M10K and 391 ALMs
changed the fitter's global placement, and `ascal` came out tighter.

**This path has always been the design's tightest and has always moved:**
+0.527 (BUILD 105) → +0.744 → +0.880 (BUILD 108) → **+0.115** (BUILD 112).

**What that means for the decision.** The bitstream **meets timing** — positive
slack, TNS 0.000, and the gate passed a check that scans every table in the
report. It is publishable. But +0.115 ns is thinner than this design's
documented **±0.157 ns placement-perturbation sensitivity**, so *a future
change as trivial as a `BUILD_ID` constant could push it negative.* Treat it as
a live fragility in the HDMI output path, not as headroom. If HDMI misbehaves
on the next flash, this is the first thing to look at — and analogue/VGA output
does not use this clock.

#### The hold reporter's first MiSTer run found something the summaries hide

`support/report_hold_paths.tcl` had never run for this project (it hardcoded
`project_open ap_core`). Its first run here reports the **Fast 1100mV 0C**
corner, which the compile flow's summary tables do not cover, and the true
worst hold there is **+0.109 ns** — below the +0.252 the Hold Summary reports
as worst:

| slack | path |
|---|---|
| **0.109** | `ascal\|o_vpixq_pre[1].g[6]` → `ascal\|o_vpixq[1].g[6]` |
| 0.116 | `ascal\|o_poly_lum1[3]` → `ascal\|o_poly_lerp_tb[3]` |
| 0.120 | `ascal\|i_vdivr[16]` → `ascal\|i_vdivr[17]` |
| 0.121 | `emu\|arcade_video\|sync_fix:sync_h\|cnt[14]` (self) |
| 0.123 | `emu\|hps_io\|video_calc\|vcnt[4]` (self) |

Still positive, still overwhelmingly in the framework rather than the machine —
but **the summary tables were never showing the worst corner**, and nobody
looking at this port had any way to know that until now.
`Arcade-Escape.hold_paths.rpt` is uploaded with every build from here on.

### BUILD 108 gate results (CI run 32804328092, netlist commit `972bbf4`)

**This is the build to flash and test.** REFRESH-112 (interval 224 → 160) and
CLKFIX-106 (Pocket `psram` CLOCK_SPEED 85.909 → 35.795455).

`972bbf4` is cited because it is the **netlist-determining** commit: every later commit
on `mister-port` is documentation, `core.json`, or an RTL *comment*, none of which reach
synthesis. Cite the netlist commit rather than the branch head — the head moves every
time someone edits this file, including this row. `check_slack.py` reported *All analysed
clocks have non-negative slack*, TNS 0.000 on all eight.

**Timing and resources are IDENTICAL to BUILD 107 — every clock, to three decimals.**

| clock | setup | hold | vs BUILD 107 |
|---|---|---|---|
| `emu\|pll` general[0] — 7.159091 MHz CPU + pixel | +15.831 ns | +0.263 | **0.000** |
| `emu\|pll` general[1] — 35.795455 MHz SDRAM | +14.587 ns | +0.254 | **0.000** |
| `SDRAM_CLK` | +3.442 | +17.450 | **0.000** |
| `pll_hdmi` divclk (tightest in the design) | **+0.880** | **+0.229** | **0.000** |
| `FPGA_CLK1_50` / `FPGA_CLK2_50` / `spi_sck` / `pll_audio` | +8.636 / +12.556 / +6.061 / +15.976 | +0.415 / +0.372 / +0.352 / +0.251 | **0.000** |

Resources also unchanged: 18,846 / 41,910 ALMs (45%), 386 / 553 M10K (70%), 76 / 112
DSP, 21,197 registers.

That identity is **expected, not luck**, and should not be read as headroom won: the
refresh change swaps one constant in a same-width comparator (224 → 160) and the new
`DEFER_CAP == 0` term folds away at 48, so the netlist is structurally unchanged and the
fitter reproduced the same placement. Given this design's measured ±0.157 ns placement
perturbation sensitivity, a 0.000 ns delta is the *strongest* possible evidence that
nothing moved.

Sim gates on this tree: `run_sdram_refresh_tb` PASS (both out-of-spec controls FAILed),
`run_psram_tb` PASS (41.0 ns headroom, wrong-clock control FAILed), `run_mob_tb`
10047/10047 100.0000% with VS-MAME `wrong_pen=0`, `run_mob_order_check` 9/9 cells
`b_shorter=0`, `run_prio_tb` 507904/507904, `run_mister_pf_tb` 13,794/13,794.
`run_stain_tb` is **not applicable** on this branch — `escape_stain.v` does not exist
here (it postdates merge base `b3926e7`), so it is unrun, not passing.

**What to watch on hardware.** The refresh fix targets *silent* corruption, so a clean
boot does not confirm it; the discriminator table below still applies. The genuine
unknown is **sprites**: refresh now takes +1.94 pp of SDRAM bus from the lowest-priority
client and no bench here puts MO on the real arbiter, so watch specifically for sprite
dropouts under a busy playfield.

### BUILD 107 gate results (CI run 32763926809, commit `dba85b4`)

Every step green, including `tb_mister_pf` on a clean checkout (13,794 / 13,794
fetches) and `check_slack.py`, which reported *All analysed clocks have
non-negative slack* with TNS 0.000 on all eight.

| clock | setup | vs BUILD 105 | hold |
|---|---|---|---|
| `emu\|pll` general[0] — 7.159091 MHz CPU + pixel | **+15.831 ns** | −0.211 | +0.263 |
| `emu\|pll` general[1] — 35.795455 MHz SDRAM | **+14.587 ns** | −0.198 | +0.254 |
| `SDRAM_CLK` | +3.442 | — | +17.450 |
| `pll_hdmi` divclk (tightest in the design) | +0.880 | — | +0.229 |
| `FPGA_CLK1_50` / `FPGA_CLK2_50` / `spi_sck` / `pll_audio` | +8.636 / +12.556 / +6.061 / +15.976 | — | +0.415 / +0.372 / +0.352 / +0.251 |

The two ~0.2 ns setup regressions on the core's own clocks are the reset fanout
PFRESET-107 adds to the playfield pipeline. They are declared rather than
buried: the margins are 15 ns and 14 ns, and the binding clock in this design is
`pll_hdmi`'s +0.880 ns, which the change does not touch.

Resources: 18,846 / 41,910 ALMs (45%), 386 / 553 M10K (70%), 76 / 112 DSP,
21,197 registers. M10K went 385 → 386; nothing here spent the DE10-Nano's
block-RAM headroom deliberately.

### What the NEXT capture confirms or refutes

There is **no debug HUD on this port** (difference 4 in `rtl/escape_mister.v`'s
header — the Pocket's forensics tooling is deliberately absent), so the reading
is the picture itself. Fortunately the picture separates the hypotheses cleanly,
because each failure mode has a different *texture*.

Capture level 1 gameplay for ~60 s, extract frames, and run the same five-patch
measurement used to diagnose this (`support/` has no tool for it — it is fifteen
lines of PIL: pick five fixed rectangles on background, report distinct colours
and σ per patch, and distinct colours over the whole play area as a scene-
complexity proxy).

| Reading | Verdict |
|---|---|
| Background patches go from **1 distinct colour** to **O(1000)**, in the region of the Pocket's 1 241; floor grid and red factory walls present; stairs drawn rather than a black hole | **PFRESET-107 confirmed.** This is the primary result. |
| Still exactly 1 distinct colour per region, still a black staircase | PFRESET-107 did **not** fix it. The channel is still not completing. Nothing else in this document explains that; re-open at the arbiter. |
| Textured, but speckled with individually wrong 8-pixel tile rows — scattered, **not** correlated with how busy the scene is | `rd_pre = 0` wrong-row serves. One-line A/B: set the PF grant arm's `rd_pre_q <= 1'b0;` to `1'b1`. See "Timing assumptions that were changed". |
| Textured, but tile rows go stale or repeat, **worse toward the right of each line** and **worse the more robots are on screen** | Bandwidth. The budget has never been exercised until now. Levers are in "Bandwidth budget". Discriminator: the artifact rate must **track scene complexity** — compare quiet and busy frames explicitly rather than eyeballing. |
| Random tiles wrong, changing frame to frame, **no** geometric or load correlation | Memory data corruption, not a fetch problem — i.e. REFRESH-112 did not go far enough (note REFRESH-107's 224 genuinely did not — it measured 103% of the JEDEC budget; 160 measures 80%). Next step is the SDRAM read-capture phase on the DE10-Nano module. |

The first two rows are the ones that matter. Everything below them is a *new*
problem that BUILD 105 could not have shown, because until this fix the
playfield client issued zero fetches and therefore exercised none of that
machinery.

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
