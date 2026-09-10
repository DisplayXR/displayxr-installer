#!/usr/bin/env bash
# Gate BEFORE anything touches the pad: prove every bundle artifact is the published build, by hash,
# and that the derived provenance agrees. Version strings are not evidence — a service reporting
# 0.10.67 was carrying a different core on 2026-09-08.
#
#   ./scripts/check-artifacts.sh expected/0.10.68.txt
# The expected file is "<glob> <sha256>" per line, plus optional directives:
#   RUNTIME_STAMPS <loader> <build>      the runtime APK's CNSDK_LOADER_VERSION / _BUILD
#   PLUGIN_EMBEDS  <string>              must appear in the runtime's libdxrp050_leia_cnsdk.so
#   SERVICE_IMPL   <sha256>              sha256 of device-service's lib/arm64-v8a/libleiaCore-impl.so
set -u
cd "$(dirname "$0")/.."
EXP="${1:?usage: check-artifacts.sh <expected-file>}"
AAPT2=$(ls -d "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)
fail=0; ok() { printf '  %-58s OK\n' "$1"; }; bad() { printf '  %-58s FAIL — %s\n' "$1" "$2"; fail=$((fail+1)); }
# Published hashes are often truncated (e.g. "c8f2bd1b611b6db9…"). Compare by PREFIX so a correct
# build is not rejected for being quoted short — but require >=16 hex chars so it stays meaningful.
hasheq() {  # hasheq <full-actual> <expected-possibly-truncated>
    e=$(printf '%s' "$2" | tr -d '.…'); a="$1"
    [ ${#e} -ge 16 ] || { echo "expected-hash too short to be evidence: $2"; return 2; }
    case "$a" in "$e"*) return 0 ;; *) return 1 ;; esac
}
while read -r key val extra; do
  [ -z "${key:-}" ] && continue; case "$key" in \#*) continue ;; esac
  case "$key" in
    RUNTIME_STAMPS)
        a=$(ls apks/2-displayxr-runtime/*.apk 2>/dev/null | head -1)
        got=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$a" 2>/dev/null | grep -A1 CNSDK_LOADER_ | grep -oE 'value\([^)]*\)="[^"]*"' | sed -E 's/.*="([^"]*)"/\1/' | tr '\n' ' ')
        [ "$got" = "$val $extra " ] && ok "runtime stamps $val / $extra" || bad "runtime stamps" "got [$got] want [$val $extra]" ;;
    PLUGIN_EMBEDS)
        a=$(ls apks/2-displayxr-runtime/*.apk 2>/dev/null | head -1); d=$(mktemp -d)
        unzip -q -o -j "$a" 'lib/arm64-v8a/libdxrp050_leia_cnsdk.so' -d "$d" 2>/dev/null
        strings -a "$d/libdxrp050_leia_cnsdk.so" 2>/dev/null | grep -q -- "$val" && ok "plug-in embeds $val" || bad "plug-in embeds $val" "string absent"; rm -rf "$d" ;;
    SERVICE_IMPL)
        a=$(ls apks/1-cnsdk-services/device-service-release-*.apk 2>/dev/null | head -1); d=$(mktemp -d)
        unzip -q -o -j "$a" 'lib/arm64-v8a/libleiaCore-impl.so' -d "$d" 2>/dev/null
        got=$(shasum -a 256 "$d/libleiaCore-impl.so" 2>/dev/null | cut -d' ' -f1)
        if hasheq "${got:-}" "$val"; then ok "device-service core sha256 (prefix $val)"; else bad "device-service core sha256" "got ${got:-none}, want prefix $val"; fi; rm -rf "$d" ;;
    *)  f=$(ls $key 2>/dev/null | head -1)
        if [ -z "$f" ]; then bad "$key" "no file matches"; else
          got=$(shasum -a 256 "$f" | cut -d' ' -f1)
          if hasheq "$got" "$val"; then ok "$(basename "$f")"; else bad "$(basename "$f")" "sha256 $got"; fi; fi ;;
  esac
done < "$EXP"
echo; [ "$fail" -eq 0 ] && echo "ARTIFACTS OK — safe to install" || { echo "$fail problem(s) — do NOT install"; exit 1; }
