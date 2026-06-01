#!/usr/bin/env bash
# Build the DisplayXR end-user meta-installer .pkg for macOS.
#
# Reads versions.json, fetches the per-component asset table from
# displayxr-runtime at the pinned runtime tag, downloads each
# component's macOS .pkg (skipping components that don't ship one yet),
# extracts the embedded component .pkg(s) from the runtime's
# productbuild distribution, and re-wraps with our own Distribution.xml.
#
# Output: _out/DisplayXRBundle-<version>.pkg

set -euo pipefail

VERSION=""
KEEP_STAGE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2#v}"  # strip leading 'v' for productbuild --version
            shift 2
            ;;
        --keep-stage)
            KEEP_STAGE=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 --version vX.Y.Z [--keep-stage]

Builds _out/DisplayXRBundle-X.Y.Z.pkg from the per-component .pkg
artifacts pinned in versions.json.

Options:
  --version vX.Y.Z   Bundle release version (required).
  --keep-stage       Keep _stage/ around after build for debugging.

Prerequisites: gh (authenticated), jq, productbuild, pkgutil.
EOF
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg '$1'" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "ERROR: --version is required (e.g. --version v0.1.0)" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$REPO_ROOT/_stage"
OUT_DIR="$REPO_ROOT/_out"

# Clean stage; preserve _out so prior builds remain inspectable.
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT_DIR"

# 1. Source the component table from the pinned runtime tag.
export REPO_ROOT
# shellcheck source=scripts/lib/fetch-components.sh
source "$REPO_ROOT/scripts/lib/fetch-components.sh"

SHELL_TAG="$(jq -r '.shell' "$REPO_ROOT/versions.json")"
LEIA_TAG="$(jq -r '.leia_plugin' "$REPO_ROOT/versions.json")"
MCP_TAG="$(jq -r '.mcp_tools' "$REPO_ROOT/versions.json")"
GAUSS_TAG="$(jq -r '.gauss_demo' "$REPO_ROOT/versions.json")"

cat <<EOF
==> DisplayXR bundle build
    bundle:      v$VERSION
    runtime:     $RUNTIME_TAG
    shell:       $SHELL_TAG
    leia_plugin: $LEIA_TAG
    mcp_tools:   $MCP_TAG
    gauss_demo:  $GAUSS_TAG
EOF

# 2. Walk components; download any with a non-empty macOS asset glob and
#    extract embedded child .pkg(s) into $STAGE/components/.
COMPONENTS_DIR="$STAGE/components"
mkdir -p "$COMPONENTS_DIR"

CHOICE_LINES=""
CHOICES=""
PKG_REFS=""

process_component() {
    local name="$1"
    local tag="$2"
    local repo glob sub pkg_file expanded

    repo="$(component_field "$name" REPO)"
    glob="$(component_field "$name" PKG_MACOS)"
    if [[ -z "$glob" ]]; then
        echo "==> [$name @ $tag] no macOS .pkg today — skipping"
        return 0
    fi

    sub="$STAGE/dl/$name"
    mkdir -p "$sub"
    echo "==> [$name @ $tag] downloading from $repo (pattern: $glob)"
    gh release download "$tag" --repo "$repo" --pattern "$glob" --dir "$sub"

    pkg_file="$(find "$sub" -maxdepth 1 -name '*.pkg' -type f | head -1)"
    if [[ -z "$pkg_file" || ! -f "$pkg_file" ]]; then
        echo "ERROR: no .pkg landed for $name in $sub" >&2
        exit 1
    fi

    # Each component's released .pkg is a productbuild distribution
    # with one or more component pkgs inside. pkgutil --expand turns
    # those into directory entries; --flatten gets us a re-usable .pkg
    # file we can hand to productbuild --package-path.
    #
    # IMPORTANT: pkgutil --expand / --flatten preserve ad-hoc signatures
    # on payload binaries — do NOT add install_name_tool or
    # codesign --remove-signature here. Regression of #279 (SIGKILL at
    # dlopen) is a real risk if signatures are stripped.
    expanded="$sub/expanded"
    pkgutil --expand "$pkg_file" "$expanded"

    case "$name" in
        runtime)
            extract_runtime "$expanded"
            ;;
        gauss_demo)
            extract_gauss_demo "$expanded"
            ;;
        shell|leia_plugin|mcp_tools)
            # Future: shell/leia/mcp don't ship macOS .pkg today. When
            # they do, add extract_$name like extract_runtime — most
            # will look the same (one component .pkg inside, one
            # <choice>/<pkg-ref> pair).
            echo "WARN: $name has a macOS glob but no extraction rule yet — skipping"
            ;;
    esac
}

extract_runtime() {
    local expanded="$1"
    local comp_dir="$expanded/runtime.pkg"
    if [[ ! -d "$comp_dir" ]]; then
        echo "ERROR: runtime.pkg not found inside expanded runtime distribution" >&2
        echo "       (expected $comp_dir; check that the runtime release artifact is a productbuild distribution)" >&2
        exit 1
    fi
    local flat="$COMPONENTS_DIR/runtime.pkg"
    pkgutil --flatten "$comp_dir" "$flat"

    CHOICE_LINES+="        <line choice=\"runtime\"/>"$'\n'
    CHOICES+="    <choice id=\"runtime\" visible=\"true\" start_selected=\"true\" enabled=\"false\"
        title=\"DisplayXR Runtime\"
        description=\"OpenXR runtime with Vulkan compositor and MoltenVK. Installs to /Library/Application Support/DisplayXR/ and registers as the active OpenXR runtime.\">
        <pkg-ref id=\"com.displayxr.runtime\"/>
    </choice>
"
    PKG_REFS+="    <pkg-ref id=\"com.displayxr.runtime\" version=\"${RUNTIME_TAG#v}\" onConclusion=\"none\">runtime.pkg</pkg-ref>
"
}

# extract_gauss_demo: same shape as extract_runtime. The demo .pkg is a
# productbuild distribution with one component named gaussiansplat.pkg
# inside (identifier com.displayxr.gaussiansplat). The choice is
# user-toggleable (no enabled="false") because demos are opt-in unlike
# the runtime which is mandatory.
extract_gauss_demo() {
    local expanded="$1"
    local comp_dir="$expanded/gaussiansplat.pkg"
    if [[ ! -d "$comp_dir" ]]; then
        echo "ERROR: gaussiansplat.pkg not found inside expanded gauss_demo distribution" >&2
        echo "       (expected $comp_dir; check that the demo release artifact is a productbuild distribution)" >&2
        exit 1
    fi
    local flat="$COMPONENTS_DIR/gauss_demo.pkg"
    pkgutil --flatten "$comp_dir" "$flat"

    CHOICE_LINES+="        <line choice=\"gauss_demo\"/>"$'\n'
    CHOICES+="    <choice id=\"gauss_demo\" visible=\"true\" start_selected=\"true\"
        title=\"Gaussian Splat Viewer\"
        description=\"DisplayXR demo: real-time 3D Gaussian Splatting viewer for glasses-free 3D displays. Installs to /Applications/Gaussian Splat Viewer.app. Optional.\">
        <pkg-ref id=\"com.displayxr.gaussiansplat\"/>
    </choice>
"
    PKG_REFS+="    <pkg-ref id=\"com.displayxr.gaussiansplat\" version=\"${GAUSS_TAG#v}\" onConclusion=\"none\">gauss_demo.pkg</pkg-ref>
"
}

process_component runtime     "$RUNTIME_TAG"
process_component shell       "$SHELL_TAG"
process_component leia_plugin "$LEIA_TAG"
process_component mcp_tools   "$MCP_TAG"
# Demos go after core components in the install UI. gauss_demo is the
# only one with a macOS .pkg today (displayxr-demo-gaussiansplat v1.4.0).
# Activation also requires runtime's components.sh to carry a gauss_demo
# entry — graceful skip otherwise.
# modelviewer_demo is Windows-only (no macOS .pkg yet) — intentionally not bundled on macOS.
process_component gauss_demo  "$GAUSS_TAG"

if [[ -z "$CHOICE_LINES" ]]; then
    echo "ERROR: no components produced a macOS .pkg — nothing to bundle" >&2
    exit 1
fi

# 3. Emit Distribution.xml.
DIST="$STAGE/Distribution.xml"
cat > "$DIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
    <title>DisplayXR ${VERSION}</title>
    <organization>com.displayxr</organization>
    <os-version min="13.0"/>
    <license file="LICENSE"/>
    <welcome file="welcome.html"/>
    <choices-outline>
${CHOICE_LINES}    </choices-outline>
${CHOICES}${PKG_REFS}</installer-gui-script>
EOF

# 4. productbuild.
OUTPUT_PKG="$OUT_DIR/DisplayXRBundle-$VERSION.pkg"
echo "==> productbuild → $OUTPUT_PKG"
productbuild --distribution "$DIST" \
    --resources "$REPO_ROOT/installer/macos/resources" \
    --package-path "$COMPONENTS_DIR" \
    "$OUTPUT_PKG"

# 5. Sanity check: confirm the runtime payload survived the rewrap.
echo "==> payload verification"
PAYLOAD_FILES="$(pkgutil --payload-files "$OUTPUT_PKG" 2>/dev/null || true)"
if [[ -z "$PAYLOAD_FILES" ]]; then
    # productbuild distributions hide payload inside child pkgs; expand
    # to peek. This is just a regression guard, not a real install step.
    PEEK="$STAGE/verify"
    mkdir -p "$PEEK"
    pkgutil --expand "$OUTPUT_PKG" "$PEEK/bundle"
    PAYLOAD_FILES="$(pkgutil --payload-files "$PEEK/bundle/runtime.pkg" 2>/dev/null || true)"
fi
if ! echo "$PAYLOAD_FILES" | grep -q 'openxr_displayxr'; then
    echo "ERROR: runtime payload missing openxr_displayxr.dylib — bundle is broken" >&2
    exit 1
fi
if ! echo "$PAYLOAD_FILES" | grep -q '200-sim-display.json'; then
    echo "WARN: sim-display plug-in manifest not found in payload (may be a runtime-build regression)" >&2
fi

# 6. Clean up unless asked to keep.
if [[ "$KEEP_STAGE" -eq 0 ]]; then
    rm -rf "$STAGE"
fi

ls -lh "$OUTPUT_PKG"
echo "==> Done. Output: $OUTPUT_PKG"
