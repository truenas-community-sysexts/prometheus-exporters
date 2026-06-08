#!/usr/bin/env bash
# Uninstall the prometheus-exporters sysext. Thin alias for restore.sh, kept
# under this name because users searching for "uninstall" won't grep for
# "restore". restore.sh is still shipped in releases.
#
# Usage: curl -fsSL <release-url>/uninstall.sh | sudo bash
#    or: sudo ./uninstall.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "${SCRIPT_DIR}/restore.sh" ]; then
    exec bash "${SCRIPT_DIR}/restore.sh" "$@"
fi

# Fallback: stdin path (curl | sudo bash). Fetch restore.sh + lib from latest.
REPO="${PROMETHEUS_EXPORTERS_REPO:-truenas-community-sysexts/prometheus-exporters}"
BASE_URL="https://github.com/${REPO}/releases/latest/download"
echo "uninstall.sh: fetching restore.sh + prometheus-exporters-lib.sh from ${REPO}/releases/latest..." >&2
TMPDIR=$(mktemp -d /tmp/pe-uninstall.XXXXXXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
if ! curl -fsSL --max-time 60 "${BASE_URL}/restore.sh" -o "${TMPDIR}/restore.sh"; then
    echo "ERROR: failed to download restore.sh from ${REPO}/releases/latest" >&2; exit 1
fi
if [ ! -s "${TMPDIR}/restore.sh" ]; then
    echo "ERROR: downloaded restore.sh is empty" >&2; exit 1
fi
curl -fsSL --max-time 30 "${BASE_URL}/prometheus-exporters-lib.sh" -o "${TMPDIR}/prometheus-exporters-lib.sh" 2>/dev/null || true
bash "${TMPDIR}/restore.sh" "$@"
exit $?
