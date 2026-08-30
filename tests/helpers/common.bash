# Shared setup for the open-couch engine test suite.
#
# Two levels are available:
#
#   oc_load_engine <compositor>   source lib/ + drivers/ into the current shell
#                                 and bind the driver_* contract, for unit tests
#   oc_engine <args...>           run the engine end to end as a subprocess
#
# Everything the engine touches -- config, state, host commands, DRM sysfs and
# /dev/input -- is redirected into the per-test temp dir, so no test can read or
# change the real session.

OC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OC_TESTS="${OC_ROOT}/tests"
export OC_ROOT OC_TESTS

# Which engine the e2e suite exercises: the dispatcher sources (default) or the
# concatenated artifact. tests/run.sh runs the same files against both.
: "${OC_ENGINE_BIN:=${OC_ROOT}/backend/dispatcher.sh}"
export OC_ENGINE_BIN

oc_sandbox() {
    OC_TMP="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
    export OC_TMP
    export HOME="${OC_TMP}/home"
    export XDG_CONFIG_HOME="${OC_TMP}/config"
    export XDG_STATE_HOME="${OC_TMP}/state"
    export XDG_DATA_HOME="${OC_TMP}/data"
    export OC_CALLLOG="${OC_TMP}/calls.log"
    export OC_DRM_ROOT="${OC_TMP}/drm"
    export OC_INPUT_ROOT="${OC_TMP}/input"
    export USER="${USER:-tester}"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
             "$OC_DRM_ROOT" "$OC_INPUT_ROOT"
    : >"$OC_CALLLOG"

    # Shims win over anything installed on the machine running the suite.
    export PATH="${OC_TESTS}/helpers/bin:${PATH}"

    # Defaults; individual tests override what they care about.
    export OC_KSCREEN_JSON="${OC_TESTS}/fixtures/kde/desk-and-tv.json"
    export OC_HYPR_MONITORS="${OC_TESTS}/fixtures/hyprland/monitors.json"

    # Window state lives at a FIXED path whose contents the test rewrites. A
    # running engine has already inherited its environment, so pointing an
    # OC_* variable somewhere else mid-test would never reach it.
    export OC_HYPR_CLIENTS="${OC_TMP}/clients.json"
    export OC_WMCTRL_LIST="${OC_TMP}/windows.txt"
    cp "${OC_TESTS}/fixtures/hyprland/clients-desktop.json" "$OC_HYPR_CLIENTS"
    : >"$OC_WMCTRL_LIST"

    export DESK_OUTPUT="DP-1"
    export TV_OUTPUT="HDMI-A-1"
}

# Point OC_DRM_ROOT at the fixture connector tree (DP-1 and HDMI-A-1 connected,
# DP-3 disconnected).
oc_use_drm_fixture() {
    cp -a "${OC_TESTS}/fixtures/drm/." "${OC_DRM_ROOT}/"
}

oc_write_config() {
    mkdir -p "${XDG_CONFIG_HOME}/open-couch-engine"
    cat >"${XDG_CONFIG_HOME}/open-couch-engine/config.env"
}

# Pretend N controllers are plugged in.
oc_controllers() {
    local count="$1" i
    rm -f "${OC_INPUT_ROOT}"/js*
    for ((i = 0; i < count; i++)); do : >"${OC_INPUT_ROOT}/js${i}"; done
}

oc_load_engine() {
    local compositor="${1:-}"
    # Same order as backend/dispatcher.sh.
    # shellcheck source=/dev/null
    source "${OC_ROOT}/backend/lib/common.sh"
    # shellcheck source=/dev/null
    source "${OC_ROOT}/backend/lib/detect.sh"
    local d
    for d in generic gnome hyprland kde; do
        # shellcheck source=/dev/null
        source "${OC_ROOT}/backend/drivers/${d}.sh"
    done
    # common.sh installs `trap on_error ERR` for the running engine; inside a
    # bats test that would fire on every expected-failure assertion.
    trap - ERR
    [[ -z "$compositor" ]] || load_driver "$compositor"
}

# --- environment shorthands -------------------------------------------------

oc_as_kde() {
    export XDG_CURRENT_DESKTOP="KDE"
    export XDG_SESSION_TYPE="wayland"
    unset HYPRLAND_INSTANCE_SIGNATURE
}

oc_as_hyprland() {
    export HYPRLAND_INSTANCE_SIGNATURE="test_signature"
    export XDG_CURRENT_DESKTOP="Hyprland"
    export XDG_SESSION_TYPE="wayland"
}

# --- assertions on what the engine asked the host to do ---------------------

oc_calls() {
    cat "$OC_CALLLOG"
}

# All recorded calls to one command.
oc_calls_to() {
    grep -E "^$1( |\$)" "$OC_CALLLOG" || true
}

oc_assert_called() {
    if ! grep -qF -- "$1" "$OC_CALLLOG"; then
        printf 'expected a host call containing:\n  %s\ngot:\n%s\n' \
            "$1" "$(sed 's/^/  /' "$OC_CALLLOG")" >&2
        return 1
    fi
}

oc_assert_not_called() {
    if grep -qF -- "$1" "$OC_CALLLOG"; then
        printf 'did not expect a host call containing:\n  %s\ngot:\n%s\n' \
            "$1" "$(sed 's/^/  /' "$OC_CALLLOG")" >&2
        return 1
    fi
}

oc_engine() {
    "$OC_ENGINE_BIN" "$@"
}

oc_log_file() {
    cat "${XDG_STATE_HOME}/open-couch-engine/open-couch-engine.log" 2>/dev/null || true
}

# Most engine functions log to stderr, and bats' `run` merges stderr into
# $output. Wrap a call in this to assert on its stdout alone.
oc_stdout() {
    "$@" 2>/dev/null
}

# Wait (up to ~10s) for a host call matching a fixed string to show up.
oc_wait_for_call() {
    local needle="$1" i
    for ((i = 0; i < 200; i++)); do
        grep -qF -- "$needle" "$OC_CALLLOG" && return 0
        sleep 0.05
    done
    printf 'timed out waiting for a host call containing:\n  %s\ngot:\n%s\n' \
        "$needle" "$(sed 's/^/  /' "$OC_CALLLOG")" >&2
    return 1
}

# Pretend Big Picture is on screen (KDE reads wmctrl, Hyprland reads hyprctl).
oc_bigpicture_open() {
    printf '0x01 0 host steam.Steam  Steam Big Picture Mode\n' >"$OC_WMCTRL_LIST"
    cp "${OC_TESTS}/fixtures/hyprland/clients-bigpicture.json" "$OC_HYPR_CLIENTS"
}

oc_bigpicture_closed() {
    : >"$OC_WMCTRL_LIST"
    cp "${OC_TESTS}/fixtures/hyprland/clients-desktop.json" "$OC_HYPR_CLIENTS"
}

# Wait (up to ~15s) for a line to appear in the engine log.
oc_wait_for_log() {
    local needle="$1" i
    for ((i = 0; i < 300; i++)); do
        oc_log_file | grep -qF -- "$needle" && return 0
        sleep 0.05
    done
    printf 'timed out waiting for a log line containing:\n  %s\ngot:\n%s\n' \
        "$needle" "$(oc_log_file | sed 's/^/  /')" >&2
    return 1
}
