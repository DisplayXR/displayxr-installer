#!/usr/bin/env bash
# Install the whole stack onto a connected 3D tablet, from a computer with adb.
#
#   ./scripts/install-from-computer.sh
#
# Installing the APKs is NOT sufficient on a clean device. This script also does the
# post-install steps that are invisible until they bite:
#
#   * launches the runtime app once  -- uninstalling deregisters its
#     OpenXRRuntimeBroker ContentProvider, and Android's FLAG_STOPPED keeps it
#     unresolvable until the app is opened by hand. Skip it and EVERY OpenXR app
#     dies at instance creation with XR_ERROR_RUNTIME_UNAVAILABLE, which reads as a
#     broken runtime rather than "nobody opened it". Nothing clears it at boot.
#   * grants SYSTEM_ALERT_WINDOW to the runtime -- an app-op, never granted at
#     install, dropped by uninstall+install. Without it, see-through apps render on
#     a BLACK background while 3D and weaving keep working, so it looks like a
#     content bug.
#   * grants CAMERA to GaussianSplat and Avatar, or they open on a consent dialog.
#   * enables the browser's inline-3D flag (see the browser note below).
set -u

. "$(dirname "$0")/lib.sh"        # ver(), require_pad()
require_pad        # refuse if another handle holds /data/local/tmp/pad.lock (PAD_HANDLE=<you> to pass)
cd "$(dirname "$0")/.."

# --replace-mismatched: on a signing-key mismatch, uninstall the old app and retry.
# OPT-IN and never the default, because uninstalling WIPES that app's data. It exists
# because this bundle ships the first RELEASE-SIGNED browser (0.1.25): Android refuses
# an install that changes the signing key, so every tester carrying 0.1.24 or earlier
# hits it exactly once on the browser (browser#188).
REPLACE_MISMATCHED=0
for arg in "$@"; do
  case "$arg" in
    --replace-mismatched) REPLACE_MISMATCHED=1 ;;
    -h|--help) echo "usage: $0 [--replace-mismatched]"; exit 0 ;;
    *) echo "unknown option: $arg"; exit 1 ;;
  esac
done

RUNTIME_PKG=org.freedesktop.monado.openxr_runtime.out_of_process
BROWSER_PKG=org.chromium.chrome

command -v adb >/dev/null || { echo "adb not found. Install Android platform-tools, or use the on-device route in INSTALL.md."; exit 1; }
N=$(adb devices | grep -cw device)
[ "$N" -eq 1 ] || { echo "Need exactly one device connected and authorised (found $N)."; adb devices; exit 1; }
echo "Device: $(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')  Android $(adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"

# Wait for the package manager to actually be READY, not merely for the boot to be
# complete. Straight after a reboot -- especially the one reset-to-virgin.sh ends with,
# where reverting two UPDATED_SYSTEM_APPs leaves PackageManager re-scanning -- `adb
# install` fails for a while with no useful error, which reads as "the bundle is broken"
# when it is only "too early". Measured on an NP02J: every install after the CNSDK
# services failed on the first attempt, and every one of them succeeded unchanged a
# minute later.
wait_for_pm() {
    local i
    for i in $(seq 1 60); do
        [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] \
            && adb shell pm path android >/dev/null 2>&1 \
            && [ -z "$(adb shell dumpsys package 2>/dev/null | grep -m1 'Package Manager is not ready')" ] \
            && return 0
        [ "$i" = 1 ] && printf 'waiting for the package manager'
        printf '.'
        sleep 2
    done
    echo; echo "  package manager still not ready after 2 min -- continuing anyway."
}
wait_for_pm && echo
echo

fail=0
install_one() {
    local apk="$1"
    [ -f "$apk" ] || return 0
    printf '  %-52s ' "$(basename "$apk")"
    out=$(adb install -r -d -g "$apk" 2>&1)
    # Retry a transient failure before reporting it. A signature/downgrade/incompatible
    # rejection is a real verdict and is handled below, but "failed for no stated reason"
    # right after a reboot is the package manager still settling -- see wait_for_pm.
    local try
    for try in 2 3; do
        echo "$out" | grep -q "^Success" && break
        case "$out" in *SIGNATURE*|*INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*INSTALL_FAILED_VERSION_DOWNGRADE*) break ;; esac
        sleep 3
        out=$(adb install -r -d -g "$apk" 2>&1)
    done
    # Read the RESULT, not the shape of the output: "Performing Streamed Install" is
    # printed before a failure too, so a naive `tail -1` reports success wrongly.
    if echo "$out" | grep -q "^Success"; then
        echo "OK"
    else
        echo "FAILED"
        echo "$out" | grep -E "Failure|Error|INSTALL_" | head -2 | sed 's/^/      /'
        case "$out" in
          *SIGNATURE*|*INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
            # Recover the package name from the APK rather than guessing it from the
            # filename -- the browser installs as org.chromium.chrome, which no part of
            # its filename says.
            PKG=$(aapt2 dump packagename "$apk" 2>/dev/null \
                  || aapt dump badging "$apk" 2>/dev/null | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)
            if [ "$REPLACE_MISMATCHED" = 1 ] && [ -n "${PKG:-}" ]; then
              echo "      -> different signing key; uninstalling $PKG and retrying (its data is wiped)"
              adb uninstall "$PKG" >/dev/null 2>&1 || true
              out=$(adb install -r -d -g "$apk" 2>&1)
              if echo "$out" | grep -q "^Success"; then
                printf '  %-52s ' "$(basename "$apk") (reinstalled)"; echo "OK"
                return 0
              fi
              echo "      -> retry after uninstall ALSO failed:"
              echo "$out" | grep -E "Failure|Error|INSTALL_" | head -2 | sed 's/^/         /'
            else
              echo "      -> signed with a different key. Uninstall it first (this wipes its data):"
              echo "         adb uninstall ${PKG:-<package>}"
              echo "         ...or re-run this script with --replace-mismatched to do it automatically."
            fi ;;
        esac
        fail=$((fail+1))
    fi
}

echo "== [1/4] installing =="
# Order matters: services, then runtime, then apps. An app installed before the
# runtime finds no runtime.
for dir in apks/1-cnsdk-services apks/2-displayxr-runtime apks/3-demos apks/4-browser; do
    ls "$dir"/*.apk >/dev/null 2>&1 || { echo "$dir: no APKs (skipped)"; continue; }
    echo "$dir"
    for a in "$dir"/*.apk; do install_one "$a"; done
done

echo
echo "== [2/4] waking the runtime's ContentProvider =="
# See the header: without this every OpenXR app fails at instance creation.
if adb shell pm path "$RUNTIME_PKG" >/dev/null 2>&1; then
    adb shell monkey -p "$RUNTIME_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 \
        && echo "  launched $RUNTIME_PKG once — OK" \
        || echo "  WARN: could not launch it. Open the DisplayXR app by hand ONCE before any demo."
    sleep 2
else
    echo "  runtime not installed — skipped"
fi

echo
echo "== [3/4] permissions that installs do not grant =="
if adb shell pm path "$RUNTIME_PKG" >/dev/null 2>&1; then
    adb shell appops set "$RUNTIME_PKG" SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1 \
        && echo "  SYSTEM_ALERT_WINDOW -> $RUNTIME_PKG  OK" \
        || echo "  WARN: SYSTEM_ALERT_WINDOW not granted; see-through apps will show a BLACK background."
fi
for pkg in com.displayxr.gausssplat_vk_android com.displayxr.avatar_vk_android; do
    adb shell pm path "$pkg" >/dev/null 2>&1 || continue
    adb shell pm grant "$pkg" android.permission.CAMERA >/dev/null 2>&1 || true
    adb shell pm grant "$pkg" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
    echo "  CAMERA / POST_NOTIFICATIONS -> $pkg  (where declared)"
done

echo
echo "== [4/4] browser command-line file =="
# 0.1.23 and earlier shipped inline-3D OFF, gated behind --enable-inline-3d, which on
# Android arrives ONLY via this file — without it the browser rendered BLACK where the
# 3D should be and looked like a runtime fault. 0.1.24+ turns it on by default
# (displayxr-browser#190), so the flag is no longer REQUIRED.
#
# We still write the file: --disable-fre skips the first-run experience, which is worth
# having either way, and an explicit --enable-inline-3d stays a no-op on 0.1.24+. Only
# the reporting is version-aware, so a failure to write is not called fatal on a build
# that does not need it.
BR_LOCAL=$(ls apks/4-browser/*.apk 2>/dev/null | head -1)
BRV=$(basename "${BR_LOCAL:-}" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$BRV" ] && [ "$(printf '%s\n0.1.24\n' "$BRV" | sort -V | head -1)" = "0.1.24" ]; then
    NEEDS_FLAG=0
else
    NEEDS_FLAG=1
fi
if adb shell pm path "$BROWSER_PKG" >/dev/null 2>&1; then
    if adb shell "echo 'chrome --disable-fre --enable-inline-3d' > /data/local/tmp/chrome-command-line" 2>/dev/null; then
        adb shell am force-stop "$BROWSER_PKG" >/dev/null 2>&1   # file is read at startup
        if [ "$NEEDS_FLAG" -eq 0 ]; then
            echo "  command-line file written (--disable-fre). inline-3D is ON by default in ${BRV}  OK"
        else
            echo "  inline-3D enabled via /data/local/tmp/chrome-command-line  OK"
        fi
    elif [ "$NEEDS_FLAG" -eq 0 ]; then
        echo "  NOTE: could not write the command-line file. Harmless on ${BRV} — inline-3D is on by default;"
        echo "        you will just see the first-run screen."
    else
        echo "  WARN: could not write the flag file. The browser will show black where 3D should be."
    fi
else
    echo "  browser not installed — skipped"
fi

echo
echo "== verifying (what is actually installed, stamps read from the installed APKs) =="
bash "$(dirname "$0")/audit-device.sh" || echo "  WARN: the audit found a pairing problem - read the lines above before shipping."
echo
if [ "$fail" -eq 0 ]; then
    echo "All installs succeeded. REBOOT THE TABLET, then open the DisplayXR app first."
else
    echo "$fail install(s) failed — see above. Nothing was rolled back."
    exit 1
fi
