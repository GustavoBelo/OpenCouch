#!/usr/bin/env bats
#
# The driver contract is the load-bearing abstraction of the engine, and it is
# also where the most expensive regression of the Hyprland branch came from:
# drivers/hyprland.sh defined big_picture_window_present() and
# close_big_picture() WITHOUT a prefix. Everything is concatenated into one bash
# file, so those hyprctl-based versions silently replaced the shared ones for
# every compositor -- on KDE, `watch` never triggered and `restore` never closed
# Big Picture.

load '../helpers/common'

# Every name load_driver() promises to bind.
CONTRACT=(
    check_deps capabilities_json list_outputs_json get_layout_json
    apply_layout window_action open_terminal play restore watch
    switch_to_tv restore_layout big_picture_window_present close_big_picture
)

setup() {
    oc_sandbox
}

@test "load_driver binds every contract function for kde" {
    oc_load_engine kde
    for fn in "${CONTRACT[@]}"; do
        declare -F "driver_${fn}" >/dev/null \
            || { echo "driver_${fn} is not defined"; return 1; }
    done
}

@test "load_driver binds every contract function for hyprland" {
    oc_load_engine hyprland
    for fn in "${CONTRACT[@]}"; do
        declare -F "driver_${fn}" >/dev/null \
            || { echo "driver_${fn} is not defined"; return 1; }
    done
}

@test "load_driver binds every contract function for gnome and generic-x11" {
    for compositor in gnome generic-x11; do
        oc_load_engine "$compositor"
        for fn in "${CONTRACT[@]}"; do
            declare -F "driver_${fn}" >/dev/null \
                || { echo "driver_${fn} is not defined for ${compositor}"; return 1; }
        done
    done
}

@test "kde and hyprland implement the whole contract without falling back to the error stub" {
    for compositor in kde hyprland; do
        oc_load_engine "$compositor"
        for fn in "${CONTRACT[@]}"; do
            local body
            body="$(declare -f "driver_${fn}")"
            [[ "$body" != *"does not implement"* ]] \
                || { echo "${compositor}: driver_${fn} resolved to the error stub"; return 1; }
        done
    done
}

@test "kde keeps the shared Big Picture implementation, not Hyprland's" {
    oc_load_engine kde
    [[ "$(declare -f driver_big_picture_window_present)" == *default_big_picture_window_present* ]]
    [[ "$(declare -f driver_close_big_picture)" == *default_close_big_picture* ]]
    [[ "$(declare -f driver_big_picture_window_present)" != *hyprland_* ]]
    [[ "$(declare -f driver_close_big_picture)" != *hyprland_* ]]
}

@test "hyprland uses its own Big Picture implementation" {
    oc_load_engine hyprland
    [[ "$(declare -f driver_big_picture_window_present)" == *hyprland_big_picture_window_present* ]]
    [[ "$(declare -f driver_close_big_picture)" == *hyprland_close_big_picture* ]]
}

@test "no driver_* name is left unbound after a driver loads" {
    # An unbound driver_* call is a `command not found` that some caller's
    # `|| true` would swallow. load_driver installs a logging stub instead.
    oc_load_engine kde
    run driver_apply_layout '{}'
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "REQUIRED_HOST_COMMANDS follows the active driver, not the last one concatenated" {
    oc_load_engine kde
    [[ "${REQUIRED_HOST_COMMANDS[*]}" == "jq kscreen-doctor pgrep" ]]
    [[ "${OPTIONAL_HOST_COMMANDS[*]}" == "wmctrl" ]]

    oc_load_engine hyprland
    [[ "${REQUIRED_HOST_COMMANDS[*]}" == *hyprctl* ]]
    [[ "${REQUIRED_HOST_COMMANDS[*]}" != *kscreen-doctor* ]]
}

@test "DRIVER_NAME reflects the loaded compositor" {
    oc_load_engine kde
    [[ "$DRIVER_NAME" == "kde" ]]
    oc_load_engine hyprland
    [[ "$DRIVER_NAME" == "hyprland" ]]
}

@test "detect_compositor identifies each session" {
    oc_load_engine ""

    oc_as_hyprland
    [[ "$(detect_compositor)" == "hyprland" ]]

    oc_as_kde
    [[ "$(detect_compositor)" == "kde" ]]

    # KDE without kscreen-doctor is NOT kde: it falls through to unknown, and
    # `check` must not answer OK for it.
    oc_as_kde
    PATH="/nonexistent" run detect_compositor
    [[ "$output" != "kde" ]]

    unset HYPRLAND_INSTANCE_SIGNATURE
    XDG_CURRENT_DESKTOP="GNOME" run detect_compositor
    [[ "$output" == "gnome" ]]

    XDG_CURRENT_DESKTOP="XFCE" XDG_SESSION_TYPE="x11" run detect_compositor
    [[ "$output" == "generic-x11" ]]

    XDG_CURRENT_DESKTOP="" XDG_SESSION_TYPE="wayland" run detect_compositor
    [[ "$output" == "unknown" ]]
}
