# drivers/gnome.sh — GNOME stub driver for open-couch-engine.
# Not yet implemented — fails gracefully.

gnome_check_deps() {
    printf 'gnome:not_implemented:missing\n'
}

gnome_capabilities_json() {
    printf '{"compositor":"gnome","display":{"list_outputs":false},"window_management":"none","terminal_launch":false,"autostart":"desktop_entry","background_portal":true,"tray":"native","note":"not_implemented"}'
}

gnome_list_outputs_json() {
    printf '[]'
}

gnome_get_layout_json() {
    printf '{"outputs":[]}'
}

gnome_apply_layout() {
    log ERROR "GNOME driver not yet implemented"
    return 1
}

gnome_window_action() {
    log ERROR "GNOME driver not yet implemented"
    return 1
}

gnome_open_terminal() {
    log ERROR "GNOME driver not yet implemented"
    return 1
}

gnome_play() {
    die "GNOME driver not yet implemented."
}

gnome_restore() {
    die "GNOME driver not yet implemented."
}

gnome_watch() {
    die "GNOME driver not yet implemented."
}
