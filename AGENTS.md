# AGENTS.md

Guia de integração para agentes de IA que trabalham neste repositório.

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

- `src/main.cpp` — bootstrap: instância única (QLocalServer), tradutores, engine QML, context properties (`backend`, `displaySettingsModel`, `appInfo`).
- `src/backend.{h,cpp}` — ponte QML↔engine. Expõe `Q_INVOKABLE`s para todas as ações (play, restore, status, logs, autostart, engine install). Roda o engine de forma síncrona (`runSync`) ou assíncrona (`runEngineAsync`).
- `src/engineclient.{h,cpp}` — constrói a linha de comando do engine (usa `flatpak-spawn --host` dentro de Flatpak), versão e instalação do engine empacotado em `~/.local/bin`.
- `src/configstore.{h,cpp}` — config (`config.env`), autostart (desktop entry / portal Background), `backgroundOnClose`, onboarding.
- `src/displaysettingsmodel.{h,cpp}` — modelo de settings usado pela tela de configuração.
- `src/displaysettingsvalidator.{h,cpp}` — valida DESK_OUTPUT/TV_OUTPUT/scale/pos antes de salvar.
- `src/appinfomodel.{h,cpp}` — nome, versão e URL do script de instalação.
- `qml/` — `main.qml`, `SetupPage.qml`, `DashboardPage.qml`, `OnboardingSheet.qml` (Kirigami, `QtQuick.Controls`).
- `translations/` — catálogos Qt Linguist (`.ts`); `opencouch_en.ts` é o catálogo base.

### backend/ — engine

- `open-couch-engine` — script bash (com `set -euo pipefail`). Comandos: `play`, `restore`, `status`, `outputs`, `check`, `version`, `watch`, `config-path`, `log`, `clear-log`, `log-history`, `print-history-log`, `export-history-log`, `export-log`. Dependências de host: `jq`, `kscreen-doctor`, `pgrep`; opcional: `wmctrl`. Opção de config `EXIT_ON_ALL_CONTROLLERS_OFF`: quando habilitada, o modo sala encerra o Big Picture e restaura o desktop quando todos os controles são desligados (após 10s de debounce e mínimo de 1 minuto de uso de controle na sessão; detecção via `/dev/input/js*`).
- `open-couch-log-viewer` — abre `konsole` com status + log em modo live.
- `SHA256SUMS` — checksums usados pelo instalador remoto.

Runtime do engine:
- Config: `${XDG_CONFIG_HOME:-~/.config}/open-couch-engine/config.env`
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

## Traduções

- Mensagens de UI usam IDs estáveis: `qsTrId("dominio.chave")` em QML e `qtTrId("dominio.chave")` em C++.
- **Nunca usar frases como chave** — o texto traduzido vive apenas nos catálogos `.ts`.
- `opencouch_en.ts` é o catálogo base; os demais (`pt_BR`, `en_GB`, `de_DE`, `es_ES`, `fr_FR`, `zh_CN`) contêm as traduções.
- Para adicionar idioma: copiar `opencouch_en.ts` → `opencouch_<locale>.ts`, traduzir só os `<translation>`, adicionar à lista `TS_FILES` em `app/CMakeLists.txt` e rebuildar. Ver `app/translations/README.md`.

## Convensões de código

- C++17, `#pragma once` em headers, QString/QVariant como tipos de interface, `Q_OBJECT`/`Q_PROPERTY`/`Q_INVOKABLE` para a ponte QML.
- Bash com `set -euo pipefail`, funções documentadas, logs via função `log` do engine.
- Não adicionar comentários desnecessários; seguir o estilo existente dos arquivos vizinhos.
- Sempre verificar o framework existente antes de assumir bibliotecas (ex.: Kirigami, Qt6).
- Mensagens de commit em inglês, estilo convencional (ex.: `feat:`, `fix:`, `refactor:`, `docs:`), acompanhando o histórico existente.

## Testes e verificação

- **Não há suíte de testes nem lint/typecheck** no repositório.
- Validação padrão: compilar com o CMake (via distrobox) e conferir que o build passa.
- Para mudanças no engine: executar `bash -n backend/open-couch-engine` para checar sintaxe e, se possível, rodar `open-couch-engine status`/`outputs` num host com os requisitos.
- Após alterações no engine que exigem nova versão mínima, atualizar `kMinEngineVersion`.

## Fluxo de trabalho recomendado para agentes

1. Entender a mudança dentro da divisão app/backend/packaging (a lógica de display fica no engine, não na GUI).
2. Implementar seguindo as convenções acima.
3. Validar com build (distrobox) e `bash -n` no engine.
4. Nunca versionar manualmente; apontar para `packaging/release.sh` quando o release for o objetivo.
5. Nunca fazer commit ou push sem pedido explícito do usuário.
6. Manter este arquivo atualizado: se a mudança afetar o que está documentado (build, versionamento, traduções, arquitetura, comandos), atualizar o AGENTS.md na mesma mudança e avisar o usuário o que e porquê alterou.