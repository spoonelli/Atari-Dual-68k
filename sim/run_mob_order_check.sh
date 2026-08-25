#!/usr/bin/env bash
# MODEPTH-1: prove the scout's park queue did not change the sprite draw order.
#
# Runs the reference engine and the working-tree engine through the SAME bench
# (tb_mob_perf, -DMOB_BASE strips the probes only the newer engine has) and
# diffs their per-line sprite LOAD ORDER with sim/tools/mob_order_check.py.
# See that file for the invariant: the shorter run must be an exact prefix.
#
#   BASE_REF=<any git ref> ./sim/run_mob_order_check.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
# STRUCTURAL LIMITATION, read before trusting a pass or a fail:
# This gate drives TWO versions of escape_mob.v with ONE bench (the current
# tb_mob_perf.v). That only works when both versions expose every signal the
# bench probes. A base older than the bench fails to elaborate -- e.g. a base
# predating `sc_pf_valid` gives "Unable to bind wire/reg/memory dut.sc_pf_valid".
# That is a real limitation, not a bug in your change: pick a BASE_REF close to
# HEAD, or vendor the matching bench alongside the base. Until then this gate is
# only meaningful for adjacent commits.
# The old default was origin/mo-chan4, a topic branch that was merged and then
# DELETED in a branch prune -- so this gate failed for everyone with a bare git
# error, and had been doing so silently since the prune. The default is now the
# last commit that actually MODIFIED escape_mob.v before HEAD, which is the
# comparison this check is for ("did my edit reorder anything?") and is always
# resolvable. Comparing HEAD against itself would be degenerate: identical files
# trivially agree, so the gate would pass while measuring nothing -- the exact
# failure mode this project has hit sixteen times.
if [ -z "${BASE_REF:-}" ]; then
    BASE_REF="$(git log -2 --format=%H -- src/fpga/core/rtl/escape_mob.v | tail -1)"
    [ -n "$BASE_REF" ] || BASE_REF="HEAD~1"
fi
if ! git rev-parse --verify -q "$BASE_REF^{commit}" >/dev/null; then
    echo "!! BASE_REF '$BASE_REF' does not resolve to a commit." >&2
    echo "   Pass an explicit ref: BASE_REF=<ref> $0" >&2
    exit 2
fi
if git diff --quiet "$BASE_REF" HEAD -- src/fpga/core/rtl/escape_mob.v; then
    echo "!! BASE_REF '$BASE_REF' has an escape_mob.v IDENTICAL to HEAD's." >&2
    echo "   This gate would compare a file with itself and pass vacuously." >&2
    echo "   Pass a ref with a different escape_mob.v: BASE_REF=<ref> $0" >&2
    exit 3
fi
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
      >"sim/build/ordlog_$tag.txt" 2>&1 || {
        # Under `set -e` this docker step used to abort the whole script with
        # docker's own exit code and NO output at all -- the run produced zero
        # bytes and a bare "exit 4", which tells you nothing. Capture the log
        # and say which cell died and where to look.
        echo "!! build/sim FAILED for $xs/$ys lat$lat -- see sim/build/ordlog_$tag.txt" >&2
        tail -5 "sim/build/ordlog_$tag.txt" >&2
        rc=1
        continue
      }
    printf '%-14s ' "$xs/$ys lat$lat"
    python3 sim/tools/mob_order_check.py \
      "sim/build/ord_base_$tag.txt" "sim/build/ord_depth_$tag.txt" || rc=1
  done
done
exit $rc
