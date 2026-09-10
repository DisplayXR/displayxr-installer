#!/usr/bin/env bash
# Put a tablet back to a VIRGIN state before (re)testing this bundle -- every
# DisplayXR component, the CNSDK service updates, and every side-channel setting the
# install path ever touches -- so an install test proves the bundle, not the leftovers.
#
#   ./scripts/reset-to-virgin.sh          # show what WOULD be done
#   ./scripts/reset-to-virgin.sh --yes    # do it (ends with a reboot + unlock)
#
# Removes:  the OpenXR runtime, every com.displayxr.* demo, the browser (org.chromium.chrome).
# Reverts:  (ONLY with --revert-services; off by default since 2026-09-05, see below)
#           com.leialoft.display.config + com.leia.headtrackingservice to the FACTORY
#           versions in /system/app. Both are UPDATED_SYSTEM_APPs on this tablet, so
#           `adb uninstall` removes the update only -- it cannot remove the package.
#           That IS what the OEM shipped, which is the virgin state. (The old
#           uninstall-displayxr.sh kept them on the theory that removing them wrecks
#           the panel; that was about full removal, which is not possible here.)
# Clears:   /data/local/tmp/chrome-command-line (the 0.1.23-era inline-3D flag file),
#           (NOT the EarthView key any more — see below) (a persisted prop cannot be
#           deleted, only emptied), and -- by virtue of the uninstalls -- every appop
#           (SYSTEM_ALERT_WINDOW) and runtime permission (CAMERA, notifications).
# Leaves:   global freeform / rotation settings (pre-existing on this tablet, not ours).
# Ends:     reboot, wait for boot, wake + dismiss keyguard -- an app launched at the
#           lockscreen after a reboot deadlocks the hosted path (displayxr-runtime#1358).
set -u

. "$(dirname "$0")/lib.sh"        # restore_rotation, task_sz, wait_picker_done, open_mediaplayer_file
require_pad        # refuse if another handle holds /data/local/tmp/pad.lock (PAD_HANDLE=<you> to pass)

trap restore_rotation EXIT
cd "$(dirname "$0")/.."
DRY=1; REVERT_SERVICES=0; WIPE_EV_KEY=0
for a in "$@"; do case "$a" in --yes) DRY=0 ;; --revert-services) REVERT_SERVICES=1 ;; --wipe-ev-key) WIPE_EV_KEY=1 ;; esac; done
command -v adb >/dev/null || { echo "adb not found."; exit 1; }
N=$(adb devices | grep -cw device)
[ "$N" -eq 1 ] || { echo "Need exactly one device connected and authorised (found $N)."; adb devices; exit 1; }
flags() { adb shell dumpsys package "$1" 2>/dev/null | tr -d '\r' | grep -m1 'flags=' | sed -E 's/.*flags=//'; }

REMOVE=()
while IFS= read -r l; do [ -n "$l" ] && REMOVE+=("$l"); done < <(adb shell pm list packages 2>/dev/null | sed 's/package://' | tr -d '\r' \
        | grep -E '^(com\.displayxr\.|org\.freedesktop\.monado\.openxr_runtime|org\.chromium\.chrome$)')
# 2026-09-05: DO NOT revert the two CNSDK services by default. ROOT CAUSE NOW KNOWN, and it
# was NOT donFun (that warning is cosmetic -- a shader polynomial string that falls back to
# "1.0"). com.leialoft.display.config regenerates the panel config from the FPC whenever its
# own version changes (tracked in shared_prefs/updateDetector.xml). Reverting it to factory
# 0.8.29 wipes its data dir, and re-installing then regenerates. On a K68 EVT pad every
# device-service BEFORE 0.10.66 double-converted d/n on that path (decided the don_mm vs
# donopx convention by device class instead of magnitude), producing donopx 3.46x too large
# -- which pins the panel to flat 2D at a normal viewing distance while head tracking still
# works perfectly. Fixed in CNSDK 0.10.66; a revert + reinstall of >= 0.10.66 now regenerates
# the correct value and is self-healing. Still off by default: a revert destroys the cached
# config, and there is no need to reach factory for a DisplayXR test -- a "virgin" test does
# not need the services at factory, it needs DisplayXR at zero.
# See CNSDK docs/internal/troubleshoot/k68-evt-donopx-vs-don_mm.md.
REVERT=()
if [ "${REVERT_SERVICES:-0}" = 1 ]; then
    for p in com.leialoft.display.config com.leia.headtrackingservice; do
        case "$(flags "$p")" in *UPDATED_SYSTEM_APP*) REVERT+=("$p") ;; *) echo "  note: $p is not an updated system app -- left alone" ;; esac
    done
else
    echo "  (CNSDK services are LEFT AS INSTALLED -- the installer upgrades them in place; see the note in this script)"
fi

echo "REMOVE (user apps):"; for p in "${REMOVE[@]:-}"; do [ -n "$p" ] && printf '  %-56s %s\n' "$p" "$(ver "$p")"; done
echo "REVERT to factory (updated system apps):"; for p in "${REVERT[@]:-}"; do [ -n "$p" ] && printf '  %-56s %s\n' "$p" "$(ver "$p")"; done
echo "CLEAR:"
printf '  %-56s %s\n' "/data/local/tmp/chrome-command-line" "$(adb shell 'test -e /data/local/tmp/chrome-command-line && echo present || echo absent' | tr -d '\r')"
k=$(adb shell getprop persist.dxr.ev.key | tr -d '\r'); printf '  %-56s %s\n' "persist.dxr.ev.key" "$([ -n "$k" ] && echo "set (${#k} chars)" || echo empty)"
echo "THEN: reboot, wait for boot, wake + dismiss keyguard."
[ "$DRY" -eq 1 ] && { echo; echo "Dry run. Re-run with --yes."; exit 0; }

echo; fail=0
for p in "${REMOVE[@]:-}" "${REVERT[@]:-}"; do [ -n "$p" ] && adb shell am force-stop "$p" >/dev/null 2>&1; done
for p in "${REMOVE[@]:-}"; do [ -z "$p" ] && continue; printf '  uninstall %-50s ' "$p"
    out=$(adb uninstall "$p" 2>&1); if echo "$out" | grep -q '^Success'; then echo OK; else echo "FAILED: $(echo "$out"|tail -1)"; fail=$((fail+1)); fi; done
for p in "${REVERT[@]:-}"; do [ -z "$p" ] && continue; before=$(ver "$p"); printf '  revert    %-50s ' "$p"
    out=$(adb uninstall "$p" 2>&1); if echo "$out" | grep -q '^Success'; then echo "OK  $before -> factory $(ver "$p")"; else echo "FAILED: $(echo "$out"|tail -1)"; fail=$((fail+1)); fi; done
adb shell rm -f /data/local/tmp/chrome-command-line 2>/dev/null && echo "  cleared   chrome-command-line"
# persist.dxr.ev.key is KEPT. It exists precisely so it survives uninstall and reboot
# (earthview #46) — clearing it here defeated its purpose and cost a manual re-entry every
# validation pass. Clear it only with --wipe-ev-key, e.g. when handing the pad to someone else.
if [ "${WIPE_EV_KEY:-0}" = 1 ]; then
    adb shell setprop persist.dxr.ev.key '""' >/dev/null 2>&1; adb shell setprop persist.dxr.ev.key "" >/dev/null 2>&1
    printf '  cleared   persist.dxr.ev.key -> %s\n' "$([ -z "$(adb shell getprop persist.dxr.ev.key | tr -d '\r')" ] && echo empty || echo 'STILL SET')"
else
    printf '  KEPT      persist.dxr.ev.key (%s chars; survives uninstall by design — --wipe-ev-key to clear)\n' "$(adb shell getprop persist.dxr.ev.key | tr -d '\r' | wc -c | tr -d ' ')"
fi
[ "$fail" -eq 0 ] || { echo; echo "$fail step(s) failed -- NOT rebooting."; exit 1; }

echo; echo "rebooting..."; adb reboot; adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done; sleep 5
adb shell input keyevent KEYCODE_WAKEUP; sleep 1; adb shell wm dismiss-keyguard; sleep 2
# The NP02J is a LANDSCAPE-FIRST tablet. A reboot brings user_rotation back to the device
# default of 0 (portrait), and user_rotation is the RESTING orientation even when
# auto-rotate is on -- so without this the pad comes back parked in portrait, which is not
# the orientation the product is evaluated in. Restore it here rather than trusting whoever
# ran the script to notice: this has been missed twice.
adb shell settings put system accelerometer_rotation 1 >/dev/null 2>&1
adb shell settings put system user_rotation 1 >/dev/null 2>&1
echo "boot complete; keyguard: $(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -oE 'mDreamingLockscreen=\w+' | head -1)"
echo; echo "AUDIT (virgin means: nothing listed under REMOVE, services at factory, clears empty):"
left=$(adb shell pm list packages 2>/dev/null | sed 's/package://' | tr -d '\r' | grep -E '^(com\.displayxr\.|org\.freedesktop\.monado\.openxr_runtime|org\.chromium\.chrome$)')
printf '  %-56s %s\n' "DisplayXR user packages" "${left:-none}"
for p in com.leialoft.display.config com.leia.headtrackingservice; do printf '  %-56s %s  [%s]\n' "$p" "$(ver "$p")" "$(flags "$p" | grep -q UPDATED_SYSTEM_APP && echo 'STILL UPDATED' || echo factory)"; done
printf '  %-56s %s\n' "chrome-command-line" "$(adb shell 'test -e /data/local/tmp/chrome-command-line && echo present || echo absent' | tr -d '\r')"
printf '  %-56s %s\n' "persist.dxr.ev.key" "$([ -z "$(adb shell getprop persist.dxr.ev.key | tr -d '\r')" ] && echo empty || echo 'STILL SET')"
AR=$(adb shell settings get system accelerometer_rotation | tr -d '\r'); UR=$(adb shell settings get system user_rotation | tr -d '\r')
printf '  %-56s %s\n' "rotation (must be auto-rotate=1, landscape=1)" "$([ "$AR" = 1 ] && [ "$UR" = 1 ] && echo "auto=$AR landscape=$UR  OK" || echo "auto=$AR user=$UR  WRONG -- pad is not landscape")"
echo; echo "Virgin. Now: scripts/install-from-computer.sh"
