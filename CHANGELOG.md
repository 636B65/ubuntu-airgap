# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Release files get a signed build provenance attestation (Sigstore, through
  GitHub artifact attestations). Verify with
  `gh attestation verify ubuntu-airgap.sh --repo 636B65/ubuntu-airgap`.
- `tests/lint.sh` runs every lint check CI runs, the same way. The CI Lint job
  now runs this script, so local and CI checks cannot drift apart.

### Fixed

- `debmirror` is retried 5 times, 1, 2, 4 and 8 minutes apart (about 15 minutes
  in all), instead of 3 times 1 minute apart, so a short outage of the archive
  or a PPA (HTTP 503) no longer fails the download.
- Every other download is retried during outages too: repository and key
  downloads (curl, up to 15 minutes with backoff), and Launchpad and keyserver
  lookups for `--ppa` (like the Snap Store API). These lookups now retry for
  about 10 minutes instead of about 2.5, honouring `Retry-After` up to 5
  minutes, because the Snap Store can rate-limit for several minutes. A repository is only reported
  as "not found (flat repos are not supported)" on a real HTTP 404; an outage is
  now reported as "cannot reach ... (HTTP 503)".
- `--snap`: `snap download` is retried (5 attempts, 10 to 80 s apart) when the
  Snap Store rate-limits or fails, like the Snap Store API queries already were.
- CI no longer cancels a run on `main` (or a tag) when a newer push arrives, so
  an automatic release cannot be interrupted halfway.

## [0.2.1] - 2026-11-17

### Changed

- Releases are automatic: when CI passes on `main` and the `VERSION` in the
  script has no tag yet, CI tags that commit and publishes the release. Pushing
  the tag yourself still works. Both paths use `.github/release.sh`.

### Fixed

- With `--package-filter`, a pocket where nothing matches no longer fails the
  download ("No packages after parsing Packages and Sources files!"). It is
  mirrored with index files only and a warning, also when a failed attempt or an
  earlier run left its directory behind. Previously the `debmirror` retries could
  never succeed after the first attempt failed.
- `--snap`: Snap Store API queries are retried on rate limiting (HTTP 429),
  server errors and network errors, honouring `Retry-After`. Errors are no
  longer all reported as "not found in the Snap Store".

## [0.2.0] - 2026-11-17

### Added

- `--snap NAME[=CHANNEL]` downloads snaps (for example `--snap firefox`) with their
  signed `.assert` files. Bases, content-snap default-providers and `snapd` are
  resolved automatically through the Snap Store API, and downloads are
  incremental. `install` (or the new `snaps` command) runs `snap ack` and
  installs or refreshes the snaps offline in dependency order. `--no-snaps`
  skips this.
- Multiarch safety on amd64:
  - i386 is never mirrored, and `install` warns about installed foreign-arch
    packages.
  - Packages that apt keeps back are listed after the upgrade, with the
    Multi-Arch reason.
  - `install -y --full-upgrade` refuses to remove i386 packages.
- End-to-end tests:
  - a client with `libc6:i386` installed at an older version;
  - an offline snap install in a systemd/snapd container whose network is
    disconnected, including an offline refresh of an installed snap to a newer
    revision (new CI job);
  - a CLI test that feeds canned `apt -s` output to the i386-removal guard.

## [0.1.1] - 2026-11-17

### Security

- The HTTP server log no longer falls back to the predictable path
  `/tmp/ubuntu-airgap-http.log`, which a local user could pre-create as a
  symlink and make root truncate a file. It now uses `mktemp`, and only uses
  `/var/log` when that path is not a symlink.
- A warning is printed when a repository key is downloaded over plain `http://`.
- GitHub Actions are pinned to commit SHAs, checkouts no longer keep the token
  on disk, and write permission is granted per job.
- Added zizmor (workflow security) to CI, plus CodeQL and OpenSSF Scorecard code
  scanning, `SECURITY.md` with the trust model, and private vulnerability
  reporting.
- CI Python tools (ruff, codespell, zizmor) are installed from the hash-locked
  `.github/requirements/lint.txt` with `--require-hashes`, and Dependabot keeps
  them current.

### Fixed

- A failed `debmirror` run is retried (up to 3 attempts). This covers the Ubuntu
  archive republishing during a download.
- The end-to-end test accepts either `InRelease` or `Release` + `Release.gpg`,
  as apt does.
- The release badge now links to the latest release.

### Changed

- GitHub Actions updated to their current major versions (checkout v7,
  setup-python v7, upload-artifact v7), and CI uses Python 3.14 with pinned tool
  versions. Dependabot updates for actions are grouped into one PR.

## [0.1.0] - 2026-11-16

### Added

- `download`: builds a real, signed Ubuntu 26.04 (amd64) mirror with `debmirror`
  in an `ubuntu:26.04` Docker container. It includes `dep11`, `cnf`, `i18n`
  and generated `by-hash` indexes, and later runs are incremental.
- `--amd64v3` to also mirror x86-64-v3 optimised builds. Clients use them
  automatically through `APT::Architecture-Variants "auto"`.
- Extra sources: `--repo` (repository + key), `--ppa` (Launchpad PPA, key
  fingerprint verified) and `--repo-deb` (repositories, keys and apt pinning taken
  from a vendor repo-setup `.deb`).
- `--dry-run` size estimate, `--package-filter` for partial mirrors, and `--config`
  files.
- `install`: serves the mirror with `python3 -m http.server`, disables and backs
  up the online sources, writes deb822 sources, runs `apt update` + `apt upgrade`,
  and reports any 404s. `--install-setup-debs` installs vendor setup packages.
- `serve` and `restore` commands.
- The first upgrade on an x86-64-v3 capable machine switches installed packages
  to their amd64v3 builds. With `-y` this is allowed only when every
  "downgrade" apt reports is a same-version variant switch.
- Architecture and CI diagrams (draw.io). The `Diagrams` workflow renders them
  to PNG for the README.
- CI: ShellCheck, ruff, codespell, actionlint, markdownlint, unit tests, and an
  offline end-to-end test (amd64 and amd64v3). There is also a release workflow.

[Unreleased]: https://github.com/636B65/ubuntu-airgap/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/636B65/ubuntu-airgap/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/636B65/ubuntu-airgap/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/636B65/ubuntu-airgap/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/636B65/ubuntu-airgap/releases/tag/v0.1.0
