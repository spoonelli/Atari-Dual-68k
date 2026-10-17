# Simulation (native GHDL, no Quartus)

We verify RTL logic with **GHDL**, which is light enough to run in Docker under
emulation on Apple Silicon (unlike Quartus). This lets the whole design-and-verify
phase proceed on a Mac with no FPGA toolchain and no GitHub runner — Quartus is only
needed at the very end to produce the physical bitstream.

## Prerequisites
- Docker Desktop running. Two images are pulled on first use:
  `ghdl/ghdl:ubuntu20-mcode` (VHDL benches) and `hdlc/iverilog` (Verilog benches;
  most runners take `IVERILOG_IMAGE` to override the default `hdlc/iverilog:latest`).
- `python3` on the host. Most runners generate their fixtures or score their output
  with a script in `sim/tools/` before or after the container runs.

## Fixtures from your own romset

No ROM data is committed, and every hex under `sim/work/` is gitignored. Benches that
boot the real program need the combined image as a word-per-line hex:

```bash
python3 support/build_rom.py /path/to/eprom.zip sim/work/atari_escape.rom
python3 sim/tools/rom_to_hex.py            # -> sim/work/combined_words.hex
```

`build_rom.py` also accepts `eprom2`, `klaxp1`/`klaxp2` and `guts`; a bench that
runs another game (e.g. `tb_escape_jshad` with `G_GAME=1`) needs that game's image
converted to the same `sim/work/combined_words.hex` path. Scene fixtures for the
MO benches come from a MAME dump (`make_scene_hex.py` for Escape,
`mame_scene_dump.lua` + `make_guts_scene_hex.py` for either map).

## What's here
- `ghdl.sh` — thin wrapper: runs GHDL in the container with the repo mounted at `/work`.
- `lib/dpram_sim.vhd` — behavioral dual-port RAM, drop-in for the Altera megafunction
  (`third_party/.../rtl/lib/mem/dpram.vhd`) so the base RTL elaborates without Quartus IP.
- `analyze_base.sh` — imports the Atari System 1 base RTL and reports which modules
  elaborate under GHDL (our adaptation baseline).
- `run_tb.sh [tb] [stoptime]` — elaborate + run a GHDL testbench from `tb/` (default
  `tb_syngen`, 500us); `GARGS='-gNAME=value ...'` overrides bench generics.
- `run_*.sh` — the dedicated runners; see the bench index below.
- `tb/` — testbenches. `tools/` — fixture generators, golden models and scorers.

## Bench index

Every `sim/run_*.sh` on this branch (`milestone-0.2`), the three MiSTer-only runners
that exist only on `milestone-0.2-mister`, and the milestone 0.2 benches that run
through `run_tb.sh`. **G** = in `run_all_gates.sh`; **i** = iverilog, **g** = GHDL.

| Runner | Sim | Checks | Notes |
|---|---|---|---|
| `run_all_gates.sh` | — | runs the gate set, one PASS/FAIL line per gate, no short-circuit | Convenience runner. Its 13 gates are marked **G** below; it runs **none** of the 0.2 benches |
| `run_tb.sh <tb>` | g | any VHDL bench in `tb/` | Builds the `tb_escape_adc` stub image itself; other benches need their fixture first |
| `run_sdram_model_tb.sh` | i | the SDRAM model + JEDEC checker: one clean run, five injected defects that must be caught | **G** (with `SDRAM_DUT=openrow`) |
| `run_sdram_refresh_tb.sh` | i | worst-case refresh interval of every shipped/proposed policy vs 7.8125 µs; two negative controls must FAIL | **G** (openrow and simple). See `docs/DEVIATIONS.md` F1 |
| `run_sdram_traffic_tb.sh` | i | row-hit rate, miss split, per-client latency and MO demand for the arbiter's real access sequence, with control cells | Measurement, not a gate |
| `run_psram_tb.sh` | i | CRAM/PSRAM timing: shipping config must pass, the BUILD 106 mis-declared clock must fail | **G** |
| `run_prio_tb.sh` | i | `escape_prio.v` exhaustively against `mo_priority_model.py` (MOSHADE-162 form, 507,904 rows); also a Guts-mode sweep against MAME's `screen_update_guts` rule (GUTS-168) | **G**. Fails unless both the Escape sweep and the `GUTS PRIO CHECK` pass |
| `run_mob_tb.sh` | i | MO engine + comparator on a MAME scene dump, scored against MAME's frame | **G**. Scroll via env vars (`XSCROLL=… YSCROLL=…`); `MOB_PARAMS='-Ptb_mob.GUTS=1 …'` for a Guts scene. Fixtures: `make_scene_hex.py`, `make_guts_scene_hex.py`; `make_shadow_twin_scene.py` (MOSHADE-162 pen-1 special) and `make_guts_pen1_special.py` (GUTS-169 control) rewrite an existing fixture |
| `run_mob_order_check.sh` | i | the park queue did not change per-line sprite load order (prefix check against a base ref) | **G**. Needs `BASE_REF` |
| `run_mob_perf.sh` | i | MO throughput against `mob_golden.py` at a given fetch latency | |
| `run_mob_perf_sweep.sh` | i | the same over latency × scene, base engine vs current | |
| `run_mob_cov.sh` | i | coverage sweep, scene × latency, base vs working tree, in parallel | |
| `run_stain_tb.sh` | i | the shipped `escape_stain.v` on a scene that contains stain markers | **G** |
| `run_pf_tb.sh` | i | CRAM playfield path against a golden frame; `PF_SINGLE_CH=1` must fail | **G** |
| `run_pf_reset_tb.sh` | i | playfield fetch channel across a core reset, fix present vs excised | **G**. Slices `core_top.v` live — see below |
| `run_pfline_tb.sh` | i | first pixels of each line are this frame's data, swept over XSCROLL | |
| `run_cadence_tb.sh` | g | the logic-frame cadence meter, with negative controls | **G** |
| `run_vshad3_tb.sh` | g | the three vshad3 decodes agree and the runtime toggle works | **G** |
| `run_busrate.sh` | g | main-CPU ROM bus-cycle cost, shadow vs fastpath (`BASE`, `VS3`, `VS3ON`) | Measurement |
| `run_tasrace.sh` | g | TASLOCK-102 matrix: freeze reproduced, DTACK-only trap, fix verified, never-wedge | **G** |
| `run_vecrace.sh` | g | interrupt-dispatch corruption hunt (`tb_escape_vecrace`) | Long; env knobs in the header |
| `run_vecrace_sweep.sh` | g | parallel phase-sweep slices of the above | Logs in `sim/work/logs/` |
| `run_worldwake.sh` | g | dual-CPU runtime IRQ contract (`EIRQ_MODE`, `CPU_TYPE` A/B in `docs/CPU_AND_ARBITER.md` §1.6.2) | |
| `run_oki_tb.sh` | i | jt6295 smoke test on a synthetic phrase table (JSA2-164); expects `JT6295 SMOKE OK` | 0.2. Needs the `third_party/jt6295` submodule |
| `run_tb.sh tb_escape_jsa2 300us` | g | JSA-II decode, WRIO→OKI, status read, both ROM clients | 0.2. Run `python3 sim/tools/make_jsa2_hex.py` first (no game data) |
| `run_tb.sh tb_escape_vmap 1us` | g | `escape_decode` in both video maps, every block boundary (GUTS-166) | 0.2. The Escape-only map has `tb_escape_decode` |
| `run_tb.sh tb_escape_core` | g | both CPUs boot the real program | Generics `G_EXTRA`, `G_JSA`, `G_VMAP`, `G_GAME`, `G_JSART` select the 0.2 configurations via `GARGS`. Needs `combined_words.hex` |
| `run_tb.sh tb_escape_jshad 30ms` | g | 6502 boot through the jshad serve FSM; with `G_GAME`/`G_JSART`, OKI requests present for JSA-II and absent for JSA-I | 0.2 generics; see the note at the end |
| `run_hps_bridge_tb.sh` | i | `escape_hps_bridge.v`: game-byte latch and EEPROM load/save across clk_ram→clk_sys (NVRAM-170); expects `HPS BRIDGE PASS` | **MiSTer only** — exists only on `milestone-0.2-mister`, where it is a CI gate |
| `run_mister_pf_tb.sh` | i | playfield fetches served by the MiSTer arbiter through download, reset release and one frame | **MiSTer only** — exists only on `milestone-0.2-mister`; CI gate. See below |
| `run_mister_moarb_tb.sh` | i | MO vs fastpath arbitration on MiSTer, gated against hardware verdicts (MOARB-146/147) | **MiSTer only** — exists only on `milestone-0.2-mister` |

Coverage gaps worth knowing: no bench exercises EPROM2-163's `v_img` remap (set 2's
self-test on hardware is the check), and MOSHADE-162 is covered only through the
priority model in `run_prio_tb.sh` and the `make_shadow_twin_scene.py` fixture for
`run_mob_tb.sh` — neither is in a 0.2-specific gate.

### MiSTer playfield bench (`run_mister_pf_tb.sh`)

Drives the real `src/mister/rtl/escape_mister.v` through power-on → ROM download
with the core held in reset → release → one measured frame, and counts the
playfield fetches the SDRAM arbiter serves. This is the PFRESET-107 regression:
BUILD 105 served **zero** and rendered a flat playfield on real hardware. Only the
VHDL machine is stubbed: `sim/tb/stub_escape_core.v` is tracked, but it is a
generated file — `support/mk_core_stub.py` regenerates it from `escape_core.vhd`'s
entity on every run so it cannot drift (commit the regenerated file when the entity
changes). `sim/tb/sdram_model_mem.v` is a behavioural MT48LC16M16A2 with storage;
the bench validates its own read latency by requiring the core's power-on readback
probes to pass. `run_mister_moarb_tb.sh` uses the same model.

## GHDL flags
`--std=08 -fsynopsys -frelaxed` — the base RTL uses `std_logic_unsigned`/`std_logic_arith`
(Synopsys) and non-protected shared variables.

## Baseline status (Atari System 1 RTL under GHDL)
16/18 top modules elaborate cleanly, including the full video chain (`SYNGEN`→`VIDEO`),
motion objects (`MOHLB_*`), playfield (`PFHS`), palette (`CRAMS`/`RGBI`), sound
(`AUDIO`/`POKEY`/`TMS5220`), `SLAPSTIC`, and the top `MAIN`. The two that don't match
by guessed name are the MiSTer wrapper (`FPGA_ATARISYS1`) and cart loader (`ATARI_CART`)
— they elaborate under their real entity names; we replace the wrapper with our APF top.

### Verified timing
`tb_syngen` measures **456 clocks per horizontal line** (H counter 0–455) — exactly
Escape's raster (456×262), confirming the System 1 video base matches Escape's timing.

## Run it
```bash
./sim/analyze_base.sh          # elaboration coverage of the base RTL
./sim/run_tb.sh tb_syngen      # sync-generator timing
./sim/run_tb.sh tb_ee_save 3ms # EEPROM save/restore across a simulated power cycle
./sim/run_tb.sh tb_ee_ram_equiv 100us   # EEPROM RAM swap is invisible to the CPU
```

`tb_ee_save` needs the longer stop time: it walks all 512 EEPROM bytes through
a restore, an autosave and an exit-time snapshot, which is ~1.4 ms of core
clock. See [`../docs/EEPROM_SAVE.md`](../docs/EEPROM_SAVE.md).

## `run_pf_reset_tb.sh` — the playfield fetch channel vs. a core reset (PFRESET-111)

```bash
./sim/run_pf_reset_tb.sh                 # the gate: six runs, three scenarios x fix/no-fix
PFRESET_SWEEP=1 ./sim/run_pf_reset_tb.sh # + the drain-rate characterisation
PFRESET_KEEP=1  ./sim/run_pf_reset_tb.sh # keep sim/build/pfslice* for inspection
```

Unlike every other bench here, `tb_pf_reset.v` **does not contain a copy of the RTL it
tests**. `sim/tools/mk_pf_reset_slice.py` cuts the four relevant blocks verbatim out of
`src/fpga/core/core_top.v` on every run and includes them, so the bench cannot drift from
what ships — and `--defeat-fix` builds the *failing* case by excising the `PFRESET-111`
reset block from that slice and nothing else. If the fix is ever deleted from
`core_top.v`, the extractor aborts rather than silently grading nothing.

The negative controls are load-bearing in both directions: PHASE 1 and PHASE 2 with the
fix excised **must** wedge (and must have actually lost a request while reset was held),
and PHASE 0 — a reset taken with the CRAM controller idle — **must not**, because a bench
that wedges on any reset is not measuring the mechanism. Full results and the
"how much contention does this take" table are in
[`../docs/PIPELINES.md`](../docs/PIPELINES.md), under *The reset rig*.

## Benches that report "fail" by construction

**`tb_escape_handshake` always reports HANDSHAKE INCOMPLETE at its default
budget, on every branch, and that is not a regression.** Its check process
loops a hard-coded 500,000 clocks (5 ms) and then reports, *ignoring the
`--stop-time` argument* — so passing a bigger stop time changes nothing. The
main's boot flow does not reach the 360011 release write inside 5 ms (the
extra's POST alone is ~1 s on device), so all three of `extra_release`,
`extra read mailbox` and `extra wrote` come back false.
[`../docs/investigations/NIGHT-ANALYSIS.md`](../docs/investigations/NIGHT-ANALYSIS.md) (the note above the
"Build 92 content" heading) recorded this as a bench-budget artifact; the bench
is kept for long-stoptime nightly use, which means raising the loop bound in
the bench itself, not the command line.

If you are bisecting a boot problem, this bench will look guilty on both sides
of the bisect. Use it only after raising that bound.

## `run_tb.sh` only elaborates what the bench needs

`ghdl -i` imports every file, `ghdl -m` analyses and elaborates only the
units the named bench reaches. A syntax or binding error in `escape_core.vhd`
does **not** fail `tb_escape_jsa` (nor, of course, `tb_prio`, which is an
iverilog bench run by `run_prio_tb.sh`); it fails the first bench that
instantiates the core. After editing `escape_core.vhd` (or anything it
instantiates), run `tb_escape_core` before committing — JSA2-164 pushed a
missing generic to the branch for an hour because only the JSA bench was run.

**`tb_escape_jshad`'s coin-report line is informational.** Its stated
purpose is the 6502's boot announcement (0xFF) arriving through the jshad
serve FSM, and that is what passes it. The held-coin report it also tries to
observe never lands inside the 24 ms window because the 68k has not consumed
the announcement yet (latch full) — verified identical on the tree before
GAMESEL-167 (2026-09-10 A/B), so the bench reports it and does not fail on
it. Since GAMESEL-167 the bench also counts SDRAM requests to the OKI ADPCM
slot and fails a JSA-II game that shows none (or a JSA-I game that shows any):
`GARGS='-gG_GAME=1 -gG_JSART=1' ./sim/run_tb.sh tb_escape_jshad 30ms` with a
Klax prototype image converted to `sim/work/combined_words.hex` (see
"Fixtures from your own romset").
