#!/system/bin/sh
# Install everything FROM the tablet itself, with no computer.
#
# Run this in Termux (or any on-device shell) after unzipping the bundle:
#     sh scripts/install-on-tablet.sh
#
# Uses `pm install`, which needs no adb and no root. Android will show a permission
# prompt the first time the shell app is allowed to install packages — accept it.
cd "$(dirname "$0")/.." || exit 1

fail=0
for dir in apks/1-cnsdk-services apks/2-displayxr-runtime apks/3-demos apks/4-browser; do
    for a in "$dir"/*.apk; do
        [ -f "$a" ] || continue
        printf '  %s ... ' "$(basename "$a")"
        # -r replace, -d allow downgrade, -g grant permissions.
        # Retry: straight after a reboot the package manager is still re-scanning and
        # rejects installs with no useful error, which looks like a broken bundle when it
        # is only "too early". A signature/downgrade rejection is a real verdict, so stop
        # retrying on those.
        ok=0
        for try in 1 2 3; do
            out=$(pm install -r -d -g "$a" 2>&1)
            case "$out" in *Success*) ok=1; break ;; esac
            case "$out" in *SIGNATURE*|*INSTALL_FAILED_UPDATE_INCOMPATIBLE*|*INSTALL_FAILED_VERSION_DOWNGRADE*) break ;; esac
            sleep 3
        done
        if [ "$ok" = 1 ]; then
            echo "OK"
        else
            echo "FAILED"
            echo "$out" | grep -E "Failure|Error|INSTALL_" | head -1 | sed 's/^/      /'
            fail=$((fail+1))
        fi
    done
done

echo
if [ "$fail" -eq 0 ]; then
    echo "All installs succeeded. REBOOT THE TABLET before use."
else
    echo "$fail install(s) failed."
    echo "If every one failed, this shell probably lacks install permission —"
    echo "use the manual tap-to-install route in INSTALL.md instead."
    exit 1
fi
