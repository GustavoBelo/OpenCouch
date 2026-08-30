# feat/hyprland — suporte a Hyprland sem quebrar o KDE

Estado desta branch, o que foi corrigido e o que falta antes de release.

## Objetivo

Fazer o Open Couch funcionar no Hyprland — tema, ícones e troca de layout — mantendo o KDE Plasma
intacto. Ao investigar, ficou claro que a branch **já quebrava o KDE** e que a causa da falha no Hyprland
não era a que o código assumia.

## Ponto de partida

A branch trazia um refactor do engine bash monolítico em `lib/` + `drivers/`, mais tentativas de resolver
tema e ícones no `app/`. Nenhuma das duas frentes funcionava, e o refactor introduziu regressões no KDE.

---

## O que foi corrigido

### Regressões que quebravam o KDE

**Driver Hyprland sequestrava o KDE.** `drivers/hyprland.sh` definia `big_picture_window_present()` e
`close_big_picture()` **sem prefixo**. Como `build-engine.sh` concatena tudo num único arquivo bash, essas
versões (baseadas em `hyprctl`) sobrescreviam as de `lib/common.sh` **para todos os compositores**. No KDE:
`watch` nunca ativava, `restore` não fechava o Big Picture, `play` travava 60 s e não restaurava.

- Funções renomeadas para `hyprland_*`; as implementações compartilhadas viraram `default_*`.
- `big_picture_window_present` e `close_big_picture` entraram no contrato de driver.
- `load_driver()` resolve cada `driver_<fn>` em três níveis: `<prefixo>_<fn>` → `default_<fn>` → stub que
  loga erro. Nenhum nome `driver_*` fica indefinido.
- **`build-engine.sh` falha o build** se um driver definir função de topo sem prefixo. A guarda já pegou
  dois casos durante a própria implementação.

**`cleanup()` chamava função inexistente.** `restore_layout` virou `kde_restore_layout` /
`hyprland_restore_layout`, mas o handler de `trap cleanup EXIT INT TERM` continuava chamando o nome antigo,
com `|| true` engolindo o `command not found`. Ctrl-C durante o `play` deixava o monitor da mesa desligado
— **nos dois compositores**. Agora chama `driver_restore_layout` e loga a falha em vez de silenciar.

**`check` mentia.** Só validava dependências se um driver tivesse carregado; num KDE sem `kscreen-doctor`
a detecção cai em `unknown` e o comando respondia `Host dependencies OK`. Agora falha.

### Hyprland — a causa real

**`hyprctl keyword monitor` é recusado no Hyprland 0.5x** (parser de config em Lua):
`keyword can't work with non-legacy parsers. Use eval.` — e **sai com status 0**. Nenhum layout era
aplicado e o engine reportava sucesso.

A API correta é `hl.monitor{}` via `hyprctl eval`. O driver detecta uma vez por execução
(`hyprland_monitor_api`), cai no `keyword` legado em builds antigas, e **verifica o resultado** relendo
`hyprctl -j monitors all` em todos os caminhos. A API detectada aparece em `capabilities` →
`display.monitor_api`.

Outras correções no driver:

| Problema | Efeito |
|---|---|
| Posição `X,Y` em vez de `XxY` no restore | Campos deslocados; restore malformado |
| `.fullscreen == true` num campo **inteiro** | Big Picture nunca detectado |
| Escala vazia (`jq` sai 0 com saída vazia) | Divisão por zero no cálculo de posição |
| Escala lida do monitor, não da config | Escala escolhida no Setup era ignorada |
| `connected: true` fixo | Estado real agora vem de `/sys/class/drm/*/status` |
| `priority` derivado de `.focused` | Mudava com o mouse; agora `null` (Hyprland não tem saída primária) |
| Modo `0x0@60` de monitor desativado | Era oferecido no Setup e gravado no `layout.env` |
| Três formatos de modo misturados | Normalizados para `WxH@R` e ordenados numericamente |
| Sem equivalente de `move_steam_to_desk_monitor` | Steam ficava em saída desativada após o restore |

### Tema e ícones

O app **nunca** chamava `QQuickStyle::setStyle()` — quem definia era o Plasma, pelo ambiente. Fora do KDE o
estilo caía para Basic/Fusion, o Kirigami não encontrava `plugins/kf6/kirigami/platform/org.kde.desktop.so`
(ele escolhe o plugin pelo **nome do estilo**) e usava um `BasicTheme` claro fixo que ignora o sistema.

`configureIconTheme()` só agia se `QIcon::themeName()` estivesse vazio — o que nunca acontece fora do
Plasma (aqui era `Yaru-sage`). Toda a UI usa nomes Breeze (`overflow-menu`, `help-hint`, `text-x-log`…),
que não existem em Adwaita/Yaru/hicolor. O teste passou a ser de **cobertura real**:
`QIcon::hasThemeIcon("overflow-menu")`.

Também: `systemPrefersDark()` desembrulhava `QDBusVariant` uma vez só, mas `portal.Settings.Read` devolve
variante dentro de variante — o ramo do portal estava morto. E `applyDarkPalette()` foi removido: não
afetava o QML (QQC2/Kirigami leem `Kirigami.Theme`, não a `QPalette`) e sobrescrevia o esquema de cores do
usuário no KDE.

Verificado no host, com o processo rodando:

| | antes | depois |
|---|---|---|
| plugin de tema | nenhum carregado | `org.kde.desktop.so` |
| ícones | Yaru-sage (sem os nomes Breeze) | `/usr/share/icons/breeze` |

### Empacotamento

O `release.yml` desta branch estava com **YAML inválido** (heredoc do `AppRun` em coluna 0 dentro de
`run: |`) — o workflow não parsearia. Além disso, dois bugs faziam o AppImage sair incompleto:

- **`--output appimage` empacota na mesma chamada** do linuxdeploy. O `AppRun` e o `libQt6Svg` eram
  instalados *depois* dessa linha, ou seja, depois do artefato já existir — nunca chegavam nele.
- **O linuxdeploy poda `usr/lib`** para o conjunto que rastreia. Das 10 libs KF6 copiadas antes dele,
  sobravam só as 5 que ele também rastreia; sumia exatamente o fecho de dependências do plugin de tema.

Corrigido com **duas passadas** (deploy → extras → empacotamento) e `--custom-apprun`. No caminho:
`/usr/lib64` no Arch é symlink para `/usr/lib` (`find -maxdepth 1` não achava nada) e `cp -a` de
`libFoo.so.6` copiava symlink de soname quebrado (precisa `cp -aL`).

O `AppRun` virou arquivo único em `packaging/AppRun`, usado pelo script local e pelo CI. O
`QT_QPA_PLATFORMTHEME=desktopportal` foi removido: medido como prejudicial a ícones e detecção de tema
escuro.

### Instância única

Uma instância viva segurava o socket e o lançamento novo apenas trazia a janela **antiga** para frente,
saindo em silêncio — indistinguível de "o build não pegou". Custou duas rodadas de depuração.

- O handoff **imprime** pid e caminho da instância viva (o `.AppImage`, não o `/tmp/appimage_extracted_*`).
- Flag **`--replace`** encerra a instância existente (SIGTERM, SIGKILL como último recurso) e assume.
- `build-appimage.sh` avisa no final se há instância rodando, com o comando pronto.
- Se `server.listen()` falhar, o app avisa — antes a proteção ficava desligada calada. Causa típica:
  caminho de temp longo demais para socket unix (`sun_path` ~107 bytes).

### Outros

- `PROTECTED_PROCESSES` cobria só KDE; no Hyprland o "controle de recursos" oferecia e matava o próprio
  compositor. Agora inclui `Hyprland`, `waybar`, `hyprpaper`, `hyprlock`, `uwsm`, portais. Espelhado em
  `app/src/appcleanupmodel.cpp`.
- `Kirigami.Theme.separatorColor` **não existe** no KF6. O fallback deixou de ser preto fixo e passou a
  derivar de `Kirigami.Theme.textColor` com alfa (funciona em tema claro e escuro).
- O auto-detect que gravava config sozinho e pulava o Setup virou **pré-preenchimento**, com heurística
  determinística (HDMI, depois maior resolução). Escolher a saída errada como "mesa" apagaria a tela.
- `open-couch-log-viewer` usava `-e` para todos os terminais; `xdg-terminal-exec`, `gnome-terminal` e
  `wezterm` têm formas próprias.
- `log ERROR "msg"` descartava a mensagem (`log()` recebia um argumento só); mensagens em português
  traduzidas para inglês.
- String de tradução órfã `resource_control.running_picker_requires_wmctrl` removida dos 7 catálogos.
- `backend.capabilities()` estava exposto e nunca usado; agora o Setup avisa quando o compositor não
  suporta autostart por `.desktop` ou não tem bandeja do sistema.

### Estrutura e CI

- **`backend/dispatcher.sh` criado.** O `build-engine.sh` lia e escrevia o mesmo arquivo — o dispatcher não
  tinha fonte de verdade. `backend/open-couch-engine` é gerado e não deve ser editado.
- **Versões sincronizadas em `lib/common.sh`** pelo `build-engine.sh` (`ENGINE_VERSION` de
  `app/version.txt`, `MIN_VERSION` de `kMinEngineVersion`). Antes o `release.sh` corrigia o artefato e um
  rebuild revertia — o `MIN_VERSION` estava voltando a `0.0.0`.
- **CI de PR** (`.github/workflows/ci.yml`): todo pull request e push de branch passa a gerar AppImage, com
  as verificações de conteúdo. Antes só tag `v*` gerava. O build vive em
  `.github/actions/build-appimage/` e é compartilhado com o `release.yml`, para os dois não divergirem.

---

---

## Suíte de testes automatizados

O maior problema desta branch não era um bug — era não haver como saber se ela quebrava o KDE. Todas
as regressões corrigidas acima são **silenciosas**: nada falha, o comportamento só some. Agora existem
duas suítes, e nenhuma precisa de uma sessão KDE ou Hyprland.

**Engine (bash, `tests/`, 156 testes, ~1 min).** `bats`, com shim para cada comando de host
(`kscreen-doctor`, `hyprctl`, `wmctrl`, `pgrep`, `pkill`, `steam`, `busctl`, `systemctl`). Cada shim
**registra o argv** num call log, e é sobre ele que a maioria das asserções é feita: o que importa não é
"a função retornou 0", é *"o driver mandou exatamente estes argumentos"*. Config, estado, DRM sysfs e
`/dev/input` são redirecionados para um diretório temporário por teste.

A suíte e2e roda **duas vezes**: contra `backend/dispatcher.sh` e contra o `backend/open-couch-engine`
concatenado. A concatenação é justamente onde as regressões entre compositores se esconderam.

Cada armadilha da tabela "Armadilhas por compositor" virou teste:

| Teste | Regressão que ele guarda |
|---|---|
| `driver_contract.bats` | KDE não pode herdar `big_picture_window_present` do Hyprland; os 14 nomes do contrato ficam ligados nos 4 compositores |
| `build_engine.bats` | a guarda de prefixo falha o build (injetando função sem prefixo em **cada** driver); o artefato commitado é o que as fontes geram |
| `play_restore.bats` | Ctrl-C e SIGTERM no meio do `play` trazem o monitor da mesa de volta — nos dois compositores |
| `hyprland_driver.bats` | `hyprctl` que recusa e **sai 0** faz `apply_monitors` falhar; `XxY` vs `X,Y`; `fullscreen` inteiro; `0x0@60` nunca reinjetado; `connected` vem do DRM |
| `kde_driver.bats` | os argumentos exatos do `kscreen-doctor` nos três modos (mesa desligada, mesa ao lado, espelhado) |
| `watch.bats` | `watch` reage ao Big Picture e não mexe no layout enquanto existe sessão de `play` |
| `protected_processes.bats` | `PROTECTED_PROCESSES` (bash) e `kProtectedProcesses` (C++) são o mesmo conjunto |
| `session.bats` | debounce dos controles, sessão stale, e `close_tracked_apps` nunca matando processo protegido |

O shim de `sleep` comprime o tempo (`OC_SLEEP_CAP`): os laços de retry do engine dormem em segundos
inteiros e a suíte levaria minutos de espera pura.

**Core C++ (`app/tests/`, Qt Test).** Tudo menos `main.cpp` passou para a biblioteca estática
`opencouch_core`; os testes linkam os mesmos objetos que o app publica. `BUILD_TESTING=OFF` por padrão —
o build de empacotamento não muda em nada. Cobrem `DisplaySettingsValidator`, `EngineClient`,
`ConfigStore` e a varredura de `.desktop` do `AppCleanupModel`. A UI (QML) não é testada.

**Seams no código de produção** — dois, ambos com default idêntico ao valor de hoje:
`OC_DRM_ROOT` (`/sys/class/drm`) e `OC_INPUT_ROOT` (`/dev/input`).

### Dois bugs que a suíte encontrou

**`saveConfig()` apagava a configuração de limpeza de apps.** `ConfigStore::saveConfig` truncava o
`config.env` e escrevia só o mapa recebido; `DisplaySettingsModel::toConfigMap()` não inclui
`CLOSE_APPS_ENABLED`, `CLOSE_APPS_WAIT_SECONDS` nem `APPS_TO_CLOSE`. Ou seja: configurar os apps a fechar
e depois salvar qualquer coisa no Setup apagava a lista, em silêncio. `saveConfig` agora **mescla** sobre
o que já está no disco — o engine lê o arquivo com `source`, então uma chave só é escrita, nunca removida.

**`desktop_process_names` perdia o `--command=` do flatpak.** O nome só era aceito se contivesse `/`, e
`--command=spotify` (a forma comum) era descartado; sobrava `Client`, de `com.spotify.Client`, que
`pkill -x` nunca casa. Afeta o caminho de fallback do engine, não a GUI (que faz a varredura em C++).

---

## Estado

| Frente | Estado |
|---|---|
| Regressões do KDE | Corrigidas e **cobertas por teste automatizado**; falta exercitar numa sessão Plasma real |
| Driver Hyprland | Corrigido, verificado no host (0.56.2) e coberto por teste |
| Tema e ícones | Verificados no binário nativo e no AppImage |
| Empacotamento | AppImage reconstruído e verificado; build de release não mudou com a extração do `opencouch_core` |
| Instância única | Verificado ponta a ponta |
| Testes | 156 testes de engine + 4 binários de teste do core C++; `shellcheck --severity=error` limpo |
| CI de PR | Job `test` roda antes do AppImage e o bloqueia; ainda não executado no GitHub |

## Antes de release

1. **Testar no KDE Plasma.** A suíte cobre o que os shims conseguem provar — a ordem das chamadas e os
   argumentos exatos. Não substitui `play`, `restore`, `watch` e Ctrl-C contra um Big Picture de verdade
   numa sessão Plasma.
2. **Decidir o `kMinEngineVersion`.** Está em `1.7.0`, igual ao `main`. O engine mudou de forma que **exige
   reinstalação** (nova API de layout, comandos novos, contrato de driver novo), então deveria subir junto
   com a release — senão quem tiver engine antigo continua com os bugs corrigidos aqui. Não foi bumpado
   agora de propósito: com `app/version.txt` ainda em `1.7.0`, um `MIN_VERSION` maior faria o Dashboard
   acusar "engine desatualizado" durante o desenvolvimento da própria branch.
   `tst_engineclient` lê o valor da fonte, então acompanha o bump sozinho.
3. **Decidir o destino do `backend/drivers/hyprland.sh`.** O Couch Mode do Hyprland/Omarchy passou a
   morar no `hyprmoncfg` (Go, com CLI e o painel `omarchy-hyprmoncfg`), então as 706 linhas do driver bash
   competem com uma implementação melhor posicionada. A decisão fica para depois do item 1 — agora com
   evidência, e sabendo que remover o driver também remove a segunda implementação do contrato.
4. Versionar apenas com `packaging/release.sh X.Y.Z`.

## Verificação rápida

```sh
bash packaging/build-engine.sh          # regenera, valida sintaxe e a regra de prefixo

tests/run.sh                            # suíte do engine (unit + e2e nas duas variantes)

cmake -S app -B app-build -DCMAKE_BUILD_TYPE=Debug -DBUILD_TESTING=ON
cmake --build app-build --parallel "$(nproc)"
ctest --test-dir app-build --output-on-failure

backend/open-couch-engine detect capabilities outputs check
```

Ao testar uma build nova da GUI, encerre a anterior — ou use `--replace`.
