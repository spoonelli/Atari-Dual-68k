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
| A1 | Core identity `spoonelli.ataridual68k` -> `spoonelli.eprom` | TODO | Must land **before** any public release. Verify saves still resolve (`/Saves/eprom/common/`) on a real device afterwards. |
| A2 | **Third-party attribution / GPL-3.0 compliance** | TODO | The most-missed item. We vendor TG68K (Tobias Gubener), jt51 (Jose Tejada), T65, TMS5220, and the Atari System 1 MiSTer RTL. A public GPL release needs a CREDITS/NOTICE naming each upstream, its licence, and preserved file headers. |
| A3 | Single combined history rewrite (marquee blob + `output/` dirs) | BLOCKED | Rewritten mirror is prepared and verified; force-push needs approval. Pre-purge backup: `Documents/Lloyd Projects/atari-dual68k-prepurge-backup.bundle`. |
| A4 | `input.json` vs RTL audit — **all** buttons, **both** players | TODO | The P2 bomb was a declared-vs-actual mismatch. Do not assume it was the only one; check the whole table rather than the one entry we already found. |
| A5 | Debug HUD gated behind a menu toggle, default off | **DONE (build 114)** | `interact.json` id 38 'Developer HUD', default unchecked. With it clear, `diag_on` is forced low, so L1/R1/R/L2 do nothing and no debug path reaches video. RTL still compiled in -- see **section F**; the `DIAG_EN` compile-time half remains open. |
| A6 | Save-path device test on real hardware | TODO | Gates the alpha/RC tag. |
| A7 | Clean-boot look on real hardware | TODO | Gates the alpha/RC tag. |
| A8 | **Tile-shaped holes in motion objects** | TODO | **The one consistent blocker to alpha.** Sprites drawn correctly but with a rectangular chunk missing. Field evidence, ruled-out causes and the diagnostic plan: [`MO_TILE_HOLES.md`](MO_TILE_HOLES.md). Frame 5629 vs 5636 (same sprite, wrong then right) is the key pair. |

## B. Identity, metadata, and store presence

| # | Item | State | Note |
|---|---|---|---|
| B1 | Pocket game label -> "Escape from the Planet of the Robot Monsters" | TODO | **Two separate fields**: core name in `core.json`, platform name in `Platforms/eprom.json`. 44 characters will likely truncate on device — check the display limit and plan a short form plus full name. |
| B2 | Version scheme | **DONE** | Scheme fixed (2026-08-28, owner call): `core.json` version and the git tag move in lockstep — `v0.1.0` = first public RC, `0.x.y` during field-testing, `1.0.0` only when every section-A blocker is closed; patch bumps for fixes, minor bumps for features (eprom2). `BUILD_ID` stays the internal on-HUD build counter, and RELEASE_NOTES records the mapping (v0.1.0 = build 133) so a HUD photo identifies a release exactly. MiSTer versions independently (`mister-v0.x.y`). `core.json` set to 0.1.0. |
| B3 | pupdate / openFPGA inventory listing | TODO | Community inventory is `joshcampbell191/openfpga-cores-inventory`. Needs a **public** repo, Releases, consistent zip naming, correct `core.json` platform metadata. Research exact submission format. |
| B4 | Public vs private decision | TODO | Going private would instantly cut public access to the marquee blob (0 forks, so airtight) **but B3 requires public**. The purge resolves this: once the blob is gone, public is fine and no GitHub Support ticket is needed. |
| B5 | `video.json` out-of-box look (aspect, scaler) | TODO | Most players never open settings. |
| B6 | `interact.json` defaults sane for a first-time user | TODO | 11 entries today; HUD off, ROM Shadow on. |

## C. Repo hygiene — "looks like a commercial release"

| # | Item | State | Note |
|---|---|---|---|
| C1 | Strip committed `output/` build dirs from history | TODO | Fold into A3. |
| C2 | Branch pruning | TODO | 29 remote heads, including `*-EXPERIMENTAL`, `spike/fx68k-EXPLORATORY-do-not-ship`, several `hold-*` probes, and a stray branch literally named `origin`. |
| C3 | Decide what `main` means | TODO | `main` is stale (`3ee6859`). Release branch? |
| C4 | README + support doc cleanup | TODO | `docs/README.md` already splits reference from investigation record — extend that discipline to the top-level README. |
| C5 | ROM prep end-to-end from a clean machine | TODO | `docs/ROMS.md` + `build_rom.py` with no local state. |
| C6 | MiSTer fork: same release or separate? | TODO | Affects wording everywhere. |

## D. Documentation and the historical record

The record is substantial — 26 docs, ~9,400 lines, with `docs/README.md`
separating reference from investigation. Three real gaps:

| # | Item | State | Note |
|---|---|---|---|
| D1 | **`HISTORY.md` stops at build 102** | TODO | Titled "v1–v78"; covers v1–v78 plus builds 101–102. **Builds 103–113 are absent** — the SDRAM arc, VSHAD3, the stain fix, TAS atomicity, EEPROM, the MiSTer port, bus hardening. `RETROSPECTIVE.md` covers that ground but **thematically, not chronologically**: it answers "what did we learn about sprites", not "what happened in build 107". |
| D2 | **`HISTORY.md` has two headings numbered "Era 6"** | TODO | Lines 89 and 116. Appended without reconciling — exactly the drift `docs/README.md` warns about, in the doc that is supposed to be the spine. |
| D3 | **Nothing separates community-reusable knowledge** | TODO | See below. |
| D4 | `RELEASE_NOTES.md` known-issues honesty | TODO | D6 left-edge strip, MO dropout status, EEPROM autosave behaviour, and which SDRAM lever shipped. |

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

Today: `L1` edge-toggles `diag_on` (starts hidden), `R1` cycles 6 pages. There is
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
