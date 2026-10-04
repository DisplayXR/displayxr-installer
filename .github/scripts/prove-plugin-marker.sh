#!/usr/bin/env bash
# Prove that `PLUGIN_EMBEDS <pin>` is a REAL discriminator for the plug-in build inside a
# vendor runtime APK, instead of trusting a hand-carried marker that has to be re-measured
# on every plug-in bump.
#
#   .github/scripts/prove-plugin-marker.sh <vendor-runtime-apk> <plugin-pin>
#   e.g. .github/scripts/prove-plugin-marker.sh apks/2-displayxr-runtime/*.apk v2.9.0
#
# Needs: gh (authenticated; displayxr-leia-plugin is public, any token works), unzip, tar,
# strings, shasum, sort -V. PREV_PLUGIN=<tag> overrides the previous-release lookup (only
# for proving this script FAILS where it must).
#
# What it asserts — all three, or exit 1:
#   1. IDENTITY  the APK's lib/arm64-v8a/libdxrp050_leia_cnsdk.so is byte-identical to the
#                .so in the pinned plug-in release's Android tarball. (The runtime's
#                build-android.yml copies that file verbatim; measured equal for 2.21.11 /
#                plug-in 2.7.6 and 2.25.3 / 2.9.0.)
#   2. PRESENT   the marker <pin> is in that .so (`strings -a | grep -c -F` >= 1).
#   3. ABSENT    the marker is NOT in the .so of the plug-in release immediately before
#                <pin> (semver order, canonical vX.Y.Z, no drafts/pre-releases) — tested with
#                the SAME expression check-artifacts.sh uses (`grep -q -- <val>`, i.e. a
#                regex, which can only match MORE than -F, so absence here is the strict
#                direction). This is the README's "a marker must be absent from the previous
#                build" rule, run on every bundle instead of once by hand.
set -euo pipefail

APK="${1:?usage: prove-plugin-marker.sh <vendor-runtime-apk> <plugin-pin>}"
PIN="${2:?usage: prove-plugin-marker.sh <vendor-runtime-apk> <plugin-pin>}"
REPO=DisplayXR/displayxr-leia-plugin
SO=libdxrp050_leia_cnsdk.so
case "$PIN" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "::error::plug-in pin '$PIN' is not vX.Y.Z"; exit 1 ;; esac

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; bad() { echo "::error::$*"; fail=1; }

# The plug-in .so from a release's Android tarball.
plugin_so() {  # plugin_so <tag> <dir>  -> prints path
    mkdir -p "$2"
    gh release download "$1" -R "$REPO" -D "$2" --clobber \
       -p 'displayxr-leia-cnsdk-*-android-arm64-v8a.tar.gz' >/dev/null \
      || { echo "::error::$REPO@$1 has no Android plug-in tarball" >&2; return 1; }
    tar -xzf "$2"/*.tar.gz -C "$2"
    f=$(find "$2" -name "$SO" | head -1)
    [ -n "$f" ] || { echo "::error::$REPO@$1 tarball has no $SO" >&2; return 1; }
    echo "$f"
}
count() { strings -a "$1" | grep -c -F -- "$2" || true; }

# The runtime's embedded plug-in.
unzip -q -o -j "$APK" "lib/arm64-v8a/$SO" -d "$T/rt" \
  || { echo "::error::$APK carries no lib/arm64-v8a/$SO"; exit 1; }
RT_SO="$T/rt/$SO"

# Previous plug-in release, by semver.
if [ -n "${PREV_PLUGIN:-}" ]; then
    PREV="$PREV_PLUGIN"
else
    PREV=$(gh release list -R "$REPO" --limit 300 --exclude-drafts --exclude-pre-releases \
             --json tagName --jq '.[].tagName' \
           | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
           | { cat; echo "$PIN"; } | sort -uV | grep -B1 -x -F -- "$PIN" | head -1)
    [ -n "$PREV" ] && [ "$PREV" != "$PIN" ] || { echo "::error::no plug-in release precedes $PIN in $REPO"; exit 1; }
fi

NEW_SO=$(plugin_so "$PIN" "$T/new")
OLD_SO=$(plugin_so "$PREV" "$T/old")

rt_sha=$(shasum -a 256 "$RT_SO" | cut -d' ' -f1)
new_sha=$(shasum -a 256 "$NEW_SO" | cut -d' ' -f1)
old_sha=$(shasum -a 256 "$OLD_SO" | cut -d' ' -f1)

# 1. identity
[ "$rt_sha" = "$new_sha" ] || bad "the runtime APK's $SO ($rt_sha) is NOT the $PIN release's ($new_sha) — this runtime was built against a different plug-in than versions.json pins"
[ "$new_sha" != "$old_sha" ] || bad "$PIN and $PREV ship byte-identical $SO ($new_sha) — nothing can discriminate them"
# 2. present
n_rt=$(count "$RT_SO" "$PIN")
[ "$n_rt" -ge 1 ] || bad "marker $PIN is absent from the runtime APK's $SO"
# 3. absent from the previous build, by the gate's own expression. NOT `strings | grep -q`:
# under pipefail, grep -q's early exit SIGPIPEs strings, the pipeline reports failure, and
# a marker that IS present reads as absent — the one direction this check exists to catch.
strings -a "$OLD_SO" > "$T/old.strings"
if grep -q -- "$PIN" "$T/old.strings"; then
    bad "marker $PIN is ALSO in the previous plug-in $PREV — it does not discriminate, and the gate would false-pass a $PREV build"
fi

{
  echo "### Plug-in version marker proof"
  echo
  echo "| | $PREV (previous) | runtime APK | $PIN (pinned) |"
  echo "|---|---|---|---|"
  echo "| \`$SO\` sha256 | \`${old_sha:0:16}\` | \`${rt_sha:0:16}\` | \`${new_sha:0:16}\` |"
  for m in "$PREV" "$PIN" "${@:3}"; do
    echo "| \`strings -a \| grep -c -F -- $m\` | $(count "$OLD_SO" "$m") | $(count "$RT_SO" "$m") | $(count "$NEW_SO" "$m") |"
  done
  echo
  [ "$fail" -eq 0 ] && echo "PROVEN: \`PLUGIN_EMBEDS $PIN\` is in the runtime's plug-in, absent from $PREV, and the plug-in is byte-identical to the $PIN release." \
                    || echo "**FAILED** — see the errors above."
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

exit "$fail"
