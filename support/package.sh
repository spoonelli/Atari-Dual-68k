#!/usr/bin/env bash
# Package a Pocket-ready release zip following Analogue's openFPGA SD layout:
#
#   Cores/<author>.<shortname>/   core defs + bitstream.rbf_r
#   Platforms/<platform_id>.json
#   Platforms/_images/<platform_id>.bin
#   Assets/<platform_id>/common/  (empty -- the user supplies their own ROM)
#   Assets/<platform_id>/<author>.<shortname>/  instance JSONs, one per set
#                                 (set 2 under _alternatives/, jotego's layout)
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
# POCKETVAR-182: VARIANT picks the Pocket core: eprom (Escape, the default -
# release identity A1, installs as Cores/spoonelli.eprom), klaxp (Klax
# prototypes) or guts (Guts n' Glory). The bitstream must be the matching CI
# variant build (build.yml 'variant' input).
VARIANT="${VARIANT:-eprom}"
case "$VARIANT" in eprom|klaxp|guts) ;; *) echo "!! unknown VARIANT '$VARIANT' (eprom|klaxp|guts)" >&2; exit 1;; esac
SHORT="$VARIANT"
PLATFORM="$VARIANT"              # must match core.json platform_ids[0]
CORE_DIR="Cores/${AUTHOR}.${SHORT}"
# Escape's definition files live at the repo root (the official core template);
# the other cores' under dist/cores/<short>/.
if [ "$VARIANT" = eprom ]; then DEFDIR="$REPO"; else DEFDIR="$REPO/dist/cores/$SHORT"; fi

test -f "$RBF" || { echo "!! bitstream not found: $RBF" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

INST_DIR="Assets/$PLATFORM/${AUTHOR}.${SHORT}"
mkdir -p "$STAGE/$CORE_DIR" "$STAGE/Platforms/_images" "$STAGE/Assets/$PLATFORM/common"

# core definition files (repo root, per the official core template).
# CORE_FILES is the single source of truth: it drives both the copy loop and
# guard 4 below, so the two can never drift apart.
CORE_FILES="core.json audio.json data.json input.json interact.json variants.json video.json info.txt"
for f in $CORE_FILES; do
    cp "$DEFDIR/$f" "$STAGE/$CORE_DIR/"
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

# licence texts MUST accompany the binary: GPL-3.0 requires a copy of the
# licence with conveyed object code, and psram.sv's MIT requires its notice
# accompany all copies including binaries (NOTICE.md is the inventory that
# points at each vendored header).
cp "$REPO/LICENSE"   "$STAGE/LICENSE.txt"
cp "$REPO/NOTICE.md" "$STAGE/NOTICE.md"

# POCKETSET-175: one instance JSON per romset. The Pocket's launch browser
# lists these (set 2 inside _alternatives/, the jotego/MiSTer convention);
# each names the ROM file in common/ and its own save file. INSTANCES is the
# single source of truth for the copy and for guard 2.
case "$VARIANT" in
  eprom) INST_SRC="$REPO/dist/instances"
         INSTANCES="Escape from the Planet of the Robot Monsters (set 1).json
_alternatives/Escape from the Planet of the Robot Monsters (set 2).json" ;;
  klaxp) INST_SRC="$REPO/dist/instances/klaxp"
         INSTANCES="Klax (prototype set 1).json
_alternatives/Klax (prototype set 2).json" ;;
  guts)  INST_SRC="$REPO/dist/instances/guts"
         INSTANCES="Guts n' Glory (prototype).json" ;;
esac
while IFS= read -r f; do
    mkdir -p "$(dirname "$STAGE/$INST_DIR/$f")"
    cp "$INST_SRC/$f" "$STAGE/$INST_DIR/$f"
done <<< "$INSTANCES"

# Assets/common ships EMPTY (plus a note) -- ROMs are user-supplied, never distributed
if [ "$VARIANT" = eprom ]; then
cat > "$STAGE/Assets/$PLATFORM/common/PLACE_ROM_HERE.txt" <<'EOF'
Put your self-built ROM image(s) in this folder, under exactly these names:

  atari_escape.rom    Escape set 1 (MAME 'eprom')
  atari_escape2.rom   Escape set 2 (MAME 'eprom2', optional)

When you start the core, the Pocket lists the games: set 1 at the top, set 2
inside the _alternatives folder. Each entry loads the matching file above.

Build them from your own verified dumps. The tool is included at the top
level of this zip (and in the project source at support/build_rom.py):

  python3 build_rom.py /path/to/eprom.zip      (a merged set builds BOTH images)
  python3 build_rom.py /path/to/eprom2.zip     (a split set 2 borrows from eprom.zip beside it)

With no --set the tool builds every set it finds; --set eprom or --set
eprom2 builds just one. Non-merged, split and merged MAME sets all work.

It detects the set and writes atari_escape.rom or atari_escape2.rom next to
the script -- move the file(s) into this folder, then copy the package's
folders onto the SD card as usual.

Python 3 is the only requirement. Every chip is CRC32-checked against MAME's
known-good values; a wrong or incomplete set is refused rather than half-built.
See docs/ROMS.md. This project does not distribute ROMs.

High scores and operator settings are saved automatically, per set, to
  /Saves/eprom/common/atari_escape.sav    (set 1)
  /Saves/eprom/common/atari_escape2.sav   (set 2)
The Pocket creates these on its own -- nothing to install. Delete one to
reset that set to a factory-fresh EEPROM.
EOF
elif [ "$VARIANT" = klaxp ]; then
cat > "$STAGE/Assets/$PLATFORM/common/PLACE_ROM_HERE.txt" <<'EOF'
Put your self-built ROM image(s) in this folder, under exactly these names:

  klaxp1.rom   Klax (prototype set 1)   (MAME 'klaxp1')
  klaxp2.rom   Klax (prototype set 2)   (MAME 'klaxp2', optional)

When you start the core, the Pocket lists the sets: set 1 at the top, set 2
inside the _alternatives folder. Each entry loads the matching file above.

Build them from your own verified dumps with the tool at the top level of
this zip (also support/build_rom.py in the project source):

  python3 build_rom.py /path/to/klax.zip      (builds BOTH klaxp1.rom and klaxp2.rom)

A merged klax.zip holds both prototypes in klaxp1/ and klaxp2/ subfolders;
split klaxp1.zip / klaxp2.zip borrow the shared chips from klax.zip next to
them. --set klaxp1 or --set klaxp2 builds just one. Every
chip is CRC32-checked; a wrong or incomplete set is refused. This project does
not distribute ROMs.

High scores and settings save per set to /Saves/klaxp/common/klaxp1.sav and
klaxp2.sav - the Pocket creates them.
EOF
else
cat > "$STAGE/Assets/$PLATFORM/common/PLACE_ROM_HERE.txt" <<'EOF'
Put your self-built ROM image in this folder, under exactly this name:

  guts.rom   Guts n' Glory (prototype)   (MAME 'guts')

Build it from your own verified dumps with the tool at the top level of this
zip (also support/build_rom.py in the project source):

  python3 build_rom.py /path/to/guts.zip

Every chip is CRC32-checked; a wrong or incomplete set is refused. This
project does not distribute ROMs.

High scores and settings save to /Saves/guts/common/guts.sav - the Pocket
creates it.
EOF
fi

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

# Guard 2: the Assets tree ships EXACTLY the placeholder plus the instance
# JSONs, whatever they are called. This is where a ROM would land, and it is
# asserted by manifest AND content: each instance must parse as an APF
# instance with only filename references (POCKETSET-175), so a renamed binary
# cannot pass as one.
ASSET_FILES="$(cd "$STAGE" && find "Assets" -type f | sort)"
ASSET_EXPECTED="$( { echo "Assets/$PLATFORM/common/PLACE_ROM_HERE.txt"
                     while IFS= read -r f; do echo "$INST_DIR/$f"; done <<< "$INSTANCES"; } | sort )"
if [ "$ASSET_FILES" != "$ASSET_EXPECTED" ]; then
    echo "!! REFUSING to package: Assets/ must contain only the ROM placeholder" >&2
    echo "   and the instance JSONs." >&2
    diff <(printf '%s\n' "$ASSET_EXPECTED") <(printf '%s\n' "$ASSET_FILES") | sed 's/^/     /' >&2
    exit 1
fi
while IFS= read -r f; do
    if ! python3 -I - "$STAGE/$INST_DIR/$f" <<'PYCHECK'
import json, sys
p = sys.argv[1]
if len(open(p, "rb").read()) > 2048: sys.exit("too large for an instance JSON")
j = json.load(open(p, encoding="ascii"))
i = j["instance"]
assert set(j) == {"instance"} and i["magic"] == "APF_VER_1"
assert set(i) <= {"magic", "data_path", "data_slots"}
for d in i["data_slots"]:
    assert set(d) == {"id", "filename"} and d["filename"].endswith((".rom", ".sav"))
PYCHECK
    then
        echo "!! REFUSING to package: $INST_DIR/$f is not a plain instance JSON." >&2
        exit 1
    fi
done <<< "$INSTANCES"

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
case "$PLATFORM" in   # POCKETVAR-182: one original text placeholder per platform
  eprom) PLACEHOLDER_SHA256="4733b92befd0a72b16716c03144f6225dc36346fcb7500e6efb7bf0b8a9040ec" ;;
  klaxp) PLACEHOLDER_SHA256="abc6f9703d18dda27a7bc2ad81190f61a4ec73294b0748392570e0e9e8d5b104" ;;
  guts)  PLACEHOLDER_SHA256="b683016f51b14abe2509631db16a132390dd4f2fde883560235f7a79835906ef" ;;
esac
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

# Guard 6 (BUILDNUM-183): the on-screen build number. The Developer HUD shows
# only BUILD_ID's LOW TWO HEX DIGITS (core_top.v). The v0.2.0 release candidate
# carried 16'h3431 with a comment saying "shows '41'" - the screen read 31.
# (a) always: the digits BUILD_ID will show must equal the "shows 'NN'" claim in
#     its own comment, so the value and its label can never disagree again;
# (b) with EXPECT_BUILD=NN: they must equal the build being packaged.
# Checked against the working tree, so package from the commit that built the
# bitstream (the CI artifact's head).
BID_LINE="$(grep -E "localparam \[15:0\] BUILD_ID *= *16'h[0-9A-Fa-f]{4}" "$REPO/src/fpga/core/core_top.v" | head -1)"
BID_HEX="$(printf '%s' "$BID_LINE" | sed -E "s/.*16'h([0-9A-Fa-f]{4}).*/\1/")"
BID_SHOWN="$(printf '%s' "$BID_HEX" | cut -c3-4 | tr 'a-f' 'A-F')"
BID_CLAIM="$(printf '%s' "$BID_LINE" | sed -nE "s/.*shows '([0-9A-Fa-f]{2})'.*/\1/p" | tr 'a-f' 'A-F')"
if [ -z "$BID_LINE" ] || [ -z "$BID_CLAIM" ]; then
    echo "!! REFUSING to package: cannot read BUILD_ID and its \"shows 'NN'\" comment in core_top.v" >&2
    exit 1
fi
if [ "$BID_SHOWN" != "$BID_CLAIM" ]; then
    echo "!! REFUSING to package: BUILD_ID 16'h$BID_HEX shows '$BID_SHOWN' on the HUD," >&2
    echo "   but its comment says '$BID_CLAIM'. Only the low two hex digits are shown:" >&2
    echo "   build NN is 16'h00NN." >&2
    exit 1
fi
if [ -n "${EXPECT_BUILD:-}" ] && [ "$BID_SHOWN" != "$(printf '%s' "$EXPECT_BUILD" | tr 'a-f' 'A-F')" ]; then
    echo "!! REFUSING to package: the HUD will show '$BID_SHOWN', not build $EXPECT_BUILD." >&2
    exit 1
fi
echo "HUD build number: $BID_SHOWN${EXPECT_BUILD:+ (matches EXPECT_BUILD)}"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" Cores Platforms Assets build_rom.py LICENSE.txt NOTICE.md )
echo "packaged: $OUT"
unzip -l "$OUT"
