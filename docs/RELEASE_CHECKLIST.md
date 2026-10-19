# Release checklist

Status of every item is one of **TODO**, **OPEN**, **DONE**, or **BLOCKED (needs a call)**.
Nothing here is a nice-to-have: the blockers are things that are painful or
impossible to change after strangers have installed the core.

Sections A–F began as the pre-flight checklist for the first public RC
(v0.1.0) and are kept as that record. **What blocks the next release is in
section G** ("0.2 release gates"); section H carries the post-v0.1.1 work items.

Two sequencing facts drove the v0.1.0 order (record — both done):

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

The record is substantial — 26 docs, ~9,400 lines at v0.1.0 (36 docs,
~13,500 lines by 2026-10-17), with `docs/README.md` separating reference from
investigation. Three real gaps at the time:

| # | Item | State | Note |
|---|---|---|---|
| D1 | **`HISTORY.md` stops at build 102** | **DONE (2026-08-31)** — extended through build 153 and the v0.1.x releases (eras 9–15); since extended through build 161 and the milestone 0.2 test builds (eras 9–17) | *(Original gap, as written:)* Titled "v1–v78"; covers v1–v78 plus builds 101–102. **Builds 103–113 are absent** — the SDRAM arc, VSHAD3, the stain fix, TAS atomicity, EEPROM, the MiSTer port, bus hardening. `RETROSPECTIVE.md` covers that ground but **thematically, not chronologically**: it answers "what did we learn about sprites", not "what happened in build 107". |
| D2 | **`HISTORY.md` has two headings numbered "Era 6"** | **DONE** — resolved in an earlier extension; verified single-numbered eras 1–17 (re-checked 2026-10-17) | Lines 89 and 116. Appended without reconciling — exactly the drift `docs/README.md` warns about, in the doc that is supposed to be the spine. |
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
| E2 | Save-path device test (A6) | DONE (v0.1.0) — see A6 |
| E3 | Clean-boot look (A7) | DONE (v0.1.0) — see A7 |
| E4 | Two-player session, including the fixed P2 bomb | TODO |
| E5 | Package guards green on the actual RC artifact (5/5, zero ROMs) | DONE for build 113 |

## F. A5 in detail — what to do with the diagnostic HUD

Before build 114 (record; A5 since gated it behind Developer HUD): `L1` edge-toggles `diag_on` (starts hidden), `R1` cycles 7 pages. There is
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

## G. 0.2 release gates (current — updated 2026-10-17)

**Shipped:** Pocket **v0.1.1** (build 36, 2026-08-30); MiSTer **mister-v0.1.2**
(build 161, 2026-09-02), adopted into MiSTer-devel 2026-09-03.
**Order of work (owner):** MiSTer 0.2 first, then Pocket 0.2 (Escape set 2 +
H8), then the Klax / Guts Pocket cores. Nothing ships until its rows below
are DONE.

Test builds (unreleased, handed to the owner for device testing):

| Build | Carries |
|---|---|
| Pocket 37 | H8 factory-map halftone (MOSHADE-162) |
| Pocket 38 | H8 + Escape set 2 (EPROM2-163) |
| MiSTer 162 | H8 |
| MiSTer 163 | + Escape set 2 |
| MiSTer 164 | + Klax prototypes (KLAX-165, GAMESEL-167) |
| MiSTer 165 | + Guts video mode (GUTS-168) |
| MiSTer 166 | + per-game button mapping |
| MiSTer 167 | + GUTS-169, MRAs say `<rbf>Escape</rbf>`, rbf named `Escape_YYYYMMDD.rbf` |
| MiSTer 168 | + NVRAM-170 (EEPROM persistence, reliable game-byte latch), jt6295 licence notice |
| MiSTer 169 | + NVRAM-171 (Arcade-Cave saving), ALT-172 (`_alternatives/` clone MRAs) — **the build under test** |

Work-tag numbers are not build numbers (GUTS-169 is in MiSTer 167, NVRAM-170
in 168, NVRAM-171 and ALT-172 in 169).

**Device results so far.** Owner's first run of **MiSTer 168**: all five MRAs
(Escape set 1, set 2, Klax prototype sets 1 and 2, Guts) boot and play. The
level-3 factory map matches the PCB capture (frame 24402 / t406–410): the
travelled routes and START box dim in the same hue, the level-1 map is all
bright, the "you are here" node blinks every 10 frames (10 grey / 10 box,
a 20-frame cycle — 3 Hz at 60 fps), identical to the PCB capture, and map
timing matches — **H8 is device-confirmed on MiSTer.** Colour differences
between that MiSTer capture and the PCB capture are not attributed to the core (different capture paths; see G-post-1).
Pocket 37/38: not yet tested. MiSTer 169: not yet tested.

**MiSTer 0.2**

| # | Gate | State | Note |
|---|---|---|---|
| G1 | Device tests T1–T10 on MiSTer 169 | **PASS with notes (2026-10-18)** — notes tracked in G11 and in 170 | T1 Escape set 1 regression vs 161 (POST, attract, play, speech/music, Bomb, OSD pause/dim/rotate, CRT position); T2 H8 map halftone — **PASS on 168**; T3 set 2 POST + play; T4 Klax sets 1/2 boot as Klax every time (five launches), attract, coin, start, OKI audio, buttons; T5 Guts menu tint, attract depth, analogue stick, three buttons, samples; T6 game switching without a power cycle; T7 the 161 set-1 MRA (no game byte) still boots Escape; T8 persistence (Autosave NVRAM Off by default and no "Saving..." on menu changes; Save NVRAM survives a power cycle as a 512-byte `.nvm` named after the MRA; Autosave On saves once per OSD visit; Klax and Escape keep separate files); T9 ten minutes of crowd play, nothing worse than 161; T10 menu layout (Arcade list shows Escape set 1 and Guts only; set 2 and both Klax sets launch from `_alternatives/`). The 168 first run covers boot-and-play for all five MRAs, not the full T-list. |
| G2 | README / RELEASE_NOTES rows flipped | **OPEN — at release only** | Klax / Guts / set 2 move from "not supported" to supported, DEVIATIONS C6/C7 from "pending" to shipped, an "Unreleased — milestone 0.2" block becomes the 0.2 entry. Not before the release build exists. |
| G3 | Release PR into the MiSTer-devel fork's `releases/` | **OPEN** | The rbf (`Escape_YYYYMMDD.rbf`) plus the five MRAs in the family layout (set 1 and Guts top-level; set 2 under `_alternatives/_Escape from the Planet of the Robot Monsters/`, the Klax prototypes under `_alternatives/_Klax/`), every MRA `<rbf>Escape</rbf>` (done in 167, so the PR does not revert the maintainer's fix). The PR text must note that `_Klax` is shared with RetroShrimp's Arcade-Klax_MiSTer core — each MRA names its own rbf, so the two coexist. |
| G4 | 0.2 fixes in the build | **DONE in RTL / packaging (167–170)** | GUTS-169, MRA rbf name, NVRAM-170 (including the game-byte latch fix), jt6295 notice, NVRAM-171, ALT-172 with the recursive CI ROM-data gate; 170: KLAXBTN-174 (one button), PAUSE-174, Cave menu order. Device verification is G1 plus a 170 spot-check (Klax Flip/Start, pause mid-music then resume). |
| G5 | H1/H2 (flicker tail) in or deferred | **OPEN (decision)** | Either bench and ship H1 with 0.2 or record it as deferred; T9 is the guard either way. |
| G6 | Version metadata | **OPEN** | The MiSTer branch's `core.json` was aligned to 0.1.1 on 2026-10-17; bump both checkouts together at 0.2 (`milestone-0.2` carries 0.2.0 from Pocket RC 1). |
| G11 | Audio loss + wrong canal result | **OPEN — blocker until understood** | One MiSTer 169 session: all audio went to digital silence before a stage and stayed silent, and an expired canal timer then gave "YOU MADE IT!" (a timeout gives "YOU DID NOT MAKE IT!" in the 2026-10-18 capture). Not reproduced since: canal timeouts on 169 (set 1), 170 (set 1) and 170 (set 2) all ended on "YOU DID NOT MAKE IT!" with audio intact (2026-10-18/19). Ruled out: the runtime board select (static from the MRA byte; flipping it would also reset the second CPU). Suspected: the sound board stops answering and the game's stage-end logic depends on its reply. Reproduce by letting the canal timer expire; compare on Pocket. |

**Pocket 0.2 (after MiSTer 0.2)**

| # | Gate | State | Note |
|---|---|---|---|
| G7 | Pocket RC 1 (build 40) device tests | **OPEN** | Set 1 regression; H8 map halftone vs the PCB capture; set 2 launched from `_alternatives` (POST + play); separate saves per set (`atari_escape.sav` untouched by set 2) and a high score surviving a power cycle; an existing 0.1.x card (set 1 files only) still works. |
| G8 | Release build from the final commit | **OPEN** | Not a test build re-labelled; package guards green on the actual artifact, zero ROMs. |
| G9 | Metadata bump to 0.2.0 | **OPEN** | `core.json` version + `date_release` (the *release* date, Era 13's lesson), tag `v0.2.0`, RELEASE_NOTES records the build number; `info.txt` refreshed (H5: "v0.2.x", "eprom or eprom2", build stamp behind Developer HUD). |
| G10 | Klax / Guts Pocket cores | **LATER — after MiSTer 0.2** | One core per game: `spoonelli.klaxp`, `spoonelli.guts`; `spoonelli.eprom` is untouched. |

**Milestone items that are not release gates**

| # | Item | State | Note |
|---|---|---|---|
| G-post-1 | Palette accuracy from a same-path capture | **OPEN (post-0.2)** | Capture the PCB and the core through the same converter and settings, then judge the palette; MAME's palette formula is self-described as crude, so it is not the reference. |
| G-post-2 | PCB gameplay comparisons | **OPEN (milestone 0.2 list)** | Walk cycle, slowdowns and screen behaviour against the direct PCB reference capture of 2026-09-01 (board over MAME). Map timing already matches on MiSTer 168. |
| G-post-3 | Save states | **FUTURE (evaluation)** | See the slow-burn list. |

**Recorded decisions**

| Decision | Detail |
|---|---|
| Packaging split | MiSTer: one rbf (`Escape_YYYYMMDD.rbf`), the game picked by the MRA's index-1 byte, clones in the `_alternatives/` family layout. Pocket: one core per game — `spoonelli.eprom` untouched, `spoonelli.klaxp`, `spoonelli.guts` — after MiSTer 0.2. |
| Shared `_Klax` folder | `_alternatives/_Klax/` is shared with RetroShrimp's Arcade-Klax_MiSTer core; each MRA names its own rbf; mention it in the release PR (G3). |
| Branch merge declined | `milestone-0.2` and `milestone-0.2-mister` stay separate. Every doc fix must go to both branches. |
| MiSTer saving | Follows Arcade-Cave: root-menu "Autosave NVRAM" default Off, plus "Save NVRAM" (NVRAM-171). |
| ThunderJaws | **Future work** (owner, 2026-10-17: "keep thunderjaws as future work"). See H11. |
| Release order | MiSTer 0.2 → Pocket 0.2 (set 2 + H8) → Klax / Guts Pocket cores. |

---

## H. Post-v0.1.1 work (drafted 2026-08-31 as "v0.1.2 planning")

Sequenced after the MiSTer-devel submission (sent 2026-08-31); nothing here
blocks the shipped v0.1.1 releases. The milestone 0.2 rows (H8 onward) feed
section G.

**MiSTer v0.1.2 — close the flicker tail (fetch-cost axis, bench-first; H1/H2 did not make v0.1.2 — in or out of 0.2 is gate G5):**

| # | Item | Note |
|---|---|---|
| H1 | `sdram_openrow` timing constants at 35.795 MHz | **OPEN** (checked 2026-10-09: `sdram_openrow` still T_RCD 2 / T_RFC 9). tRCD/tRP 2→1, tRFC 9→3 — datasheet-legal with margin (27.94 ns/clk). One variable; scored on `tb_mister_moarb` before hardware; watch the hold floor. |
| H2 | PF line-start burst spreading | **OPEN** (behind H1). Only if H1 leaves the tail: the playfield's clustered line-start fetches are the residual MO latency-spike source. |
| H3 | MiSTer-devel review follow-ups | **DONE — shipped as `mister-v0.1.2` (2026-09-02, build 161).** Builds 154–161: menu pages per Cave/Psikyo/DK, credits pages retired for the about-line credit, DK-style pause + dim, Rotate/Flip, CRT H/V adjust, MRA `<buttons>` corrected (Pause + owner defaults), composite-centred sync (MegaDrive-calibrated). H1/H2 (flicker tail) carry to the next MiSTer release alongside H8. |
| H4 | db retirement on adoption | **DONE (2026-09-03)** — MiSTer-devel fork live, official distribution carries `Escape_YYYYMMDD.rbf`; empty db published under the unchanged `db_id`, README tells users to uninstall the stanza. Trigger was fork issue #1 (two dbs sharing the MRA path + a stale six-button map). |

**Pocket v0.1.2 — small truths (there was no Pocket v0.1.2; these now ride Pocket 0.2 or later):**

| # | Item | Note |
|---|---|---|
| H5 | Ship the refreshed `info.txt` | **OPEN** — rides Pocket 0.2 (G9). Committed 2026-08-30, rides the next Pocket release; at 0.2 it also needs "v0.2.x", "eprom or eprom2", and the build stamp described as appearing once Developer HUD is ticked. |
| H6 | D4: 33-pixel deviation at scroll 50/157 | **OPEN.** Suspect already named (un-wrapped `spr_right` in off-screen rejection); one bench-driven attempt. **New data point (2026-09-09):** a freshly dumped crowd scene (`scenedump2.lua` idx 108, scroll 222/422) scores VS-MAME coverage 99.81% — 25 pixels MAME draws that the engine drops, "dropped tiles, not draw order". A/B-proven pre-existing (identical with the pre-MOSHADE-162 RTL). Same family as D4; fixture regenerable from MAME in a minute. |
| H7 | Speech-tail adjudication | **OPEN.** The last unmeasured claim in the docs — measure vs MAME audio, then fix or retract with numbers. |

**Milestone 0.2 — MiSTer first, Pocket after (shared machine RTL):**

| # | Item | Note |
|---|---|---|
| H8 | Factory-map "halftone": travelled nodes must dim, not vanish | **DEVICE-CONFIRMED ON MiSTer (build 168, owner's first run) — Pocket 37/38 not yet tested.** Carried by Pocket 37/38 and MiSTer 162–169. On 168 the level-3 map matches the PCB capture frame 24402 / t406–410 — travelled routes and START box dim in the same hue, level-1 map all bright, the "you are here" node blinks every 10 frames, identical to the PCB capture, map timing matches. Remaining: T2 on Pocket 38 (G7). *Status as first written:* **FIXED IN RTL (MOSHADE-162, 2026-09-09) — device verification pending.** Root cause, from the romset GAL fuse maps + the PCB capture: GAL 136069.100V writes special (MPR2) pixels of pen 1 into the line buffer, so they shade the playfield (SHADE → colour-RAM +0x100, the I=4 bank the game populates); MAME `continue`s before SHADE and never dims (its level maps stay bright), and MAME's extra `pf |= 0x080` on M7 pointed shadows at the never-written 0x38X bank — the "erased to black". Both transcribed into our line buffer/comparator; both corrected, benches (tb_prio exhaustive, tb_mob shadow-twin, tb_stain) pass. Verify on device at a level ≥ 2 map against the PCB capture t406–t410: travelled nodes and START box dim same-hue (0x30X). Record: `investigations/MAP_HALFTONE.md`. |
| H9 | `eprom2` (Escape set 2) | **IMPLEMENTED (EPROM2-163, 2026-09-09) — boots and plays on MiSTer 168; formal T3 on MiSTer 169 and Pocket 38 pending.** Carried by Pocket 38 and MiSTer 163–169; on MiSTer 169 the set-2 MRA lives under `_alternatives/_Escape from the Planet of the Robot Monsters/` (ALT-172). The tenth main pair lands at image `0x0A0000`; `escape_core` remaps the video CPU's A19 window on all four ROM paths; `build_rom.py` auto-detects the set (and borrows shared chips from a sibling `eprom` folder); MiSTer gets its own `(set 2).mra`. MAME read taps (6000 frames): window read only in POST (f626–641), extra CPU never touches its hole. `tb_escape_core` boots set 2 (reset PC `$6A4`) and still boots set 1. Verify on both devices: POST passes (the checksum covers the new window), attract + a level of play, then the H8 map check on set 2 too. |
| H10 | Klax prototypes / Guts n' Glory (JSA-II variants) | **IN PROGRESS — romsets MAME-verified 2026-09-09; real programs boot in GHDL; MiSTer test builds 164–169, all unreleased; both Klax prototypes and Guts boot and play on MiSTer 168 (owner's first run); MiSTer 169 not yet device-tested.** Builds 164–167 latched the MRA game byte unreliably (clk_sys sampling a 28 ns clk_ram strobe; a bench control of the old latch missed 8 of 10), so they usually booted Klax/Guts as Escape — fixed in 168 (NVRAM-170). **Next:** MiSTer 169 device tests (G1: T4–T6, T8, T10) → MiSTer 0.2 release → Pocket 0.2 (Escape) → Pocket cores `spoonelli.klaxp` / `spoonelli.guts`. *Status as first written: "IN PROGRESS (2026-09-09) — no romsets on hand, bench-only"; the body below records the progress after that line was set.* Deltas measured from MAME in `investigations/KLAX_GUTS.md`. Done: `jt6295` vendored (GPL-3.0, NOTICE row), `escape_jsa` `BOARD=2` (OKI in the TMS slot, WRIO/MIX/RDIO remaps, second ROM client at image 0x240000), `tb_escape_jsa2` + `run_oki_tb.sh` pass, JSA-I bench unchanged. Romsets arrived 2026-09-09 (MAME-verified); `EXTRA_EN=0` + Klax inputs (KLAX-165), `build_rom.py` klaxp1/klaxp2/guts, Guts decoder map (GUTS-166), and the one-selector design (GAMESEL-167: `game_sel` runtime on MiSTer via the MRA index-1 byte, constant on the Pocket; OKI ADPCM through the SDRAM arbiter) are in; real Klax/Guts firmware and main programs boot in GHDL through both selector modes. MiSTer MRAs for both Klax sets and Guts exist. MiSTer 164 (Klax playable) handed to the owner for testing (unreleased) 2026-09-10; Guts video reading proven pixel-exact offline (KLAX_GUTS 4c) and transcribed (GUTS-168: MO format, forward order, comparator, tile slot; exhaustive + fixture benches pass, Escape paths bit-identical). MiSTer 166 added per-game button mapping, 167 GUTS-169 (H12). *(Superseded "next" as first written: MiSTer 165 device test of Guts and Klax, then Pocket packages `spoonelli.klaxp` / `spoonelli.guts` — the order is now MiSTer 0.2 first, see above.)* |
| H11 | ThunderJaws feasibility | **FUTURE WORK (owner decision).** 2026-09-10: "out of our dev reach for now - we don't want to poison the integrity of our project"; confirmed 2026-10-17: "keep thunderjaws as future work". The Atari VAD video chip has no public FPGA implementation, so there is no second reference beside MAME. Not shelved: the research stays in `investigations/THUNDERJAWS.md`, the `thunderj` romset is MAME-verified (2026-09-09) but unused, and the recommended first step (MAME trace + offline pixel model, no RTL) still stands. *As first written:* **RESEARCHED (2026-09-09)** — `investigations/THUNDERJAWS.md`: same CPU pair / shared-RAM interlock / JSA-II skeleton, but the Atari VAD video (two playfields, new priority PAL, IRGB1555 palette, banked 64 KB alpha ROM, programmable scanline IRQ) makes it a **separate core built from this repo's blocks**, not a variant. If pursued: MAME trace + offline pixel model first, no RTL. Owner decision pending. |
| H12 | GUTS-169 + MRA rbf name (MiSTer 167) | **DONE in RTL (2026-10-09) — device verification under G1 (T5).** Guts mode now holds back every special (MPR2) sprite pixel, pen 1 included, as MAME's Guts rule does; GUTS-168 had left Escape's GAL 100V pen-1 exception live in Guts mode. Latent: none of the twelve sampled Guts frames has a pen-1 special; a control fixture (`sim/tools/make_guts_pen1_special.py`) drew 64 stray pixels before the gate, 0 after. Same build: every MRA says `<rbf>Escape</rbf>` (the maintainer's spelling) and CI names the rbf `Escape_YYYYMMDD.rbf`. |
| H13 | NVRAM-170 + jt6295 notice (MiSTer 168) | **DONE — boot/play device-confirmed on 168; persistence is T8.** MiSTer EEPROM persistence (`src/mister/rtl/escape_hps_bridge.v`; one `.nvm` per MRA). While building it: the MRA game byte was latched on clk_sys from a 28 ns clk_ram strobe, so 164–167 usually booted Klax/Guts as Escape (bench control: the old latch missed 8 of 10; the new one catches all). NOTICE / README now list jt6295 as compiled into the MiSTer rbf. |
| H14 | NVRAM-171 + ALT-172 (MiSTer 169) | **DONE in packaging — device tests T8 / T10 pending.** NVRAM-171 adopts the Arcade-Cave saving convention: root-menu "Autosave NVRAM" default Off, plus "Save NVRAM". Before it, "Saving..." appeared on nearly every menu change, because Escape rewrites a 4-byte counter every 10–20 s and Main polls the save request on every menu redraw. ALT-172 moves the clone MRAs to `_alternatives/_Escape from the Planet of the Robot Monsters/` and `_alternatives/_Klax/`; the CI ROM-data gate now scans every MRA recursively. |
| H15 | Report the two MAME inaccuracies upstream | **OPEN.** `eprom.cpp`'s early `continue` on MPR2 (no dim) and its `pf \|= 0x080` on M7, with the GAL 100V/100T equations (`investigations/MAP_HALFTONE.md` §6). Now that H8 is device-confirmed, the report can cite a device result. |

**Slow-burn (no version attached):**

- **MiSTer vertical-sync edge alignment** — VS edges aligned to the
  horizontal-sync leading edge (`VSYNC_HSTART = HSYNC_START`, the MegaDrive
  VDP idiom) instead of `x=0`. Cosmetic on the wire, since composite sync
  merges the pulses and the TV locks to the HS edge anyway; logged 2026-09-02
  after the MISTER-161 sync calibration.
- **Authentic composite-sync record** — the board's real H/V sync positions,
  widths, vertical-sync line count and serration are unrecorded (MAME models
  none of it; ours were chosen, then TV-calibrated). Path 1, no hardware:
  decode the six GAL16V8 fuse dumps in the romset
  (`136069.50f/50p/55p/70j/100t/100v`) with MAME `jedutil` — if one is the
  sync/blank generator the positions fall out in counter terms. Path 2: USB
  scope on the csync line (period, pulse width, porches to first active pixel
  via the service-mode grid, VS lines, serration). Adopt widths / VS
  structure / edge alignment on both platforms if they differ; keep the
  display-centred default position (arcade monitors were pot-centred, so
  absolute position was never user-visible).
- Section-F `DIAG_EN` decision.
- C5 clean-machine ROM-prep walkthrough.
- Optional GitHub Support ticket for the pre-rewrite `refs/pull/*` snapshots.
- **Save-states evaluation** (future evaluation item; MiSTer `SS<base>:<size>`
  DDR window + framework hooks; the open question is CPU state capture — the
  imported T65/TG68K/jt51 expose no internal state, so the fork is in-house
  CPU rewrites vs a sequencer-walk snapshot; the MISTER-155 pause already
  provides the coherent-freeze half, and any answer must serve both platforms
  or be MiSTer-only by design).

*(The HISTORY.md builds-103+ chronology item that stood here is done — D1.)*
