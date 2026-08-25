#!/usr/bin/env bash
# Playfield fetch service on the MiSTer SDRAM arbiter.
#
# Drives the REAL src/mister/rtl/escape_mister.v through power-on -> ROM
# download (core in reset) -> reset release -> one measured frame, and counts
# the playfield fetches the arbiter actually serves.  See sim/tb/tb_mister_pf.v.
#
# Usage: ./sim/run_mister_pf_tb.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/sim:latest}"

# regenerate the machine stub from the VHDL entity so it can never drift
python3 support/mk_core_stub.py src/fpga/core/rtl/escape_core.vhd > sim/tb/stub_escape_core.v

docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
  iverilog -g2012 -o sim/build/tb_mister_pf.vvp \
    src/mister/rtl/escape_mister.v \
    src/fpga/core/rtl/sdram_simple.v \
    src/fpga/core/rtl/escape_mob.v \
    src/fpga/core/rtl/escape_prio.v \
    src/fpga/core/rtl/escape_stain.v \
    src/fpga/core/rtl/hall_stick.v \
    sim/tb/stub_escape_core.v \
    sim/tb/sdram_model_mem.v \
    sim/tb/tb_mister_pf.v && \
  vvp sim/build/tb_mister_pf.vvp" | tee sim/build/tb_mister_pf.log

grep -q '^RESULT: PASS' sim/build/tb_mister_pf.log
