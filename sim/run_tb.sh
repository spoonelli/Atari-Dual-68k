#!/usr/bin/env bash
# Elaborate + run a testbench under native GHDL. Imports the System 1 base RTL
# (behavioral dpram substituted) plus everything in sim/tb/, then runs the named
# testbench entity. Usage: ./sim/run_tb.sh [tb_entity]   (default: tb_syngen)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
TB="${1:-tb_syngen}"
# tb_escape_adc boots from a generated stub image (hand-assembled words, no
# game ROM); rebuild it here on the host, since hex files are never committed
if [ "$TB" = "tb_escape_adc" ]; then
  python3 "$REPO_ROOT/sim/tools/make_adc_hex.py" >/dev/null
fi
exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work -w /work "$IMAGE" bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' 2>/dev/null | sort)
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' | sort) \$OURS \$(ls sim/tb/*.vhd)\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W $TB >/dev/null
  ghdl -r \$STD --workdir=\$W $TB --ieee-asserts=disable --stop-time=500us
"
