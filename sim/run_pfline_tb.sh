#!/usr/bin/env bash
# PFLINE gate: are the first pixels of each line this frame's data, or stale?
# Sweeps XSCROLL, because the device says the stale strip is 8 - (xscroll & 7)
# native pixels wide - so the WIDTH TRACKING SCROLL is itself a prediction the
# bench can confirm, not just a pass/fail.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IVERILOG_IMAGE:-hdlc/iverilog:latest}"
mkdir -p "$REPO/sim/build"
for XS in ${XSCROLLS:-0 2 3 5 6}; do
  docker run --rm -v "$REPO":/work -w /work "$IMAGE" bash -c "
    iverilog -g2012 -Ptb_pfline.XSCROLL=$XS -Ptb_pfline.GFX_LAT=${GFX_LAT:-6} -Ptb_pfline.GFX_LAT=${GFX_LAT:-6} -Pescape_pf.RP_OFFSET=${RP_OFF:-0} -Ptb_pfline.GFX_LAT=${GFX_LAT:-6} -o sim/build/tb_pfline.vvp \
      src/fpga/core/rtl/escape_pf.v sim/tb/tb_pfline.v && \
    timeout 300 vvp sim/build/tb_pfline.vvp" 2>&1 | grep -E "PFLINE"
done
