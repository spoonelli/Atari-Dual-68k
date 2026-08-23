#!/usr/bin/env bash
# Elaborate + run tb_escape_worldwake (the faithful dual-CPU runtime IRQ
# contract bench - see the tb header) under docker GHDL.
#
# Env knobs:
#   EIRQ=0|1|2    escape_core EIRQ_MODE (0=86 shared pulse, 1=91 IACK latch,
#                 2=armed latch - the ZEROWAIT-92 fix; default 2)
#   FPEN=0|1      escape_core FASTPATH_EN (default 1)
#   FP=n          fastpath server model (0=none, 1=authentic, n>1=n-clk fill)
#   SHAD=0|1      shadow BRAMs filled + enabled (device runs 1)
#   LAT=n         legacy rom service latency clks (default 2)
#   FRAME=n       base vblank period, clks (default 2500)
#   SWEEP=n       period modulus, 1 = LOCKED period (default 613)
#   PHOFF=n       phase offset for parallel slices
#   NFRM=n        frames to run (default 400)
#   SLOW=1        rebuild image with the SDRAM-starved poll loop (86 regime)
#   TAG=name      unique build-dir tag for parallel runs
#   SKIPHEX=1     don't regenerate the hex image
#   WAVE=path.ghw dump waves   STOPTIME=t (default 2sec)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
EIRQ="${EIRQ:-2}"
FPEN="${FPEN:-1}"
FP="${FP:-1}"
SHAD="${SHAD:-0}"
LAT="${LAT:-2}"
FRAME="${FRAME:-2500}"
SWEEP="${SWEEP:-613}"
PHOFF="${PHOFF:-0}"
NFRM="${NFRM:-400}"
SLOW="${SLOW:-0}"
TAG="${TAG:-e$EIRQ-fp$FPEN$FP-s$SHAD-p$PHOFF}"
WAVE="${WAVE:-}"
STOPTIME="${STOPTIME:-2sec}"

HEX="sim/work/worldwake_words.hex"
if [ "$SLOW" = "1" ]; then HEX="sim/work/worldwake_slow_words.hex"; fi
if [ "${SKIPHEX:-0}" != "1" ]; then
  if [ "$SLOW" = "1" ]; then
    SLOW=1 python3 "$REPO_ROOT/sim/tools/make_worldwake_hex.py"
    mv "$REPO_ROOT/sim/work/worldwake_words.hex" "$REPO_ROOT/sim/work/worldwake_slow_words.hex"
  else
    python3 "$REPO_ROOT/sim/tools/make_worldwake_hex.py"
  fi
fi

# worktrees carry an empty third_party submodule: mount the main checkout's
TPMOUNT=()
if [ ! -d "$REPO_ROOT/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAIN="$(git -C "$REPO_ROOT" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAIN/third_party:/work/third_party:ro")
fi

RUNFLAGS="--ieee-asserts=disable --stop-time=$STOPTIME"
if [ -n "$WAVE" ]; then RUNFLAGS="$RUNFLAGS --wave=$WAVE"; fi

exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work "${TPMOUNT[@]}" \
  -w /work "$IMAGE" bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build/worldwake-$TAG
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' ! -iname 'escape_jsa.vhd' 2>/dev/null | sort)
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' ! -iname 'TMS5220.vhd' | sort) \$OURS sim/tb/escape_jsa_vecstub.vhd sim/tb/tb_escape_worldwake.vhd\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W tb_escape_worldwake >/dev/null
  ghdl -r \$STD --workdir=\$W tb_escape_worldwake $RUNFLAGS \
    -gG_EIRQ=$EIRQ -gG_FPEN=$FPEN -gG_FP=$FP -gG_SHAD=$SHAD -gG_LAT=$LAT \
    -gG_FRAME=$FRAME -gG_SWEEP=$SWEEP -gG_PHOFF=$PHOFF -gG_NFRM=$NFRM \
    -gG_HEX=$HEX
"
