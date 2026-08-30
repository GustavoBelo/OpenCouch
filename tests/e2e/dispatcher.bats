#!/usr/bin/env bats
#
# End-to-end runs of the engine as a subprocess. tests/run.sh executes this file
# twice: once against backend/dispatcher.sh and once against the concatenated
# backend/open-couch-engine, because the concatenation step is exactly where
# cross-compositor regressions have hidden.

load '../helpers/common'

setup() {
    oc_sandbox
    oc_use_drm_fixture
}

@test "version prints the engine version" {
    oc_as_kde
    run oc_engine version
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "an unknown command prints the usage and fails" {
    oc_as_kde
    run oc_engine not-a-command
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "detect reports the running compositor" {
    oc_as_kde
    run oc_engine detect
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"kde"* ]]

    oc_as_hyprland
    run oc_engine detect
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"hyprland"* ]]
}

@test "capabilities are valid JSON for both supported compositors" {
    oc_as_kde
    run oc_stdout oc_engine capabilities
    [[ "$status" -eq 0 ]]
    [[ "$(jq -r '.compositor' <<<"$output")" == "kde" ]]
    [[ "$(jq -r '.display.primary_output' <<<"$output")" == "true" ]]

    oc_as_hyprland
    run oc_stdout oc_engine capabilities
    [[ "$status" -eq 0 ]]
    [[ "$(jq -r '.compositor' <<<"$output")" == "hyprland" ]]
    # Hyprland has no primary-output concept.
    [[ "$(jq -r '.display.primary_output' <<<"$output")" == "false" ]]
}

@test "check passes on a complete KDE host" {
    oc_as_kde
    run oc_engine check
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Host dependencies OK"* ]]
}

@test "check fails on a KDE session without kscreen-doctor" {
    # Detection falls through to 'unknown' there. The engine used to answer
    # "Host dependencies OK" anyway, which is the worst possible reply.
    oc_as_kde
    run env PATH="/usr/bin:/bin" "$OC_ENGINE_BIN" check
    [[ "$status" -ne 0 ]]
    [[ "$output" != *"Host dependencies OK"* ]]
}

@test "check fails when no supported compositor is detected" {
    unset HYPRLAND_INSTANCE_SIGNATURE
    export XDG_CURRENT_DESKTOP=""
    export XDG_SESSION_TYPE="wayland"
    run oc_engine check
    [[ "$status" -ne 0 ]]
}

@test "play and restore refuse to run without a supported compositor" {
    unset HYPRLAND_INSTANCE_SIGNATURE
    export XDG_CURRENT_DESKTOP=""
    export XDG_SESSION_TYPE="wayland"

    run oc_engine play
    [[ "$status" -ne 0 ]]
    oc_assert_not_called "kscreen-doctor"

    run oc_engine restore
    [[ "$status" -ne 0 ]]
}

@test "outputs lists the connected displays on KDE" {
    oc_as_kde
    run oc_stdout oc_engine outputs
    [[ "$status" -eq 0 ]]
    [[ "$(jq -r 'length' <<<"$output")" == "2" ]]
    [[ "$(jq -r '.[0].name' <<<"$output")" == "DP-1" ]]
}

@test "outputs lists the connected displays on Hyprland" {
    oc_as_hyprland
    run oc_stdout oc_engine outputs
    [[ "$status" -eq 0 ]]
    [[ "$(jq -r 'length' <<<"$output")" == "2" ]]
    [[ "$(jq -r '.[] | select(.name=="HDMI-A-1") | .modes[0]' <<<"$output")" == "3840x2160@120" ]]
}

@test "outputs answers an empty list instead of failing with no compositor" {
    unset HYPRLAND_INSTANCE_SIGNATURE
    export XDG_CURRENT_DESKTOP=""
    export XDG_SESSION_TYPE="wayland"
    run oc_stdout oc_engine outputs
    [[ "$status" -eq 0 ]]
    [[ "$output" == "[]" ]]
}

@test "status reports the desk and TV roles as JSON" {
    oc_as_kde
    run oc_stdout oc_engine status
    [[ "$status" -eq 0 ]]
    [[ "$(jq -r '.[0].role' <<<"$output")" == "desk" ]]
    [[ "$(jq -r '.[0].name' <<<"$output")" == "DP-1" ]]
    [[ "$(jq -r '.[1].role' <<<"$output")" == "tv" ]]
    [[ "$(jq -r '.[1].pos' <<<"$output")" == "1920,0" ]]
}

@test "status reports null priority on Hyprland and a number on KDE" {
    oc_as_kde
    run oc_stdout oc_engine status
    [[ "$(jq -r '.[0].priority' <<<"$output")" == "1" ]]

    oc_as_hyprland
    run oc_stdout oc_engine status
    [[ "$(jq -r '.[0].priority' <<<"$output")" == "null" ]]
}

@test "config-path points inside the sandboxed XDG config dir" {
    oc_as_kde
    run oc_engine config-path
    [[ "$output" == "${XDG_CONFIG_HOME}/open-couch-engine/config.env" ]]
}

@test "the engine reads DESK_OUTPUT and TV_OUTPUT from config.env" {
    oc_as_kde
    oc_write_config <<'EOF'
DESK_OUTPUT="HDMI-A-1"
TV_OUTPUT="DP-1"
EOF
    run oc_stdout oc_engine status
    [[ "$(jq -r '.[0].name' <<<"$output")" == "HDMI-A-1" ]]
    [[ "$(jq -r '.[1].name' <<<"$output")" == "DP-1" ]]
}

@test "log, append-log and clear-log round-trip" {
    oc_as_kde
    run oc_engine append-log "hello from the test"
    [[ "$status" -eq 0 ]]

    run oc_stdout oc_engine log
    [[ "$output" == *"hello from the test"* ]]

    run oc_engine clear-log
    [[ "$status" -eq 0 ]]
    run oc_stdout oc_engine log
    [[ "$output" != *"hello from the test"* ]]
}

@test "log-history lists archived logs and refuses a traversal id" {
    oc_as_kde
    oc_engine append-log "seed" >/dev/null 2>&1

    run oc_stdout oc_engine log-history
    [[ "$status" -eq 0 ]]

    run oc_engine print-history-log "../../../etc/passwd"
    [[ "$status" -ne 0 ]]
}

@test "status logs the missing optional component instead of staying quiet" {
    oc_as_kde
    # wmctrl is optional on KDE: its absence is a WARNING in the log, not a
    # failure, and the app surfaces it from there.
    local slim="${OC_TMP}/bin-no-wmctrl"
    mkdir -p "$slim"
    cp -a "${OC_TESTS}/helpers/bin/." "$slim/"
    rm -f "${slim}/wmctrl"

    run env PATH="${slim}:/usr/bin:/bin" "$OC_ENGINE_BIN" status
    [[ "$status" -eq 0 ]]
    run oc_log_file
    [[ "$output" == *"Missing optional host component(s): wmctrl"* ]]
}
