#!/usr/bin/env bash
# Fixture test for lens_ack_verdict (lib.sh) -- the leg that made prove-3d.sh stop passing a
# panel that was physically 2D. No device, no adb: it feeds recorded logcat captures in and
# checks the verdict, so it runs in CI and on any box while the pad is locked by someone else.
#
#   ./android-bundle/tests/lens-ack-fixtures.sh
#
# fixtures/ holds real captures from the K68 (2026-09-22) plus the three shapes that must NOT
# be read as an ack. Add a fixture whenever this classifier is changed -- the whole point of
# the incident was that a check agreed with a broken device.
#
# NOTE this lives OUTSIDE scripts/, deliberately: sync-from-repo.sh ships scripts/ to testers,
# and a test is not part of the bundle they unpack.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../scripts/lib.sh"          # lens_ack_verdict

fail=0
check() {  # check <expected> <fixture> <why this case exists>
    got=$(lens_ack_verdict "$(cat "$HERE/fixtures/$2")")
    if [ "$got" = "$1" ]; then
        printf '  ok    %-28s -> %-12s %s\n' "$2" "$got" "$3"
    else
        printf '  FAIL  %-28s -> %-12s (expected %s) %s\n' "$2" "$got" "$1" "$3"
        fail=1
    fi
}

echo "lens_ack_verdict fixtures:"
check wedged      lens-wedged.log             "K68 as captured: write out, UART never answered -> FAIL"
check acked       lens-healthy.log            "same write after a reboot, answered -> the leg passes"
check acked       lens-healthy-threadtime.log "logcat's other default format classifies the same"
check unacked     lens-ack-before-write.log   "an ack BEFORE the 3D write answers the PREVIOUS state"
check no-3d-write lens-no-3d-write.log        "HAL talking, no 3D write in the window -> not checked"
check absent      lens-absent.log             "no such HAL (other OEM platforms) -> not checked, never FAIL"
echo

# The classifier is only half of it: prove-3d.sh must also turn each verdict into the right
# gate. Mirror its case statement so a verdict that stops failing is caught here too.
gate=$(sed -n '/^case "\$lens" in$/,/^esac$/p' "$HERE/../scripts/prove-3d.sh")
[ -n "$gate" ] || { echo "  FAIL  prove-3d.sh no longer has a 'case \$lens' gate to check"; fail=1; }
for v in wedged unacked; do
    printf '%s\n' "$gate" | grep -qE "^ *$v\)[^#]*lens_ok=0" \
      || { echo "  FAIL  prove-3d.sh does not fail on verdict '$v'"; fail=1; }
done
for v in acked no-3d-write; do
    printf '%s\n' "$gate" | grep -qE "^ *$v\)[^#]*lens_ok=1" \
      || { echo "  FAIL  prove-3d.sh does not pass verdict '$v'"; fail=1; }
done
printf '%s\n' "$gate" | grep -qE '^ *\*\)[^#]*lens_ok=1' \
  || { echo "  FAIL  prove-3d.sh must not FAIL on an unknown/absent verdict -- other OEM platforms"; fail=1; }

[ "$fail" -eq 0 ] || { echo "FAIL: lens-ack classification is wrong."; exit 1; }
echo "PASS: every fixture classifies as expected and prove-3d.sh gates on it correctly."
