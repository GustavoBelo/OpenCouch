#!/usr/bin/env bats
#
# `watch` is the mode that reacts to Big Picture started by Steam itself. On the
# branch where the Hyprland driver hijacked big_picture_window_present(), this
# never triggered on KDE at all.

load '../helpers/common'

ENGINE_PID=""

setup() {
    set -m
    oc_sandbox
    oc_use_drm_fixture
    oc_bigpicture_closed
}

teardown() {
    [[ -n "$ENGINE_PID" ]] && kill -TERM "$ENGINE_PID" 2>/dev/null
    local i
    for ((i = 0; i < 40; i++)); do
        kill -0 "${ENGINE_PID:-0}" 2>/dev/null || break
        sleep 0.05
    done
    [[ -n "$ENGINE_PID" ]] && kill -KILL "$ENGINE_PID" 2>/dev/null
    return 0
}

@test "watch applies the TV layout when Big Picture shows up, and undoes it when it goes" {
    oc_as_kde

    "$OC_ENGINE_BIN" watch >/dev/null 2>&1 &
    ENGINE_PID=$!

    oc_wait_for_log "monitoring Big Picture started by Steam"
    oc_assert_not_called "output.DP-1.disable"

    oc_bigpicture_open
    oc_wait_for_log "Big Picture detected, couch layout applied"
    oc_assert_called "output.DP-1.disable"

    : >"$OC_CALLLOG"
    oc_bigpicture_closed
    oc_wait_for_log "Big Picture closed, desktop layout restored"
    oc_assert_called "output.DP-1.enable"
}

@test "watch does the same on Hyprland" {
    oc_as_hyprland
    export OC_HYPR_API_PROBE="function"

    "$OC_ENGINE_BIN" watch >/dev/null 2>&1 &
    ENGINE_PID=$!

    oc_wait_for_log "monitoring Big Picture started by Steam"

    oc_bigpicture_open
    oc_wait_for_log "Big Picture detected, couch layout applied"
    run oc_calls_to hyprctl
    [[ "$output" == *'output = "DP-1", disabled = true'* ]]
}

@test "watch stays out of the way while a play session owns the state" {
    oc_as_kde
    mkdir -p "${XDG_STATE_HOME}/open-couch-engine"
    printf '%s\n' "$$" >"${XDG_STATE_HOME}/open-couch-engine/session.pid"

    "$OC_ENGINE_BIN" watch >/dev/null 2>&1 &
    ENGINE_PID=$!

    oc_wait_for_log "monitoring Big Picture started by Steam"
    oc_bigpicture_open
    sleep 1
    # A live session file means `play` is driving; watch must not touch the layout.
    oc_assert_not_called "output.DP-1.disable"
}

@test "watch refuses to start on KDE without wmctrl" {
    oc_as_kde
    local slim="${OC_TMP}/bin-no-wmctrl"
    mkdir -p "$slim"
    cp -a "${OC_TESTS}/helpers/bin/." "$slim/"
    rm -f "${slim}/wmctrl"

    run env PATH="${slim}:/usr/bin:/bin" "$OC_ENGINE_BIN" watch
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"wmctrl"* ]]
}
