#!/usr/bin/env python3
"""Generate the MiSTer Downloader custom database for this core.

Usage: gen_mister_db.py <mister-release-dir> <release-tag> [out.json.zip]

Reads the staged release files (the dated .rbf and the .mra), computes
md5/size, and emits ataridual68k_db.json.zip in Downloader db format v1.
File URLs point at the named release tag's individual assets (GitHub
replaces spaces in asset names with dots - the db's path key, not the URL,
decides the on-SD filename). The db itself is published under the fixed
rolling tag `mister-db`, so the user's downloader.ini URL never changes:

  [spoonelli/ataridual68k]
  db_url = 'https://github.com/spoonelli/Atari-Dual-68k/releases/download/mister-db/ataridual68k_db.json.zip'

DB_ID is frozen forever; changing it duplicates installs.
"""
import hashlib, json, os, sys, time, zipfile, urllib.parse

DB_ID = "spoonelli/ataridual68k"
REPO  = "spoonelli/Atari-Dual-68k"
# The MiSTer convention: files are served from the distribution repo's committed
# releases/ folder (raw URLs, percent-encoded).  DB_URLS=release-assets restores
# the pre-2026-08-30 behaviour of pointing at this repo's release assets.
DIST  = "spoonelli/Arcade-Escape_MiSTer"

def main() -> int:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    stage, tag = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else "ataridual68k_db.json.zip"

    files = {}
    for name in sorted(os.listdir(stage)):
        if not (name.endswith(".rbf") or name.endswith(".mra")):
            continue
        p = os.path.join(stage, name)
        data = open(p, "rb").read()
        sd_path = ("_Arcade/cores/" + name) if name.endswith(".rbf") else ("_Arcade/" + name)
        # GitHub asset-name normalization: spaces become dots, parentheses
        # and brackets are dropped (verified against a live release; if a
        # future filename uses other punctuation, re-verify with
        # `gh release view <tag> --json assets`).
        asset = name.replace(" ", ".")
        for ch in "()[]":
            asset = asset.replace(ch, "")
        files[sd_path] = {
            "hash": hashlib.md5(data).hexdigest(),
            "size": len(data),
            "url": (f"https://github.com/{REPO}/releases/download/{tag}/{asset}"
                    if os.environ.get("DB_URLS") == "release-assets" else
                    f"https://raw.githubusercontent.com/{DIST}/main/releases/{urllib.parse.quote(name)}"),
        }
    if not any(k.endswith(".rbf") for k in files):
        raise SystemExit("no .rbf staged - refusing to emit an empty db")
    if not any(k.endswith(".mra") for k in files):
        raise SystemExit("no .mra staged - refusing to emit an empty db")

    db = {
        "db_id": DB_ID,
        "timestamp": int(time.time()),
        "files": files,
        "folders": {"_Arcade": {}, "_Arcade/cores": {}},
    }
    inner = os.path.basename(out).replace(".zip", "")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(inner, json.dumps(db, indent=2))
    print(f"wrote {out} (db_id {DB_ID}, {len(files)} files, tag {tag})")
    for k, v in files.items():
        print(f"  {k}  md5={v['hash']}  {v['size']} bytes")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
