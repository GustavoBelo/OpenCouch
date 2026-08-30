#!/usr/bin/env bash
set -euo pipefail

# tests/run.sh — runs the engine test suite.
#
#   tests/run.sh                 everything
#   tests/run.sh unit            only the unit tests
#   tests/run.sh e2e             only the end-to-end tests
#   tests/run.sh unit/kde_driver.bats   one file
#
# bats is used if installed; otherwise it is fetched once into tests/.bats
# (gitignored), so the suite needs no root and no system packages.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

BATS="$(command -v bats || true)"
if [[ -z "$BATS" ]]; then
    VENDOR="${HERE}/.bats/bats-core"
    if [[ ! -x "${VENDOR}/bin/bats" ]]; then
        printf 'bats not found; fetching it into %s\n' "${VENDOR}" >&2
        mkdir -p "$(dirname "$VENDOR")"
        git clone --depth 1 --quiet https://github.com/bats-core/bats-core.git "$VENDOR"
    fi
    BATS="${VENDOR}/bin/bats"
fi

if (($# > 0)); then
    exec "$BATS" "$@"
fi

printf '\n=== unit ===\n'
"$BATS" "${HERE}/unit"

# The end-to-end suite runs twice: against the dispatcher sources, and against
# the concatenated backend/open-couch-engine that actually ships. The
# concatenation step is where cross-compositor regressions have hidden before,
# so passing on one proves nothing about the other.
printf '\n=== e2e (dispatcher sources) ===\n'
OC_ENGINE_BIN="${ROOT}/backend/dispatcher.sh" "$BATS" "${HERE}/e2e"

printf '\n=== e2e (generated open-couch-engine) ===\n'
OC_ENGINE_BIN="${ROOT}/backend/open-couch-engine" "$BATS" "${HERE}/e2e"
