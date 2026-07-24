#!/usr/bin/env bash
# DisplayXR Linux bundle installer (displayxr-runtime #781 Phase 3).
#
# Installs the DisplayXR stack from the .debs bundled alongside this script:
#   - displayxr-runtime  (OpenXR runtime + sim-display fallback DP)
#   - displayxr-leia-sr  (Leia SR display-processor plug-in, probe_order 50)
#
# After install the box needs ZERO environment variables: the runtime .deb
# registers the OpenXR ActiveRuntime and searches /usr/lib/displayxr/plugins by
# default; the Leia plug-in drops in there and claims the display automatically
# WHEN the Leia SR runtime is present. Without the SR runtime, sim-display
# drives apps and the Leia DP declines — a clean fallback.
#
# The commercial Leia SR runtime (`leiasr-runtime`) is NOT bundled here — it
# ships separately from Leia. This installer detects it and tells you how to
# proceed if it is missing.
#
#   sudo ./install.sh            # install the bundled .debs
#   ./install.sh --uninstall     # remove them (or use ./uninstall.sh)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBS_DIR="$HERE/debs"

if [ "${1:-}" = "--uninstall" ]; then
    exec "$HERE/uninstall.sh"
fi

# --- Preconditions ---------------------------------------------------------
command -v apt-get >/dev/null 2>&1 || {
    echo "error: this installer targets Debian/Ubuntu (apt-get not found)." >&2
    exit 1
}
if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "==> re-running under sudo (package install needs root)"
        exec sudo -- "$0" "$@"
    fi
    echo "error: run as root (package install needs root)." >&2
    exit 1
fi

shopt -s nullglob
DEBS=("$DEBS_DIR"/*.deb)
shopt -u nullglob
if [ "${#DEBS[@]}" -eq 0 ]; then
    echo "error: no .debs found in $DEBS_DIR — is this the unpacked bundle?" >&2
    exit 1
fi

echo "==> Installing the DisplayXR stack:"
for d in "${DEBS[@]}"; do echo "      $(basename "$d")"; done

# apt-get install resolves each .deb's Depends from the apt archives and orders
# them (the plug-in Depends: displayxr-runtime). The plug-in's
# `Recommends: leiasr-runtime` is best-effort — pulled if a Leia apt repo is
# configured, silently skipped otherwise (the commercial SR runtime is not in
# public apt). Either way the stack installs.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y "${DEBS[@]}"

# --- Leia SR runtime presence -------------------------------------------------
SR_PRESENT=0
if dpkg -s leiasr-runtime >/dev/null 2>&1 \
   || [ -f /etc/leia/sr/1/active_runtime.json ] \
   || [ -x /opt/leiasr/bin/SRService ]; then
    SR_PRESENT=1
fi

echo ""
echo "======================================================================"
if [ "$SR_PRESENT" = 1 ]; then
    echo " Leia SR runtime detected — the Leia display processor will claim the"
    echo " display automatically (probe_order 50, ahead of sim-display)."
else
    echo " Leia SR runtime NOT detected."
    echo " The stack is installed and WORKS NOW on the sim-display fallback."
    echo " To enable real 3D weaving, install the Leia SR runtime package"
    echo " (leiasr-runtime) provided by Leia. Once it is installed, the Leia"
    echo " display processor claims the display automatically — no reconfig,"
    echo " no environment variables."
fi
echo "======================================================================"

# --- Verify -------------------------------------------------------------------
echo ""
echo "==> Verifying (displayxr-cli selftest)"
if command -v displayxr-cli >/dev/null 2>&1; then
    displayxr-cli selftest
    echo ""
    echo "DisplayXR installed. Diagnostics: displayxr-cli info"
else
    echo "warn: displayxr-cli not on PATH after install — check the runtime .deb." >&2
    exit 1
fi
