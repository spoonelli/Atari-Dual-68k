# SDRAM architecture: open-row policy and bank interleaving

Branch `sdram-openrow-EXPERIMENTAL`. **Nothing here is merged, and nothing here
has run on hardware.** Every number below is simulation or synthesis. I cannot
flash the Pocket, so no claim in this document is a hardware verification.

---

## 0. Corrections to the starting brief

Four things the brief asserted turned out to be wrong or incomplete. They are
listed first because two of them change the conclusion.

| Brief said | Actually |
|---|---|
| "full activate–read–**precharge** for every access: `S_IDLE → S_ACTIVE → S_RW → S_CL → S_DATA → S_PRECHG → S_IDLE`" | There is no explicit precharge on the normal path and no `S_CL` state. The FSM sets **A10=1 (auto-precharge)** on the second beat of the burst; `S_PRECHG` is only a wait state. Measured: 300 reads produce `act=300, read=600, preall=301`. |
| four clients: video CPU / extra CPU / motion objects / **the CRAM drain queue** | The CRAM drain queue is **not an SDRAM client**. Playfield and CRAM traffic go to the separate **PSRAM** part (`psram cram0`, `core_top.v:1115`). The SDRAM read clients are video CPU, extra CPU, and motion objects. |
| "Bank interleaving without open-row buys little; that is why it is second." | **Backwards for this design.** Open-row *without* banking buys little (6.7% hit rate). See §2. |
| Stage 3 blast radius: "address mapping, ROM image layout (`build_rom.py`), `docs/ROMMAP.md`, every client's address arithmetic, and the MiSTer port's loader" | **None of those need to change.** See §4.3. |

A fifth item, not in the brief, found while calibrating: **`rd_pre` is dead
code.** `core_top.v` assigns `rd_pre_q <= 1` at all four grant sites (`:1626`,
`:1634`, `:1671`, `:1711`), never `0`, and the port mux forces `1'b1`
otherwise. So the controller's `rd_pre=0` "video/scrub fast path" is
unreachable, and **every read pays the 15-clock precharge-all armored path.**

---

## 0a. The finding to carry forward: a gate whose controls stop being controls

Ahead of everything else, because it generalises beyond this work and would
have bitten silently.

`sim/run_sdram_refresh_tb.sh` proves it can fail by running two policies that
are **out of JEDEC spec** and requiring both to be reported FAIL. That is the
right design. But the thing being bounded is a **time** — 7.8125 µs per row —
while the policies are expressed in **clocks**. So the verdict on every cell,
including the negative controls, is a function of the clock:

| | 35.795455 MHz | 50.113637 MHz |
|---|---|---|
| the 7.8125 µs limit, in clocks | 279.7 | **391.5** |
| control "250 / 48" (worst ≈ 314 clk) | **8.77 µs → FAIL** ✓ | **6.27 µs → PASS** ✗ |
| control "224 / 48" (worst ≈ 288 clk) | **8.05 µs → FAIL** ✓ | **5.75 µs → PASS** ✗ |

**Raise the clock and both negative controls start passing.** The script's own
logic then reports every cell green and prints its success banner, while
measuring nothing at all — and it would do so at the exact moment someone was
relying on it most, having just changed the clock. Nothing in the script warns;
its `report ... FAIL` expectations are literals chosen for one clock.

Fixed on `sdram-clock-EXPERIMENTAL` by making `CLK_NS` a knob and re-basing the
controls to policies that are genuinely out of spec **at the new clock**
(350/70 → 8.700 µs, 320/60 → 7.902 µs, both correctly rejected).

The general shape, worth stating because this project has now hit this class
repeatedly: **a proof-it-can-fail control is itself calibrated, and its
calibration can go stale exactly like the constant it is guarding.** The same
audit applied to the neighbouring gates found `run_psram_tb.sh` in the same
condition — its negative control was "declared 35.795455 while the PLL runs
85.909", a clock this design does not have.

A related, smaller instance found the same way: `sim/tb/tb_mob_perf.v` declares
`reg [6:0] lat [0:3]` and assigns `lat[k] <= GFX_LAT[6:0]`, so **any
`GFX_LAT ≥ 128` silently truncates mod 128**. `GFX_LAT=134` behaves as 6 and
reports a perfectly clean frame. Neither the default 8 nor the 31 in that
file's own header trips it, so nothing in the gate set exposes it.

---

## 1. What the shipping controller actually does

`src/fpga/core/rtl/sdram_simple.v`, clock `clk_sdram` = **35.795455 MHz**
(`mf_pllbase_0002.v` `output_clock_frequency2`; period 27.936508 ns).

Address split, line ~76: `{ba, row, col} = {wa[23:22], wa[21:9], wa[8:0]}` from
the word address `wa = addr[24:1]`.

A row is **512 words = 1024 bytes** of byte address. That number does most of
the work in this document.

The whole 2.2 MB image (`0x220000` bytes = `0x110000` words) fits inside
`wa[20:0]`, so **`wa[23:22]` is always zero and three of the four banks are
never used.** Verified from `support/build_rom.py:89` (`img =
bytearray(0x220000)`) and from the measured trace, not from the comment.

Measured read timeline (traced against the real FSM, `S_IDLE` → ack):

```
S_IDLE  PRECHARGE ALL   1 clk
S_PREALL                3
S_ACTIVE                4
S_RW    READ  (A10=0)   1
S_RD2   READ  (A10=1)   1
S_DATA  capture word0   1
S_DATA1 capture word1, rd_ack   1
S_PRECHG                3
                       ── 15 clocks, + 1 to clear the ack in S_IDLE
```

At 5:1 that is exactly **3 of the CPU's 4 bus clocks**, before any arbitration
or handshake overhead.

### 1.1 CAS latency, and a caveat that cannot be settled in simulation

Traced directly: the chip registers `READ` at clock 11 and the controller
captures `rd_data[31:16]` at clock 13. That is **standard CL2** in
command-to-capture terms. But in a zero-delay *cycle* model the READ appears on
the pins one clock after the FSM issues it, so `sim/tb/sdram_model.v` has to
return data **one controller-visible clock** after registering the READ
(`CL_EFF = 1`) for the shipping FSM to read correct data.

The missing clock is the 90° `clk_sdram_chip` phase (`phase_shift3 = 6984 ps`)
plus `FAST_INPUT_REGISTER` capture in the IO cell (`ap_core.qsf:810`). That is a
**sub-cycle** relationship. `CL_EFF` is therefore **calibrated against the
shipping, hardware-validated FSM, not derived** — this is exactly the
"one-clock skew, phase-dependent" of SDSCHED-83.

**Consequence:** comparisons *between controller variants measured the same
way* are sound. Any claim about the **absolute** data latency is not, and must
be settled on hardware.

### 1.2 Only motion objects consume burst word-1

`sd_rd_data[15:0]` is read by exactly one client — `mg_data` at
`core_top.v:1718`. Every other client (`probe0`, `chk2_val`, `chr_wdata`,
`fpv_data`, `fpe_data`, `:1443`–`:1649`) uses `[31:16]` only.

Word-1 is also the half with an eight-day unresolved capture history
(`f94d6bf`, `6060ae1`, `6c59ca6`, `033eba6`, `37a81fe`; v52: *"word-1
corruption persists through both the spread-burst and no-auto-precharge
experiments"*).

**So the one client that consumes the unreliable half of the burst is the one
with the sprite artifacts.** This document does not claim that is the cause of
D3 — it is a coincidence worth a dedicated experiment, and it is independent of
bandwidth. Flagged, not concluded.

---

## 2. Stage 1 — measurement before changing anything

Instrument: `sim/run_sdram_traffic_tb.sh` → `sim/tb/tb_sdram_traffic.v`.

**What is real in it:** the controller (unmodified RTL); the memory
(`sim/tb/sdram_model.v`, which serves from the *physically latched* row); the
motion-object address stream **and its arrival times**, captured from
`tb_mob_perf.v` driving the real `escape_mob.v` against real sprite RAM and
real graphics — 8,185 fetches over one frame; and the video-CPU program-fetch
stream, captured from `tb_escape_core.vhd` running the **real game ROM**
through the real TG68K with `SHAD_EN => 0`.

**What is modelled, and is the weakest link:** the arbiter. `core_top.v`'s read
arbitration is not instantiable by any bench, so the priority chain is
reproduced in the testbench with every grant condition quoted verbatim above
the code implementing it. A drift between the two would be invisible.

### 2.1 Results, no-shadow configuration (70% fill)

```
accesses in one frame's clocks (597,360) ...... 33,102
row-hit rate an open-row policy would achieve ....  6.74%
  misses caused by CLIENT SWITCH ................ 87.40%
  misses caused by same-client stride ...........  0.23%
  misses caused by refresh ......................  5.63%
service latency ....................... mean 14.12, worst 23 clocks
demand-to-ack latency  FPV 23.7/40   FPE 31.1/73   MO 106.0/668
motion objects served ......... 5,606 of 8,185 demanded (68.5%)
```

### 2.2 Why client-switch dominates — structural, not statistical

The three read clients occupy disjoint regions:

| client | image bytes |
|---|---|
| video CPU program | `0x000000`–`0x07FFFF` |
| extra CPU program | `0x080000`–`0x0FFFFF` |
| sprite graphics | `0x120000`–`0x21FFFF` |

They are ≥ 512 KB apart and a row spans 1 KB, so **no row can straddle two
clients**. With every client in bank 0, *every* client switch is necessarily a
row miss. That is arithmetic, not a measurement artefact.

### 2.3 The conclusion does not depend on the CPU locality assumption

The captured CPU trace covers early boot — a tight RAM-test loop, 7,633
fetches across **two** 1 KB rows, 99.99% same-row. Real code, but not
gameplay. So CPU locality was swept rather than assumed:

| CPU row-residency | 8 | 32 | 64 | 256 | real trace |
|---|---|---|---|---|---|
| row-hit rate | 6.19% | 6.61% | 6.74% | 6.79% | 6.81% |
| client-switch share | 87.40% | 87.40% | 87.40% | 87.40% | 87.40% |

A 0.6-point spread across the entire plausible range. **The answer is
insensitive to the one thing that was assumed rather than measured.**

### 2.4 How hard is the extra CPU actually pushing? — a real qualification

The one input with genuine uncertainty is `EFILL_PCT`, how often the extra CPU
needs an SDRAM fill. 70% comes from `docs/VSHAD3.md`'s no-shadow figure, but
`docs/DEVIATIONS.md` D2 notes the world CPU *"uses only 48% of its cycle
budget"*, so an idler extra CPU is plausible. Swept, against the baseline
controller:

| `EFILL_PCT` | row-hit | client-switch share | MO served | service mean |
|---|---|---|---|---|
| 70% | 6.74% | 87.40% | **68.5%** | 14.12 |
| 50% | 7.62% | 86.26% | **92.5%** | 14.12 |
| 35% | 11.40% | 81.41% | 100% | 14.07 |
| 20% | 20.70% | 70.49% | 100% | 14.00 |
| 0% | 42.52% | 45.49% | 100% | 13.92 |

Two conclusions, and they are different from each other:

- **The architectural conclusion is robust.** Client-switch stays the dominant
  miss cause across the whole plausible range — 70% to 87% for any extra-CPU
  load from 20% upward. Open-row alone remains poor and banking remains the
  change that matters. Only if the extra CPU stopped using SDRAM almost
  entirely (0%) would the picture change, and it does not.
- **The severity is load-dependent, and this is a real caveat.** Motion objects
  are starved only when the extra CPU is genuinely busy: 68.5% served at 70%
  fill, but fully served at 35% and below. So the *size* of the sprite-dropout
  problem in the no-shadow configuration depends on how much the extra CPU
  actually fetches — a quantity taken from a document rather than measured
  here, because `tb_escape_core.vhd` never releases the extra CPU in the window
  captured. **If the true figure is nearer 35% than 70%, the baseline is much
  less broken than §2.1 suggests, and the case rests on latency rather than on
  starvation.**

Measuring the extra CPU's real fill rate is the single highest-value follow-up
to this work.

### 2.4 Bench validity controls

- **C1** MO only: bench reports SEQ-ROW **84.13%**; an offline analysis of the
  same trace file computes **84.14%** by a completely independent route. Two
  routes, one number.
  *This control failed on its first run* (69.80%) — because it compared
  ROW-HIT (which includes refresh closing the row) against a refresh-free
  offline figure. The control was wrong, not the bench; a separate SEQ-ROW
  counter was added so the comparison is like-for-like. Recorded because a
  control that is quietly relaxed until it passes is worth nothing.
- **C2** video CPU only: 82.51% — a single sequential client hits often, as it
  must.
- Every cell fails if the memory model reports any protocol violation, if the
  data check is absent/empty, or if any wrong word is returned.

---

## 3. Stage 2/3 — the controller

`src/fpga/core/rtl/sdram_openrow.v`. **A separate module.** `sdram_simple.v` is
not edited at all: it carries five documented freeze fixes and ~25 builds of
debugging, and a separate module means a bad night cannot regress it.
`core_top.v` selects between them with one `localparam SDRAM_OPENROW_EN`.

`OPENROW_EN` and `BANKMAP_EN` are independent parameters so the two halves stay
separately measurable.

### 3.1 Latencies by path

| path | clocks (grant → ack) |
|---|---|
| row hit | **4** |
| miss, bank idle | 8 |
| miss, bank open on another row (precharge + activate) | 11 |
| shipping controller, every access | 15 |

### 3.2 Timings honoured, and where the numbers come from

MT48LC16M16A2, **-75** grade. No speed grade is recorded anywhere in this repo
for the fitted part, so the slowest grade the part is offered in is assumed —
the conservative choice. (The only speed grade ever named in the history is
`-7E`, in a reverted commit `926b3a2`, asserted without a datasheet in-repo and
in a commit whose own header carries the wrong clock. Treated as unverified.)

At 27.936508 ns/clock:

| parameter | ns | clocks required | clocks used |
|---|---|---|---|
| tRCD ACTIVE→READ/WRITE | 20 | 1 | 2 (`T_RCD_CLK`) |
| tRP PRECHARGE→ACTIVE | 20 | 1 | 2 (`T_RP_CLK`) |
| tRAS(min) ACTIVE→PRECHARGE | 45 | 2 | 2 (`T_RAS_CLK`, guarded) |
| tRC ACTIVE→ACTIVE same bank | 65 | 3 | ≥3 (implied by tRP+tRCD) |
| tRRD ACTIVE→ACTIVE other bank | 15 | 1 | ≥1 |
| tRFC REFRESH→any | 66 | 3 | 9 (`T_RFC_CLK`, as shipped) |
| **tRAS(max) row-open limit** | **120,000** | **4,295** | ≤ 216 (see §3.3) |

The kept values are the ones `sdram_simple` ships. They are 2–3× the minimum
and are **left alone deliberately** — this module already changes the row
policy, and shortening the waits at the same time would confound a hardware
A/B. They are parameters *in clocks* so a clock change scales them explicitly
rather than silently; that silent-scaling failure is what put refresh 6.6%
outside JEDEC spec for months (`docs/RETROSPECTIVE.md` §5).

At this clock the row minimums are **nearly free** (1–2 clocks). That is why
open-row has so much timing headroom here — and it shrinks if the clock rises.

### 3.3 Refresh and the open row

`AUTO REFRESH` requires all banks precharged. `S_IDLE` therefore issues
`PRECHARGE ALL` first when any row is open, waits `T_RP_CLK`, then issues the
refresh, clearing all four open-row registers. Handled by construction, and
checked: `sdram_model.v` reports `refresh_with_open_bank`, and its own mutation
gate proves that detector fires.

The refresh policy itself (`REFRESH_INTERVAL=160`, `DEFER_CAP=48`, `refresh_due`
consumed only from `S_IDLE`) is **unchanged**.

`sim/run_sdram_refresh_tb.sh SDRAM_DUT=openrow`:

| policy | worst gap, `sdram_simple` | worst gap, `sdram_openrow` | verdict |
|---|---|---|---|
| NEGATIVE 250/48 | 314 clk / 8.772 µs | 306 clk / 8.549 µs | **FAIL** (required) |
| NEGATIVE 224/48 (mister-port) | 288 clk / 8.046 µs | 280 clk / 7.822 µs | **FAIL** (required) |
| 250/0 | 266 clk | 259 clk | PASS |
| **shipping 160/48** | 224 clk / 6.258 µs | **216 clk / 6.034 µs** | PASS |
| idle bus | 161 clk | 161 clk | PASS |

The worst case **improves**: the in-flight transaction shortens from 15 clocks
to 11, which more than pays for the added `PRECHARGE ALL`. tRAS(max) is
therefore never approached — a row can be held at most 216 clocks against a
4,295-clock limit, i.e. 5% of it.

> **⚠ Caveat, recorded rather than buried.** The mister-port negative control
> now fails by only **0.0097 µs** (280 vs the 279.7-clock limit). It still
> fails, which is what the gate requires. But it used to fail by 0.233 µs, and
> the margin narrowed *because this FSM got faster*. **A further speedup could
> make that control start passing, at which point the gate silently loses a
> control and nobody would notice.** If the FSM is made faster again, that cell
> needs re-basing on purpose.

### 3.4 Read-during-write and same-row writes

Writes use the same per-bank row tracking and the same one address-mapping
function as reads, so a write lands in the sense amps the next read selects
from. `sdram_model.v` stores writes at `{bank, latched_row, col}` and serves
reads from the same place, so a stale open row serving a just-written location
would show as a data mismatch.

**Limitation, stated:** the traffic bench drives `wr_req` low, so the
write/read-back path is exercised only by the model gate's clean run, not under
concurrent read pressure. A dedicated concurrent write+read gate is **not yet
written** — see §8.

---

## 4. Results, measured separately

`sim/run_sdram_traffic_tb.sh`, one frame, no-shadow (70% fill), CPU
row-residency 64. Every cell: **0 data mismatches, 0 protocol violations.**

| controller | hit *opportunity* | service mean | accesses/frame | MO demand→ack mean/max |
|---|---|---|---|---|
| `sdram_simple` (baseline) | 6.74% | 14.12 | 33,102 | 106.0 / 668 |
| A — leaner FSM, no open-row, no banks | 7.01% | 11.75 | 38,969 | 55.7 / 177 |
| B — **open-row only** | 7.65% | 11.31 | 39,476 | 48.5 / 198 |
| C — **banks only** | 71.45% | 11.51 | 39,891 | 51.0 / 185 |
| D — **both** | **79.22%** | **6.15** | **50,628** | **18.7 / 101** |

And the miss split, which shows the mechanism directly:

| controller | client switch | same-client stride | refresh |
|---|---|---|---|
| `sdram_simple` (baseline) | **87.40%** (28,931) | 0.23% | 5.63% |
| B — open-row only | 82.54% (32,582) | 0.50% | 9.32% |
| D — open-row + banks | **0.00% (2 accesses)** | 14.11% | 6.67% |

Bank interleaving takes client-switch misses from **28,931 to two**. What is
left is genuine same-client stride (14.11%, consistent with the motion-object
stream's own 84% same-row locality) and refresh (6.67%, which no row policy can
avoid because `AUTO REFRESH` precharges every bank).

> **A correction to an earlier version of this table.** It reported
> `client_switch = 13.79%` for configuration D. That was a defect in the
> taxonomy, not a property of the design: the classifier compared against the
> previous access *overall* rather than the previous access **to that bank**.
> Under banking each bank keeps its own open row, so a client's own stride miss
> was being relabelled a "client switch" whenever another client happened to be
> served in between — which, with banking working, is nearly always. The
> row-hit rate was never affected (79.22% either way, since the fix only
> reclassifies misses), which is how the two versions can be reconciled.

**The interaction is the entire win.** B and C each land within half a clock of
the A control. Banking raises the *opportunity* from 7% to 71%; open-row is
what cashes it. Either alone is not worth the risk; together they halve service
latency and cut MO demand-to-ack by 5.7×.

Command counts confirm the policy is actually engaged: 300 sequential reads
need **15** activates instead of 300, and `read=…(ap=0)` — no auto-precharge
anywhere.

Throughput note: the baseline serves 33,102 of ~50,185 demanded accesses
(66%) — the no-shadow configuration is **~34% oversubscribed** on the shipping
controller. Configuration D serves 50,628, i.e. all of it.

The baseline is genuinely bus-saturated, and the saturated cost per access is
**18.1 clocks** (600,000 / 33,102), not the 15 the FSM spends: the 4-phase
handshake, the grant decision and the `S_IDLE` ack-clear add ~3 clocks of
arbitration overhead on top of every transaction. Per-client service is
consistent with the priority chain — FPV 15,023 served against FPE's 12,473 on
identical demand. (MO's *fraction* served, 68.5%, exceeds FPE's 59.4% only
because MO's demand **rate** is 2.6× lower; a low-rate client can be well served
at low priority whenever any slack exists. That is not a priority inversion.)

### 4.1 The bank map

| bank | word addresses | contents | image bytes |
|---|---|---|---|
| 0 | `wa < 0x040000` | video CPU program | `0x000000`+ |
| 1 | `0x040000 ≤ wa < 0x080000` | extra CPU program | `0x080000`+ |
| 2 | `0x080000 ≤ wa < 0x090000` | JSA 6502 + chars | `0x100000`+ |
| 3 | `wa ≥ 0x090000` | sprite graphics | `0x120000`+ |

`row = wa[21:9]`, `col = wa[8:0]` — **bit-identical to `sdram_simple`'s**. No
offset arithmetic is needed: every region is smaller than one bank (4M words)
and the regions are already disjoint in `wa[21:0]`. The bank select is three
8-bit comparisons on `wa[23:16]`.

### 4.2 Why *this* map

Directly from the Stage 1 split: client-switch misses are 87.4% of all misses,
and the switching clients are exactly video CPU / extra CPU / motion objects.
Giving those three their own banks is the minimum change that addresses the
measured cause. Bank 2 (JSA + chars) is nearly idle after boot — the char ROM
is DMA'd into BRAM once — so it costs nothing to give it the spare bank.

### 4.3 Blast radius — much smaller than the brief expected

The remap is applied to `wr_addr` **and** `rd_addr` by **one function inside
the controller**. The SDRAM image is created by the download writes themselves,
so remapping both sides stores the image in the remapped layout and finds it
there.

**Unchanged: `support/build_rom.py`, `docs/ROMMAP.md`, the MiSTer loader, and
every client's address arithmetic.** The external byte-address contract is
identical.

The one invariant that must hold is that reads and writes use the *same*
function — so it is literally one function, used by both. If they ever diverge
the download writes to one place and the CPU reads another, which is a silent
whole-image corruption.

The PSRAM mirror (`cq_enq` snoops `sd_wr_addr`) and the BRAM shadow fill
(`shad_waddr`) both see byte addresses *before* the controller, so both are
unaffected.

---

## 5. The question the exercise is for: can the shadows come out?

**In simulation, yes.**

Method: take the MO fetch latency **measured** in §4, convert to pixel clocks
(÷5), and feed it into the real MO engine bench (`tb_mob_perf.v` + real
`escape_mob.v` + real sprite data), then score the rendered frame against
`sim/tools/mob_golden.py`.

| config | GFX_LAT / OCC | coverage | **partial lines** | complete |
|---|---|---|---|---|
| reference (bench default) | 8 / 0 | 99.47% | **0** | 211 |
| no-shadow, `sdram_simple` (measured 21.2 px) | 21 / 3 | 99.21% | **11** | 200 |
| no-shadow, `sdram_openrow` (measured 3.7 px) | 4 / 1 | 99.47% | **0** | 211 |

Sensitivity, to show the instrument responds rather than always saying zero:

| GFX_LAT | 4 | 8 | 12 | 16 | 21 | 31 | 64 |
|---|---|---|---|---|---|---|---|
| partial lines | 0 | 0 | 0 | 0 | 11 | 39 | 54 |
| coverage % | 99.47 | 99.47 | 99.47 | 99.47 | 99.21 | 93.27 | 73.58 |

**The dropout knee is between 16 and 21 pixel clocks.** `sdram_simple` with no
shadows lands at 21.2 — just past it. `sdram_openrow` lands at 3.7 — far below
it. That is the mechanism: the shadows exist to keep MO fetch latency under the
knee, and the controller now does that on its own.

The residual `missing=64` is line y=239 in **every** cell including the
reference — a pre-existing property of the bench, not a dropout.

### 5.1 How much to trust this

- It couples **two instruments with one number** (measured latency → MO engine
  bench). It is not one unified simulation.
- `GFX_LAT` is a *constant* latency; real latency has a distribution. The mean
  is used. The measured **worst case** (668 clk = 134 px) cannot be modelled at
  all — see the defect below.
- It is simulation. The real dropout figure of record is **1.25e-3 per
  robot-object-frame** for BUILD 110, measured by a different detector on
  hardware. **This work has not been placed on that scale**, and doing so needs
  a device.

### 5.2 Bench defect found, reported not worked around

`sim/tb/tb_mob_perf.v` declares `reg [6:0] lat [0:3]` and assigns
`lat[k] <= GFX_LAT[6:0]`. **Any `GFX_LAT ≥ 128` silently truncates mod 128.**
`GFX_LAT=134` behaves as 6 and reports a perfectly clean frame — which is how
it first appeared in my sweep, breaking monotonicity.

Anyone testing a high fetch latency gets a spuriously green result. The default
8 and the 31 in the file's own header both fit, so **nothing in the gate set
exposes this.** Valid range is ≤ 127. Not fixed here (that file belongs to the
MO work another agent is in); flagged for the owner.

---

## 6. Synthesis and timing

See §9 for the CI run and its numbers.

Baseline for comparison: setup **+5.225**, hold **+0.090**, **M10K 299/308**.
`BUILD_ID` is deliberately **not** bumped (still `0x3112`) — a `BUILD_ID` change
alone has been measured to move hold by **0.157 ns**, which would confound
exactly the comparison this branch exists to produce.

The controller adds four 13-bit row registers and a 4-bit valid vector (56
flip-flops) plus three 8-bit comparators. It should be **M10K delta 0** — it
adds no storage — but that is a prediction until the fit report says so.

Per `docs/DEVIATIONS.md` D5, hold on this design moves ±0.157 ns from
placement perturbation alone, which is **larger than the margin itself**. A
small hold movement in either direction from this change is **not evidence of
causation**, and the 0.150 ns gate warning is a warning, not a failure.

---

## 7. The third lever: raising `clk_sdram`

Assessed, not built. Summarised here because it bears on whether any of the
above is necessary.

**The evidence that pinned the clock at 35.795455 MHz does not survive
inspection.** Commit `323e854` ("v22: SDRAM 42.95 → 35.8 MHz … stability
build") named its own reasoning: *"the remaining common factor for every
symptom is SDRAM read integrity"*. That hypothesis was then tested by a
purpose-built instrument — the v23 read-integrity scrubber — and **refuted
every time it ever reported**:

- v29: *"roving scrubber swept the ENTIRE image (every SDRAM row/bank) with
  ZERO errors across boots, soft resets and relaunches"*
- v65: one full 2.2 MB sweep, zero errors
- LANE3g final verdict `0100`: full pass, zero errors

There is **no commit, doc or comment in 462 commits reporting a non-zero
scrubber error count at any clock frequency.** The symptoms v22 blamed on read
integrity were later traced to an FSM state collision (v44), the wrong
chip-clock phase (v45), a missing playfield fetch/show handshake (v68), and an
entirely unconstrained SDRAM I/O interface (v76–78). v22's capture-margin
arithmetic was `T/2` **at 180°** — the phase v45 proved wrong.

So the clock is a real candidate. Three things constrain it:

1. **Setup headroom.** Worst setup `+5.488 ns` on a 27.936 ns period puts the
   SDRAM-domain critical path near **22.45 ns**, which caps the clock around
   **44.5 MHz** on the current fit — below even the 7:1 (50.11 MHz) candidate.
   *But* that slack reflects where Quartus **stopped**, not the achievable
   minimum; given a tighter constraint the fitter will work harder. This is the
   same argument `docs/TIMING.md` §13.3 makes about hold, and it cuts both
   ways. **Only a real build settles it.**
2. **Reachable ratios.** All five PLL outputs are integer multiples of
   7.159091 MHz. The next integer-ratio step up from 5:1 is **10:1 =
   71.590909 MHz**; everything between is a non-integer rational ratio. The VCO
   and counter solve are **not in the repo**, so what is reachable without
   re-solving the whole PLL cannot be determined from source — and re-solving
   risks perturbing the 7.159091 MHz pixel clock that `docs/DEVIATIONS.md`
   pins the 59.9227 Hz refresh rate to exactly.
3. **The decisive risk is unfalsifiable in CI.** There is **no
   `set_input_delay`/`set_output_delay` on any SDRAM pin** — they were removed
   at v77 and never restored. Quartus does not time that interface at all. It
   will report green while the part's setup/hold at the pins is violated. The
   90° chip-clock phase is a **hand-swept empirical constant** (`da603ea`,
   found by trial to fix a *silent wrong-row data corruption*), and 90° is a
   fixed *angle* — its absolute skew halves if the frequency doubles. A clock
   raise would very likely need a re-sweep, and the failure mode is
   valid-looking data from the wrong row.

**Recommendation on the clock.** Worth trying, on its own branch, but it is
**not** the low-risk option it first appears, and it should not be sequenced
ahead of this work: the decisive question (does DQ capture still close?) can
only be answered on the device, whereas the open-row+bank result is
simulation-provable *now*. If it is attempted, restoring the deleted
`set_input_delay`/`set_output_delay` block from `926b3a2` is a prerequisite for
the experiment to produce a number rather than another anecdote.

There is a genuine bonus if it works: the exact 5:1 phase-aligned ratio is the
documented **cause** of the design's hold fragility (`docs/TIMING.md` §10b —
every fifth SDRAM edge coincides with a pixel edge, a 0.002 ns hold
relationship across 4,266 paths). A non-integer ratio would break that
coincidence up. **No analysis of a non-integer ratio exists anywhere in this
repo** — that is a real gap in the record.

---

## 7a. Do the two branches compose?

Yes, and they compose multiplicatively in the useful direction — but one
parameter has to move, and the reason it currently gets away without moving is
worth knowing.

Service latency for a row hit is 4 SDRAM clocks. In CPU-clock terms, which is
what the 4-clock bus cycle actually cares about:

| | 35.795455 MHz (5:1) | 50.113637 MHz (7:1) |
|---|---|---|
| `sdram_simple`, every access (15 clk) | 3.00 CPU clocks | 2.14 |
| `sdram_openrow`, mean (6.15 clk) | 1.23 CPU clocks | **0.88** |
| `sdram_openrow`, row hit (4 clk) | 0.80 CPU clocks | **0.57** |

Combined, the mean access drops inside a single CPU clock.

`sdram_openrow` was run against the JEDEC checker at 19.954662 ns: **0
violations** across modes 0, 6 and 7 (clean, cross-bank write/read, same-row
read-after-write), with the tighter requirements the higher clock imposes
(tRCD 2, tRP 2, tRAS(min) 3, tRC 4, tRFC 4).

**The caveat.** `T_RAS_CLK` defaults to **2**, which is correct at 35.795455 MHz
and **below the 3 clocks tRAS(min) needs at 50.113637 MHz**. No violation
appears anyway, because the FSM cannot structurally precharge sooner than about
five clocks after an ACTIVE — every path to a precharge goes through a
completed access or an S_IDLE refresh decision. So the guard is not what is
keeping it legal; the state machine's shape is.

That is a latent fragility, not a safety margin. A combined build should pass
`T_RAS_CLK(3)` explicitly so correctness comes from the parameter rather than
from an emergent property nobody is checking. The parameters exist precisely so
this is a one-line change rather than a rediscovery.

---

## 7b. Head to head: the clock alone also does it

The coordinator asked this explicitly, so it was measured with the same rig:
the shipping `sdram_simple` FSM, unchanged, at 50.113637 MHz (7:1), one frame
= 836,306 clocks.

| | baseline 35.8 MHz | **clock only** 50.1 MHz | **open-row+banks** 35.8 MHz |
|---|---|---|---|
| FSM changed? | — | **no** | yes (new module) |
| MO served | 5,606 / 8,185 = **68.5%** | 8,185 / 8,185 = **100%** | 8,185 / 8,185 = **100%** |
| MO demand→ack, **pixel clocks** | mean 21.2, worst 134 | mean **10.1**, worst 61 | mean **3.7**, worst 20.2 |
| MO frame: partial lines | **11** | **0** | **0** |
| MO frame: coverage | 99.21% | **99.47%** | **99.47%** |
| margin to the 16–21 px dropout knee | none — past it | **1.6–2.1×** | **4.3–5.7×** |

**Both levers independently achieve the objective in simulation.** The shadows
can come out either way. That is a better position than expected, and it makes
the choice a risk question rather than a capability one.

Where they differ:

- **Clock only** leaves `sdram_simple` — five freeze fixes, ~25 builds of
  debugging — completely untouched. That is a large and real advantage. Its
  cost is that the decisive risk is **unfalsifiable in CI**: the SDRAM pins
  carry no timing constraints, so a green build says nothing about whether DQ
  capture still works at the chip, and the 90° phase is a hand-swept constant
  whose absolute skew this change alters (see `docs/SDRAM_CLOCK.md` §6). It
  also has the **thinner margin** — mean 10.1 px against a knee at 16–21, and a
  worst case of 61 px that is well past it. A busier scene than the 103-sprite
  frame measured here would eat that first.
- **Open-row + banks** carries FSM risk, but that risk is the kind simulation
  can attack, and it was attacked: wrong-row serve, refresh-with-open-bank,
  every JEDEC minimum, cross-bank write/read-back, same-row read-after-write —
  all gated, all with the detector proven able to fire. Its margin is **3×
  larger**, and its worst case (20.2 px) sits at the knee rather than far past
  it.
- **Together** a mean access is 0.88 CPU clocks (§7a).

**Recommendation.** Try the clock branch on hardware **first** — it is the
smaller change, it achieves the objective, and the only way to learn whether
its risk is real is to flash it. If DQ capture holds at 50.113637 MHz, that is
the cheapest route to the accuracy win and the FSM never has to be touched. If
it does not hold, the open-row branch achieves the same end with more
simulation evidence behind it and no change to the chip interface at all.

They are not alternatives that have to be chosen between permanently — §7a
shows they compose.

---

## 8. What is NOT proven

Listed so nobody mistakes this for a finished result.

1. **Nothing has run on hardware.** Not one number here is a device
   measurement.
2. **The arbiter in the bench is a reimplementation**, not the shipped RTL.
   Conditions are quoted verbatim beside the code, but drift would be silent.
   `core_top.v`'s read arbiter still has **no simulation coverage** — the
   `mk_pf_reset_slice.py` verbatim-extraction approach would fix this and was
   not done here.
3. **Concurrent write + read is not gated.** The download path writes; the
   traffic bench holds `wr_req` low. The write/read-back path is covered only
   by the model gate's clean run.
4. **The extra CPU's address locality is assumed**, not measured — the video
   trace offset by `+0x080000`. `tb_escape_core.vhd` never released the extra
   CPU in the captured window.
5. **The captured CPU trace is early boot**, not gameplay. Mitigated by the
   sweep in §2.3, not eliminated.
6. `CL_EFF = 1` is **calibrated, not derived** (§1.1). Absolute-latency claims
   are not supported; between-variant comparisons are.
7. The **dropout rate has not been placed on the 1.25e-3 scale** used for
   BUILD 108/110/112.
8. The MO **worst-case** latency cannot be modelled by `tb_mob_perf` at all
   (§5.2).

---

## 9. Gate and CI results

### 9.1 Synthesis — a true A/B, not a comparison against prose

Two CI builds from the **same tree on the same day**, differing only in
`localparam SDRAM_OPENROW_EN`. That matters: comparing against the recorded
baseline figures would fold in every unrelated change between that build and
this one.

| | control `EN=0` (32815732669) | experimental `EN=1` (32814970038) | **branch tip** (32817070783) |
|---|---|---|---|
| **M10K** | **299 / 308** | **299 / 308** | **299 / 308** |
| worst setup | +5.627 ns | +5.456 ns | +5.476 ns |
| worst hold | +0.007 ns | +0.091 ns | +0.053 ns |
| all 64 rows | non-negative | non-negative | non-negative |
| gate | PASS (margin warning) | PASS (margin warning) | PASS (margin warning) |

**M10K delta is 0 in all three.**

The three hold figures are worth pausing on, because they are the best
demonstration of D5 this branch produced. The tip build differs from the
`EN=1` build by **one flip-flop** — `refresh_age` widened 6 bits to 7, with no
functional change at `DEFER_CAP=48`. That alone moved worst-case hold from
**+0.091 to +0.053 ns**. Across three builds of functionally equivalent RTL the
spread is **+0.007 / +0.053 / +0.091**, i.e. 0.084 ns, entirely from placement.

So: **do not read any hold number on this branch as caused by the controller
change.** D5 says ±0.157 ns of placement perturbation, larger than the margin
itself, and this branch reproduced it by accident while trying to measure
something else. All three builds pass all 64 rows; all three trip the 0.150 ns
margin warning, as the baseline does; it is a warning, not a failure.

**M10K delta is 0**, as required — the controller adds registers and
comparators, no storage. M10K was the binding constraint (299/308 = 97%), so
this is the number that had to be zero, and it is.

Logic cost, from the fit reports:

| | control `EN=0` | experimental `EN=1` | delta |
|---|---|---|---|
| the controller entity itself | `sdram_simple` **79.8 ALMs** | `sdram_openrow` **328.6 ALMs** | **+248.8** |
| whole design, ALMs | 12,740 / 18,480 (69%) | 13,527 / 18,480 (73%) | +787 |
| whole design, registers | 10,283 | 11,671 | +1,388 |

**Only ~249 of the +787 ALMs are the controller**, and roughly 254 of the
+1,388 registers. The module is about 4× the size of `sdram_simple`, which is
what per-bank row tracking, the hit comparison and the bank map cost, and is
unsurprising.

**The remaining ~538 ALMs and ~1,134 registers are elsewhere in the design and
are NOT attributed here.** The most likely explanation is that physical
synthesis made different retiming and register-duplication choices against a
different critical path — the compile log shows those passes running — but that
is a hypothesis, not a measurement. It was not isolated. What can be said is
that ALMs are not the binding resource on this design (73% against an M10K
ceiling already at 97%), so the headroom exists either way.

**The hold difference is not evidence of anything.** `docs/DEVIATIONS.md` D5
records ±0.157 ns of movement from placement perturbation alone — larger than
either number here. Note the *control* landed at **+0.007 ns**, far thinner
than the +0.090 in the recorded baseline, from RTL that is functionally the
shipping design. That is D5's lottery, and it is the reason no causal claim is
made in either direction. Both builds trip the 0.150 ns margin warning; so did
the baseline; it is a warning, not a failure.

### 9.2 Gates

| gate | result | the number that matters |
|---|---|---|
| `run_sdram_model_tb.sh` (openrow) | **PASS** | all 8 modes; wrong-row mutation caught 600/600 |
| `run_sdram_model_tb.sh` (simple) | **PASS** | all 8 modes — the modes test the hazard, not the module |
| `run_sdram_refresh_tb.sh` (openrow) | **PASS** | worst 216 clk / 6.034 µs; **both** controls rejected |
| `run_sdram_refresh_tb.sh` (simple) | **PASS** | worst 224 clk / 6.258 µs; both controls rejected |
| `run_prio_tb.sh` | **PASS** | 507904 / 507904 = 100.0000% |
| `run_mob_tb.sh` | **PASS** | MOB PRIO 100.0000%; VS-MAME `wrong_pen=0`, 10047/10047 |
| `run_mob_order_check.sh` | **PASS** | 9 cells, `b_shorter=0` in every one |
| `run_psram_tb.sh` | **PASS** | 41.0 ns headroom; control rejected with real violations |
| `run_pf_tb.sh` | **PASS** | 9600 cells, 0 mismatches, `issueB=4021` non-zero |
| `run_pf_reset_tb.sh` | **PASS** | — |
| `run_stain_tb.sh` | **PASS** | 11320 / 11320 stained px; fixture has 16680 stained px |
| `run_cadence_tb.sh` | **PASS** | exact count, all three decoys rejected |
| `run_tasrace.sh` | **PASS** | six cells; see §9.3 |
| `run_vshad3_tb.sh` | **PASS** | 4 / 4 rows |

Two notes on gates that did not simply pass:

- **`run_mob_order_check.sh` failed on its default ref — since FIXED at
  source, and my diagnosis of the cause was wrong.** Its default is
  `BASE_REF=origin/mo-chan4`; `git show` exited 128 and the gate died in 0 s. I
  inferred the branch "was never pushed". It was — it was later **deleted in a
  branch prune**, so this was not a latent defect in the script but a ref that
  went away underneath it. Run here with `BASE_REF=mo-chan4`: **PASS**, 9 cells,
  `b_shorter=0` in every one.
  Fixed at source since, along with a **second and worse bug found in the same
  file**: its docker step piped stdout *and stderr* to `/dev/null` with no error
  handling, so under `set -e` any docker failure aborted the whole script with
  docker's exit code and **zero output** — a gate that dies silently and blames
  nothing. A guard now also refuses a base whose `escape_mob.v` is identical to
  HEAD's, which would make the comparison vacuous.
- **`run_vshad3_tb.sh` was invalidated by me, not by the change.** I removed
  orphaned Docker containers while it was mid-run and killed one of its cells,
  which then reported "the bench produced no result at all". Re-run clean —
  see §9.3.

### 9.3 The two long gates

**`run_tasrace.sh` — PASS, six cells.** The three "expect the bug" cells
produced **real** violation counts, which is the property the brief calls out:

| cell | result |
|---|---|
| `clr.b` release, `TASLOCK_EN=0` | **51** foreign stores inside a TAS |
| `clr.b` release, `TASLOCK_EN=1` | 0 foreign stores; interlock engaged 255× (207 writes) |
| `move.b` release, `TASLOCK_EN=0` | **104** foreign stores; 51 of 414 trials ownerless |
| `move.b` release, `TASLOCK_EN=2` DTACK-only | **156** foreign stores |
| `move.b` release, `TASLOCK_EN=1` | 0 foreign stores; interlock engaged 208× (156 writes) |
| never-wedge, stuck LOCK adversary | both CPUs survive; worst single stall 64 clks |

51 / 104 / 156 — the counts the brief requires. The bench is measuring, not
passing vacuously.

**`run_vshad3_tb.sh` — PASS, 4/4 rows**, on a clean re-run. An earlier run
reported "the bench produced no result at all" on one cell. That was **my
fault, not the change's**: I removed orphaned Docker containers while the gate
was mid-run and killed one of its cells. Recorded rather than quietly re-run,
because a gate failure with an innocent explanation is exactly the kind of
thing that should not be waved away without naming the cause.

### 9.4 Clock branch CI — `sdram-clock-EXPERIMENTAL`

Run 32815667926, **success**. 50.113637 MHz, shadows off by default.

| | 35.795455 MHz control | 50.113637 MHz | 
|---|---|---|
| M10K | 299 / 308 | **299 / 308** |
| worst setup | +5.627 ns | **+4.534 ns** |
| worst hold | +0.007 ns | **+0.110 ns** |
| all 64 rows | non-negative | non-negative |

Confirmed from the fit report artifact, not inferred: `outclk_2` and `outclk_3`
solved to **50.113636 MHz** and `outclk_0` stayed at **7.15909 MHz**, so the
59.9227 Hz refresh rate is untouched. No PLL frequency warnings; zero critical
warnings in either build.

**This refutes the setup-headroom ceiling estimated in §7.** That estimate —
critical path ≈ 22.45 ns from the +5.488 ns baseline slack, so a cap near
44.5 MHz — is wrong, and wrong in the way `docs/TIMING.md` §13.3 predicts:
reported slack shows **where Quartus stopped**, not what it can achieve. Asked
for a 19.95 ns period it delivered one with 4.5 ns to spare. **The internal
logic would very likely close higher still.**

#### The hold-path composition changed, and the obvious reading is wrong

Worst 30 hold paths on the clock branch: **20 jt51 FM, 1 TMS5220, 9 other —
and not one `gpll[2] → gpll[0]` cross-domain path.** (The single `gpll[2]` entry
is `recheck_ctr → recheck_ctr`, same-domain.) At 5:1, BUILD 110's worst 20 were
*10 playfield CDC* / 9 jt51 / 1 APF bridge — the CDC family was half of it.

It is tempting to call that the two-for-one fix for D5. **It is not, and the
mechanism says so.** 7:1 is still an *integer, phase-aligned* ratio: every
seventh SDRAM edge lands exactly on a pixel edge, so the coincident-edge
relationship D5 describes is unchanged in principle. Nothing structural has
been fixed. The most likely explanation is placement — the same lottery D5
warns about, in the favourable direction for once.

**Actually breaking the coincidence needs a NON-INTEGER ratio, which was not
tested, and which no analysis in this repo has ever covered.** That remains the
open question, and it is the one worth pursuing if D5 is to be fixed rather
than re-rolled.

---

## 10. Recommendation

0. **The clock branch also achieves the objective, without touching the FSM.**
   Measured, not assumed (§7b). Try it on hardware first; it is the smaller
   change. Its risk is real but unfalsifiable in CI, and its margin to the
   dropout knee is 3x thinner than the controller change's.
1. **Open-row and bank interleaving should land together or not at all.**
   Measured separately, each alone is worth ~0.4 clocks of service latency
   against a leaner-FSM control — inside the noise of the change's own risk.
   Together they take service latency from 14.12 to 6.15 clocks and MO
   demand-to-ack from 106 to 18.7.
2. **Bank interleaving is justified by the Stage 1 split** — 87.4% of misses
   are client switches — and its blast radius turned out to be one function
   inside one module, not the ROM pipeline the brief feared.
3. **The shadows can come out** (simulation): 11 partially-rendered lines → 0,
   coverage back to the reference 99.47%. That is the accuracy win the owner is
   buying — 4-clock CPU bus cycles *and* no sprite dropouts.
4. **Do not merge on this evidence alone.** The residual risk is concentrated
   in exactly the places simulation cannot reach: the sub-cycle DQ capture
   relationship (§1.1) and the real device's behaviour with rows held open
   across a refresh boundary. This wants a device A/B behind the
   `SDRAM_OPENROW_EN` localparam before it goes near the alpha line.
