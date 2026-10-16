#!/usr/bin/env bash
# NVRAM-170: escape_hps_bridge (MiSTer game-select latch + EEPROM load/save)
# against an hps_io-shaped stimulus, clk_ram and clk_sys phase-locked at 5:1.
# Usage: ./sim/run_hps_bridge_tb.sh     expects "HPS BRIDGE PASS"
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 -o sim/build/tb_hps_bridge.vvp \
    src/mister/rtl/escape_hps_bridge.v sim/tb/tb_hps_bridge.v &&
  vvp -n sim/build/tb_hps_bridge.vvp" | tee sim/build/tb_hps_bridge.log
grep -q 'HPS BRIDGE PASS' sim/build/tb_hps_bridge.log
