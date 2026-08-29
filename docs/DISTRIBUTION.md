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

**Roadmap — official MiSTer-devel adoption (the zero-friction tier).**
`update_all`'s menu is a curated list (official distribution, JTCORES,
Coin-Op Collection); independent cores cannot inject themselves into it,
so the custom db above is the correct interim. The one path to
zero-user-effort distribution is adoption into the MiSTer-devel org as
`Arcade-Escape_MiSTer`, after which the official distribution aggregator
carries the core to every stock `update_all` run automatically.

Plan (deliberately sequenced after `mister-v0.1.x` stabilizes in the
field):

1. Accumulate device mileage on the tagged releases; keep the issue
   tracker responsive.
2. Prepare the conformance restructuring: the official aggregator
   collects from a `releases/` folder committed in the repo (dated
   `.rbf` files), not from GitHub Releases — a staging branch can hold
   that layout without disturbing this repo's release flow.
3. Submit to the MiSTer team with the accuracy record attached
   (`DEVIATIONS.md`, the measured benchmarks, `NOTICE.md` licensing
   inventory) — the review criteria are GPL sources, hardware maturity,
   proper `.mra`, no ROM distribution, and an active maintainer.
4. On adoption, the org repo becomes the MiSTer distribution point;
   the custom db is then retired with a final db update that leaves the
   Downloader-managed files in place for the official db to take over.

Until then: the custom db is the supported auto-update route.

## Division of labour

| Concern | Pocket | MiSTer |
|---|---|---|
| Discovery | inventory registration (one issue, once) | db URL in the user's `downloader.ini` (once) |
| Per-release work | none — publish the GitHub release | CI regenerates the db JSON |
| Release tagging | `v*`, full release | `mister-v*`, pre-release |
| Asset naming | `AtariDual68k-pocket-v*.zip` | `AtariDual68k-mister-*.zip` + dated `.rbf` |
