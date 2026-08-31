# MiSTer (DE10-Nano) port — reference

Current as of **`mister-v0.1.1`** (2026-08-30, MISTER BUILD 153,
`Arcade-Escape_20260830.rbf`). The build-by-build engineering history —
including the arbiter saga and its wrong turns — is preserved separately in
[`investigations/MISTER_PORT_RECORD.md`](investigations/MISTER_PORT_RECORD.md);
where that record disagrees with this page, this page wins.

## Status

Plays on real hardware at **measured performance parity with the Analogue
Pocket release**: identical crowd-scene scroll-velocity distributions
(median 5.33 native px per 1/30 s), zero sub-half-speed dips where MAME's
model dips in 19–28% of samples. Known imperfect: rare one-frame sprite-row
flickers on the very heaviest scanlines (quantified; the fetch-cost work is
[checklist section H](RELEASE_CHECKLIST.md)). The machine RTL is shared
verbatim with the Pocket build.

## Where to get it

- **Distribution repo (standard MiSTer layout, submitted to MiSTer-devel):**
  [`spoonelli/Arcade-Escape_MiSTer`](https://github.com/spoonelli/Arcade-Escape_MiSTer)
  — rbf + MRA in `releases/`.
- **update_all**: one `downloader.ini` stanza, in
  [`DISTRIBUTION.md`](DISTRIBUTION.md) and the distribution repo's README.
- **Release zips**: `mister-v*` pre-release tags on this repository.

Install, controls (defaults Jump=Y/left, Fire=B/bottom, Duck=A/right,
Bomb=X/top; the define-flow traps), OSD options, and the authentic
"Waiting for Second Processor" boot hold are documented in the distribution
repo's README, which also ships inside the release zip.

## Platform architecture — how this port differs from the Pocket

The bus topology genuinely differs (the Pocket gives the playfield its own
PSRAM; MiSTer has one SDRAM for everything), and every difference below is
measured and bench-gated. The full cross-platform rules live in
[`DEVIATIONS.md`](DEVIATIONS.md) §F.

- **SDRAM controller**: `sdram_openrow` at 35.795455 MHz (5× pixel clock,
  phase-locked; conservative default timings; refresh policy 160/48 as
  reconciled in DEVIATIONS §F1). The 5:1 phase relationship makes hold on
  the fetch-return CDC a placement lottery — see [`TIMING.md`](TIMING.md).
- **Arbiter**: playfield outranks the CPUs (its per-scanline deadline is the
  hardest on this bus); motion objects and the CPUs' speculative fastpath
  interleave one-for-one on contested cycles via a turn bit, with a
  demand-fetch escape. The design constraint that killed three prior
  arbiters: `escape_core` gives a blocked fastpath only ~16 CPU clocks
  before ROM fetches degrade to timeout-plus-fallback, so no policy may
  block the fastpath for long.
- **MO tile mirror**: the 1 MB sprite-tile region is written twice during
  ROM download; motion objects fetch a bank-2 copy while the playfield keeps
  bank 3, so neither evicts the other's open rows — the Pocket's
  separate-memory advantage rebuilt from bank partitioning. Measured: MO
  worst-case fetch latency −91%, every bus client improved simultaneously.
- **CDC settle**: fetch-return done-toggles carry a two-edge settle delay
  (the Pocket's SDSCHED-74 arrangement, ported after its absence produced
  bit-soup garble).
- **Credits overlay**: core-drawn (the framework's `P1-,text;` pages render
  empty on some builds), cycled by the OSD "Show Credits" trigger, the
  mappable Credits button, or keyboard C; the build number is on page 1.

## Benches (run before any bus/arbiter change)

- `sim/run_mister_pf_tb.sh` — playfield fetch service, power-on probes,
  second-download survival.
- `sim/run_mister_moarb_tb.sh` — crowd-load MO service vs fastpath
  pressure. Gates calibrated against hardware verdicts: dense-line fill
  (≥40 tiles/line), per-lane fastpath timeout-share (<10%; the working
  arbiter measures 4%, the reboot-looping one 27%), a demand-standoff
  probe, and playfield-service invariance.

## Release history

| Tag | Build | Notes |
|---|---|---|
| [`mister-v0.1.1`](https://github.com/spoonelli/Atari-Dual-68k/releases/tag/mister-v0.1.1) | 153 | The parity release: open-row controller, interleave arbiter, tile mirror + download-race fix, owner button defaults, credits accuracy pass. First update_all delivery. |
| [`mister-v0.1.0`](https://github.com/spoonelli/Atari-Dual-68k/releases/tag/mister-v0.1.0) | 142 | First tagged release: boot splash retired, dated rbf naming. |
