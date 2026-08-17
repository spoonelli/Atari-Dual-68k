#!/usr/bin/env bash
# Art-in-sim for the CRAM playfield path: iverilog (docker) + golden checker.
# Usage: ./sim/run_pf_tb.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/sim:latest}"
docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
  iverilog -g2012 -o sim/build/tb_pf_cram.vvp \
    third_party/analogue-pocket-utils/psram.sv \
    sim/tb/tb_pf_cram.v && \
  vvp sim/build/tb_pf_cram.vvp"
python3 sim/tools/check_pf_frame.py
