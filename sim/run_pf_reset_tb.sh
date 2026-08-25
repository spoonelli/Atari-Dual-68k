#!/usr/bin/env bash
# PFRESET-111: does the playfield fetch channel survive a core reset?
#
# Usage: ./sim/run_pf_reset_tb.sh
#
# Six simulations: three reset scenarios x {fix present, fix EXCISED}.
#
#   PHASE 0  reset with the CRAM controller IDLE.  chk_state 4'd10, no
#            download-mirror traffic.  Expected NOT to wedge even without the
#            fix - the read-start chain catches every request edge in the one
#            cycle it has.  This is the control that keeps the bench honest:
#            if PHASE 0 wedged too, the bench would be wedging on any reset
#            rather than on the mechanism, and its other two results would
#            mean nothing.  It is also the answer to "why has the Pocket not
#            visibly failed".
#   PHASE 1  reset with the read-start chain unreachable (chk_state 4'd0, the
#            boot download).  The MiSTer PFRESET-107 sequence exactly.
#            Expected to wedge BOTH channels, deterministically.
#   PHASE 2  reset in steady state (chk_state 4'd10) with the REAL CRAM
#            download-mirror drain running - a gfx-region SDRAM write stream,
#            which is what happens on any dataslot re-download.  cq_n != 0
#            blocks a PF read start, so the chain misses edges.  Expected to
#            wedge BOTH channels.
#
# The excised runs are not hand-written imitations of the old RTL.  Every run
# `includes the SAME four blocks cut verbatim out of src/fpga/core/core_top.v
# by sim/tools/mk_pf_reset_slice.py; --defeat-fix removes the PFRESET-111
# reset block from the pixel-domain slice and nothing else.
#
# A negative control that stops failing is a gate that has stopped measuring
# anything, so this script FAILS if a PHASE 1 or PHASE 2 excised run does not
# wedge - and it also fails if such a run lost no request, because then it
# never constructed the race it claims to test.
#
# PFRESET_SWEEP=1 additionally sweeps the drain rate on the PHASE 2 excised
# run.  Not part of the gate (it is a characterisation, not a pass/fail), but
# it is where the "how much traffic does this take" table in docs/PIPELINES.md
# comes from.
#
# Env:
#   PFRESET_KEEP=1    leave sim/build/pfslice* in place for inspection
#   PFRESET_SWEEP=1   run the drain-rate characterisation sweep as well
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
mkdir -p sim/build
IMG="${IVERILOG_IMAGE:-hdlc/sim:latest}"

# Plain strings, not arrays: macOS bash 3.2 expands an empty array badly under
# `set -u` and six gate scripts in this repo have already been fixed for it
# once (d6ca697).
rm -rf sim/build/pfslice sim/build/pfslice_defeat
rm -f  sim/build/pf_reset_*.log sim/build/tb_pf_reset_*.vvp

fail=0

sim() {   # $1 phase, $2 mode, $3 wr_period, $4 tag -> writes sim/build/pf_reset_$4.log
    local phase="$1" mode="$2" wp="$3" tag="$4" dir log
    if [ "$mode" = "defeat" ]; then
        dir=sim/build/pfslice_defeat
        python3 sim/tools/mk_pf_reset_slice.py --outdir "$dir" --defeat-fix
    else
        dir=sim/build/pfslice
        python3 sim/tools/mk_pf_reset_slice.py --outdir "$dir"
    fi
    log="sim/build/pf_reset_${tag}.log"
    # Never grade a previous run's log as this one's.
    rm -f "$log" "sim/build/tb_pf_reset_${tag}.vvp"
    docker run --rm -v "$REPO":/work -w /work "$IMG" bash -c "
      iverilog -g2012 -P tb_pf_reset.PHASE=$phase -P tb_pf_reset.WR_PERIOD=$wp \
        -I $dir -o sim/build/tb_pf_reset_${tag}.vvp \
        third_party/analogue-pocket-utils/psram.sv \
        sim/tb/tb_pf_reset.v && \
      vvp sim/build/tb_pf_reset_${tag}.vvp" > "$log" 2>&1 || true
    if ! grep -q '^PFRESET_RESULT' "$log"; then
        echo "!!! $tag produced no verdict line - the run died. Tail:"
        tail -20 "$log"
        return 1
    fi
    return 0
}

field() { sed -n "s/.*$2=\([A-Za-z0-9_-]*\).*/\1/p" "sim/build/pf_reset_$1.log" | tail -1; }

echo "### PFRESET-111: playfield fetch channel vs. core reset"
for phase in 0 1 2; do
    for mode in defeat fix; do
        tag="p${phase}_${mode}"
        echo "--- PHASE $phase, fix $mode"
        sim "$phase" "$mode" 24 "$tag" || fail=1
        grep -E '^###' "sim/build/pf_reset_${tag}.log" | sed 's/^/    /' || true
    done
done

echo
echo "================= PFRESET-111 gate ================="
printf '%-8s %-14s %-14s %-8s %-8s\n' PHASE fix-excised fix-present lost post-iss
for phase in 0 1 2; do
    vd="$(field "p${phase}_defeat" VERDICT)"
    vf="$(field "p${phase}_fix" VERDICT)"
    ld="$(field "p${phase}_defeat" lost)"
    pd="$(field "p${phase}_defeat" post_issued)"
    ir="$(field "p${phase}_defeat" inreset)"
    printf '%-8s %-14s %-14s %-8s %-8s\n' "$phase" "${vd:-NONE}" "${vf:-NONE}" "${ld:-?}" "${pd:-?}"

    if [ "$phase" = "0" ]; then
        # The idle-controller control. It must NOT wedge either way: a bench
        # that wedges on every reset is not measuring the mechanism.
        if [ "$vd" != "ALIVE" ]; then
            echo "  FAIL: PHASE 0 (idle CRAM) wedged even without contention."
            echo "        The bench is no longer isolating the mechanism."
            fail=1
        fi
    else
        case "$vd" in
            WEDGED_BOTH|WEDGED_ONE) ;;
            *) echo "  FAIL: PHASE $phase negative control did NOT wedge (got '${vd:-NONE}')."
               echo "        This gate can no longer fail, so a clean run means nothing."
               fail=1 ;;
        esac
        if [ "${ld:-0}" -lt 1 ] 2>/dev/null || [ -z "${ld:-}" ]; then
            echo "  FAIL: PHASE $phase negative control lost no request - it never"
            echo "        constructed the race it claims to test."
            fail=1
        fi
        if [ "${ir:-0}" -lt 1 ] 2>/dev/null || [ -z "${ir:-}" ]; then
            echo "  FAIL: PHASE $phase negative control issued no fetch while reset"
            echo "        was held - there was nothing in flight to lose."
            fail=1
        fi
    fi
    if [ "$vf" != "ALIVE" ]; then
        echo "  FAIL: PHASE $phase with the fix present is '${vf:-NONE}', expected ALIVE."
        fail=1
    fi
done

if [ "${PFRESET_SWEEP:-0}" != "0" ]; then
    echo
    echo "--- drain-rate characterisation (PHASE 2, fix excised).  WR_PERIOD is"
    echo "--- clk_sdram cycles between 32-bit gfx-region SDRAM writes; the"
    echo "--- clock is 35.795455MHz, so 1536 cycles = 42.9us = ~93 KB/s."
    for wp in 24 96 384 1536 4096 9216; do
        sim 2 defeat "$wp" "sweep_$wp" || fail=1
        printf '    WR_PERIOD %-6s %-14s lost=%-4s post_issued=%s\n' \
            "$wp" "$(field "sweep_$wp" VERDICT)" \
            "$(field "sweep_$wp" lost)" "$(field "sweep_$wp" post_issued)"
    done
fi

[ "${PFRESET_KEEP:-0}" != "0" ] || rm -rf sim/build/pfslice sim/build/pfslice_defeat

if [ "$fail" != "0" ]; then
    echo "PFRESET-111 GATE: FAIL"
    exit 1
fi
echo "PFRESET-111 GATE: PASS"
