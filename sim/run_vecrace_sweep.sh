#!/usr/bin/env bash
# Parallel phase-sweep launcher for tb_escape_vecrace: N docker slices with
# staggered phase offsets and varied rom-service latency. Logs land in
# sim/work/logs/<BATCH>-p<PHOFF>.log.
#
#   BATCH=name FIXED=0|1 SHAD=0|1 NIRQ_SLICE=n ./sim/run_vecrace_sweep.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BATCH="${BATCH:-batch}"
FIXED="${FIXED:-0}"
SHAD="${SHAD:-1}"
NIRQ_SLICE="${NIRQ_SLICE:-1667}"
STOPTIME="${STOPTIME:-120ms}"

mkdir -p "$REPO_ROOT/sim/work/logs"
python3 "$REPO_ROOT/sim/tools/make_vecrace_hex.py" >/dev/null

pids=()
for spec in "0 2" "102 3" "204 4" "306 2" "408 3" "510 4"; do
  read -r ph lat <<< "$spec"
  PHOFF=$ph LAT=$lat SHAD=$SHAD FIXED=$FIXED NIRQ=$NIRQ_SLICE SKIPHEX=1 \
    STOPTIME=$STOPTIME TAG="$BATCH-p$ph" "$REPO_ROOT/sim/run_vecrace.sh" \
    > "$REPO_ROOT/sim/work/logs/$BATCH-p$ph.log" 2>&1 &
  pids+=($!)
done

rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
echo "=== sweep batch $BATCH done (rc=$rc) ==="
grep -hE "COMPLETE|CORRUPTION|WEDGE|EARLY-TERM|\(assertion" \
  "$REPO_ROOT"/sim/work/logs/$BATCH-p*.log | head -60
exit $rc
