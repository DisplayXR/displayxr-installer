#!/usr/bin/env bash
# Put the shared-pad tools on PATH, so the correct tool is the one at hand.
#
#   ./scripts/link-pad-tools.sh            # link into ~/.claude/bin
#   ./scripts/link-pad-tools.sh --check    # report what is linked, change nothing
#   ./scripts/link-pad-tools.sh --unlink   # remove the links
#
# WHY. On 2026-09-12 a session destroyed another session's live pad claim with a plain
# `echo > pad.lock`. It had not read the lock first, and the reason was not carelessness:
# these scripts live in this repo while the work happens in a sibling checkout, so
# pad-lock.sh was not on its PATH and it improvised. Atomic claiming and tolerant readers
# only help if the tool is the thing people actually run -- so make it reachable.
#
# Same shape as displayxr-runtime's scripts/link-dxr-skills.sh: the bytes stay git-tracked
# here and the symlink makes them reachable, so edit the file in the repo, never the link.
#
# ~/.claude/bin already holds box-level private helpers. This only ADDS symlinks into it and
# never reads or copies anything out, so nothing private can leak into this public repo.
set -u

DEST="${PAD_TOOLS_BIN:-$HOME/.claude/bin}"
TOOLS="pad-lock.sh pad-run.sh"

# Resolve this script's own directory through symlinks, so --unlink still works when invoked
# through a link it created.
_self="$0"
while [ -L "$_self" ]; do
    _link=$(readlink "$_self")
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(dirname -- "$_self")/$_link" ;;
    esac
done
SRC=$(CDPATH= cd -- "$(dirname -- "$_self")" && pwd)

case "${1:-link}" in
  --check|check)
    rc=0
    for t in $TOOLS; do
        l="$DEST/$t"
        if [ -L "$l" ]; then
            tgt=$(readlink "$l")
            if [ "$tgt" = "$SRC/$t" ]; then echo "  linked   $l -> $tgt"
            else echo "  MISMATCH $l -> $tgt (expected $SRC/$t)"; rc=1; fi
        elif [ -e "$l" ]; then echo "  NOT A LINK $l is a real file -- refusing to touch it"; rc=1
        else echo "  missing  $l"; rc=1; fi
    done
    case ":$PATH:" in *":$DEST:"*) echo "  $DEST is on PATH" ;;
                      *) echo "  NOTE: $DEST is not on your PATH -- add it, or the links buy nothing"; rc=1 ;; esac
    exit $rc ;;
  --unlink|unlink)
    for t in $TOOLS; do
        l="$DEST/$t"
        if [ -L "$l" ]; then rm -f "$l"; echo "  removed  $l"
        elif [ -e "$l" ]; then echo "  SKIPPED  $l is a real file, not our link"
        else echo "  absent   $l"; fi
    done
    exit 0 ;;
  --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
  link) ;;
  *) echo "usage: $0 [--check|--unlink]" >&2; exit 2 ;;
esac

mkdir -p "$DEST"
for t in $TOOLS; do
    [ -f "$SRC/$t" ] || { echo "  ERROR: $SRC/$t not found" >&2; exit 1; }
    l="$DEST/$t"
    # Never clobber a real file someone put there deliberately; replacing our own link is fine.
    if [ -e "$l" ] && [ ! -L "$l" ]; then
        echo "  REFUSING: $l exists and is not a symlink." >&2
        exit 1
    fi
    ln -sfn "$SRC/$t" "$l"
    echo "  linked   $l -> $SRC/$t"
done
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo
     echo "  $DEST is not on your PATH. Add it, or the links buy nothing:"
     echo "    export PATH=\"\$PATH:$DEST\"" ;;
esac
