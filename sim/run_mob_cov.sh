#!/usr/bin/env bash
# MOCOV: coverage sweep - scene x fetch-latency, for a BASE engine and the
# working-tree engine, printed as one table.
#
# Unlike run_mob_perf_sweep.sh (which compares against the pre-MOFETCH engine
# on sdram-sched) this defaults to comparing against zerowait, i.e. the
# CURRENT shipped engine, which is the baseline coverage work has to beat.
#
# Cells are independent, so they run in PARALLEL - each into its own dump via
# the bench's +out= plusarg. Wall time goes from ~20min to ~3min, which is
# what makes an iterate-and-measure loop usable.
#
#   ./sim/run_mob_cov.sh              # base=origin/zerowait vs working tree
#   BASE_REF=HEAD~1 ./sim/run_mob_cov.sh
#   JOBS=4 ./sim/run_mob_cov.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build/cov
BASE_REF="${BASE_REF:-origin/zerowait}"
JOBS="${JOBS:-6}"
IMG="${IVERILOG_IMAGE:-hdlc/iverilog:latest}"
SCENES="${SCENES:-50:157 123:253 0:0}"
LATS="${LATS:-8 16 31}"

git show "$BASE_REF:src/fpga/core/rtl/escape_mob.v" > sim/build/escape_mob_base.v

# fixture guard: docs/LESSONS.md - this project has shipped three benches that
# reported a clean pass while rendering nothing. Refuse to run without a scene.
for f in game_mo.hex game_cfg.hex image_bytes.hex; do
  [ -s "sim/work/$f" ] || { echo "FATAL: sim/work/$f missing or empty" >&2; exit 1; }
done

cell() {  # $1=engine-name $2=rtl $3=xs $4=ys $5=lat
  local name="$1" rtl="$2" xs="$3" ys="$4" lat="$5"
  local tag="${name}_${xs}_${ys}_${lat}"
  local vvp="sim/build/cov/$tag.vvp" dump="sim/build/cov/$tag.txt"
  docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
    iverilog -g2012 -Ptb_mob_perf.XSCROLL=$xs -Ptb_mob_perf.YSCROLL=$ys \
      -Ptb_mob_perf.GFX_LAT=$lat -o $vvp $rtl sim/tb/tb_mob_perf.v &&
    timeout 900 vvp $vvp +out=$dump" 2>/dev/null | grep '^PERF' > "sim/build/cov/$tag.perf"
  python3 sim/tools/mob_golden.py --xscroll "$xs" --yscroll "$ys" --budget 1000 \
      --compare "$dump" | grep -E '^(COMPARE|LINES)' >> "sim/build/cov/$tag.perf"
}

n=0
for scene in $SCENES; do
  xs="${scene%%:*}"; ys="${scene##*:}"
  for lat in $LATS; do
    for e in base:sim/build/escape_mob_base.v new:src/fpga/core/rtl/escape_mob.v; do
      cell "${e%%:*}" "${e##*:}" "$xs" "$ys" "$lat" &
      n=$((n+1)); [ $((n % JOBS)) -eq 0 ] && wait
    done
  done
done
wait

printf '%-6s %-9s %-4s | %-7s %-9s %-9s %-7s %-6s %s\n' \
  ENGINE SCENE LAT pixels coverage lines-done wrong spur 'cycles/line idle/trav/prime/blit'
for scene in $SCENES; do
  xs="${scene%%:*}"; ys="${scene##*:}"
  for lat in $LATS; do
    for name in base new; do
      out=$(cat "sim/build/cov/${name}_${xs}_${ys}_${lat}.perf" 2>/dev/null || true)
      px=$(sed -n 's/.*PERF pixels=\([0-9]*\).*/\1/p' <<<"$out" | head -1)
      cov=$(sed -n 's/.*coverage=\([0-9.]*%\).*/\1/p' <<<"$out")
      dn=$(sed -n 's/.*complete=\([0-9]*\) aborted.*/\1/p' <<<"$out")
      wr=$(sed -n 's/.*correct=[0-9]* wrong=\([0-9]*\).*/\1/p' <<<"$out")
      sp=$(sed -n 's/.*spurious=\([0-9]*\).*/\1/p' <<<"$out")
      cyc=$(sed -n 's/.*per line: \(.*\))/\1/p' <<<"$out")
      printf '%-6s %-9s %-4s | %-7s %-9s %-9s %-7s %-6s %s\n' \
        "$name" "$xs/$ys" "$lat" "${px:-ERR}" "${cov:-ERR}" "${dn:-?}/240" "${wr:-?}" "${sp:-?}" "$cyc"
    done
  done
done
echo "cycles/line = idle / traverse / prime(fetch stall) / blit   (456 total)"
