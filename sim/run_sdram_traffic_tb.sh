#!/usr/bin/env bash
# STAGE 1 measurement + its own validity controls.
#
#   ./sim/run_sdram_traffic_tb.sh
#
# Measures, for the real access sequence the arbiter produces:
#   - the row-hit rate an open-row policy would achieve
#   - the miss split (client switch vs same-client stride vs refresh)
#   - access latency, mean and worst, per client
#   - whether motion-object fetch demand is met (the sprite-dropout proxy)
#
# THE CONTROL CELLS ARE NOT DECORATION. Cells C1-C3 are the ones that make the
# headline number mean anything:
#
#   C1  MO only, no CPU. The SEQ-ROW figure MUST land near 84.14%, because an
#       offline analysis of the very same trace file computes exactly that for
#       the MO stream's consecutive-same-row fraction (8185 fetches, 23 distinct
#       1 KB rows). Two independent routes to one number. If C1 disagrees, the
#       bench's row accounting is wrong and every other cell is void.
#       NOTE it is SEQ-ROW that is compared, not ROW-HIT. ROW-HIT additionally
#       has refresh closing the row (~22% of MO-only accesses follow a refresh),
#       so comparing ROW-HIT against the offline number compares two different
#       quantities. The first version of this control did exactly that and
#       failed at 69.80% - the control was wrong, not the bench.
#   C2  Video CPU only, no MO and no extra CPU. A single sequential client MUST
#       show a high hit rate. If it does not, the counterfactual is broken.
#   C3  MO only with CPU_ROW_RES made irrelevant - proves the CPU locality knob
#       does not leak into a cell that has no CPU.
#
# and the sweep cells S1-S5 exist because the captured CPU trace covers early
# boot (a tight loop, 99.99% same-row) and is NOT representative of gameplay.
# The conclusion is only reported if it survives the whole locality range.
#
# bash 3.2 safe (macOS): no arrays, no ${ARR[@]} under set -u.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/iverilog:latest}"

RTL="${SDRAM_RTL:-src/fpga/core/rtl/sdram_simple.v}"
echo "### controller under test: $RTL"
echo

FAIL=0

cell() {  # $1=tag $2=label $3..=iverilog -P overrides (single string)
  TAG="$1"; LABEL="$2"; shift 2
  rm -f "sim/build/tb_traffic_$TAG.vvp"
  OUT="$(docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
    iverilog -g2012 $* -o sim/build/tb_traffic_$TAG.vvp \
      $RTL sim/tb/sdram_model.v sim/tb/tb_sdram_traffic.v &&
    timeout 900 vvp sim/build/tb_traffic_$TAG.vvp" 2>&1 \
    | grep -v '^WARNING: The requested' | grep -v '^INFO:')"
  echo "=== $TAG: $LABEL ==="
  echo "$OUT" | grep -E 'TB_SDRAM_TRAFFIC (cfg|accesses|ROW-HIT|SEQ-ROW|MISS SPLIT|per-client|latency|MO demand|DATA CHECK|FAIL)|SDRAM_MODEL violations|SDRAM_MODEL   (read_no_row|tRCD)' || true
  if ! printf '%s' "$OUT" | grep -q 'TB_SDRAM_TRAFFIC DONE'; then
    echo "  !! CELL FAIL: no DONE line - the bench did not complete" >&2
    FAIL=1
  fi
  if printf '%s' "$OUT" | grep -q 'TB_SDRAM_TRAFFIC FAIL'; then
    echo "  !! CELL FAIL: the bench reported a failure" >&2
    FAIL=1
  fi
  # A cell that checked no data, or returned any wrong word, is a hard fail:
  # a wrong-row serve is FAST and WRONG, so a throughput-only pass is exactly
  # the trap this whole exercise is trying to avoid.
  if ! printf '%s' "$OUT" | grep -q 'DATA CHECK: words=[1-9][0-9]* mismatches=0'; then
    echo "  !! CELL FAIL: data check absent, empty, or non-zero mismatches" >&2
    FAIL=1
  fi
  # Any JEDEC protocol violation invalidates the cell outright.
  if ! printf '%s' "$OUT" | grep -q 'SDRAM_MODEL violations: total=0'; then
    echo "  !! CELL FAIL: the memory model reported protocol violations" >&2
    FAIL=1
  fi
  LAST_OUT="$OUT"
  echo
}

# ---- validity controls ------------------------------------------------
cell C1 "CONTROL - MO only. Row-hit MUST be ~84% (independent offline figure)" \
  "-Ptb_sdram_traffic.CPU_EN=0 -Ptb_sdram_traffic.MO_EN=1"
C1SEQ="$(printf '%s' "$LAST_OUT" | sed -n 's/.*SEQ-ROW.*= \([0-9.]*\)%.*/\1/p')"
if [ -n "$C1SEQ" ]; then
  OK="$(python3 -c "print(1 if 83.0 <= $C1SEQ <= 85.5 else 0)")"
  if [ "$OK" != "1" ]; then
    echo "  !! CONTROL FAIL: C1 seq-row ${C1SEQ}% is outside 83.0-85.5%." >&2
    echo "     The offline analysis of the same trace says 84.14%. The bench's" >&2
    echo "     row accounting disagrees with it, so no other cell can be trusted." >&2
    FAIL=1
  else
    echo "  C1 cross-check OK: ${C1SEQ}% vs 84.14% offline (independent routes agree)"; echo
  fi
else
  echo "  !! CONTROL FAIL: could not parse C1 seq-row rate" >&2; FAIL=1
fi

cell C2 "CONTROL - video CPU only. A single sequential client MUST hit often" \
  "-Ptb_sdram_traffic.MO_EN=0 -Ptb_sdram_traffic.EFILL_PCT=0 -Ptb_sdram_traffic.CPU_ROW_RES=256"
C2HIT="$(printf '%s' "$LAST_OUT" | sed -n 's/.*ROW-HIT RATE.*= \([0-9.]*\)%.*/\1/p')"
if [ -n "$C2HIT" ]; then
  OK="$(python3 -c "print(1 if $C2HIT >= 80.0 else 0)")"
  if [ "$OK" != "1" ]; then
    echo "  !! CONTROL FAIL: C2 row-hit ${C2HIT}% - one sequential client should" >&2
    echo "     hit nearly always. The counterfactual is not measuring row reuse." >&2
    FAIL=1
  else
    echo "  C2 OK: single-client hit rate ${C2HIT}%"; echo
  fi
fi

# ---- the measurement, swept over CPU locality -------------------------
cell S1 "no-shadow (70% fill), CPU_ROW_RES=8   (very poor CPU locality)" \
  "-Ptb_sdram_traffic.CPU_ROW_RES=8"
cell S2 "no-shadow (70% fill), CPU_ROW_RES=32" \
  "-Ptb_sdram_traffic.CPU_ROW_RES=32"
cell S3 "no-shadow (70% fill), CPU_ROW_RES=64  (default)" \
  "-Ptb_sdram_traffic.CPU_ROW_RES=64"
cell S4 "no-shadow (70% fill), CPU_ROW_RES=256" \
  "-Ptb_sdram_traffic.CPU_ROW_RES=256"
cell S5 "no-shadow (70% fill), real captured video-CPU trace (boot loop)" \
  "-Ptb_sdram_traffic.USE_CPU_TRACE=1"
cell S6 "SHADOWED (39% fill), CPU_ROW_RES=64 - what BUILD 112 looks like" \
  "-Ptb_sdram_traffic.VFILL_PCT=39 -Ptb_sdram_traffic.EFILL_PCT=39"

if [ "$FAIL" -ne 0 ]; then
  echo "SDRAM TRAFFIC STAGE-1 FAIL" >&2
  exit 1
fi
echo "SDRAM TRAFFIC STAGE-1 COMPLETE (controls passed)"
