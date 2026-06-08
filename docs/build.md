# Build Guide

All builds run in GitHub Actions. The Go exporters are downloaded prebuilt; the
only compiled-language dependency (FreeIPMI) is pulled from Debian, so there's
no source compilation here.

## The pipeline

`.github/workflows/build.yml`:

1. **resolve** — reads `debian.suite` and the `mark_latest` input.
2. **build** — runs in a `debian:<suite>-slim` container and:
   - downloads each exporter's static `linux-amd64` release asset (expanding
     the `{version}`/`{vnum}` templates) into `/usr/bin`,
   - seeds the example configs (`blackbox.yml`, `snmp.yml`) from inside their
     tarballs into `configs-seed/`,
   - `apt-get install`s the `freeipmi` package and bundles it self-contained via
     `.github/scripts/bundle-apt-tool.sh`,
   - copies the static systemd units from `sysext/` and bundles the PREINIT
     script,
   - packs `prometheus-exporters.raw` (`mksquashfs … -comp zstd -all-root`),
   - smoke-tests the image (every exporter binary + unit present and
     `--version`-runnable, seed configs present, FreeIPMI bundled with all
     libraries resolved),
   - uploads the artifact.
3. **release** — publishes a GitHub release with the `.raw`, its `.sha256`, and
   the install scripts. `make_latest` follows the `mark_latest` input.

Run a verified build from the Actions tab (**Build prometheus-exporters
Sysext** → *Run workflow*, `mark_latest=true`).

## `tracked-versions.json`

```jsonc
{
  "debian": { "suite": "bookworm" },          // FreeIPMI is built against this
  "freeipmi": { "package": "freeipmi-tools" },
  "exporters": {
    "node_exporter": {
      "repo": "prometheus/node_exporter",
      "version": "v1.11.1",                    // the release tag (bumped daily)
      "asset": "node_exporter-{vnum}.linux-amd64.tar.gz",
      "extract": "node_exporter-{vnum}.linux-amd64/node_exporter",
      "port": 9100
    },
    "blackbox_exporter": {
      "...": "...",
      "config": { "name": "blackbox.yml",
                  "from": "blackbox_exporter-{vnum}.linux-amd64/blackbox.yml" }
    },
    "nut_exporter": {                          // raw binary: no 'extract'
      "asset": "nut_exporter-{version}-linux-amd64", "...": "..."
    }
  }
}
```

Template tokens: `{version}` = the tag (e.g. `v1.11.1`), `{vnum}` = without the
leading `v` (e.g. `1.11.1`). If `extract` is omitted the downloaded asset *is*
the binary. `config` (optional) seeds an example config from inside the tarball.
The shape is enforced by `.github/scripts/validate-tracked-versions.sh`.

## Adding an exporter

1. Add an entry under `exporters` with the repo, current tag, and the
   `asset`/`extract` patterns (download a release once and `tar tzf` it to get
   the exact internal path — the version usually appears in both).
2. Add a `sysext/usr/lib/systemd/system/<name>.service` unit. Reference configs
   via `/run/prometheus-exporters/configs/<name>.yml` and optional overrides via
   `EnvironmentFile=-/run/prometheus-exporters/env/<name>.env` + `$ARGS`.
3. If it reads a config file, add a `config` block and ship the default in the
   tarball; otherwise omit it.
4. Add the default port to `install.sh`'s `port_for()`.
5. Run the lint workflow, then build and verify on hardware.

## Automated updates

`.github/workflows/check-releases.yml` runs daily: for each exporter it queries
the latest upstream release and, if newer than tracked, bumps `version` (the
asset/extract templates handle the rest), pushes, and dispatches `build.yml`
with `mark_latest=false`. That publishes a release without marking it latest and
opens a `hardware-test` issue; promote it to *Latest* after verifying.

Pushing to `main` needs a `CHECK_BUILDS` repository secret (a PAT that can
bypass the branch ruleset); the default `GITHUB_TOKEN` is used for read-only
API calls.
