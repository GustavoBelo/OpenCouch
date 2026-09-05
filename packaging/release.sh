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

# The engine carries no version of its own to sync: it is a Go binary and the
# version arrives at build time through -ldflags, from this file. There is
# nothing to sed and nothing to checksum here -- the release workflow publishes
# the binary and its SHA256SUMS.

# Sync version into host installer files
INSTALL_FILE="${SCRIPT_DIR}/host/install.sh"
sed -i -e "s/^SELF_VERSION=\"[^\"]*\"/SELF_VERSION=\"${VERSION}\"/" "$INSTALL_FILE"
if ! grep -q "^SELF_VERSION=\"${VERSION}\"" "$INSTALL_FILE"; then
    printf 'Error: failed to update SELF_VERSION in %s (pattern did not match).\n' "$INSTALL_FILE" >&2
    exit 1
fi

# Sync version into the native packages.
#
# These carry the version in their own files and are built from the tag's
# tarball, so one left behind does not fail loudly -- it fetches the *previous*
# tag and ships it under the new version's name. Every one is verified after
# writing, because a silent sed miss here is a package that lies about what is
# inside it.
PKGBUILDS=(
    "${SCRIPT_DIR}/aur/open-couch-engine/PKGBUILD"
    "${SCRIPT_DIR}/aur/open-couch/PKGBUILD"
)
for pkgbuild in "${PKGBUILDS[@]}"; do
    sed -i -e "s/^pkgver=.*/pkgver=${VERSION}/" -e "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild"
    if ! grep -q "^pkgver=${VERSION}$" "$pkgbuild"; then
        printf 'Error: failed to update pkgver in %s.\n' "$pkgbuild" >&2
        exit 1
    fi
done

SPEC="${SCRIPT_DIR}/rpm/open-couch.spec"
sed -i -e "0,/^Version:.*/s//Version:        ${VERSION}/" -e "0,/^Release:.*/s//Release:        1%{?dist}/" "$SPEC"
if ! grep -q "^Version:        ${VERSION}$" "$SPEC"; then
    printf 'Error: failed to update Version in %s.\n' "$SPEC" >&2
    exit 1
fi

# rpmlint treats a version with no changelog entry as an error, and a package
# whose changelog stops before its own version tells the user nothing about what
# they are installing. The entry points at the release notes rather than trying
# to summarise them here, where nobody would keep it honest.
PACKAGER_NAME="$(git -C "$PROJECT_DIR" config user.name || echo 'Gustavo Belo')"
PACKAGER_EMAIL="$(git -C "$PROJECT_DIR" config user.email || echo 'gustavobelo28@gmail.com')"
if ! grep -q "^\* .* - ${VERSION}-1$" "$SPEC"; then
    CHANGELOG_ENTRY="* $(LC_ALL=C date -u '+%a %b %d %Y') ${PACKAGER_NAME} <${PACKAGER_EMAIL}> - ${VERSION}-1
- See https://github.com/GustavoBelo/OpenCouch/releases/tag/${TAG}
"
    awk -v entry="$CHANGELOG_ENTRY" '
        /^%changelog$/ { print; print entry; next }
        { print }
    ' "$SPEC" > "${SPEC}.tmp" && mv "${SPEC}.tmp" "$SPEC"
    if ! grep -q "^\* .* - ${VERSION}-1$" "$SPEC"; then
        printf 'Error: failed to add a %%changelog entry for %s.\n' "$VERSION" >&2
        exit 1
    fi
fi

# Validate AppStream metainfo BEFORE commit/tag — fail if invalid (when tool is available)
if command -v appstreamcli >/dev/null 2>&1; then
    TMP_META="$(mktemp)"
    sed -e "s/@PROJECT_VERSION@/${VERSION}/g" -e "s/@OPENCOUCH_RELEASE_DATE@/${RELEASE_DATE}/g" \
        "$MANIFEST_TEMPLATE" > "$TMP_META"
    # --no-net because the screenshot URLs point at the tag this script is
    # about to create. Fetching them can only fail: the tag does not exist yet,
    # and it cannot, since the validation gates the commit that precedes it.
    # Everything else the validator checks is in the file itself.
    if appstreamcli validate --no-net "$TMP_META"; then
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

git -C "$PROJECT_DIR" add "$VERSION_FILE" "$INSTALL_FILE" "${PKGBUILDS[@]}" "$SPEC"
git -C "$PROJECT_DIR" commit -m "Release ${TAG}"

git -C "$PROJECT_DIR" tag "$TAG"
printf 'Release %s created: tag %s and app/version.txt updated.\n' "$VERSION" "$TAG"
printf 'Push with: git push origin main --tags\n'
