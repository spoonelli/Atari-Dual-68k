#!/usr/bin/env bash
# Quartus ANALYSIS & ELABORATION only (no synthesis, no fit) - the cheap gate
# that catches VHDL/Verilog the GHDL benches never see (Verilog top level,
# mixed-language binding, .qsf file-list mistakes).  Minutes, not an hour.
#
#   ./sim/quartus_analyze.sh
#
# Worktrees carry an empty third_party submodule: the main checkout's copy is
# mounted read-only over it, same trick as sim/run_tb.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="theypsilon/quartus-lite-c5:18.1"

TPMOUNT=()
if [ ! -d "$REPO_ROOT/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAIN/third_party:/work/third_party:ro")
fi

docker run --rm --platform linux/amd64 \
  -v "$REPO_ROOT":/work ${TPMOUNT[@]+"${TPMOUNT[@]}"} -w /work/src/fpga \
  "$IMAGE" quartus_map --analysis_and_elaboration ap_core
