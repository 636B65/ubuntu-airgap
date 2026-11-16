# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/636B65/ubuntu-airgap/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/636B65/ubuntu-airgap/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/636B65/ubuntu-airgap/releases/tag/v0.1.0
