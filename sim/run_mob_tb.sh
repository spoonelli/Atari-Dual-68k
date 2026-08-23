#!/usr/bin/env bash
# Scene-replay bench for the MO line engine + the MO/playfield priority
# comparator, against real in-game state dumped from MAME.
# Fixtures (sim/work/game_{mo,cfg,pf,pfx}.hex) come from sim/tools/make_scene_hex.py.
# Usage: MOB_PARAMS='-PXSCROLL=255 -PYSCROLL=27' ./sim/run_mob_tb.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 ${MOB_PARAMS:-} -o sim/build/tb_mob.vvp \
    src/fpga/core/rtl/escape_mob.v src/fpga/core/rtl/escape_prio.v sim/tb/tb_mob.v &&
  timeout 600 vvp sim/build/tb_mob.vvp"
python3 sim/tools/check_mob_prio.py
