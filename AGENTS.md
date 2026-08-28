# AGENTS.md

Guia de integração para agentes de IA que trabalham neste repositório.

## Referência rápida

- **Nunca** editar versão manualmente → use sempre `packaging/release.sh X.Y.Z`.
- **Nunca** fazer commit ou push sem pedido explícito do usuário.
- Host é Arch Linux (toolchain instalada direto no sistema, sem distrobox/container).
- Editar o engine em `backend/lib/`, `backend/drivers/` e `backend/dispatcher.sh` — **nunca** em `backend/open-couch-engine`, que é gerado. Depois: `bash packaging/build-engine.sh` (já roda `bash -n` no resultado).
- Lógica de exibição/monitor vive no **engine bash** (`backend/`), não na GUI (`app/`).
- Se a mudança tocar em algo documentado aqui (build, versionamento, traduções, arquitetura), **atualize este arquivo na mesma mudança**.

```sh
# Build (host Arch)
cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Release -DINSTALL_ENGINE_BUNDLE=ON
cmake --build app-build --parallel "$(nproc)"

# Regenerar o engine a partir das fontes (valida sintaxe e versões)
bash packaging/build-engine.sh

# Release (cria tag; push separado)
packaging/release.sh X.Y.Z && git push origin main --tags
```

> Bloco acima é só referência rápida — detalhes completos em **Build**, **Versionamento** e **Armadilhas conhecidas** abaixo.

## Visão geral

Open Couch é um aplicativo Linux (KDE Plasma e Hyprland) que alterna o layout de monitores entre a mesa e a TV da sala com um clique, lança o Steam Big Picture e restaura o layout do desktop automaticamente quando o jogo termina. Licença GPL-3.0-or-later. Repositório: `GustavoBelo/OpenCouch` (branch `main`).

O projeto é dividido em três partes:

| Caminho | Papel |
|---|---|
| `app/` | GUI em Qt6 + Kirigami (C++17 + QML). Ponte entre a UI e o engine. |
| `backend/` | O "engine": scripts bash que controlam os displays e monitoram o Steam. |
| `packaging/` | Scripts de release, Flatpak, instalador host e metadados AppStream. |

A GUI é apenas uma camada: toda a lógica de exibição vive no engine bash (`backend/open-couch-engine`), que é invocado pela aplicação via `QProcess`.

## Arquitetura

### app/ — GUI Qt6/QML

- `src/main.cpp` — bootstrap: instância única (QLocalServer), **estilo QtQuick Controls + tema de ícones**, tradutores, engine QML, context properties (`backend`, `displaySettingsModel`, `appCleanupModel`, `appInfo`).
  - **Instância única se anuncia.** Se já houver instância, o segundo lançamento manda `WAKEUP`, **imprime no stderr o pid e o caminho da instância viva** e sai com 0. Sair calado fazia isso parecer "o build não pegou" — já custou duas rodadas de depuração. A flag **`--replace`** encerra a instância existente (SIGTERM, SIGKILL como último recurso) e assume o lugar.
  - O servidor grava `${TMPDIR:-/tmp}/OpenCouchInstance.info` (pid, executável, `$APPIMAGE`) ao lado do socket. **Não faz parte do protocolo IPC** — é lido de fora, então funciona mesmo com a instância travada. Arquivo órfão é inofensivo: o pid é validado com `kill(pid, 0)` antes de qualquer uso.
  - Dentro do AppImage, `applicationFilePath()` aponta para `/tmp/appimage_extracted_*`; por isso o info file guarda também `$APPIMAGE`, que é o caminho que o usuário reconhece.
  - Se `server.listen()` falhar, o app **avisa** e segue: sem isso a proteção de instância única fica desligada em silêncio. Causa típica: caminho de temp longo demais para socket unix (`sun_path` tem ~107 bytes) — acontece ao isolar testes com `TMPDIR` dentro de um diretório fundo.
  - **`configureQuickStyle()` é obrigatório fora do KDE.** O Kirigami escolhe o plugin de tema pelo *nome do estilo QQC2* (carrega `plugins/kf6/kirigami/platform/<estilo>.so`), e só existe `org.kde.desktop.so`. Com qualquer outro estilo o Kirigami cai num `BasicTheme` claro fixo que ignora o sistema. O Plasma exporta `QT_QUICK_CONTROLS_STYLE` na sessão — por isso só funcionava no KDE. Roda **antes** de criar o `QQmlApplicationEngine`.
  - **`configureIconTheme()` decide por cobertura, não por vazio.** Toda a UI usa nomes Breeze (`overflow-menu`, `help-hint`, `help-donate`, `text-x-log`…). Testar `QIcon::themeName().isEmpty()` é inútil: fora do Plasma ele vem preenchido (`hicolor`, `Adwaita`, `Yaru-*`), e nenhum desses tem esses nomes. O teste correto é `QIcon::hasThemeIcon("overflow-menu")`.
  - `systemPrefersDark()` desembrulha `QDBusVariant` **em laço**: `org.freedesktop.portal.Settings.Read` devolve variante dentro de variante, e um único unwrap faz `toUInt()` falhar em silêncio.
  - **Não** sobrescrever a `QPalette` com cores fixas: QQC2/Kirigami leem `Kirigami.Theme`, não a paleta, então isso não conserta nada e ainda substitui o esquema de cores do usuário no KDE.
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
  - **`Kirigami.Theme.separatorColor` não existe** no KF6. Use `page.safeSeparatorColor`, derivado de `Kirigami.Theme.textColor` com alfa (funciona em tema claro e escuro).
  - `main.qml` só **sugere** desk/TV no primeiro run (`suggestOutputs()`, heurística determinística: HDMI, depois maior resolução) e passa a sugestão ao `SetupPage` via a property `suggestion`. Nunca grava config sozinho nem pula o Setup — escolher a saída errada como "mesa" apagaria a tela que o usuário está olhando.
  - `SetupPage` consome `backend.capabilities()` para avisar quando o compositor não suporta autostart por `.desktop` ou não tem bandeja do sistema.
- `translations/` — catálogos Qt Linguist (`.ts`); `opencouch_en.ts` é o catálogo base.

### backend/ — engine

O engine é um **dispatcher + drivers de compositor plugáveis**. `backend/dispatcher.sh` é a fonte: em desenvolvimento ele faz `source` de `lib/` e `drivers/` e roda direto. Para distribuição (AppImage/Flatpak/instalador), `packaging/build-engine.sh` concatena tudo em um único `backend/open-couch-engine` — o mesmo artefato de sempre, `SHA256SUMS`/`install.sh`/`kMinEngineVersion` não mudam de forma.

> **`backend/open-couch-engine` é GERADO.** Não edite. O build lê apenas as fontes e nunca a própria saída; o CI (`.github/workflows/release.yml`) falha se o artefato commitado divergir delas.

Estrutura de origem:
- `backend/dispatcher.sh` — parsing de comando + `main()` (fonte do dispatcher)
- `backend/lib/common.sh` — funções compartilhadas (log, config, state, sessão, controles, cleanup, helpers jq)
- `backend/lib/detect.sh` — detecção de compositor (`detect_compositor()`, `load_driver()`)
- `backend/drivers/kde.sh` — driver KDE Plasma (kscreen-doctor, wmctrl, konsole)
- `backend/drivers/hyprland.sh` — driver Hyprland (hyprctl, sem wmctrl)
- `backend/drivers/gnome.sh` — stub GNOME (não implementado, falha graciosamente)
- `backend/drivers/generic.sh` — fallback X11 genérico (xrandr, sem管理 de layout)

Contrato do driver (cada `drivers/<nome>.sh` implementa):
- `driver_check_deps()` — imprime `nome:comando:presente|ausente` por linha
- `driver_capabilities_json()` — JSON com capacidades declaradas (evita "parece que funciona mas não funciona")
- `driver_list_outputs_json()` — saídas normalizadas (independente de compositor)
- `driver_get_layout_json()` — snapshot do layout atual (formato interno do compositor)
- `driver_apply_layout(json)` — aplica layout
- `driver_window_action(action, class_regex)` — focus|close|is_open, best-effort
- `driver_open_terminal(cmd)` — abre terminal com comando
- `driver_play()` / `driver_restore()` / `driver_watch()` — fluxo de alto nível
- `driver_switch_to_tv()` / `driver_restore_layout()` — aplicação de layout
- `driver_big_picture_window_present()` / `driver_close_big_picture()` — detecção/fechamento do Big Picture

**REGRA CRÍTICA: toda função de topo em `drivers/*.sh` precisa levar o prefixo do driver** (`kde_`, `hyprland_`, `gnome_`, `generic_`). Tudo é concatenado num único arquivo bash, então uma função sem prefixo sobrescreve silenciosamente a implementação compartilhada de `lib/common.sh` **para todos os compositores** — foi assim que o driver Hyprland sequestrou a detecção de Big Picture do KDE. `packaging/build-engine.sh` falha o build se isso acontecer.

`load_driver()` (`lib/detect.sh`) resolve cada `driver_<fn>` em três níveis: `<prefixo>_<fn>` → `default_<fn>` (implementação compartilhada em `lib/common.sh`) → stub que loga erro e retorna 1. Nenhum nome `driver_*` fica indefinido.

Comandos core do dispatcher: `play`, `restore`, `status`, `outputs`, `check`, `version`, `watch`, `detect`, `capabilities`, `config-path`, `log`, `append-log`, `clear-log`, `log-history`, `print-history-log`, `export-history-log`, `export-log`, `close-tracked-apps`; legados `list-running`/`list-apps` mantidos só para CLI/host fallback.

Compositores suportados: KDE Plasma (completo), Hyprland (funcional, com ressalvas abaixo), GNOME (stub), X11 genérico (limitado). Detecção via `HYPRLAND_INSTANCE_SIGNATURE` → `XDG_CURRENT_DESKTOP` → `XDG_SESSION_TYPE`.

**Hyprland — como o layout é aplicado.** Versões com o parser de config em Lua (0.5x+) **recusam** `hyprctl keyword monitor` com `keyword can't work with non-legacy parsers. Use eval.` — e ainda saem com status 0, ou seja, a mudança falha em silêncio. O driver detecta isso uma vez por execução (`hyprland_monitor_api`) e usa:

```sh
hyprctl eval 'hl.monitor({ output = "DP-1", mode = "1920x1080@300", position = "0x0", scale = 1 })'
hyprctl eval 'hl.monitor({ output = "HDMI-A-1", disabled = true })'
```

caindo no `keyword` legado só em builds antigas. O resultado é sempre verificado relendo `hyprctl -j monitors all`. A API detectada aparece em `capabilities` → `display.monitor_api`.

Detalhes que já causaram bug e não devem regredir:
- **Posição é `XxY` no Hyprland**, mas o `layout.env` guarda `X,Y` (formato compartilhado com o KDE). Converta sempre com `hyprland_position()`.
- **`fullscreen`/`fullscreenClient` de `hyprctl clients -j` são inteiros**, não booleanos. `.fullscreen == true` nunca casa.
- **`hyprctl` reporta `connected: true` para tudo**; o estado real vem de `/sys/class/drm/*/status`.
- **Monitor desativado reporta `0x0@<taxa>`** — nunca reinjete isso como modo.
- Hyprland não tem conceito de saída primária: `priority` é `null` e `verify_primary_output` não se aplica.

Dependências de host variam por compositor:
- KDE: `jq`, `kscreen-doctor`, `pgrep`; opcional: `wmctrl`
- Hyprland: `jq`, `hyprctl`, `pgrep`
- `open-couch-log-viewer` usa `xdg-terminal-exec` ou detecta terminal disponível (não depende mais de `konsole`). A flag de comando varia por terminal: `xdg-terminal-exec` recebe direto, `gnome-terminal` usa `--`, `wezterm` usa `start --`, o resto usa `-e`.

- O `status` registra no log os componentes ausentes (obrigatórios como `ERROR`, opcionais como `WARNING`); o app usa `append-log` para persistir eventos próprios no arquivo (ex.: falha do watcher).
- **`EXIT_ON_ALL_CONTROLLERS_OFF`** (opção de config): quando habilitada, o modo sala encerra o Big Picture e restaura o desktop quando todos os controles são desligados.
  - Debounce de 10s antes de agir.
  - Exige mínimo de 1 minuto de uso de controle na sessão.
  - Detecção via `/dev/input/js*`.
- **Controle de recursos** — `CLOSE_APPS_ENABLED` / `CLOSE_APPS_WAIT_SECONDS` / `APPS_TO_CLOSE` (lista separada por vírgula):
  - Quando habilitado, o `play` aguarda o tempo configurado após o Big Picture abrir e encerra os apps listados via `pkill -x`.
  - Processos em `PROTECTED_PROCESSES` **nunca** são fechados nem aparecem nas listas. A lista cobre KDE **e** Hyprland (`Hyprland`, `waybar`, `hyprpaper`, `hyprlock`, `uwsm`, portais…) e precisa ficar em sincronia com `kProtectedProcesses` em `app/src/appcleanupmodel.cpp`.
- A GUI **não usa mais** `list-running`/`list-apps` do engine: `AppCleanupModel` faz tudo nativo em C++ (ver acima) e só usa `close-tracked-apps` do engine.
- `open-couch-log-viewer` — abre `konsole` com status + log em modo live.
- `SHA256SUMS` — checksums usados pelo instalador remoto.

Runtime do engine:
- Config: `${XDG_CONFIG_HOME:-~/.config}/open-couch-engine/config.env` (inclui `CLOSE_APPS_ENABLED`, `CLOSE_APPS_WAIT_SECONDS`, `APPS_TO_CLOSE`)
- Estado: `${XDG_STATE_HOME:-~/.local/state}/open-couch-engine/` (`layout.env` snapshot, `session.pid`, logs, `history/`)

### packaging/

- `release.sh` — **única forma autorizada de versionar** (ver abaixo).
- `build-engine.sh` — concatena `lib/` + `drivers/` + `dispatcher.sh` em um único `backend/open-couch-engine`. Chamado por `release.sh` e `build-appimage.sh`. Também **sincroniza as versões** (`ENGINE_VERSION` de `app/version.txt`, `MIN_VERSION` de `kMinEngineVersion`) dentro de `backend/lib/common.sh`, para que um rebuild nunca reverta o que o release gravou. Falha o build se algum driver definir função de topo sem prefixo.
- `AppRun` — o `AppRun` do AppImage, **fonte única** usada tanto por `build-appimage.sh` quanto pelo `release.yml`, instalado via `linuxdeploy --custom-apprun` na passada de empacotamento (antes era um heredoc duplicado nos dois; a versão no YAML chegou a quebrar o parsing do workflow).
- `build-flatpak.sh` — build local do Flatpak.
- `build-appimage.sh` — build local do AppImage (replica o `release.yml`; roda no host Arch direto — `packaging/build-appimage.sh`).
- `io.github.gustavobelo.opencouch.yml` — manifest Flatpak (tag sincronizada pelo release.sh).
- `io.github.gustavobelo.opencouch.metainfo.xml` — metadados AppStream.
- `host/install.sh` — instalador do engine no host (local ou via curl com verificação SHA256).
- `icons/`, `screenshots/`, `video/`.

## Build

O host é Arch Linux e a toolchain roda direto no sistema (sem distrobox/container).

```sh
# Configurar build (apenas uma vez ou quando mudar de opções)
cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Release -DINSTALL_ENGINE_BUNDLE=ON

# Compilar
cmake --build app-build --parallel "$(nproc)"
```

Dependências de build: Qt6 (Core, Gui, Widgets, Qml, Quick, QuickControls2, DBus, LinguistTools), KF6 Kirigami, ECM, C++17, CMake ≥ 3.16, ninja.

Pacotes Arch sugeridos (confirme os nomes no seu sistema — `pacman -Qqe` lista o que está instalado):

- Toolchain: `cmake`, `ninja`, `gcc`
- Qt6: `qt6-base`, `qt6-declarative`, `qt6-wayland`, `qt6-svg`, `qt6-tools` (lupdate/lrelease)
- KF6: `kirigami`, `ki18n`, `kwindowsystem`, `extra-cmake-modules`
- AppImage: `patchelf`, `wget`, `fuse2` (ou `fuse3`)

Para buildar o AppImage localmente no Arch:

```sh
packaging/build-appimage.sh
# gera OpenCouch-x86_64.AppImage na raiz do projeto
```

Build do AppImage na **CI** (`.github/workflows/release.yml`) continua rodando em `fedora:latest`, que é o ambiente oficial de release.

## Versionamento (CRÍTICO)

A versão é sincronizada em **vários arquivos** e não deve ser editada manualmente:

- `app/version.txt` (`VERSION=`, `RELEASE_DATE=`)
- `ENGINE_VERSION` e `MIN_VERSION` em `backend/lib/common.sh` (escritos por `build-engine.sh`, que os lê de `app/version.txt` e de `kMinEngineVersion`; o `release.sh` apenas verifica). **Nunca** editar o artefato `backend/open-couch-engine`.
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
- Validação padrão: compilar com o CMake direto no host, conferir que o build passa e pedir ao usuário para testar na prática.
- **Ao testar uma build nova da GUI, encerre a instância anterior.** Uma instância viva segura o socket de instância única e o lançamento novo apenas traz a janela *antiga* para frente — indistinguível de "o build não pegou". O app agora avisa, e `--replace` resolve:
  ```sh
  ./OpenCouch-x86_64.AppImage --replace   # encerra a anterior e assume
  ./app-build/opencouch --replace
  ```
  Para rodar duas builds lado a lado, isole com um `TMPDIR` **curto** (`TMPDIR=/tmp/oc-t`), nunca um caminho fundo.
- Para mudanças no engine: `bash packaging/build-engine.sh` (regenera, valida sintaxe e a regra de prefixo dos drivers) e, se possível, rodar `open-couch-engine detect`/`capabilities`/`outputs`/`check` num host com os requisitos.
- Uma mudança que toque em qualquer driver ou em `lib/common.sh` **precisa ser testada nos dois compositores**, ou pelo menos ter o impacto no outro analisado explicitamente. O código é compartilhado num único arquivo e regressões cruzadas são silenciosas.
- Checagens rápidas que pegam as regressões já vistas:
  ```sh
  # nenhuma função de driver sem prefixo (sequestraria os outros compositores)
  for f in backend/drivers/*.sh; do d=$(basename "$f" .sh); \
    grep -nE '^[a-z_][a-z0-9_]*\(\) *\{' "$f" | grep -vE ":${d}_" && echo "VAZANDO: $f"; done

  # nenhuma chamada a função removida (o `|| true` esconde `command not found`)
  grep -n "restore_layout" backend/lib/common.sh   # só driver_restore_layout
  ```
- Após alterações no engine que exigem nova versão mínima, atualizar `kMinEngineVersion`.

## Armadilhas conhecidas e validações do `release.sh`

Verificadas por leitura direta de `packaging/release.sh` — o script agora **mitiga** cada ponto abaixo com validação + `exit 1`:

- **`sed -i` com verificação pós-substituição.** As substituições de `SELF_VERSION` (`packaging/release.sh:49`), `ENGINE_VERSION` (`packaging/release.sh:55`) e `tag:` (`packaging/release.sh:64`) usam `sed -i` com padrões fixos (ex.: `^SELF_VERSION="[^"]*"`). `sed` não retorna erro quando o padrão não casa — `set -e` não pega. O script agora faz `grep -q` do valor esperado após cada `sed` e aborta com erro se a substituição não ocorreu, evitando arquivo dessincronizado silencioso.
- **`MIN_VERSION` validado após extração.** O script lê `kMinEngineVersion` de `app/src/engineclient.cpp:13` via regex (`packaging/release.sh:71`). Agora valida que o valor não está vazio e que casa `X.Y.Z`; se o padrão não bater (nome da variável mudou, formato C++ mudou), aborta em vez de inserir `MIN_VERSION=""` no engine. A inserção também é verificada com `grep -q`.
- **Indentação do `tag:` no manifest Flatpak ainda é hardcoded.** A substituição `s/^  *tag: v.*/    tag: ${TAG}/` (`packaging/release.sh:64`) sempre escreve 4 espaços. Continua frágil se a estrutura YAML mudar, mas agora o script verifica com `grep -q "tag: ${TAG}"` e aborta se não encontrar — um manifest mal indentado não passa silenciosamente.
- **Checagem de branch `main`.** O script agora confere `git rev-parse --abbrev-ref HEAD` (`packaging/release.sh:33`) e aborta se não estiver em `main`, garantindo que tags `vX.Y.Z` nunca sejam criadas em branches de feature (alinhado à **Estratégia de branch** abaixo).
- **`appstreamcli validate` bloqueante e antes do commit.** Antes, a validação rodava *depois* do `git commit` e só emitia `Warning:` — o commit já ficava no histórico. Agora o script valida o metainfo renderizado (`packaging/release.sh:98`) **antes** de `git add`/`commit`/`tag`; se `appstreamcli` estiver disponível e falhar, aborta sem criar commit/tag. Se `appstreamcli` não estiver instalado, mantém `Warning` e segue (único caso não-bloqueante).

## Armadilhas por compositor (aprendidas na marra)

Cada item abaixo já foi um bug real nesta base de código. São silenciosos: nada falha, o comportamento só some.

| Armadilha | Sintoma | Regra |
|---|---|---|
| Função de driver sem prefixo | Um compositor passa a usar a implementação de outro | Todo símbolo de topo em `drivers/*.sh` leva o prefixo do driver. O build valida. |
| `cmd >/dev/null 2>&1 \|\| true` em torno de uma função | `command not found` engolido; a ação nunca acontece | Não silencie chamadas de driver; logue a falha. |
| `hyprctl` sai 0 mesmo recusando | Layout nunca aplicado, engine reporta sucesso | Inspecione a saída, não o status; releia `hyprctl -j monitors all` para confirmar. |
| `QIcon::themeName()` não vazio ≠ ícones presentes | UI sem ícone nenhum fora do KDE | Teste `hasThemeIcon()` de um nome Breeze real. |
| Estilo QQC2 não definido | UI ignora o tema do sistema fora do KDE | `QQuickStyle::setStyle()` antes de criar o engine QML. |
| Plugin não linkado não é rastreado pelo linuxdeploy | AppImage sem tema | Copie `plugins/kf6/kirigami/platform/` e o fecho KF6 explicitamente. |
| Heredoc em coluna 0 dentro de `run: \|` | Workflow inteiro deixa de parsear | Arquivos como o `AppRun` ficam no repositório, não em heredoc. |
| Mexer no AppDir depois de `--output appimage` | Mudança nunca chega ao artefato | O linuxdeploy empacota na mesma chamada. Use duas passadas: deploy → extras → empacotamento. |
| Copiar lib para `usr/lib` antes do linuxdeploy | Sumiu do AppImage | Ele **poda** `usr/lib` para o que rastreou. Extras entram entre as duas passadas. |
| `cp -a` de `libFoo.so.6` | Symlink quebrado no AppImage | É symlink de soname; use `cp -aL`. |
| `/usr/lib64` no Arch | `find -maxdepth 1` não acha nada | É symlink para `/usr/lib`; resolva com `readlink -f`. |
| Instância única saindo calada | Parece que o build não pegou | O handoff precisa dizer para quem passou. Use `--replace` ao testar build nova. |
| `TMPDIR` fundo em teste | `listen()` falha, dois apps sobem juntos | Socket unix cabe em ~107 bytes; use caminho curto (`/tmp/oc-t`). |

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
3. Validar com build (host Arch) e `bash -n` no engine; testar manualmente se a mudança afeta comportamento visível.
4. Nunca versionar manualmente; para releases seguir **Publicação de release — boa prática** (`packaging/release.sh` + push + GitHub Release idempotente).
5. Nunca fazer commit ou push sem pedido explícito do usuário.
6. Manter este arquivo atualizado: se a mudança afetar o que está documentado (build, versionamento, traduções, arquitetura, comandos), atualizar o AGENTS.md na mesma mudança e avisar o usuário o que e porquê alterou.