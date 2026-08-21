#!/usr/bin/env bash
set -euo pipefail

# Builds a local AppImage replicating the CI pipeline (.github/workflows/release.yml).
# Run it inside the `fedora` distrobox, from the project root:
#
#   distrobox enter fedora -- bash -c "packaging/build-appimage.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/appimage-build"
DIST_DIR="${PROJECT_DIR}/appimage-dist"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/opencouch-appimage"
OUTPUT="${PROJECT_DIR}/OpenCouch-x86_64.AppImage"

VERSION_FILE="${PROJECT_DIR}/app/version.txt"
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage"
LINUXDEPLOY_QT_URL="https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    }
}

[[ -f "${VERSION_FILE}" ]] || { printf 'Error: %s not found.\n' "${VERSION_FILE}" >&2; exit 1; }
VERSION="$(sed -n 's/^VERSION=//p' "${VERSION_FILE}")"
[[ -n "${VERSION}" ]] || { printf 'Error: could not read VERSION from %s.\n' "${VERSION_FILE}" >&2; exit 1; }

require_cmd cmake
require_cmd g++
require_cmd wget
require_cmd patchelf
require_cmd file

APPDIR="${DIST_DIR}/AppDir"

# ---------------------------------------------------------------------------
# 1. Download + extract linuxdeploy tooling (cached)
# ---------------------------------------------------------------------------
mkdir -p "${CACHE_DIR}"
linuxdeploy_bin="${CACHE_DIR}/linuxdeploy-x86_64.AppImage"
qt_plugin_bin="${CACHE_DIR}/linuxdeploy-plugin-qt-x86_64.AppImage"

if [[ ! -f "${linuxdeploy_bin}" ]]; then
    printf 'Downloading linuxdeploy...\n'
    wget --no-verbose -O "${linuxdeploy_bin}" "${LINUXDEPLOY_URL}"
    chmod +x "${linuxdeploy_bin}"
fi
if [[ ! -f "${qt_plugin_bin}" ]]; then
    printf 'Downloading linuxdeploy-plugin-qt...\n'
    wget --no-verbose -O "${qt_plugin_bin}" "${LINUXDEPLOY_QT_URL}"
    chmod +x "${qt_plugin_bin}"
fi

rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
(
    cd "${DIST_DIR}"
    "${linuxdeploy_bin}" --appimage-extract >/dev/null
    mv squashfs-root linuxdeploy-ext
    "${qt_plugin_bin}" --appimage-extract >/dev/null
    mv squashfs-root qt-plugin-ext
)
cp /usr/bin/patchelf "${DIST_DIR}/linuxdeploy-ext/usr/bin/patchelf"
cp /usr/bin/patchelf "${DIST_DIR}/qt-plugin-ext/usr/bin/patchelf"
ln -sf "${DIST_DIR}/qt-plugin-ext/AppRun" "${DIST_DIR}/linuxdeploy-ext/usr/bin/linuxdeploy-plugin-qt"

# ---------------------------------------------------------------------------
# 2. Configure + build + install into AppDir (same flags as CI)
# ---------------------------------------------------------------------------
printf 'Configuring build (INSTALL_ENGINE_BUNDLE=ON)...\n'
cmake -S "${PROJECT_DIR}/app" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DINSTALL_ENGINE_BUNDLE=ON \
    -DCMAKE_INSTALL_PREFIX=/usr

printf 'Building...\n'
cmake --build "${BUILD_DIR}" --parallel "$(nproc)"

DESTDIR="${APPDIR}" cmake --install "${BUILD_DIR}"

# ---------------------------------------------------------------------------
# 3. Package Qt plugins, QML and icons (same steps as CI)
# ---------------------------------------------------------------------------
mkdir -p "${APPDIR}/usr/plugins"/{platforms,styles,iconengines,imageformats}
cp -a /usr/lib64/qt6/plugins/platforms/libqwayland*.so "${APPDIR}/usr/plugins/platforms/"
test -f "${APPDIR}/usr/plugins/platforms/libqwayland.so"
cp -a /usr/lib64/qt6/plugins/wayland-* "${APPDIR}/usr/plugins/"
cp -a /usr/lib64/qt6/plugins/styles/* "${APPDIR}/usr/plugins/styles/" || true
cp -a /usr/lib64/qt6/plugins/iconengines/* "${APPDIR}/usr/plugins/iconengines/" || true
cp -a /usr/lib64/qt6/plugins/imageformats/* "${APPDIR}/usr/plugins/imageformats/" || true

test -f "${APPDIR}/usr/bin/opencouch"
test -f "${APPDIR}/usr/share/applications/io.github.gustavobelo.opencouch.desktop"
test -f "${APPDIR}/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg"
test -f "${APPDIR}/usr/share/open-couch/open-couch-engine"

mkdir -p "${APPDIR}/usr/qml"
cp -a /usr/lib64/qt6/qml/* "${APPDIR}/usr/qml/"

mkdir -p "${APPDIR}/usr/share/icons"
cp -a /usr/share/icons/breeze "${APPDIR}/usr/share/icons/"
cp -a /usr/share/icons/breeze-dark "${APPDIR}/usr/share/icons/"

cat >> "${APPDIR}/AppRun.env" <<'EOF'
export XDG_DATA_DIRS="${APPDIR}/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export QT_PLUGIN_PATH="${APPDIR}/usr/plugins:${QT_PLUGIN_PATH:-}"
EOF

# ---------------------------------------------------------------------------
# 4. Run linuxdeploy to produce the AppImage
# ---------------------------------------------------------------------------
printf 'Running linuxdeploy...\n'
(
    cd "${PROJECT_DIR}"
    VERSION="${VERSION}" \
    QMAKE=qmake6 \
    QML_SOURCES_PATHS="${PROJECT_DIR}/app/qml" \
    EXTRA_QT_PLUGINS=wayland \
    APPIMAGE_EXTRACT_AND_RUN=1 \
    NO_STRIP=1 \
        "${DIST_DIR}/linuxdeploy-ext/AppRun" \
        --appdir "${APPDIR}" \
        --plugin qt \
        --output appimage \
        --icon-file "${PROJECT_DIR}/packaging/icons/io.github.gustavobelo.opencouch.svg" \
        --desktop-file "${APPDIR}/usr/share/applications/io.github.gustavobelo.opencouch.desktop"
)

APPIMAGE_FILE="$(ls Open_Couch-*-x86_64.AppImage 2>/dev/null | head -1 || true)"
if [[ -z "${APPIMAGE_FILE}" ]]; then
    APPIMAGE_FILE="$(ls Open_Couch*.AppImage 2>/dev/null | head -1 || true)"
fi
if [[ -z "${APPIMAGE_FILE}" ]]; then
    printf 'Error: linuxdeploy did not produce an AppImage.\n' >&2
    exit 1
fi
mv "${APPIMAGE_FILE}" "${OUTPUT}"

# ---------------------------------------------------------------------------
# 5. Smoke-check the resulting AppImage
# ---------------------------------------------------------------------------
rm -rf "${DIST_DIR}/appimage-check"
mkdir -p "${DIST_DIR}/appimage-check"
(
    cd "${DIST_DIR}/appimage-check"
    "${OUTPUT}" --appimage-extract >/dev/null
    test -f squashfs-root/usr/bin/opencouch
    test -f squashfs-root/usr/plugins/platforms/libqwayland.so
    test -f squashfs-root/usr/share/applications/io.github.gustavobelo.opencouch.desktop
    test -f squashfs-root/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg
    test -f squashfs-root/usr/share/open-couch/open-couch-engine
)

printf '\nAppImage generated: %s (version %s)\n' "${OUTPUT}" "${VERSION}"
printf 'Run it with: %s\n' "${OUTPUT}"
printf '(if FUSE is missing on the host, use: APPIMAGE_EXTRACT_AND_RUN=1 %s)\n' "${OUTPUT}"