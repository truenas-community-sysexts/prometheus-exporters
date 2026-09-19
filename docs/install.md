# Install Guide

## Quick install + enable

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/prometheus-exporters/main/get.sh \
  | sudo bash -s -- --enable=node_exporter,smartctl_exporter
```

`get.sh` picks the newest release approved for your TrueNAS train (see
[Which release is installed](#which-release-is-installed)) and runs that
release's `install.sh`, which downloads the release's
`prometheus-exporters.raw`, verifies its checksum, merges it into `/usr`, copies
it to your data pool, seeds default configs, starts the exporters you enabled,
and registers a PREINIT script so they come back after reboots and TrueNAS
updates. Every option below goes after `bash -s --` and passes through to
`install.sh`.

Exporters ship **disabled** - nothing runs until you `--enable` it.

## Options

| Option | Description |
| --- | --- |
| `--enable=LIST` | Comma-separated exporters to enable, or `all` |
| `--disable=LIST` | Comma-separated exporters to disable |
| `--list` | Show available and currently-enabled exporters |
| `--pool=NAME` | ZFS pool for persistent config (`/mnt/NAME/.config/prometheus-exporters`) |
| `--persist-path=PATH` | Exact persistent path; must be `/mnt/<pool>/.config/prometheus-exporters` |
| `--release=TAG` | Install that release (e.g. `v2026.07.15-r5`) instead of the newest approved one |
| `--repo=OWNER/NAME` | Download from a fork (also `PROMETHEUS_EXPORTERS_REPO` env) |
| `--check` | Read-only probe of an existing install |
| `--dry-run` | Validate without changing anything |
| `--help` | Usage |
| `[path-to-.raw]` | Install a local image instead of downloading |

`--enable`/`--disable` are **incremental** - they adjust the stored set, so you
can add or remove one exporter without restating the rest. Re-running the
one-liner with no `--enable`/`--disable` keeps the current set and just
re-applies/upgrades (to the newest release approved for your train).

## Which release is installed

Each release is approved **per TrueNAS train**. The train is the major version
from 26 on (every 26.x release, betas included, is train `26`) and
major.minor before that (`25.10`). A release starts as a pre-release with one
hardware-test issue per supported train; closing a train's issue as completed
approves it for that train's boxes only.

`get.sh` reads the TrueNAS version (`midclt call system.info`), derives the
train, and picks the newest release that is approved for it:

- its notes carry `<!-- verified-train: <train> -->`, or
- it is a full (non-pre-release) release with no `verified-train` marker at
  all. Every release published before per-train approval is one of these, so
  they stay approved for every train.

Nothing else is installed, on stable or beta boxes: with no approved release
for the train it stops and links the open hardware-test issues (see
[troubleshooting](troubleshooting.md#no-release-is-approved-for-truenas-train-train-yet)).
It then downloads **that** release's `install.sh` and
`prometheus-exporters-lib.sh` and runs `install.sh` with your arguments plus
`--release=<tag>`, so the image comes from the same release. `--uninstall`
runs the release's `uninstall.sh` (with its `restore.sh` and lib) instead.
Releases from before per-train approval have an `install.sh` without
`--release`; for those, `get.sh` downloads the release's image, checks its
sha256 and passes the local file instead.

To install a specific release, pin it. This skips the approval check, which is
how a tester installs a release under test:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/prometheus-exporters/main/get.sh \
  | sudo bash -s -- --release=v2026.07.15-r5 --enable=node_exporter
```

`install.sh`, `uninstall.sh` and `restore.sh` run on their own (downloaded from
a release, or piped from one) use the same rule for whatever they download:
`--release=TAG` if given, else the newest release approved for the box's train.
None of them use GitHub's "Latest" release any more.

## What lives on the data pool

`/mnt/<pool>/.config/prometheus-exporters/`:

| Path | Purpose |
| --- | --- |
| `prometheus-exporters.raw` | the sysext image (activation source + backup) |
| `prometheus-exporters-preinit.sh` | PREINIT: re-merges + restarts enabled exporters |
| `enabled` | one exporter name per line (managed by `--enable`/`--disable`) |
| `configs/blackbox.yml`, `configs/snmp.yml` | editable exporter configs (seeded from defaults) |
| `env/<name>.env` | optional per-exporter overrides (see below) |

At boot the PREINIT script symlinks this directory to `/run/prometheus-exporters`,
which is the stable path the unit files reference - so editing a file here and
restarting the service is all it takes to reconfigure.

## Configuring an exporter

**Config files** (`blackbox_exporter`, `snmp_exporter`): edit
`/mnt/<pool>/.config/prometheus-exporters/configs/<name>.yml`, then
`sudo systemctl restart <name>.service`. Your edits survive updates (they're on
the data pool); re-running `install.sh` never overwrites an existing config.

**Flags / ports** (any exporter): drop a
`/mnt/<pool>/.config/prometheus-exporters/env/<name>.env` file setting `ARGS=`,
then restart. For example, to move node_exporter to port 19100 and enable the
systemd collector:

```bash
echo 'ARGS=--web.listen-address=:19100 --collector.systemd' \
  | sudo tee /mnt/<pool>/.config/prometheus-exporters/env/node_exporter.env
sudo systemctl restart node_exporter.service
```

## Default ports

`node` 9100 · `smartctl` 9633 · `nut` 9199 · `blackbox` 9115 · `snmp` 9116 · `ipmi` 9290.
Metrics are at `http://<host>:<port>/metrics`. See [exporters.md](exporters.md).

## Verifying

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/prometheus-exporters/main/get.sh \
  | sudo bash -s -- --check
```

Reports: sysext merged, `/run` path wired, backup + PREINIT present and
registered, and for each enabled exporter: binary present, service active,
config seeded (where applicable), and (for `ipmi_exporter`) bundled FreeIPMI
present.

## Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/prometheus-exporters/main/get.sh \
  | sudo bash -s -- --uninstall
```

Stops all exporters, unmerges the sysext (re-merging any other sysexts),
deregisters the PREINIT script, and removes `/mnt/*/.config/prometheus-exporters`.
