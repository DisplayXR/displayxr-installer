#!/usr/bin/env bash
# Read the CNSDK pairing stamps from what is INSTALLED on the tablet -- version-agnostic.
#
#   ./scripts/audit-device.sh
#
# Android 13 on the NP02J does NOT print <meta-data> in `dumpsys package` (verified
# 2026-09-05: the runtime's stamps and the services' FULL_VERSION are both invisible
# there), so the honest on-device read is: pull each package's installed base.apk and
# read its manifest with aapt2 on the host. Needs Android build-tools on this computer;
# without them the stamps are reported as "not checked", never guessed.
#
#   runtime   com.displayxr.CNSDK_LOADER_VERSION  x.y.z  (== the loader binary; gated in CI)
#             com.displayxr.CNSDK_LOADER_BUILD    x.y.z+<n>.<sha>  (identification only)
#   services  com.leia.cnsdk.FULL_VERSION         x.y.z+build  (CNSDK >= 0.10.65)
set -u
RT=org.freedesktop.monado.openxr_runtime.out_of_process
command -v adb >/dev/null || { echo "adb not found."; exit 1; }
AAPT2=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/aapt2 "${ANDROID_HOME:-/nonexistent}"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
ver() { adb shell dumpsys package "$1" 2>/dev/null | tr -d '\r' | grep -m1 versionName | tr -d ' ' | cut -d= -f2; }
# stamp <pkg> <meta-data name> -> value, "" if absent, "?" if it could not be read
stamp() {
    local p; p=$(adb shell pm path "$1" 2>/dev/null | tr -d '\r' | sed 's/^package://' | head -1)
    [ -n "$p" ] || { echo "?"; return; }
    [ -n "$AAPT2" ] || { echo "?"; return; }
    local t; t=$(mktemp -d)
    adb pull "$p" "$t/base.apk" >/dev/null 2>&1 || { rm -rf "$t"; echo "?"; return; }
    "$AAPT2" dump xmltree --file AndroidManifest.xml "$t/base.apk" 2>/dev/null \
        | grep -A1 "\"$2\"" | grep -oE ':value\([^)]*\)="[^"]*"' | head -1 | sed -E 's/.*="([^"]*)"/\1/'
    rm -rf "$t"
}
show() { printf '  %-58s %s\n' "$1" "$2"; }
warn=0
echo "installed:"
for p in com.leialoft.display.config com.leia.headtrackingservice "$RT" org.chromium.chrome; do show "$p" "$(ver "$p" 2>/dev/null || true)"; done
[ -n "$AAPT2" ] || { echo; echo "  no aapt2 under ~/Library/Android/sdk/build-tools (or \$ANDROID_HOME) -- stamps NOT checked."; exit 0; }
echo "stamps (read from the installed APKs):"
RT_V=$(stamp "$RT" com.displayxr.CNSDK_LOADER_VERSION); RT_B=$(stamp "$RT" com.displayxr.CNSDK_LOADER_BUILD)
DS_F=$(stamp com.leialoft.display.config com.leia.cnsdk.FULL_VERSION); HT_F=$(stamp com.leia.headtrackingservice com.leia.cnsdk.FULL_VERSION)
show "runtime  CNSDK_LOADER_VERSION" "${RT_V:-<absent: runtime predates displayxr-runtime#1356>}"
show "runtime  CNSDK_LOADER_BUILD" "${RT_B:-<absent>}"
# Provenance a version string cannot fake: the sha256 of the CNSDK core the device-service actually
# carries, plus the installed APK's own hash vs the bundle file. Measured 2026-09-08: a service
# installed on the pad reported versionName 0.10.67 and FULL_VERSION "0.10.67" while carrying a
# DIFFERENT core than the 0.10.67 release (impl 6421b85c… vs the release's 8eef31d0…). Version
# strings alone would have called that "the release".
impl_sha() {
    IS_PATH=$(adb shell pm path com.leialoft.display.config 2>/dev/null | tr -d '\r' | sed 's/^package://' | head -1)
    [ -n "$IS_PATH" ] && { IS_T=$(mktemp); IS_D=$(mktemp -d); } || { printf 'unknown'; return 0; }
    adb pull "$IS_PATH" "$IS_T" >/dev/null 2>&1
    unzip -q -o -j "$IS_T" 'lib/arm64-v8a/libleiaCore-impl.so' -d "$IS_D" >/dev/null 2>&1
    IS_DEV=$(shasum -a 256 "$IS_D/libleiaCore-impl.so" 2>/dev/null | cut -c1-16)
    IS_BF=$(ls "$(dirname "$0")/../apks/1-cnsdk-services"/device-service-release-*.apk 2>/dev/null | head -1)
    IS_BUN=""
    if [ -n "$IS_BF" ]; then IS_D2=$(mktemp -d); unzip -q -o -j "$IS_BF" 'lib/arm64-v8a/libleiaCore-impl.so' -d "$IS_D2" >/dev/null 2>&1
        IS_BUN=$(shasum -a 256 "$IS_D2/libleiaCore-impl.so" 2>/dev/null | cut -c1-16); rm -rf "$IS_D2"; fi
    rm -rf "$IS_T" "$IS_D"
    if [ -z "$IS_DEV" ]; then printf 'unreadable'
    elif [ -z "$IS_BUN" ]; then printf '%s… (no bundle service APK to compare)' "$IS_DEV"
    elif [ "$IS_DEV" = "$IS_BUN" ]; then printf '%s… == the bundle device-service' "$IS_DEV"
    else printf '%s… DIFFERS from the bundle (%s…) — the INSTALLED service is not the bundle build' "$IS_DEV" "$IS_BUN"; fi
}
show "CNSDK core (libleiaCore-impl.so) sha256" "$(impl_sha)"
show "device-service  FULL_VERSION" "${DS_F:-<absent: CNSDK < 0.10.65; versionName $(ver com.leialoft.display.config) is the provenance>}"
show "headTracking    FULL_VERSION" "${HT_F:-<absent: CNSDK < 0.10.65>}"
# What actually gates the core loading is loader == PLUG-IN apiVersion, and both live
# inside the runtime APK (verify-bundle.sh checks that offline; CI asserts it). The
# services' impl version is NOT gated against the loader: measured 2026-09-05 -- a
# 0.10.65 device-service under a 0.10.63 loader mapped the 0.10.65 libleiaCore-impl.so,
# initialized, created the DP, published the horizon. So this line is information,
# never a failure. Only prove-3d.sh (running log) can say whether 3D works.
SVC=${DS_F:-$(ver com.leialoft.display.config)}; SVC=${SVC%%+*}
if [ -n "$RT_V" ] && [ "$RT_V" != "?" ] && [ -n "$SVC" ]; then
    if [ "$RT_V" = "$SVC" ]; then show "runtime loader vs installed services" "$RT_V == $SVC  (same drop)"
    else show "runtime loader vs installed services" "$RT_V vs $SVC  (mixed; not a load gate -- confirm with scripts/prove-3d.sh)"; fi
fi
if [ -n "$DS_F" ] && [ -n "$HT_F" ] && [ "$DS_F" != "$HT_F" ]; then show "the two services" "DIFFERENT builds ($DS_F vs $HT_F)"; warn=1; fi

# PANEL CALIBRATION -- the check that was missing on 2026-09-05, when every other check
# here and in prove-3d.sh passed while the panel sat in flat 2D at a normal viewing
# distance. donopx sets the no-face phase gate: CNSDK resets its no-face timer only while
# donopx*63/z lands inside (0.15, 0.85), so donopx alone decides the range of viewing
# distances at which the display will weave at all. A bad donopx is silent -- head
# tracking keeps working perfectly -- which is why it has to be checked, not eyeballed.
# Compare it against the DESIGN value in the same config: they are the same quantity, so a
# real calibration differs by a few percent (px, n and sl all move 2-9% on a K68-EVT3-b).
echo
echo "panel calibration (decides whether it can weave at all):"
CFG=$(adb shell "su 0 cat /data/user_de/0/com.leialoft.display.config/files/local_leia_3d_para.txt" 2>/dev/null | tr -d '\r')
if [ -z "$CFG" ]; then
    show "served config" "<unreadable -- needs adb root; skipped>"
else
    CAL=$(printf '%s' "$CFG" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('ERR parse'); raise SystemExit
cal=d.get('cellCalibration',{}); des=d.get('cellDesign',{})
dn=cal.get('donopx', cal.get('don_mm')); dd=des.get('donopx')
dev=d.get('configInfo',{}).get('device','?')
if not dn or not dd: print('ERR missing'); raise SystemExit
lo,hi = dn*63/0.85, dn*63/0.15
print(f'{dev}|{dn:.6f}|{dd:.6f}|{dn/dd:.2f}|{lo:.0f}|{hi:.0f}')
" 2>/dev/null)
    case "$CAL" in
      ERR*|"") show "served config" "<could not read cellCalibration/cellDesign>" ;;
      *) IFS='|' read -r DEV DN DD RATIO LO HI <<EOF2
$CAL
EOF2
         show "device / calibrated d/n" "$DEV / $DN  (design $DD)"
         show "weaves at viewing distance" "${LO} mm .. ${HI} mm"
         # A tablet is used at roughly 40-55 cm. If 450 mm is outside the window the panel
         # cannot leave 2D in normal use, whatever every other check says.
         if [ "$LO" -gt 450 ] || [ "$HI" -lt 450 ]; then
             show "  -> 450 mm inside that window" "NO -- panel CANNOT weave at a normal viewing distance"; warn=1
         else
             show "  -> 450 mm inside that window" "yes"
         fi
         BAD=$(python3 -c "print(1 if $RATIO>1.5 or $RATIO<0.667 else 0)" 2>/dev/null)
         if [ "$BAD" = 1 ]; then
             show "  -> calibrated vs design" "${RATIO}x -- UNIT/CONVERSION ERROR upstream (expect ~1.0)"; warn=1
         else
             show "  -> calibrated vs design" "${RATIO}x  (sane)"
         fi ;;
    esac
fi
exit $warn
