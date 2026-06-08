# Exporters Reference

Per-exporter notes for running on TrueNAS SCALE. All listen on `0.0.0.0:<port>`
by default; scrape `http://<host>:<port>/metrics`. Change flags via an
`env/<name>.env` file (see [install.md](install.md#configuring-an-exporter)).

## node_exporter — port 9100
Host metrics: CPU, memory, load, filesystems, network, and ZFS (via the
`zfs` collector, enabled by default on Linux). Runs as root. No config file.
Common tweak — enable the systemd collector:
```
ARGS=--collector.systemd
```

## smartctl_exporter — port 9633
Disk SMART health. Calls the host's `/usr/sbin/smartctl` (ships with TrueNAS)
and auto-discovers devices via `smartctl --scan`. Runs as root (required to
read SMART data). No config file needed for the common case.

## nut_exporter — port 9199
UPS metrics from a [NUT](https://networkupstools.org/) `upsd`. TrueNAS's own UPS
service runs `upsd` on `127.0.0.1:3493` when configured. Point the exporter at
it and pick variables:
```
ARGS=--nut.server=127.0.0.1 --nut.vars_enable=battery.charge,battery.runtime,ups.status,ups.load
```
If `upsd` requires auth, add `--nut.username`/`--nut.password` (or set them via
the env file).

## blackbox_exporter — port 9115
HTTP/TCP/ICMP/DNS probing. Reads
`/run/prometheus-exporters/configs/blackbox.yml` (seeded from the upstream
default). Edit that file on the data pool to define modules, then
`systemctl restart blackbox_exporter`. Prometheus passes the probe target via
`?target=...&module=...`.

## snmp_exporter — port 9116
SNMP device metrics. Reads `/run/prometheus-exporters/configs/snmp.yml` (the
large generated default ships in the release). For custom MIBs, regenerate
`snmp.yml` with the upstream generator and drop it in
`configs/snmp.yml`, then restart.

## ipmi_exporter — port 9290
BMC/IPMI sensors, power, SEL. Uses the **bundled FreeIPMI** tools (under
`/usr/sbin`, merged by the sysext) for local collection — no config file is
required for the built-in local module. Runs as root for `/dev/ipmi*` access.

Requirements on the host:
- An IPMI BMC and the kernel IPMI device (`/dev/ipmi0`). TrueNAS loads the
  `ipmi_si` / `ipmi_devintf` modules on systems with a BMC; if `/dev/ipmi0` is
  missing, `modprobe ipmi_devintf` (or the board may simply have no BMC).
- For **remote** BMCs, pass a config via
  `ARGS=--config.file=/run/prometheus-exporters/configs/ipmi.yml` describing the
  remote module (host/user/password), and create that file on the data pool.

The bundled FreeIPMI binaries are GPLv3 (Debian `freeipmi` package); see the
repository README for licensing.

## Adding to Prometheus

Example scrape config:
```yaml
scrape_configs:
  - job_name: truenas-node
    static_configs: [{ targets: ['truenas.lan:9100'] }]
  - job_name: truenas-smartctl
    static_configs: [{ targets: ['truenas.lan:9633'] }]
```
For `blackbox`/`snmp`, use the relabel pattern from each exporter's upstream
README (target passed via `__param_target`).
