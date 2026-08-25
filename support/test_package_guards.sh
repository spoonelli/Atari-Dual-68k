#!/usr/bin/env bash
# Provoke every ROM guard in support/package.sh and assert it refuses.
#
# Why this exists: the project rule is that no ROM data may ever enter a
# package, and package.sh's original guard was a `find -iname '*.rom'` check
# that no code path could ever trigger. It was never provoked. When it finally
# was, the same 2,228,224-byte ROM renamed to `gfxdata.bin` sailed straight
# into the release zip. A guard nobody has tried is not a guard, so this script
# tries them -- and asserts the happy path still produces a zip, so a guard
# that refuses everything cannot pass either.
#
# No real ROM data is needed or used: the decoys are random bytes at ROM sizes.
#
# Usage: ./support/test_package_guards.sh [path/to/bitstream.rbf_r]
#   With no bitstream, a small dummy stands in (fine for every guard except the
#   MAXK size check, which does not depend on the bitstream's real size).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$REPO/support/package.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RBF="${1:-}"
if [ -z "$RBF" ]; then
    RBF="$TMP/bitstream.rbf_r"
    dd if=/dev/urandom of="$RBF" bs=1024 count=64 2>/dev/null
fi
test -f "$RBF" || { echo "!! bitstream not found: $RBF" >&2; exit 1; }

# Decoy ROM-sized payloads. Random bytes -- never real ROM data.
dd if=/dev/urandom of="$TMP/big.bin"   bs=1024 count=2176 2>/dev/null   # ~ a 2 MB image
dd if=/dev/urandom of="$TMP/small.bin" bs=1024 count=16   2>/dev/null   # ~ the chars chip

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }

# Run a package.sh variant built by injecting $2 (a shell line) just before the
# ROM guards. $3 = "refuse" or "package".
provoke() {
    desc="$1"; inject="$2"; want="$3"
    variant="$REPO/support/.guardtest_$$.sh"
    awk -v ins="$inject" '/^# ---------------------------------------------------------------- ROM guards/ && !done {print ins; done=1} {print}' "$PKG" > "$variant"
    chmod +x "$variant"
    rm -f "$TMP/out.zip"
    set +e
    out="$(bash "$variant" "$RBF" "$TMP/out.zip" 2>&1)"; rc=$?
    set -e
    rm -f "$variant"
    if [ -f "$TMP/out.zip" ]; then got="package"; else got="refuse"; fi
    if [ "$got" = "$want" ] && { [ "$want" = "package" ] || [ "$rc" -ne 0 ]; }; then
        ok "$desc -> $got"
    else
        bad "$desc -> $got (wanted $want, exit $rc)"
        echo "$out" | sed 's/^/        /'
    fi
    rm -f "$TMP/out.zip"
}

echo "=== package.sh guard provocation ==="
# The happy path must still work, or every "refuse" below is meaningless.
provoke "control: unmodified script"                                  ":" package
provoke "guard 1: payload staged as *.rom in Assets/" \
        'cp "'"$TMP"'/big.bin" "$STAGE/Assets/$PLATFORM/common/atari_escape.rom"' refuse
provoke "guard 2: payload renamed .bin in Assets/" \
        'cp "'"$TMP"'/big.bin" "$STAGE/Assets/$PLATFORM/common/gfxdata.bin"' refuse
provoke "guard 3: oversized payload in Cores/" \
        'cp "'"$TMP"'/big.bin" "$STAGE/$CORE_DIR/tables.dat"' refuse
provoke "guard 3: oversized payload in Platforms/" \
        'cp "'"$TMP"'/big.bin" "$STAGE/Platforms/_images/extra.bin"' refuse
provoke "guard 4: small payload hidden in Cores/" \
        'cp "'"$TMP"'/small.bin" "$STAGE/$CORE_DIR/chars.dat"' refuse
provoke "guard 4: a core definition file gone missing" \
        'rm -f "$STAGE/$CORE_DIR/video.json"' refuse
# ARTWORK-113: the marquee is under the ROM rule. Guards 3 and 4 both pass it
# (under the size limit, at an expected manifest path), so only guard 5 stands
# between the real art and a release zip. Provoke it with the ACTUAL artwork
# when it is present, and with a same-sized stand-in when it is not, so this
# still proves the guard fires on a machine that does not hold the art.
ART="/Users/lloyd/Documents/Lloyd Projects/artwork/eprom.bin"
if [ -f "$ART" ]; then
    provoke "guard 5: the real marquee art as the platform image" \
            'cp "'"$ART"'" "$STAGE/Platforms/_images/$PLATFORM.bin"' refuse
else
    echo "  SKIP  guard 5 with real art (not present on this machine)"
fi
# Content-substitution control: any non-placeholder image must be refused, not
# merely the one known bad file. A hash guard that only knew one hash would be
# a blocklist, and blocklists miss art v6.
provoke "guard 5: any non-placeholder image (unknown art)" \
        'dd if=/dev/urandom of="$STAGE/Platforms/_images/$PLATFORM.bin" bs=171930 count=1 2>/dev/null' refuse

echo
echo "$pass passed, $fail failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
