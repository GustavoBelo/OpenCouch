#!/usr/bin/env bash
set -euo pipefail

# Installs the Open Couch engine into ~/.local/bin.
#
# The engine is a static Go binary with no runtime dependencies, so this is a
# download and a checksum -- there is nothing to compile and nothing to pull in.
# It is here for people who want the console without a package, and it is what
# the application's own "Install" button calls.
#
# Prefer a native package where one exists: it puts the engine on PATH for every
# account, which is what lets the hosting session entry be installed system-wide
# and removes the one step in setup that needs root.
#
#   curl -fsSL https://raw.githubusercontent.com/GustavoBelo/OpenCouch/main/packaging/host/install.sh | bash

# Bumped automatically by release.sh, do not edit manually
SELF_VERSION="2.0.1"

REPO="GustavoBelo/OpenCouch"
DEST_DIR="${HOME}/.local/bin"
ENGINE="open-couch-engine"

# What the engine's own `check` prints. Kept in step with CheckIdentity in
# engine/cmd/open-couch-engine/main.go and kCheckIdentity in
# app/src/engineclient.cpp -- an exit code alone cannot tell this engine from
# the bash one it replaced.
CHECK_IDENTITY="open-couch-engine console-mode/1"

die() { printf 'Error: %s\n' "$1" >&2; exit 1; }

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) die "unsupported architecture $(uname -m); build from source with 'go install github.com/${REPO}/engine/cmd/${ENGINE}@latest'" ;;
    esac
}

check_host() {
    local cmd
    local -a missing=()
    # Only what the engine cannot do without. gamescope and Steam are checked by
    # `open-couch-engine doctor`, which reports far better than this can.
    for cmd in systemctl pactl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || die "missing on this host: ${missing[*]}"
}

install_engine() {
    local arch tmpdir asset
    arch="$(detect_arch)"
    asset="${ENGINE}-linux-${arch}"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    local base="https://github.com/${REPO}/releases/download/v${SELF_VERSION}"
    printf 'Downloading %s v%s (%s)...\n' "${ENGINE}" "${SELF_VERSION}" "${arch}"
    curl -fsSL "${base}/${asset}" -o "${tmpdir}/${asset}" \
        || die "could not download ${asset} from release v${SELF_VERSION}"
    curl -fsSL "${base}/SHA256SUMS" -o "${tmpdir}/SHA256SUMS" \
        || die "could not download SHA256SUMS from release v${SELF_VERSION}"

    (cd "${tmpdir}" && sha256sum -c SHA256SUMS --ignore-missing --quiet) \
        || die "checksum mismatch; refusing to install"

    mkdir -p "${DEST_DIR}"
    install -Dm755 "${tmpdir}/${asset}" "${DEST_DIR}/${ENGINE}"
}

verify() {
    local got
    got="$("${DEST_DIR}/${ENGINE}" check 2>/dev/null || true)"
    [[ "${got}" == "${CHECK_IDENTITY}" ]] \
        || die "the installed binary does not identify itself as this engine (got '${got}')"
    printf 'Installed %s %s to %s\n' "${ENGINE}" "$("${DEST_DIR}/${ENGINE}" version)" "${DEST_DIR}"
}

check_host
install_engine
verify

case ":${PATH}:" in
    *":${DEST_DIR}:"*) ;;
    *) printf '\nNote: %s is not on your PATH. Add it to your shell profile.\n' "${DEST_DIR}" ;;
esac

printf '\nNext: %s/%s doctor\n' "${DEST_DIR}" "${ENGINE}"
