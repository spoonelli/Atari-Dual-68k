#!/usr/bin/env bash
# Package a Pocket-ready release zip following Analogue's openFPGA SD layout:
#
#   Cores/<author>.<shortname>/   core defs + bitstream.rbf_r
#   Platforms/<platform_id>.json
#   Platforms/_images/<platform_id>.bin
#   Assets/<platform_id>/common/  (empty -- the user supplies their own ROM)
#
# Saves/<platform_id>/common/ is NOT packaged: the Pocket creates it itself the
# first time the core writes its EEPROM (see docs/EEPROM_SAVE.md). Shipping a
# save here would overwrite the owner's high scores on every update.
#
# NEVER includes ROM data: three guards below refuse to build if any reaches the
# staging tree. They are tested against deliberately broken inputs; see the
# comment above them for what each one actually constrains.
#
# Usage: ./support/package.sh <path/to/bitstream.rbf_r> [out.zip] [version]
#
# ---------------------------------------------------------------- releasing
# Cutting a GitHub Release (proposed scheme -- RC-113):
#
#   tag     v0.1.0-alpha        semver, "v" prefix, prerelease suffix.
#                               Sorts correctly, sorts BEFORE v0.1.0, and GitHub
#                               shows a "Pre-release" badge off the suffix alone.
#                               Next ones: v0.1.1-alpha, v0.2.0-beta, v1.0.0.
#   title   "v0.1.0-alpha - Escape from the Planet of the Robot Monsters"
#                               The tag alone tells a stranger nothing; lead with
#                               the version, then the game, because that is what
#                               a search lands on.
#   asset   AtariDual68k-Pocket-v0.1.0-alpha.zip
#                               ./support/package.sh <rbf> "" v0.1.0-alpha
#                               Never ship the internal build tag as the asset
#                               name -- "AtariDual68k-VSHAD3-16K-112.zip" means
#                               nothing on a Releases page.
#   body    docs/RELEASE_NOTES.md, which is written to work as the release-page
#           body: what it is, what you need, install, then limitations.
#   tick    "Set as a pre-release".
#
# Before tagging, confirm the on-screen build number in the running core matches
# the bitstream in the zip. That check exists because a build once shipped
# showing the wrong number.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RBF="${1:?usage: package.sh <bitstream.rbf_r> [out.zip] [version]}"
# RC-113: the default asset name has to survive being seen with no context, on
# a Releases page, by someone who has never heard of this project. Internal
# build tags like "VSHAD3-16K-112" do not. Pass a version as $3 to stamp it:
#   ./support/package.sh <rbf> "" v0.1.0-alpha
#     -> AtariDual68k-Pocket-v0.1.0-alpha.zip
VERSION="${3:-}"
if [ -n "$VERSION" ]; then
    DEFAULT_OUT="$REPO/output/AtariDual68k-Pocket-${VERSION}.zip"
else
    DEFAULT_OUT="$REPO/output/AtariDual68k-Pocket.zip"
fi
OUT="${2:-$DEFAULT_OUT}"
[ -n "$OUT" ] || OUT="$DEFAULT_OUT"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac

AUTHOR="spoonelli"
SHORT="ataridual68k"             # dev identity; release profile will ship spoonelli.eprom
PLATFORM="eprom"                 # must match core.json platform_ids[0]
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

High scores and operator settings are saved automatically to
  /Saves/eprom/common/atari_escape.sav
The Pocket creates that file on its own -- nothing to install. Delete it to
reset the machine to a factory-fresh EEPROM.
EOF

# ---------------------------------------------------------------- ROM guards
# RC-113: the *.rom name check below is a REGRESSION TRIPWIRE, not an active
# check -- no path in this script stages a .rom, so on an unmodified script it
# can never fire. (Proven: re-adding a `cp dist/assets/.../. -> Assets/` line,
# the exact regression it exists to catch, makes it fire and produce no zip.)
# It is also blind to a ROM under any other name. So it is backed by two checks
# that constrain the ACTUAL output rather than a filename:
#
#   1. Assets/ must contain exactly the placeholder note and nothing else.
#      This is where a ROM would land, and it is asserted by content, not name.
#   2. Nothing outside the bitstream may be large. A 2 MB ROM cannot hide in a
#      renamed file without tripping this.
#
# Guard 1: no file named like a ROM, anywhere in the tree.
if find "$STAGE" -iname '*.rom' | grep -q .; then
    echo "!! REFUSING to package: ROM file found in staging tree" >&2
    exit 1
fi

# Guard 2: the Assets tree ships EXACTLY the placeholder, whatever it is called.
ASSET_FILES="$(cd "$STAGE" && find "Assets" -type f | sort)"
if [ "$ASSET_FILES" != "Assets/$PLATFORM/common/PLACE_ROM_HERE.txt" ]; then
    echo "!! REFUSING to package: Assets/ must contain only the ROM placeholder." >&2
    echo "   found:" >&2
    echo "$ASSET_FILES" | sed 's/^/     /' >&2
    exit 1
fi

# Guard 3: nothing but the bitstream may be big. Catches ROM data smuggled in
# under a non-.rom name (the platform image is the largest legitimate asset).
MAXK=600
while IFS= read -r f; do
    case "$f" in "$STAGE/$CORE_DIR/bitstream.rbf_r") continue;; esac
    sz=$(( $(wc -c < "$f") / 1024 ))
    if [ "$sz" -gt "$MAXK" ]; then
        echo "!! REFUSING to package: ${f#$STAGE/} is ${sz} KB (limit ${MAXK} KB)." >&2
        echo "   Only the bitstream may exceed this. Is this ROM data?" >&2
        exit 1
    fi
done < <(find "$STAGE" -type f)

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" Cores Platforms Assets )
echo "packaged: $OUT"
unzip -l "$OUT"
