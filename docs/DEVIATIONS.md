# Where this core deviates from the real board

Two reference authorities, in this order of precedence:

1. **The schematics** (`reference/schematics/Escape_Schematic_Package.pdf`) — what the
   hardware actually is.
2. **MAME's `eprom.cpp` driver** — a behavioural reference, cross-checked against (1).

Where they disagree the schematic wins — except on CPU type (C5 below), where they did
not actually disagree: SP-332 documents the **dedicated** cabinet, which is a 68010,
while MAME's `M68000` matches the **JAMMA** variant. Both references were right about
different boards. It is measurably immaterial to this core either way.
This file lists every known place our implementation is *not* the board. Some are
unavoidable consequences of the target hardware; some are open bugs; a few are choices.

---

## A. Structural — no hardware equivalent, unavoidable on this target

These exist because an FPGA with SDRAM is not a 1989 arcade board with mask ROMs.
None of them are "wrong", but all of them are places where our timing can differ.

| # | Deviation | Why it exists | Observable consequence |
|---|---|---|---|
| A1 | **SDRAM + PSRAM replace discrete ROM/SRAM** | The Pocket has no room for 2.2 MB of parallel ROM | Introduces arbitration, latency and refresh that the board does not have. Root of several bugs below. |
| A2 | **SDRAM refresh** | SDRAM requires it; the board's SRAM/ROM do not | Consumes ~6.9% of SDRAM cycles. **Has no analogue on the board at all.** An out-of-spec interval was corrupting graphics until BUILD 106. |
| A3 | **ROM shadowing into BRAM** (`vshad*`) | Reduce SDRAM pressure | The board fetches from ROM directly at a fixed cost. Ours copies to BRAM, which costs **5 clocks/bus cycle vs 4** on the fastpath. Measured, and the reason BUILD 109 exists. |
| A4 | **Speculative fastpath** (`FASTPATH_EN`) | Hide SDRAM latency from the CPUs | Predicts the CPU's address to start a fetch early. **No hardware equivalent.** Tag-compared before use, so it cannot serve wrong data, but it is pure invention. |
| A5 | **Non-integer video scaling** | 336x240 into 1440x1080 | Every 1-px feature is drawn 4 or 5 px thick depending on position (measured: period-9 fold contrast 12.3x). Causes visible shimmer on this game's 1-px diagonals. **In the scaler, not the core — no RTL change can fix it.** |
| A6 | **EEPROM autosave to APF storage** | The Pocket has no battery-backed EEPROM chip | Board persists continuously; we snapshot ~1.17 s after the last write. |

## B. Structural — where we chose a different mechanism for the same behaviour

| # | Board | Ours | Status |
|---|---|---|---|
| B1 | **Shared RAM is single-ported behind a mux arbiter** (sheet 5: SRAMs 40M/50M, LS158A mux 30M with SEL = EWAI, ownership from a cross-coupled NOR latch 60N/20J; wait states from the 163 counters at 30D/30L — **50P is the ECPU address decoder, not the wait-state generator**), which makes 68000 read-modify-write naturally indivisible | True dual-port RAM plus an **explicit TAS interlock** keyed on the operand address | Functionally equivalent, structurally different. Verified: 114 ownerless locks in 306 trials without it, **0 in 514 with it**. This was the project's dominant bug. **We reproduce indivisibility but not contention**: measured common-bus rates are 2,742/frame (video) and 5,462/frame (world), implying ~502-753 collisions/frame and **0.8-1.9% of each CPU's frame** spent stalled on the real board — a cost neither we nor MAME model. Rebuilding the board's structure is analysed and **not recommended before alpha** in [`CPU_AND_ARBITER.md`](CPU_AND_ARBITER.md) §2: zero M10K saved, ~1-2% slower, and **not actually atomic on TG68K**, which releases `/AS` for 3 clocks mid-RMW. |
| B2 | **Motion-object line buffer self-clears as it is read** (MOHLB) | Was a 1-bit frame-parity staleness tag; **now self-clearing as of BUILD 108** | Fixed. The 1-bit tag let two-frame-old entries read back live — the horizontal dash artifact. |

## C. Behavioural — schematic taken over MAME

| # | Subject | Resolution |
|---|---|---|
| C1 | Autovectored IRQs | Schematic |
| C2 | SLAPSTIC | Schematic |
| C3 | Serial SCOM link | Schematic (894.9 kHz, NMI per byte; instant delivery let a fast CPU NMI-storm the sound 6502) |
| C4 | Vblank latch | Schematic — sheet 7 shows **ONE** 60M LS74 flip-flop, not per-CPU latches. Modelling per-CPU latches killed builds 87-92. |
| C5 | **CPU type** | **CLOSED — there were two boards, and both are authentic.** Confirmed from photographs: the **dedicated cabinet is a 68010** (`MC68010P8`, Motorola, date code `A71R8813`; SP-332 — which is the dedicated-cabinet package — draws both CPUs `U68010`, sheet 4 designator **45J** `VCPU`, sheet 5 designator **20P** `ECPU`), and the **JAMMA version is a 68000**. Nobody was wrong: the schematic describes the dedicated board, and MAME's `M68000` faithfully describes the **JAMMA** board. **Every shipped build up to and including BUILD 109 ran `CPU => "00"` and was therefore a faithful JAMMA machine** — not an error, just the other cabinet. (The one thing that *was* wrong is the old claim that production boards carry 68000s *as against the schematic*; it came from one unphotographed inspection in `24d900e`, was written up as "photo-verified" when no photo existed, and is retracted.) It changes nothing measurable in either direction: the ROM contains **no** MOVEC/MOVES/RTD on any reachable path (0 illegal-instruction and 0 privilege exceptions in 400 s / 24,000 frames, detector falsified 4 ways), all 7 `MOVE SR` sites run with S=1 so the privilege change is inert, only **8 `RTE` opcode words exist across both 512 KB images** and every reachable one pops exactly what its handler pushed with **no pointer arithmetic around the frame**, and **0.0000%** of the video CPU's per-frame work sits in a loop-mode-eligible `DBcc` loop (ceiling over *all* DBcc loops: 0.137%, vs a 2.5% cadence gap) — and TG68K implements no loop mode regardless. **Both variants are supported** via the `CPU_TYPE` generic on `escape_core` (0 = 68000/JAMMA, 1 = 68010/dedicated), overridden in one place -- the `localparam CPU_TYPE` in `core_top.v`. It defaults to **1 (dedicated / 68010)** as of BUILD 110; 109 and earlier were `0`. The variant is **not** inferable from the ROM set (MAME's `eprom`/`eprom2` differ only by program-ROM revision, and all sets are `M68000`), so it has to be a configuration choice rather than something the core detects. See [`CPU_AND_ARBITER.md`](CPU_AND_ARBITER.md) §1.6. |

## D. Known remaining gaps — measured, not yet closed

Two of the original rows are **closed** and kept below (struck) so the history of the
claim stays visible; D4 and D5 remain open.

| # | Gap | Measured | Notes |
|---|---|---|---|
| D1 | ~~Video-CPU cadence tail~~ **CLOSED (MOPAIR-131 / MOPF2-132)** | Attract-loop period on device **5992–5994** frames vs MAME **6013** (**0.35%**, and in the *faster* direction); the demo scene MAME half-rates by 1.6% runs at **0.0%** drop on device; the heaviest crowd scene slows **23–34%** on device vs **39–51%** in MAME's longplay (same scroll-velocity estimator on both) | The pre-131 figures this row used to carry (median 0.973, p10 0.703) measured the single-bank MO engine, whose line-buffer fill was eating the bus the video CPU needed. The paired line buffers (MOPAIR-131) and the tile-1 prefetch lane (MOPF2-132) removed the contention; the residual slowdown is *smaller than MAME's own 68000 model*, consistent with the 68010 this cab runs. The core never runs faster than authentic. Walk-cycle cadence locks the frame rate: exactly **8 frames/phase** against all four reference-cab captures. Original tail analysis preserved in [`investigations/PERF_CADENCE.md`](investigations/PERF_CADENCE.md). |
| D2 | World-CPU cadence | **0.984** vs MAME **0.9999** | Near-authentic. The original uses only 48% of its cycle budget; this gap is not worth chasing. |
| D3 | ~~Sprite "blocks that did not write"~~ **CLOSED (MOPAIR-131 / MOPF2-132)** | Crowd fixture missing pixels **527 → 0**; worst-case 16-line fetch latency **153 → 34**; device captures across two full playthroughs show no dropouts | The statistical detectors were right that the *shipped* builds' holes wouldn't reproduce on the bench — the failure needed real-traffic fetch latency. The schematic answer (SP-332 sheet 9: the real board fills **paired** line buffers, 2 px/DCLK) became MOPAIR-131; 71% of the remaining steady-state stall was one sprite's second tile, which the MOPF2-132 prefetch lane removed. Hunt record: [`investigations/MO_TILE_HOLES.md`](investigations/MO_TILE_HOLES.md). |
| D4 | 33-pixel VS-MAME deviation at scroll 50/157 | Identical on 105/106/107 | Pre-existing, not a regression. Likely an un-wrapped `spr_right` in off-screen rejection. |
| D5 | Hold-slack margin | Structurally thin on the playfield fetch-ring CDC (`vg_dataB[27] -> pfring0..3[27]`, launch gpll[2] 35.8 MHz, latch gpll[0] 7.159 MHz). Across six builds worst-case Fast-0C hold has ranged **+0.005 to +0.103 ns, and once to -0.054 (gate failure)** | Placement perturbation, not our logic: `BUILD_ID` alone has moved it **0.088 ns** (BUILD 108) and **0.157 ns** (BUILD 110). The margin is smaller than the perturbation sensitivity, so any edit re-rolls it. Root cause: gpll[2] is exactly 5x gpll[0] and the PLL outputs are phase-aligned, so every fifth SDRAM edge coincides with a pixel edge and the hold relationship is **0.002 ns** - hold is decided purely by routing skew. SDSCHED-73 groups all four PLL outputs synchronous on purpose, and this is its price. **BUILD 110 passes at +0.103 by luck, not by fix**, and the restored per-path reporter shows its *binding* path is not this row's CDC at all but **jt51 FM audio on a same-domain gpll[0] path** - the worst 20 at Fast 0C span just 0.103-0.124 and are 10 playfield CDC / 9 jt51 FM / 1 APF bridge. This is a **cluster at the floor across three unrelated subsystems**, all latching on gpll[0], not one thin path: BUILD 107's worst was TMS5220 speech, 108's the playfield CDC, 110's jt51 FM. A CDC-only `set_multicycle_path -hold` is proposed but NOT shipped and would not widen 110's margin, though it does remove ~4,200 paths from the lottery. **SHIPPABLE: hold passes all four corners (+0.295/+0.284/+0.124/+0.103), and the fast corners ARE the hold-worst corners** - fastest silicon at the voltage/temperature extremes, with Cyclone V OCV derating applied - so there is no operating condition worse for hold than the one signed off. Unlike setup, hold margin does not erode with droop or aging. The risk is the NEXT EDIT re-rolling placement negative (as `cpu-68010` did at -0.054, caught by the gate), not the device. Global levers costed and **rejected**: gpll[0] is already a promoted Global Clock (GCLK8) carrying **9,717 loads** vs 1,366 for gpll[2], so there is no promotion left; `set_max_skew` cannot re-route a fixed GCLK spine; and the cluster's position looks to be Quartus's hold-fixing stopping criterion rather than a design property - BUILD 110's binding path is internal to **vendored jt51 IP** (a shift stage into its own `altshift_taps`), so improving skew would just mean the fitter pads less. Treat +0.10 as this design's structural floor. **The gate failure has now been reproduced and its registers named:** all 8 negative paths over 4 endpoints were `vg_dataA/B[19] -> pfring0..3[19]` - the CDC family - with the per-endpoint TNS arithmetic closing exactly at both corners (-0.201, -0.118). So the CDC family is the one that actually loses (BUILD 108's worst path, and the entire failing set at -0.054), even though jt51 happens to bind in BUILD 110. That makes a payload-only `set_multicycle_path -hold` the one worthwhile change - it would have prevented the failure - but it will **not** raise the reported worst-case slack, and the `vg_done*` control paths must stay timed. Proposed, NOT applied; apply after alpha if at all. Full analysis, the stability proof, the control-path caveat, the corrected inference and the lever costing: [`TIMING.md`](TIMING.md). |

## E. Where we match the reference exactly

Worth stating, because the list above is longer than the list of things that are wrong.

| Subsystem | Result |
|---|---|
| MO/PF priority comparator | **507,904 / 507,904 = 100.0000%** against `eprom.cpp`'s own equations |
| Motion-object renderer | **10,047 / 10,047**, `wrong_pen=0` against MAME's tail-first `atarimo draw()` |
| Stain second pass | matches `atarimo.cpp`'s `apply_stain` on every scored frame, all cases |
| Draw order | prefix-compatible in all 9 latency/scene cells, `b_shorter=0` |
| Pixel clock / refresh rate | 7.159091 MHz, **59.9227 Hz** = 7,159,090 / (456 x 262) — exact |
| ROM contents | 28/28 CRC-verified against MAME known-good |

## F. Cross-platform: where Pocket and MiSTer must NOT drift

The MiSTer playfield bug was caused by a fetch channel with no reset, because the
Pocket's equivalent sat behind a different gate. Anything both platforms share needs a
single source of truth, or a written reason why not.

### F1. SDRAM refresh interval — reconciled to ONE policy (REFRESH-111)

**Status: reconciled. `REFRESH_INTERVAL = 160`, `DEFER_CAP = 48`, both platforms.**

The same JEDEC retention violation was "fixed" three different ways on three branches,
each justified by hand arithmetic and none by measurement:

| Branch | Interval | Deferral | Believed | **Measured worst case** | Verdict |
|---|---|---|---|---|---|
| (original) | 250 | kept (48) | "2.9 µs, >2x margin" | **8.772 µs** (314 clk) | **FAIL** — 112.3% of budget |
| `mister-port` | 224 | kept (48) | "7.599 µs, in spec with ~3% margin" | **8.046 µs** (288 clk) | **FAIL** — 103.0% of budget |
| `sdram-sched` | 250 | **deleted** | — | **7.431 µs** (266 clk) | pass, but only 4.9% margin |
| `tas-atomic` (Pocket) | 160 | kept (48) | "5.81 µs worst" | **6.258 µs** (224 clk) | **PASS** — 80.1% of budget |

Limit: MT48LC16M16A2, 8192 rows / 64 ms = **7.8125 µs** per row = 279.7 clocks at
35.795455 MHz (27.936508 ns). When this reconciliation was done the SDRAM domain was
35.795455 MHz on **both** platforms, verified from the PLL IP on each, not from
comments: Pocket `src/fpga/core/mf_pllbase/mf_pllbase_0002.v`
`output_clock_frequency2`, MiSTer `src/mister/rtl/pll/pll_0002.v`
`output_clock_frequency1`. Both also used an identical +6984 ps chip clock.
Different reference clocks (74.25 vs 50.0 MHz), same output.

**Since LOWLAT-124 the platforms run different SDRAM clocks and the POLICY, not the
number, is the shared thing.** The Pocket moved to the open-row controller
(`sdram_openrow.v`) at 42.954546 MHz (exactly 6× pixel clock; the PLL IP above now
reads 42.954546) and scales the same policy by the clock ratio: interval 160×1.2 = 192,
defer cap 48×1.2 = 58, worst case 250 clocks = **5.82 µs = 74.5% of budget** — the same
`INTERVAL + DEFER_CAP + 16`-shaped bound, re-derived at 23.280 ns/clock in the
`core_top.v` controller-select comment. The MiSTer ran `sdram_simple` at
35.795455 MHz with 160/48 as tabled above until MISTER-141, when it adopted
`sdram_openrow` at the same 35.795455 MHz — with the module's conservative
default timings and the same 160/48 policy, so the reconciliation stands.
A future edit to either platform's interval must re-run
`sim/run_sdram_refresh_tb.sh`, not inherit either number.

**Everyone's arithmetic was wrong in the same safe-looking direction.** All three
branches assumed `worst case = INTERVAL + DEFER_CAP`. Measured against the real FSM the
answer is `INTERVAL + DEFER_CAP + 16` — exact across every point sampled. The missing 16
clocks are the transaction still in flight when the deferral cap expires (a
precharge-armored `rd_pre` read is 15 clocks) plus one clock to clear the read ack.
`refresh_due` is only consumed from `S_IDLE`, so the controller cannot drop what it is
doing to service a refresh.

That correction is what convicts `mister-port`: **224 is not a fix.** It was chosen to
land at 7.599 µs; it actually lands at 8.046 µs and is still out of spec — on the
platform where the playfield is *also* on this bus, which is the worse place to have a
retention violation.

**So "the two platforms legitimately need different values" is not available as an
answer here.** It would require MiSTer's value to be in spec, and it is not.

**Why 160/48 and not something cheaper.** The bound is
`INTERVAL + DEFER_CAP + 16 <= 279.7`. Keeping `DEFER_CAP = 48` (which the zero-wait CPU
fastpath was tuned against — changing it would force a retune on `mister-port`), the
largest interval that still meets spec is 215, and that lands at 99.8% of the JEDEC
budget: no engineering margin at all, for a failure mode that is silent, temperature
dependent (the 7.8125 µs figure halves above 85 °C) and manifests as graphics
corruption rather than a crash. 160 is the value that keeps ~20% margin with the
deferral intact. Measured trade-off:

| Interval (DEFER_CAP=48) | Worst case | % of JEDEC budget | Refresh occupancy |
|---|---|---|---|
| 160 | 6.258 µs | 80.1% | **6.831%** |
| 176 | 6.705 µs | 85.8% | 6.214% |
| 192 | 7.152 µs | 91.5% | 5.700% |
| 208 | 7.599 µs | 97.2% | 5.263% |
| 215 | 7.738 µs | 99.8% | 5.092% |

**Bandwidth cost.** Refresh occupancy goes 4.890% (MiSTer's 224) → 6.831% (160), i.e.
**+1.94 percentage points** of the SDRAM bus, taken from the lowest-priority client,
which is sprites. On MiSTer that bus is genuinely busier: the playfield moved onto it and
adds **13,794 read transactions per frame** (57 cells/line × 242 lines — verified from
`escape_mister.v:714`; the enqueue has no horizontal gate, so it free-runs at 57/line,
not the 42 that `docs/investigations/MISTER_PORT_RECORD.md` (its 42/line figure) assumes) = 27,588 word accesses ≈ 32.3% of frame
clocks. Pocket issues the same 13,794 fetches but as PSRAM reads on a physically
separate chip, so its SDRAM sees none of them. That is a real asymmetry — it is just not
one that can buy MiSTer an out-of-spec refresh interval. Losing ~2% of sprite bandwidth
is strictly better than corrupting the memory the sprites are stored in.

**The mechanism that stops this recurring.** `REFRESH_INTERVAL` and `DEFER_CAP` are now
module parameters on `sdram_simple` rather than hardcoded literals, defaulting to
160/48. One FSM, one source of truth; a platform that wants a different value must say
so at its instantiation, in the open, next to the other one. `mister-port`'s hardcoded
224 will now surface as a **merge conflict** in the parameter default rather than as two
files that quietly disagree.

**The gate:** `sim/run_sdram_refresh_tb.sh` measures worst-case row interval against the
real FSM. It carries **two negative controls** — the original 250/48 and
`mister-port`'s 224/48 — both of which must be reported FAIL, so the bench is proven able
to reject the specific values that hand arithmetic blessed.

**Do not re-derive this on paper. Run the bench.** The bench itself contains the same
trap in miniature: under *constant* read pressure the measured gap collapses to
`INTERVAL + 1` and every policy above looks fine, because `refresh_ctr` is reset when a
refresh becomes *due*, not when it is *serviced*, so a constant service delay cancels out
of the gap. Only a **bursty** adversary (`READ_PRESSURE=3`) — an undelayed refresh
followed by a maximally delayed one — reaches the true worst case. Two earlier, weaker
adversaries are kept in the bench precisely because they are the trap.

### F2. Deliberately divergent — the SDRAM controller and its arbiter

(An earlier F2 tracked a live CLKFIX-106 regression on the `mister-port` branch; that
branch was deleted in the pre-release prune and the regression died with it. The
current `mister` branch is a different lineage and never carried it.)

The one place the platforms are *allowed* to differ is the SDRAM subsystem, because
the bus topology genuinely differs: on the Pocket the playfield fetches from PSRAM,
so SDRAM is shared by the CPUs and the motion objects only; on MiSTer the playfield
is on the same SDRAM as everything else. Consequences, each measured on device:

- **Controller**: both platforms run `sdram_openrow` since MISTER-141 —
  Pocket at 42.95 MHz (6× pixel clock, re-derived tight timings), MiSTer at
  35.795 MHz (5×, phase-locked, near-zero-hold CDC cluster — see
  [`TIMING.md`](TIMING.md)) with the module's conservative default timings.
- **Arbiter rank**: on MiSTer the playfield outranks the CPUs (fixed-sprite streaks
  in builds ≤134 were PF scanline-deadline starvation behind CPU vblank-burst
  traffic); on the Pocket no PF client exists on this bus, so the CPUs own the top.
- **MO vs speculative CPU fills**: the Pocket's blanket "MO outranks the
  fastpath" rule was catastrophic when ported literally (builds 137/143/145:
  `escape_core` gives a blocked fastpath only 16 CPU clocks before every ROM
  fetch degrades to timeout-plus-fallback, and one variant deadlocked into
  the game watchdog). What the Pocket rule actually *produces* on its
  two-client bus is strict alternation — so MiSTer implements that property
  directly: a turn bit interleaves MO and fastpath one-for-one on contested
  cycles, with a demand-fetch escape (MOARB-146/147). Scored before
  hardware by `sim/run_mister_moarb_tb.sh`, whose gates are calibrated
  against hardware verdicts (the working arbiter measures 4% fastpath
  timeout-share; the reboot-looping one 27%; the fence is 10%).
- **MO tile mirror (MISTER-150)**: the deepest Pocket advantage is that its
  playfield has a physically separate memory (PSRAM), so PF and MO never
  evict each other's open rows. MiSTer reproduces the separation inside one
  SDRAM: the 1 MB sprite-tile region is written twice at download and the
  motion objects fetch their own copy from an otherwise-idle bank. Measured
  effect: every axis improved at once — MO worst-case latency −91%, and
  crowd-scene performance at parity with the Pocket release.

The rule this section exists for: **a bus-priority change proven on one platform is
a hypothesis, not a fix, on the other.** Port the intent, re-derive the mechanism
against that platform's client set, and re-verify on device.

## G. How to keep this honest

Every entry above is a measurement or a schematic citation, not a recollection. The
project has been burned repeatedly by checks that could not fail — a slack regex that
never matched, a 0/0 "pass", a Python model standing in for RTL, and a stain gate whose
fixture contained no stain. **If you add a row here, cite the measurement and make sure
the check that produced it has been proven able to fail.**
