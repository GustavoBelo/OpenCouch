#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${PROJECT_DIR}/app/version.txt"
BUILD_DIR="${PROJECT_DIR}/appimage-build"
APPDIR="${BUILD_DIR}/AppDir"

VERSION="$(sed -n 's/^VERSION=//p' "${VERSION_FILE}")"
OUTPUT="OpenCouch-v${VERSION}-x86_64.AppImage"

LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
PLUGIN_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"

# --- Toolchain ---
# Both tools must live in the same directory, so we can use the same AppImage runtime for both.
mkdir -p "${BUILD_DIR}"
_fetch() {
    local dest="$1" url="$2"
    [[ -x "$dest" ]] && return
    echo "Downloading $(basename "$dest")..." >&2
    curl -fsSL "$url" -o "$dest" && chmod +x "$dest"
}
_fetch "$BUILD_DIR/linuxdeploy" "$LINUXDEPLOY_URL"
_fetch "$BUILD_DIR/linuxdeploy-plugin-qt" "$PLUGIN_URL"
LINUXDEPLOY="$BUILD_DIR/linuxdeploy"

# --- Build ---

echo "Building OpenCouch v${VERSION}..."
cmake -S "${PROJECT_DIR}/app" -B "${BUILD_DIR}/cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_STAGING_PREFIX="${APPDIR}/usr" \

cmake --build "${BUILD_DIR}/cmake" --parallel "$(nproc)"
cmake --install "${BUILD_DIR}/cmake" --prefix "${APPDIR}/usr"

# --- AppDir Structure ---
mkdir -p "${APPDIR}/usr/share/applications" \
         "${APPDIR}/usr/share/icons/hicolor/scalable/apps" \
         "${APPDIR}/usr/share/metainfo"

cp "$SCRIPT_DIR/io.github.gustavobelo.opencouch.desktop" \
   "$APPDIR/usr/share/applications/"

cp "$SCRIPT_DIR/icons/io.github.gustavobelo.opencouch.svg" \
   "$APPDIR/usr/share/icons/hicolor/scalable/apps/"

# Remove X-Flatpak key - not applicable to AppImage
sed -i '/^X-Flatpak/d' "$APPDIR/usr/share/applications/io.github.gustavobelo.opencouch.desktop"

# --- Bundle Qt6 + Kirigami QML modules ---
export QMAKE="${QMAKE:-$(command -v qmake6 || command -v qmake-qt6 || command -v qmake || echo qmake6)}"
export QML_SOURCES_PATHS="${PROJECT_DIR}/app/qml"
export EXTRA_QT_PLUGINS="wayland-shell-integration;wayland-graphics-integration-client"
# Suppress errors for missing option Wayland plugins, since they are not needed for AppImage
export EXTRA_QT_PLUGINS_OPTIONAL=1

"$LINUXDEPLOY" \
    --appdir "${APPDIR}" \
    --executable "${APPDIR}/usr/bin/opencouch" \
    --desktop-file "${APPDIR}/usr/share/applications/io.github.gustavobelo.opencouch.desktop" \
    --icon-file "${APPDIR}/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg" \
    --plugin qt \
    --output appimage

mv "OpenCouch-x86_64.AppImage" "${PROJECT_DIR}/${OUTPUT}"
    || mv "${APPDIR}/OpenCouch-x86_64.AppImage" "${PROJECT_DIR}/${OUTPUT}" 2>/dev/null 
    || true

echo ""
echo "AppImage built: ${PROJECT_DIR}/${OUTPUT}"
echo ""
echo "Note: the Open Couch engine (opencouch-engine) is NOT bundled - users need to install it separately."
echo "You can install it on the host with:"
echo "  bash <(curl -fsSL https://raw.githubusercontent.com/gustavobelo/open-couch/v$VERSION/packaging/host/install.sh)"