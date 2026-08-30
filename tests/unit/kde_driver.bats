#!/usr/bin/env bats
#
# The KDE driver talks to the compositor through kscreen-doctor only. The
# assertions here are on the exact argument list it produces: a layout applied
# with the wrong mode, scale or position fails silently on a real session.

load '../helpers/common'

setup() {
    oc_sandbox
    oc_as_kde
    oc_load_engine kde
    KEEP_DESK_ENABLED="false"
    MIRROR_DESK_TO_TV="false"
}

@test "check_deps reports every required and optional command" {
    run oc_stdout kde_check_deps
    [[ "$output" == *"kde:jq:present"* ]]
    [[ "$output" == *"kde:kscreen-doctor:present"* ]]
    [[ "$output" == *"kde:pgrep:present"* ]]
    [[ "$output" == *"kde:wmctrl:present"* ]]
}

@test "capabilities report wmctrl as absent when it is not installed" {
    run oc_stdout kde_capabilities_json
    [[ "$(jq -r '.window_management' <<<"$output")" == "true" ]]
    [[ "$(jq -r '.display.primary_output' <<<"$output")" == "true" ]]

    PATH="/usr/bin:/bin" run oc_stdout kde_capabilities_json
    [[ "$(jq -r '.window_management' <<<"$output")" == "false" ]]
}

@test "list_outputs_json normalizes to the shared shape and drops disconnected outputs" {
    OC_KSCREEN_JSON="${OC_TESTS}/fixtures/kde/tv-disconnected.json"
    run oc_stdout kde_list_outputs_json
    [[ "$(jq -r 'length' <<<"$output")" == "1" ]]
    [[ "$(jq -r '.[0].name' <<<"$output")" == "DP-1" ]]
    [[ "$(jq -r '.[0].pos' <<<"$output")" == "0,0" ]]
    [[ "$(jq -r '.[0].currentMode' <<<"$output")" == "1920x1080@300" ]]
}

@test "switch_to_tv turns the TV on and the desk off by default" {
    run kde_switch_to_tv
    [[ "$status" -eq 0 ]]
    oc_assert_called "kscreen-doctor output.HDMI-A-1.enable output.HDMI-A-1.mode.3840x2160@120 output.HDMI-A-1.scale.1.7 output.HDMI-A-1.position.0,0 output.HDMI-A-1.priority.1 output.DP-1.disable"
}

@test "switch_to_tv keeps the desk beside the TV when KEEP_DESK_ENABLED is true" {
    KEEP_DESK_ENABLED="true"
    run kde_switch_to_tv
    [[ "$status" -eq 0 ]]
    # 3840 / 1.7 rounded up = 2259: the desk starts where the TV ends.
    oc_assert_called "output.DP-1.enable output.DP-1.mode.1920x1080@300 output.DP-1.scale.1 output.DP-1.position.2259,0 output.DP-1.priority.2"
    oc_assert_not_called "output.DP-1.disable"
}

@test "switch_to_tv mirrors on a mode both displays actually have" {
    KEEP_DESK_ENABLED="true"
    MIRROR_DESK_TO_TV="true"
    run kde_switch_to_tv
    [[ "$status" -eq 0 ]]
    # The TV's 4K modes are not on the desk display; 1920x1080@60 is shared.
    oc_assert_called "output.HDMI-A-1.mode.1920x1080@60"
    oc_assert_called "output.DP-1.mode.1920x1080@60"
    oc_assert_called "output.DP-1.position.0,0"
    oc_assert_called "output.HDMI-A-1.position.0,0"
}

@test "switch_to_tv refuses to run when the TV is disconnected" {
    OC_KSCREEN_JSON="${OC_TESTS}/fixtures/kde/tv-disconnected.json"
    run kde_switch_to_tv
    [[ "$status" -ne 0 ]]
    oc_assert_not_called "output.DP-1.disable"
}

@test "save_snapshot records both outputs in the shared X,Y format" {
    run save_snapshot
    [[ "$status" -eq 0 ]]
    [[ -f "$SNAPSHOT_FILE" ]]

    # shellcheck source=/dev/null
    source "$SNAPSHOT_FILE"
    [[ "$DESK_OUTPUT" == "DP-1" ]]
    [[ "$DESK_ENABLED" == "true" ]]
    [[ "$DESK_POS" == "0,0" ]]
    [[ "$DESK_MODE" == "1920x1080@300" ]]
    [[ "$TV_POS" == "1920,0" ]]
    [[ "$TV_SCALE" == "1.7" ]]
    [[ "$TV_MODE" == "3840x2160@120" ]]
}

@test "save_snapshot refuses when the TV is not connected" {
    OC_KSCREEN_JSON="${OC_TESTS}/fixtures/kde/tv-disconnected.json"
    run save_snapshot
    [[ "$status" -ne 0 ]]
}

@test "restore_layout replays the snapshot and then deletes it" {
    save_snapshot
    : >"$OC_CALLLOG"

    run kde_restore_layout
    [[ "$status" -eq 0 ]]
    oc_assert_called "output.DP-1.enable output.DP-1.mode.1920x1080@300 output.DP-1.scale.1 output.DP-1.position.0,0 output.DP-1.priority.1"
    oc_assert_called "output.HDMI-A-1.enable output.HDMI-A-1.mode.3840x2160@120 output.HDMI-A-1.scale.1.7 output.HDMI-A-1.position.1920,0 output.HDMI-A-1.priority.2"
    [[ ! -f "$SNAPSHOT_FILE" ]]
}

@test "restore_layout disables an output that was disabled when the snapshot was taken" {
    OC_KSCREEN_JSON="${OC_TESTS}/fixtures/kde/tv-primary.json"
    save_snapshot
    : >"$OC_CALLLOG"

    run kde_restore_layout
    [[ "$status" -eq 0 ]]
    oc_assert_called "output.DP-1.disable"
}

@test "restore_layout falls back to the default desktop layout without a snapshot" {
    [[ ! -f "$SNAPSHOT_FILE" ]]
    run kde_restore_layout
    [[ "$status" -eq 0 ]]
    oc_assert_called "output.DP-1.enable"
    oc_assert_called "output.DP-1.position.0,0"
    oc_assert_called "output.HDMI-A-1.position.1920,0"
    run oc_log_file
    [[ "$output" == *"snapshot missing; using desktop fallback"* ]]
}

@test "restore fallback brings the desk back even with no TV attached" {
    OC_KSCREEN_JSON="${OC_TESTS}/fixtures/kde/tv-disconnected.json"
    run kde_restore_fallback_layout
    [[ "$status" -eq 0 ]]
    oc_assert_called "output.DP-1.enable"
    oc_assert_not_called "output.HDMI-A-1.enable"
}

@test "window_action reports not-open instead of crashing when wmctrl is missing" {
    PATH="/usr/bin:/bin" run kde_window_action is_open 'steam'
    [[ "$status" -ne 0 ]]
}

@test "window_action finds Big Picture in the wmctrl listing" {
    oc_bigpicture_open
    run kde_window_action is_open '([Ss]team|[Bb]ig.?[Pp]icture)'
    [[ "$status" -eq 0 ]]

    oc_bigpicture_closed
    run kde_window_action is_open '([Ss]team|[Bb]ig.?[Pp]icture)'
    [[ "$status" -ne 0 ]]
}

@test "move_steam_to_desk_monitor is a no-op without wmctrl" {
    run env PATH="/usr/bin:/bin" bash -c '
        source "'"${OC_ROOT}"'/backend/lib/common.sh"
        source "'"${OC_ROOT}"'/backend/drivers/kde.sh"
        trap - ERR
        kde_move_steam_to_desk_monitor
    '
    [[ "$status" -eq 0 ]]
}
