#!/usr/bin/env bash
# Shared harness helpers. Sourced, never executed:
#
#   . "$(dirname "$0")/lib.sh"
#
# Everything here was duplicated across the prove-* scripts and had ALREADY drifted --
# restore_rotation existed in three variants across seven files (two of them silently
# skipping the verification line), and the picker helpers were copied into two. A CI check
# now fails the build if any script redefines a name this file defines, so it cannot come
# back. Add a helper here only when a second script needs it.
#
# NOTE: the scripts are no longer standalone. lib.sh must sit beside them -- the bundle
# ships the whole scripts/ directory, and sync-from-repo.sh keeps it complete, so this only
# matters if someone copies a single script out on its own.

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
    adb shell input tap $((w/2)) $((h/2))
    # WAIT for the picker window, do not sleep a fixed amount. documentsui cold-starts here,
    # and 5s caught the 2D splash instead (measured 2026-09-10, stock 1.9.5): the dump then
    # held no file nodes at all, which reads exactly like "there are no clips on this device"
    # and sent the run on to measure the splash. Same class as the recents race below.
    for _ in $(seq 1 20); do
        sleep 1
        case "$(adb shell dumpsys window 2>/dev/null | tr -d '\r' | grep -m1 -oE 'mCurrentFocus=Window\{[^}]*')" in
          *documentsui*) break ;;
        esac
    done
    sleep 1
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

# Installed versionName, normalised for comparison. Strips whitespace and a LEADING "v"
# only -- the old prove-freeform copy used `tr -d ' v'`, which deletes EVERY v and quietly
# turned 1.9.5-dev into 1.9.5-de. The leading v must go because callers feed this to
# atleast()/sort -V against bare numbers like 2.16.17. Cost of the merge: audit-device.sh
# and reset-to-virgin.sh now PRINT versions without the leading v (2.16.23, not v2.16.23).
ver() { adb shell dumpsys package "$1" 2>/dev/null | tr -d '\r' | grep -m1 versionName | cut -d= -f2 | tr -d ' ' | sed 's/^v//'; }

# Refuse to drive the pad when another handle holds the lock.
#
# The lock used to be purely ADVISORY: pad-lock.sh would refuse to hand it over, but a
# caller that did not check its exit status walked straight through and drove the device
# anyway. That happened for real on 2026-09-10 -- a run started three seconds after
# another session took the lock, force-stopped its app, cleared its recents and dropped
# its rotation pin, mid-measurement. Advice in a README cannot prevent that; a refusal
# here can. Every script that CHANGES device state calls this first.
#
# Export PAD_HANDLE=<your handle> when you hold the lock, so your own runs pass.
require_pad() {
    _pl=/data/local/tmp/pad.lock
    _ex=$(adb shell "test -e $_pl && echo yes || echo no" 2>/dev/null | tr -d '\r')
    [ "$_ex" = yes ] || return 0                       # free
    _lk=$(adb shell cat "$_pl" 2>/dev/null | tr -d '\r')
    if [ -z "$_lk" ]; then
        echo "  REFUSING: $_pl exists but is EMPTY -- that means held-by-unknown, never free." >&2
        echo "  Find out whose it is before touching this pad." >&2
        exit 1
    fi
    _h=${_lk%% *}
    if [ -n "${PAD_HANDLE:-}" ] && [ "$_h" = "${PAD_HANDLE}" ]; then return 0; fi
    echo "  REFUSING: the pad is held by another handle." >&2
    echo "    lock: $_lk" >&2
    echo "  If that handle is you, re-run with PAD_HANDLE=$_h. Otherwise wait for them to release;" >&2
    echo "  driving a pad someone else is measuring destroys their run and yours." >&2
    exit 1
}
