#!/usr/bin/env bash
# Remove DisplayXR from a tablet, for a clean-slate reinstall.
#
#   ./scripts/uninstall-displayxr.sh            # show what WOULD be removed
#   ./scripts/uninstall-displayxr.sh --yes      # actually remove it
#
# Removes: the OpenXR runtime, every com.displayxr.* demo, and the browser.
#
# Does NOT remove com.leialoft.display.config (device-service). That package owns
# backlight and display-mode control as well as carrying the CNSDK core, so
# uninstalling it can leave the panel in a bad state. The installer upgrades it in
# place instead, which is the supported path.
set -u

. "$(dirname "$0")/lib.sh"        # ver(), require_pad()
require_pad        # refuse if another handle holds /data/local/tmp/pad.lock (PAD_HANDLE=<you> to pass)
cd "$(dirname "$0")/.."
DRY=1; [ "${1:-}" = "--yes" ] && DRY=0

command -v adb >/dev/null || { echo "adb not found."; exit 1; }
N=$(adb devices | grep -cw device)
[ "$N" -eq 1 ] || { echo "Need exactly one device connected and authorised (found $N)."; adb devices; exit 1; }

# Anything displayxr-ish, plus the runtime and browser by exact name.
# Portable list-building: macOS ships bash 3.2, which has no `mapfile`.
PKGS=()
while IFS= read -r line; do
    [ -n "$line" ] && PKGS+=("$line")
done < <(adb shell pm list packages 2>/dev/null | sed 's/package://' | tr -d '\r' \
         | grep -E '^(com\.displayxr\.|org\.freedesktop\.monado\.openxr_runtime)')
# The DisplayXR browser installs under the package name org.chromium.chrome, so it
# is NOT matched by the com.displayxr.* pattern above. Listed separately and called
# out in the dry run, because on a device that also carries a stock Chrome this is
# the same package name - check the version before saying yes.
for extra in org.chromium.chrome; do
    adb shell pm path "$extra" >/dev/null 2>&1 && PKGS+=("$extra")
done

if [ "${#PKGS[@]}" -eq 0 ]; then echo "Nothing to remove — no DisplayXR packages installed."; exit 0; fi

echo "Packages that will be removed:"
for p in "${PKGS[@]}"; do
    v=$(adb shell dumpsys package "$p" 2>/dev/null | grep -m1 versionName | tr -d '\r ' | cut -d= -f2)
    printf '  %-56s %s\n' "$p" "${v:-?}"
done
echo
echo "KEPT (upgraded in place by the installer, never uninstalled):"
for p in com.leialoft.display.config com.leia.headtrackingservice; do
    v=$(adb shell dumpsys package "$p" 2>/dev/null | grep -m1 versionName | tr -d '\r ' | cut -d= -f2)
    printf '  %-56s %s\n' "$p" "${v:-not installed}"
done

if [ "$DRY" -eq 1 ]; then echo; echo "Dry run. Re-run with --yes to actually uninstall."; exit 0; fi

echo
fail=0
for p in "${PKGS[@]}"; do
    printf '  uninstalling %-46s ' "$p"
    out=$(adb uninstall "$p" 2>&1)
    # Check the RESULT, not the shape of the output.
    if echo "$out" | grep -q "^Success"; then echo "OK"; else echo "FAILED: $(echo "$out" | tail -1)"; fail=$((fail+1)); fi
done
echo
[ "$fail" -eq 0 ] && echo "Clean. Now run scripts/install-from-computer.sh, then reboot." \
                  || { echo "$fail uninstall(s) failed."; exit 1; }
