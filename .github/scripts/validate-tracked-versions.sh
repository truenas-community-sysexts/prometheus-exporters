#!/usr/bin/env bash
# Validate that .github/tracked-versions.json has the shape the rest of the
# CI machinery (check-releases.yml, build.yml) assumes.
#
# Run locally:
#   .github/scripts/validate-tracked-versions.sh
# Exits non-zero with a `::error::` annotation on any shape violation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="${REPO_ROOT}/.github/tracked-versions.json"

if [ ! -f "$FILE" ]; then
  echo "::error title=tracked-versions::file not found: ${FILE}" >&2
  exit 1
fi

python3 - "$FILE" <<'PY'
import json
import re
import sys

path = sys.argv[1]

def fail(msg):
    print(f"::error title=tracked-versions::{msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    fail(f"invalid JSON in {path}: {e}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

# --- debian.suite: the Debian release the bundled FreeIPMI is pulled from.
# Pin to the OLDEST Debian base among supported TrueNAS versions: a binary
# built against an older glibc runs on newer glibc, but not vice versa.
debian = data.get("debian")
if not isinstance(debian, dict):
    fail("'debian' key missing or not an object")
suite = debian.get("suite")
if not isinstance(suite, str) or not re.match(r"^[a-z]+$", suite):
    fail(f"'debian.suite' missing or malformed (got {suite!r}); expected a Debian codename e.g. bookworm")

# --- freeipmi.package: the Debian package bundled for ipmi_exporter's runtime.
freeipmi = data.get("freeipmi")
if not isinstance(freeipmi, dict):
    fail("'freeipmi' key missing or not an object")
if not isinstance(freeipmi.get("package"), str) or not freeipmi["package"].strip():
    fail("'freeipmi.package' missing or empty")

# --- exporters: map of exporter-name -> descriptor.
exporters = data.get("exporters")
if not isinstance(exporters, dict) or not exporters:
    fail("'exporters' key missing, not an object, or empty")

name_re = re.compile(r"^[a-z0-9][a-z0-9_]*$")
tag_re = re.compile(r"^v?\d+(\.\d+)+")

for name, spec in exporters.items():
    if not name_re.match(name):
        fail(f"exporter name {name!r} malformed; expected lowercase [a-z0-9_]")
    if not isinstance(spec, dict):
        fail(f"exporter {name!r}: value must be an object")

    for key in ("repo", "version", "asset"):
        val = spec.get(key)
        if not isinstance(val, str) or not val.strip():
            fail(f"exporter {name!r}: requires non-empty '{key}'")
    if "/" not in spec["repo"]:
        fail(f"exporter {name!r}: 'repo' must be owner/name (got {spec['repo']!r})")
    if not tag_re.match(spec["version"]):
        fail(f"exporter {name!r}: 'version' must look like a release tag (got {spec['version']!r})")

    port = spec.get("port")
    if not isinstance(port, int) or not (1 <= port <= 65535):
        fail(f"exporter {name!r}: 'port' must be an integer 1-65535 (got {port!r})")

    # 'extract' optional (absent => the asset IS the raw binary).
    if "extract" in spec and (not isinstance(spec["extract"], str) or not spec["extract"].strip()):
        fail(f"exporter {name!r}: 'extract' present but empty")

    # 'config' optional: {name, from} to seed an example config from the tarball.
    cfg = spec.get("config")
    if cfg is not None:
        if "extract" not in spec:
            fail(f"exporter {name!r}: 'config' requires 'extract' (config comes from inside the archive)")
        for key in ("name", "from"):
            if not isinstance(cfg.get(key), str) or not cfg[key].strip():
                fail(f"exporter {name!r}: config.{key} missing or empty")

n = len(exporters)
print(f"tracked-versions OK: {n} exporters on Debian {suite}, freeipmi={freeipmi['package']}")
PY
