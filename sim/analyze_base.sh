#!/usr/bin/env bash
# Baseline analysis of the Atari System 1 RTL under native GHDL simulation.
# No Quartus required. Reports which modules elaborate cleanly.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work -w /work "$IMAGE" \
     bash /work/sim/_analyze_in_container.sh
