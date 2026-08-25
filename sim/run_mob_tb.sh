#!/usr/bin/env bash
# Scene-replay bench for the MO line engine + the MO/playfield priority
# comparator, against real in-game state dumped from MAME.
# Fixtures (sim/work/game_{mo,cfg,pf,pfx}.hex) come from sim/tools/make_scene_hex.py.
#
# Usage: XSCROLL=224 YSCROLL=421 ./sim/run_mob_tb.sh
#
# MOPLACE-0: the scroll MUST be passed this way. iverilog's -P takes a
# HIERARCHICAL name (-Ptb_mob.XSCROLL=224); a bare "-PXSCROLL=224" is accepted
# on the command line and then SILENTLY IGNORED, so the bench quietly ran at its
# default 123/253 while the scene it was being compared against scrolled at
# 224/421. Every MO placement measurement taken before this was therefore of a
# different frame than the one it was diffed against. The env vars below build
# the hierarchical form, and MOB_PARAMS is rejected if it uses the bare form.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build

PARAMS=""
if [ -n "${XSCROLL:-}" ]; then PARAMS="$PARAMS -Ptb_mob.XSCROLL=$XSCROLL"; fi
if [ -n "${YSCROLL:-}" ]; then PARAMS="$PARAMS -Ptb_mob.YSCROLL=$YSCROLL"; fi
if [ -n "${MOB_PARAMS:-}" ]; then
  case "$MOB_PARAMS" in
    *-P[A-Za-z]*)
      if ! printf '%s' "$MOB_PARAMS" | grep -q -- '-Ptb_mob\.'; then
        echo "run_mob_tb.sh: MOB_PARAMS='$MOB_PARAMS' uses iverilog's bare -PNAME= form," >&2
        echo "  which iverilog ignores without warning. Use XSCROLL=/YSCROLL= env vars," >&2
        echo "  or spell the parameter hierarchically as -Ptb_mob.NAME=value." >&2
        exit 2
      fi;;
  esac
  PARAMS="$PARAMS $MOB_PARAMS"
fi
echo "iverilog params:${PARAMS:-  (bench defaults)}"

docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 $PARAMS -o sim/build/tb_mob.vvp \
    src/fpga/core/rtl/escape_mob.v src/fpga/core/rtl/escape_prio.v src/fpga/core/rtl/escape_mo_cache.v sim/tb/tb_mob.v &&
  timeout 600 vvp sim/build/tb_mob.vvp"
python3 sim/tools/check_mob_prio.py
# MODEPTH-1: ...and score the MO layer itself against MAME's own atarimo
# renderer. check_mob_prio above validates the PRIORITY decision; this
# validates which SPRITE won each pixel, which is the only check that notices a
# change in the order the engine reaches the linked list. See that file.
python3 sim/tools/mob_vs_mame.py --xscroll "${XSCROLL:-123}" --yscroll "${YSCROLL:-253}"
