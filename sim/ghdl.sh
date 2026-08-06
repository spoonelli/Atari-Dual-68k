#!/usr/bin/env bash
# Run GHDL from the Docker image with the repo mounted at /work.
# GHDL is light enough to run under emulation on Apple Silicon (unlike Quartus).
# Usage: ./sim/ghdl.sh <ghdl args...>
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="ghdl/ghdl:ubuntu20-mcode"
exec docker run --rm --platform linux/amd64 -v "$REPO_ROOT":/work -w /work "$IMAGE" ghdl "$@"
