# Build Guide

All builds run in GitHub Actions. The Go exporters are downloaded prebuilt; the
only compiled-language dependency (FreeIPMI) is pulled from Debian, so there's
no source compilation here.

## The pipeline

`.github/workflows/build.yml`:

1. **resolve**: reads `debian.suite` (or the `suite` input).
2. **build**: runs in a `debian:<suite>-slim` container and:
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
3. **release**: publishes a GitHub **pre-release** tagged
   `v<YYYY.MM.DD>-r<run>` with the `.raw`, its `.sha256`, and the scripts
   `get.sh` uses (`install.sh`, `prometheus-exporters-lib.sh`, `uninstall.sh`,
   `restore.sh`), then opens one hardware-test issue per TrueNAS train in
   `tracked-versions.json` (`trains`): label `hardware-test` for a stable train,
   `preview-hardware-test` for a preview one.

Run a build from the Actions tab (**Build prometheus-exporters Sysext** →
*Run workflow*). There is no publish-straight-to-Latest option: every release
starts as a pre-release and is approved per train (below).

## Per-train approval

One release serves every TrueNAS train (the exporters are userspace only), but
a hardware test approves it for its own train only:

- Each hardware-test issue names its train in the title and carries
  `<!-- release-tag -->` and `<!-- train -->` markers.
- Closing it as **completed** runs `promote.yml`, which appends
  `<!-- verified-train: <key> -->` to the release notes. On the release's first
  approval the same update turns the pre-release into a full release and
  appends the changelog, so a full release never exists without a marker.
- GitHub's "Latest" follows the newest release approved for a stable train. It
  is cosmetic: `get.sh` and the scripts select by the markers, not by Latest.
- A full release with **no** marker counts as approved for every train. That is
  how the releases from before per-train approval stay installable, and why
  there is no way to publish straight to Latest: such a release would reach
  every box untested.

## `tracked-versions.json`

```jsonc
{
  "debian": { "suite": "bookworm" },          // FreeIPMI is built against this
  "freeipmi": { "package": "freeipmi-tools" },
  "trains": [                                 // one hardware-test issue each per release
    { "key": "25.10", "name": "TrueNAS 25.10", "channel": "stable" },
    { "key": "26", "name": "TrueNAS 26 beta", "channel": "preview" }
  ],
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

`trains` lists every TrueNAS train a release supports. `key` is the train key
`get.sh` derives from the TrueNAS version (the major from 26 on, major.minor
before, e.g. `25.10`) and the value `promote.yml` writes into the
`verified-train` marker; `name` goes into the issue title; `channel` is
`stable` or `preview` and picks the issue label. When TrueNAS 26.0 goes GA, `26`
becomes a stable train.

The shape is enforced by `.github/scripts/validate-tracked-versions.sh`, and
`tests/` (run by the lint workflow) checks each key is one `get.sh` can derive.

## Adding an exporter

1. Add an entry under `exporters` with the repo, current tag, and the
   `asset`/`extract` patterns (download a release once and `tar tzf` it to get
   the exact internal path - the version usually appears in both).
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
asset/extract templates handle the rest), pushes, and dispatches `build.yml`.
That publishes a pre-release and opens one hardware-test issue per train;
closing each as completed after testing approves it for that train.

Pushing to `main` needs a `CHECK_BUILDS` repository secret (a PAT that can
bypass the branch ruleset); the default `GITHUB_TOKEN` is used for read-only
API calls.
