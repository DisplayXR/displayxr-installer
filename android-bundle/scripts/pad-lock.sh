#!/usr/bin/env bash
# Shared-pad lock, in the agreed format (freeform-android, 2026-09-08):
#   /data/local/tmp/pad.lock holds "<handle> <ISO ts> <what/how long>"; cat it back after writing.
#   An EMPTY file means held-by-unknown — never treat it as free. Remove only your own entry.
#
#   ./scripts/pad-lock.sh status
#   ./scripts/pad-lock.sh take "android-bundle" "0.10.68 four-way swap, ~20 min"
#   ./scripts/pad-lock.sh release "android-bundle"
set -u
L=/data/local/tmp/pad.lock
read_lock() { adb shell "cat $L 2>/dev/null" | tr -d '\r'; }
case "${1:-status}" in
  status) v=$(read_lock)
          if adb shell "test -e $L" 2>/dev/null; then [ -n "$v" ] && echo "HELD: $v" || echo "HELD by unknown (empty file) — do not take it"
          else echo "free"; fi ;;
  take)   h="${2:?handle}"; w="${3:-unspecified}"; v=$(read_lock)
          if adb shell "test -e $L" 2>/dev/null && [ -n "$v" ] && ! printf '%s' "$v" | grep -q "^$h "; then echo "REFUSING: held by someone else -> $v"; exit 1; fi
          if adb shell "test -e $L" 2>/dev/null && [ -z "$v" ]; then echo "REFUSING: empty lock file = held by unknown"; exit 1; fi
          adb shell "echo '$h $(date -u +%Y-%m-%dT%H:%M:%SZ) $w' > $L"; echo "took: $(read_lock)" ;;
  release) h="${2:?handle}"; v=$(read_lock)
          if [ -n "$v" ] && ! printf '%s' "$v" | grep -q "^$h "; then echo "REFUSING: not my entry -> $v"; exit 1; fi
          adb shell "rm -f $L"; echo "released" ;;
  *) echo "usage: $0 status|take <handle> <what>|release <handle>"; exit 1 ;;
esac
