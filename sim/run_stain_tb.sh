#!/usr/bin/env bash
# GFXDASH-3: the stain gate.
#
# Unlike sim/run_mob_tb.sh, whose fixture reports "0 special pixels", this
# bench builds its own scene and that scene CONTAINS stain markers. It also
# drives src/fpga/core/rtl/escape_stain.v - the same file core_top.v
# instantiates - so it is the shipped compositor automaton under test and not
# a transcription of it (which is all sim/tools/check_stain_automaton.py has
# ever tested).
#
# Fails on: a lost END marker (stain runs to the last screen column), a stale
# line-buffer pixel (an MO pixel in two places at once), a broken special/pen
# decode, and a missing or truncated fixture.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build sim/work

python3 sim/tools/make_stain_scene.py

docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 -o sim/build/tb_stain.vvp \
    src/fpga/core/rtl/escape_mob.v src/fpga/core/rtl/escape_stain.v \
    sim/tb/tb_stain.v &&
  timeout 900 vvp sim/build/tb_stain.vvp"

python3 sim/tools/check_stain.py
