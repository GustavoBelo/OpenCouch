#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${PROJECT_DIR}/app/version.txt"
MANIFEST_TEMPLATE="${PROJECT_DIR}/packaging/io.github.gustavobelo.opencouch.metainfo.xml"

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s X.Y.Z\n' "$(basename "$0")" >&2
    exit 1
fi

VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Error: invalid version "%s" (use X.Y.Z).\n' "$VERSION" >&2
    exit 1
fi

TAG="v${VERSION}"
if git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    printf 'Error: tag %s already exists.\n' "$TAG" >&2
    exit 1
fi

if git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    if ! git -C "$PROJECT_DIR" status --porcelain | grep -q .; then
        printf 'Working tree clean. Proceeding with %s...\n' "$TAG"
    else
        printf 'Error: the working tree has uncommitted changes.\n' >&2
        exit 1
    fi
    CURRENT_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
    if [[ "$CURRENT_BRANCH" != "main" ]]; then
        printf 'Error: releases must be created from branch "main" (current: %s).\n' "$CURRENT_BRANCH" >&2
        exit 1
    fi
else
    printf 'Repo without an initial commit; creating the initial commit before the release...\n'
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "Initial commit"
fi

RELEASE_DATE="$(date -u +%Y-%m-%d)"
printf 'VERSION=%s\nRELEASE_DATE=%s\n' "$VERSION" "$RELEASE_DATE" > "$VERSION_FILE"

# Sync version into host installer files
INSTALL_FILE="${SCRIPT_DIR}/host/install.sh"
sed -i -e "s/^SELF_VERSION=\"[^\"]*\"/SELF_VERSION=\"${VERSION}\"/" "$INSTALL_FILE"
if ! grep -q "^SELF_VERSION=\"${VERSION}\"" "$INSTALL_FILE"; then
    printf 'Error: failed to update SELF_VERSION in %s (pattern did not match).\n' "$INSTALL_FILE" >&2
    exit 1
fi

sed -i -e "s/^ENGINE_VERSION=\"[^\"]*\"/ENGINE_VERSION=\"${VERSION}\"/" \
    "${PROJECT_DIR}/backend/open-couch-engine"
if ! grep -q "^ENGINE_VERSION=\"${VERSION}\"" "${PROJECT_DIR}/backend/open-couch-engine"; then
    printf 'Error: failed to update ENGINE_VERSION in backend/open-couch-engine.\n' >&2
    exit 1
fi

# Sync tag in Flatpak manifest
FLATPAK_MANIFEST="${PROJECT_DIR}/packaging/io.github.gustavobelo.opencouch.yml"
sed -i -e "s/^  *tag: v.*/    tag: ${TAG}/"    "${FLATPAK_MANIFEST}"
if ! grep -q "tag: ${TAG}" "${FLATPAK_MANIFEST}"; then
    printf 'Error: failed to update tag in %s.\n' "$FLATPAK_MANIFEST" >&2
    exit 1
fi

# Sync MIN_VERSION in engine from the app's kMinEngineVersion
MIN_VERSION="$(sed -n 's/.*kMinEngineVersion\s*=\s*"\([^"]*\)".*/\1/p' \
    "${PROJECT_DIR}/app/src/engineclient.cpp")"
if [[ -z "$MIN_VERSION" ]]; then
    printf 'Error: could not extract kMinEngineVersion from app/src/engineclient.cpp.\n' >&2
    exit 1
fi
if ! [[ "$MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Error: invalid MIN_VERSION "%s" extracted from app/src/engineclient.cpp.\n' "$MIN_VERSION" >&2
    exit 1
fi
sed -i "/^MIN_VERSION=/d" "${PROJECT_DIR}/backend/open-couch-engine"
sed -i "/^ENGINE_VERSION=/a MIN_VERSION=\"${MIN_VERSION}\"" \
    "${PROJECT_DIR}/backend/open-couch-engine"
if ! grep -q "^MIN_VERSION=\"${MIN_VERSION}\"" "${PROJECT_DIR}/backend/open-couch-engine"; then
    printf 'Error: failed to insert MIN_VERSION=%s into backend/open-couch-engine.\n' "$MIN_VERSION" >&2
    exit 1
fi

# Generate SHA256SUMS for the host engine scripts
BACKEND_DIR="${PROJECT_DIR}/backend"
(cd "$BACKEND_DIR" && sha256sum open-couch-engine open-couch-log-viewer > SHA256SUMS)

# Validate AppStream metainfo BEFORE commit/tag — fail if invalid (when tool is available)
if command -v appstreamcli >/dev/null 2>&1; then
    TMP_META="$(mktemp)"
    sed -e "s/@PROJECT_VERSION@/${VERSION}/g" -e "s/@OPENCOUCH_RELEASE_DATE@/${RELEASE_DATE}/g" \
        "$MANIFEST_TEMPLATE" > "$TMP_META"
    if appstreamcli validate "$TMP_META"; then
        printf 'AppStream metainfo validated successfully.\n'
    else
        printf 'Error: appstreamcli validation failed — aborting release.\n' >&2
        rm -f "$TMP_META"
        exit 1
    fi
    rm -f "$TMP_META"
else
    printf 'Warning: appstreamcli not found; skipping metainfo validation.\n' >&2
fi

git -C "$PROJECT_DIR" add "$VERSION_FILE" "$INSTALL_FILE" \
    "${BACKEND_DIR}/open-couch-engine" "${BACKEND_DIR}/SHA256SUMS" \
    "$FLATPAK_MANIFEST"
git -C "$PROJECT_DIR" commit -m "Release ${TAG}"

git -C "$PROJECT_DIR" tag "$TAG"
printf 'Release %s created: tag %s and app/version.txt updated.\n' "$VERSION" "$TAG"
printf 'Push with: git push origin main --tags\n'
