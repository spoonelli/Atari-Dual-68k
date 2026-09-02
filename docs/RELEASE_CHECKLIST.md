# Pre-flight checklist — first public RC

Status of every item is one of **TODO**, **DONE**, or **BLOCKED (needs a call)**.
Nothing here is a nice-to-have: the blockers are things that are painful or
impossible to change after strangers have installed the core.

Two sequencing facts drive the order:

1. **There is exactly one history rewrite to do, not two.** The marquee purge
   and the "development artifact cleanup" are the same operation — the repo
   carries committed `output/AtariDual68k-pocket-v*` build directories going
   back to v10, which is most of the 36 MB history. Strip the marquee blob and
   those directories in a single `filter-repo` pass, force-push once.
2. **The core identity rename must precede the first release.** Renaming
   `spoonelli.ataridual68k` after people have installed it breaks their setup.
   It shares a gate with the save-path device test, because that test is what
   proves the rename did not orphan saves.

---

## A. Blockers

| # | Item | State | Note |
|---|---|---|---|
| A1 | Core identity `spoonelli.ataridual68k` -> `spoonelli.eprom` | **DONE (v0.1.0 prep)** | Renamed: core.json shortname, package.sh, docs. `platform_ids` stays `eprom`; saves platform-keyed. Device confirmation of save carry-over folds into A6. Upgraders must delete the old core folder (noted in RELEASE_NOTES + README). |
| A2 | **Third-party attribution / GPL-3.0 compliance** | **DONE (v0.1.0 prep)** | `NOTICE.md` at repo root: compliance inventory of every compiled component with authors, licences, vendored-file locations; reference/ material separated; the TMS5220 coefficient-provenance question stays flagged there. |
| A3 | Single combined history rewrite (marquee blob + `output/` dirs) | **DONE (2026-08-28)** | Executed and verified: blob and `output/` gone from all branches and tags, repo 36 MB → 2.4 MB. Residual: GitHub's read-only `refs/pull/1-3` still snapshot pre-rewrite history (no ROM data there; the marquee is reachable only by explicit PR-ref fetch) — a GitHub Support ticket can purge them if desired. Backups: `atari-dual68k-prepurge-backup.bundle`, `atari-dual68k-prerelease-backup-20260828.bundle`. |
| A4 | `input.json` vs RTL audit — **all** buttons, **both** players | **DONE (v0.1.0 prep)** | Full sweep: A/B/X/Y/Select map to cont1_key 4/5/6/7/14 exactly as the RTL consumes them, both controller blocks declared, Start-shares-Jump matches the schematic, shoulders intentionally unmapped (HUD-only). No mismatches found beyond the long-fixed P2 bomb. |
| A5 | Debug HUD gated behind a menu toggle, default off | **DONE (build 114)** | `interact.json` id 38 'Developer HUD', default unchecked. With it clear, `diag_on` is forced low, so L1/R1/R/L2 do nothing and no debug path reaches video. RTL still compiled in -- see **section F**; the `DIAG_EN` compile-time half remains open. |
| A6 | Save-path device test on real hardware | **DONE (v0.1.0)** | Owner-verified 2026-08-29: saves carried over from the `spoonelli.ataridual68k` dev install to `spoonelli.eprom`. |
| A7 | Clean-boot look on real hardware | **DONE (v0.1.0)** | Owner-blessed 2026-08-29 on the RC2 package (BUILD_ID 35); v0.1.0 tagged and released. |
| A8 | **Tile-shaped holes in motion objects** | **DONE (builds 131-132)** | Closed by MOPAIR-131 (paired even/odd line buffers, 2 px/clock — the schematic's MOL/MOR) + MOPF2-132 (tile-1 prefetch lane). Crowd fixture missing pixels 527 → 0; device-verified across full playthroughs. Record: [`MO_TILE_HOLES.md`](investigations/MO_TILE_HOLES.md). |

## B. Identity, metadata, and store presence

| # | Item | State | Note |
|---|---|---|---|
| B1 | Pocket game label | **DONE (v0.1.0)** | Platform name: `Esc Robot Monst` (owner call after on-device menu checks, 2026-08-29; well under the 31-char limit). Full title lives in core.json description and the docs. Category Arcade / Atari Games / 1989 unchanged. |
| B2 | Version scheme | **DONE** | Scheme fixed (2026-08-28, owner call): `core.json` version and the git tag move in lockstep — `v0.1.0` = first public RC, `0.x.y` during field-testing, `1.0.0` only when every section-A blocker is closed; patch bumps for fixes, minor bumps for features (eprom2). `BUILD_ID` stays the internal on-HUD build counter, and RELEASE_NOTES records the mapping (v0.1.0 = build 35) so a HUD photo identifies a release exactly. MiSTer versions independently (`mister-v0.x.y`). `core.json` set to 0.1.0. |
| B3 | pupdate / openFPGA inventory listing | **DONE (2026-08-31)** | Submitted as openfpga-library/analogue-pocket#1536; the inventory serves `spoonelli.eprom` (v0.1.1, correct date) and pupdate installs it — owner-verified end to end. |
| B4 | Public vs private decision | **DONE** | Public, post-purge. See A3 for the refs/pull residual and the optional Support ticket. |
| B5 | `video.json` out-of-box look (aspect, scaler) | **DONE (audited 2026-08-30)** | One scaler mode: 336x240 at 4:3, no rotation/mirror — correct for this game. |
| B6 | `interact.json` defaults sane for a first-time user | **DONE (audited 2026-08-30)** | 12 variables (under the Pocket's 16-render cap), every default correct: Service/Skip-Test off, sticks normal, deadzone 8, both volumes full, EEPROM Autosave on, ROM Shadow on, Developer HUD off. |

## C. Repo hygiene — "looks like a commercial release"

| # | Item | State | Note |
|---|---|---|---|
| C1 | Strip committed `output/` build dirs from history | **DONE** | Folded into A3, executed 2026-08-28. |
| C2 | Branch pruning | **DONE (2026-08-28)** | 53 heads → 3: `main` / `pocket` / `mister`. All pre-prune branches preserved in `atari-dual68k-prerelease-backup-20260828.bundle`. |
| C3 | Decide what `main` means | **DONE** | `main` mirrors `pocket` (fast-forwarded on every pocket push); `mister` carries the port. |
| C4 | README + support doc cleanup | **DONE (2026-08-29)** | Top-level README refreshed for release (accuracy benchmarks, architectural-decisions section); docs reorganized (investigations/ split) and accuracy-swept; READMEs synced across all three branches; 0 dead links. |
| C5 | ROM prep end-to-end from a clean machine | TODO | `docs/ROMS.md` + `build_rom.py` with no local state. |
| C6 | MiSTer fork: same release or separate? | **DONE — separate** | MiSTer tags independently (`mister-v0.x.y`), zips per build from the `mister` branch. Its two release gates (retire boot splash; `escape_YYYYMMDD.rbf` naming — the latter done in CI) are recorded in [`MISTER.md`](MISTER.md)'s status note. |

## D. Documentation and the historical record

The record is substantial — 26 docs, ~9,400 lines, with `docs/README.md`
separating reference from investigation. Three real gaps:

| # | Item | State | Note |
|---|---|---|---|
| D1 | **`HISTORY.md` stops at build 102** | **DONE (2026-08-31)** — extended through build 153 and the v0.1.x releases (eras 9–15) | Titled "v1–v78"; covers v1–v78 plus builds 101–102. **Builds 103–113 are absent** — the SDRAM arc, VSHAD3, the stain fix, TAS atomicity, EEPROM, the MiSTer port, bus hardening. `RETROSPECTIVE.md` covers that ground but **thematically, not chronologically**: it answers "what did we learn about sprites", not "what happened in build 107". |
| D2 | **`HISTORY.md` has two headings numbered "Era 6"** | **DONE** — resolved in an earlier extension; verified single-numbered eras 1–15 | Lines 89 and 116. Appended without reconciling — exactly the drift `docs/README.md` warns about, in the doc that is supposed to be the spine. |
| D3 | **Nothing separates community-reusable knowledge** | TODO | See below. |
| D4 | `RELEASE_NOTES.md` known-issues honesty | **DONE (v0.1.0)** | Known-issues rewritten with resolution stories in the pre-release refresh; accuracy section carries the measured benchmarks. |

### D3 — what is worth extracting for other developers

Several findings are general to openFPGA/MiSTer work and are currently buried in
project-specific documents. A `docs/FOR_OTHER_DEVELOPERS.md` would carry its own
weight:

* **M10K blocks address only 8,192 of their 10,240 bits** at byte-aligned
  widths; the rest is parity. A "wasted BRAM" calculation that ignores this is
  wrong — ours looked like 64 blocks of waste and was actually 96.5% efficient.
* **The Pocket renders only 16 `interact.json` variables.** We shipped 28 and
  silently lost the tail.
* **A proof-it-can-fail control is itself calibrated**, and goes stale exactly
  like the constant it guards. Three instances here, all found the same way.
  See `LESSONS.md` — this is the most transferable thing in the repo.
* **TG68K's TAS is not indivisible**: 13 clocks with `/AS` high for 3. Anyone
  building a dual-68000 arcade core on TG68K will hit this.
* **TG68K asserts write strobes half a clock after `/AS`**, invisible to a
  rising-edge-sampled DTACK generator — benign until it isn't.
* **SDRAM refresh maths must be re-derived when the clock changes**; the JEDEC
  7.8125 us limit in *clocks* moves with it, and so must the test's controls.
* **`.mra` conventions** for referencing MAME chips by CRC without shipping ROM
  data.
* **Guarding a release package by content, not filename.** Ours refused a `.rom`
  but happily shipped the same bytes named `gfxdata.bin`. Five guards now, each
  provoked by `test_package_guards.sh`.

## E. Testing before the tag

| # | Item | State |
|---|---|---|
| E1 | Fresh-SD **clean install** (not an upgrade over an existing install) | TODO |
| E2 | Save-path device test (A6) | TODO |
| E3 | Clean-boot look (A7) | TODO |
| E4 | Two-player session, including the fixed P2 bomb | TODO |
| E5 | Package guards green on the actual RC artifact (5/5, zero ROMs) | DONE for build 113 |

## F. A5 in detail — what to do with the diagnostic HUD

Today: `L1` edge-toggles `diag_on` (starts hidden), `R1` cycles 7 pages. There is
no `interact.json` entry. So the HUD is reachable by any player who presses L1,
and L1/R1 are unavailable for anything else.

Four options, and the trap in the obvious one:

1. **Rip it out for release.** Cleanest-looking, and the worst for support: the
   HUD is how a field report becomes a diagnosis. Losing it means every user
   report is "it looked wrong" with nothing behind it.
2. **Compile-time flag only** (`DIAG_EN`, default 0 in the shipped build,
   documented for anyone who pulls the core). Attractive — but note the trap:
   if the repo default differs from what was released, **the artifact people
   test is not the artifact people build**. That divergence has bitten this
   project before in other forms. If we take this route, the repo default and
   the release build must agree, and the flag must be flipped by a deliberate,
   documented edit rather than by a release script.
3. **Runtime gate via `interact.json`** ("Developer HUD", default off), keeping
   the RTL compiled in. A player never meets it; a developer or a user helping
   debug enables it from the menu with no rebuild. L1/R1 become free.
4. **Both**: `DIAG_EN` compile-time (default **1**, so anyone pulling the core
   gets it) *plus* the runtime menu gate defaulted off.

**Recommendation: option 4.** *(Runtime half shipped in build 114; the
`DIAG_EN` compile-time half is still to do.)* It is the only one that satisfies all three
constituencies at once — the player never sees a developer overlay, the person
filing a bug report can turn it on without a toolchain, and anyone who pulls the
core to build on it gets the diagnostics unchanged and unsurprising. It also
keeps the repo default and the released bitstream identical, which option 2
does not.

**One thing to measure, not assume, before deciding.** The HUD carries a hex
font, probe registers, and capture logic. Compiling it out may free M10K and
logic, and at **299/308 M10K** that headroom has real value — the vshad3-off
build freed 25 blocks, so the effect size here is worth knowing. But *do not*
ship an unmeasured `DIAG_EN=0` variant: it is a different bitstream from the one
that was tested, and this project's own timing history (a `BUILD_ID` constant
alone moving worst-case hold by 0.088 ns) says small diffs are not free.
Measure the saving first; then decide whether it changes the recommendation.

---

## H. v0.1.2 planning (drafted 2026-08-31, post-submission)

Sequenced after the MiSTer-devel submission (sent 2026-08-31); nothing here
blocks the shipped v0.1.1 releases.

**MiSTer v0.1.2 — close the flicker tail (fetch-cost axis, bench-first):**

| # | Item | Note |
|---|---|---|
| H1 | `sdram_openrow` timing constants at 35.795 MHz | tRCD/tRP 2→1, tRFC 9→3 — datasheet-legal with margin (27.94 ns/clk). One variable; scored on `tb_mister_moarb` before hardware; watch the hold floor. |
| H2 | PF line-start burst spreading | Only if H1 leaves the tail: the playfield's clustered line-start fetches are the residual MO latency-spike source. |
| H3 | MiSTer-devel review follow-ups | Reactive; structural changes as requested. |
| H4 | db retirement on adoption | Per the documented handoff in `DISTRIBUTION.md`. |

**Pocket v0.1.2 — small truths:**

| # | Item | Note |
|---|---|---|
| H5 | Ship the refreshed `info.txt` | Committed 2026-08-30, rides the next Pocket release. |
| H6 | D4: 33-pixel deviation at scroll 50/157 | Suspect already named (un-wrapped `spr_right` in off-screen rejection); one bench-driven attempt. |
| H7 | Speech-tail adjudication | The last unmeasured claim in the docs — measure vs MAME audio, then fix or retract with numbers. |

**Both platforms — accuracy, next release after v0.1.2 (shared machine RTL):**

| # | Item | Note |
|---|---|---|
| H8 | Factory-map "halftone": travelled nodes must dim, not vanish | Found 2026-09-02 against the owner's real-PCB capture (`Genki Arcade - 2026-09-01 234201.mp4`, frame 24402, sector D level 03): the board renders already-travelled map nodes at reduced intensity; ours appear to drop them. Mechanism per the PCB GAL equations MAME carries (`eprom.cpp` screen_update): motion objects with the top priority bit set draw nothing themselves but *stain* the playfield beneath — `SHADE`/`CRA9` selects the alternate (dimmer) colour-RAM bank. Check `escape_core` handles that MO class as stain, not transparency. Oracle = the PCB capture, not MAME. Present in every release to date; not a regression. |

**Slow-burn (no version attached):** MiSTer vertical-sync edges aligned to
the horizontal-sync leading edge (`VSYNC_HSTART = HSYNC_START`, the
MegaDrive VDP idiom) instead of `x=0` — cosmetic on the wire, since
composite sync merges the pulses and the TV locks to the HS edge anyway;
logged 2026-09-02 after the MISTER-161 sync calibration; **authentic
composite-sync record** — the board's real H/V sync positions, widths,
vertical-sync line count and serration are unrecorded (MAME models none of
it; ours were chosen, then TV-calibrated). Path 1, no hardware: decode the
six GAL16V8 fuse dumps in the romset (`136069.50f/50p/55p/70j/100t/100v`)
with MAME `jedutil` — if one is the sync/blank generator the positions fall
out in counter terms. Path 2: USB scope on the csync line (period, pulse
width, porches to first active pixel via the service-mode grid, VS lines,
serration). Adopt widths / VS structure / edge alignment on both platforms
if they differ; keep the display-centred default position (arcade monitors
were pot-centred, so absolute position was never user-visible); section-F `DIAG_EN` decision; `eprom2`
(second CRC table + MRA + both-platform verify); HISTORY.md builds-103+
chronology; C5 clean-machine ROM-prep walkthrough; optional GitHub Support
ticket for the pre-rewrite `refs/pull/*` snapshots; **save-states
evaluation** (MiSTer `SS<base>:<size>` DDR window + framework hooks; the
open question is CPU state capture — the imported T65/TG68K/jt51 expose no
internal state, so the fork is in-house CPU rewrites vs a sequencer-walk
snapshot; the MISTER-155 pause already provides the coherent-freeze half,
and any answer must serve both platforms or be MiSTer-only by design).
