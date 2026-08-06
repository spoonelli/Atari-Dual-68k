#!/usr/bin/env bash
# Elaborate + run a testbench under native GHDL. Imports the System 1 base RTL
# (behavioral dpram substituted) plus everything in sim/tb/, then runs the named
# testbench entity. Usage: ./sim/run_tb.sh [tb_entity]   (default: tb_syngen)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
TB="${1:-tb_syngen}"
exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work -w /work "$IMAGE" bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/work
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' 2>/dev/null | sort)
  FILES=\"sim/lib/dpram_sim.vhd \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' | sort) \$OURS \$(ls sim/tb/*.vhd)\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W $TB >/dev/null
  ghdl -r \$STD --workdir=\$W $TB --stop-time=500us
"
