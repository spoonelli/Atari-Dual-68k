# Where this core deviates from the real board

Two reference authorities, in this order of precedence:

1. **The schematics** (`reference/schematics/Escape_Schematic_Package.pdf`) — what the
   hardware actually is.
2. **MAME's `eprom.cpp` driver** — a behavioural reference, cross-checked against (1).

Where they disagree the schematic wins, with one recorded exception (CPU type, below).
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
| B1 | **Shared RAM is single-ported behind a mux arbiter** (EWAI / PAL16L8 50P, sheet 5 designators 40M/50M/30M), which makes 68000 read-modify-write naturally indivisible | True dual-port RAM plus an **explicit TAS interlock** keyed on the operand address | Functionally equivalent, structurally different. Verified: 114 ownerless locks in 306 trials without it, **0 in 514 with it**. This was the project's dominant bug. |
| B2 | **Motion-object line buffer self-clears as it is read** (MOHLB) | Was a 1-bit frame-parity staleness tag; **now self-clearing as of BUILD 108** | Fixed. The 1-bit tag let two-frame-old entries read back live — the horizontal dash artifact. |

## C. Behavioural — schematic taken over MAME

| # | Subject | Resolution |
|---|---|---|
| C1 | Autovectored IRQs | Schematic |
| C2 | SLAPSTIC | Schematic |
| C3 | Serial SCOM link | Schematic (894.9 kHz, NMI per byte; instant delivery let a fast CPU NMI-storm the sound 6502) |
| C4 | Vblank latch | Schematic — sheet 7 shows **ONE** 60M LS74 flip-flop, not per-CPU latches. Modelling per-CPU latches killed builds 87-92. |
| C5 | **CPU type** | **MAME, not the schematic.** The schematic labels U68010; production boards carry 68000s. The one recorded case where MAME wins. |

## D. Known remaining gaps — measured, not yet closed

| # | Gap | Measured | Notes |
|---|---|---|---|
| D1 | **Video-CPU cadence tail** | median **0.973** vs MAME **0.9977**; p10 **0.703**, min **0.313** | The median is nearly right; the whole gap is in the tail. This is the perceived sluggishness in crowds. BUILD 109 (`VSHAD3_EN=0`) is the A/B against it. |
| D2 | World-CPU cadence | **0.984** vs MAME **0.9999** | Near-authentic. The original uses only 48% of its cycle budget; this gap is not worth chasing. |
| D3 | **Sprite "blocks that did not write"** | Not reproduced by three independent detectors | Enclosed-black: **0 ours vs 11 MAME**. Hole rate indistinguishable across builds. Fetch-latency knee refuted three ways. **A sprite fetching wrong-but-plausibly-coloured data cannot be caught by any statistical shape test** — needs a scene dump of the exact failing moment. |
| D4 | 33-pixel VS-MAME deviation at scroll 50/157 | Identical on 105/106/107 | Pre-existing, not a regression. Likely an un-wrapped `spr_right` in off-screen rejection. |
| D5 | Hold-slack margin | +0.005 ns on the playfield fetch ring (`vg_dataB -> pfring`) | Placement perturbation, not our logic: **changing `BUILD_ID` alone moved it 0.088 ns**. Wants a hold multicycle, which is an SDRAM-region change. |

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
