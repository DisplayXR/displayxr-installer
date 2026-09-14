#!/usr/bin/env bash
# Shared-pad lock, in the agreed format (freeform-android, 2026-09-08):
#   /data/local/tmp/pad.lock holds "<handle> <ISO ts> <what/how long>"; cat it back after writing.
#   An EMPTY file means held-by-unknown — never treat it as free. Remove only your own entry.
#
#   ./scripts/pad-lock.sh status
#   ./scripts/pad-lock.sh take "android-bundle" "0.10.68 four-way swap, ~20 min"
#   ./scripts/pad-lock.sh release "android-bundle"
set -u
# Resolve $0 through symlinks BEFORE locating lib.sh. link-pad-tools.sh puts a symlink to
# this script on PATH, and for a symlink "dirname $0" is the link's directory -- which has no
# lib.sh, so sourcing would fail and the tool would be unavailable exactly when someone
# finally had it at hand. readlink -f is avoided: it is not portable to every BSD userland.
_self="$0"
while [ -L "$_self" ]; do
    _link=$(readlink "$_self")
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(dirname -- "$_self")/$_link" ;;
    esac
done
_HERE=$(CDPATH= cd -- "$(dirname -- "$_self")" && pwd)
. "$_HERE/lib.sh"   # pad_holder
L=/data/local/tmp/pad.lock
read_lock() { adb shell "cat $L 2>/dev/null" | tr -d '\r'; }

# Report whether a foreign lock meets the four-step clearable rule (issue #56).
#
# READ-ONLY ON PURPOSE. It clears nothing and cannot. Steps 1 and 3 are mechanical
# and checked here; steps 2 and 4 need a human or agent and are printed as
# instructions. The rule exists because AGE ALONE IS NEVER SUFFICIENT: on
# 2026-09-12 three sessions judged a 3.5-hour-old lock dead, and it was live --
# on a different device that had been swapped onto the cable.
stale_check() {
    _want="${1:-}"
    # A DEVICE must be attached before anything below means anything. Without this the
    # no-device case reads "no lock on this device", which would convince an operator a
    # lock had gone when they simply were not talking to the pad -- the same shape as the
    # 2026-09-12 cable swap, where the evidence and the lock came from different units.
    _att=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
    _n=$(printf '%s\n' "$_att" | grep -c . || true)
    if [ "$_n" -eq 0 ]; then echo "UNKNOWN: no device attached -- cannot evaluate any step"; return 2; fi
    if [ "$_n" -gt 1 ] && [ -z "${PAD_SERIAL:-}" ]; then
        echo "UNKNOWN: $_n devices attached and PAD_SERIAL unset -- which pad do you mean?"; return 2
    fi
    _lk=$(read_lock)
    if ! adb shell "test -e $L" 2>/dev/null; then echo "NOT CLEARABLE: no lock on this device"; return 1; fi
    if [ -z "$_lk" ]; then echo "NOT CLEARABLE: empty lock file (held-by-unknown) -- a human must resolve this"; return 1; fi
    _h=$(pad_holder "$_lk")
    if [ -n "$_want" ] && [ "$_h" != "$_want" ]; then
        echo "NOT CLEARABLE: lock is held by '$_h', not '$_want'"; return 1
    fi

    # Step 1 -- device identity. The lock and every piece of evidence below must come
    # from the SAME unit. ro.product.model cannot discriminate these units; the serial can.
    _serial=$(adb shell getprop ro.serialno 2>/dev/null | tr -d '\r')
    _name=$(adb shell getprop ro.product.name 2>/dev/null | tr -d '\r')
    if [ -n "${PAD_SERIAL:-}" ] && [ "$PAD_SERIAL" != "$_serial" ]; then
        echo "NOT CLEARABLE: step 1 -- attached serial $_serial is not PAD_SERIAL=$PAD_SERIAL"; return 1
    fi
    echo "  step 1 OK   device $_serial ($_name)"

    # Step 3 -- no device activity, and the lock has not been touched, for 30 min past
    # the lock's own stated duration. Compare EPOCH SECONDS: usagestats prints device-local
    # time, the lock line is UTC, and this box is UTC-7. Comparing the printed strings is
    # how you get a seven-hour error that looks plausible.
    _mtime=$(adb shell stat -c %Y "$L" 2>/dev/null | tr -d '\r')
    _now=$(adb shell date +%s 2>/dev/null | tr -d '\r')
    case "$_mtime$_now" in *[!0-9]*|'') echo "NOT CLEARABLE: step 3 -- cannot read device clock/mtime"; return 1 ;; esac
    _idle=$(( _now - _mtime ))
    # Stated duration, e.g. "~15min" / "20 min" / "2h"; absent means 30 min.
    _dur=$(printf '%s' "$_lk" | grep -oE '[0-9]+ *(min|m|h|hour)' | head -1)
    _durs=1800
    case "$_dur" in
        *h*|*hour*) _durs=$(( $(printf '%s' "$_dur" | grep -oE '[0-9]+') * 3600 )) ;;
        *m*)        _durs=$(( $(printf '%s' "$_dur" | grep -oE '[0-9]+') * 60 )) ;;
    esac
    # A lock taken through pad-run.sh carries "[hb]" and is touched every 60 s while its
    # run lives, so silence is EVIDENCE the holder is gone rather than an inference from
    # elapsed time. 5 minutes is five missed beats -- generous for a slow adb, far short
    # of the half hour a non-heartbeated lock needs.
    case "$_lk" in
        *'[hb]'*) _need=300;  _why="no heartbeat for 5 min (lock is [hb])" ;;
        *)        _need=$(( _durs + 1800 ))
                  _why="stated ${_dur:-none} + 30 min (no heartbeat marker)" ;;
    esac
    if [ "$_idle" -lt "$_need" ]; then
        echo "NOT CLEARABLE: step 3 -- lock touched ${_idle}s ago, need ${_need}s: $_why"
        return 1
    fi
    _resumed=$(adb shell dumpsys usagestats 2>/dev/null | tr -d '\r' \
                 | grep -c "type=ACTIVITY_RESUMED" 2>/dev/null || echo 0)
    echo "  step 3 OK   lock untouched ${_idle}s (>= ${_need}s: $_why); usagestats rows: $_resumed"
    echo "              CHECK THOSE ROWS YOURSELF for activity inside your window -- this"
    echo "              counts them, it cannot know which window you care about."

    echo "CLEARABLE (steps 1 and 3 only) -- holder '$_h'"
    echo
    echo "  STEP 2, yours to do, NOT checked here:"
    echo "    ListAgents on this box shows no session answering '$_h', AND a message to any"
    echo "    plausible owner has gone unanswered for 10 minutes. Liveness of the holder"
    echo "    SESSION is the signal -- never liveness of a process on the device. A frozen"
    echo "    runtime is alive, has a ServiceRecord, and does nothing."
    echo
    echo "  STEP 4, yours to do:"
    echo "    post this line verbatim (bus or issue) before clearing:"
    echo "      $_lk"
    echo "    then take the lock in the same command with purpose 'cleared stale $_h'."
    return 0
}


# Step 4 of the #56 rule, and ONLY once stale_check says CLEARABLE.
#
# It cannot post to the bus for you, so it will not pretend to: --posted <ref> is you
# asserting you already published the old line, and the reference is recorded in the new
# lock so the claim is auditable by whoever was holding it. Without it, this refuses.
clear_stale() {
    _h="${1:-}"; shift 2>/dev/null || true
    _ref=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --posted) _ref="${2:-}"; shift 2 ;;
            *) echo "usage: $0 clear-stale <your-handle> --posted <where-you-posted-the-old-line>" >&2; return 2 ;;
        esac
    done
    [ -n "$_h" ] || { echo "usage: $0 clear-stale <your-handle> --posted <ref>" >&2; return 2; }
    if [ -z "$_ref" ]; then
        echo "REFUSING: --posted <ref> is required." >&2
        echo "  Step 4 of the rule is that the old line is published BEFORE it is cleared," >&2
        echo "  so the holder can see what happened to their lock. Post it, then pass where." >&2
        return 2
    fi
    _old=$(read_lock)
    stale_check "" >/dev/null 2>&1 || { echo "REFUSING: stale-check does not say CLEARABLE. Run it and read the failing step." >&2; return 1; }
    _oldh=$(pad_holder "$_old")
    echo "clearing stale lock, previously held by '$_oldh':"
    printf '  %s\n' "$_old"
    adb shell "rm -f $L"
    "$0" take "$_h" "cleared stale $_oldh (posted: $_ref)" || return 1
}

case "${1:-status}" in
  status) v=$(read_lock)
          if adb shell "test -e $L" 2>/dev/null; then [ -n "$v" ] && echo "HELD: $v" || echo "HELD by unknown (empty file) — do not take it"
          else echo "free"; fi ;;
  take)   h="${2:?handle}"; w="${3:-unspecified}"; v=$(read_lock)
          if adb shell "test -e $L" 2>/dev/null && [ -n "$v" ] && [ "$(pad_holder "$v")" != "$h" ]; then echo "REFUSING: held by someone else -> $v"; exit 1; fi
          if adb shell "test -e $L" 2>/dev/null && [ -z "$v" ]; then echo "REFUSING: empty lock file = held by unknown"; exit 1; fi
          # Create ATOMICALLY when the lock is absent. The check above and the write below are
          # two round trips to the device, and a second session can take the lock in between --
          # a plain ">" then silently destroys their claim. That happened for real on
          # 2026-09-12: one session's one-line lock was overwritten ~17s later by another's,
          # and the victim only found out because they were told. `set -C` makes the redirect
          # fail instead ("File exists"), verified on this device's /system/bin/sh.
          # Refreshing a lock that is already OURS still needs a plain write.
          _line="$h $(date -u +%Y-%m-%dT%H:%M:%SZ) $w"
          # Escape single quotes for the DEVICE shell. The line is interpolated into
          # adb shell "echo '...'", so one apostrophe in the reason ends the quoting and
          # the write silently produces nothing -- a caller passing "test 2's run" got an
          # EMPTY lock file, which then correctly reads back as held-by-unknown. The
          # read-back guard below caught it, which is the only reason it was not a stranded
          # lock; the write should not have been able to fail that way in the first place.
          # Standard sh idiom: ' -> '\'' .
          _esc=$(printf '%s' "$_line" | sed "s/'/'\\\\''/g")
          if adb shell "test -e $L" 2>/dev/null; then
              adb shell "echo '$_esc' > $L"                  # already ours; checked above
          else
              adb shell "set -C; echo '$_esc' > $L" >/dev/null 2>&1
          fi
          # Read back and PROVE it is ours. A lost race, a full filesystem or a read-only
          # /data/local/tmp all leave the write silently ineffective, and "took:" printing
          # someone else's lock is how a caller walks on to drive the pad anyway.
          v=$(read_lock)
          if [ "$(pad_holder "$v")" != "$h" ]; then
              echo "REFUSING: could not take the lock; it now reads -> ${v:-<empty>}" >&2
              exit 1
          fi
          echo "took: $v" ;;
  release) h="${2:?handle}"; v=$(read_lock)
          if [ -n "$v" ] && [ "$(pad_holder "$v")" != "$h" ]; then echo "REFUSING: not my entry -> $v"; exit 1; fi
          adb shell "rm -f $L"; echo "released" ;;
  stale-check) stale_check "${2:-}" ;;
  clear-stale) shift; clear_stale "$@" ;;
  *) echo "usage: $0 status|take <handle> <what>|release <handle>|stale-check [<handle>]|clear-stale <handle> --posted <ref>"; exit 1 ;;
esac
