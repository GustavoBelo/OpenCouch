# ujust recipe to install the Open Couch "engine" component on the host.
# This recipe is optional and can be used on any system with just.
# On Bazzite, it can also be copied to /etc/just/ujust.d/ so that
# "ujust install-open-couch" is available.
#
# The graphical app (Open Couch) is distributed separately via
# Flatpak/Flathub; this recipe only installs the script that needs to run
# outside the sandbox (display control via kscreen-doctor and Steam).

[group('Open Couch')]
[doc('Installs the Open Couch host script (required for the Flatpak app to work)')]
install-open-couch:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_URL="https://raw.githubusercontent.com/GustavoBelo/open-couch/main/backend"
    DEST="${HOME}/.local/bin"
    mkdir -p "$DEST"
    curl -fsSL "${REPO_URL}/open-couch-engine" -o "${DEST}/open-couch-engine"
    curl -fsSL "${REPO_URL}/open-couch-log-viewer" -o "${DEST}/open-couch-log-viewer"
    chmod +x "${DEST}/open-couch-engine" "${DEST}/open-couch-log-viewer"
    echo "Open Couch engine installed at ${DEST}."
    echo "Install the graphical app with: flatpak install flathub io.github.gustavobelo.opencouch"

[group('Open Couch')]
[doc('Removes the Open Couch host script')]
remove-open-couch:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f "${HOME}/.local/bin/open-couch-engine" "${HOME}/.local/bin/open-couch-log-viewer"
    echo "Open Couch engine removed."
