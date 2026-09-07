# AGENTS.md

Guia de integração para agentes de IA que trabalham neste repositório.

## Referência rápida

- **Nunca** editar versão manualmente → use sempre `packaging/release.sh X.Y.Z`.
- **Nunca** fazer commit ou push sem pedido explícito do usuário.
- O engine é um **binário Go** em `engine/`. Antes de mexer: `cd engine && go test ./... && go vet ./...`.
- Lógica de sessão/display vive no **engine** (`engine/`), não na GUI (`app/`).
- **Configuração de console é escrita pelo engine, nunca pelo app.** O app chama `tv`, `boot`,
  `controller`; ele não abre o `console.json`. O `ConfigStore` guarda só o que é da GUI
  (autostart, segundo plano, onboarding), em `QSettings`. Escrever config do engine a partir do
  app já custou um recurso inteiro em silêncio: o app gravava num `config.env` que o engine Go
  nunca leu, e a preferência simplesmente não existia.
- O app **não decide modo, resolução, HDR nem VRR** — isso é do gamescope e do Steam.
- Se a mudança tocar em algo documentado aqui (build, versionamento, traduções, arquitetura), **atualize este arquivo na mesma mudança**.

```sh
# Build (o alvo `engine` compila o Go e injeta a versão via -ldflags)
cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Release
cmake --build app-build --parallel "$(nproc)"

# Testes do engine
cd engine && go test ./... && go vet ./...
# ou, pelo ctest, a partir da raiz:
ctest --test-dir app-build --output-on-failure

# A GUI não tem testes; este é o único smoke test que existe.
# Sem warning e sem sair sozinho = o QML carregou.
QT_QPA_PLATFORM=offscreen ./app-build/opencouch

# A documentação confere a si mesma
packaging/check-docs.sh

# Release
packaging/release.sh X.Y.Z && git push origin main --tags
```

> Bloco acima é só referência rápida — detalhes completos em **Build**, **Versionamento** e **Armadilhas conhecidas** abaixo.

## Visão geral

Open Couch entrega a máquina inteira para a sessão gamescope do Steam na TV da sala, e devolve limpo quando o usuário sai. Licença GPL-3.0-or-later. Repositório: `GustavoBelo/OpenCouch` (branch `main`).

Não é um app KDE: o wrapper hospeda qualquer compositor (KDE, Hyprland, GNOME). A única coisa específica de cada desktop é **como pará-lo** — a interface `Compositor` em `engine/internal/console/compositor.go`.

**O modelo é uma sessão de login hospedeira**, não um gamescope aninhado:

```
login manager (SDDM/GDM/greetd/ly/nenhum)
└─ open-couch-engine host-session     ← vive o login inteiro
     ├─ compositor do desktop          Exec= do .desktop escolhido
     └─ start-gamescope-session        o entry com DesktopNames=gamescope
```

Entrar no modo console **encerra a sessão do desktop**. Não existe botão de volta na GUI porque, enquanto o console roda, não existe GUI: o caminho de volta é o "Switch to Desktop" do próprio Steam, ou `open-couch-engine leave` por ssh.

O projeto é dividido em três partes:

| Caminho | Papel |
|---|---|
| `app/` | GUI em Qt6 (C++17 + QtQuick puro, **sem Kirigami**). Ponte entre a UI e o engine. |
| `engine/` | O engine: binário Go que hospeda as sessões. Onde vive toda a lógica. |
| `packaging/` | Scripts de release, instalador host e metadados AppStream. |

A GUI é apenas uma camada; ela invoca o engine via `QProcess` (`app/src/engineclient.cpp`). O contrato é estreito: `check` (exit 0) e `version` (imprime `X.Y.Z`) são o que a GUI sonda, e todo o resto imprime JSON para a GUI ou um parágrafo para uma pessoa.

## Arquitetura

### app/ — GUI Qt6/QML

- `src/main.cpp` — bootstrap: instância única (QLocalServer), tradutores, engine QML, context
  properties (`backend`, `appInfo`) e **`setDesktopFileName`**, que é de onde sai o `app_id` no
  Wayland. Sem ele o Qt cai no nome do executável (`opencouch`) e nada casa com o `.desktop`:
  sem ícone no alt-tab e sem nada para uma windowrule mirar.
- `src/backend.{h,cpp}` — ponte QML↔engine. Expõe `Q_INVOKABLE`s para status, displays, entrar,
  setup, logs, autostart e as preferências. Roda o engine de forma síncrona (`runEngineSync`) ou
  assíncrona (`runEngineAsync`), e observa `$XDG_RUNTIME_DIR` pelo anúncio de uma entrada que a
  janela não pediu (`configChanged`/`pendingEntryChanged`).
- `src/engineclient.{h,cpp}` — constrói a linha de comando do engine (só o nome: ele está no PATH),
  a identidade (`check`) e a versão mínima (`kMinEngineVersion`).
- `src/desktoptheme.{h,cpp}` — lê `~/.local/state/omarchy/current/theme/colors.toml` e observa o
  arquivo **e o diretório** (trocar de tema reescreve o diretório inteiro, então uma watch só no
  arquivo fica apontando para um inode morto). Registrado como **singleton QML**, não context
  property: `Colors.qml` é singleton, e singletons não enxergam context properties.
- `src/configstore.{h,cpp}` — só o que é **do app**: autostart (desktop entry / portal
  Background), `backgroundOnClose`, `startMinimized`, onboarding — tudo em `QSettings`. Configuração do
  **console** não passa por aqui: ela mora no `console.json` e só o engine escreve nela.
  (Havia um `config.env` do engine bash sendo gravado por este arquivo até a 2.0.1; o
  engine Go nunca leu esse arquivo, então toda preferência escrita ali era silenciosamente
  perdida.)

- `src/appinfomodel.{h,cpp}` — nome, versão e URL do script de instalação.
- `qml/` — QtQuick puro, **sem Kirigami**. `theme/Colors.qml` e `theme/Metrics.qml` são singletons
  (a paleta e a escala); `StateSurface.qml` é o **único** lugar onde a prioridade de estado é
  declarada; `Icon.qml` + `IconData.js` desenham os 17 ícones como `Shape`.
- `translations/` — catálogos Qt Linguist (`.ts`); `opencouch_en.ts` é o catálogo base.

### engine/ — o engine

Módulo Go próprio (`github.com/GustavoBelo/OpenCouch/engine`). Dependências: só `godbus/dbus/v5`.

- `cmd/open-couch-engine/` — a CLI. Subcomandos: `host-session`, `enter [--yes]`, `leave`, `cancel`,
  `status` (JSON), `doctor`, `setup`, `outputs` (JSON), `tv <CONNECTOR>`, `boot <modo>`,
  `controller <on|off>`, `log [--clear | --list | --session <ID>]`, `config-path`, `check`,
  `version`.
- `internal/console/` — o núcleo. As peças que carregam o valor são as chatas:
  - `session.go` — o loop do wrapper: `Sanitize` → `SettleJobs` → `commandFor` → `Launch`, repetindo.
  - `systemd.go` — **`Sanitize`**. Nada mais limpa o systemd user manager na saída de uma sessão
    gamescope; sem isso o uwsm recusa o compositor seguinte e a sessão morre no segundo em que sobe.
  - `connector.go` — **`AwaitConnector`**. O gamescope enumera conectores uma vez e nunca reexamina;
    entrar antes da TV acordar dá tela preta até um replug físico.
  - `compositor.go` — a interface `Compositor` e `SessionRunning`. **O único ponto que sabe qual
    desktop está rodando.** Desktop desconhecido **recusa** em vez de cair em `loginctl
    terminate-session`, que mataria a sessão hospedeira junto.
  - `live.go` — o arquivo de modo. Prova por efeito que a sessão trocou; a geração é o que distingue
    "ainda rodando" de "trocou enquanto eu não olhava".
  - `displays.go` — `ListDisplays` lê `/sys/class/drm` e faz parse do EDID. **Sem compositor**, o que
    é obrigatório: o wrapper precisa da lista entre sessões, quando não há nenhum rodando.
  - `setup.go`, `detect.go` — descoberta de `.desktop` e a entrada hospedeira.
  - `announce.go` — countdown com botão Cancel, para os caminhos sem GUI.
- `internal/audio/` — EDID→ELD→pin→profile→sink. O WirePlumber move *streams*, não o sink default.
  - `logfile.go` — o log do login atual e os anteriores. `RotateLog` arquiva no topo do
    `host-session`; `log --list`/`--session` são o que a GUI mostra em **History**. O id é
    validado por regex antes de virar caminho: ele volta de fora, pela GUI.
  - `trigger.go` — o gatilho de controle. Roda **só enquanto o desktop está na tela** e
    arma na **borda de subida** da contagem de pads: armar pelo número entraria no console
    toda vez que o desktop voltasse com um controle plugado, inclusive na volta do console.
  - `pending.go` — o anúncio que a GUI lê para desenhar a mesma contagem que a notificação.
    `deadline` absoluto, não segundos restantes: a janela pode ler tarde.
- `internal/notify/`, `internal/atomicfile/`.

Runtime:
- Config: `${XDG_CONFIG_HOME:-~/.config}/open-couch/console.json`
- Estado: `~/.cache/open-couch/` (`last-session`, `console-failure`, `console-prepared.json`,
  `console.log`, `logs/AAAAMMDD-HHMMSS.log` — os 10 logins anteriores)
- Runtime: `$XDG_RUNTIME_DIR/open-couch-{live,hosted,next-session,cancel-entry,entry-pending}`

Requisitos de host: systemd user manager, um pacote `gamescope-session` (o engine **não** o fornece,
só o detecta), `gamescope`, `steam`, `pactl`, D-Bus.
### packaging/

- `release.sh` — **única forma autorizada de versionar** (ver abaixo).
- `io.github.gustavobelo.opencouch.metainfo.xml` — metadados AppStream.
- `aur/` — dois PKGBUILDs: `open-couch-engine` (binário + entrada de sessão) e `open-couch` (a GUI).
- `rpm/open-couch.spec` — o mesmo par, como subpacotes, para o COPR.
- `host/install.sh` — baixa o binário da release para `~/.local/bin` e confere o SHA256.
- `check-docs.sh` — confere este arquivo contra o código: todo `src/*` e `qml/*` citado existe,
  todo subcomando do `usage()` do engine está documentado, e todos os catálogos `.ts` carregam o
  mesmo conjunto de ids. Roda na CI antes do build. Existe porque "atualize o AGENTS.md na mesma
  mudança" é regra sem nada que a faça valer, e este arquivo derivou até documentar dois
  arquivos-fonte inexistentes e um `MIN_VERSION` que nunca existiu.
- `icons/hicolor/<N>x<N>/apps/*.png` — o ícone, um por tamanho (16 a 512). Nada em `scalable/`.
- `screenshots/`, `video/`.

## Build

Go e Qt6 no host (não há KF6: a GUI é QtQuick puro). O alvo `engine` do CMake roda `go build` e
injeta a versão via `-ldflags`. Um `cmake --install` põe os dois binários, o `.desktop`, o ícone,
o metainfo e a entrada de sessão hospedeira sob o `CMAKE_INSTALL_PREFIX` — para instalar por cima
dos pacotes da distribuição, use `-DCMAKE_INSTALL_PREFIX=/usr`.

```sh
cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Release
cmake --build app-build --parallel "$(nproc)"
```

Dependências de build: Go ≥ 1.26, Qt6 (Core, Gui, Widgets, Qml, Quick, QuickControls2, DBus,
LinguistTools), C++17, CMake ≥ 3.16.

## Versionamento (CRÍTICO)

A versão é sincronizada em **vários arquivos** e não deve ser editada manualmente:

- `app/version.txt` (`VERSION=`, `RELEASE_DATE=`) — é daqui que o CMake tira a versão quando não há tag
- `SELF_VERSION` em `packaging/host/install.sh`
- `pkgver=`/`pkgrel=` nos dois PKGBUILDs (`packaging/aur/open-couch-engine`, `packaging/aur/open-couch`)
- `Version:`/`Release:` e uma entrada de `%changelog` em `packaging/rpm/open-couch.spec`
- a versão do engine **não** é sincronizada: é um binário Go e a versão chega por
  `-ldflags -X main.version=` no build, vinda de `app/version.txt` ou da tag

`kMinEngineVersion` (`app/src/engineclient.cpp`) **não entra nessa lista**: é a versão mínima de
engine que o app aceita, e quem a decide é você, na mudança que a exige. O `release.sh` não a lê e
não a propaga para lugar nenhum.

**Para lançar uma versão, rode sempre:**

```sh
packaging/release.sh X.Y.Z
```

que valida a versão, verifica árvore limpa, sincroniza todos os arquivos, regenera `SHA256SUMS`, valida o metainfo com `appstreamcli`, faz commit e cria a tag `vX.Y.Z`. Depois: `git push origin main --tags`.

Ao alterar o engine de forma que exija reinstalação do usuário, **bumpe `kMinEngineVersion`** em
`app/src/engineclient.cpp` — à mão, e para a versão que **vai** sair. Nada automatiza isso.

Efeito colateral conhecido: enquanto a tag não existe, o build local injeta a versão do **último**
tag, então o app acusa "engine desatualizado" contra o engine que você acabou de compilar. É o
esperado; some no `release.sh`.

Ao dar push de uma tag `v*`, a CI (`.github/workflows/release.yml`) testa o engine, compila os
binários estáticos `linux-amd64`/`linux-arm64`, gera o `SHA256SUMS` e publica os três na release.
Não há AppImage nem Flatpak desde a 2.0.

## Publicação de release — boa prática

Fluxo completo após `packaging/release.sh` + `git push`. **Release notes sempre em inglês**; este arquivo permanece em PT-BR.

### 1. Pré-voo

```sh
git status --porcelain  # limpo
git tag --sort=-v:refname | head
grep -n kMinEngineVersion app/src/engineclient.cpp  # confira antes: ninguém o atualiza por você
cat app/version.txt
(cd engine && go test ./... && go vet ./...)
```

### 2. Versionar (único caminho)

```sh
packaging/release.sh X.Y.Z
# valida X.Y.Z, tag inexistente, árvore limpa e branch main;
# atualiza app/version.txt (RELEASE_DATE=date -u), SELF_VERSION,
# os dois PKGBUILDs e o .spec (+ entrada de %changelog);
# valida o metainfo com appstreamcli --no-net ANTES de commit/tag
#
# O engine não tem versão gravada em arquivo: é um binário Go e a versão
# chega por -ldflags no build. Quem publica o binário e o SHA256SUMS é o
# workflow de release, não este script.
git log --oneline -2 && git show --stat HEAD
```

Revisar `app/version.txt`, o `SELF_VERSION` de `packaging/host/install.sh`, o `pkgver` dos dois
PKGBUILDs e o `Version:` do `.spec`. Conferir com `open-couch-engine version`.

### 3. Push da tag

```sh
git push origin main --tags
# dispara .github/workflows/release.yml — job `engine` (testa, compila estático
# para amd64/arm64, gera SHA256SUMS) e job `release` (cria ou atualiza a release)
```

### 4. Release notes

```sh
PREV=$(git tag --sort=-v:refname | sed -n '2p')
git log $PREV..HEAD --oneline --no-merges
git log $PREV..HEAD --pretty=format:"%h %s%n%b"
git diff $PREV..HEAD --stat
```

Categorizar em **Highlights / Features / Fixes / Translations / Packaging & Docs / Engine & Versioning**. Incluir sempre `**Full Changelog**: https://github.com/GustavoBelo/OpenCouch/compare/<prev>...vX.Y.Z` e, se `kMinEngineVersion` subiu, instrução de reinstalação do engine (`packaging/host/install.sh --update`, ou o pacote da distribuição).

Modelo publicado: `v1.7.0` — https://github.com/GustavoBelo/OpenCouch/releases/tag/v1.7.0

### 5. GitHub Release — idempotência (CRÍTICO)

O passo `Create or update release` do workflow é **idempotente**:

```sh
ASSETS=(dist/open-couch-engine-linux-amd64 dist/open-couch-engine-linux-arm64 dist/SHA256SUMS)
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" --clobber      # preserva notes escritas à mão
else
  gh release create "$TAG" "${ASSETS[@]}" --title "Open Couch $TAG" --generate-notes
fi
```

Duas formas válidas:

* **A — Automática (simples):** só `git push origin main --tags`; workflow cria a release com `--generate-notes`. Depois editar se quiser notas detalhadas: `gh release edit vX.Y.Z --notes-file /tmp/release_notes.md`.
* **B — Manual detalhada (usada em v1.7.0):** criar antes do workflow com `gh release create vX.Y.Z --title "Open Couch vX.Y.Z" --notes-file /tmp/release_notes.md --latest`; o workflow detecta que a release já existe e apenas faz `upload --clobber` dos binários, sem sobrescrever as notas. **Não recriar** a tag com `gh release create` após o workflow já ter criado — falhará com `a release with the same tag name already exists`.

Verificação:

```sh
gh release view vX.Y.Z --json tagName,name,body,assets --jq .
gh release list --limit 5
```

### 6. Pós-release

Acompanhar `gh run list --limit 5` e `gh run view <id> --log-failed`. Warnings
`screenshot-image-not-found` antes do push são esperados (as URLs usam `vX.Y.Z`, que só existe
depois da tag) — e é por isso que o `release.sh` valida com `--no-net`.

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

- O engine tem suíte Go (`internal/console` ~77% de cobertura). Rode sempre:
  `cd engine && go test ./... && go vet ./... && gofmt -l ./cmd ./internal`.
  Pelo ctest: `ctest --test-dir app-build --output-on-failure`.
  Tudo isso também roda na esteira (`ci.yml`) em todo push na `main` e todo PR.
- A GUI não tem testes. Para pegar erro de QML sem sessão gráfica:
  `QT_QPA_PLATFORM=offscreen ./app-build/opencouch` — `main.cpp` imprime todo warning de QML em
  stderr, e sair sozinho significa que o QML não carregou.
- **O caminho crítico não é testável em CI**: trocar de sessão exige um login de verdade. Depois de
  mexer no wrapper, peça teste manual — entrar, voltar pelo "Switch to Desktop" do Steam, e repetir
  **duas vezes** (o guard de restart curto só aparece na segunda volta), conferindo
  `systemctl --user list-units --failed` vazio.
- Após alterações no engine que exigem nova versão mínima, atualizar `kMinEngineVersion`.

## Armadilhas conhecidas e validações do `release.sh`

Verificadas por leitura direta de `packaging/release.sh`. Sem número de linha de propósito: eles
apodrecem na primeira edição, e este arquivo já carregou um conjunto inteiro apontando para linhas
que não existiam mais. O que está entre crases é `grep`-ável.

- **Todo `sed -i` é verificado depois.** `sed` não retorna erro quando o padrão não casa, e `set -e`
  não pega isso — um arquivo dessincronizado passaria em silêncio. Cada substituição
  (`SELF_VERSION=`, `pkgver=`, `Version:`) é seguida de um `grep -q` do valor esperado e de um
  `exit 1` se não encontrar.
- **Os PKGBUILDs e o `.spec` são construídos a partir do tarball da tag.** Um deles esquecido não
  falha alto: ele baixa a tag **anterior** e a publica com o nome da versão nova. É por isso que
  cada um é verificado após a escrita.
- **O `.spec` precisa de entrada de `%changelog`.** O `rpmlint` trata versão sem entrada como erro,
  e um changelog que para antes da própria versão não diz nada a quem instala. O script insere uma
  entrada apontando para as release notes, e verifica que entrou.
- **Checagem de branch `main`.** O script confere `git rev-parse --abbrev-ref HEAD` e aborta fora da
  `main`, para que tags `vX.Y.Z` nunca nasçam em branch de feature.
- **`appstreamcli validate` é bloqueante e roda antes do commit.** Valida o metainfo já renderizado
  e aborta sem criar commit nem tag se falhar. Usa `--no-net` porque as URLs de screenshot apontam
  para a tag que o script ainda vai criar. Se o `appstreamcli` não estiver instalado, avisa e segue
  — é o único caso não-bloqueante.
- **O que o `release.sh` NÃO faz:** não toca em `kMinEngineVersion`, não gera AppImage, não mexe em
  manifest Flatpak (não existe nenhum) e não publica nada. Publicar é do workflow.

- **O sufixo `(console switch)` no `Name=` é compartilhado com o hyprmoncfg por construção.**
  Os dois projetos geram o nome da entrada hospedeira com o mesmo `HostingEntryName`, e é por isso
  que o `HostsConsole` o usa para detectar hospedeiras alheias. Uma hospedeira pode apontar para um
  script wrapper e não ter marcador nem `Exec` reconhecível — o nome é o que sempre sobra. Sem isso o
  wrapper adota o wrapper do outro como "desktop" e ninguém chega a um desktop.
- **`ReadsUserSessionDir` decide onde o `setup` manda instalar a entrada.** SDDM, GDM e LightDM só
  leem os diretórios de sistema (`SessionDir=/usr/local/share/wayland-sessions,/usr/share/...`;
  sddm/sddm#916 ainda está aberto). Mandar instalar em `~/.local/share/wayland-sessions` nesses casos
  produz o pior desfecho possível: o usuário desloga, não encontra a sessão e nada explica.
- **`CheckIdentity` (Go) e `kCheckIdentity` (C++) precisam ser idênticos byte a byte.**
  `engine/cmd/open-couch-engine/main.go` imprime a string em `check`;
  `app/src/engineclient.cpp` compara por igualdade. Mudar um lado só faz o app relatar
  **todo** engine como ausente. A comparação existe porque sair 0 não prova nada: o engine bash
  que isto substituiu também tem um `check` que passa e reporta a mesma versão, e depois responde
  `status` com linhas de log em vez de JSON — o app falaria com ele e mostraria "não pronto" para
  sempre, sem nada a dizer.

- **Nunca nomear um tipo QML como um tipo embutido do Qt.** `Palette` e `Style` existem no QtQuick e
  no QtQuick.Controls: um singleton com esses nomes compila (o módulo vence na compilação) e falha em
  runtime com `was a singleton at compile time, but is not a singleton anymore` ou lendo o tipo errado.
  Custou uma sessão inteira. Por isso são `Colors` e `Metrics`.
- **O módulo QML precisa de `RESOURCE_PREFIX "/qt/qml"`.** É o prefixo que o caminho de import padrão
  do engine procura; sem ele o módulo existe no resource mas não é importável, e os tipos resolvem
  pelo diretório como componentes comuns.
- **Todo `.qml` que usa `Colors`/`Metrics` precisa de `import io.github.gustavobelo.opencouch`.**
  Singletons não vêm pelo import implícito do diretório.
- **Ícones são `Shape`, não imagem.** Tingir imagem exige efeito de shader, e shader não desenha nada
  sob rasterizador de software — o `QT_QPA_PLATFORM=offscreen` do CI, por exemplo. Com `ShapePath` a
  cor é propriedade comum.
- **O ícone do app é raster, e `hicolor/scalable/` tem que ficar vazio.** Ele é um desenho de uma
  sala (estante, pôster, dois controles), não um diagrama: mora em
  `packaging/icons/hicolor/<N>x<N>/apps/*.png`, um reamostrado por tamanho. O spec do icon theme
  prefere **scalable a qualquer tamanho fixo**, então um `.svg` esquecido lá vence os oito PNGs e o
  ícone antigo volta sem nada falhar. Ao trocar o ícone, apague o do sistema também:
  `/usr/share/icons/hicolor/scalable/apps/`. O `check-docs.sh` verifica que o repositório não tem
  nenhum.
- **Se um dia o ícone voltar a ser SVG, ele é SVG Tiny 1.2.** Quem o desenha é o `QIcon` do Qt, e o
  renderizador dele ignora `<style>`/CSS, `filter` e `mask` — sem erro, sem aviso, simplesmente não
  desenha. Renderizar com `rsvg-convert` **não prova nada**: ele entende SVG 1.1 inteiro. Para
  conferir de verdade, desenhe pelo próprio Qt.
- **Controle mostra estado, não guarda estado.** `Toggle.qml` e `SettingSwitch.qml` só emitem
  `toggled(!checked)`; quem escreve em `checked` é o dono, a partir do que o engine respondeu.
  Escrever no próprio `checked` **quebra o binding do dono para sempre** — daí em diante o controle
  reporta o último clique e não o que a máquina fez, que é como uma configuração parece salva sem
  ter mudado nada. Vale igual para `Select`: ativar um ComboBox escreve `currentIndex` e mata o
  binding, então `SetupPage.reload()` reatribui.
- **Página empilhada não é página recriada.** `SetupPage` é empilhada **por cima** do
  `DashboardPage`, que continua vivo e não roda `Component.onCompleted` de novo na volta. É por isso
  que existe o sinal `configChanged` — sem ele o dashboard mostra o que era verdade quando foi
  construído, e o botão *Refresh* vira a única forma de descobrir o contrário.
- **Autostart tem dois mecanismos e só um pode ficar.** O portal Background e o entry em
  `~/.config/autostart` lançam o app de formas independentes; um entry órfão (de uma tentativa em
  que o portal falhou) dispara segunda instância no login, e o `WAKEUP` dela abre a janela da
  primeira — um "iniciar minimizado" que não minimiza. `ConfigStore::setAutostart` sincroniza os
  dois a cada mudança. No Hyprland com uwsm o entry vira o serviço *generated*
  `app-io.github.gustavobelo.opencouch@autostart.service` (sem unit file persistente).
- **"Iniciar minimizado" esconde sem depender do tray.** A janela nasce com `visible: false`
  (`main.qml` lê `backend.startMinimized()`), porque esconder logo depois do `show()` corre contra
  o primeiro frame do Wayland. O tray pode subir **depois** do app no boot — por isso o
  `QSystemTrayIcon` é criado lazy em `Backend::showTray()`, e `attachWindow` repete a tentativa
  com `QTimer::singleShot` até a barra aparecer. Escondido sem tray ainda tem volta: abrir o app
  de novo acorda a janela via `WAKEUP`.

## Estratégia de branch
 
Segue o modelo **GitHub Flow** — simples, adequado a um projeto de porte pequeno/médio com um mantenedor principal, e evita a complexidade de algo como GitFlow (branches `develop`/`release` separadas) que não se justifica aqui.
 
- **`main` é sempre estável e "release-able".** Toda tag de release (`vX.Y.Z`) é criada a partir de `main` — nunca de outra branch.
- **Trabalho novo vai em branch a partir de `main`**, com prefixo indicando o tipo de mudança, alinhado aos tipos de commit já usados no projeto:
  - `feat/<descrição-curta>` — nova funcionalidade
  - `fix/<descrição-curta>` — correção de bug
  - `refactor/<descrição-curta>` — refatoração sem mudança de comportamento
  - `docs/<descrição-curta>` — documentação (README, AGENTS.md, etc.)
  - Exemplo: `fix/wmctrl-wayland-noop`
- **Merge em `main` via Pull Request** — a esteira (`ci.yml`) roda em todo push na `main` e em
  todo PR: confere a documentação contra o código, roda `go vet`/`go test` no engine e compila a
  GUI com o smoke test offscreen. O merge em `main` **exige a esteira verde** (branch protection
  com required status checks): PR que não passa não pode ser mergeado. Squash merge é preferível
  (um commit por PR, no padrão `feat:`/`fix:`/etc.).
- **Commit direto em `main` só com pedido explícito do usuário**, ou pelos commits automáticos do
  `packaging/release.sh` (`Release vX.Y.Z`), que fazem parte do próprio fluxo de release e são
  validados para rodar **apenas em `main`** (o `release.sh` aborta fora dela).
- **Branches de feature são de vida curta**: mergear e deletar assim que a mudança for aceita, para não acumular branches obsoletas.
- **Tags (`vX.Y.Z`) nunca são criadas em branches que não sejam `main`** (enforçado pelo `release.sh`).
Para agentes de IA: abrir branch ou Pull Request exige pedido explícito do usuário — não são assumidos automaticamente a partir de uma tarefa de código.

## Fluxo de trabalho recomendado para agentes

1. Entender a mudança dentro da divisão app/engine/packaging (a lógica de sessão e display fica no engine, não na GUI).
2. Implementar seguindo as convenções acima.
3. Validar com `cmake --build` e `go test ./...`; testar manualmente se a mudança afeta comportamento visível.
4. Nunca versionar manualmente; para releases seguir **Publicação de release — boa prática** (`packaging/release.sh` + push + GitHub Release idempotente).
5. Manter este arquivo atualizado: se a mudança afetar o que está documentado (build, versionamento, traduções, arquitetura, comandos), atualizar o AGENTS.md na mesma mudança e avisar o usuário o que e porquê alterou.