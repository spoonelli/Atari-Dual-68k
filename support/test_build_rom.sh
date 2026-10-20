#!/usr/bin/env bash
# Exercise support/build_rom.py the way users run it (BUILDROM-181): default
# output names, --set before/after the romset, merged / split / non-merged
# MAME sets and folders. Needs YOUR OWN dumps - no ROM data is in this repo:
#   EPROM_ZIP  a MERGED MAME eprom.zip (set 2 in an eprom2/ subfolder)
#   EPROM_DIR  optional: a folder of set-1 chips with an eprom2/ subfolder
#   KLAX_ZIP   optional: a MERGED MAME klax.zip (klaxp1/ and klaxp2/ subfolders)
#   KLAX_DIR   optional: the same as a folder
# Each set-2 build must be byte-identical to every other set-2 build, each
# set-1 build to every other set-1 build, and nothing else may be written.
# A run builds split and non-merged zips from the merged one in a temp dir.
#
# Usage: EPROM_ZIP=~/Downloads/eprom.zip [EPROM_DIR=~/Downloads/eprom] ./support/test_build_rom.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
: "${EPROM_ZIP:?set EPROM_ZIP to your own merged MAME eprom.zip}"
abspath() { case "$1" in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac; }
EPROM_ZIP="$(abspath "$EPROM_ZIP")"
[ -n "${EPROM_DIR:-}" ] && EPROM_DIR="$(abspath "$EPROM_DIR")"
[ -n "${KLAX_ZIP:-}" ] && KLAX_ZIP="$(abspath "$KLAX_ZIP")"
[ -n "${KLAX_DIR:-}" ] && KLAX_DIR="$(abspath "$KLAX_DIR")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp "$REPO/support/build_rom.py" "$T/"
python3 -I - "$EPROM_ZIP" "$T" <<'PY'
import sys, zipfile, os
src, t = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(src)
clone = [n for n in z.namelist() if n.startswith("eprom2/") and not n.endswith("/")]
if not clone: sys.exit("EPROM_ZIP is not a merged set (no eprom2/ subfolder)")
os.makedirs(f"{t}/split", exist_ok=True)
with zipfile.ZipFile(f"{t}/split/eprom2.zip", "w") as s:            # split clone zip
    for n in clone: s.writestr(n.split("/", 1)[1], z.read(n))
with zipfile.ZipFile(f"{t}/split/eprom.zip", "w") as p:             # its parent
    for n in z.namelist():
        if "/" not in n: p.writestr(n, z.read(n))
own = {n.split("/", 1)[1] for n in clone}
with zipfile.ZipFile(f"{t}/eprom2_nonmerged.zip", "w") as m:        # non-merged clone
    for n in clone: m.writestr(n.split("/", 1)[1], z.read(n))
    for n in z.namelist():
        if "/" not in n and n not in own and not n.startswith("136069-3") and not n.startswith("136069-4") \
           and n not in ("136069-2032.50k", "136069-2033.40k", "136069-2034.10u", "136069-2035.10s"):
            m.writestr(n, z.read(n))
PY
fail=0; declare -a H1 H2
HASHES="$T/hashes.txt"; : > "$HASHES"
run() {  # desc, set(1|2), args...
    local desc="$1" want="$2"; shift 2
    # start each case clean: only the script and the test zips may be present
    ( cd "$T" && for x in * .[!.]*; do case "$x" in build_rom.py|split|eprom2_nonmerged.zip|ksplit|hashes.txt|'.[!.]*'|'*') ;; *) rm -rf -- "./$x" ;; esac; done )
    ( cd "$T" && python3 -I build_rom.py "$@" >/dev/null 2>&1 ) || true
    local f; [ "$want" = 1 ] && f=atari_escape.rom || f=atari_escape2.rom
    local stray; stray="$(cd "$T" && ls | grep -v -E '^(build_rom.py|split|eprom2_nonmerged.zip|ksplit|hashes.txt|atari_escape2?\.rom|klaxp[12]\.rom|guts\.rom)$' | tr '\n' ' ' || true)"
    if [ ! -f "$T/$f" ] || [ -n "$stray" ]; then echo "  FAIL  $desc (no $f${stray:+; stray: $stray})"; fail=1; return; fi
    local h; h="$(shasum "$T/$f" | cut -c1-16)"
    if [ "$want" = 1 ]; then H1+=("$h"); else H2+=("$h"); fi
    echo "  ok    $desc -> $f $h"
}
echo "=== build_rom.py invocation matrix ==="
run "merged, plain"               1 "$EPROM_ZIP"
run "merged, --set eprom2 after"  2 "$EPROM_ZIP" --set eprom2
run "merged, --set eprom2 before" 2 --set eprom2 "$EPROM_ZIP"
run "split eprom2.zip"            2 split/eprom2.zip
run "non-merged eprom2.zip"       2 eprom2_nonmerged.zip
if [ -n "${EPROM_DIR:-}" ]; then
    run "folder, --set eprom2"    2 "$EPROM_DIR" --set eprom2
    run "clone folder"            2 "$EPROM_DIR/eprom2"
    run "parent folder, plain"    1 "$EPROM_DIR"
fi
# BUILDROM-184: Klax prototypes - merged zip/folder (shared chips live only
# under klaxp1/), no --set builds both, --set klaxp2 borrows from the sibling,
# and a split klaxp2.zip next to klax.zip. Every klaxp1 image identical, every
# klaxp2 image identical.
krun() {  # desc, expected files (space-separated), args...
    local desc="$1" files="$2"; shift 2
    ( cd "$T" && for x in * .[!.]*; do case "$x" in build_rom.py|split|eprom2_nonmerged.zip|ksplit|hashes.txt|'.[!.]*'|'*') ;; *) rm -rf -- "./$x" ;; esac; done )
    ( cd "$T" && python3 -I build_rom.py "$@" >/dev/null 2>&1 ) || true
    local ok=1 f
    for f in $files; do
        if [ -f "$T/$f" ]; then echo "${f%.rom} $(shasum "$T/$f" | cut -c1-16)" >> "$HASHES"; else ok=0; fi
    done
    local stray; stray="$(cd "$T" && ls | grep -v -E '^(build_rom.py|split|eprom2_nonmerged.zip|ksplit|hashes.txt|klaxp[12]\.rom)$' | tr '\n' ' ' || true)"
    for f in $files; do stray="$(printf '%s' "$stray" | sed "s/$f //")"; done
    if [ "$ok" = 1 ] && [ -z "$(printf '%s' "$stray" | tr -d ' ')" ]; then echo "  ok    $desc -> $files"
    else echo "  FAIL  $desc (want $files${stray:+; stray: $stray})"; fail=1; fi
}
if [ -n "${KLAX_ZIP:-}" ]; then
    python3 -I - "$KLAX_ZIP" "$T" <<'PY'
import sys, zipfile, os
src, t = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(src)
own = [n for n in z.namelist() if n.startswith("klaxp2/") and not n.endswith("/")]
if not own: sys.exit("KLAX_ZIP is not a merged klax set (no klaxp2/)")
os.makedirs(f"{t}/ksplit", exist_ok=True)
with zipfile.ZipFile(f"{t}/ksplit/klaxp2.zip", "w") as s:      # split clone: its two program chips
    for n in own: s.writestr(n.split("/", 1)[1], z.read(n))
os.symlink(os.path.abspath(src), f"{t}/ksplit/klax.zip")          # its parent beside it
PY
    krun "klax merged zip, no --set (both)"   "klaxp1.rom klaxp2.rom" "$KLAX_ZIP"
    krun "klax merged zip, --set klaxp2"      "klaxp2.rom"            "$KLAX_ZIP" --set klaxp2
    krun "klax merged zip, --set klaxp1"      "klaxp1.rom"            --set klaxp1 "$KLAX_ZIP"
    krun "split klaxp2.zip beside klax.zip"   "klaxp2.rom"            ksplit/klaxp2.zip
fi
if [ -n "${KLAX_DIR:-}" ]; then
    krun "klax folder, no --set (both)"       "klaxp1.rom klaxp2.rom" "$KLAX_DIR"
    krun "klax folder, --set klaxp2"          "klaxp2.rom"            "$KLAX_DIR" --set klaxp2
    krun "klaxp2 clone folder"                "klaxp2.rom"            "$KLAX_DIR/klaxp2"
fi
for k in klaxp1 klaxp2; do
    [ "$(awk -v k=$k '$1==k{print $2}' "$HASHES" | sort -u | grep -c .)" -le 1 ] || { echo "  FAIL  $k images differ"; fail=1; }
done
# ${ARR[@]+...}: macOS bash 3.2 treats an empty array as unbound under set -u
[ "$(printf '%s\n' ${H1[@]+"${H1[@]}"} | sort -u | grep -c .)" -le 1 ] || { echo "  FAIL  set-1 images differ"; fail=1; }
[ "$(printf '%s\n' ${H2[@]+"${H2[@]}"} | sort -u | grep -c .)" -le 1 ] || { echo "  FAIL  set-2 images differ"; fail=1; }
[ "$fail" = 0 ] && echo "BUILD_ROM PASS" || { echo "BUILD_ROM FAIL"; exit 1; }
