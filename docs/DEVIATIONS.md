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

| # | Gap | Measured | Notes |
|---|---|---|---|
| D1 | **Video-CPU cadence tail** | median **0.973** vs MAME **0.9977**; p10 **0.703**, min **0.313** | The median is nearly right; the whole gap is in the tail. This is the perceived sluggishness in crowds. BUILD 109 (`VSHAD3_EN=0`) is the A/B against it. **Ruled out as causes:** CPU type — 68010 loop mode would save **0.0000%** here (ceiling over all `DBcc` loops 0.137%, vs a 2.5% gap), so the 0.9977 target is not too low on that account; and if anything the real board is *slower* than MAME, which models none of the ~0.8-1.9%/frame common-bus arbitration stalls. A constant few-percent term cannot produce a p10 of 0.703 anyway — the tail shape is the thing to explain. See [`CPU_AND_ARBITER.md`](CPU_AND_ARBITER.md). |
| D2 | World-CPU cadence | **0.984** vs MAME **0.9999** | Near-authentic. The original uses only 48% of its cycle budget; this gap is not worth chasing. |
| D3 | **Sprite "blocks that did not write"** | Not reproduced by three independent detectors | Enclosed-black: **0 ours vs 11 MAME**. Hole rate indistinguishable across builds. Fetch-latency knee refuted three ways. **A sprite fetching wrong-but-plausibly-coloured data cannot be caught by any statistical shape test** — needs a scene dump of the exact failing moment. |
| D4 | 33-pixel VS-MAME deviation at scroll 50/157 | Identical on 105/106/107 | Pre-existing, not a regression. Likely an un-wrapped `spr_right` in off-screen rejection. |
| D5 | Hold-slack margin | Structurally thin on the playfield fetch-ring CDC (`vg_dataB[27] -> pfring0..3[27]`, launch gpll[2] 35.8 MHz, latch gpll[0] 7.159 MHz). Across six builds worst-case Fast-0C hold has ranged **+0.005 to +0.103 ns, and once to -0.054 (gate failure)** | Placement perturbation, not our logic: `BUILD_ID` alone has moved it **0.088 ns** (BUILD 108) and **0.157 ns** (BUILD 110). The margin is smaller than the perturbation sensitivity, so any edit re-rolls it. Root cause: gpll[2] is exactly 5x gpll[0] and the PLL outputs are phase-aligned, so every fifth SDRAM edge coincides with a pixel edge and the hold relationship is **0.002 ns** - hold is decided purely by routing skew. SDSCHED-73 groups all four PLL outputs synchronous on purpose, and this is its price. **BUILD 110 passes at +0.103 by luck, not by fix**, and the restored per-path reporter shows its *binding* path is not this row's CDC at all but **jt51 FM audio on a same-domain gpll[0] path** - the worst 20 at Fast 0C span just 0.103-0.124 and are 10 playfield CDC / 9 jt51 FM / 1 APF bridge. This is a **cluster at the floor across three unrelated subsystems**, all latching on gpll[0], not one thin path: BUILD 107's worst was TMS5220 speech, 108's the playfield CDC, 110's jt51 FM. A CDC-only `set_multicycle_path -hold` is proposed but NOT shipped and would not widen 110's margin, though it does remove ~4,200 paths from the lottery. **SHIPPABLE: hold passes all four corners (+0.295/+0.284/+0.124/+0.103), and the fast corners ARE the hold-worst corners** - fastest silicon at the voltage/temperature extremes, with Cyclone V OCV derating applied - so there is no operating condition worse for hold than the one signed off. Unlike setup, hold margin does not erode with droop or aging. The risk is the NEXT EDIT re-rolling placement negative (as `cpu-68010` did at -0.054, caught by the gate), not the device. Global levers costed and **rejected**: gpll[0] is already a promoted Global Clock (GCLK8) carrying **9,717 loads** vs 1,366 for gpll[2], so there is no promotion left; `set_max_skew` cannot re-route a fixed GCLK spine; and the cluster's position looks to be Quartus's hold-fixing stopping criterion rather than a design property - BUILD 110's binding path is internal to **vendored jt51 IP** (a shift stage into its own `altshift_taps`), so improving skew would just mean the fitter pads less. Treat +0.10 as this design's structural floor. Full analysis, the stability proof, the control-path caveat, the corrected inference and the lever costing: [`TIMING.md`](TIMING.md). |

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

## F. How to keep this honest

Every entry above is a measurement or a schematic citation, not a recollection. The
project has been burned repeatedly by checks that could not fail — a slack regex that
never matched, a 0/0 "pass", a Python model standing in for RTL, and a stain gate whose
fixture contained no stain. **If you add a row here, cite the measurement and make sure
the check that produced it has been proven able to fail.**
