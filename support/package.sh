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
# NEVER includes ROM data: a guard fails the build if any *.rom would be packaged.
#
# Usage: ./support/package.sh <path/to/bitstream.rbf_r> [out.zip]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RBF="${1:?usage: package.sh <bitstream.rbf_r> [out.zip]}"
OUT="${2:-$REPO/output/AtariDual68k-pocket.zip}"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac

AUTHOR="spoonelli"
SHORT="eprom"                    # release identity (A1): installs as Cores/spoonelli.eprom
PLATFORM="eprom"                 # must match core.json platform_ids[0]
CORE_DIR="Cores/${AUTHOR}.${SHORT}"

test -f "$RBF" || { echo "!! bitstream not found: $RBF" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/$CORE_DIR" "$STAGE/Platforms/_images" "$STAGE/Assets/$PLATFORM/common"

# core definition files (repo root, per the official core template).
# CORE_FILES is the single source of truth: it drives both the copy loop and
# guard 4 below, so the two can never drift apart.
CORE_FILES="core.json audio.json data.json input.json interact.json variants.json video.json info.txt"
for f in $CORE_FILES; do
    cp "$REPO/$f" "$STAGE/$CORE_DIR/"
done
cp "$REPO/dist/icon.bin" "$STAGE/$CORE_DIR/"
cp "$RBF" "$STAGE/$CORE_DIR/bitstream.rbf_r"

# platform files
cp "$REPO/dist/platforms/$PLATFORM.json" "$STAGE/Platforms/"
cp "$REPO/dist/platforms/_images/$PLATFORM.bin" "$STAGE/Platforms/_images/"

# the ROM builder ships at the zip ROOT, deliberately outside Assets/ --
# Guard 2 asserts Assets/ holds exactly the placeholder, and root files are
# not merged onto the SD by users following the folder-copy instructions.
cp "$REPO/support/build_rom.py" "$STAGE/build_rom.py"

# Assets dir ships EMPTY (plus a note) -- ROMs are user-supplied, never distributed
cat > "$STAGE/Assets/$PLATFORM/common/PLACE_ROM_HERE.txt" <<'EOF'
Put your self-built atari_escape.rom in this folder, under exactly that name --
data.json declares it as a required slot and the Pocket asks for that filename.

Build it from your own verified dumps of the MAME 'eprom' set. The tool is
included at the top level of this zip (and in the project source at
support/build_rom.py):

  python3 build_rom.py /path/to/eprom.zip atari_escape.rom

then place atari_escape.rom in this folder.

Python 3 is the only requirement. Every chip is CRC32-checked against MAME's
known-good values; a wrong or incomplete set is refused rather than half-built.
See docs/ROMS.md. This project does not distribute ROMs.

High scores and operator settings are saved automatically to
  /Saves/eprom/common/atari_escape.sav
The Pocket creates that file on its own -- nothing to install. Delete it to
reset the machine to a factory-fresh EEPROM.
EOF

# ---------------------------------------------------------------- ROM guards
# The project rule is absolute: no ROM data in any package, ever. These four
# checks were each provoked deliberately (support/test_package_guards.sh runs
# the same provocations on demand) -- a guard nobody has tried is not a guard.
#
# Guard 1 is a REGRESSION TRIPWIRE, not an active check: no path in this script
# stages a .rom, so on an unmodified script it can never fire. It catches the
# specific regression of someone re-adding a `cp dist/assets/... -> Assets/`
# line. It is blind to ROM data under any other name -- and that blindness was
# not theoretical: with only guard 1 present, staging the real 2,228,224-byte
# atari_escape.rom as `gfxdata.bin` produced a release zip containing the whole
# ROM, byte-identical. Guards 2-4 exist because of that measurement. They
# constrain the ACTUAL output by content rather than by filename.
#
# Guard 1: no file named like a ROM, anywhere in the tree.
if find "$STAGE" -iname '*.rom' | grep -q .; then
    echo "!! REFUSING to package: ROM file found in staging tree" >&2
    exit 1
fi

# Guard 2: the Assets tree ships EXACTLY the placeholder, whatever it is called.
# This is where a ROM would land, and it is asserted by content, not by name.
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

# Guard 4: Cores/ and Platforms/ ship EXACTLY the expected manifest. Guards 2
# and 3 together still leave a gap -- a small ROM region (the 16 KB chars chip,
# say) dropped into Cores/ is neither in Assets/ nor over the size limit. The
# expected list is derived from CORE_FILES above, so adding a core definition
# file needs no change here.
EXPECTED="$( { for f in $CORE_FILES icon.bin bitstream.rbf_r; do echo "$CORE_DIR/$f"; done
               echo "Platforms/$PLATFORM.json"
               echo "Platforms/_images/$PLATFORM.bin"; } | sort )"
ACTUAL="$(cd "$STAGE" && find Cores Platforms -type f | sort)"
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "!! REFUSING to package: Cores//Platforms/ do not match the expected manifest." >&2
    echo "   unexpected or missing:" >&2
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL") | sed 's/^/     /' >&2
    exit 1
fi

# Guard 5: the platform image must be EXACTLY the text placeholder, by content.
# ARTWORK-113: the marquee art is under the same rule as ROM data - usable
# locally for testing, never distributed (docs/ARTWORK.md). It used to live in
# git history and was purged. Guards 3 and 4 do not stop it: the image is under
# the size limit and sits at an EXPECTED manifest path, so a copied-in marquee
# would package silently. This pins it by hash instead. If you are legitimately
# changing the placeholder art, update PLACEHOLDER_SHA256 in the same commit -
# that edit is the point at which someone has to think about what is shipping.
PLACEHOLDER_SHA256="4733b92befd0a72b16716c03144f6225dc36346fcb7500e6efb7bf0b8a9040ec"
IMG="$STAGE/Platforms/_images/$PLATFORM.bin"
IMG_SHA="$(shasum -a 256 < "$IMG" | cut -d' ' -f1)"
if [ "$IMG_SHA" != "$PLACEHOLDER_SHA256" ]; then
    echo "!! REFUSING to package: Platforms/_images/$PLATFORM.bin is not the" >&2
    echo "   distributable placeholder." >&2
    echo "     expected $PLACEHOLDER_SHA256" >&2
    echo "     found    $IMG_SHA" >&2
    if [ "$IMG_SHA" = "2557c131823270514f5f7dbc036b518327b8ad7d7c942ec103f0aa1637d9418c" ]; then
        echo "   That is the COPYRIGHTED MARQUEE ART. It must never ship." >&2
        echo "   See docs/ARTWORK.md - install it on the SD card, not here." >&2
    fi
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" Cores Platforms Assets build_rom.py )
echo "packaged: $OUT"
unzip -l "$OUT"
