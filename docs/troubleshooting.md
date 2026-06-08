# Troubleshooting

Start with the built-in probe:

```bash
sudo ./install.sh --check
```

## An exporter isn't running

1. Is it enabled? `sudo ./install.sh --list`. Enable with
   `sudo ./install.sh --enable=<name>`.
2. Check the service: `systemctl status <name>.service` and
   `journalctl -u <name>.service -b`.
3. Is the sysext merged? `systemd-sysext list` should show
   `prometheus-exporters`; if not, `sudo systemd-sysext refresh` or reboot.

## Nothing comes back after a reboot

The PREINIT script re-merges the sysext and restarts enabled exporters.

1. `sudo ./install.sh --check` — look at "PREINIT registered" and "PREINIT
   completed this boot".
2. `journalctl -b -t prometheus-exporters-preinit` for the boot log.
3. Confirm the persistent dir exists: `ls /mnt/*/.config/prometheus-exporters/`.
4. Re-run `install.sh` if the registration is missing.

## Nothing comes back after a TrueNAS update

Expected mid-update (`/usr` is reset); the PREINIT script restores everything on
the next boot. The image, `enabled` list, and configs live on the data pool and
are untouched by updates. Re-run `install.sh` if needed.

## A config change isn't taking effect

Configs live at `/mnt/<pool>/.config/prometheus-exporters/configs/<name>.yml`
(exposed to the unit as `/run/prometheus-exporters/configs/<name>.yml`). After
editing, restart: `sudo systemctl restart <name>.service`. `install.sh` never
overwrites an existing config, so your edits are safe across upgrades.

## Changing a port / flags

Create `/mnt/<pool>/.config/prometheus-exporters/env/<name>.env` with
`ARGS=--web.listen-address=:NNNN ...` and restart the service. See
[install.md](install.md#configuring-an-exporter).

## ipmi_exporter returns no metrics

1. Is there a BMC? `ls /dev/ipmi*`. If absent, `modprobe ipmi_devintf ipmi_si`;
   if still absent, the board likely has no BMC.
2. The bundled FreeIPMI tools must be on PATH: `command -v ipmimonitoring`
   should resolve to `/usr/sbin/ipmimonitoring`. If not, the sysext isn't
   merged.
3. Test FreeIPMI directly: `sudo ipmimonitoring`. If that fails, the exporter
   can't collect either — it's an IPMI/host issue, not the exporter.
4. For a remote BMC, you need a config file (see
   [exporters.md](exporters.md#ipmi_exporter--port-9290)).

## smartctl_exporter shows no disks

It calls the host's `smartctl` and runs as root. Confirm `smartctl --scan`
lists your disks. On some controllers you may need device-specific flags via a
config file (see the exporter's upstream README).

## A bundled FreeIPMI tool fails with a library error

The FreeIPMI binaries carry their own libraries under
`/usr/lib/prometheus-exporters/lib` with an `rpath`. `ldd /usr/sbin/ipmimonitoring`
should show no "not found". If it does, the `debian.suite` in
`tracked-versions.json` may be newer than your TrueNAS base — it should be the
*oldest* Debian base among the TrueNAS versions you run.
