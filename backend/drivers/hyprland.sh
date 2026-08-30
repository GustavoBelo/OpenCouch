# drivers/hyprland.sh — Hyprland driver for open-couch-engine.
# shellcheck shell=bash

HYPRLAND_REQUIRED_HOST_COMMANDS=(jq hyprctl pgrep)
HYPRLAND_OPTIONAL_HOST_COMMANDS=()

# --- Runtime detection helpers (plan sections 3.6, 3.7, 3.8) ---

hyprland_autostart_via_desktop_entry() {
    # Detect whether the session manager reads ~/.config/autostart/.
    # Hyprland via UWSM/systemd activates xdg-desktop-autostart.target;
    # Hyprland launched directly from TTY does not.
    if systemctl --user is-active graphical-session.target &>/dev/null \
       && systemctl --user is-active xdg-desktop-autostart.target &>/dev/null; then
        return 0
    fi
    return 1
}

hyprland_portal_has_background() {
    # Check whether org.freedesktop.portal.Background is actually available
    # on the session bus. xdg-desktop-portal-hyprland does NOT implement it
    # as of 2026 — only xdg-desktop-portal-gnome and xdg-desktop-portal-kde do.
    if ! command -v busctl >/dev/null 2>&1; then
        return 1
    fi
    busctl --user introspect org.freedesktop.portal.Desktop \
        /org/freedesktop/portal/desktop 2>/dev/null \
        | grep -q 'org.freedesktop.portal.Background'
}

hyprland_tray_host_present() {
    # Check whether a StatusNotifierItem host is running on D-Bus.
    # Without it, QSystemTrayIcon won't show on Hyprland.
    if ! command -v busctl >/dev/null 2>&1; then
        return 1
    fi
    busctl --user list 2>/dev/null | grep -q 'StatusNotifierWatcher'
}

# --- Driver interface ---

hyprland_check_deps() {
    local cmd
    for cmd in "${REQUIRED_HOST_COMMANDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf 'hyprland:%s:present\n' "$cmd"
        else
            printf 'hyprland:%s:missing\n' "$cmd"
        fi
    done
    for cmd in "${OPTIONAL_HOST_COMMANDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf 'hyprland:%s:present\n' "$cmd"
        else
            printf 'hyprland:%s:missing\n' "$cmd"
        fi
    done
}

hyprland_capabilities_json() {
    local hypr_version autostart_mode bg_portal tray_mode
    hypr_version="$(hyprctl version -j 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"

    if hyprland_autostart_via_desktop_entry; then
        autostart_mode="desktop_entry"
    else
        autostart_mode="manual_snippet"
    fi

    if hyprland_portal_has_background; then
        bg_portal="true"
    else
        bg_portal="false"
    fi

    if hyprland_tray_host_present; then
        tray_mode="available"
    else
        tray_mode="requires_sni_host"
    fi

    # monitor_api tells support whether this build takes hl.monitor{} (Lua
    # config parser) or the legacy `hyprctl keyword monitor`.
    printf '{"compositor":"hyprland","compositor_version":"%s","display":{"list_outputs":true,"apply_layout":true,"mirror":true,"disable_output":"experimental","primary_output":false,"monitor_api":"%s"},"window_management":"best_effort","terminal_launch":true,"autostart":"%s","background_portal":%s,"tray":"%s"}' \
        "${hypr_version}" "$(hyprland_monitor_api)" "${autostart_mode}" "${bg_portal}" "${tray_mode}"
}

hyprland_monitors_json() {
    local json
    json="$(hyprctl -j monitors all 2>/dev/null || true)"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" || return 1
    printf '%s\n' "$json"
}

# Connector names reported as physically connected by DRM sysfs.
# hyprctl always reports connected:true, so this is the only reliable source.
hyprland_connected_outputs_json() {
    local names="[]"
    local connector_dir connector_name
    for connector_dir in "${OC_DRM_ROOT}"/card[0-9]*-*; do
        [[ -f "${connector_dir}/status" ]] || continue
        [[ "$(cat "${connector_dir}/status" 2>/dev/null)" == "connected" ]] || continue
        connector_name="${connector_dir##*/}"
        connector_name="${connector_name#card[0-9]*-}"
        names="$(jq -c --arg n "$connector_name" '. + [$n]' <<<"$names" 2>/dev/null \
            || printf '%s' "$names")"
    done
    printf '%s' "$names"
}

hyprland_list_outputs_json() {
    # Read EDID-reported modes from DRM sysfs for each connector.
    # hyprctl monitors only returns the current mode; /sys/class/drm has all.
    local drm_modes="{}"
    local connector_dir modes_file connector_name modes_json
    for connector_dir in "${OC_DRM_ROOT}"/card[0-9]*-*; do
        [[ -f "${connector_dir}/status" ]] || continue
        [[ "$(cat "${connector_dir}/status" 2>/dev/null)" == "connected" ]] || continue
        modes_file="${connector_dir}/modes"
        [[ -f "$modes_file" ]] || continue
        connector_name="${connector_dir##*/}"
        connector_name="${connector_name#card[0-9]*-}"
        modes_json="$(grep -v '^$' "$modes_file" 2>/dev/null \
            | sort -u | jq -R . | jq -sc . 2>/dev/null || echo "[]")"
        drm_modes="$(printf '%s' "$drm_modes" \
            | jq --arg c "$connector_name" --argjson m "$modes_json" \
            '. + {($c): $m}' 2>/dev/null || printf '%s' "$drm_modes")"
    done

    local monitors
    if ! monitors="$(hyprland_monitors_json)"; then
        log "WARNING: could not read monitors from Hyprland"
        printf '[]\n'
        return 0
    fi

    # Normalizes every mode to WxH@R with one decimal and sorts numerically, so
    # the Setup combos don't mix "1920x1080", "1920x1080@300.00" and
    # "1920x1080@300.00000" as three distinct entries. Modes without a refresh
    # rate (DRM sysfs) and the 0x0 placeholder of a disabled output are dropped.
    jq -c --argjson drm "$drm_modes" '
        def norm:
            capture("^(?<w>[0-9]+)x(?<h>[0-9]+)@(?<r>[0-9.]+)$")
            | select((.w | tonumber) > 0 and (.h | tonumber) > 0)
            | {w: (.w | tonumber), h: (.h | tonumber), r: (.r | tonumber)};
        def fmt: "\(.w)x\(.h)@\(.r * 10 | round / 10)";
        def current_mode:
            (.width | tostring) + "x" + (.height | tostring) + "@" + (.refreshRate | tostring);
        [.[] | . as $m | {
            name: .name,
            enabled: (.disabled == false),
            modes: (
                ([current_mode] + ((.availableModes // []) | map(tostring | sub("Hz$"; "")))
                 + ($drm[.name] // []))
                | map(. as $s | try ($s | norm) catch empty)
                | unique_by(fmt)
                | sort_by(-.w, -.h, -.r)
                | map(fmt)
            ),
            currentMode: ((current_mode | try (norm | fmt) catch "") // ""),
            scale: .scale,
            pos: ((.x | tostring) + "," + (.y | tostring))
        }]
    ' <<<"$monitors"
}

hyprland_get_layout_json() {
    local monitors connected
    if ! monitors="$(hyprland_monitors_json)"; then
        printf '{"outputs":[]}\n'
        return 0
    fi
    connected="$(hyprland_connected_outputs_json)"

    # Hyprland has no primary-output concept, so `priority` is reported as null
    # rather than derived from focus (which would flip with the mouse). Callers
    # already treat it as optional.
    jq -c --argjson connected "$connected" '
        def mode_name:
            (.width | tostring) + "x" + (.height | tostring) + "@" + (.refreshRate | tostring);
        {
            outputs: [.[] | {
                name: .name,
                connected: (.name as $n | $connected | index($n) != null),
                enabled: (.disabled == false),
                priority: null,
                pos: {x: .x, y: .y},
                scale: .scale,
                currentModeId: 0,
                modes: [{
                    id: 0,
                    name: (if (.width > 0 and .height > 0) then mode_name else "" end),
                    refreshRate: .refreshRate
                }]
            }]
        }
    ' <<<"$monitors"
}

# --- Layout application ---------------------------------------------------
#
# Hyprland moved `monitor` to its non-legacy (Lua) config parser. On those
# builds `hyprctl keyword monitor …` answers
#   "keyword can't work with non-legacy parsers. Use eval."
# and — critically — still exits 0, so a layout change silently does nothing.
# The supported entry point there is the Lua API: hl.monitor{...} via
# `hyprctl eval`. Older builds only understand the legacy keyword.
#
# Detected once per process and cached in HYPRLAND_MONITOR_API.
HYPRLAND_MONITOR_API=""

hyprland_monitor_api() {
    if [[ -n "$HYPRLAND_MONITOR_API" ]]; then
        printf '%s' "$HYPRLAND_MONITOR_API"
        return 0
    fi

    if [[ "$(hyprctl eval 'return type(hl.monitor)' 2>/dev/null || true)" == *function* ]] \
       || [[ "$(hyprctl repl 'print(type(hl.monitor))' 2>/dev/null || true)" == *function* ]]; then
        HYPRLAND_MONITOR_API="lua"
    else
        HYPRLAND_MONITOR_API="keyword"
    fi
    log "hyprland: monitor API = ${HYPRLAND_MONITOR_API}"
    printf '%s' "$HYPRLAND_MONITOR_API"
}

# Hyprland positions are "XxY". The engine stores them as "X,Y" in layout.env
# (shared format with the KDE driver), so every position must go through here.
hyprland_position() {
    local pos="${1:-0,0}"
    pos="${pos//,/x}"
    [[ "$pos" =~ ^-?[0-9]+x-?[0-9]+$ ]] || pos="0x0"
    printf '%s' "$pos"
}

# Reject scales that would break the awk logical-width math downstream.
hyprland_scale() {
    local scale="${1:-}"
    if [[ "$scale" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v s="$scale" 'BEGIN { exit !(s > 0) }'; then
        printf '%s' "$scale"
        return 0
    fi
    return 1
}

# hyprland_monitor_spec <name> disable
# hyprland_monitor_spec <name> <mode> <position> <scale> [mirror_of]
#
# Emits one command in whichever dialect the running Hyprland accepts.
hyprland_monitor_spec() {
    local name="$1"
    local api
    api="$(hyprland_monitor_api)"

    if [[ "${2:-}" == "disable" ]]; then
        if [[ "$api" == "lua" ]]; then
            printf 'hl.monitor({ output = "%s", disabled = true })' "$name"
        else
            printf 'keyword monitor %s,disable' "$name"
        fi
        return 0
    fi

    local mode="$2"
    local position="$3"
    local scale="$4"
    local mirror="${5:-}"

    if [[ "$api" == "lua" ]]; then
        printf 'hl.monitor({ output = "%s", mode = "%s", position = "%s", scale = %s' \
            "$name" "$mode" "$position" "$scale"
        [[ -n "$mirror" ]] && printf ', mirror = "%s"' "$mirror"
        printf ' })'
    else
        printf 'keyword monitor %s,%s,%s,%s' "$name" "$mode" "$position" "$scale"
        [[ -n "$mirror" ]] && printf ',mirror,%s' "$mirror"
    fi
}

# Applies the specs produced by hyprland_monitor_spec and verifies the result.
hyprland_apply_monitors() {
    local -a specs=("$@")
    ((${#specs[@]} > 0)) || return 0

    local api
    api="$(hyprland_monitor_api)"

    local output status=0
    if [[ "$api" == "lua" ]]; then
        local lua=""
        local spec
        for spec in "${specs[@]}"; do
            lua+="${spec}"$'\n'
        done
        output="$(hyprctl eval "$lua" 2>&1)" || status=$?
    else
        local batch=""
        local spec
        for spec in "${specs[@]}"; do
            if [[ -n "$batch" ]]; then
                batch="${batch}; ${spec}"
            else
                batch="$spec"
            fi
        done
        output="$(hyprctl --batch "$batch" 2>&1)" || status=$?
    fi

    # hyprctl exits 0 even when it refuses the command, so inspect the reply.
    if (( status != 0 )) || [[ "$output" == *"can't work with non-legacy"* ]] \
       || [[ "$output" == *"Invalid"* ]] || [[ "$output" == *"error"* ]] \
       || [[ "$output" == *"Error"* ]]; then
        log "ERROR: Hyprland refused the layout change (api=${api}): ${output}"
        return 1
    fi
    return 0
}

# Re-reads the compositor state and logs any output that did not end up as
# requested. Called after every layout change, not just after `disable`.
hyprland_verify_output() {
    local name="$1"
    local expect_enabled="$2"

    local json disabled
    json="$(hyprctl -j monitors all 2>/dev/null || true)"
    [[ -n "$json" ]] || return 0

    disabled="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .disabled' \
        <<<"$json" 2>/dev/null || printf 'unknown')"

    case "${expect_enabled}:${disabled}" in
        true:false|false:true)
            log "hyprland: confirmed ${name} enabled=${expect_enabled}"
            ;;
        true:true)
            log "WARNING: ${name} should be enabled but is still disabled"
            ;;
        false:false)
            log "WARNING: disable of ${name} did not take effect (known Hyprland issues #14711, #14496)"
            ;;
        *)
            log "WARNING: could not verify state of ${name} (disabled=${disabled})"
            ;;
    esac
}

hyprland_apply_layout() {
    # Kept for the driver contract. The engine drives layout through
    # hyprland_switch_to_tv / hyprland_restore_layout, which build their specs
    # with hyprland_monitor_spec and apply them with hyprland_apply_monitors.
    local json="$1"
    shift
    (($# > 0)) || return 0
    hyprland_apply_monitors "$@"
}

hyprland_window_action() {
    local action="$1"
    local class_regex="$2"

    case "$action" in
        is_open)
            hyprctl clients -j | jq -e --arg re "$class_regex" \
                '.[] | select(.class | test($re; "i"))' >/dev/null 2>&1
            ;;
        close)
            local pids
            pids="$(hyprctl clients -j | jq -r --arg re "$class_regex" \
                '.[] | select(.class | test($re; "i")) | .pid' 2>/dev/null || true)"
            if [[ -n "$pids" ]]; then
                while IFS= read -r pid; do
                    [[ -n "$pid" ]] && hyprctl dispatch closewindow "pid:${pid}" 2>/dev/null || true
                done <<< "$pids"
            fi
            ;;
        focus)
            hyprctl dispatch focuswindow "class:${class_regex}" 2>/dev/null || true
            ;;
        fullscreen)
            hyprctl dispatch focuswindow "class:${class_regex}" 2>/dev/null || true
            hyprctl dispatch fullscreen 0 2>/dev/null || true
            ;;
        *)
            return 1
            ;;
    esac
}

# Steam's Gamepad UI differs by Steam build: it can be identified by title,
# initial title, class, or only become fullscreen after the window is mapped.
#
# NOTE: `fullscreen` and `fullscreenClient` are integers in hyprctl (0 = none,
# >0 = a fullscreen mode), not booleans — comparing them against `true` never
# matches. Keep these prefixed: an unprefixed name here overrides the shared
# implementation for every compositor in the concatenated engine.
_hyprland_big_picture_filter='
    .[] | select(
        ((.class // "") + " " + (.initialClass // "") + " "
         + (.title // "") + " " + (.initialTitle // ""))
        | test("steam|gamepadui|big.?picture"; "i")
    ) | select(
        ((.title // "") + " " + (.initialTitle // "")
         | test("gamepadui|big.?picture"; "i"))
        or ((.fullscreen // 0) > 0)
        or ((.fullscreenClient // 0) > 0)
    )
'

hyprland_big_picture_window_present() {
    hyprctl clients -j 2>/dev/null \
        | jq -e "$_hyprland_big_picture_filter" >/dev/null 2>&1
}

# Close only the fullscreen Steam window (Big Picture), not desktop Steam.
hyprland_close_big_picture() {
    log "Closing Big Picture (keeping Steam open in desktop mode)"
    local addresses
    addresses="$(hyprctl clients -j 2>/dev/null \
        | jq -r "${_hyprland_big_picture_filter} | .address" 2>/dev/null || true)"
    if [[ -n "$addresses" ]]; then
        while IFS= read -r address; do
            # Close by window address, not by pid: `pid:` would take down every
            # window of that process, including desktop Steam.
            [[ -n "$address" ]] && hyprctl dispatch closewindow "address:${address}" 2>/dev/null || true
        done <<< "$addresses"
    fi
    sleep 0.5
}

hyprland_open_terminal() {
    local cmd="$1"
    if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null; then
        exec "$TERMINAL" -e bash -c "$cmd"
    fi
    if command -v xdg-terminal-exec >/dev/null 2>&1; then
        exec xdg-terminal-exec bash -c "$cmd"
    fi
    for t in kitty foot alacritty wezterm konsole gnome-terminal xterm; do
        if command -v "$t" >/dev/null 2>&1; then
            exec "$t" -e bash -c "$cmd"
        fi
    done
    log ERROR "No terminal emulator found. Run manually: $cmd"
    return 1
}

hyprland_monitor_mode_string() {
    local name="$1"
    local json="$2"

    local w h r
    w="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .width' <<<"$json" 2>/dev/null || true)"
    h="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .height' <<<"$json" 2>/dev/null || true)"
    r="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .refreshRate' <<<"$json" 2>/dev/null || true)"

    if [[ -n "$w" && -n "$h" && -n "$r" && "$w" != "null" && "$h" != "null" && "$r" != "null" ]]; then
        printf '%sx%s@%s' "$w" "$h" "$r"
    else
        printf '%s' ""
    fi
}

hyprland_switch_to_tv() {
    local json
    json="$(hyprland_monitors_json)" || die "Could not query monitors from Hyprland."

    if ! jq -e --arg n "$TV_OUTPUT" 'any(.[]; .name == $n)' >/dev/null 2>&1 <<<"$json"; then
        die "The TV ($TV_OUTPUT) is not connected."
    fi

    local tv_mode tv_scale live_scale tv_w desk_mode desk_x

    # The configured mode/scale win: they are what the user picked in Setup.
    # The live values are only a fallback.
    tv_mode="${FALLBACK_TV_MODE:-}"
    [[ -n "$tv_mode" ]] || tv_mode="$(hyprland_monitor_mode_string "$TV_OUTPUT" "$json")"

    live_scale="$(jq -r --arg n "$TV_OUTPUT" '.[] | select(.name == $n) | .scale // empty' \
        <<<"$json" 2>/dev/null || true)"
    tv_scale="$(hyprland_scale "$FALLBACK_TV_SCALE" \
        || hyprland_scale "$live_scale" \
        || printf '1')"

    tv_w="${tv_mode%%x*}"
    if [[ ! "$tv_w" =~ ^[0-9]+$ ]] || (( tv_w == 0 )); then
        desk_x=0
    else
        # logical_width takes the full mode string, not just the width.
        desk_x="$(logical_width "$tv_mode" "$tv_scale")"
    fi

    log "switch_to_tv: config => KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, TV_MODE=${tv_mode}, TV_SCALE=${tv_scale}"

    local -a specs=()
    local desk_expect_enabled="true"

    if [[ "${KEEP_DESK_ENABLED:-false}" == "true" ]]; then
        if [[ "${MIRROR_DESK_TO_TV:-false}" == "true" ]]; then
            specs+=("$(hyprland_monitor_spec "$TV_OUTPUT" "$tv_mode" "0x0" "$tv_scale" "$DESK_OUTPUT")")
            specs+=("$(hyprland_monitor_spec "$DESK_OUTPUT" "$tv_mode" "0x0" "$tv_scale")")
            log "switch_to_tv: TV primary + desktop mirrored"
        else
            desk_mode="${FALLBACK_DESK_MODE:-}"
            [[ -n "$desk_mode" ]] || desk_mode="$(hyprland_monitor_mode_string "$DESK_OUTPUT" "$json")"
            [[ -z "$desk_mode" ]] && desk_mode="$FALLBACK_DESK_MODE"

            specs+=("$(hyprland_monitor_spec "$TV_OUTPUT" "$tv_mode" "0x0" "$tv_scale")")
            specs+=("$(hyprland_monitor_spec "$DESK_OUTPUT" "$desk_mode" "${desk_x}x0" "1")")
            log "switch_to_tv: TV primary + desktop at x=${desk_x}"
        fi
    else
        specs+=("$(hyprland_monitor_spec "$TV_OUTPUT" "$tv_mode" "0x0" "$tv_scale")")
        specs+=("$(hyprland_monitor_spec "$DESK_OUTPUT" disable)")
        desk_expect_enabled="false"
        log "switch_to_tv: TV primary, desk disabled"
    fi

    if ! hyprland_apply_monitors "${specs[@]}"; then
        die "Could not apply the couch layout on Hyprland. See the log for the compositor's reply."
    fi

    hyprland_verify_output "$TV_OUTPUT" true
    hyprland_verify_output "$DESK_OUTPUT" "$desk_expect_enabled"
}

hyprland_restore_layout() {
    local -a specs=()
    local desk_expect_enabled tv_expect_enabled

    if [[ ! -f "$SNAPSHOT_FILE" ]]; then
        log "restore_layout: snapshot missing; using fallback"
        local json desk_mode tv_mode tv_scale
        json="$(hyprctl -j monitors all 2>/dev/null || printf '[]')"
        desk_mode="$(hyprland_monitor_mode_string "$DESK_OUTPUT" "$json")"
        tv_mode="$(hyprland_monitor_mode_string "$TV_OUTPUT" "$json")"
        # A disabled monitor reports 0x0@... — never feed that back as a mode.
        [[ -z "$desk_mode" || "$desk_mode" == 0x0@* ]] && desk_mode="$FALLBACK_DESK_MODE"
        [[ -z "$tv_mode" || "$tv_mode" == 0x0@* ]] && tv_mode="$FALLBACK_TV_MODE"
        tv_scale="$(hyprland_scale "$FALLBACK_TV_SCALE" || printf '1')"

        specs+=("$(hyprland_monitor_spec "$DESK_OUTPUT" "$desk_mode" \
            "$(hyprland_position "$FALLBACK_DESK_POS")" \
            "$(hyprland_scale "$FALLBACK_DESK_SCALE" || printf '1')")")
        specs+=("$(hyprland_monitor_spec "$TV_OUTPUT" "$tv_mode" \
            "$(hyprland_position "$FALLBACK_TV_POS")" "$tv_scale")")

        if ! hyprland_apply_monitors "${specs[@]}"; then
            log "ERROR: restore_layout fallback failed to apply"
            return 1
        fi
        hyprland_verify_output "$DESK_OUTPUT" true
        return 0
    fi

    source "$SNAPSHOT_FILE"

    local desk_mode tv_mode desk_pos tv_pos desk_scale tv_scale
    desk_mode="${DESK_MODE:-$FALLBACK_DESK_MODE}"
    tv_mode="${TV_MODE:-$FALLBACK_TV_MODE}"
    [[ "$desk_mode" == 0x0@* ]] && desk_mode="$FALLBACK_DESK_MODE"
    [[ "$tv_mode" == 0x0@* ]] && tv_mode="$FALLBACK_TV_MODE"

    # layout.env stores positions as "X,Y"; Hyprland wants "XxY".
    desk_pos="$(hyprland_position "${DESK_POS:-$FALLBACK_DESK_POS}")"
    tv_pos="$(hyprland_position "${TV_POS:-$FALLBACK_TV_POS}")"

    desk_scale="$(hyprland_scale "${DESK_SCALE:-}" || hyprland_scale "$FALLBACK_DESK_SCALE" || printf '1')"
    tv_scale="$(hyprland_scale "${TV_SCALE:-}" || hyprland_scale "$FALLBACK_TV_SCALE" || printf '1')"

    desk_expect_enabled="${DESK_ENABLED:-true}"
    tv_expect_enabled="${TV_ENABLED:-true}"

    if [[ "$desk_expect_enabled" == "true" ]]; then
        specs+=("$(hyprland_monitor_spec "$DESK_OUTPUT" "$desk_mode" "$desk_pos" "$desk_scale")")
    else
        specs+=("$(hyprland_monitor_spec "$DESK_OUTPUT" disable)")
    fi

    if [[ "$tv_expect_enabled" == "true" ]]; then
        specs+=("$(hyprland_monitor_spec "$TV_OUTPUT" "$tv_mode" "$tv_pos" "$tv_scale")")
    else
        specs+=("$(hyprland_monitor_spec "$TV_OUTPUT" disable)")
    fi

    if ! hyprland_apply_monitors "${specs[@]}"; then
        log "ERROR: restore_layout failed to apply; keeping the snapshot for a retry"
        return 1
    fi

    hyprland_verify_output "$DESK_OUTPUT" "$desk_expect_enabled"
    hyprland_verify_output "$TV_OUTPUT" "$tv_expect_enabled"

    rm -f "$SNAPSHOT_FILE"
    log "restore_layout: layout restored"
}

# After restoring the desktop layout, Steam's window may still sit on an output
# that is now disabled. Pull it back onto the desk monitor's workspace.
hyprland_move_steam_to_desk_monitor() {
    local workspace
    workspace="$(hyprctl -j monitors 2>/dev/null \
        | jq -r --arg n "$DESK_OUTPUT" \
            '.[] | select(.name == $n) | .activeWorkspace.id // empty' 2>/dev/null || true)"
    [[ -n "$workspace" ]] || return 0

    local addresses
    addresses="$(hyprctl clients -j 2>/dev/null | jq -r --arg w "$workspace" '
        .[] | select(((.class // "") + " " + (.initialClass // "")) | test("steam"; "i"))
            | select((.workspace.id | tostring) != $w)
            | .address
    ' 2>/dev/null || true)"
    [[ -n "$addresses" ]] || return 0

    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        hyprctl dispatch movetoworkspacesilent "${workspace},address:${address}" >/dev/null 2>&1 || true
    done <<< "$addresses"
    log "restore: moved Steam windows back to ${DESK_OUTPUT} (workspace ${workspace})"
}

hyprland_play() {
    log "play: starting couch mode"
    require_commands
    start_session
    AUTO_RESTORE_ON_EXIT=1
    trap cleanup EXIT INT TERM
    controller_session_reset

    log "play: active config => KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}, EXIT_ON_ALL_CONTROLLERS_OFF=${EXIT_ON_ALL_CONTROLLERS_OFF}"

    save_snapshot
    hyprland_switch_to_tv
    log "play: couch layout applied, opening Big Picture"
    launch_big_picture_and_wait
    log "play: restoring desktop layout"
    hyprland_restore_layout
    hyprland_move_steam_to_desk_monitor
    AUTO_RESTORE_ON_EXIT=0
    log "play: layout restored successfully"
}

hyprland_restore() {
    log "restore: starting manual restore"
    require_commands

    driver_close_big_picture

    local had_session=0
    if [[ -f "$SESSION_FILE" ]] && kill -0 "$(<"$SESSION_FILE")" 2>/dev/null; then
        had_session=1
    fi

    stop_active_session

    if [[ "$had_session" == "0" ]] || [[ -f "$SNAPSHOT_FILE" ]]; then
        hyprland_restore_layout
        hyprland_move_steam_to_desk_monitor
    fi

    rm -f "$SESSION_FILE"
    log "restore: layout restored successfully"
}

hyprland_watch() {
    require_commands
    AUTO_RESTORE_ON_EXIT=1
    trap cleanup EXIT INT TERM
    log "watch: monitoring Big Picture started by Steam"

    local active=0

    while true; do
        if [[ -f "$SESSION_FILE" ]]; then
            sleep 2
            continue
        fi
        if [[ "$active" == "0" ]] && driver_big_picture_window_present; then
            log "watch: Big Picture detected externally"
            log "watch: active config => KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}, EXIT_ON_ALL_CONTROLLERS_OFF=${EXIT_ON_ALL_CONTROLLERS_OFF}"
            save_snapshot
            hyprland_switch_to_tv
            controller_session_reset
            active=1
            log "watch: Big Picture detected, couch layout applied"
        elif [[ "$active" == "1" ]] && ! driver_big_picture_window_present; then
            hyprland_restore_layout
            hyprland_move_steam_to_desk_monitor
            active=0
            log "watch: Big Picture closed, desktop layout restored"
        elif [[ "$active" == "1" ]] \
            && [[ "${EXIT_ON_ALL_CONTROLLERS_OFF:-false}" == "true" ]] \
            && controllers_all_off; then
            log "watch: all controllers turned off; closing Big Picture and restoring desktop"
            driver_close_big_picture
            wait_for_big_picture_close
            hyprland_restore_layout
            hyprland_move_steam_to_desk_monitor
            controller_session_reset
            active=0
            log "watch: desktop layout restored after all controllers turned off"
        fi
        sleep 2
    done
}
