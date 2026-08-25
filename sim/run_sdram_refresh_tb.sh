#!/usr/bin/env bash
# SDRAM auto-refresh JEDEC retention gate (REFRESH-111).
#
#   ./sim/run_sdram_refresh_tb.sh
#
# Measures the WORST-CASE clocks between consecutive AUTO REFRESH commands
# under saturated read pressure, for every refresh policy that has been shipped
# or proposed, and checks each against the MT48LC16M16A2's 7.8125 us per-row
# limit. The point is that these numbers are MEASURED against the real FSM: the
# hand arithmetic that justified each of the three forked values used
# "interval + defer_cap" and silently dropped the in-flight transaction, which
# understates the worst case by ~15 clocks.
#
# The sweep includes the shipping policy, both rival policies from the other
# branches, and a NEGATIVE CONTROL (the original 250 + 48 that started this)
# which MUST be reported FAIL. If the negative control passes, the bench is not
# measuring anything and the script exits non-zero.
#
# bash 3.2 safe (macOS): no associative arrays, no ${ARR[@]} on empty arrays.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/iverilog:latest}"

run() {   # $1=interval  $2=defer_cap  $3=read_pressure  $4=tag
  docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
    iverilog -g2012 \
      -Ptb_sdram_refresh.REFRESH_INTERVAL=$1 \
      -Ptb_sdram_refresh.DEFER_CAP=$2 \
      -Ptb_sdram_refresh.READ_PRESSURE=$3 \
      -o sim/build/tb_sdram_refresh_$4.vvp \
      src/fpga/core/rtl/sdram_simple.v sim/tb/tb_sdram_refresh.v &&
    timeout 600 vvp sim/build/tb_sdram_refresh_$4.vvp" 2>&1 \
  | grep -v '^WARNING: The requested' | grep -v '^INFO:' | grep -v '^ *Time: 0'
}

FAIL=0
report() {  # $1=label  $2=interval  $3=defer  $4=pressure  $5=tag  $6=expect(PASS|FAIL)
  echo "=== $1  (REFRESH_INTERVAL=$2 DEFER_CAP=$3 read_pressure=$4) ==="
  OUT="$(run "$2" "$3" "$4" "$5")"
  echo "$OUT" | grep -E 'TB_SDRAM_REFRESH (cfg|refreshes|mean|WORST|margin|paper|refresh occupancy|PASS|FAIL)' || true
  if [ "$6" = "PASS" ]; then
    if ! printf '%s' "$OUT" | grep -q 'TB_SDRAM_REFRESH PASS'; then
      echo "  !! GATE FAIL: expected this policy to meet spec and it did not" >&2
      FAIL=1
    fi
  else
    if ! printf '%s' "$OUT" | grep -q 'TB_SDRAM_REFRESH FAIL'; then
      echo "  !! GATE FAIL: the negative control PASSED - this bench cannot fail," >&2
      echo "     so a green run from it means nothing. Fix the bench first." >&2
      FAIL=1
    fi
  fi
  echo
}

# READ_PRESSURE=3 (bursty) is the only mode that reaches the true worst case;
# see the mode table in sim/tb/tb_sdram_refresh.v. Modes 1 and 2 report
# comfortable margin for policies that are actually out of spec.
#
# Negative controls FIRST: two policies that are genuinely out of spec and MUST
# be reported FAIL. The second one is not hypothetical - 224/48 is what
# origin/mister-port ships, believing (from hand arithmetic) that it is in spec.
report "NEGATIVE CONTROL - original policy, pre-CLKFIX-106"   250 48 3 orig   FAIL
report "NEGATIVE CONTROL - mister-port's 224, deferral kept"  224 48 3 mister FAIL
report "sdram-sched proposal - 250, deferral DELETED"         250  0 3 sched  PASS
report "SHIPPING both platforms - 160, deferral kept"         160 48 3 pocket PASS
report "sanity: idle bus, no read pressure"                   160 48 0 idle   PASS

if [ "$FAIL" -ne 0 ]; then
  echo "SDRAM REFRESH GATE FAIL" >&2
  exit 1
fi
echo "SDRAM REFRESH GATE PASS: shipping policy is inside the JEDEC limit under"
echo "  saturated read pressure, and the out-of-spec control was correctly rejected."
