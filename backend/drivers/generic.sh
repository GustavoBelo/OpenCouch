# drivers/generic.sh — Generic X11 fallback driver for open-couch-engine.
# Basic xrandr-based driver for X11 sessions without a recognized DE.

GENERIC_REQUIRED_HOST_COMMANDS=(jq xrandr pgrep)
GENERIC_OPTIONAL_HOST_COMMANDS=(wmctrl)

generic_check_deps() {
    local cmd
    for cmd in "${REQUIRED_HOST_COMMANDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf 'generic-x11:%s:present\n' "$cmd"
        else
            printf 'generic-x11:%s:missing\n' "$cmd"
        fi
    done
}

generic_capabilities_json() {
    local wmctrl_present="false"
    command -v wmctrl >/dev/null 2>&1 && wmctrl_present="true"
    printf '{"compositor":"generic-x11","display":{"list_outputs":true,"apply_layout":true,"mirror":false,"disable_output":false,"primary_output":false},"window_management":"%s","terminal_launch":true,"autostart":"desktop_entry","background_portal":false,"tray":"none"}' \
        "$wmctrl_present"
}

generic_list_outputs_json() {
    xrandr --query 2>/dev/null | jq -Rn '
        [inputs
         | select(test("^.* connected"))
         | split(" ")
         | {name: .[0],
            enabled: (index("primary") != null or (length > 2 and .[2] != "disconnected")),
            modes: []}]
    ' 2>/dev/null || printf '[]'
}

generic_get_layout_json() {
    printf '{"outputs":[]}'
}

generic_apply_layout() {
    log ERROR "Generic X11 driver has limited display management support"
    return 1
}

generic_window_action() {
    local action="$1"
    local class_regex="$2"

    if ! command -v wmctrl >/dev/null 2>&1; then
        return 1
    fi

    case "$action" in
        is_open)
            wmctrl -lx 2>/dev/null | awk -v re="$class_regex" 'tolower($0) ~ re {found=1; exit} END {exit !found}'
            ;;
        close)
            wmctrl -lx 2>/dev/null | awk -v re="$class_regex" 'tolower($0) ~ re {print $1}' | xargs -r wmctrl -i -c || true
            ;;
        focus)
            wmctrl -lx 2>/dev/null | awk -v re="$class_regex" 'tolower($0) ~ re {print $1; exit}' | xargs -r wmctrl -i -a || true
            ;;
        *)
            return 1
            ;;
    esac
}

generic_open_terminal() {
    local cmd="$1"
    if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null; then
        exec "$TERMINAL" -e bash -c "$cmd"
    fi
    if command -v xdg-terminal-exec >/dev/null 2>&1; then
        exec xdg-terminal-exec bash -c "$cmd"
    fi
    for t in xterm konsole kitty foot alacritty; do
        if command -v "$t" >/dev/null 2>&1; then
            exec "$t" -e bash -c "$cmd"
        fi
    done
    log ERROR "No terminal emulator found. Run manually: $cmd"
    return 1
}

generic_play() {
    die "Generic X11 driver does not support couch mode. Install a desktop environment (KDE Plasma, Hyprland)."
}

generic_restore() {
    die "Generic X11 driver does not support couch mode."
}

generic_watch() {
    die "Generic X11 driver does not support Big Picture monitoring."
}
