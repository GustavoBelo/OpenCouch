#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/flatpak-build"
REPO_DIR="${PROJECT_DIR}/flatpak-repo"
BUNDLE="${PROJECT_DIR}/OpenCouch.flatpak"
MANIFEST="${SCRIPT_DIR}/io.github.gustavobelo.opencouch.yml"
VERSION_FILE="${PROJECT_DIR}/app/version.txt"

if [[ ! -f "${VERSION_FILE}" ]]; then
    printf 'Erro: %s nao encontrado.\n' "${VERSION_FILE}" >&2
    exit 1
fi
VERSION="$(sed -n 's/^VERSION=//p' "${VERSION_FILE}")"
if [[ -z "${VERSION}" ]]; then
    printf 'Erro: nao consegui ler VERSION de %s.\n' "${VERSION_FILE}" >&2
    exit 1
fi

if ! command -v flatpak >/dev/null 2>&1; then
    printf 'Erro: flatpak nao esta instalado.\n' >&2
    exit 1
fi

if ! flatpak run org.flatpak.Builder --help >/dev/null 2>&1; then
    printf 'Erro: instale o org.flatpak.Builder antes de compilar.\n' >&2
    exit 1
fi

flatpak run org.flatpak.Builder \
    --force-clean \
    --default-branch="v${VERSION}" \
    --repo="${REPO_DIR}" \
    "${BUILD_DIR}" \
    "${MANIFEST}"

flatpak build-bundle \
    "${REPO_DIR}" \
    "${BUNDLE}" \
    io.github.gustavobelo.opencouch \
    "v${VERSION}"

printf 'Flatpak gerado em: %s (versao v%s)\n' "${BUNDLE}" "${VERSION}"
