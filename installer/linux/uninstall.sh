#!/usr/bin/env bash
# DisplayXR Linux bundle uninstaller (displayxr-runtime #781 Phase 3).
#
# Removes the DisplayXR components this bundle installed. Does NOT touch the
# commercial Leia SR runtime (leiasr-runtime) — that ships and is managed
# separately by the SR vendor.
#
#   sudo ./uninstall.sh            # remove displayxr-leia-sr + displayxr-runtime
#   sudo ./uninstall.sh --purge    # also purge config (active_runtime.json, etc.)

set -euo pipefail

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

command -v apt-get >/dev/null 2>&1 || { echo "error: apt-get not found (Debian/Ubuntu only)." >&2; exit 1; }
if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo -- "$0" "$@"; fi
    echo "error: run as root." >&2; exit 1
fi

export DEBIAN_FRONTEND=noninteractive
OP="remove"; [ "$PURGE" = 1 ] && OP="purge"

# Remove the plug-in first (it Depends: displayxr-runtime), then the runtime.
# `|| true` per package so a not-installed component doesn't abort the rest.
for pkg in displayxr-leia-sr displayxr-runtime; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "==> apt-get $OP $pkg"
        apt-get "$OP" -y "$pkg" || true
    else
        echo "==> $pkg not installed — skipping"
    fi
done

echo "Done. (The Leia SR runtime, if installed, was left untouched.)"
