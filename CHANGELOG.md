# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Releases are versioned by build date and CI run (`v<YYYY.MM.DD>-r<run>`) rather
than a semantic version, because the artifact is a moving bundle of upstream
exporters. The exact exporter versions in each release are listed in that
release's notes.

## [Unreleased]

### Changed
- **Releases are approved per TrueNAS train, and nothing unapproved is
  installed.** The new one-liner is `curl -fsSL .../main/get.sh | sudo bash -s
  -- --enable=...` (uninstall: `... | sudo bash -s -- --uninstall`). It derives
  the train from the TrueNAS version (the major from 26 on, so every 26.x
  including betas is `26`; major.minor before that, e.g. `25.10`), picks the
  newest release approved for that train, and runs that release's `install.sh`
  (or `uninstall.sh`) with `--release=<tag>`, so the image comes from the same
  release. Approved means the release notes carry
  `<!-- verified-train: <train> -->`, or it is a full release with no such
  marker (every release from before this change, so `v2026.07.15-r5` stays the
  release on both 25.10 and 26 until a newer one is approved). With nothing
  approved for the train it stops and links the open hardware tests. For a
  release whose `install.sh` predates `--release`, `get.sh` downloads the
  image, checks its sha256 and passes the local file. The old
  `releases/latest/download/...` one-liners keep working.
- **`install.sh` takes `--release=TAG`** and, without it, uses the newest
  release approved for the box's train instead of GitHub's Latest, for both the
  image and (when it is not beside the script) `prometheus-exporters-lib.sh`.
  `uninstall.sh` and `restore.sh` fetch `restore.sh` and the lib the same way
  and also take `--release=TAG`.
- **One hardware-test issue per train.** `build.yml` opens an issue per train
  in `tracked-versions.json` (`hardware-test` for TrueNAS 25.10,
  `preview-hardware-test` for the TrueNAS 26 beta), each naming its train in
  the title and body and installing through `get.sh --release=<tag>`. Closing
  one as completed approves the release for that train only (`promote.yml`
  adds the marker); the first approval also turns the pre-release into a full
  release and appends the changelog. GitHub's "Latest" now follows the newest
  release approved for a stable train and is cosmetic. Issues from before this
  change (no train marker) promote exactly as before.
- **`build.yml` no longer has the `mark_latest` input.** A full release
  without markers is approved for every train, so publishing one straight to
  Latest would reach every box untested. Every release now starts as a
  pre-release. `check-releases.yml` no longer passes it.
- The lint workflow runs `tests/` (release selection, `get.sh` and the
  scripts' release resolution, `promote.yml` and the hardware-test issues)
  and validates the `trains` list.

### Added
- Initial scaffold of the `prometheus-exporters` sysext.
- Six exporters bundled: `node_exporter`, `smartctl_exporter`, `nut_exporter`,
  `blackbox_exporter`, `snmp_exporter`, `ipmi_exporter` (static upstream Go
  binaries), with `ipmi_exporter`'s FreeIPMI runtime dependency bundled
  self-contained (private-lib + `rpath`, GPLv3) from Debian.
- systemd units per exporter; exporters ship disabled and are turned on with
  `install.sh --enable=<list>` (or `all`). The enabled set, editable configs
  (`blackbox.yml`, `snmp.yml`), and per-exporter env overrides persist on the
  data pool; a PREINIT script re-merges the sysext and restarts enabled
  exporters on every boot.
- `install.sh` with `--enable`/`--disable`/`--list`/`--check`/`--dry-run`,
  identical smart pool detection to the other repos.
- `build.yml` (download exporters with version-templated assets + bundle
  FreeIPMI in a Debian container), `check-releases.yml` (daily upstream bump +
  hardware-test gate), and `lint.yml` (shellcheck, actionlint, schema).
- Docs: install, exporters, build, architecture, troubleshooting.
