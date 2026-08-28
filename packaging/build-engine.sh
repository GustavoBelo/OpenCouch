#!/usr/bin/env bash
set -euo pipefail

# build-engine.sh — concatenates lib/ + drivers/ + dispatcher into a single
# backend/open-couch-engine script for distribution.
#
# The sources are backend/lib/, backend/drivers/ and backend/dispatcher.sh.
# backend/open-couch-engine is a GENERATED artifact and is never read here.
#
# Run from the project root or packaging/:
#   bash packaging/build-engine.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${PROJECT_DIR}/backend"
DISPATCHER="${BACKEND_DIR}/dispatcher.sh"
ENGINE="${BACKEND_DIR}/open-couch-engine"

# Explicit load order. Do not switch to a glob: the order decides which
# definition wins for any symbol defined in more than one file.
DRIVERS=(generic gnome hyprland kde)

for required in "${BACKEND_DIR}/lib/common.sh" "${BACKEND_DIR}/lib/detect.sh" "$DISPATCHER"; do
    [[ -f "$required" ]] || { printf 'Error: missing source file %s\n' "$required" >&2; exit 1; }
done
for driver in "${DRIVERS[@]}"; do
    [[ -f "${BACKEND_DIR}/drivers/${driver}.sh" ]] \
        || { printf 'Error: missing driver %s.sh\n' "$driver" >&2; exit 1; }
done

# --------------------------------------------------------------------------
# Guard: drivers must only define prefixed top-level functions.
#
# Everything is concatenated into one bash file, so an unprefixed function in
# one driver silently overrides the shared implementation in lib/common.sh for
# EVERY compositor. That is how the Hyprland driver once hijacked KDE's
# Big Picture handling. Fail the build instead.
# --------------------------------------------------------------------------
leaks=0
for driver in "${DRIVERS[@]}"; do
    file="${BACKEND_DIR}/drivers/${driver}.sh"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf 'Error: %s defines an unprefixed top-level function: %s\n' \
            "drivers/${driver}.sh" "$line" >&2
        leaks=1
    done < <(grep -nE '^[a-z_][a-z0-9_]*\(\) *\{' "$file" \
             | grep -vE ":${driver}_" || true)
done
if (( leaks )); then
    printf 'Every driver function must be prefixed with its driver name.\n' >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Version sync: ENGINE_VERSION comes from app/version.txt, MIN_VERSION from
# app/src/engineclient.cpp. Both are written into lib/common.sh so that a
# rebuild can never revert them (release.sh used to patch only the artifact).
# --------------------------------------------------------------------------
COMMON="${BACKEND_DIR}/lib/common.sh"

APP_VERSION="$(sed -n 's/^VERSION=\(.*\)$/\1/p' "${PROJECT_DIR}/app/version.txt")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Error: could not read a valid VERSION from app/version.txt (got "%s").\n' \
        "$APP_VERSION" >&2
    exit 1
fi

MIN_VERSION="$(sed -n 's/.*kMinEngineVersion[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${PROJECT_DIR}/app/src/engineclient.cpp")"
if [[ ! "$MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Error: could not extract kMinEngineVersion from app/src/engineclient.cpp (got "%s").\n' \
        "$MIN_VERSION" >&2
    exit 1
fi

sed -i -e "s/^ENGINE_VERSION=\"[^\"]*\"/ENGINE_VERSION=\"${APP_VERSION}\"/" \
       -e "s/^MIN_VERSION=\"[^\"]*\"/MIN_VERSION=\"${MIN_VERSION}\"/" "$COMMON"
grep -q "^ENGINE_VERSION=\"${APP_VERSION}\"" "$COMMON" \
    || { printf 'Error: failed to sync ENGINE_VERSION in lib/common.sh.\n' >&2; exit 1; }
grep -q "^MIN_VERSION=\"${MIN_VERSION}\"" "$COMMON" \
    || { printf 'Error: failed to sync MIN_VERSION in lib/common.sh.\n' >&2; exit 1; }

# --------------------------------------------------------------------------
# Concatenate. The dispatcher's dev-mode header (shebang, set, ENGINE_DIR,
# source lines) is stripped: everything it sources is already inlined above it.
# --------------------------------------------------------------------------
{
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '\n'
    printf '# GENERATED FILE — do not edit.\n'
    printf '# Built by packaging/build-engine.sh from backend/lib, backend/drivers\n'
    printf '# and backend/dispatcher.sh. Edit those instead.\n'
    printf '\n'

    cat "${BACKEND_DIR}/lib/common.sh"
    printf '\n'
    cat "${BACKEND_DIR}/lib/detect.sh"

    for driver in "${DRIVERS[@]}"; do
        printf '\n\n'
        cat "${BACKEND_DIR}/drivers/${driver}.sh"
    done

    printf '\n'
    sed -e '1{/^#!/d}' \
        -e '/^set -euo pipefail$/d' \
        -e '/^ENGINE_DIR=/d' \
        -e '/^export ENGINE_DIR$/d' \
        -e '/^# shellcheck source=/d' \
        -e '\|^source "\${ENGINE_DIR}|d' \
        "$DISPATCHER"
} > "$ENGINE"

chmod +x "$ENGINE"

if ! bash -n "$ENGINE"; then
    printf 'Error: generated engine has syntax errors.\n' >&2
    exit 1
fi

printf 'Built %s (ENGINE_VERSION=%s, MIN_VERSION=%s)\n' \
    "$ENGINE" "$APP_VERSION" "$MIN_VERSION"
