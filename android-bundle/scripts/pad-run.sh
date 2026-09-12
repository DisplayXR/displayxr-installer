#!/usr/bin/env bash
# Run a command against the shared pad, or refuse to run it at all.
#
#   ./scripts/pad-run.sh <handle> "<purpose, duration>" -- <command...>
#   ./scripts/pad-run.sh mac/media3 "#71 phase 1, ~10 min" -- ./scripts/prove-3d.sh
#   ./scripts/pad-run.sh runtime-wake "thaw proof" -- adb shell am start -n pkg/.Main
#
# Set PAD_RUN_OUT to your session's scratch directory. It defaults to a mktemp -d under
# /tmp, which is the one place the after-the-fact evidence should NOT live -- it is the
# only record of a contaminated window once logcat has rolled.
#
# WHY THIS EXISTS. The lock was advisory twice over. pad-lock.sh refuses to hand the lock to
# a second holder, and require_pad refuses to drive the pad -- but both only protect scripts
# that ASK. Two sessions in three days drove the pad under another session's live measurement,
# and both made the identical mistake: they gated WRITING their own lock and then ran the
# device commands regardless (2026-09-10 08:52Z, 2026-09-12 08:37Z). Neither was a prove-*
# script, so the require_pad guard inside the harness could not see them -- they were ad-hoc
# one-liners. A guard that lives inside the harness cannot defend against a command typed
# outside it. This wrapper can, because it owns the exec: nothing runs until the lock check
# passes. Put every pad command behind it, ad-hoc ones most of all.
#
# WHAT IT DOES
#   1. Refuses (exit 75, EX_TEMPFAIL) while a FOREIGN handle holds the lock, and never execs.
#      75 rather than 1 so a caller can tell "wait and retry" from "this run is broken".
#   2. Takes the lock for <handle>, runs the command, then releases it -- but only if it took
#      it. A lock that was already yours is left alone on exit, so nesting cannot strand it.
#   3. Restores the pad's resting rotation on the way out, however the command exited.
#   4. Snapshots who else used the device, before and after, and prints the delta.
#
# (4) is the half a lock cannot give you. A lock prevents a collision; it does not let you
# AUDIT one afterwards. logcat rolls within minutes on this pad, so by the time you learn a
# peer touched the device, the line naming what they did is gone -- which on 2026-09-12 left
# a published measurement resting on file mtimes to infer ordering, and it had to be
# withdrawn. usagestats keeps per-package ACTIVITY_RESUMED rows with wall-clock times long
# after logcat drops them, so the delta below can still name a foreign app launch afterwards.
# Any reading that keys on a client connect/disconnect -- cgroup.freeze, oom adj, service
# lifetime -- is invertible by ONE foreign launch, so "my run looked clean" is not evidence.
set -u

usage() { sed -n '2,20p' "$0"; exit 2; }

HANDLE="${1:-}"; PURPOSE="${2:-}"
[ -n "$HANDLE" ] && [ -n "$PURPOSE" ] || usage
shift 2
[ "${1:-}" = -- ] || { echo "pad-run.sh: expected -- before the command" >&2; usage; }
shift
[ $# -gt 0 ] || { echo "pad-run.sh: no command given" >&2; usage; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib.sh"        # restore_rotation, require_pad, pad_holder
command -v adb >/dev/null || { echo "pad-run.sh: adb not found." >&2; exit 1; }

# Step 1. Refuse before anything is executed. PAD_HANDLE lets require_pad pass a lock that is
# already ours; PAD_REFUSE_RC makes a held lock exit 75 instead of 1.
LOCK=/data/local/tmp/pad.lock
export PAD_HANDLE="$HANDLE"
PAD_REFUSE_RC=75 require_pad

# Step 2. Take it, unless it is already ours. Written via pad-lock.sh so the on-device format
# stays in one place.
HELD_BEFORE=$(adb shell "cat $LOCK 2>/dev/null" | tr -d '\r')
TOOK=no
if [ "$(pad_holder "$HELD_BEFORE")" = "$HANDLE" ]; then
    echo "pad-run: lock already held by $HANDLE; leaving it in place on exit."
else
    "$HERE/pad-lock.sh" take "$HANDLE" "$PURPOSE" || exit 75
    TOOK=yes
fi

OUT="${PAD_RUN_OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
# stderr is discarded for the whole pipeline, not just adb: the snapshot has no diagnostics
# worth keeping, and a missing dumpsys must not derail a teardown.
snap() { { adb shell dumpsys usagestats | tr -d '\r' \
             | grep -oE 'time="[^"]+" type=ACTIVITY_RESUMED package=[^ ]+' > "$OUT/usage.$1"; } 2>/dev/null || true
         { adb shell dumpsys activity recents | tr -d '\r' > "$OUT/recents.$1"; } 2>/dev/null || true; }

# Steps 3+4. Teardown runs however the command exits, including a signal.
#
# ARM THIS BEFORE THE FIRST WRITE TO STDOUT. Measured the hard way: the informational echoes
# used to come before the trap, and piping pad-run into `head -1` closed the pipe after the
# first line -- so the next echo took an untrapped SIGPIPE and killed the script with the
# lock already taken, STRANDING it on the device. A stranded lock is the worst thing this
# tool can do, because nobody else may clear another handle's entry. Piping the output is an
# obvious thing to do, so every line that writes to stdout must already be protected.
finish() {
    _rc=$?
    trap - EXIT INT TERM HUP
    # IGNORE PIPE rather than resetting it: with PIPE reset, finish's own first echo writes
    # to the already-closed pipe, takes a second SIGPIPE and dies before releasing. Ignoring
    # turns those writes into harmless EPIPE errors (nothing here runs under set -e).
    trap "" PIPE
    snap after
    echo "pad-run: activities resumed during this run (anything not yours is contamination):"
    # Only the rows that are NEW since the start. A package you did not launch appearing here
    # means someone else was on the pad inside your window, and the timestamps date it.
    if [ -s "$OUT/usage.before" ] || [ -s "$OUT/usage.after" ]; then
        comm -13 <(sort -u "$OUT/usage.before" 2>/dev/null) <(sort -u "$OUT/usage.after" 2>/dev/null) \
          | sed 's/^/  /' | head -40
    fi
    # pad_holder, not grep: grep would treat the handle as a REGEX, and it also has to cope
    # with both on-device lock formats (see lib.sh). Noticing a WRONG lock is this line's
    # whole job, so it must not mis-parse a valid one.
    if [ "$(pad_holder "$(adb shell "cat $LOCK 2>/dev/null" | tr -d '\r')")" != "$HANDLE" ]; then
        echo "pad-run: WARNING -- the lock is no longer yours; someone overwrote it mid-run."
    fi
    # Restore ONLY if this invocation took the lock. In the nesting case (TOOK=no) the outer
    # run may have pinned landscape deliberately, and restore_rotation UNPINS -- so restoring
    # here would drop the outer run's pin mid-measurement, silently. That is the exact failure
    # class this wrapper exists to prevent. The outermost invocation owns the lock and restores
    # on its own exit.
    if [ "$TOOK" = yes ]; then
        # 2>/dev/null because finish() ignores SIGPIPE and children inherit that: the helper
        # pipes into `grep -m1`, which exits after the first match, so the upstream `tr` no
        # longer dies silently on the closed pipe -- it prints "tr: stdout: Broken pipe" on
        # every single run. Its stdout (the "rotation restored" line, with the verification
        # numbers) is what matters and is kept.
        restore_rotation 2>/dev/null
        "$HERE/pad-lock.sh" release "$HANDLE"
    fi
    exit "$_rc"
}
trap finish EXIT INT TERM HUP PIPE

snap before
echo "pad-run: $HANDLE -- $PURPOSE"
echo "pad-run: audit trail in $OUT"

"$@"
