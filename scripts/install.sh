#!/usr/bin/env bash
# Installs the pre-built prometheus-exporters.raw sysext on a running TrueNAS
# system. The sysext bundles a set of Prometheus exporters (node, smartctl,
# nut, blackbox, snmp, ipmi) and their systemd units, merged into /usr.
#
# Exporters ship DISABLED. Choose which run with --enable; the choice is stored
# on the data pool and a PREINIT script (re)starts them on every boot, so the
# selection survives reboots and TrueNAS updates.
#
# Usage: curl -fsSL <release-url>/install.sh | sudo bash -s -- --enable=node_exporter
#    or: sudo ./install.sh --enable=node_exporter,smartctl_exporter --pool=fast
#    or: sudo ./install.sh --enable=all
#    or: sudo ./install.sh --disable=ipmi_exporter
#    or: sudo ./install.sh --list          (show available / enabled exporters)
#    or: sudo ./install.sh --check         (probe an existing install)
#    or: sudo ./install.sh --dry-run
# See --help for the full option list.

set -euo pipefail

CONFIG_EXPORTERS="blackbox_exporter snmp_exporter"   # exporters that read a config file
FREEIPMI_PROBE="/usr/sbin/ipmimonitoring"            # presence => FreeIPMI bundled OK

# in_list <needle> <space-separated-haystack> -> 0 if present
in_list() {
    local needle="$1" hay="$2" x
    for x in $hay; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

# port_for <exporter> -> upstream default listen port (informational only;
# an operator can override via env/<name>.env ARGS=--web.listen-address=...).
port_for() {
    case "$1" in
        node_exporter)     echo 9100 ;;
        smartctl_exporter) echo 9633 ;;
        nut_exporter)      echo 9199 ;;
        blackbox_exporter) echo 9115 ;;
        snmp_exporter)     echo 9116 ;;
        ipmi_exporter)     echo 9290 ;;
        *)                 echo "?" ;;
    esac
}

# do_check: read-only probe of an existing install.
do_check() {
    local pass=0 warn=0 fail=0
    local -a status_lines=() hint_lines=()
    record_pass() { status_lines+=("  [OK] $1"); pass=$((pass+1)); }
    record_warn() { status_lines+=("  [!!] $1"); warn=$((warn+1)); [ -n "${2:-}" ] && hint_lines+=("    -> $2"); }
    record_fail() { status_lines+=("  [XX] $1"); fail=$((fail+1)); [ -n "${2:-}" ] && hint_lines+=("    -> $2"); }

    echo "=== prometheus-exporters install status ==="
    echo ""

    # 1. Sysext merged
    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx prometheus-exporters; then
        record_pass "Sysext merged into /usr"
    else
        record_warn "Sysext not currently merged" "the PREINIT script merges it on boot; reboot or re-run install.sh"
    fi

    # 2. Persistent config + stable /run path
    local persist_dir=""
    if resolve_persist_dir; then
        persist_dir="$PERSIST_DIR"
        record_pass "Persistent config at ${persist_dir}"
    else
        record_fail "No persistent config resolved" "re-run install.sh with --pool=NAME or --persist-path=PATH"
    fi
    if [ -L /run/prometheus-exporters ] && [ -d /run/prometheus-exporters ]; then
        record_pass "/run/prometheus-exporters resolves (units can find configs/env)"
    else
        record_warn "/run/prometheus-exporters missing" "the PREINIT script recreates it on boot; reboot or re-run install.sh"
    fi

    # 3. Backup + PREINIT script on disk
    if [ -n "$persist_dir" ] && [ -f "${persist_dir}/prometheus-exporters.raw" ]; then
        record_pass "Backup ${persist_dir}/prometheus-exporters.raw present"
    elif [ -n "$persist_dir" ]; then
        record_fail "Backup prometheus-exporters.raw missing in ${persist_dir}" "re-run install.sh"
    fi
    if [ -n "$persist_dir" ] && [ -x "${persist_dir}/prometheus-exporters-preinit.sh" ]; then
        record_pass "PREINIT script present and executable"
    elif [ -n "$persist_dir" ]; then
        record_fail "PREINIT script missing or not executable in ${persist_dir}" "re-run install.sh"
    fi

    # 4. PREINIT registered with middleware
    if command -v midclt >/dev/null 2>&1; then
        local lookup w en
        lookup=$(pe_init_script_lookup)
        case "$lookup" in
            error) record_warn "Could not query TrueNAS middleware" "run with sudo on TrueNAS SCALE" ;;
            "")    record_fail "No init script registered" "re-run install.sh" ;;
            *) IFS='|' read -r _ w en <<<"$lookup"
               if [ "$w" = "PREINIT" ] && [ "$en" = "True" ]; then
                   record_pass "PREINIT script registered (PREINIT, enabled)"
               else
                   record_warn "Init script registered but not as enabled PREINIT" "re-run install.sh to fix"
               fi ;;
        esac
    else
        record_warn "midclt not available, skipping middleware check" "this script must run on TrueNAS SCALE"
    fi

    # 5. Per-enabled-exporter checks: binary present, service active, config seeded
    local enabled=""
    [ -n "$persist_dir" ] && [ -f "${persist_dir}/enabled" ] && \
        enabled=$(grep -v '^[[:space:]]*$' "${persist_dir}/enabled" 2>/dev/null | tr '\n' ' ')
    if [ -z "$enabled" ]; then
        record_warn "No exporters enabled" "enable some with: sudo ./install.sh --enable=node_exporter,smartctl_exporter"
    else
        local name
        for name in $enabled; do
            if [ -x "/usr/bin/${name}" ]; then
                record_pass "${name}: binary present"
            else
                record_fail "${name}: binary /usr/bin/${name} missing" "is the sysext merged?"
            fi
            if systemctl is-active --quiet "${name}.service" 2>/dev/null; then
                record_pass "${name}: service active"
            else
                record_fail "${name}: service not active" "systemctl status ${name}.service; journalctl -u ${name}.service"
            fi
            if in_list "$name" "$CONFIG_EXPORTERS"; then
                local cfg="${name%_exporter}"; cfg="${persist_dir}/configs/${cfg}.yml"
                [ -f "$cfg" ] && record_pass "${name}: config ${cfg} present" \
                              || record_fail "${name}: config ${cfg} missing" "re-run install.sh to re-seed defaults"
            fi
            if [ "$name" = "ipmi_exporter" ]; then
                [ -x "$FREEIPMI_PROBE" ] && record_pass "ipmi_exporter: bundled FreeIPMI present" \
                                        || record_fail "ipmi_exporter: FreeIPMI ($FREEIPMI_PROBE) missing" "is the sysext merged?"
            fi
        done
    fi

    # 6. PREINIT result this boot
    if command -v journalctl >/dev/null 2>&1; then
        local plog
        plog=$(journalctl -b -t prometheus-exporters-preinit --no-pager -o cat 2>/dev/null || true)
        if [ -z "$plog" ]; then
            record_warn "No preinit entries this boot" "reboot after install, or re-run install.sh"
        elif printf '%s' "$plog" | grep -q '^ERROR:'; then
            record_warn "PREINIT logged an error this boot" "see: journalctl -b -t prometheus-exporters-preinit"
        elif printf '%s' "$plog" | tail -1 | grep -q 'Done'; then
            record_pass "PREINIT completed this boot"
        else
            record_warn "PREINIT ran but did not log the Done sentinel" "see: journalctl -b -t prometheus-exporters-preinit"
        fi
    fi

    printf '%s\n' "${status_lines[@]}"
    echo ""
    if [ "${#hint_lines[@]}" -gt 0 ]; then printf '%s\n' "${hint_lines[@]}"; echo ""; fi
    printf 'Summary: %d ok, %d warn, %d fail\n' "$pass" "$warn" "$fail"
    [ "$fail" -gt 0 ] && return 1
    return 0
}

if_real() {
    if [ "$DRY_RUN" = "1" ]; then printf '[dry-run] would: %s\n' "$*"; else "$@"; fi
}

# resolve_persist_dir: identical pool-detection logic to the other repos.
resolve_persist_dir() {
    PERSIST_DIR=""
    local d p
    local -a existing=() pools=() choices=()
    local header n i

    if [ -n "${PERSIST_PATH:-}" ]; then PERSIST_DIR="$PERSIST_PATH"; return 0; fi
    if [ -n "${POOL_NAME:-}" ]; then PERSIST_DIR="/mnt/${POOL_NAME}/.config/prometheus-exporters"; return 0; fi

    shopt -s nullglob
    for d in /mnt/*/.config/prometheus-exporters; do [ -d "$d" ] && existing+=("$d"); done
    shopt -u nullglob

    if [ "${#existing[@]}" -eq 1 ]; then
        PERSIST_DIR="${existing[0]}"; echo "Re-using existing config: $PERSIST_DIR"; return 0
    fi

    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "boot-pool" ] && pools+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)

    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 0 ]; then
        echo "ERROR: No ZFS pool found (excluding boot-pool). Cannot set up persistence." >&2
        echo "  Re-run with --pool=<name> or --persist-path=/mnt/<pool>/<path>" >&2
        return 1
    fi
    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/prometheus-exporters"
        echo "Auto-selected pool: ${pools[0]} -> $PERSIST_DIR"; return 0
    fi
    if [ "${#existing[@]}" -gt 1 ]; then
        header="Found existing prometheus-exporters configs on multiple pools:"; choices=("${existing[@]}")
    else
        header="Multiple data pools available (no existing config):"
        for p in "${pools[@]}"; do choices+=("/mnt/${p}/.config/prometheus-exporters"); done
    fi
    if ! { : </dev/tty; } 2>/dev/null; then
        echo "ERROR: $header" >&2
        echo "  No controlling terminal. Pass --pool=<name> or --persist-path=<path>." >&2
        return 1
    fi
    echo "$header"
    for i in "${!choices[@]}"; do echo "  [$((i+1))] ${choices[$i]}"; done
    while true; do
        printf 'Pick one (1-%d): ' "${#choices[@]}"
        read -r n </dev/tty || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#choices[@]}" ]; then
            PERSIST_DIR="${choices[$((n-1))]}"; echo "Selected: $PERSIST_DIR"; return 0
        fi
        echo "  Invalid. Enter 1-${#choices[@]}."
    done
}

REPO="${PROMETHEUS_EXPORTERS_REPO:-truenas-community-sysexts/prometheus-exporters}"

# --- Parse CLI arguments ---
LOCAL_RAW=""
POOL_NAME=""
PERSIST_PATH=""
CHECK_MODE=0
DRY_RUN=0
LIST_MODE=0
ENABLE_CSV=""
DISABLE_CSV=""

for arg in "$@"; do
    case "$arg" in
        --repo=*)         REPO="${arg#*=}"; [ -n "$REPO" ] || { echo "ERROR: --repo= requires a value" >&2; exit 2; } ;;
        --pool=*)         POOL_NAME="${arg#*=}"; [ -n "$POOL_NAME" ] || { echo "ERROR: --pool= requires a value" >&2; exit 2; } ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}"; [ -n "$PERSIST_PATH" ] || { echo "ERROR: --persist-path= requires a value" >&2; exit 2; } ;;
        --enable=*)       ENABLE_CSV="${arg#*=}" ;;
        --disable=*)      DISABLE_CSV="${arg#*=}" ;;
        --list)           LIST_MODE=1 ;;
        --check)          CHECK_MODE=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --help)
            cat <<'HELP'
Usage: sudo ./install.sh [OPTIONS] [path-to-prometheus-exporters.raw]

Options:
  --enable=LIST        Comma-separated exporters to enable (or 'all').
                       e.g. --enable=node_exporter,smartctl_exporter
  --disable=LIST       Comma-separated exporters to disable.
  --list               Show available and currently-enabled exporters.
  --pool=NAME          ZFS pool for persistent config (e.g. fast).
  --persist-path=PATH  Exact path; must be /mnt/<pool>/.config/prometheus-exporters.
  --repo=OWNER/NAME    Download release from a fork (or PROMETHEUS_EXPORTERS_REPO env).
  --check              Probe an existing install (read-only) and report status.
  --dry-run            Validate without changing anything.
  --help               Show this help.

Examples:
  sudo ./install.sh --enable=node_exporter,smartctl_exporter --pool=fast
  sudo ./install.sh --enable=all
  sudo ./install.sh --disable=ipmi_exporter
  sudo ./install.sh --list
  sudo ./install.sh --check
HELP
            exit 0 ;;
        *)
            if [ -f "$arg" ]; then LOCAL_RAW="$arg"
            elif [[ "$arg" == -* ]]; then echo "ERROR: unknown option: $arg (see --help)" >&2; exit 2
            else echo "ERROR: positional argument is not an existing file: $arg" >&2; exit 2; fi ;;
    esac
done

if [ "$CHECK_MODE" = "1" ] && [ "$DRY_RUN" = "1" ]; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2; exit 2
fi

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root (use sudo)" >&2; exit 1
fi

if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/prometheus-exporters/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/prometheus-exporters (got: ${PERSIST_PATH})" >&2
        echo "  The boot-time PREINIT script only scans /mnt/*/.config/prometheus-exporters." >&2
        echo "  Pass --pool=<name> instead." >&2
        exit 2
    fi
fi

# Source shared library (provides pe_init_script_lookup, pe_available_exporters).
_source_pe_lib() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || dir=""
    if [ -n "$dir" ] && [ -f "${dir}/prometheus-exporters-lib.sh" ]; then
        # shellcheck source=scripts/prometheus-exporters-lib.sh
        source "${dir}/prometheus-exporters-lib.sh"; return 0
    fi
    local tmp
    tmp=$(mktemp /tmp/pe-lib.XXXXXXXXXX)
    if curl -fsSL --max-time 30 \
           "https://github.com/${REPO}/releases/latest/download/prometheus-exporters-lib.sh" \
           -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        # shellcheck source=scripts/prometheus-exporters-lib.sh
        source "$tmp"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}
_source_pe_lib || {
    echo "ERROR: Could not load prometheus-exporters-lib.sh (not found locally, download failed)." >&2
    exit 1
}

if [ "$CHECK_MODE" = "1" ]; then do_check; exit $?; fi

if [ "$LIST_MODE" = "1" ]; then
    echo "Available exporters (from merged sysext):"
    avail=$(pe_available_exporters)
    if [ -z "$avail" ]; then
        echo "  (sysext not merged yet -- install first, then --list)"
    else
        printf '%s\n' "$avail" | sed 's/^/  /'
    fi
    if resolve_persist_dir >/dev/null 2>&1 && [ -f "${PERSIST_DIR}/enabled" ]; then
        echo "Enabled:"
        grep -v '^[[:space:]]*$' "${PERSIST_DIR}/enabled" | sed 's/^/  /' || echo "  (none)"
    else
        echo "Enabled: (none)"
    fi
    exit 0
fi

WORK_DIR=$(mktemp -d /tmp/pe-install.XXXXXXXXXX)
cleanup() { [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT INT TERM

# --- Obtain the .raw (local path or latest release) ---
if [ -n "$LOCAL_RAW" ]; then
    LOCAL_REAL=$(realpath "$LOCAL_RAW" 2>/dev/null || echo "$LOCAL_RAW")
    STAGE_REAL=$(realpath -m "${WORK_DIR}/prometheus-exporters.raw" 2>/dev/null || echo "${WORK_DIR}/prometheus-exporters.raw")
    if [ "$LOCAL_REAL" = "$STAGE_REAL" ]; then
        echo "ERROR: input file collides with the installer's staging path." >&2; exit 2
    fi
    echo "Using local prometheus-exporters.raw: $LOCAL_RAW"
    cp "$LOCAL_RAW" "${WORK_DIR}/prometheus-exporters.raw"
else
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
    echo "Downloading latest prometheus-exporters.raw from ${REPO}..."
    curl -fSL --max-time 600 "${BASE_URL}/prometheus-exporters.raw" -o "${WORK_DIR}/prometheus-exporters.raw" \
        || { echo "ERROR: Failed to download prometheus-exporters.raw"; exit 1; }
    curl -fSL --max-time 600 "${BASE_URL}/prometheus-exporters.raw.sha256" -o "${WORK_DIR}/prometheus-exporters.raw.sha256" \
        || { echo "ERROR: Failed to download checksum"; exit 1; }
    [ -s "${WORK_DIR}/prometheus-exporters.raw" ] || { echo "ERROR: image is empty"; exit 1; }
    echo "Verifying checksum..."
    if ! (cd "$WORK_DIR" && sha256sum -c prometheus-exporters.raw.sha256); then
        echo "ERROR: Checksum verification failed!"; exit 1
    fi
    echo "Checksum OK"
fi

# --- Extract the PREINIT script from the sysext ---
echo ""
echo "=== Extracting PREINIT script from prometheus-exporters.raw ==="
if ! command -v unsquashfs &>/dev/null; then
    echo "ERROR: unsquashfs not found (install squashfs-tools)"; exit 1
fi
unsquashfs -q -d "${WORK_DIR}/unpack" "${WORK_DIR}/prometheus-exporters.raw" \
    usr/lib/prometheus-exporters/prometheus-exporters-preinit.sh
BUNDLED_PREINIT="${WORK_DIR}/unpack/usr/lib/prometheus-exporters/prometheus-exporters-preinit.sh"
if [ ! -f "$BUNDLED_PREINIT" ]; then
    echo "ERROR: preinit script not found in sysext. Re-fetch a current release." >&2; exit 1
fi
cp "$BUNDLED_PREINIT" "${WORK_DIR}/preinit.sh"; chmod +x "${WORK_DIR}/preinit.sh"
rm -rf "${WORK_DIR}/unpack"
echo "PREINIT script extracted"

# --- Resolve pool, place image, activate ---
echo ""
echo "=== Installing prometheus-exporters.raw ==="
if ! resolve_persist_dir; then echo "ERROR: No persistent storage pool found." >&2; exit 1; fi
echo "Persistent config directory: ${PERSIST_DIR}"
if_real mkdir -p "$PERSIST_DIR" "${PERSIST_DIR}/configs" "${PERSIST_DIR}/env"
RAW_DEST="${PERSIST_DIR}/prometheus-exporters.raw"
echo "Installing image to ${RAW_DEST}..."
if_real cp "${WORK_DIR}/prometheus-exporters.raw" "${RAW_DEST}"

echo "Removing old sysext symlink..."
if_real rm -f /run/extensions/prometheus-exporters.raw
if [ "$DRY_RUN" != "1" ]; then
    UNMERGE_ERR=$(systemd-sysext unmerge 2>&1) || {
        if printf '%s' "$UNMERGE_ERR" | grep -qi "no extensions"; then true
        else echo "ERROR: systemd-sysext unmerge failed: ${UNMERGE_ERR}" >&2; exit 1; fi
    }
else
    echo "[dry-run] would: systemd-sysext unmerge"
fi
echo "Activating sysext..."
if_real mkdir -p /run/extensions
if_real ln -sf "${RAW_DEST}" /run/extensions/prometheus-exporters.raw
if_real systemd-sysext refresh
if_real ldconfig
# Stable, pool-independent path the unit files reference.
if_real ln -sfn "$PERSIST_DIR" /run/prometheus-exporters
if_real systemctl daemon-reload

# --- Seed default configs (only if absent, to preserve operator edits) ---
SEED_DIR="/usr/lib/prometheus-exporters/configs-seed"
if [ "$DRY_RUN" != "1" ] && [ -d "$SEED_DIR" ]; then
    for f in "$SEED_DIR"/*; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        if [ ! -f "${PERSIST_DIR}/configs/${base}" ]; then
            cp "$f" "${PERSIST_DIR}/configs/${base}"
            echo "Seeded default config: configs/${base}"
        else
            echo "Keeping existing config: configs/${base}"
        fi
    done
fi

# --- Resolve the enabled set ---
AVAILABLE="$(pe_available_exporters | tr '\n' ' ')"
if [ -z "$AVAILABLE" ] && [ "$DRY_RUN" != "1" ]; then
    echo "ERROR: sysext merged but no exporter manifest found; aborting." >&2; exit 1
fi

# Start from the existing enabled set.
declare -a ENABLED=()
if [ -f "${PERSIST_DIR}/enabled" ]; then
    while IFS= read -r ln; do
        ln="$(printf '%s' "$ln" | tr -d '[:space:]')"; [ -n "$ln" ] && ENABLED+=("$ln")
    done < "${PERSIST_DIR}/enabled"
fi

set_contains() { local x; for x in "${ENABLED[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
set_add() { set_contains "$1" || ENABLED+=("$1"); }
set_remove() { local -a keep=(); local x; for x in "${ENABLED[@]:-}"; do [ "$x" != "$1" ] && keep+=("$x"); done; ENABLED=("${keep[@]:-}"); }

# Expand and validate --enable
if [ -n "$ENABLE_CSV" ]; then
    if [ "$ENABLE_CSV" = "all" ]; then
        ENABLED=(); for x in $AVAILABLE; do ENABLED+=("$x"); done
    else
        IFS=',' read -r -a req <<<"$ENABLE_CSV"
        for x in "${req[@]}"; do
            x="$(printf '%s' "$x" | tr -d '[:space:]')"; [ -z "$x" ] && continue
            if ! in_list "$x" "$AVAILABLE"; then
                echo "ERROR: --enable: unknown exporter '$x'. Available: ${AVAILABLE}" >&2; exit 2
            fi
            set_add "$x"
        done
    fi
fi
# Expand and validate --disable
if [ -n "$DISABLE_CSV" ]; then
    IFS=',' read -r -a req <<<"$DISABLE_CSV"
    for x in "${req[@]}"; do
        x="$(printf '%s' "$x" | tr -d '[:space:]')"; [ -z "$x" ] && continue
        set_remove "$x"
    done
fi

# Persist the enabled set.
if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would: write enabled set: ${ENABLED[*]:-(none)}"
else
    : > "${PERSIST_DIR}/enabled"
    for x in "${ENABLED[@]:-}"; do [ -n "$x" ] && echo "$x" >> "${PERSIST_DIR}/enabled"; done
    printf '%s' "$REPO" > "${PERSIST_DIR}/.prometheus-exporters-repo"
    cp "${WORK_DIR}/preinit.sh" "${PERSIST_DIR}/prometheus-exporters-preinit.sh"
    chmod +x "${PERSIST_DIR}/prometheus-exporters-preinit.sh"
fi

# --- Apply service state now: (re)start enabled, stop the rest ---
if [ "$DRY_RUN" != "1" ]; then
    echo ""
    echo "=== Applying exporter state ==="
    for name in $AVAILABLE; do
        if set_contains "$name"; then
            if systemctl restart "${name}.service" 2>/dev/null; then
                echo "  started ${name}"
            else
                echo "  WARNING: failed to start ${name} (systemctl status ${name}.service)"
            fi
        else
            systemctl stop "${name}.service" 2>/dev/null || true
        fi
    done
fi

# --- Register the PREINIT script ---
echo ""
echo "=== Setting up persistence ==="
PREINIT_SCRIPT="${PERSIST_DIR}/prometheus-exporters-preinit.sh"
EXISTING_LOOKUP=$(pe_init_script_lookup)
if [ "$EXISTING_LOOKUP" = "error" ]; then
    echo "ERROR: Could not query TrueNAS middleware to check for existing init scripts." >&2
    echo "  Refusing to register without a clean lookup. Check 'midclt call initshutdownscript.query'." >&2
    exit 1
fi
EXISTING_ID="${EXISTING_LOOKUP%%|*}"
PREINIT_PAYLOAD=$(PREINIT_SCRIPT="$PREINIT_SCRIPT" python3 -c '
import json, os
print(json.dumps({
    "type": "COMMAND",
    "command": os.environ["PREINIT_SCRIPT"],
    "when": "PREINIT",
    "enabled": True,
    "timeout": 60,
    "comment": "Activate prometheus-exporters sysext and start enabled exporters",
}))
')
if [ -n "$EXISTING_ID" ]; then
    echo "Init script already registered (id: ${EXISTING_ID}), updating to PREINIT..."
    if ! if_real midclt call initshutdownscript.update "$EXISTING_ID" "$PREINIT_PAYLOAD"; then
        echo "ERROR: Failed to update init script (id: ${EXISTING_ID})." >&2
        echo "ERROR: Without it, enabled exporters will NOT restart after a reboot." >&2
        exit 1
    fi
else
    if ! if_real midclt call initshutdownscript.create "$PREINIT_PAYLOAD"; then
        echo "ERROR: Failed to register PREINIT script via midclt." >&2
        echo "ERROR: Without it, enabled exporters will NOT restart after a reboot." >&2
        exit 1
    fi
    echo "PREINIT script registered"
fi

echo ""
echo "=== Done ==="
echo "Persistent config: ${PERSIST_DIR}/"
echo "  prometheus-exporters.raw       - sysext image (backup + activation source)"
echo "  prometheus-exporters-preinit.sh - PREINIT: re-activates + restarts enabled exporters"
echo "  enabled                         - one exporter per line (edit via --enable/--disable)"
echo "  configs/                        - editable exporter configs (blackbox.yml, snmp.yml)"
echo "  env/<name>.env                  - optional per-exporter overrides (ARGS=...)"
echo ""
if [ "${#ENABLED[@]}" -eq 0 ] || [ -z "${ENABLED[0]:-}" ]; then
    echo "No exporters enabled yet. Enable some, e.g.:"
    echo "  sudo ./install.sh --enable=node_exporter,smartctl_exporter"
else
    echo "Enabled exporters and their default ports:"
    for name in "${ENABLED[@]}"; do
        [ -z "$name" ] && continue
        echo "  ${name}  (http://<host>:$(port_for "$name")/metrics)"
    done
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== Dry-run complete (no changes made) ==="
fi
