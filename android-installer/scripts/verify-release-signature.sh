#!/usr/bin/env bash
# verify-release-signature.sh <apk> — is this the DisplayXR Installer, signed with THE release key?
#
# Exit 0 only when ALL of these hold, judged from the APK's bytes by apksigner:
#   - the signature verifies;
#   - exactly one signer, and its certificate SHA-256 equals the pin in
#     android-installer/release-signing-cert.sha256;
#   - that signer is verified from the APK Signing Block (v2, or v3 after a key rotation),
#     not from a JAR (v1) signature alone. apksigner checks only the schemes the APK's minSdk
#     range needs (31+: v2/v3), so "v1: false" in its output is not a statement about v1 and
#     is not asserted here;
#   - the package is com.displayxr.installer (when aapt2 is available).
# Exit 1 otherwise, with the reason. A debug-signed or foreign-key APK FAILS: this is
# the gate that keeps an installer tablets cannot update in place off a release.
#
# apksigner / aapt2: $APKSIGNER / $AAPT2, else the newest under
# $ANDROID_HOME (or $ANDROID_SDK_ROOT, or ~/Library/Android/sdk) /build-tools.
set -euo pipefail

apk=${1:?usage: verify-release-signature.sh <apk>}
here=$(cd "$(dirname "$0")/.." && pwd)
pin_file=${RELEASE_CERT_PIN_FILE:-$here/release-signing-cert.sha256}

die() { echo "::error::verify-release-signature: $*" >&2; exit 1; }

[ -f "$apk" ] || die "no such file: $apk"
pin=$(grep -v '^[[:space:]]*#' "$pin_file" | tr -d '[:space:]' | tr 'A-F' 'a-f')
[[ "$pin" =~ ^[0-9a-f]{64}$ ]] || die "$pin_file does not hold exactly one SHA-256 (got '$pin')"

sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
bt=$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)
apksigner=${APKSIGNER:-$bt/apksigner}
aapt2=${AAPT2:-$bt/aapt2}
[ -x "$apksigner" ] || die "apksigner not found (looked at '$apksigner'); set APKSIGNER or ANDROID_HOME"

out=$("$apksigner" verify --verbose --print-certs "$apk" 2>&1) || { echo "$out" >&2; die "$(basename "$apk"): apksigner verify FAILED"; }

# Two output formats exist: build-tools <= 34 print "Signer #1 certificate SHA-256 digest: …",
# newer ones print one block per scheme, "V2 Signer: certificate SHA-256 digest: …". Count
# signers from "Number of signers", and collect every signer-certificate digest in either
# format (not "public key" digests, not a Source Stamp's) — all of them must be the pin.
signers=$(sed -nE 's/^Number of signers: *([0-9]+).*/\1/p' <<<"$out" | head -1)
[ "$signers" = 1 ] || { echo "$out" >&2; die "$(basename "$apk"): expected exactly 1 signer, found '${signers:-none}'"; }
digests=$(grep -v '^Source Stamp' <<<"$out" \
  | sed -nE 's/^(Signer #[0-9]+|V[0-9.]+ Signer( #[0-9]+)?):? certificate SHA-256 digest: *([0-9a-fA-F]{64}).*/\3/p' \
  | tr 'A-F' 'a-f' | sort -u)
[ -n "$digests" ] || { echo "$out" >&2; die "$(basename "$apk"): apksigner printed no signer certificate digest (unknown output format?)"; }
dn=$(grep -v '^Source Stamp' <<<"$out" | sed -nE 's/^(Signer #[0-9]+|V[0-9.]+ Signer( #[0-9]+)?):? certificate DN: *//p' | head -1)
got=$(tr '\n' ' ' <<<"$digests" | sed 's/ $//')
if [ "$got" != "$pin" ]; then
  die "$(basename "$apk") is signed by '$dn' ($got), NOT the DisplayXR Installer release key ($pin). Tablets could not update to it in place. Refusing."
fi

grep -qE '^Verified using v(2|3|3\.1) scheme \(APK Signature Scheme v[0-9.]+\): true' <<<"$out" \
  || { echo "$out" >&2; die "$(basename "$apk"): no v2/v3 (APK Signing Block) signature"; }

if [ -x "$aapt2" ]; then
  pkg=$("$aapt2" dump badging "$apk" 2>/dev/null | sed -nE "s/^package: name='([^']+)'.*/\1/p")
  [ "$pkg" = com.displayxr.installer ] || die "$(basename "$apk"): package is '$pkg', not com.displayxr.installer"
  ver=$("$aapt2" dump badging "$apk" 2>/dev/null | sed -nE "s/^package: .*versionCode='([0-9]+)'.*versionName='([^']*)'.*/\2 (versionCode \1)/p")
fi
echo "OK: $(basename "$apk") ${ver:+$ver }is signed by the DisplayXR Installer release key ($dn, $got)."
