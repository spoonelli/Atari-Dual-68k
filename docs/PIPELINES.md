# Data and processing pipelines

**How this core is *supposed* to work.**

This is a design document, not a narration of the current source. It describes the
intended contract of each pipeline stage — what feeds it, what it owes its consumer,
and what its timing budget is — so an implementation can be measured against it.
Where the shipped RTL is known to deviate, the text says so and points at
[`DEVIATIONS.md`](DEVIATIONS.md); it does not quietly promote a bug to a specification.

Identifiers in `code font` are the real names in the RTL, with `file:line` where the
line is worth going to. The two authorities behind every number here are the original
schematics (Atari SP-332, 1989 — `reference/schematics/`, not redistributed) and
MAME's `eprom.cpp` family, in that order of precedence; `DEVIATIONS.md` §C records the
one case where MAME wins.

Target is the Analogue Pocket (Cyclone V `5CEBA4F23C8` behind the openFPGA APF
framework). A DE10-Nano/MiSTer port lives on branch `mister-port` and compiles the
same machine RTL; differences are called out under **MiSTer** headings.

**Branch context.** This document was written against `origin/tas-atomic` at BUILD 109
(`BUILD_ID = 16'h3109`). BUILD 109 is an **A/B evaluation build**, not the shipping
configuration: `core_top.v:2710-2712` passes `.VSHAD3_EN(0)` where the entity default
is 1. Read the instantiation, never the generic default (§3.3).

---

## 0. The machine in one picture

```
   APF data slot (Pocket)              .mra + ioctl (MiSTer)
   atari_escape.rom, 0x220000 B        same 0x220000 stream, repacked in RTL
                │                                  │
                ▼                                  ▼
     ┌──────────────────┐  ┌──────────────┐   ┌──────────────────────┐
     │      SDRAM       │  │ CRAM0 PSRAM  │   │   one shared SDRAM   │
     │ program ROM      │  │ gfx assets   │   │   (everything)       │
     │ + MO gfx         │  │ (playfield)  │   └──────────────────────┘
     └────────┬─────────┘  └──────┬───────┘
              │                   │
   ┌──────────┴───────────┐       │
   │ BRAM ROM shadows     │       │
   │ + speculative        │       │
   │   fastpath           │       │
   └──┬────────────────┬──┘       │
      ▼                ▼          │
 ┌──────────┐   ┌────────────┐    │      escape_mob ── gfx (SDRAM) ─┐
 │  video   │   │   world    │    └───── playfield  ── gfx (CRAM) ──┤
 │  68000   │◄─►│   68000    │           alpha      ── chr_ram BRAM ┤
 │ (vcpu)   │SR │  (ecpu)    │                                       │
 └────┬─────┘   └────────────┘        escape_prio ◄──────────────────┘
      │  SR = shared_ram 0x160000-0x16FFFF                │
      │       true dual-port + TAS interlock              ▼
      │                                          alpha overlay
      │                                                   ▼
      │                                          escape_stain (|0x400)
      │                                                   ▼
      │                                     color_ram ─► IRGB ─► APF video
      ▼
 SCOM serial link ──► escape_jsa (6502 + YM2151 + TMS5220) ──► APF audio
```

Every box below expands one part of that picture.

---

## 1. Clocks

One PLL, `mf_pllbase` (`src/fpga/core/mf_pllbase/mf_pllbase_0002.v`), reference
74.25 MHz, instantiated as `mp1` at `core_top.v:707-717`. Its outputs are the whole
clocking story:

| Output | Frequency | Phase | Net | Role |
|---|---|---|---|---|
| `outclk_0` | **7.159091 MHz** | 0 ps | `clk_sys_7159` | 68000s, pixel clock, JSA parent, `video_rgb_clock` |
| `outclk_1` | 7.159091 MHz | 34,920 ps (+90°) | `clk_sys_7159_90deg` | `video_rgb_clock_90` |
| `outclk_2` | **35.795455 MHz** | 0 ps | `clk_sdram` | memory service domain |
| `outclk_3` | 35.795455 MHz | 6,984 ps (+90°) | `clk_sdram_chip` | `dram_clk` pin |
| `outclk_4` | 28.636364 MHz | 0 ps | — | **not connected** |

7.159091 MHz is the board's real 68000 and pixel clock: 14.31818 MHz ÷ 2, the NTSC
colourburst family the arcade board is built on. The memory domain is therefore
**exactly 5:1**:

```
35.795455 / 7.159091 = 5.000000     periods 27.9366 ns vs 139.68 ns
```

Both 90° shifts check out as exact quarter-periods. The `clk_sdram_chip` shift is the
v45 capture fix — at 180° the controller served words from the wrong row.

There is **no separate video clock**; video runs on `clk_sys_7159`.

> ### Do not trust comments about the SDRAM clock
>
> For most of this project's life, a set of comments, one PSRAM parameter and one
> refresh threshold all asserted `clk_sdram` was **85.909 MHz** at a **12:1** ratio.
> It never was. The *data* uses were corrected in BUILD 106 (`6596423`), but that
> commit's claim to have corrected everything is not true of the tree today:
>
> | Site | Says | Status |
> |---|---|---|
> | `core_constraints.sdc:4-5` | "85.909MHz = exactly 12 x 7.159MHz" | **FIXED (REFRESH-111)** — now "35.795455MHz = exactly 5 x 7.159091MHz". The constraint itself was always fine (`derive_pll_clocks`); only the justification was wrong |
> | `sdram_simple.v:3` | "28.636 MHz SDRAM domain (4x CPU)" | **FIXED (REFRESH-111)** — a *third* wrong figure for this clock, which the `85.909` greps could never have found |
> | `sdram_simple.v:151-156` | argues from "250-clk interval = 2.9us" | **FIXED (REFRESH-111)** — and the replacement arithmetic was wrong too; see §"the refresh constant" below |
> | `core_top.v:1280` (now `:1309`) | "one clk_sdram cycle (11.6ns)" | **FIXED (REFRESH-111)** — 27.94 ns |
> | `escape_core.vhd:100,105,655,657`; `escape_mob.v:69,275` | "85.9MHz domain" | **stale comments only** — not yet swept |
> | `sim/tb/tb_pf_cram.v:6,25,101` | `psram #(.CLOCK_SPEED(85.909))`, "the real 12:1 clock ratio" | **FIXED (PFCLK-111)** — parameter, simulated clock and ratio all corrected together (fixing only the parameter would have produced `run_psram_tb.sh`'s *negative control*). But see the warning header now in that file: **the bench has never passed for unrelated reasons**, so it was never validating the 7-cycle machine either. |
> | `sim/tb/tb_mob_perf.v:30` | "10 clocks at 85.909MHz = 116ns" | **FIXED (PERFDIV-111)** — 279 ns, and the conclusion it supported inverts: the comment used it to argue MO port occupancy is "well under ONE pixel clock", when 279 ns is **two** pixel clocks |
> | `src/mister/rtl/pll.v:7-8` | "57.272727 MHz SDRAM" | **stale** — residue of a reverted 8:1 draft. Not on this branch. |
>
> Authoritative sites: the PLL file above, `core_top.v:1080-1087` (CLKFIX-106) and
> `sdram_simple.v:110-118`. `sim/tb/tb_psram_timing.v` exists specifically to catch
> this class of error, and carries two separate knobs (`DECLARED_CLOCK_MHZ`,
> `ACTUAL_CLOCK_MHZ`) so a mismatch is a test case rather than a silent property.
> The story is in [`RETROSPECTIVE.md`](RETROSPECTIVE.md) §5.

### Frame rate

The raster free-runs. There is no frame buffer and no frame pacing anywhere in the
design; the APF scaler consumes whatever the core emits.

```
7,159,090 / (456 × 262) = 59.9227 Hz              DEVIATIONS.md §E, "exact"
```

The game's logic-frame budget is **119,318 68000 clocks = 16,688.15 µs**;
`PERF_CADENCE.md` measures the original against exactly that number.

**MiSTer** uses its own PLL (`src/mister/rtl/pll/pll_0002.v`, reference 50.0 MHz)
producing 7.159091 / 35.795455 / 35.795455+90° — the same three clocks. `hps_io` is
deliberately clocked from `clk_ram` so the whole download path is single-domain
(`Arcade-Escape.sv:240`).

---

## 2. ROM delivery

### 2.1 What the user supplies

A verified MAME `eprom` set — 28 chips, all CRC32-checked. **No ROM data is in this
repository and none is downloaded.** On the Pocket the user runs, once:

```bash
python3 support/build_rom.py /path/to/eprom.zip ./atari_escape.rom
```

`support/build_rom.py` takes a directory of `136069-*.xxx` dumps or a standard
`eprom.zip`, verifies every chip against the CRC table at `build_rom.py:26-37`, and
refuses to build on any mismatch. Output is one flat image of **2,228,224 bytes
(0x220000)**:

| Offset | Size | Region | Form |
|---|---|---|---|
| `0x000000` | 512 KB | `maincpu` — video-CPU program | 16-bit big-endian, byte-interleaved |
| `0x080000` | 512 KB | `extra` — world-CPU program, + shared program copy at `+0x60000` | ditto |
| `0x100000` | 64 KB | JSA 6502 program **and** TMS5220 LPC speech data | flat bytes |
| `0x110000` | 16 KB | `chars` — alphanumerics tiles | as dumped |
| `0x120000` | 1024 KB | `spr_tiles` — motion-object graphics | **inverted and repacked** (§2.2) |

Interleave (`build_rom.py:60-64`): even byte = the `.50x` chip (D15–D8), odd byte =
the `.40x` chip (D7–D0). The `0x060000` pair is the documented exception — there
`.40k` is the even byte (`build_rom.py:67`, `ROMMAP.md:8-9`).

### 2.2 The bitplane-to-chunky repack, and `ROMREGION_INVERT`

This is the one genuinely non-obvious transform in the delivery path, and the reason
the MiSTer port cannot use a stock `.mra` alone.

MAME declares the sprite region `ROMREGION_INVERT`, so every byte is bitwise
complemented after loading. The 16 sprite chips are then `RGN_FRAC(1,4)` **four
bitplanes**, each a contiguous 256 KB bank, plane 0 the most significant pen bit. A
pixel's 4-bit pen is assembled from one bit in each of four bytes 256 KB apart.

That layout is hostile to a line engine. A tile row is 8 pixels; fetching it planar
costs **four** reads at four widely separated addresses — four arbitration rounds and
four row activations on a shared memory. So the transposition is done **once, offline**
(`build_rom.py:105-125`):

```
inv = bytes(b ^ 0xFF for b in range(256))          # ROMREGION_INVERT, :109
for i in 0 .. 256K-1:                              # i = tile*8 + row
    b0,b1,b2,b3 = planar[i], planar[256K+i], planar[512K+i], planar[768K+i]
    emit 4 bytes: [px0|px1] [px2|px3] [px4|px5] [px6|px7]     # plane0 = MSB
```

**The result is the contract the whole sprite engine is built on: one tile row = 4
consecutive bytes = a single 32-bit fetch.** `escape_mob`'s fetch channels are 32 bits
wide and one channel transaction yields exactly one 8-pixel tile row. Every per-tile
cost figure in §5.4 assumes it.

Note that honouring `ROMREGION_INVERT` at all is a choice, not a hardware property.
`MISTER.md:127-144` states it plainly: it is a MAME `gfxdecode` convenience, and
schematic-accurate cores usually ignore it — but this project's engines were written
against the MAME-decoded form, so it follows MAME here.

**Why an `.mra` cannot express this.** MRA's ROM assembly language is *byte* granular:
concatenate parts, map byte lanes with `interleave`/`map`, fill, patch at byte offsets.
It has no operator for a bitwise complement of a region and none for a bit-level
transposition gathering one bit from each of four bytes a quarter of a megabyte apart.
Both halves of the repack are below MRA's resolution. The MRA itself says so
(`src/mister/releases/…mra`, comment block lines 14-38): *MRA has no primitive for
either operation, and the planar to chunky repack is not expressible as an interleave.*

### 2.3 Pocket: APF data slots into memory

`data.json` declares exactly two slots:

| id | name | file | bridge address | size | required |
|---|---|---|---|---|---|
| 1 | `ROM` | `atari_escape.rom` | `0x10000000` | image is 0x220000 | **yes** |
| 2 | `EEPROM` | `atari_escape.sav` | `0x20000000` | 512, nonvolatile | no |

The APF streams the file over the bridge as 32-bit writes, captured in the `clk_74a`
domain (`core_top.v:734-744`: `dl_addr_74`, `dl_data_74`, `dl_req_74` toggle,
`dl_quiet_ctr`) and crossed into `clk_sdram` by `synch_3 s_dl` (`:850`).

The loader is `dl_phase` (`core_top.v:1005`, FSM at `:1022-1066`): phase 0 latches
address/data and raises `sd_wr_req` (one bridge word = one two-word SDRAM burst);
phase 1 waits `sd_wr_ack`; phase 2 holds until the CRAM mirror queue has drained
(`cq_bp_ok = cq_n <= 4'd2`).

Two things happen **off the same grant**, which is what makes them incapable of
disagreeing with SDRAM:

- **BRAM shadows are filled from the download stream** — `shad_waddr`/`shad_wdata`/
  `shad_we` driven at `core_top.v:1044-1049`, word 1 on the following cycle via
  `shad_second`. Not copied back later from SDRAM.
- **Everything at image offset ≥ `0x110000` (chars + sprites) is mirrored into CRAM0**
  by snooping the same write port (`core_top.v:1343-1373`), through an 8-entry queue
  `cq_addr`/`cq_data`. CRAM word address = `sd_wr_addr[22:1] - 22'h88000`, i.e. image
  byte `0x110000` → CRAM word 0.

**Loading is done when the core says so, not when a timer says so.** `core_reset_n`
(`core_top.v:1783-1784`) is the AND of: `dataslot_allcomplete` from the APF host
command `0x008F`; `sdram_init_done` from the controller; `ee_ready_c` from `ee_save`;
and `chk_done` — the end of a self-check FSM (`chk_state`, `core_top.v:1375-1673`)
that probes three known image words (`0x000000` must read `16'h003F`, the high word
of the reset SP; `0x110400`; `0x110410` must read `16'h3388`) and then DMAs the 8192
char-ROM words into on-FPGA `chr_ram`. `dl_quiet_74` (`:845`) additionally requires
~56 ms of silence after the last download write. The diag strip at
`core_top.v:602-625` renders each of these as a coloured cell, so a stuck boot names
its own gate.

### 2.4 MiSTer: `.mra` + `ioctl`, repack in RTL

The framework hands the core a byte stream through the standard
`ioctl_download`/`ioctl_wr`/`ioctl_addr`/`ioctl_dout` interface, assembled by the MRA
loader from the user's `eprom.zip`. The `.mra` does the 68000 byte interleave
(`<interleave output="16">`, `map="01"` = MAME's even address = D15–D8) and delivers
the four sprite planes byte-adjacent via `<interleave output="32">`.

The **loader RTL finishes the job**, unbuffered, in the `SPRITE REPACK` block of
`src/mister/rtl/escape_mister.v:228-249`:

```verilog
wire [7:0]  iv0 = ~dlb0, iv1 = ~dlb1, iv2 = ~dlb2, iv3 = ~ioctl_dout;   // the INVERT
wire [31:0] spr_word = { chunky2(...,3'd0), chunky2(...,3'd2),
                         chunky2(...,3'd4), chunky2(...,3'd6) };
wire        in_spr   = (ioctl_addr >= SPR_BASE);        // SPR_BASE = 25'h0120000
```

**The two platforms' SDRAM contents are identical and this was verified rather than
argued**: the `.mra` was assembled with `sebdel/mra-tools-c` against a real
`eprom.zip`, the loader transform replayed offline, and the result compared to
`build_rom.py`'s image — byte-for-byte identical across all `0x220000` bytes
(`MISTER.md:165-171`). The *download stream* differs and cannot not differ.

Backpressure is `ioctl_wait = ~pll_locked | dl_pending` (`:280`). One hazard is worth
knowing: `dl_pending` is deliberately **not** cleared when `ioctl_download` drops,
because hps_io deasserts it while the last byte group is still queued; clearing there
would silently drop the final four bytes of the image (`:266-273`). Done detection is
correspondingly exact — `rom_ready = sdram_init_done_s & chk_done_s & dl_idle_s`
(`:160-170`) — with no equivalent of the Pocket's 56 ms quiet timer, because the
MiSTer download is single-domain.

There is deliberately **no `eprom2` MRA**: set 2 loads an extra `maincpu` pair at
region `0x80000` for which the packed image has no room.

---

## 3. Memory hierarchy and arbitration

### 3.1 What the board had, and why that is the whole problem

The real Escape board has roughly a dozen **independent, zero-wait** memories:
dedicated program EPROMs per CPU, private playfield and alpha VRAMs, motion-object RAM
on its own bus, sprite line buffers on theirs. Nothing arbitrates against anything
else and a fetch costs about 4 clocks, always.

This core funnels all of it through one SDRAM, one PSRAM and a block-RAM budget that
is fully spent. **That substitution — not the CPUs, not the sound chips — is the
design.** Roughly three-quarters of the project's builds went into it
([`LESSONS.md`](LESSONS.md)). Two consequences are structural and permanent:

- **Memory speed is part of the machine.** The game's frame architecture assumes
  ~4-clock fetches. Starving it does not produce a memory error; it produces behaviour
  that looks like a logic bug (v58, `HISTORY.md` Era 3).
- **Neither reference models it.** MAME's arrays are perfect and time-free; the
  schematic solved the problem with more chips. Every arbitration bug here had to be
  found against instruments the core carries itself.

### 3.2 The memories

**Pocket.**

| Memory | Part / size | Domain | Serves |
|---|---|---|---|
| SDRAM | `MT48LC16M16A2`-class, 512 Mbit ×16 (2.2 MB used) | `clk_sdram` | program ROM for both 68000s, **motion-object graphics**, boot probes, char DMA |
| CRAM0 (cellular PSRAM) | 8 MB, own bus | `clk_sdram` | **playfield graphics**, download mirror, forensics |
| CRAM1 | — | — | **entirely tied off** (`core_top.v:266-276`) |
| SRAM (1 Mbit) | — | — | **unused**, tied off (`core_top.v:280-285`) |
| M10K block RAM | **308 blocks, all of them** | `clk_sys_7159` | line buffers, ROM shadows, char ROM, and every game RAM |

The two external buses are genuinely separate, which is the point: it is the closest
available approximation to the PCB's own topology. This was the `cram-gfx` contender
in [`BAKEOFF.md`](BAKEOFF.md), and it won. Note that motion objects were *moved off*
CRAM onto SDRAM later (`core_top.v:1532-1533`) — CRAM now belongs to the playfield.

On-FPGA memories in `escape_core.vhd` (all ×16 bits):

| Instance | Line | Size | Purpose |
|---|---|---|---|
| `shared_ram` | `:908` | 64 KB | inter-CPU shared RAM `0x160000-0x16FFFF` |
| `pf_ram` | `:1304` | 8 KB | playfield picture RAM |
| `mo_ram` | `:1310` | 8 KB | motion-object RAM |
| `work_ram` | `:1316` | 16 KB | working RAM |
| `pfpal_ram` | `:1319` | 8 KB | playfield palette RAM |
| `color_ram` | `:1325` | 4 KB | 2048-entry colour RAM |
| `cfg_ram` | `:1331` | 256 B | scroll + MOB config + SLIP pointers |
| `ee_ram` | `:1343` | 512 B | the 2804 EEPROM (`initbyte => x"FF"` — virgin EEPROMs read FF) |
| `alpha_ram` | `:1466` | 4 KB | alphanumerics RAM |

> **The M10K ceiling is a hard design constraint, not a budget.** The design uses
> 308/308. Any newly inferred block RAM — however small — fails the fit with Quartus
> Error 170048; builds 72/72b/72c and 103 all died this way. The fix is normally to
> move the array to a different resource class (`attribute ramstyle ... is "MLAB"`,
> ALM-based LUTRAM), not to shrink it — as the flight-recorder ring does
> (`escape_core.vhd:454-455`). Anything added to the pixel pipeline must be registers
> or MLAB, and `escape_mob.v` says so at almost every declaration. Note also that MLAB
> power-up contents are not guaranteed (Warning 170052), so check whether anything
> depends on an array's initial value before relocating it.

**MiSTer.** One SDRAM bus, no PSRAM, and the `psram.sv` path is not in the project
file list at all. The playfield graphics channel moved onto the SDRAM arbiter beside
the motion objects, where the two share the lowest priority tier round-robin
(`escape_mister.v:21-27`). The arbiter therefore carries strictly more traffic than
the Pocket's.

### 3.3 ROM shadows

*Deviation A3.* Blocks of the hottest 68000 code are mirrored into dual-clock BRAM
during download so instruction fetch does not touch SDRAM:

| Instance | Size | Image range |
|---|---|---|
| `vshad` | 16 KB | `0x000000-0x003FFF` |
| `vshad2` | 32 KB | `0x048000-0x04FFFF` |
| `vshad3` (generate-guarded) | 32 KB | `0x050000-0x057FFF` |
| `eshad` | 16 KB | `0x080000-0x083FFF` |
| `eshad2` | 4 KB | `0x08F000-0x08FFFF` |
| `jshad` | 64 KB | `0x100000-0x10FFFF` — the whole JSA 6502 ROM |

Coverage was chosen from MAME page profiles, not guessed: `vshad3` was sized off
"profiled pages 0x53000 14% + 0x56000 17%" (commit `aca5510`). Today the video CPU has
~80 KB shadowed and the world CPU ~20 KB.

The **intended** property is "a shadowed fetch never waits". The **measured** property
is that a shadow fetch costs **5.015 core clocks per bus cycle** and a fastpath hit
costs **4.015** (`sim/run_busrate.sh`, `VSHAD3.md` §1). On a machine that also has the
fastpath, a shadow now *costs* the CPU a clock on its hottest code — and `v_shad_rng`
suppresses the fastpath on exactly those addresses, so it cannot win the clock back
(`escape_core.vhd:662-670`).

`escape_core.vhd:22-32` states the inversion precisely: the shadow was added when the
only alternative was the legacy 15–25 clock arbiter; the fastpath landed two days
later and inverted the premise. This is the entire motivation for BUILD 109. **Do not
describe the shadows as "zero-wait"** — `README.md` still does, and it is wrong.

`jshad` is a different case and remains unambiguously right: the JSA 6502 fetched every
opcode over the marginal SDRAM path until v63, and one corrupt fetch derailed it into
RAM — phantom credits, dead coins, intermittent sound. It now fetches entirely from
BRAM and **is not an SDRAM client at all** (`escape_core.vhd:494-499`, `:1422-1425`).

### 3.4 The speculative fastpath

*Deviation A4 — no hardware equivalent whatsoever.* `FASTPATH_EN` (`core_top.v:1184`),
`fast_v_spec`/`fast_e_spec` in `escape_core.vhd`. Each CPU gets a **one-word read
cache** filled *speculatively* from the live 7.159 MHz bus: `escape_core` exports the
CPU's image address plus a raw ROM-region decode **with no `as_n`**, because the TG68K
kernel presents the next fetch address a full CPU clock before AS falls. The armored
SDRAM read therefore completes before the first post-AS CPU edge, and DTACK lands at
the authentic 4-clock phase.

Two properties make it safe rather than reckless:

- ROM is read-only, so a speculative read can have no side effects.
- `ready` is tag-compared against the CPU's *current* address every `clk_sdram` cycle
  (`fpv_ready_q`, `core_top.v:1210-1213`), so a stale serve is structurally impossible.
- The legacy `rom_req` arbiter still serves any cycle the fastpath leaves un-ready for
  16 clocks — a never-wedge fallback (`escape_core.vhd:39-46`).

Its cost curve is measured, and it is not flat (`VSHAD3.md` §1):

| fill latency | clocks per bus cycle |
|---|---|
| 1 clk | **4.015** |
| 2 clk | 5.015 (= the shadow) |
| 3 clk | 6.015 |
| 4 clk | 7.015 |
| 6 clk | 9.015 |

The fastpath beats the shadow **only while fills land inside one core clock**; past two
clocks it is worse than the thing it replaced. Since `fast_v_spec` fires on essentially
every non-shadow ROM address, anything that raises SDRAM occupancy — including removing
a shadow — moves the design along that curve. Two independent cross-checks against
hardware bus-cycle counts, on CPUs with very different shadow fractions (61% vs 37%),
both solve to c = 4.0, which is good evidence the device sits on the top row today
(`VSHAD3.md` §2).

> One live intent-vs-code hazard: the comment block at `core_top.v:1178-1183` is the
> BISECT-93 note explaining why the fastpath was turned **off**, and the very next line
> is `localparam FASTPATH_EN = 1;` turning it back on ("95: back ON, now with authentic
> SCOM link timing"). Read the parameter.

### 3.5 Arbitration

Both arbiters live in the single `always @(posedge clk_sdram)` block at
`core_top.v:1339-1692`, and both are **strict-priority if/else chains** so that at most
one grant can fire per clock. That is not stylistic: two grant arms firing on one edge
is the v14–v19 bug, where sprite pixels were served to a CPU as instructions. The same
discipline is re-applied inside `escape_mob.v`, where four separate fetch issuers were
collapsed into one issue port (`escape_mob.v:537-546`).

**SDRAM clients, highest priority first:**

| # | Client | Signals | Notes |
|---|---|---|---|
| 1 | Refresh | `refresh_ctr`, `refresh_age` | non-negotiable; *deviation A2* — no analogue on the board at all |
| 2 | CPU fastpath fills | `fpv_want`/`fpe_want`, `fpv_owner`/`fpe_owner` | one if/else chain, alternating on `fp_last_v` |
| 3 | Legacy CPU ROM fetch | `core_rom_req_s`, `cpu_owner` | never-wedge fallback; the only CPU client when `FASTPATH_EN=0` |
| 4 | **Motion objects — lowest** | `mo_pend_q`, `mo_nch_q`, `mo_naddr_q`, `mo_owner` | 4 channels, registered pre-decode |

**CRAM clients, highest priority first** (`core_top.v:1442-1444`, 1469-1503):
download-mirror drain → **playfield** (channel A before B) → *(MO — retired)* →
CRAM self-test. "Every CRAM start goes through ONE strict-priority chain … so no two
clients can ever collide by construction."

The JSA 6502 appears in neither list: it is served from `jshad` (§3.3).

**MiSTer** collapses these into one chain: fastpath fills → legacy CPU fetch →
`{PF, MO}` round-robin on a `vid_last_pf` token (`escape_mister.v:565-592`).

Two properties are load-bearing:

- **MO being last is deliberate.** A late MO fetch degrades one sprite for one line; a
  late CPU fetch degrades the game's whole cadence. It is also why every estimate of MO
  bandwidth is fragile: `core_top.v:1630-1632` budgets for "both CPUs streaming
  fetches" and estimates MO keeps ≥40% of the bus — an **estimate, not a measurement**,
  and the stated reason BUILD 109 is an A/B rather than a merge.
- **The MO pre-decode trades latency for depth.** `mo_pend_q`/`mo_nch_q`/`mo_naddr_q`
  (`core_top.v:1291-1307`) are registered so the shared grant tests one flop bit rather
  than a widening OR of per-channel comparators, at a cost of one `clk_sdram` cycle
  (27.94 ns) of arbitration latency per MO fetch.

**Refresh is not free, and was recently out of spec.** Before BUILD 106 the threshold
was derived from the wrong clock constant:

```
250 clk / 35.795455 MHz              = 6.984 us typical
+ the SDSCHED-88 deferral (48 clk)   = 8.325 us worst case
MT48LC16M16A2 requirement            = 7.8125 us          ->  6.6% OVER
```

That is a genuine JEDEC retention violation on the memory holding sprite graphics and
CPU RAM. The threshold is now **160** (4.47 µs typical, 5.81 µs worst — 26% under
spec) at a cost of 14 refreshes per line instead of 9; occupancy rose 4.4% → 6.9%.
**Measured cost to the CPUs: none detectable** — BUILD 107's bus-cycle counts reproduce
BUILD 106's to −0.1% / +0.8% (`GFX_DASH_ARTIFACT.md` §8). There is no case for
reverting it.

> **RECONCILED (REFRESH-111): one policy, `REFRESH_INTERVAL=160`, `DEFER_CAP=48`,
> both platforms.** The three branches disagreed — `tas-atomic` 160, `mister-port`
> 224 with the deferral intact, `sdram-sched` 250 with the deferral deleted — and
> **all three justifications were hand arithmetic that was wrong the same way.**
> Every one assumed `worst = INTERVAL + DEFER_CAP`; measured against the real FSM
> it is `INTERVAL + DEFER_CAP + 16`, the extra clocks being the transaction still
> in flight when the cap expires (`refresh_due` is only consumed from `S_IDLE`).
>
> That correction convicts `mister-port`: its 224 does **not** land at the 7.599 µs
> its comment claims, it lands at a measured **8.046 µs — still out of spec**, on
> the platform whose playfield also shares this bus. The interval and the deferral
> cap are now module **parameters** on `sdram_simple`, so the platforms cannot
> silently disagree again. Full measurements, the trade-off table and the
> bandwidth accounting: [`DEVIATIONS.md`](DEVIATIONS.md) §F1. Gate:
> `sim/run_sdram_refresh_tb.sh`, which carries the original 250/48 **and**
> `mister-port`'s 224/48 as negative controls that must both be reported FAIL.

---

## 4. The two CPUs

### 4.1 Who they are

Both are `entity work.TG68K generic map (CPU => "00")` — **68000 mode**. The schematic
labels them U68010 (sheets 4 and 5) but production boards carry MC68000s, verified from
a real board; this is the one recorded case where MAME beats the schematic
(`DEVIATIONS.md` §C5). Exception frames differ, so it matters.

| | video / main CPU | world / extra CPU |
|---|---|---|
| Instance | `vcpu`, `escape_core.vhd:589` | `ecpu`, `escape_core.vhd:598` |
| Bus | `v_addr`, `v_as_n`, `v_uds_n`, `v_lds_n`, `v_rw_n`, `v_dtack_n`, `v_fc`, `v_ipl`, `v_vpa_n`, `v_lock` | `e_*` equivalents |
| Reset / halt | `reset_n` | `e_resn <= reset_n and (extra_release or dbg_force_extra)` |
| Decoder | `vdec` — all 15 selects used | `edec` — only `sel_rom` / `sel_ram` used |

Each CPU consumes a **registered** copy of read data (`v_di_r`/`e_di_r`, produced by
`di_capture` at `escape_core.vhd:2150-2156`).

**Ownership is heavily asymmetric.** The video CPU owns the video registers, all video
RAMs, work RAM, the EEPROM, the watchdog, the JSA link, scroll, and the world CPU's
run/halt latch. The world CPU owns nothing but shared RAM and read-only I/O. Its ROM
fetches are re-based into the combined image as
`addr + 0x080000` (`escape_core.vhd:673-674`).

Two deliberate exceptions:

- The **ADC start strobe fires on either CPU's read**, with the extra winning the
  channel-latch tie (`:1936-1955`) — the gameplay engine runs on the extra 68000 and
  polls the analog stick itself.
- The **vblank ack at `0x360000` is honoured from either CPU** (`:1864-1868`) — see
  §4.4.

The world CPU's run/halt latch is `0x360011` bit D0, decoded to that **exact byte under
LDS** (`escape_core.vhd:1887-1896`). The previous 16-byte-wide decode was the mid-game
restart bug: restart count 0x10 by mid-game against MAME's 2-at-boot. The same byte
carries `intensity <= v_do(4 downto 1)` and `video_off <= v_do(5)`.

**SLAPSTIC is not implemented, deliberately.** The part is physically present on the
board (sheet 4, 60E `SLAPSTK5`) but the shipped code never banks through it: MAME's
`eprom` driver instantiates none, the game flat-references the whole address space, the
decode PALs contain no bank multiplexer, and the game's own service-mode ROM checksum
screen matches MAME byte-for-byte. Full argument in [`SLAPSTIC.md`](SLAPSTIC.md).
`ARCHITECTURE.md` still carries a stale pre-bring-up "likely unused — verify" note
alongside its own contradicting finding; read `SLAPSTIC.md`.

### 4.2 Shared RAM and the mailbox

`shared_ram` is `dpram_bytelane_syn` with `awidth => 15` — **true dual-port, 32768 ×
16 = 64 KB**, both ports on `clk`, registered reads, covering `0x160000-0x16FFFF`. Port
A is the video CPU, port B the world CPU. It carries a cross-port same-address
collision bypass (SDSCHED-82b) because real arcade VRAM returned old data on a
collision, where undefined reads gave location-locked garble.

The game's own handshake convention, snooped by `mbox_snoop`
(`escape_core.vhd:1094-1110`):

| Address | Meaning |
|---|---|
| `0x16FFE0` | video → world command (`1234` boot, `5A5A` runtime) |
| `0x16FFE2` | world → video answer (`4321` = self-test done) |
| `0x16FFE8` | world RAM-test result (`0000` = pass) |
| `0x16FFEA` | world ROM checksum word |

`mbox_ledger` counts `5A5A` commands against `4321` acks and latches a deadlock flag if
one goes unanswered for ~4.7 s.

Three further game-known addresses the RTL decodes, and one important correction:

- **`$16CCD4`** (video) and **`$16CCD6`** (world) are the vblank ISR's re-entrancy
  flags. A `$50` byte write starts a logic frame, `$00` ends it. `cadence_meter`
  (`escape_core.vhd:1186-1234`) counts those `$50` writes over 256 video frames and
  reports them on HUD page 5 — the only speed number this core produces that is not a
  proxy. `0100` hex **is** 1.0000 logic updates per video frame.
- `$16CCD6` doubles as the world CPU's wake flag for the `EIRQ_MODE=2` arming detector.
- **`$16C990` / `$16C992` are NOT usable as cadence counters.** They are incremented
  *before* the already-running gate, so they count ISR entries — i.e. video frames —
  and would read a flat 1.0000 even on a core missing every other deadline.
  `PERF_CADENCE.md` §4 still recommends reading them and asserts the core "can already
  read" them; both halves are wrong, and nothing read either address before the cadence
  meter existed. `VSHAD3.md` §6 is the correct account.

*Deviation B1.* On the board this memory is **two single-ported SRAMs behind one
`/AS`-level ownership mux** (EWAI / PAL16L8 50P, sheet 5 designators 40M/50M/30M), and
the loser is held in wait states. Replacing that with true dual-port BRAM is
functionally equivalent for every ordinary access and silently deletes one property —
see §4.3.

The board's single arbitrated bus also means its two 68000s can never run without ever
stalling each other. Ours can, and a fixed timing relationship between them could
persist indefinitely, so `e_bus_yield` makes the extra CPU yield one cycle when the
video CPU is using shared RAM in the same cycle (BUS-99, `escape_core.vhd:2231-2248`).

### 4.3 The TAS interlock — read-modify-write atomicity

**The problem.** The 68000's `TAS` is an indivisible read-modify-write: `/AS` stays
asserted across both cycles (M68000UM Rev 9 §5.1.3). TG68K decodes TAS through the
ordinary MOVE path, writes bit 7 back unconditionally, and **has no bus-lock output**,
so it issues two `/AS`-separated bus cycles. Measured on the real RTL: the
read-modify-write is **13 clocks wide, with `/AS` HIGH for 3 of them**. That 3-clock
gap is the entire bug, as a number.

The board is immune because its shared RAM is single-ported behind the mux — atomicity
was a property of the **memory fabric**, not of a lock signal. Ours is not. A `clr.b`
release landing in the gap is overwritten with `$80`: the mutex ends up **set with no
owner**, and every later acquirer on both CPUs spins forever. That is the freeze.

**The mechanism.** The kernel's existing `exec_write_back` is exported as a real `LOCK`
output from the vendored TG68K (`TG68KdotC_Kernel.vhd:489`,
`lock_rmw <= '1' WHEN exec_write_back='1'`), and `escape_core` serialises the other
port off that exact byte for the duration. It is a two-state window, not a multi-state
FSM (`escape_core.vhd:1007-1089`):

- **OPEN** when `tl_owner = "00"` and the owner's `LOCK` is up on a stable shared-RAM
  address. The video CPU is tested first, so it wins a same-clock tie — matching the
  board, where it owns the bus by default because it drives the run/halt latch.
  Latches `tl_addr` (the word), `tl_lane` (the byte lanes), `tl_ttl <= 63`.
- **HOLD** the *other* CPU when it addresses the exact word `tl_addr` with an
  overlapping lane. Both hold conditions depend only on registered window state, so
  there is no combinational path from one CPU's DTACK to the other's.
- **CLOSE** when the owner's `LOCK` drops, or on `tl_ttl` expiry, which additionally
  sets `tl_v_inh`/`tl_e_inh` so a stuck LOCK costs the peer one window and never
  another.

**Both halves of the enforcement are required.** DTACK alone is not enough, because
`we_shr_a`/`we_shr_b` assert on *every clock* of a stalled cycle by design — so a
DTACK-stalled write strobe keeps re-writing the byte. The interlock therefore gates the
write strobe *and* DTACK (`escape_core.vhd:890-901`).

**Bounded by construction.** Any bus cycle can be delayed by at most `TL_TTL_MAX+1` =
64 clocks = 8.9 µs at 7.159 MHz — roughly 1900× shorter than a frame. Proven by
`sim/tb/tb_escape_taswedge.vhd`, which forces a permanently stuck LOCK with a bound of
66 clocks and shows neither CPU can be starved.

**Scope** is deliberately the whole shared RAM, keyed on the address being modified, so
every mutex the game uses is covered with no address table to maintain.

`TASLOCK_EN` (`core_top.v:1190`, shipped `1`) selects: `0` = off (pre-102 baseline,
prunes entirely), `1` = ship, `2` = **DTACK-only, a bench diagnostic that is
deliberately broken; never ship it**. Mode 2 exists to keep the counter-example
executable — see `RETROSPECTIVE.md` §2 for why that matters more than it sounds.

**The fix carries its own proof.** `dbg_tas_cnt` and `dbg_tas_addr` (HUD page 2) are
saturating counters of the bus cycles the interlock actually held off, plus the first
colliding address. They are deliberately **not** cleared on reset so the owner can
photograph them after a session that included a watchdog reboot. Freezes stopping with
a non-zero count means the mechanism was confirmed and cured in one session; freezes
stopping with a zero count would mean the fix is not what helped.

### 4.4 Vblank and interrupts

`vblank_w` (`core_top.v:1794`) is simply "`y_count` outside the active window".

IPL, active-low into TG68K (`escape_core.vhd:610-623`):

```
v_ipl <= "001" when jsa_snd_irq='1'    -- /SINT = IRQ6, video CPU only
         "011" when v_virq='1"         -- vblank = IRQ4
         "111" otherwise
e_ipl <= "011" when e_virq='1' else "111"     -- world CPU: vblank IRQ4 only
```

Interrupts are **autovectored** — `VPA` asserted on FC=111 (schematic sheet 4, 60L/55L)
— and `dtack_gen` explicitly withholds DTACK on IACK so the autovector path is the only
one.

**What ships is the schematic-literal model.** `core_top.v:2710` passes
`.EIRQ_MODE(0)`: **one shared vblank latch**, cleared by either CPU's `0x360000`
access. Sheet 7 shows exactly one 60M LS74 flip-flop, whose CLR comes off a common-bus
decoder that cannot tell which CPU is driving. Modes 1 and 2 model a structure the
hardware does not have and are kept only for A/B.

> **Read the instantiation, not the generic default.** `escape_core.vhd`'s own default
> for `EIRQ_MODE` is 2. The comment at `core_top.v:2697-2704` records that a previous
> version of that very comment claimed mode 2 while the line passed 0. Anyone
> documenting this path from the VHDL alone will get it wrong.

The modes, and why they exist, are the compressed form of builds 86–92:

| Mode | Semantics | Failure it exhibits |
|---|---|---|
| 0 | shared pulse, cleared by the ack (~60–73 clk) | **lost wakeup**: the world CPU parks in a poll loop with a ~30-clock open IRQ window per ~60-clock pass; when that phase-locks against the ack, it misses every frame forever |
| 1 | held until the extra's IACK completes | **POST derail**: a stale pending vblank is delivered at the first unmask instant during the world CPU's multi-frame, IRQ-masked POST, whose ISR writes through RAM state only runtime init makes valid |
| 2 | mode 1 + arming: delivery arms only after two completed reads of `$16CCD6` within ~1K clocks with no intervening write — the runtime poll loop's unique access signature | (the fix for both) |

The constraints are genuinely in tension: the pulse must be **longer** than any masked
stretch of the runtime poll loop, and the pending must be **invisible** to a CPU not yet
in that loop. No fixed pulse length satisfies both against a deterministic lockstep
machine. Knowing when the world CPU is actually in its runtime loop satisfies both
exactly — at the cost of encoding a game-code address in hardware, which is flagged in
the generic's own comment as needing revisiting for the Klax/Guts variants.

A detail that cost three builds: the world CPU's *runtime* vblank ISR (ROM
`0x908-0x93C`) contains **no `36xxxx` store at all** — flight-recorder truth. It relies
on the main CPU's ack clearing the shared latch. Per-CPU latches that clear only on
their own ack therefore never clear, and storm.

**Watchdog:** a `0x2E0000` write clears `wdog_ctr`; 64 vblanks (~1.07 s) without a
strobe latches `wdog_expired_i`. Escape's exception vectors all route to a
die-and-let-watchdog-reboot `STOP`, so this is part of normal operation, not a
diagnostic.

---

## 5. The video pipeline

This is the heart of the core and the part with least in common with the original
silicon. The board scans out with dedicated chips on private buses; we rebuild each
line from RAM and two memory services, one line ahead of the beam.

> **Navigation note.** The video pipeline is **not** in `escape_core.vhd`. That file
> supplies only the video-port sides of the RAMs and the scroll/intensity registers.
> All raster timing, playfield fetch, alpha scanout, the compositor and the three
> Verilog module instantiations live in **`src/fpga/core/core_top.v`**.

### 5.1 Raster and timing budget

`core_top.v:514-519`:

```
VID_H_TOTAL = 456    VID_H_BPORCH = 60    VID_H_ACTIVE = 336
VID_V_TOTAL = 262    VID_V_BPORCH = 12    VID_V_ACTIVE = 240
```

`x_count`/`y_count` free-run over that grid at 7.159091 MHz (`core_top.v:523-524`,
`:555-563`); `visible_x`/`visible_y` are the back-porch-corrected coordinates
(`:526-527`). `vidout_vs` pulses at `(0,0)`, `vidout_hs` at `x_count == 3`.

There is **no `hblank` signal** in this design; `vblank_w` (`:1794`) is the only
blanking signal, and it is what drives §4.4.

One piece of wrap arithmetic is relied on downstream: `visible_x[8:0]` — which is
`disp_x` into the motion-object engine — sweeps **452..511 then 0..395** across a line,
because `x_count` 0..59 gives `visible_x = 964..1023`. The BUILD 108 self-clearing
readout depends on that sweep covering every writable column.

**The budget is 456 core clocks per scanline, and that is the entire budget.** Nothing
is borrowed from the next line: the motion-object engine restarts at every line
boundary. Everything in §5.4 exists to fit inside 456.

### 5.2 Playfield

A 64×64 tilemap. `core_top.v:2184-2363`.

**Scroll** is **frame-latched**, not applied immediately: writes to MOB-config RAM
stage into `xs_pend`/`ys_pend`, and `xscroll`/`yscroll` load from them on the vblank
rising edge (`escape_core.vhd:1821-1822`, `:1904-1909`).

**Address computation:**

```verilog
wire [8:0] pf_y  = visible_y[8:0] + yscroll;                        // :2192
wire [8:0] pf_x2 = vis_x[8:0] + 9'd16 + vpshift_s + xscroll;        // :2195
pf_vaddr <= {pf_x2[8:3], pf_y[8:3]};        // map col*64 + row     // :2233
gfx addr  = 24'h120000 + {pf_vdata[14:0], 5'd0} + {pf_y[2:0], 2'd0} // :2249
```

The map is **column-major** (MAME `SCAN_COLS`). The previous row-major read transposed
every lookup for 90-plus builds; symmetric tiles — borders, pillars — hid it (LANE3j,
`core_top.v:2227-2232`).

**Sources:** map from `pf_ram`, colour attribute from `pfpal_ram`, and tile **pixels
from CRAM**, not SDRAM (`cram_addr <= vg_addrA_px[22:1] - 22'h88000`). Two 16-bit CRAM
reads assemble one 32-bit tile row, `{cvg_hi, cram_dout}`. Format is 4bpp chunky, 8
pixels per 32-bit word, `pf_word[31:28]` = px0 through `pf_word[3:0]` = px7.

**Pipeline.** A cell-phase machine keyed on `vis_x[2:0]`: phase 0 presents the map
address, phase 3 enqueues the gfx fetch, phase 7 loads the show registers. The show
registers load at phase 7 — one pixel early — because loading at phase 0 left pixel 0
rendering the previous cell's word, giving 1-pixel vertical tears at every cell
boundary (LANE3k). Two fetch channels A/B, a four-slot request queue
(`pfq_addr0..3`, `pfq_count`), and a **slot-addressed ring** `pfring0..3` — the ring
replaced a shift pipe whose late completions landed in the next cell's slot. The
pipeline starts two lines before active video (`y_count >= VID_V_BPORCH - 2`) and
resyncs at `x_count == 0`.

**Horizontal fine scroll** (SDSCHED-84, `core_top.v:2340-2351`) selects between the
current and following cell on `pf_cross = pf_x2[2:0] < visible_x[2:0]`, and indexes
with the *scrolled* fine X. Before it, the sub-tile phase was dropped and all
horizontal motion quantised to 8-pixel tile lurches — a 60 fps device capture showed
dx = 0,0,…,+8 against MAME's smooth ±1..3.

**Two facts about this path are the ones that bite:**

- **The fetch/show handshake is mandatory.** For 68 builds there was none, so any late
  return displayed the previous cell's pixels — corruption that looked exactly like bad
  ROM data and survived a formal 2.2 MB scrubber sweep proving memory content innocent
  (v65, v68). With the handshake, plus a 3-cell prefetch (v69/v70), the attract demo
  ran for the first time.
- **The fetch channel must reset with the core.** On MiSTer the playfield rendered a
  flat fill because this channel had no reset: the pipeline free-ran during download,
  set `inflA` and `inflB`, and the reset resync then did `vg_req_last <= vg_req_s` —
  **retiring those pending edges without ever completing them**. The issue side
  requires `!inflA`/`!inflB`, so neither channel ever toggled again. Correct for motion
  objects, which zero their own toggles under reset; fatal here. Commit `dcd1196`
  (`PFRESET-107`), and `RETROSPECTIVE.md` §8. **A toggle-handshake channel with no
  reset is a latent wedge on every platform**; it only surfaced where the reset
  sequence differed.

### 5.3 Alpha (text) layer

A 64×31 tilemap in `alpha_ram` (`0x3F4000-0x3F4EFF`). `core_top.v:2404-2477`.

Character data lives in **on-FPGA `chr_ram`** (8192 × 16), DMA'd from image
`0x110000..0x113FFF` during boot (§2.3) — so the alpha layer never touches an external
memory at scanout, and never arbitrates. Address is `{code[9:0], visible_y[2:0]}`.

Pixels are **2bpp, planar-in-nibbles** (`core_top.v:2467-2472`). A cell is visible when
`pix != 0` or the entry's opaque bit is set; phases 4..7 prefetch the next cell.

**The alpha layer wins outright** over the MO/PF comparator result
(`core_top.v:2569`), because the reference draws it *after* the MO/PF merge. It is the
score line, the "Tap JUMP to speed up" banner and the attract text, and it is never
occluded by sprites.

It is also a standing trap for automated image analysis. Alpha-layer text is the third
thing — after the core's own hex debug bar and its status line — that a naive
"unexpected pixel" detector rediscovers; a stray-pixel scan on the killed-playfield
capture returned 1,496 "stray" pixels that were the game's own banner
(`GFX_DASH_ARTIFACT.md` §7). HUD rows must be excluded with margin: status 0–11, hex
bar 96–128, game HUD 192–239 — which is **38.8% of the frame** that all such detectors
are blind to.

### 5.4 The motion-object engine — `escape_mob.v`

`escape_mob` builds **the next scanline** into one of two line buffers while the display
side reads the other. Everything it does must fit in 456 clocks. Instantiated at
`core_top.v:2378-2402`.

#### Data structures

MO RAM (`0x3F2000-0x3F3FFF`) holds 4-word entries; SLIP pointers (cfg words
`0x40-0x7F`, CPU-visible at `0x3F4F80-0x3F4FFF`) name the head of each 8-line band's
list.

```
w0 = link[9:0]                                  -> next entry, singly linked
w1 = code[14:0]                                 -> tile code
w2 = color[3:0] | prio[6:4] | x[15:7]           -> MPR2:MPR0 live in [6:4]
w3 = y[15:7] | width[6:4] | height[2:0] | hflip[3]
```

Tiles walk row-major, `code + ty*width + tx`; palette base `0x100`.

The Y field is **negated and offset by the sprite height** — `atarimo` ground truth,
found at v80 after a raw-field compare matched almost nothing (v79 probe: 97 fetches,
12 pixels per frame):

```
top   = -yfield - (height+1)*8
ydiff = ly + yfield + (height+1)*8 + 8        escape_mob.v:471
match = ydiff < (height+1)*8                  escape_mob.v:472
```

#### The line being built

```
ly = (y_count - vbporch + 10'd1 + yscroll) & 0x1FF        escape_mob.v:703
```

The **`+1`** is not an off-by-one waiting to be tidied away: the buffer built during
raster line Y is displayed on line Y+1, so the engine must build for `ly+1`. An earlier
`+2` put every sprite one scanline too high; cross-correlating the engine's output
against MAME's gave a clean `(dx=0, dy=+1)` peak covering 88% of matched pixels
(`MOPLACE-1`, `mo_placement.md`).

#### Two state machines, mirroring the board

Escape's PAL16L8 at 70J drives a **dedicated `/LINK` memory slot** (SP-332 sheet 7) so
list walking never competes with the pixel pipeline. US4894774 calls it the lookahead
cycle. The engine is split the same way.

**The LINK SCOUT** (`sstate`, `SC_IDLE … SC_DONE`, `escape_mob.v:356-364`) owns the MO
RAM video port and walks the list continuously — including right through the blitter's
`S_PRIME`/`S_BLIT`, where the port would otherwise idle. Its reject loop touches only
`w0` and `w3`, the two words that decide an entry's fate, so a rejected entry costs
**2 cycles**. On a hit it also reads `w1`, computes `code_row = code + ty*width`, and
**issues that sprite's first tile fetch itself** (`MOCOV-1`). That matters because
per-sprite startup latency was 54–74% of all `S_PRIME` time: with sprites averaging 1–3
tile rows, there is nothing to amortise a first-tile wait against.

Three list terminators: ring closure (`nlink == first_link`), a 64-entry cap
(`ent_count == 63`), and budget exhaustion.

The scout **yields exactly one cycle** — `S_E0`, where the blitter assigns `mo_vaddr` —
and redoes the entry it was on. Re-reading `w0`/`w3` reaches the same verdict every
time and neither `link` nor `ent_count` advances mid-entry, so a yield costs cycles and
nothing else. Yielding `S_WAIT` as well was tried and cost 8,140 scout cycles a frame.

**The BLITTER** (`state`, `escape_mob.v:224-237`) pops sprites from the queue head,
decodes `w2` for colour, X and **priority** in `S_MATCH`, and paints tile rows 8 pixels
at a time in `S_BLIT`. Priority stays blitter-side on purpose: only `w1`, which carries
no priority information at all, moved to the scout, which is what makes the prefetch
compatible with the priority decode landing where `escape_prio` expects it.

*(`S_E1`/`S_E2`/`S_E3` are declared but unreachable — the in-line walk they belonged to
moved to the scout at MOFETCH-3. `S_CLEAR` is likewise named for a clear pass it no
longer performs; it is now purely the SLIP address cycle.)*

#### The park queue and the fetch channels

```
QDEPTH = 3        escape_mob.v:391     strict FIFO: scout pushes tail, blitter pops head
NCH    = 4        escape_mob.v:72      gfx_req[3:0] / gfx_addr[95:0]
                                       gfx_done[3:0] / gfx_data[127:0]
```

Per-tile cost is `max(8 blit cycles, round_trip / NCH)`. At the measured worst-case
round trip of 31 pixel clocks, `NCH=2` gives `max(8, 15.5) = 15.5` — fetch-bound — and
`NCH=4` gives `max(8, 7.75) = 8`, i.e. blit-bound, which is the floor. Four channels is
not a tuning choice; it is the smallest number that reaches the floor.

Channels come from a **free list**, `ch_free = ~(infl | pend)` (`escape_mob.v:494-502`),
not a fixed rotation. A rotation is safe with one prefetch outstanding and becomes a
**deadlock** with two, because a prefetch for the second queued sprite can land on a
channel the first queued sprite's later tiles will rotate onto — and the second sprite
is consumed after the first.

Landed prefetches are **harvested** into their queue slot the cycle they arrive
(`hv`/`hv_dat`, `:527-535`) and the channel handed straight back. Without harvesting a
prefetch parked two sprites ahead pins its channel for the whole of the sprite in front
of it — two pinned channels leave the blitter's pump running at `(31+8)/2 = 19.5`
cycles a tile instead of `(31+8)/4 = 9.75`, so depth would pay for itself out of the
steady-state term. Harvesting also makes deadlock-freedom independent of the
depth-versus-channel-count argument, because it asks nothing of the blitter.

**Depth 3 is measured, not guessed.** At the worst-case round trip (lat31, scene
50/157) coverage goes **82.70 → 90.50 → 93.51%** for one, two and three slots, and 4, 5
and 6 slots reproduce the three-slot frame *to the pixel*. Three is the knee.

**There is exactly one fetch issuer in the module.** Before MOCHAN-4 there were four —
the scout's prefetch, the blitter's tile-0 issue, its tile-1 issue and its steady-state
refill — each with its own address adder, each writing `gfx_req`/`gfx_addr`/`infl`,
kept apart only by an argument about states. Collapsing them removed three adders and
made the mutual exclusion structural: the arbitration is an if/else chain, so at most
one request can launch per cycle.

#### Line buffers, and first-write-wins

Two buffers, `buf0`/`buf1`, each **512 × 20 bits** — exactly the native M10K geometry,
which is why the entry width is a hard constraint:

```
entry = { fpar, tag[7:0], special, prio[1:0], color[3:0], pix[3:0] }
```

`disp_pen`, `disp_prio`, `disp_valid`, `disp_stain_s` and `disp_stain_e` leave the
module from here. The build buffer's otherwise-idle read port is repurposed as the
occupancy probe (`MOPLACE-2`) — still one read and one write per buffer, so it costs no
block, no port and no cycle.

**First-write-wins** (`MOPLACE-3`, `escape_mob.v:978-1004`). `eprom`'s MO config sets
"render in reverse order", so `atarimo` draws the linked list from tail back to head and
the *head* entry wins every pixel it touches. We must walk head-first, so the equivalent
is to refuse to overwrite a pixel already written for this line — earliest entry wins,
same result. The refusal is the write enable itself, gated on `bld_occupied`. This used
to be last-wins, which handed **16% of MO pixels in the reference frame** to the wrong
object.

**Staleness must be structural, not tagged.** The buffers carried a `{fpar, ly[7:0]}`
tag whose frame parity is **one bit**, which separates this frame from last frame and
from nothing else. An entry written *two* frames ago carries this frame's parity and
reads back live. As of BUILD 108 the display side **self-clears on readout**
(`clr_x`, `escape_mob.v:210-221`) — what the real MOHLB does. While a buffer is
displayed its write port is idle, so writing zero there costs no port, no block and no
cycle; an all-zero entry is unrepresentable as a hit because `S_BLIT` only ever writes
`pix != 0`. `clr_x` is `disp_x` delayed one cycle, so the clear never touches the
address the display side is reading. Buffers alternate every line, so each is cleared
during the line immediately before it is built. **Staleness is now impossible by
construction rather than by an argument about tag width.** The tags remain because they
still cover the reset state and cost nothing.

Widening the tag was never available: a 21st bit doubles both line buffers, and the
design is at 308/308 M10K.

#### What happens when the budget is missed

Four mechanisms, in increasing severity:

1. **`fetch_budget`** (7 bits, loaded to 126 at `S_SLIP1`) caps tile-row fetches per
   line. On exhaustion the scout stops walking, the issue port stops, and the current
   sprite ends rather than waiting in `S_PRIME` for a completion that can never come.
   Raised from a 6-bit ceiling of 62 because the engine reached it on 20 lines a frame;
   the golden model saturates at 40 tile-rows a line for that scene, so raising it cost
   no pixels and removed a limiter that was no longer measuring anything real.
2. **Right-edge clipping.** `S_BLIT` discards writes at column ≥ 344, and a tile row
   landing wholly in the clipped 344..504 window costs one cycle instead of eight
   (`MOFETCH-4`) — not one line-buffer write changes, only cycles spent.
3. **The line abort**, which is the real bound on a build. `mo_placement.md:189-192`
   is explicit: raising `fetch_budget` from 62 to 4000 changes the output by *zero
   pixels*, and capping the link walk at 34 entries gives byte-identical output. The
   line trigger aborts first. That scene has lines needing 218–441 tile-row fetches
   against a 456-cycle scanline.
4. **Completion discard on abort.** A request issued before the abort but *served after
   it* still toggles `done`. v87 resynced the done toggles, which discards completions
   that have already arrived but not ones still in flight — so the new line's first tile
   got paired with the old line's data, and from then on every tile on that channel
   carried real sprite art at the wrong X. `disc <= infl & ~done_edge` swallows exactly
   one completion per in-flight channel. **A line abort must retire pending edges by
   completing them, not by forgetting them.** The MiSTer playfield wedge (§5.2) is the
   same lesson in a different module.

Whatever is left un-built stays cleared, because the self-clearing readout guarantees an
empty start. **The failure mode is therefore missing MO pixels, never stale ones** —
graceful degradation, and never a wedge. That never-wedge property is a design
requirement, not an emergent one.

### 5.5 The MO/PF priority comparator — `escape_prio.v`

Purely combinational, 115 lines, transcribed from GAL equations verified off the real
PCB and quoted in `reference/eprom.cpp`. The equations are in the module header
verbatim; the mapping into this core's pixel pipeline is at `escape_prio.v:21-31`.

```
FORCEMC0 = !PFX3*PFX4*PFX5*!MPR0 + !PFX3*PFX5*!MPR1 + !PFX3*PFX4*!MPR0*!MPR1
!PF/M    = MPR0*MPR1 + PFX3 + !PFX4*MPR1 + !PFX5*MPR1 + !PFX5*MPR0
         + !PFX4*!PFX5*!MPR0*!MPR1
M7       = MPX0*!MPX1*!MPX2*!MPX3
```

Two derived facts are proved **exhaustively** by `sim/tb/tb_prio.v` against
`sim/tools/mo_priority_model.py` over all 2·4·16·16·16·16 input combinations:

```
FORCEMC0 == PF/M == (!PFX3 && mo_prio < pf_prio)
MO wins  == (PFX3 || mo_prio >= pf_prio) && !M7
```

Because `FORCEMC0` and `PF/M` are the same function, `FORCEMC0` can never be set on the
branch where the MO wins, so the reference's "force 3 bits of the MO colour to 0" arm is
unreachable. It is left out of the hardware deliberately, and the equivalence is
machine-checked rather than asserted.

Output is the 11-bit colour-RAM index directly:

```verilog
wire [10:0] mo_pen11 = {3'b001, mo_color, mo_pix};
wire [10:0] pf_pen11 = {2'b01, shade, pf_color[3] | m7, pf_color[2:0], pf_pix};
assign pen = mo_win ? mo_pen11 : pf_pen11;
```

**Special-sprite masking.** `MPR2` never reaches this module. `escape_mob` *does* write
special (`mopriority & 4`) pixels into the line buffer — they must be there to mask
normal sprites beneath them, exactly as the reference's single MO bitmap does — but it
clears `disp_valid` for them, so the comparator sees precisely what the reference's
first pass sees after its `continue`.

Score against the reference model: **507,904 / 507,904 = 100.0000%**
(`sim/run_prio_tb.sh`).

### 5.6 The stain pass — `escape_stain.v`

MAME applies the stain as a genuine **second pass**: `eprom.cpp` runs
`iterate_dirty_rects` again and, at every marker pixel, `atarimo.cpp`'s `apply_stain`
walks right along the scanline ORing `0x400` into the pen until it sees an END bit
followed by a non-START pixel.

```c
offnext = false;
for (x = x0; x < width; x++) {
    pf[x] |= 0x400;
    if (offnext && !S(x)) break;
    offnext = E(x);
}
```

A raster core cannot afford a second pass over the line, so the union of all those
restarted scans is collapsed into a **single-pass, one-flip-flop recurrence** applied
during scanout:

```
stain(x) = S(x) | alive(x-1)
alive(x) = stain(x) & ~( E(x-1) & ~S(x) )
```

with `S` = "special pixel here whose pen has bit 1 set" (`START_MARKER`) and `E` =
"...bit 2 set" (`END_MARKER`), matching `(4 << PRIORITY_SHIFT) | 2` and `| 4` exactly.
Both halves of each mask must match, which is what `spc_hit` in `escape_mob.v:155`
contributes. Two flip-flops; the M10K delta is structurally zero.

It reaches the picture at `core_top.v:2568-2570`, ORed in **after** the alpha/MO/PF mux,
i.e. over the finished picture, exactly as the reference's second pass does:

```verilog
color_vaddr <= (alpha_vis ? {3'b000, act_color, pix} : pr_pen) | {stain_now, 10'd0};
```

The equivalence between the C loop and the recurrence is **checked, not argued**:
`sim/tools/check_stain_automaton.py` replays the RTL's own special pixels through both
and fails on any per-line difference (320 stained pixels each, 0 lines differing, on the
FACTORY MAP scene).

**Two behaviours fall out, and both are correct:** a solid marker (pen 6, both bits)
stains its own silhouette plus exactly one pixel past its right edge; a **pen-2 marker
with no END bit stains to the end of the scanline.** The second is not a bug in the
automaton — the C loop does the same. It is, however, the amplifier that turned a
dropped line-buffer write into a screen-wide artifact: when the *terminator* marker's
write is refused, the stain runs from the marker's world-anchored left edge to the last
screen column. That was the scrolling-dashes artifact
([`GFX_DASH_ARTIFACT.md`](GFX_DASH_ARTIFACT.md)), fixed by §5.4's self-clearing readout.

> **Two status corrections.**
>
> `mo_placement.md:205-207` still lists "no `apply_stain` second pass, and a special
> object does not mask a normal object underneath it" as known deviations. **Both were
> implemented in BUILD 105 (MOSTAIN-1) and both halves of that sentence are now false.**
>
> `DEVIATIONS.md` §E claims the stain pass "matches `atarimo.cpp`'s `apply_stain` on
> every scored frame, all cases". Read that narrowly. What is verified is (a) the
> recurrence ≡ the C loop, offline, and (b) `sim/run_stain_tb.sh`, which drives the
> shipped `escape_stain` instance and went from 226 mismatching pixels to 0. What is
> **not** verified is end-to-end coverage on silicon: the last hardware measurement
> (BUILD 106) reached **61.3%** of the marker box against MAME's own **66.8%** ceiling,
> a residual of ~16–21 pixels, and the shortfall reproduces in no bench we have. See
> `RETROSPECTIVE.md` §6 for why the earlier "100%" number meant nothing.

### 5.7 Colour RAM and output

Per-layer colour RAM, as the schematic's memory map lays it out (sheet 16), in one
2048 × 16 `color_ram`:

| CPU range | Bank | Index range |
|---|---|---|
| `0x3E0000-0x3E01FF` | Alpha | 0..255 |
| `0x3E0200-0x3E03FF` | Motion Object | 256..511 (CRA9) |
| `0x3E0400-0x3E05FF` | Playfield | 512..767 (CRA10) |
| `0x3E0600-0x3E07FF` | Playfield Shadow | 768..1023 |
| `0x3E0800-0x3E0FFF` | **Stain** | 1024..2047 |

The 11-bit index from `escape_prio`, with `0x400` ORed in by the stain pass, addresses
this space directly — which is *why* the stain works: bit 10 selects a different bank,
so a stained pen resolves to a different colour with no compositing arithmetic at all.
On the FACTORY MAP the stained playfield pens resolve to entries 1537, 1538, 1539, 1547,
1549 and 1550, all `0xF888` — six pens mapping to one grey, which is why a stained block
goes flat rather than shaded.

Final colour is **IRGB4444 with global intensity** (`core_top.v:2572-2580`):

```
i     = (I + 1) * (4 - intensity)          intensity clamped to 4
ch8   = ch4 * i / 4, saturated at 255
```

`intensity` and `video_off` come from the `0x360011` byte (§4.1). Attract-mode screen
dimming is authentic and driven from there; it looked like a core bug for a while
(`LESSONS.md`, "Check authenticity before debugging").

Pixel-to-screen latency is **3 pixel clocks** (`color_vaddr` register → registered BRAM
read → `vidout_rgb` register). There is no compensating X shift in the timing counters;
the alignment is absorbed by the `+16 + vpshift` lead in `pf_x2` and by the alpha
prefetch phase.

Output leaves through the APF video interface at native 336×240. *Deviation A5*: the
Pocket's scaler maps 240 rows to 1080 as alternating runs of 4 and 5 — measured period-9
fold contrast **12.3×** against 1.17–1.46 for control periods 7/8/10/11/13, and
screen-locked to within 0.06 rows over 42 frames. Every 1-pixel horizontal feature is
drawn 4 or 5 pixels thick depending on where it lands. **No RTL change can alter this**;
it is in the scaler.

---

## 6. Audio: the JSA-I board

*Register-level spec: [`JSA.md`](JSA.md), with the caveat at the end of this section.*

Escape carries an Atari **JSA-I** audio board: a 6502 (T65), a YM2151 (jt51), and a
TMS5220 speech chip. No POKEY — the socket is present and unpopulated, and reads return
`0xFF`. No OKI6295.

`escape_jsa` is single-clock on the 7.159091 MHz core clock, with everything paced by
enables derived from a 2-bit counter:

| Enable | Rate | Consumer |
|---|---|---|
| `cen_ym` | **3.579545 MHz** (÷2) | `jt51 cen` |
| `cen_ymp1` | **1.789773 MHz** (÷4) | `jt51 cen_p1` |
| `cen_cpu` | **1.789773 MHz** (÷4, CPU phase) | 6502 timing base, timed-IRQ divider |
| `cpu_ena` | ≤1.789773 MHz | `T65 Enable` — `cen_cpu and not rom_stall` |
| `tms_en` | **650.8 kHz** (÷11) or **795.4 kHz** (÷9) | `TMS5220 I_ENA`, selected by WRIO D3 "squeak" |
| — | **249.69 Hz** | timed IRQ: ÷7168 of `cen_cpu` |

The 6502's clock enable is gated off while a ROM fetch is in flight — that is what
`rom_stall` is — and its ROM is `jshad`, a BRAM copy of the whole 64 KB region (§3.3),
not an arbiter client.

### The SCOM link, and why it is not a latch

The schematic (sheet 2) shows the sound link is **not** a parallel latch: it is a serial
**SCOM ASIC pair** driving a cable to a stand-alone audio PCB
(`/DATA /CLK FIN FOUT /SCBSY FULL /SINT`). MAME models the link as instantaneous, and
for MAME that is harmless.

It is not harmless here, and this is *deviation C3* resolved in the schematic's favour.
Each byte the 68000 writes to `0x360031` raises the 6502's **NMI**, cleared when the
6502 reads `0x2802`. With instant delivery, a 68000 writing several bytes in quick
succession **NMI-storms the sound CPU** through its software-timed `/WS` pulse and coin
handling: speech cut mid-phrase, coins dropped. The serial bit rate is the pacing the
board relies on, and the model is explicit about it (`escape_jsa.vhd:125-131`,
`:401-421`):

```vhdl
constant SCOM_XFER : unsigned(6 downto 0) := to_unsigned(80, 7);
```

Sheet p5/p6: main 20K ↔ audio 1M, clocked by `/B4H` = **894.9 kHz**; 8 bits plus
framing ≈ 11 µs ≈ **80 clocks at 7.159 MHz**. On a command write the byte latches and
`cmd_pend` rises immediately, but `cmd_full_i` — and therefore the NMI — rises only
`SCOM_XFER` clocks later. `/SCBSY` and the buffer-full bits at `0x260010` D2/D3 are what
the 68000 polls to stay in step.

The return path mirrors it: the 6502 writes `0x2A02`, setting output-buffer-full and
asserting the main CPU's **/SINT** (IRQ6, main CPU only); the 68000's read of
`0x260031` clears both. All three 68k-side strobes are exact-width byte decodes under
LDS.

### Speech

The TMS5220 is real — `src/fpga/core/rtl/TMS5220.vhd`, the d18c7db MAME-faithful model
vendored from the System 1 tree with a lattice-filter arithmetic fix. The original's
13-bit accumulators were fine for quiet System 1 speech and overflowed on this game's
loud announcer. Two details are board behaviour, not convenience:

- `tms_ws_n`/`tms_rs_n` power up **asserted low**, because the LS273s clear at POR on
  the real board and hold the chip in reset until firmware's first WRIO write.
- **There is no auto-WS logic.** The firmware strobes WS through the WRIO latch on every
  byte (`2A04=07 → 2A00=data → 2A04=05`). An auto-pulse added on a mistaken sim reading
  produced two WS edges per byte — every byte delivered twice, which is the buzz. That
  misdiagnosis, and the two builds spent fixing its artifacts, are in `LESSONS.md` under
  "Misdiagnoses compound".

### Mixing and output

`/MIX` (`0x2A06`) carries per-source volume: YM2151 0–7, TMS5220 0–3. YM gain is a Q8
table `round(0.60 × 256 × v/7)` = `{0,22,44,66,88,110,132,154}` applied to `jt51`'s
`xleft`/`xright`; TMS gain is `{0x00,0x55,0xAA,0xFF}`. User volume sliders multiply on
top. Sums are 18-bit and saturated into `audio_l`/`audio_r`.

The path to the Pocket is: `escape_core`'s `audio_l/r` → `core_audio_l/r` →
`aud_l_feed`/`aud_r_feed` → the I2S generator (`core_top.v:641-692`), which produces
`audgen_mclk` = 12.288 MHz on `clk_74a` via a fractional accumulator, SCLK = MCLK/4, and
LRCK toggling every 32 SCLKs — **48 kHz, 32 bits per channel, top 16 active**. The
crossing from the 7.159 MHz domain is a plain double register, on the stated grounds
that tearing at 48 kHz boundaries is inaudible.

**One documented open item:** YM CT1 gating of the TMS (and would-be POKEY) volume is
deliberately **not applied** — "polarity unverified; ungated proves the speech engine —
revisit after device test" (`escape_jsa.vhd:571-573`). `JSA.md` describes the gain law
with the gate, so the doc and the RTL differ here on purpose.

> **`JSA.md` is stale in three places** and should be read with this section beside it.
> It describes the TMS5220 as a stub with silence output, the SCOM as modelled with
> latch semantics, and `escape_core`'s JSA status bits as a stub driving both flags
> idle. All three were superseded. `escape_jsa.vhd`'s own header still says
> "TMS5220 stub" and "SCOM stubbed"; `escape_core.vhd:7-9` still describes a 2268-line
> file as a "'Hello world' skeleton".

---

## 7. Where to start reading

| You want | Read |
|---|---|
| raster timing, playfield, alpha, the compositor, SDRAM/CRAM services, arbitration, HUD | `src/fpga/core/core_top.v` — the video pipeline lives here, not in the VHDL |
| CPUs, decode, shared RAM, TAS interlock, interrupts, shadows, fastpath, JSA glue | `src/fpga/core/rtl/escape_core.vhd` |
| the sprite engine | `src/fpga/core/rtl/escape_mob.v` — read the header comments first; they are the design record |
| MO/PF priority | `src/fpga/core/rtl/escape_prio.v` (115 lines, all of it) |
| the stain automaton | `src/fpga/core/rtl/escape_stain.v` (63 lines, all of it) |
| the sound board | `src/fpga/core/rtl/escape_jsa.vhd` + `docs/JSA.md` |
| the memory controller | `src/fpga/core/rtl/sdram_simple.v` |
| what the ROM image looks like | `support/build_rom.py` + `docs/ROMMAP.md` |
| the MiSTer port | `git show origin/mister-port:docs/MISTER.md` |
| how any of this was arrived at | [`RETROSPECTIVE.md`](RETROSPECTIVE.md), [`HISTORY.md`](HISTORY.md), [`LESSONS.md`](LESSONS.md) |

The codebase carries no `TODO`/`FIXME` markers in first-party RTL. It uses tagged
change-IDs instead — `MOCHAN-4`, `MODEPTH-1/2`, `MOFETCH-1..5`, `MOPLACE-1/2/3`,
`MOPRI-1`, `MOSTAIN-1/2`, `GFXDASH-1/2/3`, `LANE3*`, `LANE4*`, `SDSCHED-*`,
`TASLOCK-102`, `CLKFIX-106`, `CADENCE-107`, `VSHAD3-107`, `PFRESET-107` — and those tags
are the best cross-reference keys into both the git log and these documents.
