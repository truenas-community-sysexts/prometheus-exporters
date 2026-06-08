# Changelog

All notable changes to this project are documented here. The format is loosely
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Releases are versioned by build date and CI run (`v<YYYY.MM.DD>-r<run>`) rather
than a semantic version, because the artifact is a moving bundle of upstream
exporters. The exact exporter versions in each release are listed in that
release's notes.

## [Unreleased]

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
