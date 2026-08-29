# Security Policy

This project ships FPGA bitstreams and local tooling for the Analogue
Pocket and MiSTer platforms. It contains no network code, collects no
data, and runs nothing on the user's behalf beyond the packaged core and
the ROM-building script the user invokes locally.

## Supported versions

| Release line | Supported |
|---|---|
| Latest Pocket release (`v0.1.x`) | ✅ |
| Latest MiSTer pre-release (`mister-v0.1.x`) | ✅ (field-testing) |
| Development builds and superseded releases | ❌ — upgrade first |

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository
(Security tab → *Report a vulnerability*). It is enabled; reports go
only to the maintainer. Please do not open a public issue for anything
you believe is exploitable before it is fixed.

You can expect an acknowledgement within a week. Fixes ship as a patch
release on the affected platform's release line; credit is given unless
you ask otherwise.

## What is in scope

- **Release integrity.** Install only from this repository's
  [Releases](https://github.com/spoonelli/Atari-Dual-68k/releases). The
  MiSTer auto-update database pins every file by MD5 and size; a
  mismatch there, or a release asset that differs from what CI built,
  is a security report.
- **`build_rom.py` input handling.** The script parses user-supplied
  zip files. Every chip is CRC32-verified against known-good values and
  mismatches are refused, but a crafted archive that escapes the
  extraction or write paths would be in scope.
- **CI / supply chain.** Builds run on GitHub-hosted runners from this
  repository's workflows; no secrets are used in any workflow. Secret
  scanning and push protection are enabled on the repository.
- **The no-ROM guarantee.** The packaging scripts carry layered guards
  (content, size, manifest, and hash checks — see `support/package.sh`
  and the MiSTer workflow) so that no ROM data or copyrighted artwork
  can reach a release. A demonstrated bypass of those guards is a
  security report, not just a bug.

## What is out of scope

- Emulation inaccuracies, crashes, or hangs in the core itself
  (ordinary bugs — please use the issue tracker).
- Anything requiring a modified bitstream or tampered SD card contents
  the user installed themselves.
- The behaviour of third-party updaters (pupdate, update_all) beyond
  the data this project publishes to them.
