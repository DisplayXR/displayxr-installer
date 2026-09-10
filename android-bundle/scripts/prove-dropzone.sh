#!/usr/bin/env bash
# The OEM "drop-zone" entry: swipe up from fullscreen, HOLD, drag into the top-right release zone,
# let go — no tap. Runtime #1424/#1425.
#
#   ./scripts/prove-dropzone.sh [package]
#
# THIS SCRIPT CANNOT PERFORM THE REAL GESTURE. `input swipe` and `input motionevent` do not satisfy
# the OEM recogniser (freeform-android, 2026-09-09), so the real drag is a MANUAL step for a human.
# What this script does is the scripted ANALOGUE — `am task resize` to the drop-zone geometry, which
# reproduces the resulting WINDOW but not the drag that precedes it. The drag itself is what used to
# poison the touch-ratio scale measurement (0.37 vs 0.67 → cross-check refused → honest 2D), so a
# green run here does NOT prove the real gesture works. Treat the two as separate claims.
set -u

. "$(dirname "$0")/lib.sh"        # restore_rotation, task_sz, wait_picker_done, open_mediaplayer_file
require_pad        # refuse if another handle holds /data/local/tmp/pad.lock (PAD_HANDLE=<you> to pass)
PKG="${1:-com.displayxr.model_viewer_vk_android}"
DROP_BOUNDS="2137 84 3217 1769"     # drop-zone geometry measured on the NP02J
trap restore_rotation EXIT
adb shell wm fixed-to-user-rotation enabled >/dev/null 2>&1
adb shell settings put system accelerometer_rotation 0; adb shell settings put system user_rotation 1
adb shell input keyevent KEYCODE_WAKEUP >/dev/null; adb shell wm dismiss-keyguard >/dev/null 2>&1
for t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+' | grep -oE '#[0-9]+$' | tr -d '#'); do adb shell am stack remove "$t" >/dev/null 2>&1; done
adb shell am force-stop "$PKG"; adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 12
TID=$(adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -oE "Task\{[0-9a-f]+ #[0-9]+ .*A=[0-9]+:$PKG" | head -1 | grep -oE '#[0-9]+' | tr -d '#')
[ -n "${TID:-}" ] || { echo "could not find a task for $PKG"; exit 1; }
adb logcat -c; adb shell am task resize "$TID" $DROP_BOUNDS >/dev/null 2>&1; sleep 8
LOG=$(adb logcat -d | tr -d '\r')
FRAMES=$(printf '%s\n' "$LOG" | grep -c 'PUBLISHED to CNSDK')
SCALED2D=$(printf '%s\n' "$LOG" | grep -c 'CONTAINER_SCALED: .*presenting 2D')
OFFPANEL=$(printf '%s\n' "$LOG" | grep -c 'OFF_PANEL_PLACEMENT')
# Only NEGATIVE VkResults matter here. This panel returns VK_SUBOPTIMAL_KHR on every present
# (~48/s, every mode), so a SWAP_DIAG line mentioning SUBOPTIMAL counts is NOT a finding.
BADVK=$(printf '%s\n' "$LOG" | grep -oE 'VkResult=-[0-9]+|VK_ERROR_[A-Z_]+' | sort -u | tr '\n' ' ')
printf '%s\n' "$LOG" | grep -E 'OFF_PANEL_PLACEMENT|miniWindow1to1|CONTAINER_SCALED' | sed -E 's/^[^A-Za-z]*//;s/^.*(WARN|INFO|D|W|I) //' | awk '!seen[$0]++' | tail -4 | cut -c1-150 | sed 's/^/  runtime: /'
# 2.16.23 (#1425): the OEM has TWO scaled-window families and the runtime must pick the right one.
#   recents "freeform" = Normal, leash 0.67, buffer 723x1129
#   drop-zone "release" = Hang,  leash 0.37, buffer 397x623   (a TAP toggles Hang -> Normal)
FAM=$(printf '%s\n' "$LOG" | grep -oE 'family=(hang|normal)[^ ]*' | tail -1)
SCALE=$(printf '%s\n' "$LOG" | grep -oE 'scale=0\.[0-9]+' | tail -1)
BUF=$(printf '%s\n' "$LOG" | grep -oE 'buffer [0-9]+x[0-9]+' | tail -1)
echo "  family=${FAM:-none} ${SCALE:-} ${BUF:-}"
echo "  scripted analogue: task $TID resized to the drop-zone geometry"
echo "  weave frames/8s=$FRAMES  presenting-2D lines=$SCALED2D  OFF_PANEL_PLACEMENT=$OFFPANEL  negative VkResults=${BADVK:-none}"
[ "$FRAMES" -gt 0 ] && [ "$SCALED2D" -eq 0 ] && echo "  ANALOGUE PASS: weaving in the drop-zone geometry" || echo "  ANALOGUE FAIL: no weave, or it fell back to 2D"
# (b) a TAP must flip Hang -> Normal. A tap IS deliverable from adb, unlike the drag.
if [ -n "${FAM:-}" ]; then
    adb logcat -c; adb shell input tap 2677 926 >/dev/null 2>&1; sleep 5
    FAM2=$(adb logcat -d | tr -d '\r' | grep -oE 'family=(hang|normal)[^ ]*' | tail -1)
    echo "  after a tap: family=${FAM2:-unchanged/none} (expect normal)"
fi
cat <<'MANUAL'

  MANUAL STEP — nobody can script this, and it is the claim that matters:
    1. Open the app fullscreen.
    2. Swipe up from the bottom and HOLD (do not tap).
    3. Drag the window into the top-right "release" zone and let go.
    4. Judge, by eye: is it in 3D (not flat, not doubled), AND does the image follow your head
       when you move? Head tracking freezing under an honest-2D degrade is a known separate issue.
  Report both answers. The scripted result above says nothing about the drag itself: the drag is
  what used to poison the scale measurement and force 2D.
MANUAL
