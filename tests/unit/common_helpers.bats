#!/usr/bin/env bats
#
# Pure helpers from backend/lib/common.sh. No compositor, no host commands.

load '../helpers/common'

KDE_FIXTURE=""

setup() {
    oc_sandbox
    oc_load_engine kde
    KDE_FIXTURE="$(cat "${OC_TESTS}/fixtures/kde/desk-and-tv.json")"
}

@test "version_gte compares semver numerically" {
    version_gte "1.7.0" "1.7.0"
    version_gte "1.8.0" "1.7.9"
    version_gte "2.0.0" "1.99.99"
    version_gte "1.10.0" "1.9.0"   # not string comparison
    ! version_gte "1.6.9" "1.7.0"
    ! version_gte "1.7.0" "1.7.1"
}

@test "version_gte rejects malformed versions instead of guessing" {
    ! version_gte "1.7" "1.7.0"
    ! version_gte "v1.7.0" "1.7.0"
    ! version_gte "" "1.7.0"
    ! version_gte "1.7.0" "not-a-version"
}

@test "version_gte handles zero-padded components without octal errors" {
    version_gte "1.08.0" "1.7.0"
}

@test "mode_exists finds only modes the output really has" {
    mode_exists "$KDE_FIXTURE" "DP-1" "1920x1080@300"
    ! mode_exists "$KDE_FIXTURE" "DP-1" "3840x2160@120"
    ! mode_exists "$KDE_FIXTURE" "DP-1" ""
    ! mode_exists "$KDE_FIXTURE" "NOPE-1" "1920x1080@300"
}

@test "resolve_mode returns the requested mode when it exists" {
    run resolve_mode "$KDE_FIXTURE" "HDMI-A-1" "3840x2160@120"
    [[ "$output" == "3840x2160@120" ]]
}

@test "resolve_mode falls back to the highest refresh rate of the same resolution" {
    # The cable came back with a mode the display no longer advertises.
    run oc_stdout resolve_mode "$KDE_FIXTURE" "DP-1" "1920x1080@240"
    [[ "$output" == "1920x1080@300" ]]
}

@test "resolve_mode returns nothing when the resolution is gone entirely" {
    run oc_stdout resolve_mode "$KDE_FIXTURE" "DP-1" "5120x1440@240"
    [[ -z "$output" ]]
}

@test "logical_width divides by the scale and rounds up" {
    run logical_width "3840x2160@120" "1.7"
    [[ "$output" == "2259" ]]
    run logical_width "1920x1080@60" "1"
    [[ "$output" == "1920" ]]
}

@test "logical_width falls back to 1920 for garbage input" {
    # An empty scale used to reach awk and divide by zero.
    run logical_width "3840x2160@120" ""
    [[ "$output" == "1920" ]]
    run logical_width "" "1"
    [[ "$output" == "1920" ]]
    run logical_width "3840x2160@120" "abc"
    [[ "$output" == "1920" ]]
}

@test "common_mirror_mode prefers the requested mode when both outputs have it" {
    run common_mirror_mode "$KDE_FIXTURE" "HDMI-A-1" "DP-1" "1920x1080@60"
    [[ "$output" == "1920x1080@60" ]]
}

@test "common_mirror_mode picks the largest shared mode when the request is not shared" {
    # The TV's 3840x2160 modes are not on the desk display.
    run common_mirror_mode "$KDE_FIXTURE" "HDMI-A-1" "DP-1" "3840x2160@120"
    [[ "$output" == "1920x1080@60" ]]
}

@test "output_snapshot_tsv emits the shared X,Y position format" {
    run output_snapshot_tsv "$KDE_FIXTURE" "HDMI-A-1"
    # connected, enabled, priority, pos, scale, mode
    [[ "$output" == $'true\ttrue\t2\t1920,0\t1.7\t3840x2160@120' ]]
}

@test "output_snapshot_tsv is empty for an output that is not there" {
    run output_snapshot_tsv "$KDE_FIXTURE" "NOPE-1"
    [[ -z "$output" ]]
}

@test "driver_name_from_id gives every supported compositor a display name" {
    [[ "$(driver_name_from_id kde)" == "KDE Plasma" ]]
    [[ "$(driver_name_from_id hyprland)" == "Hyprland" ]]
    [[ "$(driver_name_from_id gnome)" == "GNOME" ]]
    [[ "$(driver_name_from_id generic-x11)" == "Generic X11" ]]
    [[ "$(driver_name_from_id something-else)" == "something-else" ]]
}

@test "log keeps the message when called with a level" {
    # log() used to take a single argument, so `log ERROR "msg"` wrote "ERROR"
    # and threw the message away.
    log ERROR "the desk monitor stayed off"
    run oc_log_file
    [[ "$output" == *"ERROR: the desk monitor stayed off"* ]]
}

@test "log accepts a bare message too" {
    log "plain message"
    run oc_log_file
    [[ "$output" == *"plain message"* ]]
}

@test "valid_history_id accepts only generated log names" {
    valid_history_id "open-couch-engine-20260829-120000.log"
    valid_history_id "open-couch-engine-20260829-120000.log.3"
    ! valid_history_id "../../etc/passwd"
    ! valid_history_id "open-couch-engine-20260829-120000.log/../x"
    ! valid_history_id ""
}

@test "archive_log rotates the log and prunes beyond MAX_HISTORY_LOGS" {
    mkdir -p "$STATE_DIR" "$HISTORY_DIR"
    printf 'current log\n' >"$LOG_FILE"

    MAX_HISTORY_LOGS=3
    local i
    for i in 1 2 3 4 5; do
        printf 'old %s\n' "$i" >"${HISTORY_DIR}/open-couch-engine-2026010${i}-000000.log"
    done

    run archive_log
    [[ "$status" -eq 0 ]]

    # 5 old + 1 new archived, pruned down to MAX_HISTORY_LOGS.
    local count
    count="$(find "$HISTORY_DIR" -type f -name 'open-couch-engine-*.log*' | wc -l)"
    [[ "$count" -eq 3 ]]
    # Oldest go first.
    [[ ! -e "${HISTORY_DIR}/open-couch-engine-20260101-000000.log" ]]
}

@test "require_commands dies when a required host command is missing" {
    REQUIRED_HOST_COMMANDS=(jq definitely-not-installed)
    run require_commands
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Missing dependencies: definitely-not-installed"* ]]
}

@test "require_commands passes when everything is present" {
    REQUIRED_HOST_COMMANDS=(jq bash)
    run require_commands
    [[ "$status" -eq 0 ]]
}

@test "log_missing_host_components separates required from optional" {
    REQUIRED_HOST_COMMANDS=(definitely-not-installed)
    OPTIONAL_HOST_COMMANDS=(also-not-installed)
    log_missing_host_components
    run oc_log_file
    [[ "$output" == *"ERROR: Missing required host components: definitely-not-installed"* ]]
    [[ "$output" == *"WARNING: Missing optional host component(s): also-not-installed"* ]]
}
