#!/usr/bin/env bash
# DisplayXR Linux bundle uninstaller (displayxr-runtime #781 Phase 3).
#
# Removes the DisplayXR components this bundle installed. Does NOT touch the
# commercial Leia SR runtime (leiasr-runtime) or the Leia conversion runtime —
# those ship and are managed separately by the display maker.
#
#   sudo ./uninstall.sh            # remove every package this bundle installed
#   sudo ./uninstall.sh --purge    # also purge config (active_runtime.json, etc.)
#
# "Every package this bundle installed" = the packages of the .debs bundled next
# to this script (the demos too), plus the core names below in case the debs/
# directory is gone. Before 2026-11-28 only the core list was removed, so every
# bundled demo stayed installed after an uninstall.

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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_FIRST="displayxr-leia-conversion"
CORE_LAST="displayxr-leia-sr displayxr-runtime"

# Package names of the bundled .debs, minus the ones handled in fixed order.
BUNDLED=""
shopt -s nullglob
for d in "$HERE"/debs/*.deb; do
    p="$(dpkg-deb -f "$d" Package 2>/dev/null || true)"
    case " $CORE_FIRST $CORE_LAST $BUNDLED " in
        *" $p "*) ;;
        *) [ -n "$p" ] && BUNDLED="$BUNDLED $p" ;;
    esac
done
shopt -u nullglob

# Apps and the conversion component first, then the Leia plug-in, then the
# runtime they all Depend on. `|| true` per package so a not-installed
# component doesn't abort the rest.
# shellcheck disable=SC2086  # word splitting of the package lists is intended
for pkg in $BUNDLED $CORE_FIRST $CORE_LAST; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "==> apt-get $OP $pkg"
        apt-get "$OP" -y "$pkg" || true
    else
        echo "==> $pkg not installed — skipping"
    fi
done

echo "Done. (The Leia SR runtime and the Leia conversion runtime, if installed, were left untouched.)"
