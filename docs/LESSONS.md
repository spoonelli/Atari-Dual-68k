# Lessons learned — bringing up a dual-68000 arcade board on the Pocket

A distillation of what ~150 builds taught. Kept because the *methods* are the
reusable asset; the specific bugs are all in the git history.

## The project was never the chips — it was the memory fabric

The 68000s, 6502, YM2151 and TMS5220 were donor cores that mostly worked on
day one. Roughly three-quarters of all builds went into the invented part:
funneling a board that had a dozen independent zero-wait memories (dedicated
EPROMs per CPU, private VRAMs, sprite line buffers on their own bus) through
one SDRAM, one PSRAM and a BRAM budget. **MAME cannot model this** (software
arrays are perfect and time-free) and **the schematic doesn't help** (they
solved it with real chips). If you attempt a similar core: design and verify
the memory/arbitration system first, with a data-integrity checker attached
from build 1. *Memory speed is part of the machine* — the game's frame
architecture assumes ~4-cycle fetches, and starving it changes behavior in
ways that look like logic bugs.

## Instruments before features

Progress velocity tracked instrument quality, not effort. The winners, all
still aboard:

- **On-screen forensics HUD** (build number + paged probes) — every device
  failure became a photograph instead of a description.
- **First-fault latches** that survive resets (crash PC + received opcode +
  vector + watchdog count) — one photo names a wedge.
- **Continuous checksums** of suspect memory regions vs offline-computed truth
  — separates "written wrong" from "read wrong" from "content fine" at a
  glance.
- **Scene replay benches**: dump real machine state (MO RAM, scroll, config)
  from MAME mid-scene, replay it through the actual RTL offline, render the
  output. Sprite questions answered in minutes without a flash cycle.
- **MAME as a *bus-level* instrument**, not just a reference: Lua write-taps
  and PC-sampling profilers produced ground truth that reading driver source
  never could. Three project-defining discoveries came from traces, not code
  reading: the speech firmware's real per-byte WS strobing, the exact
  one-byte width of the CPU-run latch, and the gameplay hot-code map.

## Check authenticity before debugging

This game is weird by design. Attract-mode screen dimming, soft-reboot
attract cycling, wave-transition CPU restarts, and a repeating "artifact"
sound (the robot-swarm effect) all looked like core bugs and were authentic.
The cheapest debugging step is a MAME (or real-board) comparison of the
symptom — several hunts ended in one observation.

## Misdiagnoses compound; retract loudly

The costliest stretches were fixes built on wrong conclusions (an auto-strobe
added because a sim seemed to show the firmware never strobed; two more
builds then fixed the artifacts of that fix). When new evidence contradicts a
prior conclusion, retract it explicitly in the log — half-believed old
theories poison later reasoning.

## Traps that cost real time (all now structurally fixed)

- **Silently-missing sim fixtures**: `$readmemh` failure is not an error in
  iverilog; a cleanup script wiping fixture files produced hours of phantom
  results. Fixtures now live outside any cleaned directory.
- **Submodule edits don't ship**: patching a file inside a submodule does
  nothing to CI, which checks out pristine upstream. Vendor the file (with
  provenance) instead.
- **Verilog sized-literal comparisons**: `slot < 4'd16` truncates 16 to 0 —
  constant false. Lint would have caught it; add lint to CI earlier than we
  did.
- **FSM state-number collisions** when inserting states into a `localparam`
  list poisoned four builds of experimental data before being noticed.
- **68000 bus facts**: vector fetches are indistinguishable from supervisor
  data reads of low memory (boot checksums read that region constantly), and
  an instruction-accurate soft-core's captured "fetch data" may belong to a
  different address than the captured PC (prefetch). Address-range snooping
  cannot detect exceptions; only sequence-aware or CPU-internal signals can.
- **Donor IP is only proven for the data it has seen**: the TMS5220 model's
  13-bit lattice accumulators were fine for quiet System 1 speech and
  overflowed on this game's loud announcer. Validate donor cores against
  reference vectors for *your* workload.

- **At the M10K ceiling, every new array is a fit failure until proven
  otherwise.** The Pocket's Cyclone V gives 308 M10K blocks and this design
  uses all of them, so any inferred block RAM -- however small -- fails the
  fit with Error 170048. Builds 72/72b/72c died this way on a 4 KB shadow;
  BUILD 103 died the same way on two 4 Kbit staging buffers. The fix is
  usually not to shrink the array but to move it to a different resource
  class: `attribute ramstyle ... is "MLAB"` puts it in ALM-based LUTRAM,
  which this design has in abundance. Cost was 1.9 ns of slack, not silicon.
  Add the attribute when you declare the array, not after CI rejects it.
- **MLAB power-up contents are not guaranteed** (Warning 170052), so check
  whether anything depends on an array's initial value before relocating it.
  In `ee_save` nothing did -- the restore path is gated on a *flip-flop*
  (`dl_seen_b`) set when APF actually delivers a save file, and the "virgin
  FF" fill that makes the game write factory defaults lives in the EEPROM
  block itself, not in the staging buffer. Had the gate been "does the buffer
  read as all-FF", MLAB would have silently corrupted first-boot settings.

## Process rules that earned their keep

- Every build bumps an on-screen build number; the screen must match the zip.
- One variable per experiment; branch-only for anything touching the memory
  path; never ship negative timing slack.
- Measurement first: prove it in sim or a MAME trace before spending a flash
  cycle. Flash cycles are the scarcest resource in phone-photo debugging.
- ROMs and copyrighted artwork never enter the repo or the package — the
  packager enforces the ROM half mechanically.
