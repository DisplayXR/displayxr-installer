#!/usr/bin/env bash
# Lay out the vendor display services for the services host (updates.displayxr.org)
# and write the manifest the Android installer reads.
#
#   make-services-manifest.sh --tag v0.10.69 --apks <dir> --licenses <dir> --out <dir>
#
# <apks>     the two APKs exactly as the CNSDK release publishes them
#            (device-service-release-*.apk, headTracking-service-release-*.apk)
# <licenses> LICENSE.txt, LICENSE-3RD-PARTY.txt, ZMQ.AUTHORS.txt, SIMDJSON.AUTHORS.txt
#            from the CNSDK release zip — the services statically link libzmq (modified
#            LGPLv3), Eigen (MPL-2.0) and Apache-2.0 components, so the notices must travel
#            with the binaries wherever they are published.
# <out>      receives manifest.json, device-service.apk, headtracking-service.apk and the
#            licence files: the exact tree served at /services/cnsdk/<tag>/.
#
# Every value in the manifest is READ from the files (aapt2, apksigner, sha256), never
# typed: a hand-typed digest in this repo has already false-passed once. And it REFUSES,
# rather than publishes, anything the installer app would refuse on the tablet:
#   - a package that is not one of the two in service-signers.tsv, or a missing one;
#   - a versionName that is not the tag;
#   - an APK that apksigner does not verify, that has more than one signer, or whose
#     certificate is not the pinned one;
#   - the two services disagreeing on the CNSDK build string (com.leia.cnsdk.FULL_VERSION);
#   - a missing licence notice.
#
# Tools: aapt2 + apksigner (Android build-tools; $AAPT2 / $APKSIGNER, else the newest under
# $ANDROID_HOME or ~/Library/Android/sdk), python3, shasum or sha256sum.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
SIGNERS="$here/service-signers.tsv"

TAG="" APKS="" LICS="" OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG=$2; shift 2 ;;
    --apks) APKS=$2; shift 2 ;;
    --licenses) LICS=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$TAG" ] && [ -n "$APKS" ] && [ -n "$LICS" ] && [ -n "$OUT" ] || {
  echo "usage: $0 --tag vX.Y.Z --apks <dir> --licenses <dir> --out <dir>" >&2; exit 2; }
case "$TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) echo "::error::tag '$TAG' is not vX.Y.Z" >&2; exit 2 ;; esac
VER=${TAG#v}

die() { echo "::error::$*" >&2; exit 1; }

find_tool() {  # find_tool <name> -> newest build-tools copy
  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" /usr/local/lib/android/sdk; do
    [ -n "$sdk" ] || continue
    local t
    t=$(ls -d "$sdk"/build-tools/*/"$1" 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$t" ] && { echo "$t"; return 0; }
  done
  command -v "$1" || true
}
AAPT2=${AAPT2:-$(find_tool aapt2)}
APKSIGNER=${APKSIGNER:-$(find_tool apksigner)}
[ -x "$AAPT2" ] || die "aapt2 not found (set AAPT2)"
[ -x "$APKSIGNER" ] || die "apksigner not found (set APKSIGNER)"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
size_of() { wc -c < "$1" | tr -d ' '; }

shopt -s nullglob
apks=("$APKS"/*.apk)
[ "${#apks[@]}" -eq 2 ] || die "expected exactly 2 APKs in $APKS, found ${#apks[@]}"

rm -rf "$OUT"; mkdir -p "$OUT"
rows="$OUT/.rows.tsv"; : > "$rows"
builds=""

while IFS=$'\t' read -r role pkg pinned published; do
  case "$role" in ''|\#*) continue ;; esac
  match=""
  for a in "${apks[@]}"; do
    p=$("$AAPT2" dump badging "$a" 2>/dev/null | awk -F"'" '/^package: name=/{print $2; exit}' || true)
    [ "$p" = "$pkg" ] && { [ -z "$match" ] || die "two APKs are package $pkg"; match=$a; }
  done
  [ -n "$match" ] || die "no APK in $APKS is package $pkg ($role)"

  badge=$("$AAPT2" dump badging "$match" 2>/dev/null | grep '^package: name=' || true)
  vcode=$(printf '%s' "$badge" | sed -nE "s/.* versionCode='([0-9]+)'.*/\1/p")
  vname=$(printf '%s' "$badge" | sed -nE "s/.* versionName='([^']*)'.*/\1/p")
  [ -n "$vcode" ] || die "$match: no versionCode"
  [ "$vname" = "$VER" ] || die "$match: versionName is '$vname', but the release is $TAG"

  build=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$match" 2>/dev/null \
          | grep -A1 'com.leia.cnsdk.FULL_VERSION' | grep -oE 'value\([^)]*\)="[^"]*"' \
          | sed -E 's/.*="([^"]*)"/\1/' | head -1 || true)
  [ -n "$build" ] || die "$match: no com.leia.cnsdk.FULL_VERSION meta-data"
  case "$build" in "$VER"|"$VER"+*) ;; *) die "$match: CNSDK build '$build' is not release $VER" ;; esac
  builds="$builds $build"

  certs=$("$APKSIGNER" verify --print-certs "$match" 2>&1) || die "$match: apksigner does not verify it:
$certs"
  n=$(printf '%s\n' "$certs" | grep -c 'certificate SHA-256 digest' || true)
  [ "$n" = 1 ] || die "$match: expected exactly one signer, apksigner reports $n"
  signer=$(printf '%s\n' "$certs" | sed -nE 's/.*certificate SHA-256 digest: ([0-9a-f]{64}).*/\1/p')
  [ "$signer" = "$pinned" ] || die "$match: signed by $signer, not the pinned $pinned ($role)"

  cp "$match" "$OUT/$published"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pkg" "$published" "$(basename "$match")" \
    "$vname" "$vcode" "$(sha256 "$OUT/$published")" "$(size_of "$OUT/$published")" "$signer" >> "$rows"
  echo "  $role: $pkg $vname ($vcode)  signer ${signer:0:16}…  -> $published"
done < "$SIGNERS"

[ "$(wc -l < "$rows" | tr -d ' ')" = 2 ] || die "manifest would list $(wc -l < "$rows") services, expected 2"
set -- $builds
[ "$1" = "$2" ] || die "the two services disagree on the CNSDK build: $1 vs $2"
BUILD=$1

lrows="$OUT/.licenses.tsv"; : > "$lrows"
for l in LICENSE.txt LICENSE-3RD-PARTY.txt ZMQ.AUTHORS.txt SIMDJSON.AUTHORS.txt; do
  [ -s "$LICS/$l" ] || die "$l missing from $LICS — the services are redistributed LGPL/MPL/Apache binaries and must not be published without their notices"
  cp "$LICS/$l" "$OUT/$l"
  printf '%s\t%s\t%s\n' "$l" "$(sha256 "$OUT/$l")" "$(size_of "$OUT/$l")" >> "$lrows"
done

TAG="$TAG" BUILD="$BUILD" ROWS="$rows" LROWS="$lrows" OUTF="$OUT/manifest.json" python3 - <<'PY'
import json, os
def rows(p):
    return [l.rstrip("\n").split("\t") for l in open(p) if l.strip()]
m = {
    "schema": 1,
    "kind": "displayxr-display-services",
    "cnsdk_tag": os.environ["TAG"],
    "cnsdk_build": os.environ["BUILD"],
    "note": "Vendor display services for 3D tablets, installed by the DisplayXR Android "
            "installer. Paths are relative to this file. Install in the order listed.",
    "services": [
        {"package": r[0], "file": r[1], "source_file": r[2], "versionName": r[3],
         "versionCode": int(r[4]), "sha256": r[5], "size": int(r[6]), "signer_sha256": r[7]}
        for r in rows(os.environ["ROWS"])
    ],
    "licenses": [
        {"file": r[0], "sha256": r[1], "size": int(r[2])} for r in rows(os.environ["LROWS"])
    ],
}
with open(os.environ["OUTF"], "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
PY
rm -f "$rows" "$lrows"
echo "OK: $OUT/manifest.json  (CNSDK $TAG, build $BUILD)"
ls -l "$OUT"
