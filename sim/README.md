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
