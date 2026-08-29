# Night analysis: the 87-91 world-engine death — root cause and the build-92 fix

*(overnight deep-analysis session, 2026-08-23; worktree `zerowait`, starting
point ZEROWAIT-91 `ccd4d5a`)*

## TL;DR

Builds 87-91 all died from **one mechanism, not two**: any design that holds
a pending vblank across the extra CPU's **IRQ-masked, multi-frame POST**
delivers that stale interrupt at POST's **first unmask instant**. The extra's
runtime vblank ISR (ROM 0x908-0x93C) writes through RAM state that only
runtime init makes valid, so the premature delivery derails POST/handshake
itself; the main times out, stops and re-releases the extra, POST re-runs,
and the same stale delivery kills it again — the endless restart loop the
build-91 HUD/video shows (extra PC sampled in the 0xBxx march band every
frame, erestart=0x10, mailbox cmds frozen at 2). The zero-wait fastpath is
**innocent**. Build 86 never hit this because the main's ISR ack cleared the
shared latch ~60-73 CPU clocks after vblank — a pulse far too short to
survive into POST's unmask — but that same short pulse is what starved the
runtime poll loop when SDRAM waits stretched its masked windows: the
build-86 phase-locked freeze. Both failure modes close simultaneously with
the **armed held-until-taken latch** (EIRQ_MODE 2, build 92): the pending
vblank is held until the extra's IACK *and* delivery only arms once the
extra demonstrably runs its runtime poll loop (two completed reads of the
wake-flag word $16CCD6 within ~1K clocks with no intervening write).

All of this is proven end-to-end in a new bench (`tb_escape_worldwake`) that
finally models the real contract — and whose absence is the reason three
plausible fixes reached hardware and died there.

## Why the bench never caught 87-91: two independent holes

1. **The vecrace ISR acked 360000.** The real extra ROM's runtime handler
   (0x908-0x93C, flight-recorder truth) has **no 36xxxx store** — it relies
   on the main's ack clearing the shared latch. The synthetic ISR's self-ack
   made every per-CPU-latch design look stormproof.
2. **The bench delivered zero interrupts from SDSCHED-88 onward.** The 87b
   fix gated the `e_virq` latch on `extra_release`, but the vecrace image's
   main CPU parks in `bra.s *` and never writes 360011, and `dbg_force_extra`
   only unresets the CPU — it does not feed the latch. Verified tonight on
   ZEROWAIT-91 tip: a 300-IRQ sweep completes with **`iack_cyc 0`**. Every
   "IRQ matrix green" from 88 through 91 was vacuous on IRQ semantics.

Both holes are now closed: the vecrace main releases the extra and its loop
carries the poll-loop arming read, and `tb_escape_worldwake` exists.

## The TG68K IPL contract (read from the vendored source)

`TG68K.vhd` wrapper + `TG68KdotC_Kernel.vhd`, as instantiated here
(`IPL_autovector => '1'`, hardwired in the wrapper):

- The wrapper samples `IPL` into `cpuIPL` on **falling** clock edges during
  bus-FSM states "00" and "10" — effectively every couple of CPU clocks.
- The kernel evaluates `setinterrupt` **only at instruction boundaries**
  (`setendOPC`), comparing `IPL_nr = NOT cpuIPL` against the SR mask
  (`FlagsSR(2:0) < IPL_nr`, or level 7).
- On the clock-enable edge that registers `interrupt`, the kernel **latches
  the vector right there**: `rIPL_nr <= IPL_nr; IPL_vec <= "00011" & IPL_nr`
  (autovector 0x18+level). With `IPL_autovector='1'` the later IACK bus
  cycle's read data is ignored (`micro_state=trap0` capture is skipped).
- The IACK bus cycle (FC=111, terminated via VPA + the E-clock sync9 path)
  happens **after** the vector is already fixed. The SR mask is raised to
  the taken level during entry; RTE restores the stacked SR.

Consequences:

- **IPL only needs to be stable across one boundary sample.** Holding the
  level through the IACK cycle is unnecessary; dropping it at IACK start
  cannot corrupt the vector. Build 90's failure theory ("autovector computed
  from IPL during IACK") and therefore build 91's refinement addressed a
  mechanism TG68K does not have — which is why 90 and 91 behaved
  identically on device.
- **A short pulse can be missed entirely** if no unmasked instruction
  boundary lands inside it — the lost-wakeup class. A held level is taken
  at the first open boundary.

## The failure mechanism, per build

| build | extra-vblank design | device result | mechanism |
|---|---|---|---|
| 86 | shared latch, cleared by main's ack (~60-73 clk pulse) | world runs; rare permanent freeze | pulse shorter than the poll loop's SDRAM-stretched masked windows; deterministic lockstep can phase-lock the miss forever (flight-recorder diagnosis, build 87 era) |
| 87 | per-CPU latch, cleared only by own 360000 ack | world dead from boot | runtime ISR never acks → storm; **plus** stale POST delivery (below) |
| 88 | 87 + latch gated by extra_release | world dead | gating only kills pendings from *before* release; POST runs for whole frames *after* release, masked — stale delivery at first unmask derails POST |
| 89/90 | + clear at IACK start (+ zero-wait merge in 90) | world dead, extra in march band, restarts climbing | one-shot delivery fixed the storm, but the *first* delivery still lands at POST's unmask → derail → restart loop |
| 91 | clear at IACK completion | identical to 90 | same — the IACK refinement was irrelevant (see TG68K contract) |

Device evidence for the restart-loop reading of 90/91 (tonight's video,
`Genki Arcade - 2026-08-23 012626.mp4`, frames extracted): HUD page 1 shows
the extra's per-frame PC samples at 0x0BAC/0x0BBE/0x0BBA/0x0B5A — the march
band, not the 0x9B4 poll loop and not the 0x908 ISR; field 3 = 105A =
{erestart 0x10, last mbox cmd 5A}; field 2 = 0204 = {cmds 2, acks 4}. The
extra spends its life re-running POST, and the world engine never starts.
The attract demo runs (main alive, graphics perfect) with no world actors —
exactly what was photographed.

## Why the POST-unmask delivery is fatal

The extra boots with SR mask 7 and runs marches/checksums for whole frames.
Its vblank ISR is reached through ROM-fixed vectors (0x70 → stub 0x308 →
trampoline 0x80C → handler 0x908), but the handler's work — the 0x50 write
that lands at $16CCD6 in runtime — goes through register/RAM state that
POST has not initialized. Fired mid-POST, that write lands somewhere in
POST's working set: trampled march data, a failed verify, a garbled
handshake. (This is not hypothetical: the 87-era boot hang was diagnosed on
device as "a stale pending vblank fired the instant POST unmasked,
derailing the Second Processor handshake".) On the real board this cannot
happen: the interrupt line falls ~7.5 µs after vblank (the main's ack), so
an unmask instant elsewhere in the frame sees a quiet line. The 68000's
level-sensitive IPL is the board's own guarantee against stale delivery —
and any latch that extends the pulse across frames breaks that guarantee.

Both constraints together define the correct design:

- pulse must be **longer than any masked stretch of the runtime poll loop**
  (else: lost wakeup — build 86's freeze), and
- pending must be **invisible to a CPU that is not yet in its runtime loop**
  (else: POST derail — builds 87-91).

A fixed pulse length cannot satisfy both against a deterministic, lockstep
machine (any length long enough to be safe for the loop has a nonzero,
*repeatable* probability of covering a POST unmask). Knowing when the extra
is actually in its runtime loop satisfies both exactly.

## The fix: EIRQ_MODE 2 — armed held-until-taken (build 92)

`escape_core` gains an `EIRQ_MODE` generic (all three semantics selectable
for A/B on device; Quartus-'93-safe, no new M10K, pixel pipelines untouched):

- **0 — BUILD-86 shared pulse** (baseline/fallback): set at vblank, cleared
  by the main's 360000 ack (and either CPU's own write).
- **1 — BUILD-91 held-until-IACK** (kept for A/B): pends until the extra's
  IACK completes.
- **2 — the fix**: held-until-IACK **plus arming**. Delivery to the extra
  only arms after two completed extra-side reads of the wake-flag word
  ($16CCD6) within ~1K clocks with no intervening extra-side write to it —
  the runtime poll loop's unique access signature (POST marches pair every
  read with a write; checksum sweeps revisit an address frames apart; the
  arming counter also ages out at 1023 clocks). Disarmed whenever the main
  stops the extra (extra_release drop), so every re-release re-qualifies.
  Once armed: exactly-once delivery per vblank, held until taken — the
  lost-wakeup and the storm are both structurally impossible, and no
  interrupt can reach POST.

Caveat, flagged deliberately: $16CCD6 is *game code* knowledge (like the
existing mailbox-forensics decodes), not board hardware. The Klax/Guts
proto variants will need their own flag addresses (or mode 0) — noted in
the generic's comment.

## Bench proof (`tb_escape_worldwake` + `make_worldwake_hex.py`)

The image finally models the real contract: main releases the extra via
360011, supervises the handshake with timeout+restart (restart counter =
the device's erestart analog), and acks 360000 from its own vblank ISR
(measured ~73 clks after vblank in-bench, vs ~54 clk / 7.5 µs authentic).
The extra boots masked, marches over the flag page (write/read pairs — the
false-arm probe for mode 2), leaves its ISR pointer aimed at POST workspace
(canary), unmasks once mid-POST (the hazard point), verifies the canary,
posts the handshake, initializes runtime, and parks in the real
critical-section poll loop at the real addresses (0x9B4+, save SR / mask 5
/ tst $16CCD6 / restore SR from $16CCD0), with the real no-ack ISR at
0x908. A trampled canary parks it at 0xBAC — the march band, reproducing
the device HUD signature. Metrics: wakes/frame (world-alive), IACKs/frame
(storm), premature IACKs (POST derail), restarts, ack delay.

Results matrix (GHDL, 10 ns clock; RESULTS FILLED FROM TONIGHT'S RUNS):

| run | EIRQ mode | FPEN/FP | SHAD | frames (period) | verdict | wakes/frames-after-ready | IACKs | premature | restarts | notes |
|---|---|---|---|---|---|---|---|---|---|---|
| smoke | 2 (fix) | 1/1 | 0 | 60 swept | **ALIVE** | 54/54 | 54 | 0 | 0 | exactly one IACK per frame |
| m0 | 0 (86) | 1/1 | 0 | 150 swept | **ALIVE** | 144/144 | 144 | 0 | 0 | fast loop: pulse (~75clk) > masked window |
| m1 | 1 (91) | 1/1 | 0 | 150 swept | **DEAD** | 0 (never ready) | 4 | **4** | 3 | every attempt derails at POST unmask; parks at 0x0BAE = the device's march-band HUD signature |
| E | 1 (91) | 0/- | 0 | 120 swept | **DEAD** | 0 (never ready) | 3 | **3** | 1 | identical death WITHOUT the fastpath: zero-wait exonerated |
| A | 2 (fix) | 1/1 | 0 | 400 swept | **ALIVE** | 394/394 | 394 | 0 | 0 | full phase sweep, slice 1 |
| F | 2 (fix) | 1/1 | 0 | 210 swept, PHOFF 205 | **ALIVE** | 205/205 | 205 | 0 | 0 | phase slice 2 |
| G | 2 (fix) | 1/1 | 0 | 210 swept, PHOFF 410 | **ALIVE** | 205/205 | 205 | 0 | 0 | phase slice 3 (A+F+G > 613 modulus: full phase coverage) |
| B | 2 (fix) | 0/- | 0 | 200 swept | **ALIVE** | 185/185 | 185 | 0 | 0 | legacy arbiter path (ack delay 138clk) |
| C | 2 (fix) | 1/3 | 0 | 150 swept | **ALIVE** | 142/142 | 142 | 0 | 0 | slow (3-clk) fastpath fills |
| D | 2 (fix) | 1/1 | 1 | 150 swept | **ALIVE** | 143/143 | 143 | 0 | 0 | device config: shadows + fastpath |
| H | 0 (86) | 1/1 | 0 | 100 LOCKED 2560, SLOW loop | **LOST WAKEUP** | stalled at frame 10 | — | 0 | 0 | **the build-86 freeze reproduced**: extra parked at 0x09D6 inside the poll loop, e_virq=0 — SDRAM-starved masked window (~255clk) outlives the ack pulse; locked period = phase-lock forever |
| I | 2 (fix) | 1/1 | 0 | 100 LOCKED 2560, SLOW loop | **ALIVE** | 94/94 | 94 | 0 | 0 | same regime as H: held latch waits for the open window |
| J | 2 (fix) | 1/1 | 0 | 280 swept + mid-run stop/re-release | **ALIVE** | 268/274 | 268 | 0 | 0 | release drop at frame 193: disarm -> re-POST (~6 frames) -> re-handshake -> re-arm -> wakes resume; zero premature across the restart |
| K | 2 (fix) | 0/- | 0 | 280 swept | **ALIVE** | 265/265 | 265 | 0 | 0 | legacy path (heartbeat too slow to reach the restart pulse in 280 frames; re-arm covered by J) |

Regressions: tb_escape_extracpu OK (real extra ROM bring-up), tb_escape_dualcpu
OK, tb_escape_march OK (game's own color-RAM march). Vecrace, with the image
now releasing the extra and carrying the arming read: FPEN=1/FP=1, 1200 swept
IRQs, **iack_cyc 13,768** (delivery live again), 95,393 extra-CPU ROM reads
verified, ALL exactly 4 clocks (MAXAS=2 armed, zero trips), zero corruption,
zero early-terms; FPEN=0, 600 IRQs, iack_cyc 6,621, 23,558 reads, clean.

## Zero-wait fastpath verdict

**Innocent, on four independent lines of evidence.**

1. Mode 1 dies *identically* with the fastpath disabled (run E, FPEN=0:
   DEAD, premature deliveries, restart loop, parked at 0x0BB2) — the failure
   follows the IRQ mode, not the memory path.
2. Mode 2 is alive under every fastpath configuration: authentic one-clock
   fills (A/F/G), slow 3-clock fills (C), watchdog-fallback-only (implied by
   FPEN=1 runs' never-wedge path), legacy arbiter (B/K), and the device
   config with shadows + fastpath (D).
3. Vecrace under FPEN=1/FP=1: 95,393 extra-CPU ROM reads across 1,200 swept
   IRQs with live delivery (13,768 IACK cycles) — every read the image's
   true word, every cycle exactly 4 clocks (MAXAS=2 armed, zero trips).
4. The device itself: builds 90/91 completed release + POST + checksums
   (HUD p2 checksums E789/2D55, coins, attract) under zero-wait — boot and
   handshake worked; only the world wake was dead.

Note on `tb_escape_handshake` (real ROMs, natural boot): at its 5 ms budget
the run ends before the main's multi-second boot flow reaches the 360011
release write (the extra's POST alone is ~1 s on device), with or without
tonight's changes — it is a bench-budget artifact, not a fastpath failure;
kept (now with a real fastpath server) for long-stoptime nightly use.

## Build 92 content (this branch, ready to flash)

- `escape_core.vhd`: `EIRQ_MODE` generic, modes 0/1/2 as above; arming
  detector (~12 registers, no M10K); mode-2 default. Latch block only —
  MO/PF pixel pipelines untouched.
- `core_top.v`: passes `.EIRQ_MODE(2)`, BUILD_ID → 3092.
- Benches: `tb_escape_worldwake` (+ image builder + runner);
  `tb_escape_handshake` upgraded with real fastpath server wiring;
  vecrace image fixed (main releases extra; loop carries the arming read)
  so its sweeps deliver interrupts again.
- Flash-day expectations: world engine alive from boot (demo actors, game
  start); erestart stays at MAME-like boot counts (~2), not 0x10; the
  build-86 freeze class cannot return (held latch); if anything is still
  dead, A/B with EIRQ_MODE 0 vs 2 is a one-line change and both are
  bench-characterized.

## Timing-risk notes

- The arming detector adds one 10-bit ager + small state off `e_addr`
  compare — same cone depth as the existing LANE4j exact decodes; no new
  cross-domain paths; slack risk negligible (but verify Quartus slack as
  always; never ship negative).
- Mode selection is generic-constant: dead modes synthesize away.
