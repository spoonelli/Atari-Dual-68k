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

*(filled in from the runs on this branch — see the commit that adds this
section's numbers)*

---

## 10. Recommendation

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
