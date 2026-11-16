# Security policy

## Supported versions

Only the latest release receives fixes.

| Version | Supported |
|---|---|
| latest `0.x` release | yes |
| older | no |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report them privately through GitHub instead:
**Security → Advisories → [Report a vulnerability](https://github.com/636B65/ubuntu-airgap/security/advisories/new)**.

Include the version (`ubuntu-airgap.sh version`), what you ran, and what an
attacker could achieve. You should get an answer within a week.

## Trust model

`ubuntu-airgap` moves packages to a machine without a network. These are the
things it trusts and the things it verifies:

| Item | How it is protected |
|---|---|
| Ubuntu packages and indexes | `debmirror` checks the GPG signature and checksums when downloading. The air-gapped apt checks them **again** against the `ubuntu-archive-keyring` already on that machine, so a modified disk is detected. |
| Extra repositories (`--repo`, `--ppa`, `--repo-deb`) | Signatures and checksums are checked with the repository's key. The keys are carried on the mirror disk and installed from there, so for these repos **the disk is trusted**. PPA keys are checked against the fingerprint Launchpad reports. |
| `ubuntu-airgap.sh` on the disk | It runs as root on the air-gapped machine, so **the disk is trusted**. Compare it with the `SHA256SUMS` of the release, or keep a known-good copy on the air-gapped machine and run `install --mirror DIR`. |
| HTTP server | Binds to `127.0.0.1` by default. With `serve --bind 0.0.0.0` the mirror is readable without authentication on the LAN; it contains only public packages. |

Keep the mirror disk under your control between the online and the air-gapped
machine.

## Automated checks

- CI runs ShellCheck, [zizmor](https://docs.zizmor.sh/) (GitHub Actions
  security), and an offline end-to-end test on every change.
- CodeQL code scanning, OpenSSF Scorecard, Dependabot alerts and security
  updates, and secret scanning with push protection are enabled for this
  repository.
- All GitHub Actions are pinned to commit SHAs and kept current by Dependabot.
