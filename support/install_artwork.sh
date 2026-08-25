#!/usr/bin/env bash
# Install the real platform marquee onto a Pocket SD card for LOCAL TESTING.
#
# The artwork is treated exactly like ROM data: it lives outside this
# repository, it is never committed, and it is never packaged (package.sh
# guard 5 refuses a zip that carries it). See docs/ARTWORK.md.
#
# Usage: ./support/install_artwork.sh /Volumes/POCKET [path/to/eprom.bin]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST_ROOT="${1:?usage: install_artwork.sh <sd-card-root> [artwork.bin]}"
ART="${2:-/Users/lloyd/Documents/Lloyd Projects/artwork/eprom.bin}"
PLATFORM="eprom"
ART_SHA256="2557c131823270514f5f7dbc036b518327b8ad7d7c942ec103f0aa1637d9418c"
EXPECT_BYTES=171930

# Refuse to write into the working tree. This is the whole point of the script:
# the one way this art gets distributed is by landing somewhere git can see it.
# Compare resolved paths so a symlink or a relative argument cannot slip past.
DEST_ABS="$(cd "$DEST_ROOT" 2>/dev/null && pwd -P || true)"
if [ -z "$DEST_ABS" ]; then
    echo "!! destination does not exist: $DEST_ROOT" >&2; exit 1
fi
REPO_ABS="$(cd "$REPO" && pwd -P)"
case "$DEST_ABS/" in
    "$REPO_ABS"/*)
        echo "!! REFUSING: $DEST_ABS is inside the repository ($REPO_ABS)." >&2
        echo "   The marquee must never enter the working tree - it would be" >&2
        echo "   committable and packageable. Point this at the SD card." >&2
        exit 1;;
esac

[ -f "$ART" ] || { echo "!! artwork not found: $ART" >&2
                   echo "   See docs/ARTWORK.md." >&2; exit 1; }

# Verify the SOURCE before copying: installing the wrong file onto the card is
# cheap to do and confusing to debug (a placeholder looks like "it didn't work").
sz=$(wc -c < "$ART" | tr -d ' ')
sha=$(shasum -a 256 < "$ART" | cut -d' ' -f1)
if [ "$sz" != "$EXPECT_BYTES" ] || [ "$sha" != "$ART_SHA256" ]; then
    echo "!! artwork does not match the expected image." >&2
    echo "   expected $EXPECT_BYTES bytes, sha256 $ART_SHA256" >&2
    echo "   found    $sz bytes, sha256 $sha" >&2
    exit 1
fi

DEST_DIR="$DEST_ABS/Platforms/_images"
[ -d "$DEST_DIR" ] || { echo "!! $DEST_DIR not found - install the core zip first." >&2; exit 1; }

cp "$ART" "$DEST_DIR/$PLATFORM.bin"

# Verify what actually landed, rather than trusting cp's exit code: this is
# removable media and a short write is a real failure mode.
got=$(shasum -a 256 < "$DEST_DIR/$PLATFORM.bin" | cut -d' ' -f1)
if [ "$got" != "$ART_SHA256" ]; then
    echo "!! copy verified BAD: $DEST_DIR/$PLATFORM.bin is sha256 $got" >&2
    exit 1
fi
echo "installed marquee -> $DEST_DIR/$PLATFORM.bin (sha256 verified)"
echo "reminder: local testing only; this must never be committed or packaged."
