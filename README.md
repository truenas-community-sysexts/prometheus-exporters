# Prometheus Exporters Sysext for TrueNAS SCALE

A [systemd-sysext](https://www.freedesktop.org/software/systemd/man/systemd-sysext.html) package that adds a set of [Prometheus](https://prometheus.io/) exporters to TrueNAS SCALE — host, disk, UPS, IPMI, and probing metrics — without modifying the immutable root filesystem.

Exporters ship **disabled**; you choose which to run with `--enable`. The selection and configs live on your data pool, and a PREINIT script restarts the enabled exporters on every boot, surviving reboots and TrueNAS updates. Because these are plain userspace binaries, **one release works on every TrueNAS version**.

## Documentation

| Doc | Contents |
| --- | --- |
| [Quick Start](#quick-start) | Install, enable, verify, uninstall |
| [docs/install.md](docs/install.md) | Enable/disable, configs, ports, persistence, scripts reference |
| [docs/exporters.md](docs/exporters.md) | Per-exporter notes, ports, and TrueNAS-specific config |
| [docs/build.md](docs/build.md) | Build process, adding an exporter, automated updates |
| [docs/architecture.md](docs/architecture.md) | sysext layout, systemd units, FreeIPMI bundling |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common issues |

## Included exporters

| Exporter | Default port | Notes |
| --- | --- | --- |
| `node_exporter` | 9100 | Host metrics (CPU, memory, filesystems, network, ZFS) |
| `smartctl_exporter` | 9633 | Disk SMART health (uses TrueNAS's `smartctl`) |
| `nut_exporter` | 9199 | UPS metrics from a NUT `upsd` server |
| `blackbox_exporter` | 9115 | HTTP/TCP/ICMP/DNS probing |
| `snmp_exporter` | 9116 | SNMP device metrics |
| `ipmi_exporter` | 9290 | BMC/IPMI sensors — bundles **FreeIPMI** (GPLv3) for local collection |

## Quick Start

### Prerequisites
- TrueNAS SCALE 25.10 or newer, root/sudo access
- A data pool (for persistent config) and internet access (to download the release)

### Install + enable
Install and turn on the exporters you want (comma-separated, or `all`):
```bash
curl -fsSL https://github.com/truenas-community-sysexts/prometheus-exporters/releases/latest/download/install.sh \
  | sudo bash -s -- --enable=node_exporter,smartctl_exporter
```
With an explicit pool:
```bash
curl -fsSL https://github.com/truenas-community-sysexts/prometheus-exporters/releases/latest/download/install.sh -o install.sh
sudo bash install.sh --enable=node_exporter --pool=fast
```

### Manage which run
```bash
sudo ./install.sh --list                       # available + enabled
sudo ./install.sh --enable=blackbox_exporter    # add one
sudo ./install.sh --disable=ipmi_exporter       # remove one
```

### Verify
```bash
sudo ./install.sh --check
curl -s localhost:9100/metrics | head           # node_exporter
```

### Uninstall
```bash
curl -fsSL https://github.com/truenas-community-sysexts/prometheus-exporters/releases/latest/download/uninstall.sh | sudo bash
```

## How It Works

- Exporters and their systemd units are packed into a squashfs image (`prometheus-exporters.raw`, `extension-release` `ID=_any`) and merged into `/usr`.
- The image lives on your data pool at `/mnt/<pool>/.config/prometheus-exporters/`, alongside the `enabled` list, editable `configs/`, and optional per-exporter `env/` overrides.
- A **PREINIT** script re-merges the sysext, wires `/run/prometheus-exporters` to the data pool (so units find their configs), and `systemctl start`s the enabled exporters on every boot.
- `ipmi_exporter`'s FreeIPMI dependency is bundled self-contained (private libs + `rpath`) so it never shadows host libraries. See [docs/architecture.md](docs/architecture.md).

## License

**MIT** ([LICENSE](LICENSE)) for the repository's own code (scripts, workflows, unit files).

Bundled exporters retain their upstream licenses (Apache-2.0 / MIT). The bundled **FreeIPMI** binaries are **GPLv3** (source: Debian's `freeipmi` package). No proprietary binaries are shipped.

## Credits

Structure, build pipeline, and persistence model adapted from the other [truenas-community-sysexts](https://github.com/truenas-community-sysexts) repos.
