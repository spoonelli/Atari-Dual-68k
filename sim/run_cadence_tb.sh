#!/usr/bin/env bash
# CADENCE-107: prove the logic-frame cadence meter counts what it says it
# counts, with negative controls. See sim/tb/tb_escape_cadence.vhd.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
BASE="${BASE:-0x001000}"

python3 "$REPO_ROOT/sim/tools/make_cadence_hex.py" "$BASE"

TPMOUNT=()
if [ ! -d "$REPO_ROOT/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAIN/third_party:/work/third_party:ro")
fi

exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work "${TPMOUNT[@]}" \
  -w /work "$IMAGE" bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build/cadence
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' ! -iname 'escape_jsa.vhd' 2>/dev/null | sort)
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' ! -iname 'TMS5220.vhd' ! -iname 'TG68K.vhd' ! -iname 'TG68KdotC_Kernel.vhd' | sort) \$OURS sim/tb/escape_jsa_vecstub.vhd sim/tb/tb_escape_cadence.vhd\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W tb_escape_cadence >/dev/null
  ghdl -r \$STD --workdir=\$W tb_escape_cadence --ieee-asserts=disable --stop-time=60ms
"
