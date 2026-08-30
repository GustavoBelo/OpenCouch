#!/usr/bin/env bats
#
# Session lifecycle, exit cleanup, controller debounce and app cleanup. These
# are shared between compositors, so each one runs against the KDE driver and
# the relevant ones against Hyprland too.

load '../helpers/common'

setup() {
    oc_sandbox
    oc_as_kde
    oc_load_engine kde
}

@test "cleanup restores the layout on exit when a session was active" {
    # The trap handler used to call restore_layout(), a name that stopped
    # existing when the drivers were split out. `|| true` swallowed the
    # 'command not found' and Ctrl-C left the desk monitor switched off.
    save_snapshot
    : >"$OC_CALLLOG"
    AUTO_RESTORE_ON_EXIT=1

    run cleanup
    oc_assert_called "kscreen-doctor output.DP-1.enable"
}

@test "cleanup does nothing when no session was active" {
    AUTO_RESTORE_ON_EXIT=0
    : >"$OC_CALLLOG"
    run cleanup
    oc_assert_not_called "kscreen-doctor"
}

@test "cleanup logs instead of staying silent when the restore fails" {
    save_snapshot
    AUTO_RESTORE_ON_EXIT=1
    driver_restore_layout() { return 1; }

    run cleanup
    run oc_log_file
    [[ "$output" == *"automatic layout restore failed on exit"* ]]
}

@test "cleanup preserves the exit status it was called with" {
    AUTO_RESTORE_ON_EXIT=0
    run bash -c '
        source "'"${OC_ROOT}"'/backend/lib/common.sh"
        trap - ERR
        AUTO_RESTORE_ON_EXIT=0
        ( exit 3 ); cleanup
    '
    [[ "$status" -eq 3 ]]
}

@test "start_session records this pid and refuses a second live session" {
    start_session
    [[ "$(<"$SESSION_FILE")" == "$$" ]]

    # A live pid in the file means couch mode is already running.
    printf '%s\n' "$$" >"$SESSION_FILE"
    run start_session
    [[ "$status" -ne 0 ]]
}

@test "start_session takes over a stale session file" {
    mkdir -p "$STATE_DIR"
    # A session killed with SIGKILL leaves the file behind.
    printf '%s\n' "999999" >"$SESSION_FILE"
    run start_session
    [[ "$status" -eq 0 ]]
}

@test "clear_session_file only removes this process's own session" {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$$" >"$SESSION_FILE"
    clear_session_file
    [[ ! -f "$SESSION_FILE" ]]

    printf '%s\n' "999999" >"$SESSION_FILE"
    clear_session_file
    [[ -f "$SESSION_FILE" ]]
}

@test "stop_active_session clears the file even when the pid is gone" {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "999999" >"$SESSION_FILE"
    run stop_active_session
    [[ "$status" -eq 0 ]]
    [[ ! -f "$SESSION_FILE" ]]
}

@test "controllers_connected counts the joystick devices" {
    oc_controllers 0
    [[ "$(controllers_connected)" == "0" ]]
    oc_controllers 2
    [[ "$(controllers_connected)" == "2" ]]
}

@test "controllers_all_off stays false while a controller is connected" {
    oc_controllers 1
    controller_usage_secs=600
    controllers_off_since="$(( $(date +%s) - 600 ))"
    ! controllers_all_off
    # A connected controller also clears the countdown.
    [[ -z "$controllers_off_since" ]]
}

@test "controllers_all_off requires a minute of controller use first" {
    # Otherwise a session where nobody ever picked up a pad would end itself.
    oc_controllers 0
    controller_usage_secs=10
    controllers_off_since="$(( $(date +%s) - 600 ))"
    ! controllers_all_off
}

@test "controllers_all_off waits out the debounce before firing" {
    oc_controllers 0
    controller_usage_secs=600

    # First poll only starts the countdown.
    controllers_off_since=""
    ! controllers_all_off
    [[ -n "$controllers_off_since" ]]

    # Still inside the debounce window.
    controllers_off_since="$(( $(date +%s) - 2 ))"
    ! controllers_all_off

    # Past it.
    controllers_off_since="$(( $(date +%s) - (CONTROLLER_DEBOUNCE_SECS + 1) ))"
    controllers_all_off
}

@test "controller_session_reset clears the accumulated state" {
    controller_usage_secs=600
    controllers_off_since="123"
    controllers_last_poll="456"
    controller_session_reset
    [[ "$controller_usage_secs" -eq 0 ]]
    [[ -z "$controllers_off_since" ]]
    [[ -z "$controllers_last_poll" ]]
}

@test "is_protected_process covers the KDE and the Hyprland session" {
    for name in plasmashell kwin_wayland ksmserver systemsettings \
                Hyprland waybar hyprlock hyprpaper uwsm \
                xdg-desktop-portal-hyprland steam Xwayland; do
        is_protected_process "$name" || { echo "$name is not protected"; return 1; }
    done
    # Case-insensitive, and Xwayland matches by prefix.
    is_protected_process "HYPRLAND"
    is_protected_process "Xwayland-1"
    ! is_protected_process "chromium"
}

@test "close_tracked_apps never kills a protected process" {
    APPS_TO_CLOSE="chromium, Hyprland , plasmashell,firefox"
    run close_tracked_apps
    oc_assert_called "pkill -x chromium"
    oc_assert_called "pkill -x firefox"
    oc_assert_not_called "pkill -x Hyprland"
    oc_assert_not_called "pkill -x plasmashell"
    run oc_log_file
    [[ "$output" == *"skipping protected process Hyprland"* ]]
}

@test "close_tracked_apps is a no-op with nothing configured" {
    APPS_TO_CLOSE=""
    run close_tracked_apps
    [[ "$status" -eq 0 ]]
    oc_assert_not_called "pkill"
}

@test "desktop_process_names extracts the binary from an Exec line" {
    run desktop_process_names "/usr/bin/chromium %U"
    [[ "$output" == "chromium" ]]

    run desktop_process_names "env LANG=C /usr/bin/foot -e bash"
    [[ "$output" == "foot" ]]

    run desktop_process_names "GDK_BACKEND=wayland /usr/bin/gimp-2.10 %f"
    [[ "$output" == "gimp-2.10" ]]
}

@test "desktop_process_names handles flatpak launchers" {
    run desktop_process_names "/usr/bin/flatpak run --branch=stable --command=spotify com.spotify.Client"
    [[ "$output" == *"spotify"* ]]

    run desktop_process_names "/usr/bin/flatpak run com.discordapp.Discord"
    [[ "$output" == *"Discord"* ]]
}
