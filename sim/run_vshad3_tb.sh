#!/usr/bin/env bash
# VSHAD3-112 GATE: the partial ROM shadow and its runtime toggle.
#
#   ./sim/run_vshad3_tb.sh
#
# vshad3 is 16 KB of BRAM shadowing the main (video) CPU's 0x54000-0x57FFF.
# Three separate decodes in escape_core.vhd have to agree about that range -
# v_shad_rng (which suppresses the zero-wait fastpath), v_sel_shad3 (which
# reads the BRAM) and vshad3_we (which fills it) - and escape_core.vhd's own
# comment records why: if v_shad_rng says "shadowed" while v_sel_shad3 says
# "not mine", the range is served by NEITHER. The fastpath is suppressed, the
# BRAM is never read, and every fetch falls through to the 16-clock
# never-wedge watchdog. That is a ~4x slowdown on the video CPU's hottest
# code and it is completely silent - nothing asserts, nothing mismatches.
#
# WHY THIS GATE CANNOT PASS BY DOING NOTHING. It runs four configurations of
# the SHIPPED escape_core and demands three DIFFERENT specific answers:
#
#   BASE      VS3 VS3ON  expect  a wrong answer here means
#   0x054000   1    1    5.015   the shadow is not serving the range it claims
#   0x054000   1    0    4.015   the runtime toggle does nothing
#   0x050000   1    1    4.015   the range was never actually halved to 16 KB
#   0x054000   0    1    4.015   VSHAD3_EN=0 no longer removes the shadow
#
# A build that ignored the toggle fails row 2. A build that kept the old 32 KB
# range fails row 3. A build where the decodes diverged fails row 1 on the
# >=6.000 "served by neither" trip. There is no single behaviour that satisfies
# all four, which is the point - see docs/VSHAD3.md section 8.4, including the
# mutation test that confirmed the gate catches a real divergence.
#
# Each row also asserts WHERE the loop ran (the bench reports bus cycles per
# 16 KB half), so a mis-assembled image that quietly executed somewhere else
# is rejected rather than graded.
#
# Env: FP (fastpath fill latency, default 1 = the authentic hit)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

FP="${FP:-1}"
# macOS ships bash 3.2. No arrays anywhere in this script: six gate scripts in
# this repo have already been fixed once for empty-array expansion under
# `set -u` (d6ca697), and the cheapest way not to be the seventh is to have no
# array to expand.
fails=0
rows=0

# clocks-per-cycle is reported x1000 as an integer, so these are exact
# comparisons, not tolerances. The +-1 window absorbs the single clock of
# warmup phase the bench's fixed window can land on and nothing else.
check() {
    base="$1"; vs3="$2"; vs3on="$3"; want="$4"; wanthalf="$5"; why="$6"
    rows=$((rows + 1))
    echo "### BASE=$base VS3=$vs3 VS3ON=$vs3on  expect ${want} (x1000)  [$why]"
    out="$(BASE="$base" VS3="$vs3" VS3ON="$vs3on" FP="$FP" "$REPO/sim/run_busrate.sh" 2>&1 || true)"
    line="$(printf '%s\n' "$out" | grep 'milliclocks_per_cycle=' || true)"
    cnts="$(printf '%s\n' "$out" | grep '^BUSRATE clocks=' || true)"
    if [ -z "$line" ]; then
        echo "    FAIL: the bench produced no result at all"
        printf '%s\n' "$out" | tail -20
        fails=$((fails + 1)); return
    fi
    got="$(printf '%s\n' "$line" | sed 's/.*milliclocks_per_cycle=\([0-9]*\).*/\1/')"
    lo="$(printf '%s\n' "$cnts" | sed 's/.*in_50000_53FFF=\([0-9]*\).*/\1/')"
    hi="$(printf '%s\n' "$cnts" | sed 's/.*in_54000_57FFF=\([0-9]*\).*/\1/')"
    cyc="$(printf '%s\n' "$cnts" | sed 's/.*buscycles=\([0-9]*\).*/\1/')"
    echo "    got=$got  buscycles=$cyc  in_50000_53FFF=$lo  in_54000_57FFF=$hi"

    # A run that issued no bus cycles is not a pass, it is a broken image.
    if [ "$cyc" -lt 1000 ]; then
        echo "    FAIL: only $cyc bus cycles - the image or the reset vector is wrong,"
        echo "          this is NOT a result"
        fails=$((fails + 1)); return
    fi

    # "Served by neither": the fastpath suppressed AND the BRAM not read, so
    # every fetch waits out the 16-clock watchdog. This is the specific silent
    # bug the three decodes exist to avoid, so trip on it by name.
    if [ "$got" -ge 6000 ]; then
        echo "    FAIL: ${got} (x1000) clocks per bus cycle. >=6.000 is the"
        echo "          SERVED-BY-NEITHER signature: v_shad_rng and v_sel_shad3"
        echo "          disagree about this range, so the fastpath is suppressed"
        echo "          and the BRAM is never read. Check all three decodes"
        echo "          (v_shad_rng, v_sel_shad3, vshad3_we) in escape_core.vhd."
        fails=$((fails + 1)); return
    fi

    # The loop must have executed in the half we aimed it at.
    if [ "$wanthalf" = "lo" ]; then
        if [ "$lo" -lt $((cyc - cyc / 100)) ] || [ "$hi" -ne 0 ]; then
            echo "    FAIL: expected the loop in 0x50000-0x53FFF, got lo=$lo hi=$hi"
            fails=$((fails + 1)); return
        fi
    else
        if [ "$hi" -lt $((cyc - cyc / 100)) ] || [ "$lo" -ne 0 ]; then
            echo "    FAIL: expected the loop in 0x54000-0x57FFF, got lo=$lo hi=$hi"
            fails=$((fails + 1)); return
        fi
    fi

    d=$((got - want)); [ "$d" -lt 0 ] && d=$((-d))
    if [ "$d" -gt 1 ]; then
        echo "    FAIL: expected $want (x1000), got $got. $why"
        fails=$((fails + 1)); return
    fi
    echo "    ok"
}

echo "=== VSHAD3-112 partial shadow gate (fastpath fill latency FP=$FP) ==="
check 0x054000 1 1 5015 hi \
  "0x54000-0x57FFF IS the shadow: the BRAM path costs 5 CPU clocks per fetch"
check 0x054000 1 0 4015 hi \
  "vshad3_on=0 must hand the SAME addresses to the 4-clock fastpath"
check 0x050000 1 1 4015 lo \
  "0x50000-0x53FFF is NO LONGER shadowed; 5.015 here means the range is still 32 KB"
check 0x054000 0 1 4015 hi \
  "VSHAD3_EN=0 must remove the shadow entirely, toggle or no toggle"

echo
if [ "$fails" -ne 0 ]; then
    echo "VSHAD3 GATE: FAIL ($fails of $rows rows)"
    exit 1
fi
echo "VSHAD3 GATE: PASS ($rows/$rows rows)"
