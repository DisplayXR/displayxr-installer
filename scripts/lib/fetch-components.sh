#!/usr/bin/env bash
# Source the per-component asset table from displayxr-runtime at the
# pinned $RUNTIME_TAG. Sourcing (not copying) keeps this repo's table in
# lockstep with what the runtime team curates — the runtime repo's
# scripts/lib/components.sh is annotated as the single source of truth
# (see its header comment).
#
# Caller responsibilities:
#   - export $REPO_ROOT (absolute path to displayxr-installer checkout)
#   - have already cd'd somewhere stable
#   - have jq + curl available
#
# After sourcing this file, the following are available:
#   - $RUNTIME_TAG                  the runtime tag the table is pinned to
#   - component_field <name> <fld>  helper from runtime's components.sh
#   - COMPONENT_REPO_<name>         per-component vars
#   - COMPONENT_PKG_MACOS_<name>
#   - COMPONENT_EXE_WINDOWS_<name>
#   - COMPONENT_INSTALL_MARKER_*_<name>

set -eu

if [[ -z "${REPO_ROOT:-}" ]]; then
    echo "fetch-components.sh: \$REPO_ROOT is not set" >&2
    return 1 2>/dev/null || exit 1
fi

VERSIONS_JSON="${VERSIONS_JSON:-$REPO_ROOT/versions.json}"
RUNTIME_TAG="$(jq -r '.runtime' "$VERSIONS_JSON")"
if [[ -z "$RUNTIME_TAG" || "$RUNTIME_TAG" == "null" ]]; then
    echo "fetch-components.sh: versions.json has no .runtime pin" >&2
    return 1 2>/dev/null || exit 1
fi

COMPONENTS_URL="https://raw.githubusercontent.com/DisplayXR/displayxr-runtime/${RUNTIME_TAG}/scripts/lib/components.sh"
CACHE_DIR="$REPO_ROOT/_stage"
CACHE_FILE="$CACHE_DIR/components.sh"
mkdir -p "$CACHE_DIR"

# Fetch fresh on each build. The runtime tag is part of the URL, so
# different tags get different caches naturally.
echo "==> fetching components.sh from runtime@${RUNTIME_TAG}"
curl -fsSL "$COMPONENTS_URL" -o "$CACHE_FILE"

# shellcheck disable=SC1090
source "$CACHE_FILE"

# Sanity: the table must define at least the four core components.
for name in runtime shell leia_plugin mcp_tools; do
    if [[ -z "$(component_field "$name" REPO)" ]]; then
        echo "fetch-components.sh: components.sh@${RUNTIME_TAG} has no entry for '$name'" >&2
        return 1 2>/dev/null || exit 1
    fi
done

export RUNTIME_TAG
