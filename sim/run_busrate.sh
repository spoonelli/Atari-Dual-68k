#!/usr/bin/env bash
# VSHAD3-107: measure main-CPU ROM bus-cycle cost, shadowed vs fastpath, on
# the shipped escape_core. See sim/tb/tb_escape_busrate.vhd for the method and
# for what this does and does not measure.
#
#   BASE=0x050000 VS3=1 ./sim/run_busrate.sh   # loop inside vshad3 -> BRAM
#   BASE=0x050000 VS3=0 ./sim/run_busrate.sh   # same code, fastpath
#
# Env: FPEN FP SHAD VS3 LAT WARM CLKS BASE TAG
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
FPEN="${FPEN:-1}"; FP="${FP:-1}"; SHAD="${SHAD:-1}"; VS3="${VS3:-1}"
LAT="${LAT:-2}"; WARM="${WARM:-20000}"; CLKS="${CLKS:-200000}"
BASE="${BASE:-0x050000}"; TAG="${TAG:-b$BASE-v$VS3-fp$FP}"

python3 "$REPO_ROOT/sim/tools/make_busrate_hex.py" "$BASE"

TPMOUNT=()
if [ ! -d "$REPO_ROOT/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAIN/third_party:/work/third_party:ro")
fi

exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work ${TPMOUNT[@]+"${TPMOUNT[@]}"} \
  -w /work "$IMAGE" bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build/busrate-$TAG
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' ! -iname 'escape_jsa.vhd' 2>/dev/null | sort)
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' ! -iname 'TMS5220.vhd' ! -iname 'TG68K.vhd' ! -iname 'TG68KdotC_Kernel.vhd' | sort) \$OURS sim/tb/escape_jsa_vecstub.vhd sim/tb/tb_escape_busrate.vhd\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W tb_escape_busrate >/dev/null
  ghdl -r \$STD --workdir=\$W tb_escape_busrate --ieee-asserts=disable --stop-time=60ms \
    -gG_FPEN=$FPEN -gG_FP=$FP -gG_SHAD=$SHAD -gG_VS3=$VS3 -gG_LAT=$LAT \
    -gG_WARM=$WARM -gG_CLKS=$CLKS -gG_HEX=sim/work/busrate_words.hex
"
