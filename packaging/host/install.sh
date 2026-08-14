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
            echo "Aviso: wmctrl nao encontrado; a saida do Big Picture so sera detectada quando a Steam fechar."
        fi
        return
    fi

    echo "Dependencias ausentes no host: ${missing[*]}"
    echo "Instale os pacotes equivalentes da sua distribuicao:"
    echo "  Fedora/Bazzite: jq kscreen procps-ng wmctrl"
    echo "  Debian/Ubuntu:  jq kde-cli-tools procps wmctrl"
    echo "  Arch:           jq kscreen procps-ng wmctrl"
    echo "Depois execute este instalador novamente."
    exit 1
}

if [[ "${1:-}" == "--system" ]]; then
    DEST="/usr/local/bin"
    [[ $EUID -eq 0 ]] || { echo "Use 'sudo $0 --system' para instalar para todos os usuarios." >&2; exit 1; }
else
    DEST="${HOME}/.local/bin"
fi

mkdir -p "$DEST"
check_dependencies
install -m755 "${BACKEND_DIR}/open-couch-engine" "${DEST}/open-couch-engine"
install -m755 "${BACKEND_DIR}/open-couch-log-viewer" "${DEST}/open-couch-log-viewer"

echo "Instalado em ${DEST}."
if [[ "$DEST" == "${HOME}/.local/bin" ]]; then
    case ":$PATH:" in
        *":${HOME}/.local/bin:"*) ;;
        *) echo "Aviso: ${HOME}/.local/bin nao esta no seu PATH. Adicione-o no seu shell rc." ;;
    esac
fi

echo "Agora instale o app Open Couch (Flatpak) para configurar e usar a interface grafica."
