#!/usr/bin/env bash
# Shared helpers for install.sh and restore.sh.
# Sourced at runtime, not executed directly.

# pe_init_script_lookup
#
# Locate any registered TrueNAS init script related to this sysext (matches
# "prometheus-exporters-preinit" or ".config/prometheus-exporters" in the
# command/script field). Used by install.sh for --check probing and
# registration updates, and by restore.sh for deregistration.
#
# Prints:
#   <id>|<when>|<enabled>  if found (when=PREINIT/POSTINIT/...; enabled=True/False)
#   (empty)                if no matching script is registered
#   error                  if midclt is unreachable / response unparseable
#
# Always exits 0; callers branch on the printed token.
pe_init_script_lookup() {
    local result
    result=$(midclt call initshutdownscript.query 2>/dev/null \
        | python3 -c '
import sys, json
try:
    scripts = json.load(sys.stdin)
    for s in scripts:
        cmd = s.get("command", "") or s.get("script", "")
        if "prometheus-exporters-preinit" in cmd or ".config/prometheus-exporters" in cmd:
            print("%s|%s|%s" % (s["id"], s.get("when", ""), s.get("enabled", False)), end="")
            sys.exit(0)
except Exception:
    print("error", end="")
' 2>/dev/null) || result=error
    printf '%s' "$result"
}

# pe_available_exporters
#
# Echo the list of exporters the merged sysext provides, one per line, read
# from the manifest the build writes. Empty output if the sysext is not
# merged (manifest absent).
pe_available_exporters() {
    local manifest="/usr/lib/prometheus-exporters/exporters.txt"
    [ -f "$manifest" ] && grep -v '^[[:space:]]*$' "$manifest" || true
}
