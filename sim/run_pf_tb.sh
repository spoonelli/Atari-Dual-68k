#!/usr/bin/env bash
# Art-in-sim for the CRAM playfield path: iverilog (docker) + golden checker.
#
# Usage: ./sim/run_pf_tb.sh
#
# NEGATIVE CONTROL (PFSIM-113). This gate is only worth anything if it can
# fail, so the failing configuration is a first-class mode rather than
# something you have to hand-edit the bench to reach:
#
#     PF_SINGLE_CH=1 ./sim/run_pf_tb.sh
#
# forces the old one-in-flight design (channel B disabled, PF issue blocked
# while a competing CRAM fetch is pending). It MUST fail, with mismatch counts
# rising toward the right of the frame - the accumulating-rightward per-column
# signature that convicted the one-in-flight design on hardware at build 39.
# If that run ever passes, the gate has stopped measuring anything; fix that
# before trusting a clean run.
#
# PF_MO_BURST=<n> overrides the competing-client burst length. See the
# MO_BURST comment in sim/tb/tb_pf_cram.v for why the default is what it is -
# raising it overruns the PF queue and the checker will reject the run as
# unattributable rather than report the resulting mismatches as a defect.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
# Never let a previous run's artefacts be graded as this run's. Without this a
# vvp that dies mid-frame leaves the last good pf_pixels.txt/pf_stats.txt in
# place and the checker cheerfully passes them.
rm -f sim/build/pf_pixels.txt sim/build/pf_stats.txt
IMG="${IVERILOG_IMAGE:-hdlc/sim:latest}"

# A plain string, not an array: the whole thing is interpolated into a
# `bash -c` command line anyway, and macOS bash 3.2 expands an empty array
# under `set -u` badly enough that six gate scripts in this repo have already
# been fixed for it once (d6ca697). No array, no trap.
PARAMS=""
if [ "${PF_SINGLE_CH:-0}" != "0" ]; then
  PARAMS="$PARAMS -P tb_pf_cram.SINGLE_CH=1"
  echo "### NEGATIVE CONTROL: SINGLE_CH=1 (one-in-flight); this run MUST FAIL"
fi
if [ -n "${PF_MO_BURST:-}" ]; then
  PARAMS="$PARAMS -P tb_pf_cram.MO_BURST=${PF_MO_BURST}"
fi

docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
  iverilog -g2012 $PARAMS -o sim/build/tb_pf_cram.vvp \
    third_party/analogue-pocket-utils/psram.sv \
    sim/tb/tb_pf_cram.v && \
  vvp sim/build/tb_pf_cram.vvp"
python3 sim/tools/check_pf_frame.py
