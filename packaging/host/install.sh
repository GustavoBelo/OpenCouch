#!/usr/bin/env bash
set -euo pipefail

# Bumped automatically by release.sh, do not edit manually
SELF_VERSION="1.6.10"
REPO_URL="https://raw.githubusercontent.com/GustavoBelo/OpenCouch/v${SELF_VERSION}/backend"

# Resolve SCRIPT_DIR only when the script lives on disk (not piped via curl)
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" && "${BASH_SOURCE[0]}"  != "bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_BACKEND="${SCRIPT_DIR}/../../backend"
else
    LOCAL_BACKEND=""
fi

check_dependencies() {
    local cmd
    local -a missing=()
    for cmd in jq kscreen-doctor pgrep; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]} == 0)); then
        if ! command -v wmctrl >/dev/null 2>&1; then
            echo "Warning: wmctrl not found; Big Picture exit will only be detected when Steam closes."
        fi
        return
    fi

    echo "Missing dependencies on the host: ${missing[*]}"
    echo "Install the equivalent packages from your distribution:"
    echo "  Fedora/Bazzite: jq kscreen procps-ng wmctrl"
    echo "  Debian/Ubuntu:  jq kde-cli-tools procps wmctrl"
    echo "  Arch:           jq kscreen procps-ng wmctrl"
    echo "Then run this installer again."
    exit 1
}

install_remote() {
    local dest="$1"
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    echo "Downloading Open Couch engine v${SELF_VERSION}..."
    curl -fsSL "${REPO_URL}/open-couch-engine" -o "${tmpdir}/open-couch-engine"
    curl -fsSL "${REPO_URL}/open-couch-log-viewer" -o "${tmpdir}/open-couch-log-viewer"
    curl -fsSL "${REPO_URL}/SHA256SUMS" -o "${tmpdir}/SHA256SUMS"

    (cd "${tmpdir}" && sha256sum -c SHA256SUMS --ignore-missing --quiet) \
        || { echo "SHA256 checksum verification failed. Aborting."; exit 1; }

    install -m755 "${tmpdir}/open-couch-engine" "${dest}/open-couch-engine"
    install -m755 "${tmpdir}/open-couch-log-viewer" "${dest}/open-couch-log-viewer"
}

install_local() {
    local dest="$1"
    if [[ -z "${LOCAL_BACKEND}" ]]; then
        echo "Local backend path not set. Cannot install local build."
        exit 1
    fi

    echo "Installing Open Couch engine from local build..."
    install -m755 "${LOCAL_BACKEND}/open-couch-engine" "${dest}/open-couch-engine"
    install -m755 "${LOCAL_BACKEND}/open-couch-log-viewer" "${dest}/open-couch-log-viewer"
}

# --- Argunment parsing --- 
FORCE_UPDATE=false
DEST="${HOME}/.local/bin"

for arg in "$@"; do
    case "$arg" in
        --system)
            DEST="/usr/local/bin"
            [[ $EUID -eq 0 ]] || { echo "Use 'sudo $0 --system' to install for all users." >&2; exit 1; }
            ;;
        --update)
            FORCE_UPDATE=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

mkdir -p "$DEST"
check_dependencies

# Skip if already installed and --update was not requested
if [[ "${FORCE_UPDATE}" == false && -x "${DEST}/open-couch-engine" ]]; then
    echo "Open Couch engine is already installed at ${DEST}."
    echo "If you came from the Open Couch app onboarding, click Refresh Status on the dashboard to continue."
    echo "Run with --update to force a reinstall."
    exit 0
fi

if [[ -n "${LOCAL_BACKEND}" && -f "${LOCAL_BACKEND}/open-couch-engine" ]]; then
    install_local "$DEST"
else
    command -v curl >/dev/null 2>&1 || { echo "curl is required for remote install." >&2; exit 1; }
    command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required for remote install." >&2; exit 1; }
    install_remote "$DEST"
fi

echo "Installed to ${DEST}."
if [[ "$DEST" == "${HOME}/.local/bin" ]]; then
    case ":$PATH:" in
        *":${HOME}/.local/bin:"*) ;;
        *) echo "Warning: ${HOME}/.local/bin is not on your PATH. Add it to your shell rc." ;;
    esac
fi

if command -v flatpak >/dev/null 2>&1 \
   && flatpak list --app --columns=application 2>/dev/null | grep -qx 'io.github.gustavobelo.opencouch'; then
    echo "The Open Couch app is already installed. Click Refresh Status on the dashboard to use the engine."
else
    echo "Now install the Open Couch app (Flatpak) to use the engine:"
    echo "  flatpak install flathub io.github.gustavobelo.opencouch"
fi
