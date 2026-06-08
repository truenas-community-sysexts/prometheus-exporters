#!/usr/bin/env bash
# Restores the original state by stopping all exporters and removing the
# prometheus-exporters.raw sysext, its PREINIT registration, and persistent config.

set -euo pipefail

for arg in "$@"; do
    case "$arg" in
        --help)
            echo "Usage: sudo ./restore.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --help     Show this help"
            echo ""
            echo "Stops all bundled exporters, removes the sysext, deregisters the"
            echo "PREINIT script, and deletes /mnt/*/.config/prometheus-exporters."
            exit 0 ;;
        *) echo "ERROR: unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root (use sudo)" >&2; exit 1
fi

_source_pe_lib() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || dir=""
    if [ -n "$dir" ] && [ -f "${dir}/prometheus-exporters-lib.sh" ]; then
        # shellcheck source=scripts/prometheus-exporters-lib.sh
        source "${dir}/prometheus-exporters-lib.sh"; return 0
    fi
    local tmp repo
    repo="${PROMETHEUS_EXPORTERS_REPO:-truenas-community-sysexts/prometheus-exporters}"
    tmp=$(mktemp /tmp/pe-lib.XXXXXXXXXX)
    if curl -fsSL --max-time 30 \
           "https://github.com/${repo}/releases/latest/download/prometheus-exporters-lib.sh" \
           -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # shellcheck source=scripts/prometheus-exporters-lib.sh
        source "$tmp"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}
_source_pe_lib || { echo "ERROR: Could not load prometheus-exporters-lib.sh." >&2; exit 1; }

echo "=== Removing prometheus-exporters sysext ==="

# Stop every exporter service the sysext provides (whether enabled or not).
echo "Stopping exporter services..."
AVAIL="$(pe_available_exporters)"
if [ -n "$AVAIL" ]; then
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        systemctl stop "${name}.service" 2>/dev/null || true
    done <<<"$AVAIL"
else
    # Manifest gone (already unmerged?) -- stop the known units by name.
    systemctl stop 'node_exporter.service' 'smartctl_exporter.service' 'nut_exporter.service' \
                   'blackbox_exporter.service' 'snmp_exporter.service' 'ipmi_exporter.service' 2>/dev/null || true
fi

# Remove the sysext symlink and unmerge; re-merge any other sysexts that the
# blanket unmerge would otherwise leave deactivated.
echo "Removing sysext..."
rm -f /run/extensions/prometheus-exporters.raw
systemd-sysext unmerge 2>/dev/null || true
if ls /run/extensions/*.raw >/dev/null 2>&1; then
    echo "Re-merging remaining sysexts..."
    systemd-sysext refresh 2>/dev/null || echo "WARNING: Failed to re-merge remaining sysexts"
    ldconfig 2>/dev/null || true
fi
rm -f /run/prometheus-exporters
systemctl daemon-reload 2>/dev/null || true

echo ""
echo "=== Cleaning up persistence ==="
INIT_LOOKUP=$(pe_init_script_lookup)
if [ "$INIT_LOOKUP" = "error" ]; then
    echo "WARNING: Could not query TrueNAS middleware, skipping init script deregistration"
    INIT_ID=""
else
    INIT_ID="${INIT_LOOKUP%%|*}"
fi
if [ -n "$INIT_ID" ]; then
    midclt call initshutdownscript.delete "$INIT_ID" 2>/dev/null \
        && echo "Init script deregistered (id: ${INIT_ID})" \
        || echo "WARNING: Failed to deregister init script"
elif [ "$INIT_LOOKUP" != "error" ]; then
    echo "No init script found to deregister"
fi

for d in /mnt/*/.config/prometheus-exporters; do
    if [ -d "$d" ]; then
        echo "Removing persistent config: $d"
        rm -rf "$d"
    fi
done

echo "Persistence cleanup complete"
echo ""
echo "=== Restore complete ==="
echo "All bundled exporters stopped and removed."
