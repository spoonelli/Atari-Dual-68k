# Documentation index

This folder holds two very different kinds of document, and mixing them up is
how stale claims survive. They are separated below —
reference lives at this level, investigation records in
[`investigations/`](investigations/).

- **Reference** describes the core *as it is now*. If a reference doc and the
  code disagree, that is a bug in the doc.
- **Investigation record** is how we got here — measurements, dead ends,
  refuted hypotheses. These are kept deliberately, including the wrong turns,
  because the wrong turns are most of the value. **They are not maintained as
  current**, and several contain conclusions that were later superseded.

If you only read one file: [`RELEASE_NOTES.md`](RELEASE_NOTES.md).

---

## Reference — current

### Using it

| Doc | What it covers |
|---|---|
| [`RELEASE_NOTES.md`](RELEASE_NOTES.md) | **Start here.** What works, what is known-imperfect, what is not implemented. |
| [`POCKET_TEST.md`](POCKET_TEST.md) | Installing and running on the Pocket; the diagnostic HUD and its 7 pages. |
| [`ROMS.md`](ROMS.md) | Building your own ROM image. No ROM data is distributed. |
| [`CONTROLS.md`](CONTROLS.md) | Player controls, the hall-effect stick model, and the debug controls. |
| [`EEPROM_SAVE.md`](EEPROM_SAVE.md) | How high scores persist, and what to do if they do not. |
| [`DISTRIBUTION.md`](DISTRIBUTION.md) | Auto-update support: the Pocket cores inventory and the MiSTer custom database. |

### How it is built

| Doc | What it covers |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Hardware map and component inventory. |
| [`DEVIATIONS.md`](DEVIATIONS.md) | **Where this core is not the board**, measured. §D is the open-gap list. |
| [`ROMMAP.md`](ROMMAP.md) | Memory and ROM layout. |
| [`CPU_AND_ARBITER.md`](CPU_AND_ARBITER.md) | CPU type, and the shared-RAM arbitration / TAS interlock. |
| [`JSA.md`](JSA.md) | The JSA-I audio subsystem. |
| [`TIMING.md`](TIMING.md) | Timing closure, and the structural hold-margin floor. |
| [`SLAPSTIC.md`](SLAPSTIC.md) | Why the security chip is deliberately absent. |
| [`MISTER.md`](MISTER.md) | The MiSTer (DE10-Nano) port: current status, architecture, distribution, benches. |
| [`PIPELINES.md`](PIPELINES.md) | Pipeline-by-pipeline walkthrough. Mostly reference; §4.1 carries a retraction notice. |

---

## Investigation record — historical

Kept for provenance. **Not maintained.** Where one of these disagrees with a
reference doc above, the reference doc wins.

| Doc | What it is |
|---|---|
| [`RETROSPECTIVE.md`](investigations/RETROSPECTIVE.md) | The long look back, including a table of claims found false. |
| [`LESSONS.md`](investigations/LESSONS.md) | What 150+ builds taught. |
| [`HISTORY.md`](investigations/HISTORY.md) | Build-by-build history. |
| [`VSHAD3.md`](investigations/VSHAD3.md) | The ROM-shadow measurements. Its title still asks why the shadow "is not flipped yet" — it since shipped; §8.3 is the current part. |
| [`PERF_CADENCE.md`](investigations/PERF_CADENCE.md) | Where the cadence reference figures come from. |
| [`GFX_DASH_ARTIFACT.md`](investigations/GFX_DASH_ARTIFACT.md) | The horizontal-dash artifact investigation. |
| [`BAKEOFF.md`](investigations/BAKEOFF.md) | Configuration comparisons. |
| [`NIGHT-ANALYSIS.md`](investigations/NIGHT-ANALYSIS.md) | A long unattended measurement run. |
| [`mo_priority.md`](investigations/mo_priority.md), [`mo_placement.md`](investigations/mo_placement.md) | Motion-object priority and placement work. |
| [`MO_TILE_HOLES.md`](investigations/MO_TILE_HOLES.md) | The sprite tile-hole hunt — closed by MOPAIR (build 131). |
| [`SDRAM_ARCH.md`](investigations/SDRAM_ARCH.md) | The SDRAM architecture analysis behind the open-row/6x work. |
| [`BUILDS_FOR_REVIEW.md`](investigations/BUILDS_FOR_REVIEW.md) | The build-128→132 decision ladder and its telemetry guide. |
| [`CAPTURE_SWEEP_0826.md`](investigations/CAPTURE_SWEEP_0826.md) | Automated artifact sweep of the build-124→128 re-test captures. |
| [`MISTER_PORT_RECORD.md`](investigations/MISTER_PORT_RECORD.md) | The MiSTer port's build-by-build record, wrong turns included — the arbiter saga lives here. |
| evidence captures | The video captures and crops backing the above are kept off-repo (large, and some contain copyrighted game art). Each investigation names the capture it used. |

---

## How to read these

The **reference docs** above were swept against the code and the current
measurements for v0.1.0; if one still disagrees with the code, the doc is
wrong — please file it. The **investigation records** are deliberately left
as written, wrong turns included, and several of their conclusions were later
superseded; each is a snapshot of what was believed at the time, not a claim
about the core today. When a claim matters, check it against the code or the
measurement it cites — and if you correct one, grep for its other copies.
