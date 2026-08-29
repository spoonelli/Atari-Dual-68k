#!/usr/bin/env bash
# Regenerate the address-trace fixtures that sim/tb/tb_sdram_traffic.v replays.
#
#   ./sim/tools/make_sdram_traces.sh
#
# Writes into sim/work/ (which is GITIGNORED, so these are not committed and a
# fresh checkout has none of them):
#
#   mo_addr.hex   motion-object graphics fetch addresses, in issue order
#   mo_time.hex   the pixel-clock time each of those became due
#   cpu_addr.hex  video-CPU program-fetch addresses
#
# WHY THIS SCRIPT EXISTS. The Stage 1 numbers in docs/investigations/SDRAM_ARCH.md are only
# as good as these three files, and without a way to regenerate them the whole
# measurement is unreproducible - someone re-running the bench on a clean
# checkout would get the fixture guard's FAIL (or, without that guard, a
# confident zero). sim/work/ being gitignored is exactly the trap the brief
# warns about: "a zero-pixel/zero-cell result means missing fixtures, NOT a pass".
#
# Both traces come from REAL RTL against REAL data:
#
#  MO   tb_mob_perf.v driving the real src/fpga/core/rtl/escape_mob.v against
#       real sprite RAM (sim/work/game_mo.hex) and real graphics
#       (sim/work/image_bytes.hex). One full frame at scroll 50/157.
#       ~8185 fetches.
#
#  CPU  tb_escape_core.vhd running the REAL game ROM
#       (sim/work/combined_words.hex) through the REAL TG68K inside
#       escape_core, with SHAD_EN => 0 so nothing is hidden by a BRAM shadow.
#       This is the ONLY bench in the repo that runs real game code; every
#       other CPU bench uses a synthetic image whose row locality would be an
#       artefact of the image rather than of the game.
#
#       CAVEAT, and it is why tb_sdram_traffic defaults to USE_CPU_TRACE=0:
#       within the window this captures, the video CPU is still in its boot
#       RAM-test loop - 7633 fetches across TWO 1 KB rows, 99.99% same-row.
#       Real code, but not gameplay, and using it alone flatters the open-row
#       case. Sweep CPU_ROW_RES instead and check the conclusion survives.
#       The extra CPU is never released in this window either, so cpu_addr.hex
#       contains video-CPU addresses only.
#
# GHDL runs under linux/amd64 emulation on Apple Silicon; the CPU trace step
# takes roughly ten minutes there. The MO step is iverilog and takes ~1 minute.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
mkdir -p sim/build sim/work

XSCROLL="${XSCROLL:-50}"
YSCROLL="${YSCROLL:-157}"
CPU_US="${CPU_US:-2000}"

# worktrees carry an empty third_party submodule: mount the main checkout's
TPMOUNT=()
if [ ! -d "$REPO/third_party/Arcade-Atari-system1_MiSTer/rtl" ]; then
  MAINWT="$(git -C "$REPO" worktree list --porcelain | head -1 | sed 's/^worktree //')"
  TPMOUNT=(-v "$MAINWT/third_party:/work/third_party:ro")
fi

echo "### 1/3  motion-object fetch trace (real escape_mob.v, real sprite data)"
rm -f sim/build/mo_trace.txt
docker run --rm -v "$REPO":/work -w /work "${IVERILOG_IMAGE:-hdlc/iverilog:latest}" bash -c "
  iverilog -g2012 -Ptb_mob_perf.XSCROLL=$XSCROLL -Ptb_mob_perf.YSCROLL=$YSCROLL \
    -Ptb_mob_perf.GFX_LAT=8 -o sim/build/tb_mob_trace.vvp \
    src/fpga/core/rtl/escape_mob.v sim/tb/tb_mob_perf.v &&
  timeout 900 vvp sim/build/tb_mob_trace.vvp +gtrace=sim/build/mo_trace.txt" \
  2>&1 | grep -E "^PERF (pixels|sprites)" || true
test -s sim/build/mo_trace.txt || { echo "FAIL: no MO trace produced" >&2; exit 1; }

echo "### 2/3  video-CPU program-fetch trace (real game ROM, real TG68K, no shadows)"
test -s sim/work/combined_words.hex || {
  echo "FAIL: sim/work/combined_words.hex missing." >&2
  echo "      Build it with: python3 sim/tools/rom_to_hex.py" >&2
  exit 1; }
rm -f sim/build/rom_trace.txt
docker run --rm --platform linux/amd64 -v "$REPO":/work ${TPMOUNT[@]+"${TPMOUNT[@]}"} \
  -w /work ghdl/ghdl:ubuntu20-mcode bash -c "
  set -e
  STD='--std=08 -fsynopsys -frelaxed'; W=sim/build/romtrace
  rm -rf \$W; mkdir -p \$W
  RTL=third_party/Arcade-Atari-system1_MiSTer/rtl
  SIMLIB=\$(find sim/lib -iname '*.vhd' | sort)
  OURS=\$(find src/fpga/core/rtl -iname '*.vhd' ! -iname 'escape_jsa.vhd' 2>/dev/null | sort)
  FILES=\"\$SIMLIB \$(find \$RTL/atarisys1 \$RTL/lib -iname '*.vhd' ! -iname 'dpram.vhd' ! -iname 'TMS5220.vhd' ! -iname 'TG68K.vhd' ! -iname 'TG68KdotC_Kernel.vhd' | sort) \$OURS sim/tb/escape_jsa_vecstub.vhd sim/tb/tb_escape_core.vhd\"
  ghdl -i \$STD --workdir=\$W \$FILES >/dev/null
  ghdl -m \$STD --workdir=\$W tb_escape_core >/dev/null
  ghdl -r \$STD --workdir=\$W tb_escape_core --ieee-asserts=disable --stop-time=3ms \
    -gG_TRACE=sim/build/rom_trace.txt -gG_US=$CPU_US
" 2>&1 | grep -E "ESCAPE-CORE|did not reach" || true
test -s sim/build/rom_trace.txt || { echo "FAIL: no CPU trace produced" >&2; exit 1; }

echo "### 3/3  converting to \$readmemh fixtures"
python3 - "$REPO" <<'PY'
import sys, os
repo = sys.argv[1]
recs = []
with open(os.path.join(repo, "sim/build/mo_trace.txt")) as f:
    for line in f:
        t, ch, a = line.split()
        recs.append((int(t), int(ch), int(a, 16)))
if not recs:
    sys.exit("FAIL: MO trace is empty")
t0 = recs[0][0]
with open(os.path.join(repo, "sim/work/mo_addr.hex"), "w") as f:
    for _, _, a in recs:
        f.write("%06x\n" % a)
with open(os.path.join(repo, "sim/work/mo_time.hex"), "w") as f:
    for t, _, _ in recs:
        f.write("%08x\n" % (t - t0))

ca = [int(x.strip(), 16) for x in open(os.path.join(repo, "sim/build/rom_trace.txt")) if x.strip()]
if not ca:
    sys.exit("FAIL: CPU trace is empty")
with open(os.path.join(repo, "sim/work/cpu_addr.hex"), "w") as f:
    for a in ca:
        f.write("%06x\n" % a)

rows = [a >> 10 for a in (r[2] for r in recs)]
hit = sum(1 for i in range(1, len(rows)) if rows[i] == rows[i-1])
print("MO  records=%d  distinct 1KB rows=%d  consecutive same-row=%.2f%%"
      % (len(recs), len(set(rows)), 100.0*hit/(len(rows)-1)))
print("CPU records=%d  range=%06x..%06x" % (len(ca), min(ca), max(ca)))
print()
print("NOTE: tb_sdram_traffic.v hardcodes MO_N and CPU_N as parameters.")
print("      If these counts differ from MO_N=8185 / CPU_N=7633, pass")
print("      -Ptb_sdram_traffic.MO_N=%d -Ptb_sdram_traffic.CPU_N=%d" % (len(recs), len(ca)))
print("      or the bench will read past the end of the arrays.")
PY

echo
echo "Wrote sim/work/mo_addr.hex, sim/work/mo_time.hex, sim/work/cpu_addr.hex"
echo "Now run: ./sim/run_sdram_traffic_tb.sh"
