#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 ${MOB_PARAMS:-} -o sim/build/tb_mob.vvp src/fpga/core/rtl/escape_mob.v sim/tb/tb_mob.v &&
  timeout 300 vvp sim/build/tb_mob.vvp"
