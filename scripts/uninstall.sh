#!/usr/bin/env bash
# Uninstall the prometheus-exporters sysext. Thin alias for restore.sh, kept
# under this name because users searching for "uninstall" won't grep for
# "restore". restore.sh is still shipped in releases.
#
# Usage: curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/prometheus-exporters/main/get.sh \
#          | sudo bash -s -- --uninstall
#    or: sudo ./uninstall.sh                  (runs the restore.sh beside it)
#    or: curl -fsSL <release-url>/uninstall.sh | sudo bash
#
# With no restore.sh beside it (curl | bash), it fetches restore.sh and
# prometheus-exporters-lib.sh from the newest release a hardware test approved
# for this box's TrueNAS train, or from --release=TAG.

set -euo pipefail

REPO="${PROMETHEUS_EXPORTERS_REPO:-truenas-community-sysexts/prometheus-exporters}"
WORK_DIR=""

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

main() {
    local tag="" arg dir base f
    local -a args=()
    for arg in "$@"; do
        case "$arg" in
            --release=*)
                tag="${arg#*=}"
                [ -n "$tag" ] || { echo "ERROR: --release= requires a tag, e.g. --release=v2026.07.15-r5" >&2; exit 2; }
                ;;
            *) args+=("$arg") ;;
        esac
    done

    dir="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "${dir}/restore.sh" ]; then
        exec bash "${dir}/restore.sh" ${args[@]+"${args[@]}"}
    fi

    # Fallback: stdin path (curl | sudo bash). Fetch restore.sh + lib from the
    # pinned release, else the newest one approved for this box's train.
    if [ -z "$tag" ]; then
        tag=$(approved_release_tag) || exit 1
    fi
    base="https://github.com/${REPO}/releases/download/${tag}"
    echo "uninstall.sh: fetching restore.sh + prometheus-exporters-lib.sh from ${REPO} release ${tag}..." >&2
    WORK_DIR=$(mktemp -d /tmp/pe-uninstall.XXXXXXXXXX)
    trap 'rm -rf "$WORK_DIR"' EXIT
    # restore.sh sources the lib beside it, so both come from this release.
    for f in restore.sh prometheus-exporters-lib.sh; do
        if ! curl -fsSL --max-time 60 "${base}/${f}" -o "${WORK_DIR}/${f}" || [ ! -s "${WORK_DIR}/${f}" ]; then
            echo "ERROR: failed to download ${f} from ${REPO} release ${tag}" >&2; exit 1
        fi
    done
    bash "${WORK_DIR}/restore.sh" ${args[@]+"${args[@]}"}
}

# Called on the last line, so bash has read this whole script before
# anything runs and restore.sh cannot swallow the rest of it from stdin.
main "$@"
