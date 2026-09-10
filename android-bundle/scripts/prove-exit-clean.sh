#!/usr/bin/env bash
# Runtime #1425 exit-side fix: returning from the mini-window to fullscreen used to leave the view
# laid out at 1079x1685 — content visibly squashed to the left. The runtime now discards the torn
# sample. This loops the exit several times because the bug was intermittent.
#
#   ./scripts/prove-exit-clean.sh [package] [iterations]
#
# PASS: no `did not follow the window` line, and the fullscreen view ends at the panel's own extent.
# The runtime may log `ignoring a torn sample … logical extent is still 1080x1685` — that is the fix
# WORKING, not a fault.
set -u

. "$(dirname "$0")/lib.sh"        # restore_rotation, task_sz, wait_picker_done, open_mediaplayer_file
PKG="${1:-com.displayxr.model_viewer_vk_android}"; N="${2:-4}"
trap restore_rotation EXIT
adb shell wm fixed-to-user-rotation enabled >/dev/null 2>&1
adb shell settings put system accelerometer_rotation 0; adb shell settings put system user_rotation 1
adb shell input keyevent KEYCODE_WAKEUP >/dev/null; adb shell wm dismiss-keyguard >/dev/null 2>&1
bad=0; torn=0
for i in $(seq 1 "$N"); do
    for t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+' | grep -oE '#[0-9]+$' | tr -d '#'); do adb shell am stack remove "$t" >/dev/null 2>&1; done
    adb shell am force-stop "$PKG"; adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 10
    adb shell input keyevent KEYCODE_HOME; sleep 2; adb shell input keyevent KEYCODE_APP_SWITCH
    for _ in 1 2 3 4 5 6 7 8; do sleep 1; case "$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 -oE 'mCurrentFocus=Window\{[^}]*')" in *launcher*|*ecents*) break ;; esac; done
    sleep 2; adb shell input tap 1895 302; sleep 6      # into the mini-window
    adb logcat -c; adb shell am start -n "$PKG/$PKG.MainActivity" >/dev/null 2>&1 || adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 6                                            # back to fullscreen — the exit under test
    L=$(adb logcat -d | tr -d '\r')
    nf=$(printf '%s\n' "$L" | grep -c 'did not follow the window'); tn=$(printf '%s\n' "$L" | grep -c 'ignoring a torn sample')
    dims=$(printf '%s\n' "$L" | grep -oE 'VIEW_DIMS: window [0-9]+x[0-9]+' | tail -1 | awk '{print $3}')
    printf '  exit %s: window=%-11s did-not-follow=%s torn-sample-discarded=%s\n' "$i" "${dims:-?}" "$nf" "$tn"
    bad=$((bad+nf)); torn=$((torn+tn))
    case "${dims:-}" in *1079x1685*) echo "    LEFT-SQUASHED: view stayed at the mini-window layout after the exit"; bad=$((bad+1)) ;; esac
done
adb shell am force-stop "$PKG"
echo "  totals: did-not-follow=$bad  torn samples discarded=$torn (discards are the fix working)"
[ "$bad" -eq 0 ] && echo "PASS: $N exits, none left the view squashed." || { echo "FAIL: see above"; exit 1; }
