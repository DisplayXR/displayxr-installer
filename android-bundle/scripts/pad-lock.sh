#!/usr/bin/env bash
# Shared-pad lock, in the agreed format (freeform-android, 2026-09-08):
#   /data/local/tmp/pad.lock holds "<handle> <ISO ts> <what/how long>"; cat it back after writing.
#   An EMPTY file means held-by-unknown — never treat it as free. Remove only your own entry.
#
#   ./scripts/pad-lock.sh status
#   ./scripts/pad-lock.sh take "android-bundle" "0.10.68 four-way swap, ~20 min"
#   ./scripts/pad-lock.sh release "android-bundle"
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"   # pad_holder
L=/data/local/tmp/pad.lock
read_lock() { adb shell "cat $L 2>/dev/null" | tr -d '\r'; }
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
          if adb shell "test -e $L" 2>/dev/null; then
              adb shell "echo '$_line' > $L"                 # already ours; checked above
          else
              adb shell "set -C; echo '$_line' > $L" >/dev/null 2>&1
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
  *) echo "usage: $0 status|take <handle> <what>|release <handle>"; exit 1 ;;
esac
