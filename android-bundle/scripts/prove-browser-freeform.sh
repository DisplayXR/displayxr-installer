#!/usr/bin/env bash
# Prove the BROWSER weaves 1:1 inside the OEM recents mini-window (browser-pvt #54, preview-0.1.31+).
# The browser reflects into the runtime's MiniWindowLayout contract, so its markers differ from the
# demos': it must log the contract, the runtime's hint, its own setFixedSize, and then import a
# woven buffer at the MINI-WINDOW size (723x1129), not the fullscreen one.
#
#   ./scripts/prove-browser-freeform.sh [url]
#
# PASS needs, after the recents freeform toggle:
#   cr_DisplayXrMiniWin: MiniWindowLayout contractVersion=2 …
#   hint ON … layout 1079x1685 buffer 723x1129
#   setFixedSize(723, 1129)
#   hint APPLIED
#   android weave: imported woven 723x1129 …
# and no `#1394: weave thread unresponsive`.
set -u

. "$(dirname "$0")/lib.sh"        # restore_rotation, task_sz, wait_picker_done, open_mediaplayer_file
PKG=org.chromium.chrome
URL="${1:-https://displayxr.github.io/displayxr-web/samples/windows/}"
IX=1895; IY=302     # freeform icon on a single cleared-recents card, LANDSCAPE (portrait: 1150,475)

trap restore_rotation EXIT
adb shell wm fixed-to-user-rotation enabled >/dev/null 2>&1
adb shell settings put system accelerometer_rotation 0; adb shell settings put system user_rotation 1
adb shell input keyevent KEYCODE_WAKEUP >/dev/null; sleep 1; adb shell wm dismiss-keyguard >/dev/null 2>&1

# One card only, and no stale task: a parked browser task is RESUMED into the old container and
# never weaves (measured 2026-09-07).
for t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+' | grep -oE '#[0-9]+$' | tr -d '#'); do adb shell am stack remove "$t" >/dev/null 2>&1; done
adb shell am force-stop $PKG; adb logcat -c
adb shell am start -a android.intent.action.VIEW -d "$URL" -p $PKG >/dev/null 2>&1; sleep 25
# A fresh install shows Chrome's first-run dialog; dismiss "No thanks" if present so it cannot
# swallow the page or the recents gesture.
adb shell uiautomator dump /sdcard/fr.xml >/dev/null 2>&1
if adb shell "grep -qi 'No thanks' /sdcard/fr.xml" 2>/dev/null; then
    bounds=$(adb shell cat /sdcard/fr.xml | tr '>' '\n' | grep -i 'No thanks' | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1)
    x=$(echo "$bounds" | grep -oE '[0-9]+' | sed -n '1p'); y=$(echo "$bounds" | grep -oE '[0-9]+' | sed -n '2p')
    x2=$(echo "$bounds" | grep -oE '[0-9]+' | sed -n '3p'); y2=$(echo "$bounds" | grep -oE '[0-9]+' | sed -n '4p')
    [ -n "${x:-}" ] && { adb shell input tap $(( (x+x2)/2 )) $(( (y+y2)/2 )); echo "  dismissed Chrome first-run dialog"; sleep 4; }
fi
PID0=$(adb shell pidof -s $PKG | tr -d '\r')
echo "  cold load: imported woven=$(adb logcat -d | grep -c 'imported woven') (pid ${PID0:-none})"

adb shell input keyevent KEYCODE_HOME; sleep 2; adb shell input keyevent KEYCODE_APP_SWITCH
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1
    case "$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 -oE 'mCurrentFocus=Window\{[^}]*')" in *launcher*|*Recents*|*recents*) break ;; esac
done
sleep 2
ROT=$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -oE 'mRotation=[0-9]' | head -1 | cut -d= -f2)
{ [ "$ROT" = 0 ] || [ "$ROT" = 2 ]; } && { IX=1150; IY=475; }
adb logcat -c; adb shell input tap "$IX" "$IY"; sleep 10

LOG=$(adb logcat -d | tr -d '\r'); PID1=$(adb shell pidof -s $PKG | tr -d '\r')
MODE=$(adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -A12 "A=[0-9]*:$PKG" | grep -oE 'mode=[a-z-]+' | head -1)
printf '%s\n' "$LOG" | grep -E 'cr_DisplayXrMiniWin|hint (ON|APPLIED|OFF)|setFixedSize|imported woven|weave thread unresponsive' | sed -E 's/^[^A-Za-z]*//;s/^.*(WARN|INFO|D|W|I) //' | awk '!seen[$0]++' | cut -c1-150 | head -6 | sed 's/^/  /'
# 'cr_DisplayXrMiniWin' is the tag the shipped browser uses ('MiniWindowLayout' was the pre-release name).
C=$(printf '%s\n' "$LOG" | grep -c 'cr_DisplayXrMiniWin'); H=$(printf '%s\n' "$LOG" | grep -c 'hint ON')
A=$(printf '%s\n' "$LOG" | grep -c 'hint APPLIED'); F=$(printf '%s\n' "$LOG" | grep -c 'setFixedSize(723, 1129)')
W=$(printf '%s\n' "$LOG" | grep -c 'imported woven 723x1129'); WEDGE=$(printf '%s\n' "$LOG" | grep -c 'weave thread unresponsive')
# $LOG starts at the toggle (logcat was cleared immediately before the tap), so this count is
# post-toggle by construction. On 0.1.30 the browser wove the FULL 1080x1685 window and let the
# container resample it — a double image, not honest 2D (browser#186 / runtime#1404). A 0.1.31
# regression would show BOTH sizes, so require the fullscreen-size import to be gone.
# ORDERING matters: the toggle happens while the browser is still 1080x1685, so ONE import at the
# old size before the hint is applied is expected and healthy (measured on 0.1.31). What must not
# happen is a fullscreen-size import AFTER the mini-window one — that would mean it reverted and the
# container is resampling again. So compare line positions, not raw counts.
WFULL=$(printf '%s\n' "$LOG" | grep -c 'imported woven 1080x1685')
LAST723=$(printf '%s\n' "$LOG" | grep -n 'imported woven 723x1129' | tail -1 | cut -d: -f1)
LAST1080=$(printf '%s\n' "$LOG" | grep -n 'imported woven 1080x1685' | tail -1 | cut -d: -f1)
REVERTED=0; [ -n "${LAST1080:-}" ] && [ -n "${LAST723:-}" ] && [ "$LAST1080" -gt "$LAST723" ] && REVERTED=1
[ -n "${LAST1080:-}" ] && [ -z "${LAST723:-}" ] && REVERTED=1
echo "  $MODE  contract=$C hintON=$H applied=$A setFixedSize=$F woven723=$W woven1080=$WFULL wedge=$WEDGE  pid ${PID0:-?}->${PID1:-dead}"
adb shell am force-stop $PKG
ok=1
case "$MODE" in *freeform*) ;; *) echo "  NOT freeform ($MODE) — tap missed the icon"; ok=0 ;; esac
[ "$W" -gt 0 ] || { echo "  no 'imported woven 723x1129' — the browser did not weave at mini-window size"; ok=0; }
if [ "$REVERTED" -eq 1 ]; then echo "  REVERTED: a fullscreen-size import (1080x1685) came AFTER the mini-window one — container resamples it = double image (browser#186)"; ok=0
elif [ "$WFULL" -gt 0 ]; then echo "  (one transitional 1080x1685 import before the hint applied — expected)"; fi
[ "$A" -gt 0 ] || echo "  note: no 'hint APPLIED' line"
[ "$WEDGE" -eq 0 ] || { echo "  #1394 wedge line present — REGRESSION on 0.10.68+"; ok=0; }
[ -n "$PID1" ] && [ "$PID1" = "$PID0" ] || { echo "  browser process changed/died"; ok=0; }
[ "$ok" -eq 1 ] && echo "PASS: browser weaves 1:1 in the mini-window." || { echo "FAIL: see above"; exit 1; }
