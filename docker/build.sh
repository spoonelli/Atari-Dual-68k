#!/usr/bin/env bash
# Compile the core with Quartus in Docker, using the community Quartus Lite 18.1 +
# Cyclone V image (theypsilon/quartus-lite-c5:18.1). On Apple Silicon this runs under
# x86 emulation, which can crash quartus_map during synthesis — the reliable build is
# CI (.github/workflows/build.yml) on a native-x86 runner. This script is for machines
# where the container runs natively (x86 Linux) or to try locally.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="theypsilon/quartus-lite-c5:18.1"
PLATFORM="linux/amd64"

echo ">> Compiling ap_core with Quartus ($IMAGE)..."
docker run --rm --platform "$PLATFORM" \
  -v "$REPO_ROOT":/work -w /work/src/fpga \
  "$IMAGE" quartus_sh --flow compile ap_core

RBF="$REPO_ROOT/src/fpga/output_files/ap_core.rbf"
OUT="$REPO_ROOT/output/bitstream.rbf_r"
if [ ! -f "$RBF" ]; then
  echo "!! Compile did not produce $RBF" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
python3 "$REPO_ROOT/support/reverse_bits.py" "$RBF" "$OUT"
echo ">> Done. Bitstream ready: $OUT"
