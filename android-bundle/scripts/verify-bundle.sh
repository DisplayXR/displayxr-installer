#!/usr/bin/env bash
# Check this bundle is complete and internally consistent BEFORE sending it out.
# Every failure mode checked here is one that otherwise fails SILENTLY on device.
set -u
cd "$(dirname "$0")/.."
warn=0; err=0
say()  { printf '  %-46s %s\n' "$1" "$2"; }
bad()  { say "$1" "FAIL — $2"; err=$((err+1)); }
soft() { say "$1" "WARN — $2"; warn=$((warn+1)); }

echo "== components present =="
for d in apks/1-cnsdk-services apks/2-displayxr-runtime apks/3-demos apks/4-browser; do
    n=$(ls "$d"/*.apk 2>/dev/null | wc -l | tr -d ' ')
    case "$d" in
        *cnsdk*)     [ "$n" -ge 2 ] && say "$d" "$n apk(s)" || bad "$d" "expected device-service AND headTracking-service" ;;
        *runtime*)   [ "$n" -ge 1 ] && say "$d" "$n apk(s)" || bad "$d" "no runtime — see MISSING.txt" ;;
        *)           [ "$n" -ge 1 ] && say "$d" "$n apk(s)" || soft "$d" "empty — see the note in that folder" ;;
    esac
done

echo
echo "== the CNSDK core is in the RIGHT package =="
DS=$(ls apks/1-cnsdk-services/device-service*.apk 2>/dev/null | head -1)
if [ -n "$DS" ]; then
    if unzip -l "$DS" 2>/dev/null | grep -q "libleiaCore-impl.so"; then
        say "device-service carries the core" "OK"
    else
        bad "device-service" "no libleiaCore-impl.so — this will update nothing"
    fi
else
    bad "device-service" "absent — the core cannot reach the tablet without it"
fi

echo
echo "== runtime and its Leia plug-in are a matched pair =="
RT=$(ls apks/2-displayxr-runtime/*.apk 2>/dev/null | head -1)
if [ -n "$RT" ]; then
    pub=$(unzip -p "$RT" lib/arm64-v8a/libopenxr_displayxr.so 2>/dev/null | strings | grep -c "206: measured weave->scanout residual")
    # AUTHORITATIVE: "PUBLISHED to CNSDK" and the CNSDK typedef. Both appear only when
    # the version-guarded consumer actually COMPILED IN — the log branch is
    # dead-code-eliminated when the guard fails, so its presence is direct proof.
    #
    # INFORMATIONAL ONLY: set_predicted_scanout_cnsdk (DP vtable impl) and
    # leia_cnsdk_set_predicted_scanout (entry point). These are the plug-in's OWN
    # symbols and exist whether or not the guarded CNSDK call compiled in. Measured on
    # plug-in v2.6.10 — which forwards nothing — both were present at the same counts
    # as in v2.6.11, which does. Verifying on them alone yields a FALSE PASS.
    #
    # Worth stating because it is easy to get backwards: the "real" linked symbols are
    # the unreliable ones here, and the string constants are the reliable ones.
    # Extract to a file rather than a shell variable: a .so contains null bytes and
    # command substitution silently drops them, which is exactly the kind of quiet
    # corruption this script exists to catch.
    plug=$(mktemp); trap 'rm -f "$plug"' EXIT
    unzip -p "$RT" lib/arm64-v8a/libdxrp050_leia_cnsdk.so > "$plug" 2>/dev/null
    typ=$(strings "$plug" | grep -c "leia_interlacer_set_predicted_scanout_ns")
    pubc=$(strings "$plug" | grep -c "PUBLISHED to CNSDK")
    fwd=$(strings "$plug" | grep -c "set_predicted_scanout_cnsdk")        # informational
    ent=$(strings "$plug" | grep -c "leia_cnsdk_set_predicted_scanout")   # informational
    [ "${pub:-0}" -ge 1 ] && say "runtime publishes the horizon" "OK" || soft "runtime publish" "not found (older runtime)"
    if [ "${pubc:-0}" -ge 1 ] && [ "${typ:-0}" -ge 1 ]; then
        say "plug-in forwards it to CNSDK" "OK  (published=$pubc typedef=$typ)"
    elif [ "${pubc:-0}" -ge 1 ] || [ "${typ:-0}" -ge 1 ]; then
        soft "plug-in markers disagree" "published=$pubc typedef=$typ — investigate"
    else
        # WARN, not FAIL: as of runtime v2.16.0 the SHIPPING release itself bundles a
        # pre-v2.6.10 plug-in, so this is an upstream property rather than a mistake in
        # assembling this bundle. Everything except the measured-horizon path works.
        # It stays loud because the failure is otherwise invisible: the runtime
        # publishes a real horizon, the plug-in drops it, and CNSDK falls back to its
        # hardcoded 40 ms with nothing logged.
        # vtable/entry present here means "right plug-in, built against a CNSDK
        # lacking the API" rather than "plug-in too old" — different fix.
        if [ "${fwd:-0}" -ge 1 ] || [ "${ent:-0}" -ge 1 ]; then
            soft "plug-in present but consumer compiled OUT" \
                 "built against a CNSDK without the API (vtable=$fwd entry=$ent); #206 inert"
        else
            soft "plug-in has no consumer at all" "too old (vtable=$fwd entry=$ent); #206 inert"
        fi
    fi
fi

echo
echo "== the runtime APK's CNSDK loader matches the plug-in it bundles =="
# CNSDK exact-matches the loader shim against the apiVersion the plug-in was built
# for: `[Core-Loader] Invalid load request: apiVersion (X) does not match the loader
# version (Y)` -> leia_cnsdk_create failed (-22) -> "falling back to no-DP path".
# Apps still launch and render -- in 2D. NOTHING upstream reports an error, and the
# #206 string check above passes, because the strings are present whether or not
# the loader will ever load them. This is the check that would have caught
# runtime 2.16.2/2.16.3 (loader 0.10.62, plug-in 0.10.63) before it reached a pad.
RT=$(ls apks/2-displayxr-runtime/*.apk 2>/dev/null | head -1)
if [ -n "$RT" ]; then
    _t=$(mktemp -d)
    unzip -o -q -j "$RT" 'lib/arm64-v8a/libleiaCore-loader.so' 'lib/arm64-v8a/libdxrp050_leia_cnsdk.so' -d "$_t" 2>/dev/null
    LDR=$(strings -a "$_t/libleiaCore-loader.so" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | head -1)
    # The plug-in .so embeds its CNSDK include paths: cnsdk-android-<ver>+<build>/include/...
    PLG=$(strings -a "$_t/libdxrp050_leia_cnsdk.so" 2>/dev/null | grep -oE 'cnsdk-android-[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -1 | sed 's/cnsdk-android-//')
    rm -rf "$_t"
    if [ -z "$LDR" ] || [ -z "$PLG" ]; then
        bad "runtime CNSDK pair" "could not read loader ($LDR) / plug-in ($PLG) versions from the APK"
    elif [ "$LDR" = "$PLG" ]; then
        say "runtime CNSDK pair" "loader $LDR == plug-in $PLG  OK"
    else
        bad "runtime CNSDK pair" "loader $LDR != plug-in $PLG -> CNSDK REFUSES TO LOAD, apps run in 2D (no DP)"
    fi
    # From the release after displayxr-runtime#1356 the APK also SAYS which loader it
    # bundles, as manifest meta-data readable on device with one `dumpsys package`:
    #   com.displayxr.CNSDK_LOADER_VERSION  x.y.z   gated: must equal the loader binary
    #   com.displayxr.CNSDK_LOADER_BUILD    x.y.z+<n>.<sha>   identification only
    # Read them here offline (aapt2) and hold the gated one to the same string the
    # loader .so reports above -- a stamp that disagrees with the binary would make
    # the on-device audit lie, which is worse than no stamp. Absent = older runtime;
    # then the unpack above is the ONLY way to check the pair, on or off the device.
    AAPT2=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
    if [ -n "$AAPT2" ]; then
        _xt=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$RT" 2>/dev/null)
        _stamp() { printf '%s\n' "$_xt" | grep -A1 "com.displayxr.$1" | grep -oE ':value\([^)]*\)="[^"]*"' | head -1 | sed -E 's/.*="([^"]*)"/\1/'; }
        ST_VER=$(_stamp CNSDK_LOADER_VERSION); ST_BLD=$(_stamp CNSDK_LOADER_BUILD)
        if [ -z "$ST_VER" ]; then
            say "runtime loader stamp" "absent (runtime predates displayxr-runtime#1356) -- pair NOT auditable on device"
        elif [ "$ST_VER" = "$LDR" ]; then
            say "runtime loader stamp" "CNSDK_LOADER_VERSION=$ST_VER == loader binary  OK   build=${ST_BLD:-?}"
        else
            bad "runtime loader stamp" "CNSDK_LOADER_VERSION=$ST_VER but the loader binary says $LDR -- the on-device audit would lie"
        fi
    else
        soft "runtime loader stamp" "no aapt2 under ~/Library/Android/sdk/build-tools; stamp not checked offline"
    fi
fi

echo "== browser inline-3D default =="
BR=$(ls apks/4-browser/*.apk 2>/dev/null | head -1)
if [ -n "$BR" ]; then
    # Preview 0.1.23 and earlier ship inline-3D OFF, gated behind --enable-inline-3d,
    # which on Android arrives only via /data/local/tmp/chrome-command-line (adb only).
    # 0.1.24+ carries the default-on fix (displayxr-browser#190). This cannot be read
    # from the APK, so it is keyed on the version in the filename.
    #
    # Compare NUMERICALLY, not with a glob. The old `case` listed 0.1.2[0-3] and fell
    # through to a default that said "browser predates default-on fix?" — so 0.1.24,
    # the first version that HAS the fix, hit the default and reported the opposite of
    # the truth. A glob over version numbers cannot express "or newer".
    # Signing: a debug-key APK is refused outright by some OEM App Centers with
    # "DisplayXR Browser has stopped ... update the app in App Center" -- a message
    # naming neither the cause nor any real remedy (browser#188). Silent on device
    # in the sense that matters: nothing in the bundle reveals it.
    APKSIGNER=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
    if [ -z "$APKSIGNER" ] || [ ! -x "$APKSIGNER" ]; then
        soft "browser signing" "apksigner not found - cannot verify (install Android build-tools)"
    else
        DN=$("$APKSIGNER" verify --print-certs "$BR" 2>/dev/null | grep -m1 -i 'certificate DN' || true)
        case "$DN" in
            *"CN=DisplayXR Browser"*) say "browser signing" "release-signed (CN=DisplayXR Browser)" ;;
            *CN=Unknown*)             bad  "browser signing" "DEBUG-KEY signed - OEM App Center will refuse first launch (browser#188)" ;;
            "")                       bad  "browser signing" "UNSIGNED or unreadable signature" ;;
            *)                        soft "browser signing" "signed by an unexpected identity: $DN" ;;
        esac
    fi

    BRV=$(basename "$BR" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$BRV" ]; then
        soft "browser (version unreadable)" "cannot tell if inline-3D defaults on; check INSTALL.md step 4"
    elif [ "$(printf '%s\n0.1.24\n' "$BRV" | sort -V | head -1)" = "0.1.24" ]; then
        say "browser $BRV" "inline-3D ON by default — no adb flag needed"
    else
        soft "browser $BRV" "inline-3D OFF by default; needs the adb flag in INSTALL.md step 4"
    fi
fi

echo
[ "$err" -eq 0 ] && echo "BUNDLE OK${warn:+  ($warn warning(s))}" || { echo "$err blocking problem(s), $warn warning(s) — do not ship"; exit 1; }
