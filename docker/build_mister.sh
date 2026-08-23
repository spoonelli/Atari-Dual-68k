#!/usr/bin/env bash
# Compile the MiSTer (DE10-Nano) core with Quartus in Docker.
#
# Same container as docker/build.sh. Note that MiSTer officially targets
# Quartus 17.0.2 Standard; this image is 18.1 Lite, which is why
# src/mister/sys/ carries a pll_q18.qip (see docs/MISTER.md).
#
# Output: src/mister/output_files/Arcade-Escape.rbf
# Rename it to escape.rbf on the SD card - that is the name the .mra asks for.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="theypsilon/quartus-lite-c5:18.1"
PLATFORM="linux/amd64"

if [ ! -f "$REPO_ROOT/third_party/jt51/hdl/jt51_op.v" ]; then
  echo "!! Submodules are not checked out. Run:" >&2
  echo "   git submodule update --init --recursive" >&2
  exit 1
fi

echo ">> Compiling Arcade-Escape with Quartus ($IMAGE)..."
docker run --rm --platform "$PLATFORM" \
  -v "$REPO_ROOT":/work -w /work/src/mister \
  "$IMAGE" quartus_sh --flow compile Arcade-Escape

RBF="$REPO_ROOT/src/mister/output_files/Arcade-Escape.rbf"
if [ ! -f "$RBF" ]; then
  echo "!! Compile did not produce $RBF" >&2
  exit 1
fi
echo ">> Done: $RBF"
echo ">> Copy to /_Arcade/cores/escape.rbf on the MiSTer SD card,"
echo "   the .mra from src/mister/releases/ to /_Arcade/,"
echo "   and your own eprom.zip to /games/mame/."
