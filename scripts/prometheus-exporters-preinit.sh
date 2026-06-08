#!/usr/bin/env bash
# TrueNAS PREINIT script: activates prometheus-exporters.raw on every boot and
# (re)starts whichever exporters the operator enabled.
#
# Runs before middleware starts. Stored on the persistent pool and registered
# via midclt during install. Idempotent: safe to run on every boot.

set -euo pipefail

log() {
    echo "[prometheus-exporters-preinit] $*"
    logger -t prometheus-exporters-preinit "$*" 2>/dev/null || true
}

# --- Find persistent config via glob ---
PERSIST_DIR=""
PERSIST_DIRS=()
shopt -s nullglob
for d in /mnt/*/.config/prometheus-exporters; do
    [ -d "$d" ] && PERSIST_DIRS+=("$d")
done
shopt -u nullglob

if [ ${#PERSIST_DIRS[@]} -eq 0 ]; then
    log "No persistent config found at /mnt/*/.config/prometheus-exporters/, nothing to do"
    exit 0
fi
if [ ${#PERSIST_DIRS[@]} -gt 1 ]; then
    log "WARNING: config found on ${#PERSIST_DIRS[@]} pools: ${PERSIST_DIRS[*]}"
    log "WARNING: using ${PERSIST_DIRS[0]} (alphabetically first). Remove duplicates to silence this warning."
fi
PERSIST_DIR="${PERSIST_DIRS[0]}"

RAW="${PERSIST_DIR}/prometheus-exporters.raw"
if [ ! -f "$RAW" ]; then
    log "No prometheus-exporters.raw at ${RAW}, nothing to do"
    exit 0
fi

# --- Activate sysext directly off the data pool ---
# /run/extensions is tmpfs (gone after reboot); recreate the symlink and merge.
log "Activating prometheus-exporters sysext..."
mkdir -p /run/extensions
ln -sf "$RAW" /run/extensions/prometheus-exporters.raw
systemd-sysext refresh
ldconfig

# Expose the persistent dir at a stable, pool-independent path the unit files
# reference for their config and env-override files.
ln -sfn "$PERSIST_DIR" /run/prometheus-exporters

# Make systemd aware of the unit files the freshly-merged /usr now provides.
systemctl daemon-reload 2>/dev/null || log "WARNING: systemctl daemon-reload failed"

# --- Start whichever exporters are enabled ---
# The 'enabled' file lists one exporter (== service basename) per line. We
# start (not enable) them here; running this every boot IS the persistence.
ENABLED_FILE="${PERSIST_DIR}/enabled"
if [ ! -f "$ENABLED_FILE" ]; then
    log "No 'enabled' file; no exporters to start. Done"
    exit 0
fi

started=0
while IFS= read -r name; do
    name="${name%%#*}"                       # strip comments
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    [ -z "$name" ] && continue
    unit="${name}.service"
    if [ ! -f "/usr/lib/systemd/system/${unit}" ]; then
        log "WARNING: enabled exporter '${name}' has no unit ${unit}, skipping"
        continue
    fi
    if systemctl start "$unit" 2>/dev/null; then
        log "started ${unit}"
        started=$((started+1))
    else
        log "ERROR: failed to start ${unit} (check: systemctl status ${unit})"
    fi
done < "$ENABLED_FILE"

log "Started ${started} exporter(s). Done"
exit 0
