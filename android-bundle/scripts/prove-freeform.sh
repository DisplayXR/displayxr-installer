#!/usr/bin/env bash
# Prove the RECENTS FREEFORM TOGGLE works for a demo: launch it fullscreen, go HOME, open
# recents, tap the card's freeform icon, then assert (1) the task is in freeform windowing
# mode, (2) the app did NOT get APP_CMD_DESTROY (no activity recreate), (3) the same process
# is still alive and still rendering (its weave keeps publishing frames).
#
#   ./scripts/prove-freeform.sh [package] [icon_x icon_y]
#
# Default: the ModelViewer demo. With recents CLEARED first (this script does that) the app is
# the single centred card and its freeform icon (left of the card's ⋮) is at (1895,302) in
# landscape device px — measured from this script's own miss-screencap on the NP02J,
# 2026-09-06 (the earlier 1505,215 came from a different card layout). Pass your own if it moves.
# STATUS: written from the freeform-android session's recipe; NOT yet exercised on a pad
# by this script -- treat the first run as calibration of the tap coordinates.
set -u

# How many activities the app's task holds. The SAF picker runs INSIDE our task
# (startActivityForResult), so the task grows while the picker is up and returns to exactly
# one activity when the pick completes.
# A stale install leaves dead task records behind under the SAME package name. Measured on
# the pad 2026-09-10: dumpsys carried 19 tasks matching the mediaplayer package across TWO
# uids -- the live one (visible, sz=1) plus records from an uninstalled debug-signed build,
# most of them sz=0. So take the VISIBLE task: picking the first match can read a dead sz=0
# task and hang the wait below forever on something that will never reach 1.
# "visible=true" does not substring-match "visibleRequested=true".
task_sz() {
    _pre=$(printf '%s' "${1:-$PKG}" | sed 's/[.]/\\./g')
    _tasks=$(adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' \
      | grep -oE "Task\{[0-9a-f]+ #[0-9]+[^}]*$_pre[^}]*\}")
    _t=$(printf '%s\n' "$_tasks" | grep -m1 'visible=true')
    [ -n "$_t" ] || _t=$(printf '%s\n' "$_tasks" | head -1)
    printf '%s' "$_t" | grep -oE 'sz=[0-9]+' | head -1 | cut -d= -f2
}

# Do not toggle freeform until the picker has actually gone. The OEM window-resize check
# refuses ANY task containing a foreign activity, so toggling too early yields no freeform
# icon at all -- indistinguishable from "the app cannot do mini-windows" (mediaplayer#69).
#
# Holds for both app generations, which is why it keys on OUR task and nothing else: up to
# 1.9.5 the picker runs inside our task, and from 1.9.6 the app trampolines it into a
# separate task that is EXCLUDED FROM RECENTS. So do not rewrite this to look for the
# picker in recents -- on 1.9.6 it is not there, and the check would silently pass early.
wait_picker_done() {
    for _ in $(seq 1 20); do sleep 1; [ "$(task_sz)" = 1 ] && break; done
    _sz=$(task_sz)
    if [ "${_sz:-?}" = 1 ]; then
        echo "  (clip open, picker finished -- the idle splash is 2D by design)"
    else
        echo "  WARNING: task still holds ${_sz:-?} activities after the pick. A foreign activity in"
        echo "           the task makes the OEM refuse the freeform toggle, so a FAIL below is this"
        echo "           harness, not the app. See mediaplayer#69."
    fi
}

# MediaPlayer >= 1.9.5 shows an IDLE SPLASH that is deliberately 2D (lens off) until a file is
# opened, so measuring on the splash reads 0 weave frames and looks like a failure. Open a clip
# first: tap the splash (tap-to-open) -> system picker -> tap a stereo clip by name.
# Measured 2026-09-10: splash 0 frames; playing 301/6s fullscreen, 319/6s in the mini-window.
# Open a clip, so the measurement is not taken on the 2D idle splash.
#
# TAP THE TITLE, NEVER THE FIRST MATCH. Each grid item carries a
# `com.android.documentsui:id/preview_icon` whose content-desc is "Preview the file <name>",
# and it sorts BEFORE the title node -- so the original `grep <name> | head -1` selected the
# preview button (measured centre 1124,556) instead of the title (1028,907). Tapping it
# launches the OEM video player INTO our task (sz=5 observed); the OEM then refuses the
# window-resize, the freeform icon never appears, and the sweep wrongly concluded that
# mediaplayer cannot show content in a mini-window. Root-caused 2026-09-10, mediaplayer#69;
# reproduces on 1.9.3 too, so it was never a 1.9.5 regression. Select on
# resource-id="android:id/title" plus the file text. Note the id is `android:id/title`, not
# `com.android.documentsui:id/title`.
open_mediaplayer_file() {
    case "$1" in *mediaplayer*) ;; *) return 0 ;; esac
    _re="${MP_FILE_RE:-lvf2|SBS}"
    sz=$(adb shell wm size | tr -d '\r' | sed 's/.*: //'); w=${sz%x*}; h=${sz#*x}
    adb shell input tap $((w/2)) $((h/2)); sleep 5
    adb shell uiautomator dump /sdcard/mp.xml >/dev/null 2>&1
    _node=$(adb shell cat /sdcard/mp.xml 2>/dev/null | tr '>' '\n' \
              | grep -F 'resource-id="android:id/title"' \
              | grep -E "text=\"[^\"]*($_re)[^\"]*\"" | head -1)
    # Belt and braces: if the selector ever drifts back onto a preview control, refuse it
    # rather than silently poisoning the task again.
    case "$_node" in
      *preview_icon*|*'content-desc="Preview the file'*)
        echo "  (refusing to tap a preview control -- it launches the OEM player into our task)"
        _node="" ;;
    esac
    if [ -z "$_node" ]; then
        echo "  (no title node matching /$_re/; a measurement on the splash will read 2D)"
        return 0
    fi
    set -- $(printf '%s' "$_node" | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' \
               | grep -oE '[0-9]+' | paste -sd' ' -)
    [ $# -eq 4 ] || { echo "  (title node carries no bounds; skipping)"; return 0; }
    _txt=$(printf '%s' "$_node" | grep -oE ' text="[^"]*"' | head -1 | cut -d'"' -f2)
    echo "  opening \"$_txt\" -- tapping its title at $(( ($1+$3)/2 )),$(( ($2+$4)/2 ))"
    adb shell input tap $(( ($1+$3)/2 )) $(( ($2+$4)/2 ))
    wait_picker_done
}

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
PKG="${1:-com.displayxr.model_viewer_vk_android}"; IX="${2:-1895}"; IY="${3:-302}"
command -v adb >/dev/null || { echo "adb not found."; exit 1; }
adb shell pm path "$PKG" >/dev/null 2>&1 || { echo "$PKG is not installed."; exit 1; }
# Landscape + unlocked; a reboot parks this landscape-first pad in portrait (user_rotation=0).
# Pin landscape FOR THE DURATION of the run. auto-rotate alone is not enough: without
# `wm fixed-to-user-rotation enabled` the app's own FULL_SENSOR orientation wins and a flat-lying
# pad drifts to portrait between runs — which moved the recents icon and made taps miss (2026-09-08).
# The EXIT trap hands rotation back (auto-rotate ON, landscape current).
adb shell wm fixed-to-user-rotation enabled >/dev/null 2>&1
adb shell settings put system accelerometer_rotation 0; adb shell settings put system user_rotation 1  # auto-rotate OFF or physical orientation wins
adb shell input keyevent KEYCODE_WAKEUP >/dev/null; sleep 1; adb shell wm dismiss-keyguard >/dev/null 2>&1
# Deterministic layout (freeform-android, 2026-09-06): the AVATAR overlay outlives its
# foreground by design and sits over the recents grid (avatar#83), and a multi-card grid
# moves every icon. So: stop the avatar, clear EVERY recents entry, then the app under test
# is the single centred card and its freeform icon is at the measured (1505,215).
adb shell am force-stop com.displayxr.avatar_vk_android
for t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+' | grep -oE '#[0-9]+$' | tr -d '#'); do adb shell am stack remove "$t" >/dev/null 2>&1; done
adb shell am force-stop "$PKG"; adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 12
open_mediaplayer_file "$PKG"
PID0=$(adb shell pidof "$PKG" | tr -d '\r'); [ -n "$PID0" ] || { echo "FAIL: $PKG did not start"; exit 1; }
mode() { adb shell dumpsys activity activities 2>/dev/null | tr -d '\r' | grep -E "Task.*$PKG|\* Task\{.*A=[0-9]+:$PKG" -A12 | grep -oE 'mode=[a-z-]+|windowingMode=[0-9]+' | head -1; }
echo "  before: pid=$PID0 $(mode)"
# Leave ONLY the app under test in recents. Opening a file brings the system picker into recents
# too, which shifts the card and makes a fixed-coordinate tap miss (measured 2026-09-10 on
# mediaplayer 1.9.5; from 1.9.6 the picker trampolines into a task excluded from recents, so
# there is nothing to sweep -- this stays correct either way). Remove every task that is not this package — after the app is running, so
# clearing cannot kill it.
for _t in $(adb shell dumpsys activity recents 2>/dev/null | tr -d '\r' | grep -oE 'Recent #[0-9]+: Task\{[0-9a-f]+ #[0-9]+ [^}]*' | grep -v "$PKG" | grep -oE '#[0-9]+ ' | tr -d '# '); do adb shell am stack remove "$_t" >/dev/null 2>&1; done
adb shell input keyevent KEYCODE_HOME; sleep 2
adb shell input keyevent KEYCODE_APP_SWITCH
# WAIT for recents to actually be up before tapping. A fixed sleep raced the heavier demos
# (earthview/modelviewer): the tap landed on the card, which just RESUMES the app fullscreen and
# looks identical to "the toggle did not work" (2026-09-08 — the miss screencap showed the app
# fullscreen, not recents).
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    case "$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 -oE 'mCurrentFocus=Window\{[^}]*')" in
      *launcher*|*Recents*|*recents*) break ;;
    esac
done
sleep 2
# Rotation-aware: a portrait app (GaussianSplat) leaves the pad in portrait, and recents then
# draws a portrait card whose icon is at (1150,475). Read the rotation NOW, not at script start.
# Choose the icon coordinate from what is ACTUALLY ON SCREEN, not from mRotation: a portrait-locked
# app (mediaplayer) makes recents render PORTRAIT while the display still reports rotation 1, and the
# landscape coordinate then misses the icon entirely (measured 2026-09-10).
_shot=$(mktemp).png; adb exec-out screencap -p > "$_shot" 2>/dev/null
_dims=$(sips -g pixelWidth -g pixelHeight "$_shot" 2>/dev/null | grep -oE '[0-9]+$' | paste -sd'x' -); rm -f "$_shot"
_w=${_dims%x*}; _h=${_dims#*x}
if [ -n "${_w:-}" ] && [ -n "${_h:-}" ] && [ "$_w" -lt "$_h" ]; then IX=1150; IY=475; else IX=1895; IY=302; fi
echo "  recents is ${_dims:-unknown} -> tapping the freeform icon at $IX,$IY"
echo "  recents rotation=${_dims:-unknown} -> tapping icon at $IX,$IY"
adb shell input tap "$IX" "$IY"; sleep 6
PID1=$(adb shell pidof "$PKG" | tr -d '\r'); M1=$(mode)
LOG=$(adb logcat -d | tr -d '\r')
DESTROY=$(printf '%s\n' "$LOG" | grep -c 'APP_CMD_DESTROY')
# WM's own record of the toggle, and the old bug's signature (freeform-android, 2026-09-06).
# WM logs two ActivityTaskManager lines on the recents toggle: "startActivityFromRecentsForWR … taskId =N"
# (the stable one) then "toggleSwitchFromFullScreenToFreeformWr"; the portrait/multi-card path was seen
# without the second. Accept either; task mode=freeform + the runtime's CONTAINER_SCALED reaction stay authoritative.
TOGGLED=$(printf '%s\n' "$LOG" | grep -cE 'startActivityFromRecentsForWR|toggleSwitchFromFullScreenToFreeformWr')
OLDBUG=$(printf '%s\n' "$LOG" | grep -cE 'Attempted to set replacing window on app token with no content|APP TRANSITION TIMEOUT')
[ "$TOGGLED" -gt 0 ] || adb exec-out screencap -p > "/tmp/freeform-miss-$(date +%H%M%S).png" 2>/dev/null   # tap probably missed the icon
adb logcat -c; sleep 5; FRAMES=$(adb logcat -d | tr -d '\r' | grep -c 'PUBLISHED to CNSDK')
# From runtime v2.16.12 the runtime says what it does in a scaled container (spec R6/S8/S9).
printf '%s\n' "$LOG" | grep -E 'CONTAINER_SCALED|lens preference (RELEASED|ASSERTED)' | sed -E 's/^[^A-Za-z\[]*//;s/^.*WARN \[[a-z_]+\] //' | awk '!seen[$0]++' | cut -c1-160 | sed 's/^/  runtime: /'
echo "  after:  pid=${PID1:-<dead>} $M1  WM-toggle=$TOGGLED  APP_CMD_DESTROY=$DESTROY  old-bug-signature=$OLDBUG  frames/5s=$FRAMES"
# This panel returns VK_SUBOPTIMAL_KHR on every present (~48/s, in every mode), so a SWAP_DIAG line
# mentioning SUBOPTIMAL counts is NOT a finding — only NEGATIVE VkResults are (freeform-android 2026-09-09).
BADVK=$(printf '%s\n' "$LOG" | grep -oE 'VkResult=-[0-9]+|VK_ERROR_[A-Z_]+' | sort -u | tr '\n' ' ')
[ -z "$BADVK" ] || echo "  negative VkResults seen: $BADVK"
ok=1
case "$M1" in *freeform*|*windowingMode=5*) ;; *) echo "  NOT freeform ($M1) -- tap missed the icon, or the manifest lacks the freeform flags"; ok=0 ;; esac
case "$M1" in *freeform*|*windowingMode=5*) [ "$TOGGLED" -gt 0 ] || { echo "  note: task is freeform but neither WM line was logged (seen on the portrait/multi-card path)"; TOGGLED=1; } ;; esac
[ "$TOGGLED" -gt 0 ] || { echo "  WM never logged the freeform toggle -- tap missed (screencap saved under /tmp/freeform-miss-*.png); single cleared-recents card -> icon at 1895,302"; ok=0; }
[ "$DESTROY" -eq 0 ] || { echo "  app was DESTROYED on the toggle"; ok=0; }
[ "$OLDBUG" -eq 0 ] || { echo "  old-bug signature present (replacing window with no content / APP TRANSITION TIMEOUT)"; ok=0; }
[ -n "$PID1" ] && [ "$PID1" = "$PID0" ] || { echo "  process changed/died ($PID0 -> ${PID1:-dead})"; ok=0; }
# What "still rendering" means depends on the runtime:
#   <= v2.16.15  the OEM mini-window is a SCALED container, so the runtime deliberately presented
#                2D there ("CONTAINER_SCALED ... presenting 2D") and 0 weave frames was CORRECT.
#   >= v2.16.16  the runtime weaves 1:1 INSIDE the mini-window (#1393/#1395): MonadoView reads the
#                container scale and sizes the buffer so layout x scale lands on an integer
#                ("miniWindow1to1: ON ... 1080x1685 -> layout 1079x1685 -> buffer 723x1129").
#                Weave frames are then REQUIRED and a CONTAINER_SCALED-2D fallback is a REGRESSION.
SCALED2D=$(printf '%s\n' "$LOG" | grep -c 'CONTAINER_SCALED: .*presenting 2D')
MINI1TO1=$(printf '%s\n' "$LOG" | grep -c 'miniWindow1to1: ON')
HINT=$(printf '%s\n' "$LOG" | grep -c 'hint ON scale=')
WEDGE=$(printf '%s\n' "$LOG" | grep -c '#1394: weave thread unresponsive')
ver() { adb shell dumpsys package "$1" 2>/dev/null | tr -d '\r' | grep -m1 versionName | cut -d= -f2 | tr -d ' v'; }
# The demos all declare versionCode=1 / versionName=0.1 in their manifests, so the DEVICE carries
# no version signal for them (verified 2026-09-07). The bundle FILENAME is the record of what was
# installed, so read it there — and prove the installed APK really is that file by sha256, or the
# filename would just be a comfortable lie.
app_ver() {
    local pkg=$1 glob f fv inst t
    case "$pkg" in
      *mediaplayer*)  glob='apks/3-demos/DisplayXRMediaPlayer-*.apk' ;;
      *model_viewer*) glob='apks/3-demos/DisplayXRModelViewer-*.apk' ;;
      *gausssplat*)   glob='apks/3-demos/DisplayXRGaussianSplat-*.apk' ;;
      *earthview*)    glob='apks/3-demos/DisplayXREarthView-*.apk' ;;
      *avatar*)       glob='apks/3-demos/DisplayXRAvatar-*.apk' ;;
      *)              echo unknown; return ;;
    esac
    f=$(ls $glob 2>/dev/null | head -1); [ -n "$f" ] || { echo unknown; return; }
    fv=$(basename "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    inst=$(adb shell pm path "$pkg" 2>/dev/null | tr -d '\r' | sed 's/^package://' | head -1)
    if [ -n "$inst" ]; then
        t=$(mktemp); adb pull "$inst" "$t" >/dev/null 2>&1
        if [ "$(shasum -a 256 "$t" | cut -d" " -f1)" = "$(shasum -a 256 "$f" | cut -d" " -f1)" ]; then echo "$fv"; else echo "unknown"; fi
        rm -f "$t"
    else echo unknown; fi
}
atleast() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # atleast A B  ->  A >= B
RTV=$(ver org.freedesktop.monado.openxr_runtime.out_of_process); APPV=$(app_ver "$PKG")   # device has no demo version; see app_ver
printf '%s\n' "$LOG" | grep -E 'miniWindow1to1|hint (ON|OFF)|windowRect:|VIEW_DIMS:|HW_XFORM' | sed -E 's/^[^A-Za-z]*//;s/^.*(WARN|INFO|D|W|I) //' | cut -c1-150 | awk '!seen[$0]++' | tail -4 | sed 's/^/  runtime: /'
# Which contract applies to THIS app on THIS runtime:
#   hosted demos (modelviewer/gauss/earthview)  weave required from runtime >= 2.16.16 (#1393/#1395)
#   mediaplayer (XR_DXR_android_surface_binding, no hosted MonadoView) weave required only from
#       runtime >= 2.16.17 AND mediaplayer >= 1.9.3 — the runtime emits a layout HINT
#       (XrEventDataAndroidWindowLayoutHintDXR) and the app applies it (#1396/#1398).
#       Either side older: the honest CONTAINER_SCALED 2D fallback is still CORRECT.
case "$PKG" in
  *mediaplayer*) if [ "$APPV" = unknown ]; then NEED_WEAVE=0
                 elif atleast "$RTV" 2.16.17 && atleast "$APPV" 1.9.3; then NEED_WEAVE=1; else NEED_WEAVE=0; fi
                 WHY="mediaplayer ${APPV} on runtime $RTV (hint path needs rt>=2.16.17 + app>=1.9.3; \"unknown\" = installed APK is not the bundle file)" ;;
  *)             if atleast "$RTV" 2.16.16; then NEED_WEAVE=1; else NEED_WEAVE=0; fi
                 WHY="hosted app on runtime $RTV (1:1 mini-window from 2.16.16)" ;;
esac
# CNSDK 0.10.68 + runtime >=2.16.19 cure the stall (CNSDK#733: pad went 6/9 stalls -> 0/24). At or
# after that pair a wedge is a REGRESSION, not the known issue. A weave COLLISION there is expected
# to self-heal instead: "[Weave] vkQueueSubmit failed" -> "#1394: CNSDK DROPPED a weave" ->
# "the display processor DROPPED a frame ... recycled" -> "weave recovered after N dropped frame(s)"
# = one black frame, no stall.
SVCV=$(adb shell dumpsys package com.leialoft.display.config 2>/dev/null | tr -d '\r' | grep -m1 versionName | cut -d= -f2 | tr -d ' ')
RECOVERED=$(printf '%s\n' "$LOG" | grep -c 'weave recovered after')
if [ "$WEDGE" -gt 0 ]; then
    if atleast "$RTV" 2.16.19 && atleast "${SVCV%%+*}" 0.10.68; then
        echo "  REGRESSION: '#1394: weave thread unresponsive' on runtime $RTV + services $SVCV — the stall is supposed to be CURED here (CNSDK#733)"
    else
        echo "  KNOWN #1394 wedge on runtime $RTV + services $SVCV — app alive, window stopped updating; not a new defect"
    fi
    ok=0
elif [ "$NEED_WEAVE" -eq 1 ]; then
    [ "$MINI1TO1" -gt 0 ] || [ "$HINT" -gt 0 ] || echo "  note: neither 'miniWindow1to1: ON' nor 'hint ON scale=' seen ($WHY)"
    if [ "$SCALED2D" -gt 0 ] && [ "$FRAMES" -le 0 ]; then echo "  REGRESSION: fell back to CONTAINER_SCALED 2D instead of weaving 1:1 — $WHY"; ok=0
    elif [ "$FRAMES" -le 0 ]; then echo "  no weave frames in the mini-window — $WHY"; ok=0
    else echo "  weaving 1:1 inside the mini-window ($FRAMES frames/5s, $WHY)"
         [ "$RECOVERED" -eq 0 ] || echo "  (self-healed a weave collision: $RECOVERED x 'weave recovered after ... dropped frame(s)' — expected on 0.10.68+, one black frame)"; fi
else
    if [ "$FRAMES" -gt 0 ]; then echo "  weaving in the mini-window ($FRAMES frames/5s) — better than required for $WHY"
    elif [ "$SCALED2D" -gt 0 ]; then echo "  2D in the mini-window is CORRECT here — $WHY"
    else echo "  neither weave frames nor a CONTAINER_SCALED line — not rendering ($WHY)"; ok=0; fi
fi
adb shell am force-stop "$PKG"
[ "$ok" -eq 1 ] && echo "PASS: $PKG survived the recents freeform toggle (freeform, same pid, still rendering)." || { echo "FAIL: see above"; exit 1; }
