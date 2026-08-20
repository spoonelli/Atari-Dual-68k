#!/usr/bin/env bash
# Package a Pocket-ready release zip following Analogue's openFPGA SD layout:
#
#   Cores/<author>.<shortname>/   core defs + bitstream.rbf_r
#   Platforms/<platform_id>.json
#   Platforms/_images/<platform_id>.bin
#   Assets/<platform_id>/common/  (empty -- the user supplies their own ROM)
#
# NEVER includes ROM data: a guard fails the build if any *.rom would be packaged.
#
# Usage: ./support/package.sh <path/to/bitstream.rbf_r> [out.zip]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RBF="${1:?usage: package.sh <bitstream.rbf_r> [out.zip]}"
OUT="${2:-$REPO/output/AtariDual68k-pocket.zip}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac

AUTHOR="spoonelli"
SHORT="ataridual68k"             # dev identity; release profile will ship spoonelli.eprom
PLATFORM="atari_escape"          # must match core.json platform_ids[0]
CORE_DIR="Cores/${AUTHOR}.${SHORT}"

test -f "$RBF" || { echo "!! bitstream not found: $RBF" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$CORE_DIR" "$STAGE/Platforms/_images" "$STAGE/Assets/$PLATFORM/common"

# core definition files (repo root, per the official core template)
for f in core.json audio.json data.json input.json interact.json variants.json video.json info.txt; do
    cp "$REPO/$f" "$STAGE/$CORE_DIR/"
done
cp "$REPO/dist/icon.bin" "$STAGE/$CORE_DIR/"
cp "$RBF" "$STAGE/$CORE_DIR/bitstream.rbf_r"

# platform files
cp "$REPO/dist/platforms/$PLATFORM.json" "$STAGE/Platforms/"
cp "$REPO/dist/platforms/_images/$PLATFORM.bin" "$STAGE/Platforms/_images/"

# Assets dir ships EMPTY (plus a note) -- ROMs are user-supplied, never distributed
cat > "$STAGE/Assets/$PLATFORM/common/PLACE_ROM_HERE.txt" <<'EOF'
Put your self-built atari_escape.rom in this folder.
Build it from your own verified dumps:
  python3 support/build_rom.py /path/to/eprom ./atari_escape.rom
This project does not distribute ROMs.
EOF

# guard: refuse to package any ROM data
if find "$STAGE" -iname '*.rom' | grep -q .; then
    echo "!! REFUSING to package: ROM file found in staging tree" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" Cores Platforms Assets )
echo "packaged: $OUT"
unzip -l "$OUT"
