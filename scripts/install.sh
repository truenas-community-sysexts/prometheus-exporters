#!/usr/bin/env bash
# Installs the pre-built prometheus-exporters.raw sysext on a running TrueNAS
# system. The sysext bundles a set of Prometheus exporters (node, smartctl,
# nut, blackbox, snmp, ipmi) and their systemd units, merged into /usr.
#
# Exporters ship DISABLED. Choose which run with --enable; the choice is stored
# on the data pool and a PREINIT script (re)starts them on every boot, so the
# selection survives reboots and TrueNAS updates.
#
# Usage: curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/prometheus-exporters/main/get.sh \
#          | sudo bash -s -- --enable=node_exporter
#        (get.sh runs this script from the newest release approved for the
#        box's TrueNAS train, with --release=<that tag>)
#    or: sudo ./install.sh --enable=node_exporter,smartctl_exporter --pool=fast
#    or: sudo ./install.sh --enable=all
#    or: sudo ./install.sh --disable=ipmi_exporter
#    or: sudo ./install.sh --list          (show available / enabled exporters)
#    or: sudo ./install.sh --check         (probe an existing install)
#    or: sudo ./install.sh --dry-run
#    or: sudo ./install.sh --release=v2026.07.15-r5 --enable=all
# See --help for the full option list.
#
# Which release the image (and, when it is not beside this script, the lib)
# comes from: --release=TAG as given, else the newest release a hardware test
# approved for this box's TrueNAS train (the same rule as get.sh). With none
# approved it stops; it never falls back to GitHub's Latest or an untested build.

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

# BEGIN approved-release (a verbatim copy lives in get.sh, scripts/install.sh,
# scripts/uninstall.sh and scripts/restore.sh, each a self-contained curl|bash
# script; tests/test_release_selection.py fails CI when the copies differ)

# TrueNAS version of this box, read from the middleware. Retried: midclt can
# be briefly unavailable right after boot.
detect_truenas_version() {
    local v i
    for i in 1 2 3; do
        v=$(midclt call system.info 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["version"])
except Exception:
    pass' 2>/dev/null) || true
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
        [ "$i" -lt 3 ] && sleep 1
    done
    return 1
}

# Train key of a TrueNAS version: the major version from 26 on (26.0.0-BETA.3
# and 26.1.2 are both train 26), major.minor before that (25.10.7 is 25.10,
# 25.04.2.6 is 25.04). Fails on anything else.
truenas_train_key() {
    local v="$1" major minor
    major="${v%%.*}"
    case "$major" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$major" -ge 26 ]; then
        printf '%s\n' "$major"
        return 0
    fi
    case "$v" in *.*) ;; *) return 1 ;; esac
    minor="${v#*.}"
    minor="${minor%%[!0-9]*}"
    [ -n "$minor" ] || return 1
    printf '%s.%s\n' "$major" "$minor"
}

# Every page of the repo's releases, appended to $1 as one JSON array per
# page. Only a full page can have more behind it; anything else (short page,
# API error object) ends the loop, and the selection reports API errors.
fetch_release_pages() {
    local out="$1" page=1 page_json page_len
    : > "$out"
    while :; do
        page_json=$(curl -sS --max-time 30 "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}") \
            || { echo "ERROR: Failed to query GitHub releases" >&2; return 1; }
        printf '%s\n' "$page_json" >> "$out"
        page_len=$(printf '%s' "$page_json" | python3 -c "
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    print(0)
else:
    print(len(doc) if isinstance(doc, list) else 0)
")
        [ "$page_len" -eq 100 ] || break
        page=$((page + 1))
    done
}

# Newest release approved for train $2 on a box running TrueNAS $1, chosen
# from the release pages in $3. Prints its tag; explains on stderr and fails
# when there is none.
select_approved_release() {
    VERSION="$1" TRAIN="$2" REPO="$REPO" python3 -c "
# BEGIN release-selection (extracted verbatim by tests/test_release_selection.py;
# single-quoted strings only, \x60 stands for backtick, no dollar signs: this
# code lives inside a double-quoted bash string)
import sys, json, os, re
# stdin carries one JSON array per fetched API page, concatenated.
decoder = json.JSONDecoder()
text = sys.stdin.read()
data = []
pos = 0
while pos < len(text):
    if text[pos].isspace():
        pos += 1
        continue
    try:
        doc, pos = decoder.raw_decode(text, pos)
    except ValueError:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
    if isinstance(doc, dict) and 'message' in doc:
        msg = doc['message']
        if 'rate limit' in msg.lower():
            print('GitHub API rate limit exceeded (60 requests/hour for unauthenticated calls).', file=sys.stderr)
            print('Wait a few minutes and try again.', file=sys.stderr)
        else:
            print(f'GitHub API error: {msg}', file=sys.stderr)
        sys.exit(1)
    elif isinstance(doc, list):
        data.extend(doc)
    else:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
if not text.strip():
    print('Failed to parse GitHub API response', file=sys.stderr)
    sys.exit(1)
version = os.environ['VERSION']
train = os.environ['TRAIN']
repo = os.environ.get('REPO', '')
# The channel (preview on a BETA/RC box, else stable) no longer decides what
# installs: every box takes the newest release approved for its train. It
# only picks which hardware-test issues the no-match message points at.
vu = version.upper()
is_preview = ('-BETA' in vu) or ('-RC' in vu)
def preview_release(release):
    # This repo's v<date>-r<run> tags carry no BETA/RC marker (one release
    # serves every train), so this never fires here; it keeps the approval gate
    # below the same expression as in the per-kernel repos (coral, hailo, memryx).
    tu = release.get('tag_name', '').upper()
    return ('-BETA' in tu) or ('-RC' in tu)
# Approval gate. promote.yml writes one verified-train line into the notes
# for each train whose hardware test signed the release off. A release with a
# line for this train is approved here; lines for other trains only are not.
# A full release with no line at all predates per-train sign-off and is
# grandfathered for every train. Nothing else qualifies: there is no fallback
# to an unverified build, on stable or preview boxes.
vt_re = re.compile(r'^[ \t]*<!--\s*verified-train:\s*([^\s>]+?)\s*-->', re.M)
def verified_trains(release):
    return set(vt_re.findall(release.get('body') or ''))
def approved(release):
    trains = verified_trains(release)
    if trains:
        return train in trains
    return not release.get('prerelease') and not preview_release(release)
def published(release):
    return release.get('published_at') or release.get('created_at') or ''
candidates = [r for r in data
              if not r.get('draft')
              and approved(r)]
if not candidates:
    print(f'No release is approved for TrueNAS train {train} yet (this box runs {version}).', file=sys.stderr)
    print('A hardware test on a train approves a release for that train only, and nothing', file=sys.stderr)
    print('unapproved is installed.', file=sys.stderr)
    pending = sorted([r for r in data if not r.get('draft')], key=published, reverse=True)
    if pending:
        print('Newest releases waiting for a hardware test on this train:', file=sys.stderr)
        for r in pending[:5]:
            t = r.get('tag_name', '?')
            mark = ' (prerelease)' if r.get('prerelease') else ''
            print(f'  {t}{mark}', file=sys.stderr)
    label = 'preview-hardware-test' if is_preview else 'hardware-test'
    print('Open hardware tests (each issue title names its train):', file=sys.stderr)
    print(f'  https://github.com/{repo}/issues?q=is%3Aissue+is%3Aopen+label%3A{label}', file=sys.stderr)
    sys.exit(1)
candidates.sort(key=published, reverse=True)
print(candidates[0]['tag_name'], end='')
# END release-selection
" < "$3"
}

# The release to use on this box when none is pinned with --release: the
# newest one approved for its train. Prints the tag.
approved_release_tag() {
    local version train pages tag
    version=$(detect_truenas_version) || {
        echo "ERROR: could not read the TrueNAS version (midclt call system.info)." >&2
        echo "       Run this as root on TrueNAS, or pin a release with --release=TAG." >&2
        return 1
    }
    train=$(truenas_train_key "$version") || {
        echo "ERROR: cannot derive a TrueNAS train from version '${version}'" >&2
        return 1
    }
    pages=$(mktemp) || return 1
    if fetch_release_pages "$pages" && tag=$(select_approved_release "$version" "$train" "$pages"); then
        rm -f "$pages"
        echo "TrueNAS ${version} (train ${train}): newest approved release is ${tag}" >&2
        printf '%s\n' "$tag"
        return 0
    fi
    rm -f "$pages"
    return 1
}
# END approved-release

# The release the image and a missing lib come from, resolved once on first
# use: --release=TAG as given, else the newest release approved for this box's
# TrueNAS train. Exits when there is none (never Latest, never unapproved).
resolve_release() {
    [ -z "$RESOLVED_TAG" ] || return 0
    if [ -n "$RELEASE_TAG" ]; then
        RESOLVED_TAG="$RELEASE_TAG"
    else
        RESOLVED_TAG=$(approved_release_tag) || exit 1
    fi
    RELEASE_DL_BASE="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}"
    echo "Release: ${RESOLVED_TAG} (downloading from its assets)" >&2
}

# The resolved release's image and checksum into $WORK_DIR, verified.
download_image() {
    resolve_release
    echo "Downloading prometheus-exporters.raw from release ${RESOLVED_TAG} (${REPO})..."
    curl -fSL --max-time 600 "${RELEASE_DL_BASE}/prometheus-exporters.raw" -o "${WORK_DIR}/prometheus-exporters.raw" \
        || { echo "ERROR: Failed to download prometheus-exporters.raw from release ${RESOLVED_TAG}"; exit 1; }
    curl -fSL --max-time 600 "${RELEASE_DL_BASE}/prometheus-exporters.raw.sha256" -o "${WORK_DIR}/prometheus-exporters.raw.sha256" \
        || { echo "ERROR: Failed to download checksum"; exit 1; }
    [ -s "${WORK_DIR}/prometheus-exporters.raw" ] || { echo "ERROR: image is empty"; exit 1; }
    echo "Verifying checksum..."
    if ! (cd "$WORK_DIR" && sha256sum -c prometheus-exporters.raw.sha256); then
        echo "ERROR: Checksum verification failed!"; exit 1
    fi
    echo "Checksum OK"
}

REPO="${PROMETHEUS_EXPORTERS_REPO:-truenas-community-sysexts/prometheus-exporters}"

# --- Parse CLI arguments ---
RELEASE_TAG=""        # --release=TAG; empty = newest release approved for this train
RESOLVED_TAG=""       # set by resolve_release
RELEASE_DL_BASE=""    # that release's asset download base URL
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
        --release=*)      RELEASE_TAG="${arg#*=}"; [ -n "$RELEASE_TAG" ] || { echo "ERROR: --release= requires a tag, e.g. --release=v2026.07.15-r5" >&2; exit 2; } ;;
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
  --release=TAG        Install that release (e.g. v2026.07.15-r5). Default: the
                       newest release a hardware test approved for this box's
                       TrueNAS train; it stops if there is none.
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
    # Not beside it (curl | bash): the lib of the release in use.
    local tmp
    resolve_release
    tmp=$(mktemp /tmp/pe-lib.XXXXXXXXXX)
    if curl -fsSL --max-time 30 \
           "${RELEASE_DL_BASE}/prometheus-exporters-lib.sh" \
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

# --- Obtain the .raw (local path, or the pinned or approved release) ---
if [ -n "$LOCAL_RAW" ]; then
    LOCAL_REAL=$(realpath "$LOCAL_RAW" 2>/dev/null || echo "$LOCAL_RAW")
    STAGE_REAL=$(realpath -m "${WORK_DIR}/prometheus-exporters.raw" 2>/dev/null || echo "${WORK_DIR}/prometheus-exporters.raw")
    if [ "$LOCAL_REAL" = "$STAGE_REAL" ]; then
        echo "ERROR: input file collides with the installer's staging path." >&2; exit 2
    fi
    echo "Using local prometheus-exporters.raw: $LOCAL_RAW"
    cp "$LOCAL_RAW" "${WORK_DIR}/prometheus-exporters.raw"
else
    download_image
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
