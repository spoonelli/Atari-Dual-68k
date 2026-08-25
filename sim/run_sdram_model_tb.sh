#!/usr/bin/env bash
# Gate for sim/tb/sdram_model.v - the SDRAM memory model + JEDEC protocol
# checker that every open-row claim depends on.
#
#   ./sim/run_sdram_model_tb.sh
#
# This is a MUTATION gate, not a smoke test. Mode 0 is the only clean run; the
# other five each inject one specific defect and the gate FAILS if the model
# does not report that defect. An instrument that has never been observed to
# fail is not evidence - see docs/LESSONS.md.
#
# bash 3.2 safe (macOS): no arrays, no ${ARR[@]} under set -u.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/iverilog:latest}"

FAIL=0

run_mode() {   # $1=mode  $2=label  $3=clk_ns (optional, default 27.936508)
  CLKNS="${3:-27.936508}"
  echo "=== MODE $1: $2   (clk=${CLKNS} ns) ==="
  # Never grade a stale artefact: remove the vvp before rebuilding.
  rm -f "sim/build/tb_sdram_model_$1.vvp"
  OUT="$(docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
    iverilog -g2012 -Ptb_sdram_model.MODE=$1 -Ptb_sdram_model.CLK_NS=$CLKNS \
      -o sim/build/tb_sdram_model_$1.vvp \
      src/fpga/core/rtl/sdram_simple.v sim/tb/sdram_model.v sim/tb/tb_sdram_model.v &&
    timeout 300 vvp sim/build/tb_sdram_model_$1.vvp" 2>&1 \
    | grep -v '^WARNING: The requested' | grep -v '^INFO:')"
  echo "$OUT" | grep -E 'TB_SDRAM_MODEL|SDRAM_MODEL (cmds|timing|violations|  |write-table)' || true
  # A run that produced no verdict line at all is a FAIL, not a pass. This is
  # the "&&-chain short-circuited the grep" trap from docs/LESSONS.md.
  if ! printf '%s' "$OUT" | grep -q 'TB_SDRAM_MODEL RESULT'; then
    echo "  !! GATE FAIL: no RESULT line - the bench did not run to completion" >&2
    FAIL=1
  elif ! printf '%s' "$OUT" | grep -q 'TB_SDRAM_MODEL RESULT PASS'; then
    echo "  !! GATE FAIL: mode $1 did not pass" >&2
    FAIL=1
  fi
  echo
}

run_mode 0 "clean run - shipping FSM, expect 0 violations and 0 data mismatches"
run_mode 1 "MUTATION wrong-row serve - model MUST report data mismatches"
run_mode 2 "MUTATION READ with no open row - model MUST report it"
run_mode 3 "MUTATION AUTO REFRESH with a bank ACTIVE - model MUST report it"
run_mode 4 "MUTATION tRCD violation - model MUST report it" 10.0
run_mode 5 "MUTATION tRAS(min) violation - model MUST report it" 10.0

if [ "$FAIL" -ne 0 ]; then
  echo "SDRAM MODEL GATE FAIL" >&2
  exit 1
fi
echo "SDRAM MODEL GATE PASS: the model is clean against the shipping FSM and"
echo "  demonstrably reports all five injected defects, including the wrong-row"
echo "  serve and the refresh-with-open-bank hazard that open-row work risks."
