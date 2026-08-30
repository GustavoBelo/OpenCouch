#!/usr/bin/env bats
#
# Every assertion here maps to a bug that shipped silently: hyprctl refusing a
# command and still exiting 0, positions in the wrong format, a boolean test
# against an integer field, and a disabled output's 0x0 placeholder mode being
# offered in Setup and written into layout.env.

load '../helpers/common'

setup() {
    oc_sandbox
    oc_as_hyprland
    oc_use_drm_fixture
    oc_load_engine hyprland
    KEEP_DESK_ENABLED="false"
    MIRROR_DESK_TO_TV="false"
}

@test "monitor_api detects the Lua API when hl.monitor exists" {
    export OC_HYPR_API_PROBE="function"
    run oc_stdout hyprland_monitor_api
    [[ "$output" == "lua" ]]
}

@test "monitor_api falls back to the legacy keyword on older builds" {
    export OC_HYPR_API_PROBE=""
    run oc_stdout hyprland_monitor_api
    [[ "$output" == "keyword" ]]
}

@test "monitor_spec emits hl.monitor for the Lua API" {
    export OC_HYPR_API_PROBE="function"
    run oc_stdout hyprland_monitor_spec "DP-1" "1920x1080@300" "0x0" "1"
    [[ "$output" == 'hl.monitor({ output = "DP-1", mode = "1920x1080@300", position = "0x0", scale = 1 })' ]]

    run oc_stdout hyprland_monitor_spec "HDMI-A-1" disable
    [[ "$output" == 'hl.monitor({ output = "HDMI-A-1", disabled = true })' ]]
}

@test "monitor_spec emits the legacy keyword form on older builds" {
    export OC_HYPR_API_PROBE=""
    run oc_stdout hyprland_monitor_spec "DP-1" "1920x1080@300" "0x0" "1"
    [[ "$output" == 'keyword monitor DP-1,1920x1080@300,0x0,1' ]]

    run oc_stdout hyprland_monitor_spec "HDMI-A-1" disable
    [[ "$output" == 'keyword monitor HDMI-A-1,disable' ]]
}

@test "apply_monitors fails when hyprctl refuses the command but exits 0" {
    # The whole reason the Hyprland support did nothing: on Hyprland 0.5x
    # `hyprctl keyword monitor` answers
    #   "keyword can't work with non-legacy parsers. Use eval."
    # and exits 0, so a status check reports success while nothing happened.
    export OC_HYPR_API_PROBE=""
    export OC_HYPR_BATCH_OUT="keyword can't work with non-legacy parsers. Use eval."
    export OC_HYPR_BATCH_RC=0

    run hyprland_apply_monitors 'keyword monitor DP-1,1920x1080@300,0x0,1'
    [[ "$status" -ne 0 ]]
    run oc_log_file
    [[ "$output" == *"Hyprland refused the layout change"* ]]
}

@test "apply_monitors fails on an error reply from the Lua API" {
    export OC_HYPR_API_PROBE="function"
    export OC_HYPR_EVAL_OUT="Invalid monitor spec"
    export OC_HYPR_EVAL_RC=0
    run hyprland_apply_monitors 'hl.monitor({ output = "DP-1" })'
    [[ "$status" -ne 0 ]]
}

@test "apply_monitors succeeds on a clean reply" {
    export OC_HYPR_API_PROBE="function"
    export OC_HYPR_EVAL_OUT="ok"
    run hyprland_apply_monitors 'hl.monitor({ output = "DP-1" })'
    [[ "$status" -eq 0 ]]
}

@test "position converts the stored X,Y into Hyprland's XxY" {
    [[ "$(hyprland_position "1920,0")" == "1920x0" ]]
    [[ "$(hyprland_position "0,0")" == "0x0" ]]
    [[ "$(hyprland_position "-1920,120")" == "-1920x120" ]]
}

@test "position rejects garbage instead of producing a malformed spec" {
    [[ "$(hyprland_position "")" == "0x0" ]]
    [[ "$(hyprland_position "not,a,position")" == "0x0" ]]
    [[ "$(hyprland_position "1920")" == "0x0" ]]
}

@test "scale rejects empty and non-positive values" {
    [[ "$(hyprland_scale "1.7")" == "1.7" ]]
    [[ "$(hyprland_scale "1")" == "1" ]]
    # An empty scale used to reach the position maths and divide by zero.
    run hyprland_scale ""
    [[ "$status" -ne 0 ]]
    run hyprland_scale "0"
    [[ "$status" -ne 0 ]]
    run hyprland_scale "abc"
    [[ "$status" -ne 0 ]]
}

@test "connected outputs come from DRM sysfs, not from hyprctl" {
    # hyprctl reports connected:true for everything, so this is the only
    # trustworthy source. DP-3 is present in sysfs but disconnected.
    run oc_stdout hyprland_connected_outputs_json
    [[ "$(jq -r 'index("DP-1")' <<<"$output")" != "null" ]]
    [[ "$(jq -r 'index("HDMI-A-1")' <<<"$output")" != "null" ]]
    [[ "$(jq -r 'index("DP-3")' <<<"$output")" == "null" ]]
}

@test "get_layout_json reports priority as null because Hyprland has no primary output" {
    run oc_stdout hyprland_get_layout_json
    [[ "$(jq -r '.outputs[0].priority' <<<"$output")" == "null" ]]
    [[ "$(jq -r '.outputs[] | select(.name == "DP-1") | .connected' <<<"$output")" == "true" ]]
}

@test "get_layout_json keeps the shared internal shape the dispatcher expects" {
    run oc_stdout hyprland_get_layout_json
    [[ "$(jq -r '.outputs[] | select(.name=="HDMI-A-1") | .pos.x' <<<"$output")" == "1920" ]]
    # get_layout_json passes hyprctl's raw refresh rate through; only
    # list_outputs_json normalizes it. Both feed different consumers.
    [[ "$(jq -r '.outputs[] | select(.name=="HDMI-A-1") | .modes[0].name' <<<"$output")" == 3840x2160@120* ]]
}

@test "list_outputs_json normalizes modes to WxH@R and sorts them descending" {
    run oc_stdout hyprland_list_outputs_json
    local modes
    modes="$(jq -r '.[] | select(.name=="HDMI-A-1") | .modes | join(" ")' <<<"$output")"
    [[ "$modes" == "3840x2160@120 3840x2160@60 1920x1080@60" ]]
    # "3840x2160@120.00Hz", "3840x2160@120.00000" and "3840x2160@120" are the
    # same mode and must not appear three times.
    [[ "$(jq -r '.[] | select(.name=="HDMI-A-1") | .modes | length' <<<"$output")" == "3" ]]
}

@test "list_outputs_json never offers the 0x0 placeholder of a disabled output" {
    export OC_HYPR_MONITORS="${OC_TESTS}/fixtures/hyprland/monitors-desk-disabled.json"
    run oc_stdout hyprland_list_outputs_json
    [[ "$output" != *"0x0@"* ]]
    [[ "$(jq -r '.[] | select(.name=="DP-1") | .enabled' <<<"$output")" == "false" ]]
    [[ "$(jq -r '.[] | select(.name=="DP-1") | .currentMode' <<<"$output")" == "" ]]
    [[ "$(jq -r '.[] | select(.name=="DP-1") | .modes | length' <<<"$output")" == "0" ]]
}

@test "list_outputs_json drops DRM modes that carry no refresh rate" {
    run oc_stdout hyprland_list_outputs_json
    # /sys/class/drm/*/modes lists bare resolutions like "1920x1080".
    [[ "$output" != *'"1920x1080"'* ]]
}

@test "big_picture_window_present matches the integer fullscreen field" {
    # fullscreen and fullscreenClient are integers in `hyprctl clients -j`;
    # `.fullscreen == true` never matched and Big Picture went undetected.
    export OC_HYPR_CLIENTS="${OC_TESTS}/fixtures/hyprland/clients-bigpicture.json"
    run hyprland_big_picture_window_present
    [[ "$status" -eq 0 ]]

    export OC_HYPR_CLIENTS="${OC_TESTS}/fixtures/hyprland/clients-desktop.json"
    run hyprland_big_picture_window_present
    [[ "$status" -ne 0 ]]
}

@test "switch_to_tv sends XxY positions and a real mode" {
    export OC_HYPR_API_PROBE="function"
    run hyprland_switch_to_tv
    [[ "$status" -eq 0 ]]
    # Positions must never reach hyprctl in the stored "X,Y" form.
    run oc_calls_to hyprctl
    [[ "$output" == *'position = "0x0"'* ]]
    [[ "$output" != *'position = "0,0"'* ]]
    [[ "$output" != *"0x0@"* ]]
}

@test "switch_to_tv disables the desk output when the desk is not kept" {
    export OC_HYPR_API_PROBE="function"
    run hyprland_switch_to_tv
    [[ "$status" -eq 0 ]]
    run oc_calls_to hyprctl
    [[ "$output" == *'output = "DP-1", disabled = true'* ]]
}

@test "verify_output warns when a disable did not take effect" {
    # hyprctl still reports the monitor as enabled: known Hyprland issues.
    run hyprland_verify_output "DP-1" "false"
    run oc_log_file
    [[ "$output" == *"disable of DP-1 did not take effect"* ]]
}

@test "verify_output confirms a state that matches" {
    run hyprland_verify_output "DP-1" "true"
    run oc_log_file
    [[ "$output" == *"confirmed DP-1 enabled=true"* ]]
}

@test "monitors_json fails instead of returning junk when hyprctl answers nothing" {
    export OC_HYPR_MONITORS="/dev/null"
    run hyprland_monitors_json
    [[ "$status" -ne 0 ]]
}
