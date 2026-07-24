#!/usr/bin/env bash
# Build the DisplayXR Linux meta-bundle (displayxr-runtime #781 Phase 3).
#
# Reads versions.json, sources the per-component asset table from
# displayxr-runtime at the pinned runtime tag (same table the macOS/Windows
# bundles use), downloads each component's Linux .deb (skipping components that
# don't ship one yet), and packs the .debs with install.sh/uninstall.sh into a
# self-contained tarball.
#
# Output: _out/DisplayXRBundle-<version>-linux-amd64.tar.gz
#
# The bundle chains the DisplayXR runtime + Leia SR plug-in (+ any demo that
# ships a Linux .deb). The COMMERCIAL Leia SR runtime (leiasr-runtime) is NOT
# bundled — it ships separately from Leia; install.sh detects it and guides the
# user. Demos are included automatically once their repo attaches a
# `*_amd64.deb` release asset and components.sh gains their DEB_LINUX glob.
#
#   ./scripts/build-bundle-linux.sh --version vX.Y.Z [--keep-stage] [--core-only]
#
# Prerequisites: gh (authenticated), jq, tar.

set -euo pipefail

VERSION=""
KEEP_STAGE=0
CORE_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)    VERSION="${2#v}"; shift 2 ;;
        --keep-stage) KEEP_STAGE=1; shift ;;
        --core-only)  CORE_ONLY=1; shift ;;   # runtime + leia only, skip demos
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown arg '$1'" >&2; exit 1 ;;
    esac
done
[[ -n "$VERSION" ]] || { echo "ERROR: --version vX.Y.Z is required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO_ROOT/_stage-linux"
OUT_DIR="$REPO_ROOT/_out"
rm -rf "$STAGE"; mkdir -p "$STAGE" "$OUT_DIR"

# Component table pinned to the runtime tag (gives RUNTIME_TAG + component_field).
export REPO_ROOT
# shellcheck source=scripts/lib/fetch-components.sh
source "$REPO_ROOT/scripts/lib/fetch-components.sh"

tag_for() {  # component name -> versions.json pin (runtime already in RUNTIME_TAG)
    local name="$1"
    if [[ "$name" == "runtime" ]]; then printf '%s' "$RUNTIME_TAG"; return; fi
    local key; key="$(component_field "$name" PIN_KEY)"; [[ -n "$key" ]] || key="$name"
    jq -r --arg k "$key" '.[$k] // ""' "$REPO_ROOT/versions.json"
}

# Core first, then demos (order = install/UI order). Demos come from
# DEMO_COMPONENTS in the runtime's components.sh, so the set stays in lockstep.
COMPONENTS=(runtime leia_plugin)
if [[ "$CORE_ONLY" -eq 0 ]]; then
    # shellcheck disable=SC2206
    COMPONENTS+=(${DEMO_COMPONENTS:-})
fi

BUNDLE="$STAGE/DisplayXRBundle-$VERSION-linux-amd64"
DEBS="$BUNDLE/debs"
mkdir -p "$DEBS"

echo "==> DisplayXR Linux bundle v$VERSION (runtime $RUNTIME_TAG)"
GOT=0 SKIPPED=""
for name in "${COMPONENTS[@]}"; do
    glob="$(component_field "$name" DEB_LINUX)"
    if [[ -z "$glob" ]]; then
        SKIPPED+=" $name(no-deb-field)"; continue
    fi
    repo="$(component_field "$name" REPO)"
    tag="$(tag_for "$name")"
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        SKIPPED+=" $name(no-pin)"; continue
    fi
    echo "==> [$name @ $tag] downloading $glob from $repo"
    if gh release download "$tag" --repo "$repo" --pattern "$glob" --dir "$DEBS" 2>/dev/null; then
        GOT=$((GOT+1))
    else
        # A component with a DEB_LINUX glob but no released asset yet (e.g. a
        # demo whose CI doesn't attach a .deb): log and keep going, don't fail
        # the whole bundle.
        echo "    (no matching Linux .deb asset on $tag — skipping)"
        SKIPPED+=" $name(no-asset)"
    fi
done

# runtime + leia are the non-negotiable core.
for req in "displayxr-runtime_" "displayxr-leia-sr_"; do
    if ! ls "$DEBS"/${req}*_amd64.deb >/dev/null 2>&1; then
        echo "ERROR: required core .deb '${req}*_amd64.deb' missing — bundle is incomplete." >&2
        echo "       (Has the component published its Linux .deb release asset? See #781.)" >&2
        exit 1
    fi
done

# Pack: debs/ + installer scripts + LICENSE + README.
cp "$REPO_ROOT/installer/linux/install.sh" "$REPO_ROOT/installer/linux/uninstall.sh" "$BUNDLE/"
chmod +x "$BUNDLE/install.sh" "$BUNDLE/uninstall.sh"
[[ -f "$REPO_ROOT/LICENSE" ]] && cp "$REPO_ROOT/LICENSE" "$BUNDLE/"
cat > "$BUNDLE/README.txt" <<EOF
DisplayXR for Linux — bundle v$VERSION (Debian/Ubuntu amd64)

Install:    sudo ./install.sh
Uninstall:  sudo ./uninstall.sh   (--purge to also remove config)

Installs the DisplayXR OpenXR runtime + Leia SR display-processor plug-in from
the bundled .debs. No environment variables needed. Without the (separately
provided) Leia SR runtime, apps run on the built-in sim-display fallback; add
the Leia SR runtime and the Leia display processor claims the display
automatically.

Bundled packages:
$(cd "$DEBS" && for d in *.deb; do echo "  - $d"; done)
EOF

OUT="$OUT_DIR/DisplayXRBundle-$VERSION-linux-amd64.tar.gz"
tar -C "$STAGE" -czf "$OUT" "DisplayXRBundle-$VERSION-linux-amd64"

echo ""
echo "==> $OUT"
echo "    components bundled: $GOT   skipped:${SKIPPED:- none}"
tar -tzf "$OUT" | sed 's/^/    /'
[[ "$KEEP_STAGE" -eq 0 ]] && rm -rf "$STAGE"
echo "==> Done."
