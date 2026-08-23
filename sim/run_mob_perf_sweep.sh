#!/usr/bin/env bash
# MOFETCH/MOCHAN: sweep the throughput bench over fetch latency and scene, for a
# reference engine and the current one, and print one comparison table.
#
# GFX_LAT is the per-tile-row service time in pixel clocks. 8 is the
# uncontended case; MO is the LOWEST-priority SDRAM client (core_top.v), so a
# busy scene means busy CPUs means a longer round trip - which is exactly when
# sprite count is highest. 31 is the measured worst case.
#
# MOCHAN-4: the bench and the engine share a PORT LIST (the fetch channels went
# from the A/B pair to a packed vector of four), so the reference engine must be
# run against the bench that shipped WITH it. Both are taken from BASE_REF, so
# the "base" column is that revision measured by its own bench rather than a
# newer bench bolted onto an older engine. The per-channel service model is
# identical in both (one independent GFX_LAT countdown per channel), which is
# what makes the two columns comparable.
#
#   BASE_REF=origin/zerowait ./sim/run_mob_perf_sweep.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
BASE_REF="${BASE_REF:-origin/zerowait}"
git show "$BASE_REF:src/fpga/core/rtl/escape_mob.v" > sim/build/escape_mob_base.v
git show "$BASE_REF:sim/tb/tb_mob_perf.v"           > sim/build/tb_mob_perf_base.v

run() {  # $1=rtl  $2=tb  $3=tag  $4=xscroll  $5=yscroll  $6=gfxlat
  docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
    iverilog -g2012 -Ptb_mob_perf.XSCROLL=$4 -Ptb_mob_perf.YSCROLL=$5 \
      -Ptb_mob_perf.GFX_LAT=$6 -o sim/build/sw_$3.vvp $1 $2 &&
    timeout 900 vvp sim/build/sw_$3.vvp +out=sim/build/mob_perf_px_$3.txt" 2>/dev/null | grep '^PERF'
  python3 sim/tools/mob_golden.py --xscroll "$4" --yscroll "$5" --budget 1000 \
      --compare "sim/build/mob_perf_px_$3.txt" | grep -E '^(COMPARE|LINES)'
}

printf '%-9s %-11s %-4s | %-7s %-8s %-9s %-8s %-6s %s\n' \
  ENGINE SCENE LAT pixels coverage lines-done slips+ghosts conc cycles/line
for scene in "50 157" "123 253" "0 0"; do
  set -- $scene
  for lat in 8 16 31; do
    for eng in base MOCHAN4; do
      if [ "$eng" = base ]; then
        out=$(run sim/build/escape_mob_base.v sim/build/tb_mob_perf_base.v base "$1" "$2" "$lat")
      else
        out=$(run src/fpga/core/rtl/escape_mob.v sim/tb/tb_mob_perf.v ch4 "$1" "$2" "$lat")
      fi
      px=$(sed -n 's/.*pixels=\([0-9]*\).*/\1/p' <<<"$out" | head -1)
      cov=$(sed -n 's/.*coverage=\([0-9.]*%\).*/\1/p' <<<"$out")
      dn=$(sed -n 's/.*complete=\([0-9]*\) aborted=\([0-9]*\).*/\1+\2/p' <<<"$out")
      sl=$(sed -n 's/.*pairing_slips=\([0-9]*\).*/\1/p' <<<"$out")
      gh=$(sed -n 's/.*ghosts=\([0-9]*\).*/\1/p' <<<"$out")
      cn=$(sed -n 's/.*concurrency max=\([0-9]*\).*/\1/p' <<<"$out")
      cyc=$(sed -n 's/.*per line: \(.*\))/\1/p' <<<"$out")
      printf '%-9s %-11s %-4s | %-7s %-8s %-9s %-8s %-6s %s\n' \
        "$eng" "$1/$2" "$lat" "$px" "$cov" "$dn/240" "$sl/$gh" "${cn:-2}" "$cyc"
    done
  done
done
echo "cycles/line = idle / traverse / prime(fetch stall) / blit"
echo "lines-done  = complete+aborted; MUST be 240 in every cell (never-wedge)"
echo "slips+ghosts= fetch pairing slips / stale-tag ghost pixels; both MUST be 0"
echo "conc        = max fetches simultaneously in flight (base bench: n/a, prints 2)"
