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

## Estado

| Frente | Estado |
|---|---|
| Regressões do KDE | Corrigidas; **faltam testes numa sessão Plasma** |
| Driver Hyprland | Corrigido e verificado no host (0.56.2) |
| Tema e ícones | Verificados no binário nativo e no AppImage |
| Empacotamento | AppImage reconstruído e verificado |
| Instância única | Verificado ponta a ponta |
| CI de PR | Adicionado; ainda não executado no GitHub |

## Antes de release

1. **Testar no KDE Plasma.** As correções de maior risco são as que não pude exercitar aqui: `play`,
   `restore`, `watch` com Big Picture, e Ctrl-C no meio do `play`.
2. **Decidir o `kMinEngineVersion`.** Está em `1.7.0`, igual ao `main`. O engine mudou de forma que **exige
   reinstalação** (nova API de layout, comandos novos, contrato de driver novo), então deveria subir junto
   com a release — senão quem tiver engine antigo continua com os bugs corrigidos aqui. Não foi bumpado
   agora de propósito: com `app/version.txt` ainda em `1.7.0`, um `MIN_VERSION` maior faria o Dashboard
   acusar "engine desatualizado" durante o desenvolvimento da própria branch.
3. Versionar apenas com `packaging/release.sh X.Y.Z`.

## Verificação rápida

```sh
bash packaging/build-engine.sh          # regenera, valida sintaxe e a regra de prefixo
cmake --build app-build --parallel "$(nproc)"

# nenhuma função de driver sem prefixo (sequestraria os outros compositores)
for f in backend/drivers/*.sh; do d=$(basename "$f" .sh); \
  grep -nE '^[a-z_][a-z0-9_]*\(\) *\{' "$f" | grep -vE ":${d}_" && echo "VAZANDO: $f"; done

backend/open-couch-engine detect capabilities outputs check
```

Ao testar uma build nova da GUI, encerre a anterior — ou use `--replace`.
