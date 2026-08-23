#!/usr/bin/env bash
# Elaborate + run a testbench under native GHDL. Imports the System 1 base RTL
# (behavioral dpram substituted) plus everything in sim/tb/, then runs the named
# testbench entity. Usage: ./sim/run_tb.sh [tb_entity]   (default: tb_syngen)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
TB="${1:-tb_syngen}"
STOPTIME="${2:-500us}"
# tb_escape_adc boots from a generated stub image (hand-assembled words, no
# game ROM); rebuild it here on the host, since hex files are never committed
if [ "$TB" = "tb_escape_adc" ]; then
  python3 "$REPO_ROOT/sim/tools/make_adc_hex.py" >/dev/null
fi
# worktrees carry an empty third_party submodule: mount the main checkout's
# copy read-only in that case (same pattern as run_vecrace.sh)
TPMOUNT=()
if [ ! -d "$REPO_ROOT/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAIN/third_party:/work/third_party:ro")
fi
exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work "${TPMOUNT[@]}" -w /work "$IMAGE" bash -c "
  set -e
  # per-TB workdir: a shared sim/build wiped on entry was killing any
  # concurrently-running vecrace slices (they build in sim/build/vecrace-*)
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build/tb-$TB
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' 2>/dev/null | sort)
  # TMS5220.vhd excluded from the submodule tree: our patched copy lives in
  # src/fpga/core/rtl/ (LANE3z lattice wrap fix) and would collide with it.
  # escape_jsa_vecstub excluded: it redefines entity escape_jsa, and with
  # both files imported the real architecture can bind against the stub's
  # entity (no numeric_std in its context) and fail analysis; the stub
  # belongs to run_vecrace.sh, which excludes the real file instead.
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' ! -iname 'TMS5220.vhd' | sort) \$OURS \$(ls sim/tb/*.vhd | grep -v escape_jsa_vecstub)\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W $TB >/dev/null
  ghdl -r \$STD --workdir=\$W $TB --ieee-asserts=disable --stop-time=$STOPTIME
"
