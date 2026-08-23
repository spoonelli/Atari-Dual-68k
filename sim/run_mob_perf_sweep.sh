#!/usr/bin/env bash
# MOFETCH: sweep the throughput bench over fetch latency and scene, for the
# pre-MOFETCH engine and the current one, and print one comparison table.
#
# GFX_LAT is the per-tile-row service time in pixel clocks. 8 is the
# uncontended case; MO is the LOWEST-priority SDRAM client (core_top.v), so a
# busy scene means busy CPUs means a longer round trip - which is exactly when
# sprite count is highest. 31 is the measured worst case.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
BASE_REF="${BASE_REF:-sdram-sched}"
git show "$BASE_REF:src/fpga/core/rtl/escape_mob.v" > sim/build/escape_mob_base.v

run() {  # $1=rtl  $2=xscroll  $3=yscroll  $4=gfxlat
  docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
    iverilog -g2012 -Ptb_mob_perf.XSCROLL=$2 -Ptb_mob_perf.YSCROLL=$3 \
      -Ptb_mob_perf.GFX_LAT=$4 -o sim/build/sw.vvp $1 sim/tb/tb_mob_perf.v &&
    timeout 900 vvp sim/build/sw.vvp" 2>/dev/null | grep '^PERF'
  python3 sim/tools/mob_golden.py --xscroll "$2" --yscroll "$3" --budget 1000 \
      --compare sim/build/mob_perf_pixels.txt | grep -E '^(COMPARE|LINES)'
}

printf '%-9s %-11s %-4s | %-7s %-8s %-9s %-8s %s\n' \
  ENGINE SCENE LAT pixels coverage lines-done ghosts cycles/line
for scene in "50 157" "123 253" "0 0"; do
  set -- $scene
  for lat in 8 16 31; do
    for rtl in sim/build/escape_mob_base.v src/fpga/core/rtl/escape_mob.v; do
      out=$(run "$rtl" "$1" "$2" "$lat")
      name=base; [ "$rtl" = src/fpga/core/rtl/escape_mob.v ] && name=MOFETCH
      px=$(sed -n 's/.*pixels=\([0-9]*\).*/\1/p' <<<"$out" | head -1)
      cov=$(sed -n 's/.*coverage=\([0-9.]*%\).*/\1/p' <<<"$out")
      dn=$(sed -n 's/.*complete=\([0-9]*\) aborted.*/\1/p' <<<"$out")
      gh=$(sed -n 's/.*ghosts=\([0-9]*\).*/\1/p' <<<"$out")
      cyc=$(sed -n 's/.*per line: \(.*\))/\1/p' <<<"$out")
      printf '%-9s %-11s %-4s | %-7s %-8s %-9s %-8s %s\n' \
        "$name" "$1/$2" "$lat" "$px" "$cov" "$dn/240" "$gh" "$cyc"
    done
  done
done
echo "cycles/line = idle / traverse / prime(fetch stall) / blit"
