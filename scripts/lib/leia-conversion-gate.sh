#!/usr/bin/env bash
# The rule that decides whether a bundle chains the Leia conversion component
# (versions.json `leia_conversion`, DisplayXR/displayxr-leia-conversion).
#
#   leia_plugin pin >= LEIA_CONVERSION_MIN_PLUGIN  -> CHAIN it (and require it)
#   leia_plugin pin <  LEIA_CONVERSION_MIN_PLUGIN  -> do NOT chain it
#
# Why the plug-in pin decides. Up to its 2.23.x line the Leia SR plug-in carries
# the conversion provider itself; from LEIA_CONVERSION_MIN_PLUGIN on it does not,
# and the provider ships only as the separate component. The two must switch in
# the same bundle:
#   - plug-in new, component absent: a display that had conversion loses it on
#     upgrade, so the component is REQUIRED from that pin on;
#   - plug-in old, component present: on Windows the old plug-in installer takes
#     the provider registration back (the component is then installed but not
#     the registered provider), and on Linux the component's package declares
#     Breaks/Replaces against every older plug-in package, so apt refuses the
#     pair. The component is therefore FORBIDDEN below that pin.
# (displayxr-leia-conversion docs/installer.md: "Handover", "Migration order".)
#
# The same rule lives in scripts/leia_conversion_gate.ps1 (Windows build +
# coverage check) and as LEIACONV_MIN_LEIA_VER in the bundle .nsi;
# scripts/check_bundle_coverage.ps1 fails when the three values differ.
#
# Sourced by build-bundle-linux.sh and build-bundle.sh.

LEIA_CONVERSION_MIN_PLUGIN="2.24.0"

# $1 = the leia_plugin tag (vX.Y.Z). Returns 0 = chain, 1 = do not chain,
# 2 = the tag is not a plain vX.Y.Z (callers must stop: guessing either way
# ships the wrong bundle).
leia_conversion_chained() {
    local tag="${1#v}" min="$LEIA_CONVERSION_MIN_PLUGIN"
    if [[ ! "$tag" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        echo "leia-conversion-gate: leia_plugin pin '${1:-}' is not vX.Y.Z" >&2
        return 2
    fi
    local a=("${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    local b; IFS=. read -r -a b <<< "$min"
    local i
    for i in 0 1 2; do
        if (( 10#${a[i]} > 10#${b[i]} )); then return 0; fi
        if (( 10#${a[i]} < 10#${b[i]} )); then return 1; fi
    done
    return 0
}
