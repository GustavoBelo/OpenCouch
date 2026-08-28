# detect.sh — compositor detection and driver dispatch for open-couch-engine.

detect_compositor() {
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        printf 'hyprland'
        return
    fi

    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*)
            if command -v kscreen-doctor >/dev/null 2>&1; then
                printf 'kde'
                return
            fi
            ;;
        *GNOME*)
            printf 'gnome'
            return
            ;;
    esac

    if [[ "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        printf 'generic-x11'
        return
    fi

    printf 'unknown'
}

# Map compositor ID to driver prefix (used by dispatch functions below)
_driver_prefix() {
    case "$1" in
        kde)           printf 'kde' ;;
        hyprland)      printf 'hyprland' ;;
        gnome)         printf 'gnome' ;;
        generic-x11)   printf 'generic' ;;
        *)             printf '' ;;
    esac
}

load_driver() {
    local compositor="$1"

    # All drivers are inlined in the built engine (and sourced up front by
    # backend/dispatcher.sh in development) with compositor-prefixed function
    # names (e.g. kde_play, hyprland_play). Here we bind the generic driver_*
    # interface to the right implementation for the detected compositor.
    local prefix
    prefix="$(_driver_prefix "$compositor")"

    if [[ -n "$prefix" ]]; then
        local fn
        for fn in check_deps capabilities_json list_outputs_json get_layout_json \
                  apply_layout window_action open_terminal play restore watch \
                  switch_to_tv restore_layout \
                  big_picture_window_present close_big_picture; do
            if declare -F "${prefix}_${fn}" >/dev/null 2>&1; then
                eval "driver_${fn}() { ${prefix}_${fn} \"\$@\"; }"
            elif declare -F "default_${fn}" >/dev/null 2>&1; then
                # Shared implementation in lib/common.sh (e.g. Big Picture
                # handling built on driver_window_action).
                eval "driver_${fn}() { default_${fn} \"\$@\"; }"
            else
                # Never leave a driver_* name unbound: an unbound call would be
                # a 'command not found' swallowed by some caller's `|| true`.
                eval "driver_${fn}() {
                    log \"ERROR: driver '${compositor}' does not implement ${fn}\"
                    return 1
                }"
            fi
        done
    fi

    # Set global dependency arrays from namespaced driver variables.
    # In the concatenated build, all drivers define their own
    # *_REQUIRED_HOST_COMMANDS and *_OPTIONAL_HOST_COMMANDS at the top level;
    # the last driver loaded would overwrite them. This resolves the correct
    # set for the active compositor.
    case "$compositor" in
        kde)
            REQUIRED_HOST_COMMANDS=("${KDE_REQUIRED_HOST_COMMANDS[@]+"${KDE_REQUIRED_HOST_COMMANDS[@]}"}")
            OPTIONAL_HOST_COMMANDS=("${KDE_OPTIONAL_HOST_COMMANDS[@]+"${KDE_OPTIONAL_HOST_COMMANDS[@]}"}")
            ;;
        hyprland)
            REQUIRED_HOST_COMMANDS=("${HYPRLAND_REQUIRED_HOST_COMMANDS[@]+"${HYPRLAND_REQUIRED_HOST_COMMANDS[@]}"}")
            OPTIONAL_HOST_COMMANDS=("${HYPRLAND_OPTIONAL_HOST_COMMANDS[@]+"${HYPRLAND_OPTIONAL_HOST_COMMANDS[@]}"}")
            ;;
        gnome)
            REQUIRED_HOST_COMMANDS=()
            OPTIONAL_HOST_COMMANDS=()
            ;;
        generic-x11)
            REQUIRED_HOST_COMMANDS=("${GENERIC_REQUIRED_HOST_COMMANDS[@]+"${GENERIC_REQUIRED_HOST_COMMANDS[@]}"}")
            OPTIONAL_HOST_COMMANDS=("${GENERIC_OPTIONAL_HOST_COMMANDS[@]+"${GENERIC_OPTIONAL_HOST_COMMANDS[@]}"}")
            ;;
        *)
            REQUIRED_HOST_COMMANDS=()
            OPTIONAL_HOST_COMMANDS=()
            ;;
    esac

    DRIVER_NAME="$compositor"
    return 0
}
