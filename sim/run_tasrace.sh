#!/usr/bin/env bash
# TASLOCK-102 run matrix: the build-101 freeze reproduced, the DTACK-only trap
# demonstrated, and the fix verified - all from ONE RTL tree, switched by
# escape_core's TASLOCK_EN generic, so there is no second branch and no oracle
# to drift.  Plus the never-wedge bench.
#
#   ./sim/run_tasrace.sh          # the whole matrix
#   ./sim/run_tasrace.sh 0        # just the reproduction
#
# Two release flavours, because they separate two different claims:
#   clr.b  - the game's own release ($9FC / $4068C).  On the 68000 CLR is
#            ITSELF a read-modify-write (it reads before writing), so its read
#            half gives the interlock a second place to serialise.
#   move.b - a PURE write: one bus cycle, no read.  This is the case that
#            proves the write strobes must be gated: they assert on EVERY
#            clock of a DTACK-stalled cycle by design, so withholding DTACK
#            alone does not stop the store from landing.
#
# Expected:
#   clr.b  TASLOCK_EN=0  -> SWALLOWED RELEASES > 0   (the bug reproduced)
#   clr.b  TASLOCK_EN=1  -> SWALLOWED RELEASES = 0   (the fix)
#   move.b TASLOCK_EN=0  -> SWALLOWED RELEASES > 0
#   move.b TASLOCK_EN=2  -> SWALLOWED RELEASES > 0   (DTACK-only is NOT enough)
#   move.b TASLOCK_EN=1  -> SWALLOWED RELEASES = 0
#   wedge  interlock ON, peer LOCK forced stuck forever -> both CPUs keep
#          running, total stall bounded by TL_TTL_MAX+1
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
RELEASE=move python3 "$REPO_ROOT/sim/tools/make_tasrace_hex.py"
MV="-gG_HEX=sim/work/tasrace_mv_words.hex"

run() {   # run <label> <ghdl generics...>
  local label="$1"; shift
  echo
  echo "=================== $label ==================="
  GARGS="$*" "$REPO_ROOT/sim/run_tb.sh" "$TB" "$STOP" 2>&1 \
    | grep -E "TASRACE|TASWEDGE|error|Error|ERROR|assert|failure" || true
}

TB=tb_escape_tasrace
case "$WHICH" in all|0) run "clr.b  release, TASLOCK_EN=0 (expect the bug)" \
      -gG_TAS=0 -gG_EXPECT=0 ;; esac
case "$WHICH" in all|1) run "clr.b  release, TASLOCK_EN=1 (expect no bug)" \
      -gG_TAS=1 -gG_EXPECT=1 ;; esac
case "$WHICH" in all|mv0) run "move.b release, TASLOCK_EN=0 (expect the bug)" \
      $MV -gG_TAS=0 -gG_EXPECT=0 ;; esac
case "$WHICH" in all|2) run "move.b release, TASLOCK_EN=2 DTACK-only (expect the bug)" \
      $MV -gG_TAS=2 -gG_EXPECT=0 ;; esac
case "$WHICH" in all|mv1) run "move.b release, TASLOCK_EN=1 (expect no bug)" \
      $MV -gG_TAS=1 -gG_EXPECT=1 ;; esac
case "$WHICH" in all|wedge) TB=tb_escape_taswedge
      run "never-wedge, stuck LOCK adversary" -gG_TAS=1 ;; esac
