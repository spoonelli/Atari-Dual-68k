#!/usr/bin/env bash
# Per-game input mapping for both players on the MiSTer wrapper (INPUTS-180).
# Drives the REAL src/mister/rtl/escape_mister.v (VHDL machine stubbed) and
# checks every pad control lands on its own player's port with MAME's bits.
# See sim/tb/tb_mister_inputs.v.
#
# Usage: ./sim/run_mister_inputs_tb.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/sim:latest}"
python3 support/mk_core_stub.py src/fpga/core/rtl/escape_core.vhd > sim/tb/stub_escape_core.v
docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
  iverilog -g2012 -o sim/build/tb_mister_inputs.vvp \
    src/mister/rtl/escape_mister.v \
    src/fpga/core/rtl/sdram_simple.v \
    src/fpga/core/rtl/sdram_openrow.v \
    src/fpga/core/rtl/escape_mob.v \
    src/fpga/core/rtl/escape_prio.v \
    src/fpga/core/rtl/escape_mo_cache.v \
    src/fpga/core/rtl/escape_stain.v \
    src/fpga/core/rtl/hall_stick.v \
    sim/tb/stub_escape_core.v \
    sim/tb/tb_mister_inputs.v && \
  vvp sim/build/tb_mister_inputs.vvp" | tee sim/build/tb_mister_inputs.log
grep -q '^INPUTS PASS' sim/build/tb_mister_inputs.log
