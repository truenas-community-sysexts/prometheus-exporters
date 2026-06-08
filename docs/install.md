# Install Guide

## Quick install + enable

```bash
curl -fsSL https://github.com/truenas-community-sysexts/prometheus-exporters/releases/latest/download/install.sh \
  | sudo bash -s -- --enable=node_exporter,smartctl_exporter
```

This downloads the latest `prometheus-exporters.raw`, verifies its checksum,
merges it into `/usr`, copies it to your data pool, seeds default configs,
starts the exporters you enabled, and registers a PREINIT script so they come
back after reboots and TrueNAS updates.

Exporters ship **disabled** — nothing runs until you `--enable` it.

## Options

| Option | Description |
| --- | --- |
| `--enable=LIST` | Comma-separated exporters to enable, or `all` |
| `--disable=LIST` | Comma-separated exporters to disable |
| `--list` | Show available and currently-enabled exporters |
| `--pool=NAME` | ZFS pool for persistent config (`/mnt/NAME/.config/prometheus-exporters`) |
| `--persist-path=PATH` | Exact persistent path; must be `/mnt/<pool>/.config/prometheus-exporters` |
| `--repo=OWNER/NAME` | Download from a fork (also `PROMETHEUS_EXPORTERS_REPO` env) |
| `--check` | Read-only probe of an existing install |
| `--dry-run` | Validate without changing anything |
| `--help` | Usage |
| `[path-to-.raw]` | Install a local image instead of downloading |

`--enable`/`--disable` are **incremental** — they adjust the stored set, so you
can add or remove one exporter without restating the rest. Re-running
`install.sh` with no `--enable`/`--disable` keeps the current set and just
re-applies/upgrades.

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
which is the stable path the unit files reference — so editing a file here and
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
sudo ./install.sh --check
```

Reports: sysext merged, `/run` path wired, backup + PREINIT present and
registered, and for each enabled exporter — binary present, service active,
config seeded (where applicable), and (for `ipmi_exporter`) bundled FreeIPMI
present.

## Uninstalling

```bash
curl -fsSL https://github.com/truenas-community-sysexts/prometheus-exporters/releases/latest/download/uninstall.sh | sudo bash
```

Stops all exporters, unmerges the sysext (re-merging any other sysexts),
deregisters the PREINIT script, and removes `/mnt/*/.config/prometheus-exporters`.
