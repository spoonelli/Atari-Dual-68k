#!/usr/bin/env bash
# Elaborate + run tb_escape_vecrace (interrupt-dispatch corruption hunt) under
# docker GHDL. Fixtures live in sim/work/ (sim/build is wiped every run).
#
# Env knobs:
#   SHAD=0|1      escape_core SHAD_EN (default 0: all fetches via rom service)
#   NIRQ=n        IRQs to fire (default 20000)
#   BASE=n        base IRQ period in clks (default 900)
#   SWEEP=n       phase modulus (default 613)
#   LAT=n         rom service latency clks (default 2)
#   FIXED=0|1     1 = substitute the main checkout's escape_core.vhd (the
#                 SDSCHED-78 address-qualified-waitstate fix) for this tree's
#   DIAG=1        per-clock trace of FC=111 cycles (small NIRQ runs)
#   PHOFF=n       phase offset (parallel sweep slices use disjoint offsets)
#   TAG=name      unique build-dir tag, for parallel slices (default: shad$SHAD-p$PHOFF)
#   SKIPHEX=1     don't regenerate the hex image (parallel launchers pre-generate)
#   WAVE=path.ghw dump a GHW wave (targeted reruns; big files - keep NIRQ small)
#   STOPTIME=t    ghdl --stop-time (default 2sec)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
SHAD="${SHAD:-0}"
NIRQ="${NIRQ:-20000}"
BASE="${BASE:-500}"
SWEEP="${SWEEP:-613}"
LAT="${LAT:-2}"
FIXED="${FIXED:-0}"
PHOFF="${PHOFF:-0}"
DIAG="${DIAG:-0}"
TAG="${TAG:-shad$SHAD-p$PHOFF}"
WAVE="${WAVE:-}"
STOPTIME="${STOPTIME:-2sec}"

if [ "${SKIPHEX:-0}" != "1" ]; then
  python3 "$REPO_ROOT/sim/tools/make_vecrace_hex.py"
fi

# worktrees carry an empty third_party submodule: mount the main checkout's
# copy read-only in that case (main checkout = first entry of worktree list,
# so this works regardless of where the worktree directory lives)
TPMOUNT=()
if [ ! -d "$REPO_ROOT/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAIN/third_party:/work/third_party:ro")
fi

# FIXED=1: pull the fixed escape_core from the main checkout into sim/work/
# and analyze it AFTER the tree's copy so it wins elaboration
FIXEDFILE=""
if [ "$FIXED" = "1" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  cp "$MAIN/src/fpga/core/rtl/escape_core.vhd" "$REPO_ROOT/sim/work/escape_core_fixed.vhd"
  FIXEDFILE="sim/work/escape_core_fixed.vhd"
fi

RUNFLAGS="--ieee-asserts=disable --stop-time=$STOPTIME"
if [ -n "$WAVE" ]; then RUNFLAGS="$RUNFLAGS --wave=$WAVE"; fi

exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work "${TPMOUNT[@]}" \
  -w /work "$IMAGE" bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build/vecrace-$TAG
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  # the real escape_jsa (T65 + speech) is timing-irrelevant to the extra CPU
  # and dominates wall clock: excluded, the vecstub stands in
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' ! -iname 'escape_jsa.vhd' 2>/dev/null | sort)
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' ! -iname 'TMS5220.vhd' | sort) \$OURS $FIXEDFILE sim/tb/escape_jsa_vecstub.vhd sim/tb/tb_escape_vecrace.vhd\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W tb_escape_vecrace >/dev/null
  ghdl -r \$STD --workdir=\$W tb_escape_vecrace $RUNFLAGS \
    -gG_SHAD=$SHAD -gG_NIRQ=$NIRQ -gG_BASE=$BASE -gG_SWEEP=$SWEEP -gG_LAT=$LAT -gG_PHOFF=$PHOFF -gG_DIAG=$DIAG
"
