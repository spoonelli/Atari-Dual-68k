# Timing: what is actually thin, and how to tell whose fault it is

BUILD 108 came in at **+0.005 ns worst-case hold** on `gpll[0]`, the 7.159 MHz
CPU/pixel clock. This file records what that path is, what moved it, and the
method — because the interesting result is not the number, it is that the
obvious suspect was innocent and reasoning alone would have convicted it.

## 1. The path, named

`support/report_hold_paths.tcl` re-opens the finished project and reports the
worst hold paths with full node names. `ap_core.sta.rpt` as written by
`quartus_sh --flow compile` contains **summary tables only** — a clock, a slack
and a TNS — which is enough to gate on and not enough to act on.

BUILD 108's worst hold paths, Fast 1100mV 0C:

| slack | from | to | launch | latch |
|---|---|---|---|---|
| **0.005** | `core_top:ic\|vg_dataB[27]` | `core_top:ic\|pfring1[27]` | gpll[2] | gpll[0] |
| 0.005 | `vg_dataB[27]` | `pfring2[27]` | gpll[2] | gpll[0] |
| 0.009 | `vg_dataB[27]` | `pfring3[27]` / `pfring0[27]` | gpll[2] | gpll[0] |
| 0.077 | `vg_doneB_85` | `vg_doneB_s_q` | gpll[2] | gpll[0] |
| 0.128 | `pmp_wr_data_latch[18]` | `mf_datatable` port B | clk_74a | clk_74a |
| 0.130-0.136 | `vg_dataA/B[*]` | `pfring*[*]` | gpll[2] | gpll[0] |

It is the **playfield graphics-fetch ring handoff**: the SDRAM-domain fetch
register `vg_data*` (gpll[2], 35.8 MHz) captured into the pixel-domain ring
`pfring0..3` (gpll[0], 7.159 MHz). Nothing in the MO line buffers, the
self-clearing readout, `escape_stain.v` or the cadence meter appears anywhere
in the worst 20.

For comparison, BUILD 107's RTL puts its worst hold on **TMS5220 speech**
(0.085), then **the same `vg_dataB -> pfring` structure** (0.118), then **jt51
FM** (0.125). The design's hold-critical set is {playfield CDC, speech, FM
audio}, and has been all along.

## 2. Why that path is timed at all

`src/fpga/core/core_constraints.sdc` deliberately puts all four PLL outputs in
**one synchronous group**:

> *the four PLL outputs are one clock family (same refclk, same PLL — 85.909MHz
> = exactly 12 x 7.159MHz). Grouped SYNCHRONOUS, every CPU<->SDRAM crossing
> becomes a timed path, legalizing single-cycle handshakes in place of 3-stage
> synchronizer chains.*

So `vg_data* -> pfring*` is a **deliberately timed, deliberately single-cycle**
cross-domain handoff. The thin hold is the price of that architecture, not an
accident, and it is inside the SDRAM scheduling region this project's freeze
history lives in.

## 3. What moved it — measured, with a control

Quartus 18.1 is **deterministic**: the refit of BUILD 108's RTL (run
32775980210, identical RTL, workflow file only) reproduced **0.005 exactly**,
to the picosecond, on every row. So "variance" here does not mean run-to-run
randomness. It means **sensitivity to arbitrary perturbation**: any change
anywhere reshuffles placement, and this path's slack moves with it.

Worst-case hold on gpll[0], Fast 1100mV 0C, six builds:

| build | RTL | hold |
|---|---|---|
| BUILD 107 (`f8a29b0`) | baseline | **+0.118** |
| stain fix alone (`fae36a2`) | + self-clearing readout | **+0.124** |
| A+B+C (`f7fbac9`) | + cadence meter, VSHAD3_EN generic | **+0.093** |
| BUILD 108 (`ff93985`) | **A+B+C with `BUILD_ID` 3107 -> 3108** | **+0.005** |
| BUILD 108 refit | identical RTL | **+0.005** |
| control (`hold-ctrl-107`) | **107's RTL with only `BUILD_ID` 3107 -> 3108** | **+0.085** |

Read the last two rows together. Changing nothing but a 16-bit `localparam`
that feeds the on-screen version digits:

* moved BUILD 107's hold by **-0.033 ns** (0.118 -> 0.085);
* moved BUILD 108's hold by **-0.088 ns** (0.093 -> 0.005).

A version constant cannot create a timing path. It changes LUT masks, which
changes packing, which changes placement, which changes routing delay on a path
whose margin is a few hundred picoseconds to begin with.

**And the self-clearing readout — the obvious suspect, being new write-port
activity on a memory port in exactly this clock domain — measured +0.124,
BETTER than the +0.118 baseline it replaced.** That is also what the structure
predicts: the change puts a 2:1 mux in front of each line buffer's write port
where the address previously came straight from a register, so every path into
that port got *longer*, and hold violations come from paths that are too short.

## 4. Method, for next time

The trap here is that the story writes itself: worst hold is on the CPU clock,
the newest change added memory-port activity on the CPU clock, therefore. Three
cheap steps beat that reasoning every time:

1. **Diff the RTL between the build that was fine and the build that was not.**
   Here that was one `localparam`.
2. **Refit identical RTL.** Quartus is deterministic, so a reproduced number
   proves the input, not the fitter, changed.
3. **Name the path.** `support/report_hold_paths.tcl`, now run by CI on every
   build and uploaded with the bitstream. A named path ends the argument in
   seconds; an unnamed one costs a day of plausible theories.

Step 3 is why the reporter exists. Steps 1 and 2 cost one CI cycle each.

## 5. What the gate does now

`support/check_slack.py` still fails only on negative slack — the policy is
unchanged, and its negative and truncated controls still fail as they should.
It now also **prints the tightest row of each check** and emits a non-failing
`MARGIN WARNING` under a per-kind floor (setup 1.000, hold 0.050, recovery
0.500, removal 0.100, pulse width 0.100 ns). BUILD 108 passed silently at
+0.005; the number existed in a table nobody reads until something went wrong.
Verified against all six real reports above plus a synthetic negative and a
truncated report.

## 6. Is +0.005 ns shippable, and what would give real margin

It is **met** at the signed-off corner with TNS 0.000, and Quartus is
deterministic, so this bitstream has exactly this timing. It is not a
violation.

It is also five picoseconds, and the honest reading is that the design has a
**structurally thin CDC** that any future change can shuffle either way — as
these six builds demonstrate in both directions. If real margin is wanted, the
lever is the `vg_data* -> pfring*` handoff itself, not whatever change happened
to be in flight when a build came in thin. That is an SDRAM-path change:

* a `set_multicycle_path -hold` on that handoff would remove the pressure
  outright **if and only if** the ring's sampling is provably stable across the
  extra edges — which is a property of the playfield prefetch handshake, not of
  the SDC;
* getting it wrong there does not produce a wrong pixel, it produces a freeze,
  and this project's freeze history is entirely in that region.

So it wants its own cycle, its own bench and its own evidence. It should not be
done as a reaction to a thin number in a build whose thinness has already been
traced to a version constant.

---

# Part 2 — BUILD 109 → 110, and the precondition §6 left open

*Added 2026-08-24, after BUILD 110. Part 1 above is unchanged and still correct;
everything here extends it.*

**First, a process note, because it cost real money.** Everything in Part 1 —
this file, `support/report_hold_paths.tcl`, the CI step, and `check_slack.py`'s
margin warning — was written for BUILD 108, used successfully, and then **never
merged to `tas-atomic`**. BUILD 110 walked into the identical problem two weeks
later with none of it available: no per-path report, no margin warning, and a
day of "which change did this" reasoning that Part 1 §4 exists specifically to
prevent. The apparatus is restored by the same commit that adds this section.
**A diagnostic that is not on the shipping branch does not exist.**

## 7. Four more builds, and the same experiment run twice

Worst-case hold on `gpll[0]`, Fast 1100mV 0C, continuing Part 1 §3's table:

| build | RTL | `BUILD_ID` | hold |
|---|---|---|---|
| BUILD 109 (`tas-atomic`, run 32783187353) | baseline | 3109 | **+0.100** |
| `cpu-68010-facts` (run 32792616267) | baseline + **comments only** | 3109 | **+0.100** |
| `cpu-68010` (run 32791757713) | **+ 68010 microcode** | 3109 | **−0.054  FAIL** |
| BUILD 110 (`tas-atomic`, run 32792274601) | + 68010 microcode | **3110** | **+0.103** |

**The determinism control reproduces, independently.** Part 1 §3 established
Quartus 18.1 is deterministic via a refit. Here a *comment-only* branch — VHDL
and Markdown comments, netlist untouched — reproduced BUILD 109 across **all
twenty** slack values, with byte-identical `ap_core.sta.rpt` size. Two different
methods, same conclusion: variation tracks netlist change, never the fitter.

**And the version-constant experiment reproduces too, at larger amplitude.**
Part 1 measured `BUILD_ID` moving hold by −0.033 and −0.088 ns. This time,
against identical RTL, `3109`→`3110` moved it **+0.157 ns** — from a failing
−0.054 to a passing +0.103. BUILD 110 ships because of a version constant.

Adding the 68010 microcode moved it **−0.154 ns**. That is the same order as the
version constant, which is the whole point: **the 68010 change is not
especially expensive; it is that nothing is cheap on this path.** Every passing
build in the six now on record sits between +0.005 and +0.103 — all of them
within 0.11 ns of failing.

M10K is 283/308 in all four builds. Setup passes by ~+5.6 ns or better
everywhere. This is a hold-only, placement-only problem.

## 8. The precondition is now discharged

Part 1 §6 identified the real lever and correctly refused to pull it:

> a `set_multicycle_path -hold` on that handoff would remove the pressure
> outright **if and only if** the ring's sampling is provably stable across the
> extra edges — which is a property of the playfield prefetch handshake, not of
> the SDC

**That property holds, and here is the proof.** From `core_top.v`:

```
sdram edge S0   vg_dataB    <= {cvg_hi, cram_dout}      (:1552)
                vg_doneB_85 <= ~vg_doneB_85             (:1553)   -- same edge

pixel edge P1   vg_doneB_s_q <= vg_doneB_85             (:1351)   -- 1-flop resample
pixel edge P2   vg_doneB_last <= vg_doneB_s             (:2328)
                if (vg_doneB_s != vg_doneB_last)
                    pfring[pf_inflB] <= vg_dataB        (:2329)   -- capture HERE
                    inflB <= 1'b0
```

Capture at **P2** is one full pixel period after **P1**, and P1 is at or after
S0. So `vg_dataB` is stable for **≥ 1 full `clk_sys_7159` period = ≥ 139.7 ns**
when `pfring` samples it, against a hold requirement of ~0.6 ns — roughly
**230×**.

It cannot change sooner, and that is structural rather than lucky: `vg_dataB` is
rewritten only by another channel-B completion, and no new channel-B fetch can
issue until `inflB` clears — which happens at P2, in the same clause as the
capture, and is guarded again at the issue site (`:2338`).

So on the **payload** bits the analyser is failing a transition the design
cannot produce. Suspicion of that sentence is healthy, which is why it is a
cycle-by-cycle trace with line numbers rather than an assertion — check it.

### 8a. The control path is different, and must NOT be exempted

`vg_doneB_85 → vg_doneB_s_q` sits at **0.077 ns** in the same report (Part 1
§1). That is a genuine single-cycle crossing: the toggle really can change on
the coincident edge, and only hold closure keeps the resample correct. **No
argument in §8 applies to it.** It stays fully timed.

This is the most important qualification on the proposal below. Exempting the
payload does not fix everything — but `ap_core.sta.rpt`'s **Hold Transfers**
table shows `gpll[2] → gpll[0]` carrying **4,266 register-to-register paths**,
and the exemption removes essentially all of them from the placement lottery,
leaving about seven control bits (`vg_doneA/B_85`, `mg_done_85[3:0]`,
`core_rom_ack_85` → their `_s_q` flops). **Seven paths can be closed
deliberately. Four thousand cannot.**

## 9. Scope of the exposure

Every `clk_sdram`→`clk_sys_7159` payload bus uses the identical idiom — data and
toggle launched together, toggle resampled by one flop, data captured on
edge-detect:

| Bus | Launch (`clk_sdram`) | Width | Capture (`clk_sys_7159`) |
|---|---|---|---|
| `vg_dataA`, `vg_dataB` | `:1552,1555` | 32 × 2 | `pfring0..3` — `:2321,2329` (each bit fans to **all four** slots) |
| `mg_data` | `:1685` | **128** (4 × 32) | MO engine `gfx_data` — `:2424` |
| `core_rom_data` | `:1645` | 32 | `escape_core.rom_data` → `v_di_r` — `:2749` |

The 4-way `pfring` fanout explains the failing build's arithmetic: worst slack
−0.054 with **TNS −0.201** bounds it at **≥ 4 failing endpoints**, and one
`vg_data` bit feeding four ring slots gives exactly four that violate together.
In every *passing* build TNS is 0.000 at all four corners.

Part 1 §1 already recorded that the hold-critical set is {playfield CDC, speech,
FM audio}. `mg_data` is four times wider than the playfield pair and crosses
identically; it has simply not lost a lottery yet.

## 10. Proposal — scoped hold multicycle. NOT SHIPPED, AND RE-SCOPED BY §11.

> **Read §11 first.** Measurement after this section was written showed BUILD
> 110's *binding* hold path is jt51 FM audio on a same-domain `gpll[0]` path,
> not the CDC family this proposal targets. The proposal below is still correct
> about the CDC family and still removes ~4,200 paths from the placement
> lottery — but it would not have widened BUILD 110's margin. Treat it as one
> candidate among several, not the answer.


```tcl
# PROPOSAL ONLY - not in core_constraints.sdc. See docs/TIMING.md §10.
set_multicycle_path -hold 1 \
  -from [get_registers {*vg_dataA[*] *vg_dataB[*] *mg_data[*] *core_rom_data[*]}] \
  -to   [get_registers {*pfring0[*] *pfring1[*] *pfring2[*] *pfring3[*] ...}]
```

**What it constrains.** The hold check only, on payload bits only. Setup stays
at its default single-cycle check (139.7 ns, currently passing by ~10 ns), so a
route genuinely gone wrong still fails the gate. Use the **minimum `-hold` value
that clears**, not the maximum §8 could defend.

**Why it does not undermine SDSCHED-73.** The grouping exists so CPU↔SDRAM
handshakes are timed single-cycle paths. This touches neither the handshake
signals nor the SDRAM grant path — only payload bits whose stability the
handshake itself guarantees. Per §8a the control paths stay fully timed, which
is the part that actually needs checking.

**What could go wrong, plainly:**

1. **If the handshake is ever restructured** — `vg_data` made free-running,
   `inflB` cleared earlier — the exception silently becomes a lie, and the
   failure mode is corrupted playfield pixels at some temperatures only. Any
   such change must revisit this file. That is the real cost of an exception,
   and Part 1 §6 is right that getting it wrong in this region produces freezes.
2. **`get_registers` wildcards over-match.** Verify with `report_exceptions` and
   compare the affected-path count against the ~4,200 expected.
3. **It does not fix §8a.** Seven control paths still need real margin and one
   is already at 0.077 ns.

### 10a. Rejected alternatives

- **`set_false_path`** — blunter and worse; it drops the setup check too, and
  setup is what would catch a route genuinely gone wrong.
- **An extra pipeline stage on the crossing** — does **not** help. A new flop in
  the pixel domain is still captured on `clk_sys_7159` from a `clk_sdram`-
  launched signal, so the identical coincident-edge check just moves to the new
  flop. Worth stating because it is the intuitive first suggestion.

### 10b. The one real structural fix, and why not yet

Margin is zero because the edges coincide — `gpll[2]` is exactly 5 × `gpll[0]`
and the PLL outputs are phase-aligned, so every fifth SDRAM edge lands on a
pixel edge with a **0.002 ns hold relationship** (measured, Part 1 §1). Give the
crossing a phase offset and the margin becomes real in silicon rather than only
in the report: a quarter period of `clk_sdram` is **~7 ns** against the ~0.6 ns
needed. The PLL already emits `clk_sys_7159_90deg` (`gpll[1]`) and
`clk_sdram_chip` (`gpll[3]`), so the phases exist, and **unlike §10 this also
fixes §8a's control paths.**

But it re-times the SDRAM read-return path, which carries SDSCHED-78 (stale
serve), -80 (write-strobe discipline), -83 (registered capture), BUS-99 (yield)
and TASLOCK-102 — five documented freeze fixes. Before an alpha that trades a
reporting problem for a functional-regression risk in the most regression-dense
region of the design. **Better answer; not this week.**

### 10bb. The margin floor is now demonstrably too low

`check_slack.py`'s hold floor is **0.050 ns**, chosen when BUILD 108 came in at
+0.005. The six builds on record show the perturbation sensitivity is
**~0.157 ns** — so a floor of 0.050 cannot warn about a build that is one
trivial edit away from failing.

BUILD 110 is precisely that build: it passes at **+0.103** and prints **no
warning**, yet a version-constant change of the same size that produced it would
take it negative. Verified just now against the real reports: the failing
`cpu-68010` report still exits 1 with NEGATIVE SLACK, and the `hold-diag`
report (+0.005) correctly emits MARGIN WARNING — but BUILD 110 sails through
silently.

**Suggestion (not applied here): raise the hold floor to ~0.150 ns**, i.e. at
least the measured perturbation sensitivity. It gates nothing either way — the
floors are informational by design — but it would have made BUILD 110 announce
that it passed by luck, which is exactly the thing we had to work out by hand.
Left unapplied because changing a threshold in the same commit that restores the
mechanism muddies both; it wants its own decision.

## 11. CORRECTION: BUILD 110's worst hold path is jt51 FM, not the playfield CDC

*Added after the restored reporter ran on BUILD 110's own RTL (run 32793948178).
It contradicts an inference in §9 and §10, so it is recorded as a correction
rather than folded silently into them.*

The restored diagnostic did the job it exists for, immediately: **it proved a
guess wrong.** §9 inferred that the failing endpoints were the
`vg_data -> pfring` family. For BUILD 110 that is **not** what binds.

Run 32793948178 is BUILD 110's exact RTL plus the diagnostics (workflow and
script files are not Quartus inputs). It reproduced **hold +0.103 exactly**,
confirming a third time that the fitter is deterministic — and it named the
paths:

**Fast 1100mV 0C — the binding corner. 20 worst paths span 0.103 to 0.124, a
0.021 ns band:**

| slack | from | to | launch | latch |
|---|---|---|---|---|
| **0.103** | `jt51_csr_op\|u_reg1op\|bits[6][0]` | `m_block6a0~porta_datain_reg7` | **gpll[0]** | **gpll[0]** |
| 0.109 | `jt51_pg\|ph_X[5]` | `m_block6a0~porta_datain_reg5` | gpll[0] | gpll[0] |
| 0.110 | `jt51_csr_op\|u_reg1op\|bits[4][0]` | `m_block6a0~porta_datain_reg5` | gpll[0] | gpll[0] |
| 0.110 | `vg_dataB[25]` | `pfring1[25]` | gpll[2] | gpll[0] |
| 0.113 | `pmp_wr_data_latch[22]` | `block1a12~portb_datain_reg10` | clk_74a | clk_74a |

Composition of those 20: **10 playfield CDC, 9 jt51 FM, 1 APF bridge.** At
Fast 85C the order flips back — 10 paths from 0.124 to 0.141, worst
`vg_dataB[25] -> pfring1[25]`, 8 of 10 playfield CDC.

Three consequences, and they are not comfortable for §10.

1. **The worst path is same-domain.** `gpll[0] -> gpll[0]`, jt51 register into a
   block-RAM data input. It is a genuine single-cycle path in one clock domain.
   **No multicycle is justifiable there** — §8's stability argument does not
   apply and neither does anything like it.

2. **A `pfring`-only exemption would not have widened BUILD 110's margin at
   all.** It removes 10 of the top 20 and leaves the binding path untouched at
   0.103. §10 is not wrong about the CDC family, but it was aimed at the wrong
   target for this build.

3. **This is a cluster at the floor, not a thin path.** Twenty paths inside
   0.021 ns, across three unrelated subsystems. Fix one family and the next is
   already waiting 0.007 ns behind it — which is exactly what the build history
   shows: BUILD 107's worst was TMS5220 speech, 108's was the playfield CDC,
   110's is jt51 FM. Part 1 §1 named the hold-critical set as {playfield CDC,
   speech, FM audio} and was right; §9 above narrowed it too far.

**What this means for the fix.** The common factor is not a structure, it is a
*clock*: every path in the cluster latches on **gpll[0]**, the 7.159 MHz
pixel/CPU clock, and the measured skew on it (~0.53 ns against ~0.60 ns of data
delay, Part 1 §1) consumes essentially the whole budget. That points at global
levers rather than per-path exceptions:

- clock-network routing/regioning for gpll[0], or `set_max_skew` on it;
- the §10b phase-offset idea, which helps the CDC family but does nothing for
  the same-domain jt51 and bridge paths;
- and, most cheaply, accepting that this design has a floor around +0.10 ns and
  **gating on the margin** (§10bb) so a build that lands on it says so.

§10 should therefore be re-scoped or held: it is a real improvement to the CDC
family and a real reduction in the number of tickets in the lottery (~4,200
paths), but **it is not the thing standing between BUILD 110 and comfortable
margin.** Nothing has been applied, so nothing needs undoing.

A throwaway branch `hold-repro110` (BUILD 110 RTL, `BUILD_ID` back to 3109,
reporter present) was pushed to reproduce the *failing* build and name its
failing pairs — the one gap remaining, since the original failure predates the
restored reporter. **Never merge it.**


## 12. Suggested sequencing

1. **Done in this commit:** the per-path reporter, its CI step and the margin
   warning are restored. Their very first run corrected a wrong inference
   (§11), which is the whole argument for having them.
2. **Settle the failing build.** `hold-repro110` names what actually failed at
   -0.054. Until that lands, "which family failed the gate" is still inference.
3. **Ship alpha on BUILD 110** — but on the understanding that +0.103 is this
   design's floor, not a comfortable margin, and that it got there via a
   version constant.
4. **Raise the margin floor** (§10bb) so the next build that lands on the floor
   announces it. Cheapest useful change on this list; gates nothing.
5. **Then decide the real fix on evidence**, not on §10 as written. The cluster
   is ~20 paths inside 0.021 ns across three subsystems, all latching on
   gpll[0] — so the candidates worth costing are the *global* ones (clock
   regioning / `set_max_skew` on gpll[0]) alongside §10 for the CDC family.
   §10 alone removes ~4,200 tickets from the lottery but does not move BUILD
   110's binding path.

## What is measured, what is inferred

**Measured:** the four builds' per-corner hold/setup and M10K (CI run IDs
above); the comment-only build reproducing BUILD 109 across all twenty values
with byte-identical report size; BUILD 110's RTL + diagnostics reproducing
+0.103 exactly (run 32793948178), a third independent determinism control; the
0.002 ns hold relationship and the endpoints `vg_dataB[27] -> pfring0..3[27]`
with skew and data delay (Part 1 §1); `vg_doneB_85 -> vg_doneB_s_q` at 0.077;
**4,266** RR paths on `gpll[2] -> gpll[0]`; TNS 0.000 in every passing build and
-0.201/-0.118 in the failing one; **BUILD 110's full worst-20 at Fast 0C —
range 0.103 to 0.124, composition 10 playfield CDC / 9 jt51 FM / 1 APF bridge,
worst path jt51 `gpll[0] -> gpll[0]`** (§11); the RTL structure, widths and line
numbers in §8 and §9.

**Corrected:** §9 inferred the failing endpoints were the `vg_data -> pfring`
family. §11 measured otherwise for BUILD 110. The inference was flagged as such
and the reporter caught it on its first run.

**Still inferred:** which registers actually failed in the `cpu-68010` build at
-0.054. That build predates the restored reporter, so its per-path detail does
not exist. `hold-repro110` (throwaway, never merge) is in flight to produce it.
Given §11, the earlier assumption that it was the CDC family should be treated
as unproven — jt51 FM is at least as likely.
