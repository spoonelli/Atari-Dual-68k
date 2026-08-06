#!/usr/bin/env bash
# Runs inside the GHDL container (see analyze_base.sh). Imports the Atari System 1
# base RTL (our behavioral dpram substituted for the Altera one) and reports which
# modules elaborate cleanly under GHDL. This is our native-sim baseline of the RTL
# we're adapting for Escape.
set -uo pipefail
STD="--std=08 -fsynopsys -frelaxed"
W=sim/work
rm -rf "$W"; mkdir -p "$W"
RTL=third_party/Arcade-Atari-system1_MiSTer/rtl

FILES="sim/lib/dpram_sim.vhd $(find $RTL/atarisys1 $RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' | sort)"
echo ">> importing $(echo $FILES | wc -w) VHDL files into $W ..."
ghdl -i $STD --workdir="$W" $FILES 2>&1 | tail -3

echo ">> elaborating candidate modules under native GHDL:"
ok=0; fail=0
for top in SLAPSTIC POKEY TMS5220 SLAGS RGBI CRAMS GPC PFHS MOHLB_LSI MOHLB_TTL LINEBUF LINECTR SYNGEN VIDEO AUDIO CART MAIN ATARISYS1; do
  if ghdl -m $STD --workdir="$W" "$top" >"/tmp/$top.log" 2>&1; then
    echo "   OK    $top"; ok=$((ok+1))
  else
    reason=$(grep -m1 -iE 'error|cannot|no declaration|not found|unknown' "/tmp/$top.log" | sed 's/^[^:]*://' | cut -c1-70)
    echo "   FAIL  $top  -> ${reason:-see log}"; fail=$((fail+1))
  fi
done
echo ">> elaborated OK: $ok   failed: $fail"
