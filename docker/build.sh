#!/usr/bin/env bash
# Compile the core locally with Quartus in Docker (Quartus can't run on macOS).
# First run builds the Quartus image (large/slow under x86 emulation); it is then cached.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="atari-dual-68k-quartus:18.1"
PLATFORM="linux/amd64"

# 1. Build the Quartus image (Docker reuses cached layers; the ~3 GB download layer
#    only runs the first time). Safe to run every time.
echo ">> Building/refreshing Quartus Lite 18.1 image..."
docker build --platform "$PLATFORM" -t "$IMAGE" "$REPO_ROOT/docker"

# 2. Compile ap_core (revision defined in src/fpga/ap_core.qsf)
echo ">> Compiling ap_core with Quartus..."
docker run --rm --platform "$PLATFORM" \
  -v "$REPO_ROOT":/work -w /work/src/fpga \
  "$IMAGE" quartus_sh --flow compile ap_core

# 3. Bit-reverse .rbf -> .rbf_r for the Pocket loader (host python3)
RBF="$REPO_ROOT/src/fpga/output_files/ap_core.rbf"
OUT="$REPO_ROOT/output/bitstream.rbf_r"
if [ ! -f "$RBF" ]; then
  echo "!! Compile did not produce $RBF" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
python3 "$REPO_ROOT/support/reverse_bits.py" "$RBF" "$OUT"
echo ">> Done. Bitstream ready: $OUT"
