# Simulation (native GHDL, no Quartus)

We verify RTL logic with **GHDL**, which is light enough to run in Docker under
emulation on Apple Silicon (unlike Quartus). This lets the whole design-and-verify
phase proceed on a Mac with no FPGA toolchain and no GitHub runner — Quartus is only
needed at the very end to produce the physical bitstream.

## Prerequisites
- Docker Desktop running. The image `ghdl/ghdl:ubuntu20-mcode` is pulled on first use.

## What's here
- `ghdl.sh` — thin wrapper: runs GHDL in the container with the repo mounted at `/work`.
- `lib/dpram_sim.vhd` — behavioral dual-port RAM, drop-in for the Altera megafunction
  (`third_party/.../rtl/lib/mem/dpram.vhd`) so the base RTL elaborates without Quartus IP.
- `analyze_base.sh` — imports the Atari System 1 base RTL and reports which modules
  elaborate under GHDL (our adaptation baseline).
- `run_tb.sh [tb]` — elaborate + run a testbench from `tb/` (default `tb_syngen`).
- `tb/` — testbenches.
- `run_mister_pf_tb.sh` — **MiSTer playfield fetch service** (iverilog, Docker).
  Drives the real `src/mister/rtl/escape_mister.v` through power-on → ROM
  download with the core held in reset → release → one measured frame, and
  counts the playfield fetches the SDRAM arbiter serves. This is the
  PFRESET-107 regression: BUILD 105 served **zero** and rendered a flat
  playfield on real hardware. Only the VHDL machine is stubbed, and
  `sim/tb/stub_escape_core.v` is regenerated from `escape_core.vhd`'s entity by
  `support/mk_core_stub.py` on every run so it cannot drift. `sim/tb/
  sdram_model.v` is a behavioural MT48LC16M16A2; the bench validates its own
  read latency by requiring the core's power-on readback probes to pass.

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

## Benches that report "fail" by construction

**`tb_escape_handshake` always reports HANDSHAKE INCOMPLETE at its default
budget, on every branch, and that is not a regression.** Its check process
loops a hard-coded 500,000 clocks (5 ms) and then reports, *ignoring the
`--stop-time` argument* — so passing a bigger stop time changes nothing. The
main's boot flow does not reach the 360011 release write inside 5 ms (the
extra's POST alone is ~1 s on device), so all three of `extra_release`,
`extra read mailbox` and `extra wrote` come back false.
[`../docs/NIGHT-ANALYSIS.md`](../docs/NIGHT-ANALYSIS.md) (the note above the
"Build 92 content" heading) recorded this as a bench-budget artifact; the bench
is kept for long-stoptime nightly use, which means raising the loop bound in
the bench itself, not the command line.

If you are bisecting a boot problem, this bench will look guilty on both sides
of the bisect. Use it only after raising that bound.
