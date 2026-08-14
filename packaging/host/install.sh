#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="${SCRIPT_DIR}/../../backend"

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

if [[ "${1:-}" == "--system" ]]; then
    DEST="/usr/local/bin"
    [[ $EUID -eq 0 ]] || { echo "Use 'sudo $0 --system' to install for all users." >&2; exit 1; }
else
    DEST="${HOME}/.local/bin"
fi

mkdir -p "$DEST"
check_dependencies
install -m755 "${BACKEND_DIR}/open-couch-engine" "${DEST}/open-couch-engine"
install -m755 "${BACKEND_DIR}/open-couch-log-viewer" "${DEST}/open-couch-log-viewer"

echo "Installed to ${DEST}."
if [[ "$DEST" == "${HOME}/.local/bin" ]]; then
    case ":$PATH:" in
        *":${HOME}/.local/bin:"*) ;;
        *) echo "Warning: ${HOME}/.local/bin is not on your PATH. Add it to your shell rc." ;;
    esac
fi

echo "Now install the Open Couch app (Flatpak) to configure and use the graphical interface."
