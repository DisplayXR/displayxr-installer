#!/usr/bin/env bash
# Prove the browser keeps its woven tiles across HOME + resume-from-launcher (browser-android's
# check, 2026-09-06). A URL intent is NOT a resume (it opens a new tab), so the second launch
# goes through the launcher icon. Markers are the browser GPU process's [DisplayXR] logcat lines
# (the page's "7 windows woven now" badge is DOM text and never reaches logcat):
#   cold load : "android weave: woven AHardwareBuffer WxH adopted" then "android weave: imported woven WxH AHardwareBuffer"
#   each resume: "android weave: staging AHardwareBuffer-backed SharedImage WxH" followed by a NEW "imported woven WxH"
#   old bug   : a "staging … SharedImage" line after resume with NO "imported woven" after it
# WxH: landscape = 2560x1540 (golden orientation); 1600x2500 means the browser was portrait.
#   ./scripts/prove-browser-resume.sh
set -u

# Resting state (the project owner's standing rule): NEVER leave this pad's rotation locked, and never hand it
# back in portrait. So a landscape PIN is for the duration of a run only; on exit restore
# auto-rotate ON with landscape current.
restore_rotation() {
    adb shell wm fixed-to-user-rotation disabled >/dev/null 2>&1
    adb shell settings put system accelerometer_rotation 1 >/dev/null 2>&1
    adb shell settings put system user_rotation 1 >/dev/null 2>&1
    sleep 2
    printf '  pad rotation restored: auto-rotate=%s user_rotation=%s mCurrentOrientation=%s (want 1/1/1)\n' \
      "$(adb shell settings get system accelerometer_rotation | tr -d '\r')" \
      "$(adb shell settings get system user_rotation | tr -d '\r')" \
      "$(adb shell dumpsys display 2>/dev/null | tr -d '\r' | grep -m1 -oE 'mCurrentOrientation=[0-9]+' | cut -d= -f2)"
}
trap restore_rotation EXIT
PKG=org.chromium.chrome
# The pad is often OFFLINE; the remote samples page then never loads and nothing weaves, which
# looks exactly like a weave bug. Serve the site from this Mac instead:
#   (cd <your displayxr-web checkout> && python3 -m http.server 8000 --bind 127.0.0.1 &)
#   adb reverse tcp:8000 tcp:8000
#   ./scripts/prove-browser-resume.sh http://localhost:8000/samples/windows/
URL="${1:-https://displayxr.github.io/displayxr-web/samples/windows/}"
adb shell settings put system accelerometer_rotation 0; adb shell settings put system user_rotation 1  # auto-rotate OFF or physical orientation wins
adb shell input keyevent KEYCODE_WAKEUP >/dev/null; sleep 1; adb shell wm dismiss-keyguard >/dev/null 2>&1
# Clear recents first. A browser task left parked by earlier testing is RESUMED into that
# stale container, and the page then never weaves (measured 2026-09-07: 0 "android weave:" lines
# on BOTH 0.1.29 and 0.1.30 until recents was cleared, after which 0.1.30 wove immediately).
for t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+' | grep -oE '#[0-9]+$' | tr -d '#'); do adb shell am stack remove "$t" >/dev/null 2>&1; done
adb shell am force-stop $PKG; adb logcat -c
adb shell am start -a android.intent.action.VIEW -d "$URL" -p $PKG >/dev/null 2>&1; sleep 25
dx() { adb logcat -d | tr -d '\r' | grep -F '[DisplayXR]' | grep -F 'android weave:'; }
COLD=$(dx | grep -c 'imported woven'); DIMS=$(dx | grep -oE 'imported woven [0-9]+x[0-9]+' | tail -1 | awk '{print $3}')
ROT=$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -oE 'mCurrentRotation=[0-9]|mRotation=[0-9]' | head -1)
pid_of() { adb shell pidof -s "$1" 2>/dev/null | tr -d '\r'; [ -n "$_" ] || true; }
PID0=$(pid_of $PKG); [ -n "$PID0" ] || { sleep 3; PID0=$(pid_of $PKG); }; echo "  cold load: imported woven=$COLD dims=${DIMS:-none} $ROT (pid $PID0)"
adb shell input keyevent KEYCODE_HOME; sleep 3; adb logcat -c
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 10     # launcher = resume, not a new tab
L=$(adb logcat -d | tr -d '\r'); PID1=$(pid_of $PKG)
STAGE=$(printf '%s\n' "$L" | grep -F '[DisplayXR]' | grep -c 'staging AHardwareBuffer-backed SharedImage')
REIMP=$(printf '%s\n' "$L" | grep -F '[DisplayXR]' | grep -c 'imported woven')
# old-bug shape: a staging line with no imported-woven line AFTER it
LASTSTAGE=$(printf '%s\n' "$L" | grep -nF 'staging AHardwareBuffer-backed SharedImage' | tail -1 | cut -d: -f1); LASTIMP=$(printf '%s\n' "$L" | grep -n 'imported woven' | tail -1 | cut -d: -f1)
CRASH=$(printf '%s\n' "$L" | grep -A1 'FATAL EXCEPTION' | grep -c "Process: $PKG"); NCRASH=$(printf '%s\n' "$L" | grep -c ">>> $PKG <<<")
echo "  after resume: pid=${PID1:-<dead>} staging=$STAGE imported-woven=$REIMP crashes=$((CRASH+NCRASH))"
adb shell am force-stop $PKG
ok=1
[ "$COLD" -gt 0 ] || { echo "  no woven import on cold load"; ok=0; }
[ "$REIMP" -gt 0 ] || { echo "  no 'imported woven' after resume"; ok=0; }
[ -z "$LASTSTAGE" ] || [ -n "$LASTIMP" ] && [ "${LASTIMP:-0}" -gt "${LASTSTAGE:-0}" ] || { echo "  OLD BUG shape: staging after resume with no import after it"; ok=0; }
[ -n "$PID1" ] && [ "$PID1" = "$PID0" ] || { echo "  process changed/died"; ok=0; }
[ $((CRASH+NCRASH)) -eq 0 ] || { echo "  crash"; ok=0; }
[ "$DIMS" = "2560x1540" ] || echo "  note: weave dims $DIMS (landscape is 2560x1540) -- orientation, not a failure"
[ "$ok" -eq 1 ] && echo "PASS: browser re-imported the woven buffer after HOME + launcher resume (same pid)." || { echo "FAIL: see above"; exit 1; }
