#!/usr/bin/env bats
#
# The full couch-mode session, driven as a subprocess: apply the TV layout,
# watch Big Picture, restore the desk. Steam is a shim and the "Steam process"
# is a sleep the test owns, so the whole run takes a couple of seconds.

load '../helpers/common'

STEAM_PID=""
ENGINE_PID=""

setup() {
    # Job control on: without it bash sets SIGINT to SIG_IGN in asynchronous
    # commands, the engine cannot install its INT trap, and `kill -INT` on the
    # background job does nothing. A real Ctrl-C in a terminal is delivered to
    # the foreground process group, where SIGINT is not ignored.
    set -m
    oc_sandbox
    oc_use_drm_fixture
    oc_bigpicture_open
    # The engine follows this pid to decide when the session is over.
    sleep 120 >/dev/null 2>&1 &
    STEAM_PID=$!
    export OC_PGREP_OUT="$STEAM_PID"
}

teardown() {
    # Nothing may outlive a test: a surviving child keeps bats' output pipe
    # open and the whole run stops making progress.
    [[ -n "$ENGINE_PID" ]] && kill -TERM "$ENGINE_PID" 2>/dev/null
    [[ -n "$STEAM_PID" ]] && kill -TERM "$STEAM_PID" 2>/dev/null
    local i
    for ((i = 0; i < 40; i++)); do
        kill -0 "${ENGINE_PID:-0}" 2>/dev/null || break
        sleep 0.05
    done
    [[ -n "$ENGINE_PID" ]] && kill -KILL "$ENGINE_PID" 2>/dev/null
    [[ -n "$STEAM_PID" ]] && kill -KILL "$STEAM_PID" 2>/dev/null
    return 0
}

@test "play switches to the TV and restores the desk when Big Picture closes" {
    oc_as_kde

    "$OC_ENGINE_BIN" play >/dev/null 2>&1 &
    ENGINE_PID=$!

    # Wait until Big Picture has actually been seen; closing the window before
    # the engine looks for it would send it into a 60s detection loop.
    oc_wait_for_log "Big Picture detected, monitoring"
    [[ -f "${XDG_STATE_HOME}/open-couch-engine/layout.env" ]]
    [[ -f "${XDG_STATE_HOME}/open-couch-engine/session.pid" ]]

    : >"$OC_CALLLOG"
    oc_bigpicture_closed          # the user quit Big Picture

    wait "$ENGINE_PID" || true
    oc_assert_called "kscreen-doctor output.DP-1.enable"
    # The snapshot and the session file are cleaned up on the way out.
    [[ ! -f "${XDG_STATE_HOME}/open-couch-engine/layout.env" ]]
    [[ ! -f "${XDG_STATE_HOME}/open-couch-engine/session.pid" ]]
}

@test "Ctrl-C during play still brings the desk monitor back" {
    # The regression this exists for: the EXIT/INT/TERM trap called a function
    # that no longer existed, `|| true` swallowed the error, and interrupting a
    # session left the desk display switched off with no way back but a reboot
    # or a manual kscreen-doctor call.
    oc_as_kde

    "$OC_ENGINE_BIN" play >/dev/null 2>&1 &
    ENGINE_PID=$!

    oc_wait_for_log "Big Picture detected, monitoring"
    : >"$OC_CALLLOG"

    kill -INT "$ENGINE_PID"
    wait "$ENGINE_PID" || true

    oc_assert_called "kscreen-doctor output.DP-1.enable"
    [[ ! -f "${XDG_STATE_HOME}/open-couch-engine/session.pid" ]]
}

@test "SIGTERM during play restores the desk too" {
    oc_as_kde

    "$OC_ENGINE_BIN" play >/dev/null 2>&1 &
    ENGINE_PID=$!

    oc_wait_for_log "Big Picture detected, monitoring"
    : >"$OC_CALLLOG"

    kill -TERM "$ENGINE_PID"
    wait "$ENGINE_PID" || true

    oc_assert_called "kscreen-doctor output.DP-1.enable"
}

@test "Ctrl-C during play brings the desk back on Hyprland as well" {
    oc_as_hyprland
    export OC_HYPR_API_PROBE="function"

    "$OC_ENGINE_BIN" play >/dev/null 2>&1 &
    ENGINE_PID=$!

    oc_wait_for_log "Big Picture detected, monitoring"
    : >"$OC_CALLLOG"

    kill -INT "$ENGINE_PID"
    wait "$ENGINE_PID" || true

    run oc_calls_to hyprctl
    [[ "$output" == *'output = "DP-1"'* ]]
    [[ "$output" != *'disabled = true'* ]]
}

@test "a second play refuses to start while a session is live" {
    oc_as_kde

    "$OC_ENGINE_BIN" play >/dev/null 2>&1 &
    ENGINE_PID=$!
    oc_wait_for_log "Big Picture detected, monitoring"

    run "$OC_ENGINE_BIN" play
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"already running"* ]]

    kill -INT "$ENGINE_PID"
    wait "$ENGINE_PID" || true
}

@test "restore closes Big Picture and replays the snapshot" {
    oc_as_kde

    "$OC_ENGINE_BIN" play >/dev/null 2>&1 &
    ENGINE_PID=$!
    oc_wait_for_log "Big Picture detected, monitoring"
    : >"$OC_CALLLOG"

    oc_bigpicture_closed
    run "$OC_ENGINE_BIN" restore
    [[ "$status" -eq 0 ]]
    # The window is closed through wmctrl, and the desk comes back.
    oc_assert_called "wmctrl"
    oc_assert_called "output.DP-1.enable"

    wait "$ENGINE_PID" || true
}

@test "restore works with no session at all, straight from the fallback layout" {
    oc_as_kde
    oc_bigpicture_closed

    run "$OC_ENGINE_BIN" restore
    [[ "$status" -eq 0 ]]
    oc_assert_called "output.DP-1.enable"
    oc_assert_called "output.HDMI-A-1.position.1920,0"
}
