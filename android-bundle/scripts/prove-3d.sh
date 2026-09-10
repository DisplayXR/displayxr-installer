#!/usr/bin/env bash
# Prove that the 3D PIPELINE comes up on the tablet after an install (core loaded, DP created).
# It does NOT prove the weave tracks a face: 2026-09-05 every app passed this while the weave
# ran in no-face 2D (look-around worked, weaver never got a face). A face-in-front check
# needs a human, or a CNSDK-side "left NoFaceMode" signal that does not exist yet. -- by running an app and
# reading what CNSDK and the display processor say in logcat. Not "strings present",
# not "app launched": those both passed on the 2.16.2 bundle where every demo ran in 2D.
#
#   ./scripts/prove-3d.sh [package]     # default: the Avatar demo
#
# PASS needs BOTH positive markers, and NONE of the failure markers:
#   loader   "[Core-Loader] Successfully initialized in-service library"   CNSDK core loaded
#   plug-in  "Leia CNSDK DP created (atlas mode)"                          display processor up
# FAIL on any of:
#   "[Core-Loader] Invalid load request"          loader != plug-in apiVersion (runtime#1357)
#   "leia_cnsdk_create failed"  /  "no-DP path"   plug-in gave up -> app renders in 2D
# Also prints the CNSDK service version the loader reports and the runtime's active
# plug-in line, so the transcript names what was actually running.
set -u

. "$(dirname "$0")/lib.sh"        # restore_rotation, task_sz, wait_picker_done, open_mediaplayer_file
require_pad        # refuse if another handle holds /data/local/tmp/pad.lock (PAD_HANDLE=<you> to pass)

trap restore_rotation EXIT
PKG="${1:-com.displayxr.avatar_vk_android}"
command -v adb >/dev/null || { echo "adb not found."; exit 1; }
adb shell pm path "$PKG" >/dev/null 2>&1 || { echo "$PKG is not installed."; exit 1; }
# Launching at the lockscreen after a reboot deadlocks the hosted path (runtime#1358).
adb shell input keyevent KEYCODE_WAKEUP >/dev/null; sleep 1; adb shell wm dismiss-keyguard >/dev/null 2>&1; sleep 1
# Launch into a CLEAN task: a leftover recents entry in the scaled freeform container is
# RESUMED by a launcher start, and the runtime then (correctly) presents 2D and publishes no
# horizon -- which looks like a broken pipeline. Clear recents first.
for t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+' | grep -oE '#[0-9]+$' | tr -d '#'); do adb shell am stack remove "$t" >/dev/null 2>&1; done
adb shell am force-stop "$PKG" >/dev/null 2>&1
adb logcat -c
echo "launching $PKG ..."
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
open_mediaplayer_file "$PKG"
sleep 25
LOG=$(adb logcat -d 2>/dev/null | tr -d '\r')
adb shell am force-stop "$PKG" >/dev/null 2>&1     # never leave a demo running on the device
echo
echo "what CNSDK and the DP said:"
printf '%s\n' "$LOG" | grep -E 'Core-Loader|leia_cnsdk_create|no-DP path|CNSDK DP created|active plug-in|FATAL EXCEPTION|Fatal signal' | grep -v 'HW_EYES' | sed -E 's/^[^A-Za-z\[]*//' | cut -c1-150 | head -12 | sed 's/^/  /'
echo
ok_loader=$(printf '%s\n' "$LOG" | grep -c 'Successfully initialized in-service library')
ok_dp=$(printf '%s\n' "$LOG" | grep -c 'CNSDK DP created')
bad=$(printf '%s\n' "$LOG" | grep -cE 'Invalid load request|leia_cnsdk_create failed|no-DP path')
# Real crashes only. "--------- beginning of crash" is logcat's crash-BUFFER separator, printed
# whenever that buffer has anything in it (a vendor daemon's F-priority "PERF: tcd abnormal"
# line puts it there on every boot) -- it is not a crash of anything. Scope to OUR process.
# Java crash: "FATAL EXCEPTION: main" names no package -- the NEXT line ("Process: <pkg>") does.
# Native crash: the tombstone header carries ">>> <pkg> <<<". Count both, for OUR package only.
crash_java=$(printf '%s\n' "$LOG" | grep -A1 'FATAL EXCEPTION' | grep -c "Process: $PKG")
crash_native=$(printf '%s\n' "$LOG" | grep -c ">>> $PKG <<<")
crash=$((crash_java + crash_native))
horizon=$(printf '%s\n' "$LOG" | grep -c 'PUBLISHED to CNSDK')
printf '  %-40s %s\n' "loader initialized in-service core" "$([ "$ok_loader" -gt 0 ] && echo YES || echo NO)"
printf '  %-40s %s\n' "display processor created" "$([ "$ok_dp" -gt 0 ] && echo YES || echo NO)"
printf '  %-40s %s\n' "failure markers" "$bad"
printf '  %-40s %s\n' "crash markers" "$crash"
printf '  %-40s %s\n' "#206 horizon published to CNSDK" "$([ "$horizon" -gt 0 ] && echo "YES ($horizon frames)" || echo "no (informational)")"
echo
if [ "$ok_loader" -gt 0 ] && [ "$ok_dp" -gt 0 ] && [ "$bad" -eq 0 ] && [ "$crash" -eq 0 ]; then
    echo "PASS: 3D pipeline is up in $PKG (CNSDK core loaded, DP created)."
else
    echo "FAIL: 3D is NOT proven in $PKG -- see the lines above."; exit 1
fi
