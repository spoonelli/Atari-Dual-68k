#!/usr/bin/env bash
# MOFETCH throughput bench for the MO line engine (sim/tb/tb_mob_perf.v).
# Scores the rendered frame against sim/tools/mob_golden.py, a model of the
# engine's OWN intended output - so any shortfall is time starvation.
#
#   XSCROLL=50 YSCROLL=157 ./sim/run_mob_perf.sh
#   XSCROLL=50 YSCROLL=157 GFX_LAT=16 ./sim/run_mob_perf.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
XSCROLL="${XSCROLL:-50}"
YSCROLL="${YSCROLL:-157}"
GFX_LAT="${GFX_LAT:-8}"
mkdir -p sim/build
docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 -Ptb_mob_perf.XSCROLL=$XSCROLL -Ptb_mob_perf.YSCROLL=$YSCROLL \
    -Ptb_mob_perf.GFX_LAT=$GFX_LAT ${MOB_PARAMS:-} \
    -o sim/build/tb_mob_perf.vvp src/fpga/core/rtl/escape_mob.v sim/tb/tb_mob_perf.v &&
  timeout 600 vvp sim/build/tb_mob_perf.vvp"
python3 sim/tools/mob_golden.py --xscroll "$XSCROLL" --yscroll "$YSCROLL" \
    --budget 62 --label 'vs-budget62' --compare sim/build/mob_perf_pixels.txt
python3 sim/tools/mob_golden.py --xscroll "$XSCROLL" --yscroll "$YSCROLL" \
    --budget 1000 --label 'vs-unlimited' --compare sim/build/mob_perf_pixels.txt
