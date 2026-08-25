# CPU type, and the shared-RAM mux arbiter

Two architectural questions that were decided early and never revisited:

1. Is the board a 68000 or a 68010, and does it matter?
2. Why did we not just build the board's mux arbiter, and what did we give up?

Everything below is either a schematic citation, a measurement with the command
that produced it, or an explicitly-labelled model. Where a claim is inferred, it
says so. Where it needs the physical board, it says that too.

> **2026-08-24 — Question 1 is answered: the board is a 68010.** The owner
> photographed the part on his dedicated-cabinet board: **`MC68010P8`**,
> Motorola, date code **`A71R8813`**. The schematic agreed all along. §1.1 was
> right, §1.2's contested "production boards carry 68000s" claim is **false as
> stated**, and §1.5 (what to check on the board) is **done**.
>
> **And there were two boards.** Confirmed from photographs by the owner:
> **the dedicated cabinet is a 68010, the JAMMA version is a 68000.** Both are
> authentic; they are different machines. That resolves the whole argument —
> the schematic, the owner's board and MAME were each describing something
> real, they were just not all describing the *same* board. See §1.6.
>
> §1.3 and §1.4 — the measurements showing the difference is unobservable on
> this ROM — are unaffected and still stand, and they are what makes supporting
> both variants free.

---

## Part 1 — CPU type

### 1.1 What the schematic actually says (read directly)

**The schematic says 68010. Both CPUs. Unambiguously.**

| Package page | SP-332 sheet | Block label | Designator | Part number **as drawn** |
|---|---|---|---|---|
| page 5 | Sheet 4 | `VCPU` | **45J** | **`U68010`** |
| page 6 | Sheet 5 | `ECPU` | **20P** | **`U68010`** |

Read off `reference/schematics/_png/page5.png` and `page6.png`, re-rendered from
the source PDF at 1200 dpi and cropped to the part-number field (the label is
vertical text on the chip's left edge). At that resolution the glyphs are not
ambiguous: `U68010`, not `U68000`.

The `U` is Atari's part-number field prefix, used consistently on the same
sheets — the common ROM pair at 40K/50K is drawn `U27512`. So `U68010` denotes
part number 68010, i.e. an MC68010.

Nothing else on those sheets discriminates. The 68000 and 68010 are pin-identical
64-pin DIPs, and the drawn pinout (VCC 49, A23 52 … `BG`/`BGACK`/`BR`/`E`/`VMA`/
`BERR`/`VPA`, `FC2-0`) is common to both parts.

**The owner is right about the schematic. The README was wrong to imply otherwise.**

**And the board agrees with the schematic.** Photographed 2026-08-24, the part in
the socket is marked:

| Field | As photographed |
|---|---|
| Part number | **`MC68010P8`** |
| Manufacturer | Motorola |
| Date code | **`A71R8813`** |
| Cabinet | **dedicated** (the JAMMA variant is a 68000 — §1.6) |

An `MC68010P8` is a 68010 in a 64-pin plastic DIP, 8 MHz rated — comfortable for
the board's 7.159 MHz. This is the record that §1.5 asked for and it closes the
question for the dedicated-cabinet board.

A third, independent corroboration was sitting in the reference material the
whole time: Atari's own JSA documentation, reproduced in MAME's
`reference/atarijsa.cpp:50,58`, labels the host interface the "Read/Write
**68010** Port".

### 1.2 Provenance of "production boards carry 68000s" — traced, and refuted

**This claim is false.** The photograph above settles it. This section is kept
because *how* a false claim got into six documents and two RTL comments is worth
recording. It traces to exactly one place:

```
commit 24d900e  "docs: CPUs are 68000s on real boards, not 68010s"
Author: djslloyd <djslloyd@gmail.com>   Date: Mon Aug 10 2026
Co-Authored-By: Claude Fable 5

  The schematic labels both CPUs U68010, but Lloyd's actual ESC board
  carries MC68000s, matching MAME's eprom driver. Production shipped
  68000s regardless of the schematic label. Comment-only change to RTL.
```

That commit is the origin of every downstream restatement (`README.md`,
`docs/ARCHITECTURE.md:87`, `docs/HISTORY.md:12`, the two `escape_core.vhd`
comments, and the `DEVIATIONS.md` C5 row written on top of them). All have now
been corrected.

**Assessment: weakly sourced, and wrong.** It was attributed to the owner's own
board, which is a real source — but:

- no photograph, part marking, date code, or designator was recorded;
- the commit message was drafted by an LLM in the owner's session, so the chain
  from "what the owner saw" to "what got written down" is not independently
  checkable from the repo;
- `docs/ARCHITECTURE.md:87` then upgraded it to "**verified** from an actual ESC
  board", which is stronger than what the commit says.

Two further restatements went beyond the evidence: "Production shipped 68000s
regardless of the schematic label" is a claim about *all* production, from a
sample of one board, and `DEVIATIONS.md` C5's framing ("the one recorded case
where MAME wins") presents a contested point as settled.

Worse, `docs/HISTORY.md:12` recorded it as "**photo-verified**" — a photograph
that did not exist. That single word is what made the claim look unassailable
for two weeks.

**Verdict: the schematic label was established fact and always was; the 68000
population claim was a single unphotographed observation, and it was wrong.**
The lesson is not "trust the schematic over the board" — it is that an
unrecorded glance at a chip is not a measurement, and that this project's own
standard (a check that can fail, with the evidence attached) applies to
hardware inspection exactly as it applies to a simulation.

### 1.3 Does it matter for CORRECTNESS? No — measured, not assumed

The 68010 adds VBR, RTD, MOVES, MOVEC; makes `MOVE from SR` privileged; and uses
a longer exception stack frame with a format/vector-offset word. Each was checked
against the actual ROM rather than argued from MAME's behaviour.

**Static scan.** Both CPUs' program images were rebuilt with the repo's own
`sim/tools/build_maincpu_rom.py` / `build_extracpu_rom.py`, then **verified
byte-identical to MAME's live program space** (`space:read_u16` dump, `cmp`
clean) — so the scan provably covers what the CPU really fetches. Disassembly
cross-checked with two independent decoders (MAME `unidasm -arch m68000` and
capstone `CS_MODE_M68K_000`).

| 68010 marker | Raw hits (main / extra) | On a reachable instruction boundary |
|---|---|---|
| `MOVEC` `$4E7A`/`$4E7B` | 0 / 0 | **0** — absent even at odd byte offsets |
| `RTD` `$4E74` | 0 / 0 | **0** — absent even at odd byte offsets |
| `MOVES` `$0E00-$0EFF` | 1349 / 153 | **0** (all data; 14 proven operand words) |
| `MOVE CCR,<ea>` (68010-only) | 12 / 11 | **0** (all data — an 8-entry, 6-byte-stride table in the `$60000` data ROM) |
| `MOVE SR,<ea>` | 105 / 7 | **7** — all supervisor-mode, see below |

`MOVEC` and `RTD` are the two unambiguous markers, and they do not occur as byte
patterns anywhere, at any alignment. There is no code/data judgement to make.

**The `MOVE SR` sites do not discriminate, and this is worth being precise
about.** All 7 are the classic save-SR / mask-interrupts / restore-SR critical
section, each followed immediately by a privileged `move #imm,SR`. On a 68010
`MOVE SR` faults only in *user* mode — and the game never enters user mode.
Measured, not assumed: the game's own `move SR,$16CCxx` sites write the live SR
into shared RAM, and every recorded value has S=1 (`$2304`, `$2314`, `$2700`);
SR sampled once per video frame over 400 s has S=1 on both CPUs, every sample.
So this test comes back "consistent with either part", and it is reported that
way rather than pressed into service as evidence.

**Exception frames: no handler inspects a format word.** Full vector tables were
read (maincpu 64 vectors at `$000-$0FF`, extra 192 at `$000-$2FF`). Every vector
except reset, L4 vblank and L6 sound points at a single catch-all:

```
maincpu $00100:  4e72 2700    stop #$2700
extra   $00300:  4e72 2700    stop #$2700
```

`STOP #$2700` touches the stack not at all — no format-word read, no `addq #n,sp`,
no `lea n(sp),sp`, no `rte`. It halts until the watchdog resets the board. The
three real handlers (`$5CC`, `$134C`, `$308`→`$8F6`) are symmetric
`movem.l …,-(A7)` / `movem.l (A7)+,…` / `rte` and never index the frame. The one
instruction that superficially looks like a format-word read — extra `$0098E
move ($6,A7),SR` — is not a handler at all; nothing vectors there. It is a
`jsr`-called helper whose `6(A7)` is a caller-pushed argument.

There is one vestigial 68000 idiom (extra `$0384`, `$097C`): a hand-built 6-byte
user-mode RTE frame. On a 68010 that would take a format error — but the `rte`
was replaced by `jsr $F93A`, so the frame is never consumed. Inert either way.

#### 1.3.1 The stack frame, re-verified independently — and the stronger claim

"No handler reads a format word" is **not** the claim that matters. Push and pop
are both in 68010 mode, so `RTE` is self-consistent by construction: TG68K's
`trap0`→`trap1` pushes the extra word and `rte1`→`rte2`→`rte3` pops it
(`TG68KdotC_Kernel.vhd:3760, 3835-3843`). What would actually break a live
machine is a handler doing **pointer arithmetic around the frame** — indexing
past it, or discarding it with a hard-coded `addq #6,A7`.

That was re-checked from scratch, by a different method than §1.3's:

**The bound that makes this tractable.** `RTE` is the only instruction that
consumes an exception frame, it is the single opcode word `$4E73`, and the
68000/68010 fetch instructions only at even addresses. So scanning both images
for `$4E73` at every even offset is not a sample — it is **exhaustive over
everything that can possibly execute an RTE**. Result:

| Image | `$4E73` at any even offset | Real, reachable handlers |
|---|---|---|
| maincpu (512 KB) | **4** — `$005E2`, `$00692`, `$01398`, `$202E0` | 3 (`$202E0` is ASCII: it is the `"Ns"` inside padding after `"15 Maximum\0"`) |
| extra (512 KB) | **4** — `$00306`, `$00318`, `$00842`, `$00942` | 3 (`$00842` sits in a zero-filled data table) |

**Every reachable handler is stack-balanced, and not one touches the frame.**

| Handler | Entry | Body | A7 depth at `RTE` |
|---|---|---|---|
| main L4 vblank | `$005CC` `movem.l D0-D1/A0-A1,-(A7)` (−16) | two exits: `$005DE` and `$0068E`, both `movem.l (A7)+,D0-D1/A0-A1` (+16) | **0** at `$005E2` and `$00692` |
| main L6 sound | `$0134C` `movem.l D0/A0-A1,-(A7)` (−12) | operands are all `d(A1)` off `$3F7F62`, never `d(A7)` | **0** at `$01398` |
| extra L6 sound | `$00306` | bare `rte` — the handler is one instruction | **0** |
| extra L4 vblank | `$00308` | `btst`/`beq $318` (bare `rte`) or `jmp $8F6` | **0** |
| extra vblank body | `$008F6` `movem.l D0-D1/A0-A1,-(A7)` (−16) | all three exits converge on `$0093E` `movem.l (A7)+,…` (+16) | **0** at `$00942` |

**Zero `d(A7)` accesses occur anywhere inside any handler body**, and no
`addq/subq/lea/adda/suba` on `A7` occurs between any handler entry and its
`RTE`. The abundant `addq.l #4,A7` / `lea $10(A7),A7` sites elsewhere in both
images (437 and 154 respectively) are ordinary caller-side argument cleanup
after `jsr`, at stack depths *below* any exception frame; the general point is
that the extra 2 bytes shift only what lies **at and above the handler's entry
A7**, and everything a handler pushes afterwards moves with it en bloc.

Two near-misses, both checked and both benign:

- **extra `$0098E move.w $6(A7),SR`** — superficially a format-word read. It is
  not a handler: nothing vectors to it, it ends in `RTS` not `RTE`, and its
  `6(A7)` is a caller-pushed argument relative to its own `jsr` return address.
- **The reboot idiom** (main `$0060A`, extra `$0095E`): `suba.l A0,A0` /
  `movea.l (A0)+,A7` / `movea.l (A0),A0` / `jmp (A0)`. This *abandons* the frame
  rather than unwinding it — it reloads A7 from the reset SSP at `$000000` and
  re-enters via the reset PC at `$000004`. Frame-size-agnostic by construction.

**The CPU never leaves supervisor mode — checked statically as well.** §1.3
establishes this dynamically (S=1 at every `MOVE SR` site and every frame sample
over 400 s). Here is the independent static half, which matters because it is
the premise the whole `SR_Read` argument rests on. Only four things can clear
the S bit: `MOVE <ea>,SR`, `ANDI #imm,SR` (`$027C`), `EORI #imm,SR` (`$0A7C`),
and `RTE`. Scanning every even offset of both images:

| Form | Raw hits (main / extra) | Verdict |
|---|---|---|
| `MOVE #imm,SR` with S=0 in the immediate | 1 / 1 (`$6B7F2`, `imm=$48A0`) | **data** — mid-record in a 6-byte-stride table (`483C 03F0 36FE / 484E 04E9 46FD / 486A 04E9 46FC / 48A0 04E9 47F7 / …`); the `46FC` is a record field, not an opcode |
| `ANDI #imm,SR` clearing S | 2 / 0 (`$21BBC`, `$21F84`) | **data** — entries in a monotonic word table (`022B 0279 022C 027A 022D 00A9 027B 022E 027C 027D …`) |
| `EORI #imm,SR` toggling S | 1 / 0 (`$1179C`) | **data** — entry in a strictly counting table (`0A74 0A75 0A76 0A77 … 0A7C 0A7D 0A7E …`) |
| `MOVE #imm,SR` with S=1 | 22 / 10 | the real ones — `$2000/$2300/$2500/$2700`, all supervisor (plus 2/2 more ASCII false hits, `$6B31`/`$6B54` = `"k1"`/`"kT"`, in the same stride table) |
| `RTE` | see above | restores only frames this CPU pushed while supervisor; the two hand-built user-mode frames are never consumed |

So no reachable instruction can drop the CPU to user mode, and `MOVE from SR`
becoming privileged cannot fire. (The register/memory forms of `MOVE <ea>,SR`
cannot be resolved statically — they restore a previously-saved SR — which is
exactly what §1.3's dynamic measurement covers, and it agrees: 0 privilege
violations in 400 s with the detector falsified four ways.)

Note the same `CPU(0)` switch also *enables* `MOVE from CCR`, a 68010-only
opcode. §1.3 already measured that: 12/11 raw hits, **0** on a reachable
instruction boundary, all in that same `$60000` stride table.

**VBR is provably zero for the life of the machine.** TG68K resets it to zero
(`TG68KdotC_Kernel.vhd:4056`) and only `MOVEC` can write it (`:4064`) — and the
even-offset opcode scan finds **no `$4E7A`/`$4E7B` anywhere in either 512 KB
image**. So vector fetching in 68010 mode is bit-identical to 68000. (This
reproduces §1.3's `MOVEC` result by an independent method.)

**Only two kernel features actually change.** Read off the generic defaults at
`TG68KdotC_Kernel.vhd:138-145`: `SR_Read` and `VBR_Stackframe` key on `CPU(0)`,
while `extAddr_Mode`, `MUL_Mode`, `DIV_Mode` and `BitField` key on `CPU(1)` —
which is `0` for both `"00"` and `"01"`. So `"00"→"01"` flips exactly those two,
and both are inert here: the frame change per above, and the privilege change
because `:2082` permits `MOVE from SR` whenever `SVmode='1'`, which §1.3 measured
to be true at all 7 sites on every sample.

**Dynamic confirmation, with the detector proven able to fire.** A vector-fetch
tap (with PC attribution, so genuine exception fetches are distinguished from the
ROM self-test's checksum sweep of the same bytes) over 400 s / ~24,000 frames of
boot + attract + coined-up level-1 play:

| CPU | Illegal-instruction (vec 4) | Privilege violation (vec 8) |
|---|---|---|
| maincpu | **0** | **0** |
| extra | **0** | **0** |

This project does not accept a check that cannot fail, so the detector was
falsified four separate ways — patching a known-fatal opcode into the extra CPU's
per-frame body at `$0924`, *after* the ROM self-test passes:

| Injected | Vector taken | Result |
|---|---|---|
| `4E7A 0801` MOVEC VBR,D0 | **vec 4** | extra CPU dead |
| `0E90 0000` MOVES.L D0,(A0) | **vec 4** | extra CPU dead |
| `4E74 0000` RTD #0 | **vec 4** | extra CPU dead |
| `46FC 0000` move #0,SR (→ user mode) | **vec 8** | extra CPU dead |

"Dead" is independently visible: the extra CPU's logic-frame counter `$16C992`
freezes and its PC sticks inside the `STOP` catch-all. The detector fires; the
clean run is a real negative.

> **Correctness verdict.** The code requires no 68010 behaviour, and it
> tolerates all of it. Nothing in the ROM distinguishes the two parts, in
> either direction — TG68K is correct here as `CPU=>"00"` **and** as
> `CPU=>"01"`. Since the board is a 68010, `"01"` is the authentic setting;
> since the ROM cannot tell, the choice is free.

### 1.4 The one that could have mattered: LOOP MODE — measured, and it is zero

A 68010 executes a `DBcc` loop whose body is a single loopable instruction from a
two-word internal cache, avoiding the per-iteration instruction refetch a 68000
must do. It is a pure performance difference, invisible to every correctness
test — so if this game's hot loops were loop-mode-eligible, **MAME's 68000 model
would itself be slower than the board**, the 0.9977 cadence target would be too
low, and no amount of memory-subsystem tuning could ever close the gap.

That was the hypothesis worth taking seriously. It is refuted.

**Static eligibility.** A DBcc loop is loop-mode-eligible only if the branch
displacement is exactly `-4` (body = one word) and that one word is a loopable
instruction. Scanning both CPUs' real program spaces:

| | DBcc pattern matches | with `disp = -4` | eligible body instruction |
|---|---|---|---|
| maincpu (`$00000-$9FFFF`) | 79 | 17 | 16 |
| extra (`$00000-$7FFFF`) | 11 | **0** | **0** |

The 16 eligible maincpu bodies are the canonical block-move/fill instructions —
`MOVE.W (A0)+,(A1)+`, `MOVE.B (A0)+,(A1)+`, `CLR.L (A0)+`, `MOVE.W D0,(A1)+`,
`CMPA.L -(A1),A0`, `TST.B -(A1)` and similar. (The 17th, `ASL.L #1,D1` at
`$3D24`, is a register-only shift and is *not* loopable — loop mode requires a
memory operand via `(Ay)`, `(Ay)+` or `-(Ay)`.)

**The world CPU has no single-instruction DBcc loop anywhere in its 512 KB.**
Loop mode cannot help it at all, regardless of what executes.

**Dynamic occupancy — the number that settles it.** Two independent methods,
both over 60 s / 3,596 frames of scripted one-player level-1 play, both scoped to
the video CPU's per-frame logic body (bracketed by the `$50`/`$00` writes to
`$16CCD4`, per `docs/PERF_CADENCE.md`):

*Method A — per-site fetch counting.* Only **two** of the 79 DBcc sites execute
inside the body at all: `$001308` (disp `-20`, a 9-word body) and `$002978`
(disp `-254`). **Not one of the 17 `disp = -4` sites executes in the body.** The
only eligible site with any activity anywhere, `$04E596`, runs entirely *outside*
the logic frame.

*Method B — PC sampling* (1,660,869 samples inside the body):

| | share of in-body execution |
|---|---|
| inside **any** backward DBcc loop | 2,273 samples = **0.137 %** |
| inside a **single-instruction (loop-mode-eligible)** DBcc loop | 0 samples = **0.0000 %** |

The two methods agree on which loops run (`$001308` and nothing else eligible),
which is the cross-check that makes the zero trustworthy.

**Probe validity.** MAME 0.289's narrow read taps are blind to m68k opcode
fetches (direct-read cache) — a two-byte tap silently reads zero, which is
exactly the kind of check-that-cannot-fail this project has been burned by. The
existing `sim/tools/logic_cadence.lua` had already discovered and documented
this. Both methods here therefore use a **wide** tap with an address filter, and
carry explicit controls:

| Control | Expected | Measured |
|---|---|---|
| `$404E0` vblank handler entry | ≈1 per logic frame | **3,590** hits / **3,590** bodies |
| `$4052E` body `jsr`, inside the bracket | in-body only | 4,003 in-body, 0 outside |
| `$40518` body-start write | just outside the bracket | 3,590 outside, 6 in |
| `$0E0200` (EEPROM hole, never code) | 0 in-body | **0** in-body |

The probe fires, it counts correctly, and it separates in-body from out-of-body.

**What a 68010 would save: nothing.**

Because measured eligible-loop occupancy is 0.0000 %, the saving is zero and no
Motorola timing table is needed to reach that conclusion. And the result is
robust to any error in the eligibility classification, because there is a hard
ceiling that does not depend on it: **all** DBcc-loop cycles — eligible or not,
single-instruction or not — are 0.137 % of the video CPU's frame work. Even
under the absurd assumption that loop mode made every one of them *free*, the
video CPU would gain 0.137 %.

The cadence gap being chased is 0.973 vs 0.9977 ≈ **2.5 %**. The ceiling is
**18× too small** to explain it, and the measured value is zero.

> **Loop-mode verdict.** The CPU type is a **non-issue for speed** on this game.
> MAME's 68000 model is not slower than a 68010 would be here, the 0.9977 target
> is not too low on this account, and TG68K's lack of loop mode costs nothing.
> **This line of inquiry is closed.** (See Part 2.3 for the effect that pushes
> the real board the *other* way.)

#### 1.4a A hypothetical runtime 68000/68010 toggle — what it could and could not do

Kept as an investigation note. **The shipping setting stays `CPU_TYPE = 1`
(68010)**: it matches SP-332 and the owner's photographed `MC68010P8`.

*It is compile-time today, and thoroughly so.* `escape_core` binds
`TG68K generic map (CPU => CPU_SEL)`, and inside `TG68K.vhd` the kernel
instantiation binds `CPU => CPU` (`:180`), so a constant propagates all the way
into the kernel. A runtime toggle means turning that generic into a routed
signal at every level.

*It could not produce a performance difference, for a reason beyond the loop-mode
argument above.* Between `"00"` and `"01"` only **CPU(0)** differs, and nothing
timing-related keys on it:

| gated on | behaviours | timing-relevant? |
|---|---|---|
| **CPU(0)** — the only differing bit | `SR_Read` (privilege), `VBR_Stackframe` (exception frame format) | no, purely functional |
| **CPU(1)** — identical (0) for both parts | `extAddr_Mode`, `MUL_Mode`, `DIV_Mode`, `BitField` | yes, but unchanged either way |

`MUL_Mode`/`DIV_Mode` therefore stay 16-bit for both, and `BarrelShifter` is
hardcoded to 1 in `TG68K.vhd` rather than switched. So the toggle would change
**two functional behaviours and zero timing behaviours** — structurally none,
not merely a small effect. Worth stating because it is a genuine ACCURACY
LIMIT, not just a null result: if the real dedicated cabinet were faster than
the JAMMA one, this core could not express that at either setting.

*And it would not be safe to flip during play.* Both switchable behaviours are
mode 2 — read combinationally, not latched at reset. `VBR_Stackframe` changes
the exception stack frame FORMAT, so an exception taken in one mode and `RTE`'d
in the other pops the wrong frame and corrupts the stack; this game is VBLANK-
interrupt driven, so that window opens ~60 times a second. `SR_Read` changes
whether `MOVE SR,<ea>` traps. A toggle would have to latch at reset (the way
`vshad3_on` latches between bus cycles for atomicity) or auto-trigger the
existing Soft Reset Core (`interact.json` id 11).

### 1.5 What the owner checked on the physical board — DONE

This section used to say what to record. It has been recorded.

| Which CPU | Designator | Result |
|---|---|---|
| **Video CPU** (`VCPU`) | **45J** | drawn `U68010` on sheet 4 |
| **World CPU** (`ECPU`) | **20P** | drawn `U68010` on sheet 5 |
| **Photographed part** | — | **`MC68010P8`**, Motorola, date code **`A71R8813`** |

**And it changed nothing in this core**, exactly as predicted: §1.3 shows the
code needs no 68010 feature and tolerates all of them, §1.3.1 shows no handler
does frame arithmetic, and §1.4 shows loop mode is never entered. The value of
checking was closing a documentation question honestly. It also closed it in
the *opposite* direction to what the docs had claimed, which is the more useful
outcome.

### 1.6 The JAMMA board — resolved: it is a 68000

Escape shipped in two cabinet variants and **they use different CPUs.**
Confirmed by the owner from photographs:

| Variant | CPU | Corroboration |
|---|---|---|
| **Dedicated cabinet** | **68010** | `MC68010P8` photographed, date code `A71R8813`; SP-332 draws `U68010` at 45J and 20P |
| **JAMMA** | **68000** | photographed |

This is the cleanest possible resolution, and it retires the argument rather
than deciding it. Every party to the dispute was describing something real:

- **The schematic was right** — SP-332 is the *dedicated-cabinet* package, and
  the dedicated board is a 68010.
- **MAME is right too, about the other board** — `eprom.cpp` instantiates
  `M68000`, which faithfully models the **JAMMA** variant.
- **The 24d900e inspection was probably right about a board** — its error was
  generalising one board to "production", and being recorded without a photo.
  §1.2 stands as written on the process failure; the observation itself may
  simply have been of a JAMMA board.

**Consequence for this core, stated plainly: every build up to and including
BUILD 109 ran `CPU => "00"` and was therefore a faithful JAMMA machine.** It
was never wrong; it was modelling the other cabinet. BUILD 110 switches the
default to the dedicated board's 68010, and **both settings remain supported**
— see `DEVIATIONS.md` C5.

Because §1.3/§1.3.1/§1.4 show this ROM cannot distinguish the two parts,
supporting both variants costs nothing and neither one can be "wrong" for a
given player's board.

#### 1.6.1 What the repo's schematic material is (for the record)

The SP-332 survey below was done while the JAMMA question was still open. It is
kept because it documents *which* board the package describes — which turns out
to be the whole point:

- `reference/schematics/Escape_Schematic_Package.pdf` — **SP-332, 1st printing,
  © 1989 Atari Games Corporation**, 17 pages (cover + 16 sheets). It is a raster
  scan with **no text layer**, so it cannot be grep'd; everything above came from
  high-DPI renders of specific fields.
- It is **dedicated-cabinet documentation**. Sheet 1's Main Wiring Diagram shows
  discrete keyed Atari connectors (`PPWR`, `JSCM`, `JPL`, `JPJS`, `JCOM`, plus
  separate video/coin-door/fluorescent harnesses) — **no 56-pin JAMMA edge
  connector anywhere.**
- It contains **no parts list, no BOM, no ECN, and no revision-history page**.

That SP-332 documents the dedicated cabinet and *only* the dedicated cabinet is
now the load-bearing fact: it is why the schematic says 68010 and MAME says
68000 without either being wrong.

Assembly numbers, recorded in case the JAMMA package is ever wanted for other
reasons (the CPU question no longer needs it):

| Item | Value |
|---|---|
| Escape Main PCB assembly | **`046145`** — sheets 2-10 stamped `A046145-01 D`; Sheet 1 cites the wildcard `046145-XX` |
| Stand-alone audio PCB | `043713` — sheets 11-14 stamped `A043713-XX D` |
| Main wiring diagram | `046977-01 A` |

The `-XX` wildcards are the only hint in the package that more than one dash
number exists — consistent with a second cabinet variant, though the package
never names one.

One caution for anyone mapping ROM sets to cabinets: **MAME's sets do not
distinguish them.** `reference/eprom.cpp` defines `eprom`, `eprom2`, `klaxp1`,
`klaxp2` and `guts`; `docs/ROMMAP.md:47` records `eprom2` as purely a
program-ROM revision ("same layout, all-rev-1 program ROMs"). No set corresponds
to a cabinet style, and all five are instantiated as `M68000`. So the CPU
variant is **not** inferable from the ROM set the player loads — which is
precisely why `CPU_TYPE` is a configuration choice rather than something the
core could auto-detect.

#### 1.6.2 The A/B, measured — behaviour identical, interrupt entry ~5 clocks slower

Everything above argues the two parts are indistinguishable *to this ROM*. That
is a claim about correctness, and it is worth separating from a claim about
timing, because the second one is **false** and the docs should not pretend
otherwise.

`sim/run_worldwake.sh` run twice over 400 frames of dual-CPU IRQ traffic, once
at `CPU_TYPE=0` and once at `CPU_TYPE=1`, everything else identical:

| Metric | `CPU_TYPE=0` (68000) | `CPU_TYPE=1` (68010) |
|---|---|---|
| frames / `ready_frame` | 400 / 6 | 400 / 6 |
| `wakes` / `iacks` | 388 / 388 | 388 / 388 |
| `premature` / `restarts` / `failpark` | 0 / 0 / 0 | 0 / 0 / 0 |
| `reldrops` / `storm_max` | 1 / 1 | 1 / 1 |
| **`ackdly_avg`** | **73 clocks** | **78 clocks** |
| verdict | ALIVE | ALIVE |

**Every correctness and liveness metric is identical. One timing metric is
not.** `ackdly` is the measured vblank→`$360000` ack delay, and it moves +5
clocks.

That number is not noise, and it is not a defect — it is the extended frame
doing exactly what a 68010 does. Stacking 8 bytes instead of 6 is one extra
word written on exception entry and one extra word read on `RTE`: about two
extra bus cycles, ~4-8 clocks depending on arbitration. +5 on a 388-sample
average is what that predicts.

So `CPU_TYPE=1` is, very slightly, **slower on interrupt entry** — and that is
the authentic behaviour for a dedicated-cabinet board, whose MC68010P8 pays the
same cost. For scale: 5 clocks against a 119,318-clock frame is **0.004%**, with
roughly one vblank interrupt per CPU per frame. Measurable in a bench,
imperceptible on screen, and in the opposite direction to the loop-mode
speed-up that §1.4 refuted.

Two smaller shifts move with it and have the same cause: the extra CPU reaches
runtime-ready 50 ns earlier, and its one release-drop lands at frame 194 instead
of 193.

> **Verdict.** "No observable difference" is right about *behaviour* and wrong
> about *timing*. The honest form is: identical results, ~5 clocks more per
> interrupt, which is the 68010 being a 68010.

### 1.7 Could `CPU_TYPE` be a runtime switch in the interact menu? — assessed, and the recommendation is NOT YET

Since both cabinet variants are authentic and a single ROM image serves both, an
obvious idea is to expose the variant as a menu option that takes effect on
reset, like a cabinet DIP, so a user can match whichever board they own without
a reflash. Assessed here; **not implemented, and not recommended for now.**

**Is the hook there? Partly.** `TG68K` exposes `CPU` only as a **generic**
(`TG68K.vhd:47`). It is the inner kernel that takes it as a **port**
(`TG68KdotC_Kernel`, declared at `TG68K.vhd:100`, driven at `:180`). So a
runtime switch needs a vendored change to the `TG68K` wrapper to add a port
passthrough — small, but it is a CPU-core edit, and `escape_core`'s `CPU_TYPE`
would have to become a port rather than a generic.

**Does the kernel latch it safely at reset? NO — and this is the important
finding.** `use_VBR_Stackframe` is a plain registered follower of `cpu(0)`
(`TG68KdotC_Kernel.vhd:510-516`): it is clocked every cycle, is not gated by
`clkena_in`, and **has no reset term at all**. `cpu(0)` is *also* used
**combinationally** in the instruction decoder (`:2082`, `:2119`). Nothing
anywhere holds the value stable across execution.

The consequence is not theoretical. Changing the variant mid-execution means an
exception pushed as one frame size can be popped as the other — which is
precisely the fault injected as a negative control for §1.3.1, and it kills the
CPU outright: **1/30 heartbeat windows, 29 stalls**. A runtime switch would
therefore be correct *only* while both CPUs are held in reset, and the CPU core
would not protect you if that discipline were ever broken. Any implementation
should first add an explicit "latch `cpu` at reset release" to the kernel (a
two-line vendored change) so the hazard is structural rather than procedural.

**What it costs.** Today `CPU` is a constant, so Quartus constant-folds it: the
`use_VBR_Stackframe` register collapses, the `trap0`→`trap1` vs `trap0`→`trap2`
microcode branch prunes to one path, the `rte2`→`rte3` word-pop branch prunes,
and the `SR_Read` decode branch prunes. As a live signal **none of that folds** —
both microcode paths stay, plus combinational `cpu(0)` fan-out into instruction
decode. In the 7.159 MHz CPU domain that is a non-issue for setup (a 139.7 ns
period with ~120 ns of headroom, §2.4). The real exposure is the same one §2.4
identifies: any logic change reshuffles placement, and this design's hold margin
is **+0.100 ns** with a known +0.005 ns path where **`BUILD_ID` alone moved it
0.088 ns** (`DEVIATIONS.md` D5). That is a re-roll risk, not a design cost — but
it is a re-roll for a feature with no observable effect.

**And that is the argument against.** §1.3, §1.3.1 and §1.4 exist to show that
**this ROM cannot tell the two parts apart** — no reachable 68010 instruction, no
handler that touches the frame, 0.0000% loop-mode occupancy, and TG68K has no
loop mode anyway. So a user toggling this switch would see, and could see,
*nothing at all*. A menu item that produces no feedback is a support burden
("did it apply?") rather than a feature, and it would be buying that burden with
de-optimised CPU-core logic and a placement re-roll.

**Recommendation: do not build it now.** Stated plainly, because there is a real
argument on the other side — it is genuinely more authentic to let a JAMMA owner
run a JAMMA CPU, and the "takes effect on reset" semantic is exactly the right
model. If it is wanted later, the order should be: (1) latch `cpu` at reset in
the kernel, (2) measure the ALM/M10K/slack delta in CI *before* committing to
the menu plumbing, (3) only then wire the interact entry, with the reset
sequencer holding **both** CPUs — the extra CPU's release is driven by the main
CPU, so a partial reset is not sufficient.

For BUILD 110 the right shape is the current one: a compile-time selector with
one place to change it, defaulting to the dedicated cabinet.

---

## Part 2 — the mux arbiter

### 2.1 What the board actually does (read off sheet 5)

Confirmed on `page6.png` (SP-332 Sheet 5) at high magnification:

| Designator | Part | Role |
|---|---|---|
| **40M / 50M** | `32KX8` SRAM ×2 | The shared RAM — 32K × 16 = **64 KB = `$160000-$16FFFF` exactly** |
| **40K / 50K** | `U27512` ×2 | Common ROM (`CROM`), also on the common bus |
| **30M** | `LS158A` quad 2→1 mux, **SEL = EWAI** | Selects *which CPU's* `A20`, `/UDS`, `/LDS`, `R//W` drive the common RAM |
| **60J/60K** (sheet 4), **40N/50N** (sheet 5) | `LS244` | Tri-state the two CPUs' address buses onto the common `CA` bus, enabled by `/EWAI` and `EWAI` respectively |
| **40F/30F/40P/20L** | `LS245` | Bidirectional data buffers onto the common `CD` bus |
| **50P** | `PAL16L8` | ECPU address decoder — outputs `/ECOM`, `/COMRAM`, `/CROM`, `/CIO`, `/EROM0-2` |
| **50F** (sheet 4) | `PAL20L10` | VCPU address decoder — outputs `/COM`, `/ROM0-3`, `/VRAM`, `/STIK`, … |
| **30D** (sheet 4), **30L** (sheet 5) | `F163`/`LS163A` counters | Per-CPU wait-state generators; `RCO` → `/DTACK` |

**The arbiter itself is a cross-coupled NOR latch**, sheet 4 bottom-left:

```
  ENOWAI = NOR( /ECOM , EWAI   )      60N LS02
  EWAI   = NOR( /COM  , ENOWAI )      20J LS02
```

`/COM` and `/ECOM` are the two CPUs' "I want the common bus" decodes. `EWAI` and
`ENOWAI` are the mutually-exclusive ownership outputs. This is a textbook SR
mutual-exclusion latch, and it is the whole arbiter: it (a) selects the 30M mux,
(b) enables one CPU's address buffers and disables the other's, (c) steers the
data buffers, and (d) gates the wait-state counters — sheet 4 shows `/EWAI AND
COM` (20H LS08) feeding the 30D counter's control, i.e. **the CPU that wants the
common bus while the other owns it does not get its `/DTACK`, so it stalls.**

That structure is why 68000 read-modify-write is naturally indivisible on this
board, and why the real hardware never suffers the TAS race that cost this
project ~25 builds. `docs/ARCHITECTURE.md:102` and `DEVIATIONS.md` B1 describe
this correctly; this is now schematic-verified rather than asserted.

One correction to the existing docs: **50P is the ECPU address decoder, not the
wait-state generator.** The wait states are generated by the 163 counters at 30D
(VCPU) and 30L (ECPU). `docs/ARCHITECTURE.md:102` calls 50P "the wait-state
arbiter", which conflates the two.

### 2.2 What we built instead

True dual-port RAM (`dpram_bytelane_syn`, `awidth=15`) plus an explicit TAS
interlock (`TASLOCK_EN`) keyed on the operand address, with TG68K's `LOCK` output
mirroring `exec_write_back`. It reproduces *indivisibility* — 114 ownerless locks
in 306 trials without it, **0 in 514 with it** — but not *contention*.

### 2.3 What we lose: contention. Quantified.

On the board, one CPU genuinely stalls while the other owns the common bus, and
those stalls are part of the machine's authentic timing. Our dual-port RAM has no
such stall (only BUS-99's occasional one-clock yield). How much are we missing?

**Measured inputs** (MAME 0.289, 60 s / 3,596 frames, scripted 1-player level-1
play; wide taps on both CPUs' program spaces):

| | COMRAM `$16xxxx` | CROM `$06-07xxxx` | **common-bus total** | all bus cycles |
|---|---|---|---|---|
| Video CPU | 2,685.7 /frame | 56.7 /frame | **2,742.4 /frame** | 25,377.5 /frame |
| World CPU | 5,452.5 /frame | 9.8 /frame | **5,462.2 /frame** | 22,222.8 /frame |

(Common-ROM traffic turns out to be negligible; the common bus is effectively the
shared RAM. 73.6 % of the video CPU's COMRAM traffic falls inside its logic body.)

Sanity check against the project's own published figures: this run's mean logic
bodies are 69,452 clocks (video) and 55,332 (world), against
`docs/PERF_CADENCE.md`'s 73,724 / 57,376 for 1-player play. Consistent.

**The model** — and it *is* a model, flagged as such. A frame is 119,318 CPU
clocks. Treating each common-bus access as occupying the bus for one 68000 bus
cycle and assuming the two CPUs' accesses are independent:

| Owner cycle | Bus occupancy (V / E) | Collisions per frame | Stall clocks/frame per CPU | Share of frame |
|---|---|---|---|---|
| 4 clocks (no wait states) | 9.2 % / 18.3 % | **502 each way** | ~1,004 | **0.84 %** |
| 6 clocks (2 wait states) | 13.8 % / 27.5 % | **753 each way** | ~2,260 | **1.89 %** |

Scoped to the video CPU's logic body, where the cadence problem lives: about
**+1.1 % to +2.4 %** on a 69,452-clock body.

**Caveats, stated plainly.**

- MAME time-slices the two CPUs by quantum rather than running them concurrently,
  so it **cannot** measure true collisions. The *rates* above are measured; the
  collision count is arithmetic on top of them.
- The independence assumption is **optimistic**. The two CPUs are known to be
  correlated: the world CPU spins on the `$16CC00` semaphore waiting for the
  video CPU, which `logic_cadence.lua` already counts as `spin_reads`. Correlated
  access clusters more collisions, not fewer. The real figure is probably worse
  than the table.
- The exact wait-state preload of the 30D/30L counters was not decoded from the
  schematic, which is why the answer is given as a 4-to-6-clock bracket rather
  than a single number.

### 2.4 Feasibility and cost of building the real thing

Yes, it is buildable — that was never the question. The costs:

**M10K: zero saving.** The shared RAM is 32768 × 16 = 524,288 bits. On Cyclone V
the M10K's usable depth is set by width mode, not by port count; true-dual-port
does not halve capacity. At the project's own calibration of 8,192 usable bits
per block (`docs/VSHAD3.md:103`), it is **64 blocks either way**. The array is
depth-limited, not port-limited. Single-porting **does not free a single block**
on the constraint that actually binds this design. The only saving is ALM-scale:
the ~36 collision-bypass flops in `dpram_bytelane_syn` plus ~29 interlock flops.

**Setup timing: free.** The CPU domain is 7.159 MHz — a 139.7 ns period — and the
recorded worst-case setup slack (+4.9 to +5.2 ns) belongs to the 35.795455 MHz SDRAM
domain. There is roughly 120 ns of headroom in front of the shared RAM. An
arbiter, a mux and a stall path cost nothing there.

**Hold timing: a re-roll risk, not a design cost.** The `vg_dataB → pfring` path
(+0.005 ns, `DEVIATIONS.md` D5) is in `core_top`'s SDRAM→CPU-domain crossing, not
in `escape_core`, so there is no logical interaction. But at +0.005 ns that path
is placement roulette — `BUILD_ID` alone moved it 0.088 ns — and a change this
size reshuffles placement and may fail the CI slack gate for reasons unrelated to
its merit.

**Fastpath and ROM shadows: unaffected.** `fast_v_spec` is gated to
`addr ≤ $09FFFF`, so the fastpath never speculates on `$16xxxx`; the `vshad*`
shadows cover ROM ranges only. Both are ready/valid mechanisms, not
fixed-latency ones.

**The blocker, and it is a real one.** The board's indivisibility comes from
`/AS` staying asserted across the whole read-modify-write, so an `/AS`-level
ownership mux cannot flip mid-TAS. **TG68K does not do this.** It releases `/AS`
between the two halves (TobiFlex/TG68K.C issue #22), and the project has the
number: `tb_escape_tasrace` measures a 13-clock TAS of which **`/AS` is HIGH for
3**. A faithful `/AS`-keyed arbiter would release ownership inside that 3-clock
gap and let the other CPU write the lock byte — which is precisely the build-101
freeze, restored.

So the authentic structure, built faithfully on this CPU core, is **not actually
atomic**. To keep atomicity you would have to hold the grant across the `/AS`
gap using a signal that spans it — and the only such signal is TG68K's
`LOCK`/`exec_write_back`, which is exactly what `TASLOCK_EN` already uses. The
change therefore either reintroduces the project's dominant bug, or
re-implements the current interlock inside the arbiter under a different name,
or requires modifying vendored TG68K microcode that nothing currently tests.

**Scope:** ~28-32 distinct edit sites; ~200 lines deleted, ~300 written; two
vendored CPU files touched; 15 benches to re-run; and six new verification
artefacts that do not exist today (a single-port arbiter bench, a
write-strobe-during-stall assertion, an `/AS`-gap pass/fail gate, a shared-RAM
busrate image, a starvation/fairness soak, and a CI re-baseline).

The region is also the most regression-dense in the design: SDSCHED-78
(stale-serve), SDSCHED-80 (write-strobe discipline), SDSCHED-83 (registered
capture), BUS-99 (yield) and TASLOCK-102 are five documented freeze fixes living
in the exact lines that would be rewritten.

One genuinely *new* risk: the board runs its two 68000s 180° out of phase, while
this core runs both lockstep on one clock edge. A strict-priority arbiter on a
lockstep pair is the phase-lock geometry that produced the build-86 freeze, and
nothing tests for it.

### 2.5 Recommendation — authentic, but not worth it before alpha

**Do not build it now.** Stated plainly, because the two motivations genuinely
pull in opposite directions:

- It is more authentic, and it would delete a bespoke interlock and a whole class
  of divergence. That is real value.
- But it costs **zero** M10K (the constraint that binds), it is **slower** by
  0.8-2.4 % on the video CPU's body — in the exact metric BUILD 109 exists to
  improve — and on this CPU core it **is not actually atomic** without keeping
  the very mechanism it was meant to replace.

The honest summary is that the current design's only deficit versus the board is
*structural fidelity*, which `DEVIATIONS.md` B1 already records honestly. Trading
a verified 0-failures-in-514 mechanism for a structure that costs the same
silicon, runs slower, rewrites five freeze fixes, and needs a CPU-core change to
be correct is not a good trade before alpha.

**What is worth doing now** is much smaller: the contention numbers in §2.3 say
the board pays ~1-2 % per frame that neither we nor MAME model. That is a
*calibration* insight, not an RTL change — see below.

### 2.6 The cadence consequence, which cuts against the original worry

Worth stating on its own, because it inverts the premise that motivated
Question 1.

The concern was that since the board is a 68010 with loop mode, **MAME might be
slower than the board**, our 0.9977 target would be too low, and the gap would be
unclosable by memory tuning. Both halves of this investigation push the *other*
way:

- **Loop mode contributes 0.0000 %** (§1.4). The board gets no speed-up from it.
- **MAME does not model the common-bus arbiter at all** (§2.3). The real board
  pays ~0.8-1.9 % per frame in arbitration stalls that MAME's model does not.

So the real board is, if anything, **slightly slower than MAME's 0.9977**, not
faster. The 0.9977 target is not too low; it is if anything marginally too high.

That does not explain our tail — median 0.973 with p10 0.703 and min 0.313 is a
*tail* shape, not a uniform few-percent slowdown, and a constant arbitration cost
would not produce it. But it does close off "the target is wrong because the
board is faster than we think" as an explanation, which was the specific worry.

---

## Reproducing

MAME needs its framework path set, or it will not launch:

```sh
export DYLD_FALLBACK_FRAMEWORK_PATH="$HOME/Library/Frameworks:/Library/Frameworks:/System/Library/Frameworks"
MAME=/Users/lloyd/Downloads/mame0289-arm64/mame
ROMPATH="/Users/lloyd/Documents/Lloyd Projects"     # parent dir; romset dir is "eprom"

$MAME eprom -rompath "$ROMPATH" -video none -sound none -nothrottle \
      -skip_gameinfo -autoboot_delay 0 -autoboot_script <script>.lua
```

The Lua probes used here are throwaway instrumentation and are not committed;
they are rebuildable from the descriptions above. The two rules that matter if
you rebuild them:

1. **Use a wide tap.** Narrow read taps do not see opcode fetches in MAME 0.289.
   A 2-byte tap on a hot instruction reads **zero** — a check that cannot fail.
2. **Carry controls.** Every count above is accompanied by a positive control
   that must fire (`$404E0`, once per logic frame) and a negative control that
   must not (`$0E0200`). For the exception detector, the falsification was four
   injected fatal opcodes.

Schematic pages are re-rendered from the source PDF with PyMuPDF; the part-number
fields need ~1200 dpi and a crop, and the labels are rotated 90°.

---

## What is measured, what is inferred, what needs the board

**Measured:** the part marking and date code on the physical CPU (photograph);
the schematic part numbers and designators; the arbiter topology;
image-equality between our ROM builds and MAME's program space; the complete
vector tables and every handler's disassembly; absence of MOVEC/RTD at any
alignment; 400 s of vector-fetch counts with the detector falsified four ways;
S=1 at every `MOVE SR` site and every frame sample; DBcc site inventory on both
CPUs; in-body DBcc occupancy by two independent methods with controls; per-CPU
common-bus access rates.

**Inferred:** the code/data verdicts for the 1,502 MOVES and 23 MOVE CCR raw hits
(recursive descent under-approximates — but the dynamic result makes it moot,
since executing any of them would have taken vector 4 and killed the CPU); the
M10K block counts (no Quartus fitter report is committed to this repo — the
283/308 figure exists only as prose in `docs/VSHAD3.md`); the collision counts in
§2.3, which are arithmetic on measured rates, not observed collisions.

**Settled by the physical boards:** there are **two** variants, and both are
authentic — the dedicated cabinet is a **68010** (`MC68010P8`, date code
`A71R8813`, photographed; SP-332 draws `U68010` at 45J/20P) and the **JAMMA**
version is a **68000** (photographed). §1.5, §1.6. It changes nothing measurable
in the RTL either way, which is what makes supporting both free.

**Nothing on the CPU question is open any more.** The one caveat worth keeping
in view: the variant is not inferable from the ROM set, so which CPU a given
player's board has is a configuration choice, not something the core can detect.
