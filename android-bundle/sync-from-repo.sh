#!/usr/bin/env bash
# Pull the harness from this repo into a local tablet-bundle folder.
#
# Canonical source : DisplayXR/displayxr-installer  android-bundle/
# Typical consumer : a dated bundle folder holding apks/, expected/, MANIFEST.md
#
#   ./sync-from-repo.sh            copy repo -> bundle folder (refuses on dirty provenance)
#   ./sync-from-repo.sh --check    report drift only, write nothing, exit 1 if drifted
#
# Copy this file into the bundle folder once; from then on it keeps itself and
# scripts/ current. Override the checkout with DXR_INSTALLER_REPO.
#
# WHY A COPY AND NOT A SYMLINK -- do not "simplify" this back to a symlink.
# The dated zips are the deliverable, and macOS "Compress" in Finder shells out
# to ditto, which stores a symlinked directory as a ~7-byte link rather than
# following it. The zip then contains a `scripts` entry of 7 bytes and no
# scripts, and nothing anywhere reports an error -- a tester just finds the
# harness missing. Only `zip -r` follows the link. Real files on disk are the
# only form that survives every way this folder gets packed, so this script
# keeps them real and uses --check to keep them honest.
set -euo pipefail

REPO="${DXR_INSTALLER_REPO:-$HOME/Documents/GitHub/displayxr-installer}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$REPO/android-bundle/scripts"
SELF_SRC="$REPO/android-bundle/sync-from-repo.sh"
DST="$HERE/scripts"
STAMP="$HERE/SCRIPTS-PROVENANCE.txt"
MODE="${1:-sync}"

die() { echo "  $*" >&2; exit 1; }

[ -d "$REPO/.git" ] || die "no displayxr-installer checkout at $REPO
   git clone https://github.com/DisplayXR/displayxr-installer.git \"$REPO\"
   (or set DXR_INSTALLER_REPO to an existing one)"
[ -d "$SRC" ] || die "$REPO has no android-bundle/scripts -- checkout predates the harness import; git -C \"$REPO\" pull"

# Running from inside the repo itself would sync the source onto itself.
[ "$HERE" = "$REPO/android-bundle" ] && die "this is the canonical copy -- run it from the bundle folder, not from the checkout"

# rsync --delete below is destructive if aimed wrong. Only ever fire it inside
# something that actually looks like the tablet bundle.
{ [ -e "$HERE/MANIFEST.md" ] || [ -d "$HERE/apks" ]; } \
  || die "$HERE does not look like the tablet bundle (no MANIFEST.md, no apks/) -- refusing to --delete into it"

git -C "$REPO" fetch -q origin 2>/dev/null || echo "  note: could not fetch (offline?) -- comparing against the local checkout as-is"

# Dirt anywhere in android-bundle/ means the bytes we are about to ship are not
# the bytes anyone can review. Dirt elsewhere in the repo cannot reach the
# harness, so it is worth saying out loud but not worth blocking on.
if [ -n "$(git -C "$REPO" status --porcelain -- android-bundle)" ]; then
  echo "  android-bundle/ has uncommitted changes in $REPO:" >&2
  git -C "$REPO" status --short -- android-bundle | sed 's/^/    /' >&2
  die "refusing to sync unreviewable bytes -- commit, stash, or discard them first"
fi
[ -n "$(git -C "$REPO" status --porcelain)" ] \
  && echo "  note: the checkout is dirty outside android-bundle/ -- does not affect the harness, continuing"

BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
SHA="$(git -C "$REPO" rev-parse --short HEAD)"
SUBJ="$(git -C "$REPO" log -1 --pretty=%s)"
if git -C "$REPO" rev-parse --verify -q origin/main >/dev/null; then
  BEHIND="$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  [ "${BEHIND:-0}" -gt 0 ] && echo "  note: checkout is $BEHIND commit(s) behind origin/main -- 'git -C \"$REPO\" pull' for the newest harness"
fi

SELF_DRIFTED=0
cmp -s "$SELF_SRC" "${BASH_SOURCE[0]}" || SELF_DRIFTED=1

if [ "$MODE" = "--check" ]; then
  RC=0
  if ! diff -rq "$SRC" "$DST" >/dev/null 2>&1; then
    echo "  DRIFT in scripts/ vs $REPO @ $SHA:"
    diff -rq "$SRC" "$DST" 2>&1 | sed 's/^/    /'
    RC=1
  fi
  [ "$SELF_DRIFTED" -eq 1 ] && { echo "  DRIFT: sync-from-repo.sh itself differs from the repo copy"; RC=1; }
  if [ "$RC" -eq 0 ]; then
    echo "  in sync with $REPO @ $SHA ($BRANCH)"
  else
    echo "  run ./sync-from-repo.sh to take the repo copy, or open a PR if the local edit is the good one"
  fi
  exit "$RC"
fi

rsync -a --delete "$SRC/" "$DST/"
chmod +x "$DST"/*.sh

FAIL=0
for f in "$DST"/*.sh; do bash -n "$f" || { echo "  PARSE FAIL $f" >&2; FAIL=1; }; done
[ "$FAIL" -eq 0 ] || die "synced scripts do not parse -- do not ship this bundle"

{
  echo "scripts/ is a synced copy -- do not edit it here, edit the repo and re-sync."
  echo
  echo "source : DisplayXR/displayxr-installer  android-bundle/scripts/"
  echo "commit : $SHA  ($BRANCH)  $SUBJ"
  echo "synced : $(date -u +%Y-%m-%dT%H:%M:%SZ)  by sync-from-repo.sh"
  echo "files  : $(ls -1 "$DST" | wc -l | tr -d ' ')"
} > "$STAMP"

echo "  scripts/ <- $REPO @ $SHA ($BRANCH)"
echo "  $(ls -1 "$DST" | wc -l | tr -d ' ') files, all parse. Provenance: $(basename "$STAMP")"

# Update ourselves LAST, and by atomic rename: the running shell keeps reading
# the old inode, so replacing the directory entry mid-run is safe, whereas
# writing into this file in place would make bash resume at a garbage offset.
if [ "$SELF_DRIFTED" -eq 1 ]; then
  T="$(mktemp "$HERE/.sync-from-repo.XXXXXX")"
  cat "$SELF_SRC" > "$T" && chmod +x "$T" && mv -f "$T" "${BASH_SOURCE[0]}"
  echo "  sync-from-repo.sh updated itself from the repo -- re-run it to use the new version"
fi
