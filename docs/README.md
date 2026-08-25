# Documentation index

This folder holds two very different kinds of document, and mixing them up is
how stale claims survive. They are separated below.

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
| [`POCKET_TEST.md`](POCKET_TEST.md) | Installing and running on the Pocket; the diagnostic HUD and its 6 pages. |
| [`ROMS.md`](ROMS.md) | Building your own ROM image. No ROM data is distributed. |
| [`CONTROLS.md`](CONTROLS.md) | Player controls, the hall-effect stick model, and the debug controls. |
| [`EEPROM_SAVE.md`](EEPROM_SAVE.md) | How high scores persist, and what to do if they do not. |

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
| [`SCHEMATIC_FINDINGS.md`](SCHEMATIC_FINDINGS.md) | Points where the schematic corrected MAME. |
| [`PIPELINES.md`](PIPELINES.md) | Pipeline-by-pipeline walkthrough. Mostly reference; §4.1 carries a retraction notice. |

---

## Investigation record — historical

Kept for provenance. **Not maintained.** Where one of these disagrees with a
reference doc above, the reference doc wins.

| Doc | What it is |
|---|---|
| [`RETROSPECTIVE.md`](RETROSPECTIVE.md) | The long look back, including a table of claims found false. |
| [`LESSONS.md`](LESSONS.md) | What 150+ builds taught. |
| [`HISTORY.md`](HISTORY.md) | Build-by-build history. |
| [`VSHAD3.md`](VSHAD3.md) | The ROM-shadow measurements. Its title still asks why the shadow "is not flipped yet" — it since shipped; §8.3 is the current part. |
| [`PERF_CADENCE.md`](PERF_CADENCE.md) | Where the cadence reference figures come from. |
| [`GFX_DASH_ARTIFACT.md`](GFX_DASH_ARTIFACT.md) | The horizontal-dash artifact investigation. |
| [`BAKEOFF.md`](BAKEOFF.md) | Configuration comparisons. |
| [`NIGHT-ANALYSIS.md`](NIGHT-ANALYSIS.md) | A long unattended measurement run. |
| [`mo_priority.md`](mo_priority.md), [`mo_placement.md`](mo_placement.md) | Motion-object priority and placement work. |
| [`evidence/`](evidence/) | Captures and crops backing the above. |

---

## A note on trusting these

Several claims in this repo have been found false *by this repo* and then
survived in docs anyway, because nobody propagated the correction back. The
CPU-type question alone has inverted four times. When you find a claim that
matters, check it against the code or the measurement rather than against
another document — and when you correct one, grep for its other copies.
