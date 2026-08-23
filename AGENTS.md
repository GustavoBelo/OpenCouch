# AGENTS.md

Guia de integração para agentes de IA que trabalham neste repositório.

## Referência rápida

- **Nunca** editar versão manualmente → use sempre `packaging/release.sh X.Y.Z`.
- **Nunca** fazer commit ou push sem pedido explícito do usuário.
- Todo build roda dentro do distrobox `fedora` (o host é Silverblue imutável, sem toolchain).
- Antes de mexer no engine: `bash -n backend/open-couch-engine` (não há suíte de testes).
- Lógica de exibição/monitor vive no **engine bash** (`backend/`), não na GUI (`app/`).
- Se a mudança tocar em algo documentado aqui (build, versionamento, traduções, arquitetura), **atualize este arquivo na mesma mudança**.

```sh
# Build
distrobox enter fedora -- bash -c \
  "cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Release -DINSTALL_ENGINE_BUNDLE=ON"
distrobox enter fedora -- bash -c "cmake --build app-build --parallel \$(nproc)"

# Checagem de sintaxe do engine
bash -n backend/open-couch-engine

# Release
packaging/release.sh X.Y.Z && git push origin main --tags
```

> Bloco acima é só referência rápida — detalhes completos em **Build**, **Versionamento** e **Armadilhas conhecidas** abaixo.

## Visão geral

Open Couch é um aplicativo Linux para KDE Plasma que alterna o layout de monitores entre a mesa e a TV da sala com um clique, lança o Steam Big Picture e restaura o layout do desktop automaticamente quando o jogo termina. Licença GPL-3.0-or-later. Repositório: `GustavoBelo/OpenCouch` (branch `main`).

O projeto é dividido em três partes:

| Caminho | Papel |
|---|---|
| `app/` | GUI em Qt6 + Kirigami (C++17 + QML). Ponte entre a UI e o engine. |
| `backend/` | O "engine": scripts bash que controlam os displays e monitoram o Steam. |
| `packaging/` | Scripts de release, Flatpak, instalador host e metadados AppStream. |

A GUI é apenas uma camada: toda a lógica de exibição vive no engine bash (`backend/open-couch-engine`), que é invocado pela aplicação via `QProcess`.

## Arquitetura

### app/ — GUI Qt6/QML

- `src/main.cpp` — bootstrap: instância única (QLocalServer), tradutores, engine QML, context properties (`backend`, `displaySettingsModel`, `appCleanupModel`, `appInfo`).
- `src/backend.{h,cpp}` — ponte QML↔engine. Expõe `Q_INVOKABLE`s para todas as ações (play, restore, status, logs, autostart, engine install). Roda o engine de forma síncrona (`runSync`) ou assíncrona (`runEngineAsync`).
- `src/engineclient.{h,cpp}` — constrói a linha de comando do engine (usa `flatpak-spawn --host` dentro de Flatpak), versão e instalação do engine empacotado em `~/.local/bin`.
- `src/configstore.{h,cpp}` — config (`config.env`), autostart (desktop entry / portal Background), `backgroundOnClose`, onboarding, e chaves de limpeza de apps (`CLOSE_APPS_ENABLED`, `CLOSE_APPS_WAIT_SECONDS`, `APPS_TO_CLOSE`).
- `src/displaysettingsmodel.{h,cpp}` — modelo de settings usado pela tela de configuração.
- `src/displaysettingsvalidator.{h,cpp}` — valida DESK_OUTPUT/TV_OUTPUT/scale/pos antes de salvar.
- `src/appcleanupmodel.{h,cpp}` — modelo de controle de recursos: lista de apps a fechar, tempo de espera e integração com `close-tracked-apps` do engine. Pontos-chave:
  - **Varredura nativa** de `.desktop` via `QStandardPaths`/`QDir`/`QFile`/`QDirIterator`, até depth 2, seguindo symlinks flatpak.
  - **Varredura de processos** via `/proc` + `/proc/<pid>/exe|comm|cmdline`, filtrando `PROTECTED_PROCESSES` e cruzando com os `.desktop` encontrados.
  - **Cache em memória por sessão** (`QMap` lower → displayName/icon).
  - **Carregamento assíncrono**: `QThread::create` + `installedApps`/`runningApps`/`loadingInstalled`/`loadingRunning` + `requestInstalledApplications`/`requestRunningApplications` + `BusyIndicator`.
  - Em Flatpak, usa `/run/host` ou `flatpak-spawn --host open-couch-engine` como fallback.
- `src/appinfomodel.{h,cpp}` — nome, versão e URL do script de instalação.
- `qml/` — `main.qml`, `SetupPage.qml`, `DashboardPage.qml`, `OnboardingSheet.qml`, `ChooseAppDialog.qml`, `RunningAppsDialog.qml` (Kirigami, `QtQuick.Controls`).
- `translations/` — catálogos Qt Linguist (`.ts`); `opencouch_en.ts` é o catálogo base.

### backend/ — engine

- `open-couch-engine` — script bash (com `set -euo pipefail`). Comandos core: `play`, `restore`, `status`, `outputs`, `check`, `version`, `watch`, `config-path`, `log`, `append-log`, `clear-log`, `log-history`, `print-history-log`, `export-history-log`, `export-log`, `close-tracked-apps`; legados `list-running`/`list-apps` mantidos só para CLI/host fallback.
- Dependências de host: `jq`, `kscreen-doctor`, `pgrep`; opcional: `wmctrl` (apenas para posicionar/fechar janelas X11 do Steam — não funciona em sessões Wayland puras).
- O `status` registra no log os componentes ausentes (obrigatórios como `ERROR`, opcionais como `WARNING`); o app usa `append-log` para persistir eventos próprios no arquivo (ex.: falha do watcher).
- **`EXIT_ON_ALL_CONTROLLERS_OFF`** (opção de config): quando habilitada, o modo sala encerra o Big Picture e restaura o desktop quando todos os controles são desligados.
  - Debounce de 10s antes de agir.
  - Exige mínimo de 1 minuto de uso de controle na sessão.
  - Detecção via `/dev/input/js*`.
- **Controle de recursos** — `CLOSE_APPS_ENABLED` / `CLOSE_APPS_WAIT_SECONDS` / `APPS_TO_CLOSE` (lista separada por vírgula):
  - Quando habilitado, o `play` aguarda o tempo configurado após o Big Picture abrir e encerra os apps listados via `pkill -x`.
  - Processos em `PROTECTED_PROCESSES` **nunca** são fechados nem aparecem nas listas.
- A GUI **não usa mais** `list-running`/`list-apps` do engine: `AppCleanupModel` faz tudo nativo em C++ (ver acima) e só usa `close-tracked-apps` do engine.
- `open-couch-log-viewer` — abre `konsole` com status + log em modo live.
- `SHA256SUMS` — checksums usados pelo instalador remoto.

Runtime do engine:
- Config: `${XDG_CONFIG_HOME:-~/.config}/open-couch-engine/config.env` (inclui `CLOSE_APPS_ENABLED`, `CLOSE_APPS_WAIT_SECONDS`, `APPS_TO_CLOSE`)
- Estado: `${XDG_STATE_HOME:-~/.local/state}/open-couch-engine/` (`layout.env` snapshot, `session.pid`, logs, `history/`)

### packaging/

- `release.sh` — **única forma autorizada de versionar** (ver abaixo).
- `build-flatpak.sh` — build local do Flatpak.
- `build-appimage.sh` — build local do AppImage (replica o `release.yml`; rodar dentro do distrobox `fedora` via `distrobox enter fedora -- bash -c "packaging/build-appimage.sh"`).
- `io.github.gustavobelo.opencouch.yml` — manifest Flatpak (tag sincronizada pelo release.sh).
- `io.github.gustavobelo.opencouch.metainfo.xml` — metadados AppStream.
- `host/install.sh` — instalador do engine no host (local ou via curl com verificação SHA256).
- `icons/`, `screenshots/`, `video/`.

## Build

O host é um Fedora Silverblue imutável sem toolchain. **Todo build roda dentro do distrobox `fedora`.**

```sh
# Configurar build (apenas uma vez ou quando mudar de opções)
distrobox enter fedora -- bash -c \
  "cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Release -DINSTALL_ENGINE_BUNDLE=ON"

# Compilar
distrobox enter fedora -- bash -c "cmake --build app-build --parallel \$(nproc)"
```

Dependências de build: Qt6 (Core, Gui, Widgets, Qml, Quick, QuickControls2, DBus, LinguistTools), KF6 Kirigami, ECM, C++17, CMake ≥ 3.16, ninja.

Dica: `distrobox enter fedora` demora; prefira `distrobox enter fedora -- bash -c "..."` para executar um comando só.

## Versionamento (CRÍTICO)

A versão é sincronizada em **vários arquivos** e não deve ser editada manualmente:

- `app/version.txt` (`VERSION=`, `RELEASE_DATE=`)
- `ENGINE_VERSION` e `MIN_VERSION` em `backend/open-couch-engine`
- `SELF_VERSION` em `packaging/host/install.sh`
- `tag:` no manifest `packaging/io.github.gustavobelo.opencouch.yml`
- `kMinEngineVersion` em `app/src/engineclient.cpp` (fonte do `MIN_VERSION` do engine)

**Para lançar uma versão, rode sempre:**

```sh
packaging/release.sh X.Y.Z
```

que valida a versão, verifica árvore limpa, sincroniza todos os arquivos, regenera `SHA256SUMS`, valida o metainfo com `appstreamcli`, faz commit e cria a tag `vX.Y.Z`. Depois: `git push origin main --tags`.

Ao alterar o engine de forma que exija reinstalação do usuário, **bumpe `kMinEngineVersion`** em `app/src/engineclient.cpp` (o release.sh copia esse valor para `MIN_VERSION` do engine). O build do AppImage é feito pela CI (`.github/workflows/release.yml`) ao dar push de uma tag `v*`.

## Publicação de release — boa prática

Fluxo completo após `packaging/release.sh` + `git push`. **Release notes sempre em inglês**; este arquivo permanece em PT-BR.

### 1. Pré-voo

```sh
git status --porcelain  # limpo
git tag --sort=-v:refname | head
grep -n kMinEngineVersion app/src/engineclient.cpp  # fonte de MIN_VERSION
cat app/version.txt
bash -n backend/open-couch-engine
```

### 2. Versionar (único caminho)

```sh
packaging/release.sh X.Y.Z
# valida X.Y.Z, tag inexistente, árvore limpa,
# atualiza app/version.txt (RELEASE_DATE=date -u), SELF_VERSION,
# ENGINE_VERSION, manifest tag, MIN_VERSION (de kMinEngineVersion),
# regenera backend/SHA256SUMS, valida metainfo/next
git log --oneline -2 && git show --stat HEAD
sha256sum -c backend/SHA256SUMS
```

Revisar `app/version.txt:1`, `backend/open-couch-engine:5-6`, `packaging/host/install.sh:5`, `packaging/io.github.gustavobelo.opencouch.yml:30`.

### 3. Push da tag

```sh
git push origin main --tags
# dispara .github/workflows/release.yml:135-153 (Build AppImage + Create GitHub Release)
```

### 4. Release notes

```sh
PREV=$(git tag --sort=-v:refname | sed -n '2p')
git log $PREV..HEAD --oneline --no-merges
git log $PREV..HEAD --pretty=format:"%h %s%n%b"
git diff $PREV..HEAD --stat
```

Categorizar em **Highlights / Features / Fixes / Translations / Packaging & Docs / Engine & Versioning**. Incluir sempre `**Full Changelog**: https://github.com/GustavoBelo/OpenCouch/compare/<prev>...vX.Y.Z` e, se `MIN_VERSION` bumpou, instrução de reinstalação (`Refresh Status` → Install ou `packaging/host/install.sh --update`).

Modelo publicado: `v1.7.0` — https://github.com/GustavoBelo/OpenCouch/releases/tag/v1.7.0

### 5. GitHub Release — idempotência (CRÍTICO)

O workflow `release.yml:146-153` é **idempotente**:

```sh
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "OpenCouch-x86_64.AppImage" --clobber  # preserva notes manuais
else
  gh release create "$TAG" "OpenCouch-x86_64.AppImage" --title "Open Couch $TAG" --generate-notes
fi
```

Duas formas válidas:

* **A — Automática (simples):** só `git push origin main --tags`; workflow cria a release com `--generate-notes`. Depois editar se quiser notas detalhadas: `gh release edit vX.Y.Z --notes-file /tmp/release_notes.md`.
* **B — Manual detalhada (usada em v1.7.0):** criar antes do workflow com `gh release create vX.Y.Z --title "Open Couch vX.Y.Z" --notes-file /tmp/release_notes.md --latest`; workflow detecta que a release já existe e apenas faz `upload --clobber` do AppImage, sem sobrescrever as notas. **Não recriar** a tag com `gh release create` após o workflow já ter criado — falhará com `a release with the same tag name already exists`.

Verificação:

```sh
gh release view vX.Y.Z --json tagName,name,body,assets --jq .
gh release list --limit 5
```

### 6. Pós-release

Acompanhar `gh run list --limit 5` e `gh run view <id> --log-failed`. Warnings `screenshot-image-not-found` antes do push são esperados (URLs usam `vX.Y.Z`).

## Traduções

- Mensagens de UI usam IDs estáveis: `qsTrId("dominio.chave")` em QML e `qtTrId("dominio.chave")` em C++.
- **Nunca usar frases como chave** — o texto traduzido vive apenas nos catálogos `.ts`.
- `opencouch_en.ts` é o catálogo base; os demais (`pt_BR`, `en_GB`, `de_DE`, `es_ES`, `fr_FR`, `zh_CN`) contêm as traduções.
- Para adicionar idioma: copiar `opencouch_en.ts` → `opencouch_<locale>.ts`, traduzir só os `<translation>`, adicionar à lista `TS_FILES` em `app/CMakeLists.txt` e rebuildar. Ver `app/translations/README.md`.

## Convenções de código

- C++17, `#pragma once` em headers, QString/QVariant como tipos de interface, `Q_OBJECT`/`Q_PROPERTY`/`Q_INVOKABLE` para a ponte QML.
- Bash com `set -euo pipefail`, funções documentadas, logs via função `log` do engine.
- Não adicionar comentários desnecessários; seguir o estilo existente dos arquivos vizinhos.
- Sempre verificar o framework existente antes de assumir bibliotecas (ex.: Kirigami, Qt6).
- Mensagens de commit em inglês, estilo convencional (ex.: `feat:`, `fix:`, `refactor:`, `docs:`), acompanhando o histórico existente.

## Testes e verificação

- **Não há suíte de testes nem lint/typecheck** no repositório.
- Validação padrão: compilar com o CMake (via distrobox), conferir que o build passa e pedir ao usuário para testar na prática.
- Para mudanças no engine: executar `bash -n backend/open-couch-engine` para checar sintaxe e, se possível, rodar `open-couch-engine status`/`outputs` num host com os requisitos (`jq`, `kscreen-doctor`, `pgrep`).
- Após alterações no engine que exigem nova versão mínima, atualizar `kMinEngineVersion`.

## Armadilhas conhecidas e validações do `release.sh`

Verificadas por leitura direta de `packaging/release.sh` — o script agora **mitiga** cada ponto abaixo com validação + `exit 1`:

- **`sed -i` com verificação pós-substituição.** As substituições de `SELF_VERSION` (`packaging/release.sh:49`), `ENGINE_VERSION` (`packaging/release.sh:55`) e `tag:` (`packaging/release.sh:64`) usam `sed -i` com padrões fixos (ex.: `^SELF_VERSION="[^"]*"`). `sed` não retorna erro quando o padrão não casa — `set -e` não pega. O script agora faz `grep -q` do valor esperado após cada `sed` e aborta com erro se a substituição não ocorreu, evitando arquivo dessincronizado silencioso.
- **`MIN_VERSION` validado após extração.** O script lê `kMinEngineVersion` de `app/src/engineclient.cpp:13` via regex (`packaging/release.sh:71`). Agora valida que o valor não está vazio e que casa `X.Y.Z`; se o padrão não bater (nome da variável mudou, formato C++ mudou), aborta em vez de inserir `MIN_VERSION=""` no engine. A inserção também é verificada com `grep -q`.
- **Indentação do `tag:` no manifest Flatpak ainda é hardcoded.** A substituição `s/^  *tag: v.*/    tag: ${TAG}/` (`packaging/release.sh:64`) sempre escreve 4 espaços. Continua frágil se a estrutura YAML mudar, mas agora o script verifica com `grep -q "tag: ${TAG}"` e aborta se não encontrar — um manifest mal indentado não passa silenciosamente.
- **Checagem de branch `main`.** O script agora confere `git rev-parse --abbrev-ref HEAD` (`packaging/release.sh:33`) e aborta se não estiver em `main`, garantindo que tags `vX.Y.Z` nunca sejam criadas em branches de feature (alinhado à **Estratégia de branch** abaixo).
- **`appstreamcli validate` bloqueante e antes do commit.** Antes, a validação rodava *depois* do `git commit` e só emitia `Warning:` — o commit já ficava no histórico. Agora o script valida o metainfo renderizado (`packaging/release.sh:98`) **antes** de `git add`/`commit`/`tag`; se `appstreamcli` estiver disponível e falhar, aborta sem criar commit/tag. Se `appstreamcli` não estiver instalado, mantém `Warning` e segue (único caso não-bloqueante).

## Estratégia de branch
 
Segue o modelo **GitHub Flow** — simples, adequado a um projeto de porte pequeno/médio com um mantenedor principal, e evita a complexidade de algo como GitFlow (branches `develop`/`release` separadas) que não se justifica aqui.
 
- **`main` é sempre estável e "release-able".** Toda tag de release (`vX.Y.Z`) é criada a partir de `main` — nunca de outra branch.
- **Trabalho novo vai em branch a partir de `main`**, com prefixo indicando o tipo de mudança, alinhado aos tipos de commit já usados no projeto:
  - `feat/<descrição-curta>` — nova funcionalidade
  - `fix/<descrição-curta>` — correção de bug
  - `refactor/<descrição-curta>` — refatoração sem mudança de comportamento
  - `docs/<descrição-curta>` — documentação (README, AGENTS.md, etc.)
  - Exemplo: `fix/wmctrl-wayland-noop`
- **Merge em `main` via Pull Request**, mesmo para o mantenedor único — isso mantém histórico revisável e permite que a CI rode antes do merge. Squash merge é preferível para manter o histórico de `main` limpo (um commit por PR, seguindo o padrão `feat:`/`fix:`/etc. já usado).
- **Nunca commitar diretamente em `main`** para mudanças de código — exceção: os commits automáticos gerados por `packaging/release.sh` (`Release vX.Y.Z`), que fazem parte do próprio fluxo de release e são validados para rodar **apenas em `main`** (`packaging/release.sh:33` — aborta se estiver em outra branch).
- **Branches de feature são de vida curta**: mergear e deletar assim que a mudança for aceita, para não acumular branches obsoletas.
- **Tags (`vX.Y.Z`) nunca são criadas em branches que não sejam `main`** (enforçado por `packaging/release.sh:33`).
Para agentes de IA: isso não muda a regra existente de **nunca fazer commit ou push sem pedido explícito do usuário** — inclusive abrir branch e Pull Request contam como ação que exige pedido explícito, não são assumidos automaticamente a partir de uma tarefa de código.

## Fluxo de trabalho recomendado para agentes

1. Entender a mudança dentro da divisão app/backend/packaging (a lógica de display fica no engine, não na GUI).
2. Implementar seguindo as convenções acima.
3. Validar com build (distrobox) e `bash -n` no engine; testar manualmente se a mudança afeta comportamento visível.
4. Nunca versionar manualmente; para releases seguir **Publicação de release — boa prática** (`packaging/release.sh` + push + GitHub Release idempotente).
5. Nunca fazer commit ou push sem pedido explícito do usuário.
6. Manter este arquivo atualizado: se a mudança afetar o que está documentado (build, versionamento, traduções, arquitetura, comandos), atualizar o AGENTS.md na mesma mudança e avisar o usuário o que e porquê alterou.