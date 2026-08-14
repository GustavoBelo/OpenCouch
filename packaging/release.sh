#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${PROJECT_DIR}/app/version.txt"
MANIFEST_TEMPLATE="${PROJECT_DIR}/packaging/io.github.gustavobelo.opencouch.metainfo.xml"

if [[ $# -ne 1 ]]; then
    printf 'Uso: %s X.Y.Z\n' "$(basename "$0")" >&2
    exit 1
fi

VERSION="$1"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Erro: versao invalida "%s" (use X.Y.Z).\n' "$VERSION" >&2
    exit 1
fi

TAG="v${VERSION}"
if git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    printf 'Erro: a tag %s ja existe.\n' "$TAG" >&2
    exit 1
fi

if git -C "$PROJECT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    if ! git -C "$PROJECT_DIR" status --porcelain | grep -q .; then
        printf 'Working tree limpo. Prosseguindo com %s...\n' "$TAG"
    else
        printf 'Erro: o working tree tem alteracoes nao commitadas.\n' >&2
        exit 1
    fi
else
    printf 'Repo sem commit inicial; criando commit inicial antes do release...\n'
    git -C "$PROJECT_DIR" add -A
    git -C "$PROJECT_DIR" commit -m "Initial commit"
fi

RELEASE_DATE="$(date -u +%Y-%m-%d)"
printf 'VERSION=%s\nRELEASE_DATE=%s\n' "$VERSION" "$RELEASE_DATE" > "$VERSION_FILE"
git -C "$PROJECT_DIR" add "$VERSION_FILE"
git -C "$PROJECT_DIR" commit -m "Release ${TAG}"

if command -v appstreamcli >/dev/null 2>&1; then
    TMP_META="$(mktemp)"
    sed -e "s/@PROJECT_VERSION@/${VERSION}/g" -e "s/@OPENCOUCH_RELEASE_DATE@/${RELEASE_DATE}/g" \
        "$MANIFEST_TEMPLATE" > "$TMP_META"
    if appstreamcli validate "$TMP_META"; then
        printf 'Metainfo AppStream validado com sucesso.\n'
    else
        printf 'Aviso: appstreamcli validou o metainfo com problemas acima.\n' >&2
    fi
    rm -f "$TMP_META"
else
    printf 'Aviso: appstreamcli nao encontrado; pulando validacao do metainfo.\n' >&2
fi

git -C "$PROJECT_DIR" tag "$TAG"
printf 'Release %s criada: tag %s e app/version.txt atualizado.\n' "$VERSION" "$TAG"
printf 'Envie com: git push origin main --tags\n'
