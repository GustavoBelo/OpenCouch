#!/usr/bin/env bash
set -euo pipefail

# Builds a local AppImage replicating the CI pipeline (.github/workflows/release.yml).
# Requires an Arch Linux host with Qt6/KF6 dev packages installed.
# Run from the project root:
#
#   packaging/build-appimage.sh

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
# 1b. Rebuild the concatenated engine from lib/ + drivers/ + dispatcher
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/build-engine.sh"

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
# The CI image is Fedora (/usr/lib64), local builds are Arch (/usr/lib).
# Resolve once instead of hardcoding, so the two never drift again.
# readlink -f matters: on Arch /usr/lib64 is a symlink to /usr/lib, and
# `find /usr/lib64 -maxdepth 1` would then match only the symlink itself.
for _libdir in /usr/lib64 /usr/lib; do
    if [[ -d "${_libdir}/qt6/plugins" ]]; then
        QT_LIBDIR="$(readlink -f "${_libdir}")"
        break
    fi
done
if [[ -z "${QT_LIBDIR:-}" ]]; then
    printf 'Error: could not locate the Qt6 plugin directory.\n' >&2
    exit 1
fi
KF_LIBDIR="${QT_LIBDIR}"

mkdir -p "${APPDIR}/usr/plugins"/{platforms,styles,iconengines,imageformats,platformthemes}
cp -a "${QT_LIBDIR}"/qt6/plugins/platforms/libqwayland*.so "${APPDIR}/usr/plugins/platforms/"
test -f "${APPDIR}/usr/plugins/platforms/libqwayland.so"
cp -a "${QT_LIBDIR}"/qt6/plugins/wayland-* "${APPDIR}/usr/plugins/"
cp -a "${QT_LIBDIR}"/qt6/plugins/styles/* "${APPDIR}/usr/plugins/styles/" || true
cp -a "${QT_LIBDIR}"/qt6/plugins/iconengines/* "${APPDIR}/usr/plugins/iconengines/" || true
cp -a "${QT_LIBDIR}"/qt6/plugins/imageformats/* "${APPDIR}/usr/plugins/imageformats/" || true
cp -a "${QT_LIBDIR}"/qt6/plugins/platformthemes/* "${APPDIR}/usr/plugins/platformthemes/" || true

# Ensure SVG icon engine and its dependency are bundled.
# The iconengines copy above may silently fail (|| true) if the host lacks
# qt6-svg.  Copy explicitly and verify.
if [[ ! -f "${APPDIR}/usr/plugins/iconengines/libqsvgicon.so" ]]; then
    cp -a "${QT_LIBDIR}"/qt6/plugins/iconengines/libqsvgicon.so \
          "${APPDIR}/usr/plugins/iconengines/" 2>/dev/null || true
fi

# Kirigami loads its platform theme from plugins/kf6/kirigami/platform/<style>.so,
# picked by the QtQuick Controls style name. Without org.kde.desktop.so the UI
# falls back to Kirigami's hardcoded light BasicTheme no matter what
# QT_QUICK_CONTROLS_STYLE says — this is not traced by linuxdeploy because
# nothing links against it.
mkdir -p "${APPDIR}/usr/plugins/kf6/kirigami/platform"
cp -a "${QT_LIBDIR}"/qt6/plugins/kf6/kirigami/platform/*.so \
      "${APPDIR}/usr/plugins/kf6/kirigami/platform/"
test -f "${APPDIR}/usr/plugins/kf6/kirigami/platform/org.kde.desktop.so"

# Its dependency closure goes in AFTER linuxdeploy's deploy pass — see step 4.
# linuxdeploy prunes usr/lib down to the libraries it traced, so anything added
# before that pass is silently deleted again.

test -f "${APPDIR}/usr/bin/opencouch"
test -f "${APPDIR}/usr/share/applications/io.github.gustavobelo.opencouch.desktop"
test -f "${APPDIR}/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg"
test -f "${APPDIR}/usr/share/open-couch/open-couch-engine"

# Ensure hicolor/icon-theme index exists so Breeze's inheritance chain resolves.
# The Breeze index.theme specifies Inherits=hicolor; without this file,
# KIconLoader cannot walk the chain and all named icons fail silently.
if [[ ! -f "${APPDIR}/usr/share/icons/hicolor/index.theme" ]] \
   && [[ -f /usr/share/icons/hicolor/index.theme ]]; then
    cp /usr/share/icons/hicolor/index.theme "${APPDIR}/usr/share/icons/hicolor/"
fi

# Create symlink so the engine is discoverable on $PATH inside the AppImage.
# The GUI binary invokes "open-couch-engine" by bare name via QProcess.
ln -sf ../share/open-couch/open-couch-engine "${APPDIR}/usr/bin/open-couch-engine"

mkdir -p "${APPDIR}/usr/qml"
cp -a "${QT_LIBDIR}"/qt6/qml/* "${APPDIR}/usr/qml/"

mkdir -p "${APPDIR}/usr/share/icons"
cp -a /usr/share/icons/breeze "${APPDIR}/usr/share/icons/"
cp -a /usr/share/icons/breeze-dark "${APPDIR}/usr/share/icons/"

# ---------------------------------------------------------------------------
# 4. linuxdeploy, in two passes.
#
# It must be split: linuxdeploy prunes AppDir/usr/lib to the libraries it can
# trace from the binaries, and `--output appimage` packs the AppImage in the
# same invocation. So anything untraced has to be added between the deploy pass
# and the packaging pass — before, it gets pruned; after, the artifact already
# exists and the change never reaches it.
# ---------------------------------------------------------------------------
run_linuxdeploy() {
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
            --icon-file "${PROJECT_DIR}/packaging/icons/io.github.gustavobelo.opencouch.svg" \
            --desktop-file "${APPDIR}/usr/share/applications/io.github.gustavobelo.opencouch.desktop" \
            "$@"
    )
}

printf 'Running linuxdeploy (deploy pass)...\n'
run_linuxdeploy --plugin qt

# --- Libraries linuxdeploy cannot trace, because nothing links against them ---
# The Kirigami platform plugin is dlopen()ed by name; without this closure the
# UI silently falls back to Kirigami's hardcoded light theme.
printf 'Adding untraced libraries...\n'
mkdir -p "${APPDIR}/usr/lib"
for lib in libKF6IconThemes libKF6ColorScheme libKF6ConfigCore libKF6ConfigGui \
           libKF6GuiAddons libKF6BreezeIcons libKF6Archive libKF6I18n \
           libKF6Codecs libKF6WidgetsAddons libQt6Svg libQt6SvgWidgets; do
    if compgen -G "${APPDIR}/usr/lib/${lib}.so.*" >/dev/null; then
        continue
    fi
    src="$(find "${KF_LIBDIR}" -maxdepth 1 -name "${lib}.so.*" 2>/dev/null | head -1)"
    if [[ -n "$src" ]]; then
        # -L dereferences: these are soname symlinks (libFoo.so.6 ->
        # libFoo.so.6.29.0) and `cp -a` would copy a dangling link.
        cp -aL "$src" "${APPDIR}/usr/lib/"
    else
        printf 'Warning: %s not found on the host; not bundled.\n' "$lib" >&2
    fi
done
test -f "${APPDIR}/usr/lib/libKF6ColorScheme.so.6"
test -f "${APPDIR}/usr/lib/libKF6IconThemes.so.6"

printf 'Running linuxdeploy (packaging pass)...\n'
run_linuxdeploy --custom-apprun "${SCRIPT_DIR}/AppRun" --output appimage
rm -f "${APPDIR}/AppRun.env"

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
    test -f squashfs-root/usr/bin/open-couch-engine
    test -f squashfs-root/usr/plugins/platforms/libqwayland.so
    test -f squashfs-root/usr/plugins/iconengines/libqsvgicon.so
    test -f squashfs-root/usr/plugins/kf6/kirigami/platform/org.kde.desktop.so
    test -f squashfs-root/usr/lib/libKF6ColorScheme.so.6
    test -f squashfs-root/usr/lib/libKF6IconThemes.so.6
    # AppRun must be our script, not linuxdeploy's symlink to the binary
    test -f squashfs-root/AppRun && ! test -L squashfs-root/AppRun
    grep -q QML2_IMPORT_PATH squashfs-root/AppRun
    test -d squashfs-root/usr/qml/org/kde/desktop
    test -f squashfs-root/usr/share/applications/io.github.gustavobelo.opencouch.desktop
    test -f squashfs-root/usr/share/icons/hicolor/scalable/apps/io.github.gustavobelo.opencouch.svg
    test -f squashfs-root/usr/share/icons/hicolor/index.theme
    test -f squashfs-root/usr/share/open-couch/open-couch-engine
)

printf '\nAppImage generated: %s (version %s)\n' "${OUTPUT}" "${VERSION}"
printf 'Run it with: %s\n' "${OUTPUT}"
printf '(if FUSE is missing on the host, use: APPIMAGE_EXTRACT_AND_RUN=1 %s)\n' "${OUTPUT}"
# A previously started instance still owns the single-instance socket, so
# launching this build would just raise the OLD window and exit — which looks
# exactly like "the rebuild did not take effect". Warn instead of letting that
# waste another debugging round. Never kill the user's process from here.
INSTANCE_INFO="${TMPDIR:-/tmp}/OpenCouchInstance.info"
if [[ -f "${INSTANCE_INFO}" ]]; then
    RUNNING_PID="$(sed -n '1p' "${INSTANCE_INFO}" 2>/dev/null || true)"
    RUNNING_PATH="$(sed -n '3p' "${INSTANCE_INFO}" 2>/dev/null || true)"
    [[ -n "${RUNNING_PATH}" ]] || RUNNING_PATH="$(sed -n '2p' "${INSTANCE_INFO}" 2>/dev/null || true)"
    if [[ "${RUNNING_PID}" =~ ^[0-9]+$ ]] && kill -0 "${RUNNING_PID}" 2>/dev/null; then
        printf '\nWARNING: an instance is already running (pid %s, %s).\n' \
            "${RUNNING_PID}" "${RUNNING_PATH:-unknown}"
        printf 'It will intercept the launch and show its own window instead.\n'
        printf 'Replace it with this build:\n  %s --replace\n' "${OUTPUT}"
    fi
fi
