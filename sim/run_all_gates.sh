#!/usr/bin/env bash
# Run the full gate set and record a pass/fail line per gate.
# NOT part of the shipped gate set - a convenience runner for this branch.
# Deliberately does NOT use && chaining between gates: an early failure must
# not short-circuit the rest (docs/investigations/LESSONS.md).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
LOG="${GATE_LOG:-sim/build/gates.log}"
: > "$LOG"
FAIL=0
run_gate() {   # $1=script  $2..=env assignments already exported by caller
  NAME="$1"; shift
  echo "########## $NAME" | tee -a "$LOG"
  START=$(date +%s)
  if "$@" >>"$LOG" 2>&1; then
    RC=0
  else
    RC=$?
  fi
  END=$(date +%s)
  if [ "$RC" -eq 0 ]; then
    echo "GATE PASS  $NAME  ($((END-START))s)" | tee -a "$LOG"
  else
    echo "GATE FAIL  $NAME  rc=$RC  ($((END-START))s)" | tee -a "$LOG"
    FAIL=1
  fi
}

run_gate "run_sdram_model_tb (openrow)"   env SDRAM_DUT=openrow ./sim/run_sdram_model_tb.sh
run_gate "run_sdram_refresh_tb (openrow)" env SDRAM_DUT=openrow ./sim/run_sdram_refresh_tb.sh
run_gate "run_sdram_refresh_tb (simple)"  ./sim/run_sdram_refresh_tb.sh
run_gate "run_prio_tb"        ./sim/run_prio_tb.sh
run_gate "run_psram_tb"       ./sim/run_psram_tb.sh
run_gate "run_mob_tb"         ./sim/run_mob_tb.sh
run_gate "run_mob_order_check" ./sim/run_mob_order_check.sh
run_gate "run_stain_tb"       ./sim/run_stain_tb.sh
run_gate "run_pf_tb"          ./sim/run_pf_tb.sh
run_gate "run_pf_reset_tb"    ./sim/run_pf_reset_tb.sh
run_gate "run_cadence_tb"     ./sim/run_cadence_tb.sh
run_gate "run_vshad3_tb"      ./sim/run_vshad3_tb.sh
run_gate "run_tasrace"        ./sim/run_tasrace.sh

echo "===== SUMMARY ====="
grep -E '^GATE (PASS|FAIL)' "$LOG"
exit "$FAIL"
