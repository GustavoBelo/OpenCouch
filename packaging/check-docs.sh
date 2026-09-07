#!/usr/bin/env bash
#
# Confere os fatos do AGENTS.md que dá para conferir por máquina.
#
# Existe porque "atualize o AGENTS.md na mesma mudança" é uma regra sem nada que
# a faça valer, e o arquivo derivou: chegou a documentar dois arquivos-fonte que
# não existiam, um manifest Flatpak apagado, um `MIN_VERSION` que nunca existiu
# em lugar nenhum e um bloco de números de linha além do fim dos arquivos.
#
# Só três checagens, todas mecânicas. Nada aqui julga o texto -- julgar texto é
# trabalho de quem revisa.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${ROOT}/AGENTS.md"
failures=0

fail() {
    printf 'AGENTS.md: %s\n' "$1" >&2
    failures=$((failures + 1))
}

# 1. Todo arquivo-fonte citado como `src/nome.{h,cpp}` ou `qml/Nome.qml` existe.
while read -r cited; do
    case "$cited" in
        *'{h,cpp}')
            base="${cited%.\{h,cpp\}}"
            for ext in h cpp; do
                [[ -f "${ROOT}/app/${base}.${ext}" ]] || fail "cita app/${base}.${ext}, que não existe"
            done
            ;;
        *) [[ -f "${ROOT}/app/${cited}" ]] || fail "cita app/${cited}, que não existe" ;;
    esac
done < <(grep -oE '`(src|qml)/[A-Za-z0-9_/.]+(\{h,cpp\}|\.(qml|js|cpp|h))`' "$DOC" \
         | tr -d '`' | sort -u)

# 2. Todo subcomando que o engine imprime no seu próprio `usage()` está documentado.
#
# Na direção que importa: um comando novo sem documentação é a derivação que
# acontece. O contrário -- documentar um comando que não existe -- é pego pelo
# smoke test da CI, que roda o binário.
while read -r command; do
    grep -q "\`${command}[ \`]" "$DOC" || fail "o engine tem o subcomando '${command}' e o documento não o menciona"
done < <(sed -n '/^func usage()/,/^}/p' "${ROOT}/engine/cmd/open-couch-engine/main.go" \
         | grep -oE '^  [a-z-]+ ' | tr -d ' ' | sort -u)

# 3. Todos os catálogos carregam o mesmo conjunto de ids.
#
# Um id que falta num catálogo não falha em lugar nenhum: o Qt cai no próprio id
# e o usuário lê `dashboard.logs` na tela, naquele idioma e só nele.
base="${ROOT}/app/translations/opencouch_en.ts"
base_ids="$(grep -oE 'id="[^"]+"' "$base" | sort -u)"
for catalog in "${ROOT}"/app/translations/opencouch_*.ts; do
    [[ "$catalog" == "$base" ]] && continue
    if ! diff -q <(printf '%s\n' "$base_ids") \
                 <(grep -oE 'id="[^"]+"' "$catalog" | sort -u) >/dev/null; then
        printf 'traduções: %s diverge de opencouch_en.ts:\n' "$(basename "$catalog")" >&2
        diff <(printf '%s\n' "$base_ids") \
             <(grep -oE 'id="[^"]+"' "$catalog" | sort -u) | sed 's/^/  /' >&2
        failures=$((failures + 1))
    fi
done

# 4. Nada em hicolor/scalable.
#
# O spec do icon theme prefere scalable a qualquer tamanho fixo, então um SVG
# esquecido ali vence os PNGs e traz de volta o ícone anterior -- sem erro, sem
# aviso, e sem nada no diff que pareça errado.
if compgen -G "${ROOT}/packaging/icons/hicolor/scalable/*" >/dev/null; then
    fail "há arquivo em packaging/icons/hicolor/scalable/, que venceria os PNGs por tamanho"
fi

if (( failures )); then
    printf '\n%d problema(s). Corrija o AGENTS.md (ou os catálogos) na mesma mudança.\n' "$failures" >&2
    exit 1
fi
printf 'AGENTS.md e catálogos conferem.\n'
