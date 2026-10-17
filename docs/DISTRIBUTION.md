# Distribution — auto-update support for both platforms

How this repository feeds both platforms' updaters. The Pocket inventory
consumes this repository's GitHub releases directly. MiSTer is served by the
**official MiSTer distribution** since 2026-09-03: each MiSTer release is
vendored into the standard-layout distribution repo
[`spoonelli/Arcade-Escape_MiSTer`](https://github.com/spoonelli/Arcade-Escape_MiSTer),
which MiSTer-devel forked as `MiSTer-devel/Arcade-Escape_MiSTer`. The interim
custom update_all database this repository published is retired; its section
below is kept as the record.

## Analogue Pocket — pupdate / openFPGA Cores Inventory

**How it works.** `pupdate` (and comparable updaters) discover cores through
the community inventory at
[`openfpga-cores-inventory/analogue-pocket`](https://github.com/openfpga-cores-inventory/analogue-pocket),
which serves a read-only API generated from registered repositories'
GitHub releases. Once a repo is registered, every new release is picked up
automatically — there is no per-release submission.

**One-time registration — DONE (2026-08-30, issue #1536; listing verified
live in the inventory and installing via pupdate).** For the record, the
submission was:

| Field | Value for this project |
|---|---|
| GitHub Repository | `spoonelli/Atari-Dual-68k` |
| Asset Filter | `AtariDual68k-pocket-` |

The asset filter is required here even though each Pocket release carries a
single zip: MiSTer releases live under the same repository (tagged
`mister-v*`), and the filter guarantees the inventory only ever selects
Pocket packages.

> **Open for the Klax and Guts Pocket cores.** The filter is a prefix, so a
> future `AtariDual68k-pocket-klaxp-…` or `…-guts-…` zip on a `v*` release
> would match it too, and the inventory would offer it as the Escape core.
> Before those cores ship (they come after MiSTer 0.2, as separate packages
> `spoonelli.klaxp` / `spoonelli.guts`), choose non-overlapping zip names or a
> separate registration per core.

**Per-release obligation:** bump `core.json`'s `date_release` to the tag
date in the same commit that bumps `version` — the inventory displays it
as the core's release date (learned when v0.1.0 shipped showing the
2026-08-06 authoring date).

**Standing obligations (all already met):**

- Public repository with GitHub Releases; the Pocket zip is one asset per
  release, in openFPGA SD layout (`Cores/`, `Platforms/`, `Assets/`).
- `core.json` metadata is accurate (`author` `spoonelli`, `shortname`
  `eprom`, `platform_ids` `["eprom"]`, semantic `version`).
- Zip naming is stable: `AtariDual68k-pocket-v<version>.zip`.
- MiSTer releases are marked **pre-release**, keeping `releases/latest`
  pointed at the current Pocket release.

## MiSTer — official distribution (the interim custom database, retired)

**Status (2026-09-03): ADOPTED — the custom db is retired.** MiSTer-devel
forked the distribution repo as `MiSTer-devel/Arcade-Escape_MiSTer`; the
official distribution aggregator publishes the core as
`_Arcade/cores/Escape_YYYYMMDD.rbf` (the aggregator strips the `Arcade-`
prefix from every core) plus the MRA, whose `<rbf>` tag the maintainers
set to `Escape` — Main resolves a tag against both `Escape_*` and
`Arcade-Escape_*`, so that tag works on every install while `Arcade-Escape`
would not have found the official file. Because the Downloader forbids two
databases sharing a path, the custom db was retired the same day with an
**empty** db under the unchanged `db_id` (so the Downloader removes the
files it owned, keeping any path the official db also owns); the shipping
README tells users to `update.sh --uninstall spoonelli/ataridual68k`.
The rest of this section, apart from the distribution-repo paragraph, is
the historical record of the interim route.

**How it worked.** MiSTer's Downloader (which `update_all` wraps) installs
third-party cores from **custom databases**: a JSON file the core author
publishes at a stable URL, which users reference once from
`/media/fat/downloader.ini`. Every later release only required regenerating
the JSON; users updated as part of their normal `update_all` run.

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
   Pocket line by design. **Since 2026-08-30 the db's file URLs point at
   the distribution repo's committed `releases/` files** (raw URLs into
   `Arcade-Escape_MiSTer`), and the installed names are
   `Arcade-Escape_YYYYMMDD.rbf` + the retagged MRA — one naming scheme
   across manual installs, the db, and the future official distribution.
   Regenerate from that repo's `releases/` directory.
4. Users added, once, to `/media/fat/downloader.ini` (no longer needed — the
   db is retired; anyone who added it should remove it with
   `update.sh --uninstall spoonelli/ataridual68k`):
   ```ini
   [spoonelli/ataridual68k]
   db_url = 'https://github.com/spoonelli/Atari-Dual-68k/releases/download/mister-db/ataridual68k_db.json.zip'
   ```
5. Superseded dated `.rbf` files are removed by the Downloader automatically
   when they leave the db.

Release-time checklist, while the db was live: upload `.rbf` + `.mra` as
release assets, run `gen_mister_db.py <stage> <tag>`, clobber-upload to
`mister-db`, then verify every db URL's md5 against the db (a stale CDN copy
can lag a clobber by ~1 minute). None of this is done any more.

**Distribution repo (current route):** [`Arcade-Escape_MiSTer`](https://github.com/spoonelli/Arcade-Escape_MiSTer)
carries the core in the MiSTer standard layout (`sys/`, `rtl/` fully
vendored, `releases/Arcade-Escape_YYYYMMDD.rbf` + MRA as of mister-v0.1.2) —
the repository MiSTer-devel forked on adoption. Development stays in this repository; each
MiSTer release is vendored over, and reaches the official distribution
through the MiSTer-devel fork (the aggregator installs it as
`_Arcade/cores/Escape_YYYYMMDD.rbf`).

**Official MiSTer-devel adoption — DONE 2026-09-03 (the plan as it was
written, kept).** `update_all`'s menu is a curated list (official
distribution, JTCORES, Coin-Op Collection); independent cores cannot inject
themselves into it, so the custom db above was the interim. The one path to
zero-user-effort distribution was adoption into the MiSTer-devel org as
`Arcade-Escape_MiSTer`, after which the official distribution aggregator
carries the core to every stock `update_all` run automatically.

Plan (deliberately sequenced after `mister-v0.1.x` stabilized in the
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
   **Done 2026-09-03** — see the status note at the top of this section.

The official distribution is now the auto-update route; the custom db is
retired.

## MiSTer — family layout for the prototypes (from 0.2)

**Implemented (ALT-172, MiSTer test build 169; milestone 0.2, unreleased).**
The 169 MRAs sit in exactly the layout below in `src/mister/releases/` on
the `milestone-0.2-mister` branch, ready to be vendored into the distribution
repo's `releases/` at the 0.2 release; the device check of the menu layout is
part of the 0.2 test plan.

One `Escape_YYYYMMDD.rbf` serves every game on this board; the MRA tells
the core which one through a one-byte `<rom index="1">` block (GAMESEL-167:
00 Escape, 01 Klax prototype, 02 Guts n' Glory — absent in older Escape
MRAs, which therefore keep working). The MRAs follow the MiSTer-devel
convention other family cores use (jotego's `jtriders`/`jtsimson` trees are
the model): one top-level MRA per distinct game, clones and regional sets
under `_alternatives/_<Game>/`, folder named after the parent game.

| MRA | MAME set | Where in `releases/` |
|---|---|---|
| `Escape from the Planet of the Robot Monsters (set 1).mra` | `eprom` (parent) | top level |
| `Escape from the Planet of the Robot Monsters (set 2).mra` | `eprom2` (clone) | `_alternatives/_Escape from the Planet of the Robot Monsters/` |
| `Guts n' Glory (prototype).mra` | `guts` (parent) | top level |
| `Klax (prototype set 1).mra`, `Klax (prototype set 2).mra` | `klaxp1`/`klaxp2` (clones of `klax`) | `_alternatives/_Klax/` |

The Klax prototypes are the one wrinkle: MAME files them under production
Klax, whose parent is served by RetroShrimp's `Arcade-Klax_MiSTer` core with
its own `_Klax` alternatives folder in the official distribution. Every MRA
names its own rbf, so the two cores' MRAs can share that folder; the pull
request that adds ours should say so explicitly and copy the Klax core's
author, whose README excludes the prototypes as "different hardware".

## Division of labour

| Concern | Pocket | MiSTer |
|---|---|---|
| Discovery | inventory registration (one issue, once) | official distribution — nothing for the user to add (the custom-db `downloader.ini` entry is retired) |
| Per-release work | none — publish the GitHub release | publish the GitHub release, vendor the rbf + MRAs into the distribution repo's `releases/`, and open a pull request to the MiSTer-devel fork |
| Release tagging | `v*`, full release | `mister-v*`, pre-release |
| Asset naming | `AtariDual68k-pocket-v*.zip` | `AtariDual68k-mister-*.zip` + dated `.rbf` (installed by the official distribution as `Escape_YYYYMMDD.rbf`; milestone 0.2 test builds from 167 carry that name themselves) |
