# Architecture

## What a sysext is

A systemd system extension overlays its `/usr` tree onto the running system via
`overlayfs`, set up by `systemd-sysext`. It's the supported way to add software
to an immutable OS like TrueNAS without touching the read-only root. The
marker file `usr/lib/extension-release.d/extension-release.<name>` identifies
it; we set `ID=_any` so it loads regardless of the host's `os-release` ID.

> **Only `/usr` (and `/opt`) are merged.** That's why the systemd units live in
> `/usr/lib/systemd/system`, the exporter binaries in `/usr/bin`, FreeIPMI in
> `/usr/sbin`, and why configs/state must live elsewhere (the data pool) and be
> reached through a `/run` symlink — files a sysext puts under `/etc` are ignored.

## Layout of `prometheus-exporters.raw`

```
usr/
├── bin/                         # the 6 exporter binaries (static Go)
├── sbin/                        # bundled FreeIPMI tools (ipmimonitoring, ipmi-sensors, ...)
├── lib/
│   ├── systemd/system/          # one <exporter>.service per exporter
│   ├── prometheus-exporters/
│   │   ├── lib/                 # private shared libs for FreeIPMI ($ORIGIN rpath)
│   │   ├── configs-seed/        # default blackbox.yml / snmp.yml (seed source)
│   │   ├── exporters.txt        # manifest of exporter names (used by install/--check)
│   │   ├── versions.txt         # human-readable version record
│   │   └── prometheus-exporters-preinit.sh
│   └── extension-release.d/
│       └── extension-release.prometheus-exporters   # ID=_any
```

## Exporters: static Go binaries

`node`, `smartctl`, `nut`, `blackbox`, `snmp`, and `ipmi` exporters are
downloaded from their upstream GitHub releases as static `linux-amd64`
binaries. Nothing to compile or link — they drop straight into `/usr/bin`. The
release asset/path names embed the version, so `tracked-versions.json` stores
them as templates (`{version}`, `{vnum}`) that the build expands; this keeps
the daily auto-bump correct.

## FreeIPMI: bundled like an apt tool

`ipmi_exporter` shells out to FreeIPMI tools (`ipmimonitoring`, `ipmi-sensors`,
`bmc-info`, …) which TrueNAS doesn't ship. The build installs Debian's
`freeipmi` package in a `debian:<suite>-slim` container and bundles it with the
same private-lib + `rpath` mechanism used by the `cli-tools` repo
(`.github/scripts/bundle-apt-tool.sh`):

- FreeIPMI binaries land in `/usr/sbin`; their shared-library closure (minus the
  glibc core / loader, which come from the host) goes into the private
  `/usr/lib/prometheus-exporters/lib` with an `rpath` so it never shadows host
  libraries.
- Built on the oldest supported Debian base so its glibc is ≤ TrueNAS's
  (forward-compatible), which is also why one release is version-independent.

FreeIPMI is GPLv3; the repo's own code is MIT. See the README's licensing note.

## Enable / disable + boot model

Exporters are **not** enabled via systemd symlinks (those would live in `/etc`,
wiped on TrueNAS updates, and couldn't be selective against a fixed image).
Instead:

1. `install.sh --enable=...` writes the chosen exporter names to
   `enabled` on the data pool and `systemctl restart`s them immediately.
2. The **PREINIT** script, on every boot: re-merges the sysext, symlinks
   `/run/prometheus-exporters → /mnt/<pool>/.config/prometheus-exporters` (so
   units resolve `--config.file=/run/prometheus-exporters/configs/...` and their
   optional `EnvironmentFile`), runs `systemctl daemon-reload`, and
   `systemctl start`s each name in `enabled`.

Running the PREINIT start every boot *is* the persistence — it replaces
`systemctl enable` and survives the `/usr` reset that TrueNAS updates perform.

## Build & release pipeline

See [build.md](build.md): `resolve` (read suite) → `build` (download exporters
+ bundle FreeIPMI in a Debian container, assemble, smoke-test the squashfs) →
`release`. A daily job bumps exporter versions and triggers an unverified build
gated behind a hardware-test issue.
