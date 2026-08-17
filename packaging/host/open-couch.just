# ujust recipe to install the Open Couch "engine" component on the host.
# This recipe is optional and can be used on any system with just.
# On Bazzite, it can also be copied to /etc/just/ujust.d/ so that
# "ujust install-open-couch" is available.
#
# The graphical app (Open Couch) is distributed separately via
# Flatpak/Flathub; this recipe only installs the script that needs to run
# outside the sandbox (display control via kscreen-doctor and Steam).

# Bumped automatically by release.sh
OPEN_COUCH_VERSION := "1.5.2"
REPO_URL := "https://raw.githubusercontent.com/GustavoBelo/OpenCouch/v" + OPEN_COUCH_VERSION + "/backend"
DEST := env_var('HOME') / ".local/bin"

_check-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    missing=()
    for cmd in jq kscreen-doctor pgrep; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]} > 0 )); then
        echo "Missing dependencies on the host: ${missing[*]}"
        echo "Install the equivalent packages from your distribution:"
        echo "  Fedora/Bazzite: jq kscreen procps-ng wmctrl"
        echo "  Debian/Ubuntu:  jq kde-cli-tools procps wmctrl"
        echo "  Arch:           jq kscreen procps-ng wmctrl"
        exit 1
    fi
    command -v wmctrl >/dev/null 2>&1 \
        || echo "Warning: wmctrl not found; Big Picture exit will only be detected when Steam closes."


[group('Open Couch')]
[doc('Installs the Open Couch host script (required for the Flatpak app to work)')]
install-open-couch: _check-deps
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_URL="{{REPO_URL}}"
    DEST="{{DEST}}"
    mkdir -p "$DEST"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fsSL "${REPO_URL}/open-couch-engine"     -o "${tmpdir}/open-couch-engine"
    curl -fsSL "${REPO_URL}/open-couch-log-viewer" -o "${tmpdir}/open-couch-log-viewer"
    curl -fsSL "${REPO_URL}/SHA256SUMS"            -o "${tmpdir}/SHA256SUMS"
    (cd "$tmpdir" && sha256sum -c SHA256SUMS --ignore-missing --quiet) \
        || { echo "SHA256 verification failed - aborting." >&2; exit 1; }
    install -m755 "${tmpdir}/open-couch-engine"     "${DEST}/open-couch-engine"
    install -m755 "${tmpdir}/open-couch-log-viewer"     "${DEST}/open-couch-log-viewer"
    echo "Open Couch engine v{{OPEN_COUCH_VERSION}} installed at ${DEST}."
    if command -v flatpak >/dev/null 2>&1 && flatpak list --app --columns=application 2>/dev/null | grep -qx 'io.github.gustavobelo.opencouch'; then
        echo "The Open Couch app is already installed. Click Refresh Status on the dashboard to use the engine."
    else
        echo "Now install the Open Couch app (Flatpak) to use the engine:"
        echo "  flatpak install flathub io.github.gustavobelo.opencouch"
    fi

[group('Open Couch')]
[doc('Update the Open Couch host script to the latest packaged version')]
update-open-couch:
    #!/usr/bin/env bash
    set -euo pipefail
    REPO_URL="{{REPO_URL}}"
    DEST="{{DEST}}"
    mkdir -p "$DEST"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    echo "Updating Open Couch engine to v{{OPEN_COUCH_VERSION}}..."
    curl -fsSL "${REPO_URL}/open-couch-engine"      -o "${tmpdir}/open-couch-engine"
    curl -fsSL "${REPO_URL}/open-couch-log-viewer"  -o "${tmpdir}/open-couch-log-viewer" 
    curl -fsSL "${REPO_URL}/SHA256SUMS"             -o "${tmpdir}/SHA256SUMS" 
    (cd "$tmpdir" && sha256sum -c SHA256SUMS --ignore-missing --quiet) \
        || { echo "SHA256 verification failed - aborting." >&2; exit 1; }
    install -m755 "${tmpdir}/open-couch-engine"     "${DEST}/open-couch-engine"
    install -m755 "${tmpdir}/open-couch-log-viewer"     "${DEST}/open-couch-log-viewer"
    echo "Open Couch engine updated to v{{OPEN_COUCH_VERSION}} at ${DEST}."
    if command -v flatpak >/dev/null 2>&1 && flatpak list --app --columns=application 2>/dev/null | grep -qx 'io.github.gustavobelo.opencouch'; then
        echo "The Open Couch app is already installed. Click Refresh Status on the dashboard to use the engine."
    else
        echo "Now install the Open Couch app (Flatpak) to use the engine:"
        echo "  flatpak install flathub io.github.gustavobelo.opencouch"
    fi

[group('Open Couch')]
[doc('Removes the Open Couch host script')]
remove-open-couch:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f "{{DEST}}/open-couch-engine" "{{DEST}}/open-couch-log-viewer"
    echo "Open Couch engine removed."
