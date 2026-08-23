#!/usr/bin/env bash
# TASLOCK-102 run matrix: the build-101 freeze reproduced, the DTACK-only trap
# demonstrated, and the fix verified - all from ONE RTL tree, switched by
# escape_core's TASLOCK_EN generic, so there is no second branch and no oracle
# to drift.  Plus the never-wedge bench.
#
#   ./sim/run_tasrace.sh          # all four runs
#   ./sim/run_tasrace.sh 0        # just the reproduction
#
# Expected:
#   TASLOCK_EN=0  interlock OFF        -> SWALLOWED RELEASES > 0   (the bug)
#   TASLOCK_EN=2  DTACK-only           -> SWALLOWED RELEASES > 0   (the trap:
#                 the shared-RAM write strobes assert on every clock of a
#                 stalled cycle, so holding DTACK alone changes nothing)
#   TASLOCK_EN=1  interlock ON         -> SWALLOWED RELEASES = 0   (the fix)
#   wedge         interlock ON, peer LOCK forced stuck forever -> both CPUs
#                 keep running, total stall bounded by TL_TTL_MAX+1
#
# Each run FAILS LOUDLY if it did not actually construct the race (trial
# count, both TAS outcomes seen, release cycle observed inside the RMW
# window).  A zero swallow count from a bench that measured nothing is the
# exact failure mode this project has hit six times.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STOP="${STOP:-6ms}"
WHICH="${1:-all}"

python3 "$REPO_ROOT/sim/tools/make_tasrace_hex.py"

run() {   # run <label> <ghdl generics...>
  local label="$1"; shift
  echo
  echo "=================== $label ==================="
  GARGS="$*" "$REPO_ROOT/sim/run_tb.sh" "$TB" "$STOP" 2>&1 \
    | grep -E "TASRACE|TASWEDGE|error|Error|ERROR|assert|failure" || true
}

TB=tb_escape_tasrace
case "$WHICH" in
  all|0) run "TASLOCK_EN=0  interlock OFF (expect the bug)"  -gG_TAS=0 -gG_EXPECT=0 ;;
esac
case "$WHICH" in
  all|2) run "TASLOCK_EN=2  DTACK-only (expect the bug)"     -gG_TAS=2 -gG_EXPECT=0 ;;
esac
case "$WHICH" in
  all|1) run "TASLOCK_EN=1  interlock ON (expect no bug)"    -gG_TAS=1 -gG_EXPECT=1 ;;
esac
case "$WHICH" in
  all|wedge) TB=tb_escape_taswedge; run "never-wedge, stuck LOCK adversary" -gG_TAS=1 ;;
esac
