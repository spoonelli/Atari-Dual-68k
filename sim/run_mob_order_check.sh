#!/usr/bin/env bash
# MODEPTH-1: prove the scout's park queue did not change the sprite draw order.
#
# Runs the reference engine and the working-tree engine through the SAME bench
# (tb_mob_perf, -DMOB_BASE strips the probes only the newer engine has) and
# diffs their per-line sprite LOAD ORDER with sim/tools/mob_order_check.py.
# See that file for the invariant: the shorter run must be an exact prefix.
#
#   BASE_REF=origin/mo-chan4 ./sim/run_mob_order_check.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
BASE_REF="${BASE_REF:-origin/mo-chan4}"
IMG="${IVERILOG_IMAGE:-hdlc/iverilog:latest}"
SCENES="${SCENES:-50:157 123:253 0:0}"
LATS="${LATS:-8 16 31}"

git show "$BASE_REF:src/fpga/core/rtl/escape_mob.v" > sim/build/escape_mob_base.v

rc=0
for scene in $SCENES; do
  xs="${scene%%:*}"; ys="${scene##*:}"
  for lat in $LATS; do
    tag="${xs}_${ys}_$lat"
    docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
      iverilog -g2012 -DMOB_BASE -Ptb_mob_perf.XSCROLL=$xs -Ptb_mob_perf.YSCROLL=$ys \
        -Ptb_mob_perf.GFX_LAT=$lat -o sim/build/ordb_$tag.vvp \
        sim/build/escape_mob_base.v sim/tb/tb_mob_perf.v &&
      timeout 900 vvp sim/build/ordb_$tag.vvp +out=/dev/null +ord=sim/build/ord_base_$tag.txt &&
      iverilog -g2012 -Ptb_mob_perf.XSCROLL=$xs -Ptb_mob_perf.YSCROLL=$ys \
        -Ptb_mob_perf.GFX_LAT=$lat -o sim/build/ordd_$tag.vvp \
        src/fpga/core/rtl/escape_mob.v sim/tb/tb_mob_perf.v &&
      timeout 900 vvp sim/build/ordd_$tag.vvp +out=/dev/null +ord=sim/build/ord_depth_$tag.txt" \
      >/dev/null 2>&1
    printf '%-14s ' "$xs/$ys lat$lat"
    python3 sim/tools/mob_order_check.py \
      "sim/build/ord_base_$tag.txt" "sim/build/ord_depth_$tag.txt" || rc=1
  done
done
exit $rc
