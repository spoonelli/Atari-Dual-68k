#!/bin/sh
# iverilog smoke bench for jotego's jt6295 (the JSA-II OKI6295), run in the
# hdlc/iverilog Docker image because GHDL cannot elaborate Verilog.
# Usage: ./sim/run_oki_tb.sh          expects "JT6295 SMOKE OK"
set -e
cd "$(dirname "$0")/.."
H="$PWD/third_party/jt6295/hdl"
[ -f "$H/jt6295.v" ] || { echo "jt6295 submodule missing: git submodule update --init third_party/jt6295"; exit 1; }
mkdir -p sim/work/oki
docker run --rm -v "$H":/hdl -v "$PWD/sim":/sim -w /sim/work/oki hdlc/iverilog sh -c '
  iverilog -g2012 -o sim.vvp -I /hdl /sim/tb/tb_jt6295.v /hdl/jt6295.v /hdl/jt6295_acc.v /hdl/jt6295_adpcm.v \
    /hdl/jt6295_ctrl.v /hdl/jt6295_rom.v /hdl/jt6295_serial.v /hdl/jt6295_sh_rst.v /hdl/jt6295_timing.v \
    /hdl/jt12_comb.v /hdl/jt12_interpol.v && vvp -n sim.vvp' 2>&1 | grep -v 'platform'
