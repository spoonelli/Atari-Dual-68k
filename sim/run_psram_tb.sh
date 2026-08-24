#!/usr/bin/env bash
# CRAM (PSRAM) external-memory timing gate.
#
#   ./sim/run_psram_tb.sh
#
# Runs sim/tb/tb_psram_timing.v twice:
#
#   1. SHIPPING config - psram.sv told the truth about clk_sdram
#      (35.795455 MHz declared, 35.795455 MHz actual). Must PASS, and prints
#      the measured adv#->sample window and the I/O round-trip headroom.
#
#   2. PROVE-IT-CAN-FAIL config - the BUILD 106 bug class in its dangerous
#      direction: psram.sv still told 35.795455 MHz while the PLL actually
#      produces 85.909 MHz. Every wait state is then ~2.4x too short in real
#      time and reads sample before t_AA. This run MUST FAIL; if it passes,
#      the gate is not measuring anything and this script exits non-zero.
#
# The check prints what it measured (headroom in ns, violation count, reads
# checked), not just a verdict - "PASS" alone is indistinguishable from a
# bench that matched nothing.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build

run() {   # $1 = declared MHz   $2 = actual MHz   $3 = tag
  docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
    iverilog -g2012 \
      -Ptb_psram_timing.DECLARED_CLOCK_MHZ=$1 \
      -Ptb_psram_timing.ACTUAL_CLOCK_MHZ=$2 \
      -o sim/build/tb_psram_$3.vvp \
      third_party/analogue-pocket-utils/psram.sv sim/tb/tb_psram_timing.v &&
    timeout 300 vvp sim/build/tb_psram_$3.vvp" 2>&1 \
  | grep -v '^WARNING: The requested' | grep -v '^INFO:' | grep -v '^ *Time: 0'
}

echo "=== 1/2 shipping config (declared 35.795455 == actual 35.795455) ==="
OUT_OK="$(run 35.795455 35.795455 ok)"
echo "$OUT_OK"

echo
echo "=== 2/2 negative control: declared 35.795455 while the PLL runs 85.909 ==="
OUT_BAD="$(run 35.795455 85.909091 bad)"
echo "$OUT_BAD"

echo
FAIL=0
if ! printf '%s' "$OUT_OK" | grep -q 'TB_PSRAM_TIMING PASS'; then
  echo "PSRAM GATE FAIL: the shipping configuration did not pass" >&2
  FAIL=1
fi
if ! printf '%s' "$OUT_BAD" | grep -q 'TB_PSRAM_TIMING FAIL'; then
  echo "PSRAM GATE FAIL: the negative control PASSED - this bench cannot fail," >&2
  echo "  so a green run from it means nothing. Fix the bench before trusting it." >&2
  FAIL=1
fi
if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "PSRAM GATE PASS: shipping config meets t_AA with measured headroom, and the"
echo "  wrong-clock negative control was correctly rejected."
