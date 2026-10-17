#!/usr/bin/env bash
# Exhaustive check of the MO/playfield priority comparator (escape_prio.v)
# against sim/tools/mo_priority_model.py, the literal transcription of the
# PAL equations + merge loop in reference/eprom.cpp.
# Usage: ./sim/run_prio_tb.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 -o sim/build/tb_prio.vvp \
    src/fpga/core/rtl/escape_prio.v sim/tb/tb_prio.v &&
  vvp sim/build/tb_prio.vvp" | tee sim/build/tb_prio.log
# GUTS-168: the Guts-mode comparator is checked in-line by the bench itself;
# without this the script's exit code covered only the Escape half.
grep -q 'GUTS PRIO CHECK PASS' sim/build/tb_prio.log || { echo "GUTS PRIO CHECK did not pass" >&2; exit 1; }
python3 sim/tools/check_prio.py
