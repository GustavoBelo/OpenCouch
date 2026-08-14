# Receita ujust para instalar o componente "engine" do Open Couch no host.
# Esta receita e opcional e pode ser usada em qualquer sistema com just.
# No Bazzite, ela tambem pode ser copiada para /etc/just/ujust.d/ para que
# "ujust install-open-couch" fique disponivel.
#
# O app com interface grafica (Open Couch) e distribuido separadamente via
# Flatpak/Flathub; esta receita instala apenas o script que precisa rodar
# fora do sandbox (controle de tela via kscreen-doctor e da Steam).

[group('Open Couch')]
[doc('Instala o script host do Open Couch (necessario para o app Flatpak funcionar)')]
install-open-couch:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_URL="https://raw.githubusercontent.com/GustavoBelo/open-couch/main/backend"
    DEST="${HOME}/.local/bin"
    mkdir -p "$DEST"
    curl -fsSL "${REPO_URL}/open-couch-engine" -o "${DEST}/open-couch-engine"
    curl -fsSL "${REPO_URL}/open-couch-log-viewer" -o "${DEST}/open-couch-log-viewer"
    chmod +x "${DEST}/open-couch-engine" "${DEST}/open-couch-log-viewer"
    echo "Open Couch engine instalado em ${DEST}."
    echo "Instale o app grafico com: flatpak install flathub io.github.gustavobelo.opencouch"

[group('Open Couch')]
[doc('Remove o script host do Open Couch')]
remove-open-couch:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f "${HOME}/.local/bin/open-couch-engine" "${HOME}/.local/bin/open-couch-log-viewer"
    echo "Open Couch engine removido."
