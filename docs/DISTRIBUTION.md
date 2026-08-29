# Distribution — auto-update support for both platforms

How this one repository feeds both platforms' updaters. No forks and no
second repository are required; both ecosystems consume GitHub releases
from a single repo, provided the conventions below are held.

## Analogue Pocket — pupdate / openFPGA Cores Inventory

**How it works.** `pupdate` (and comparable updaters) discover cores through
the community inventory at
[`openfpga-cores-inventory/analogue-pocket`](https://github.com/openfpga-cores-inventory/analogue-pocket),
which serves a read-only API generated from registered repositories'
GitHub releases. Once a repo is registered, every new release is picked up
automatically — there is no per-release submission.

**One-time registration.** Open a `New Issue → Add Core` on that repository
with:

| Field | Value for this project |
|---|---|
| GitHub Repository | `spoonelli/Atari-Dual-68k` |
| Asset Filter | `AtariDual68k-pocket-` |

The asset filter is required here even though each Pocket release carries a
single zip: MiSTer releases live under the same repository (tagged
`mister-v*`), and the filter guarantees the inventory only ever selects
Pocket packages.

**Standing obligations (all already met):**

- Public repository with GitHub Releases; the Pocket zip is one asset per
  release, in openFPGA SD layout (`Cores/`, `Platforms/`, `Assets/`).
- `core.json` metadata is accurate (`author` `spoonelli`, `shortname`
  `eprom`, `platform_ids` `["eprom"]`, semantic `version`).
- Zip naming is stable: `AtariDual68k-pocket-v<version>.zip`.
- MiSTer releases are marked **pre-release**, keeping `releases/latest`
  pointed at the current Pocket release.

## MiSTer — Downloader / update_all custom database

**How it works.** MiSTer's Downloader (which `update_all` wraps) installs
third-party cores from **custom databases**: a JSON file the core author
publishes at a stable URL, which users reference once from
`/media/fat/downloader.ini`. Every later release only requires regenerating
the JSON; users update as part of their normal `update_all` run.

**Database format** (v1): `db_id`, `timestamp`, and a `files` map of
SD-relative paths to `{hash (md5), size, url}` entries, plus a `folders`
map. For this core the file set is exactly the release surface:

```
_Arcade/Escape from the Planet of the Robot Monsters (set 1).mra
_Arcade/cores/escape_<YYYYMMDD>.rbf
```

**Implemented (2026-08-29):**

1. `db_id`: `spoonelli/ataridual68k` — fixed forever (changing it duplicates
   installs; the Downloader documentation is explicit on this).
2. `support/gen_mister_db.py` reads the `mister-release/` staging directory,
   computes md5/size, and emits `ataridual68k_db.json.zip` with URLs pinned
   to the given release tag's **individual assets** (each MiSTer release
   carries the `.rbf` and `.mra` as separate assets alongside the zip;
   GitHub normalizes asset names — spaces to dots, parentheses dropped —
   and the script reproduces that).
3. The db is published under the fixed rolling tag **`mister-db`**, so the
   user-facing URL never changes; each MiSTer release regenerates the asset
   in place (`gh release upload mister-db … --clobber`). No extra branch,
   release infrastructure only. `releases/latest` cannot be used as the
   anchor: MiSTer releases are pre-releases, so `latest` resolves to the
   Pocket line by design.
4. Users add, once, to `/media/fat/downloader.ini`:
   ```ini
   [spoonelli/ataridual68k]
   db_url = 'https://github.com/spoonelli/Atari-Dual-68k/releases/download/mister-db/ataridual68k_db.json.zip'
   ```
5. Superseded dated `.rbf` files are removed by the Downloader automatically
   when they leave the db.

Release-time checklist: upload `.rbf` + `.mra` as release assets, run
`gen_mister_db.py <stage> <tag>`, clobber-upload to `mister-db`, then verify
every db URL's md5 against the db (a stale CDN copy can lag a clobber by
~1 minute).

**Not applicable:** distribution via the official `MiSTer-devel` repos or
the default `update_all` database list — those are curated collections;
a custom db is the standard route for an independent core and works with
stock tooling.

## Division of labour

| Concern | Pocket | MiSTer |
|---|---|---|
| Discovery | inventory registration (one issue, once) | db URL in the user's `downloader.ini` (once) |
| Per-release work | none — publish the GitHub release | CI regenerates the db JSON |
| Release tagging | `v*`, full release | `mister-v*`, pre-release |
| Asset naming | `AtariDual68k-pocket-v*.zip` | `AtariDual68k-mister-*.zip` + dated `.rbf` |
