# drivers/kde.sh — KDE Plasma driver for open-couch-engine.
# shellcheck shell=bash
# Extracted from the original monolithic engine without behavior changes.

KDE_REQUIRED_HOST_COMMANDS=(jq kscreen-doctor pgrep)
KDE_OPTIONAL_HOST_COMMANDS=(wmctrl)

kde_check_deps() {
    local cmd
    for cmd in "${REQUIRED_HOST_COMMANDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf 'kde:%s:present\n' "$cmd"
        else
            printf 'kde:%s:missing\n' "$cmd"
        fi
    done
    for cmd in "${OPTIONAL_HOST_COMMANDS[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            printf 'kde:%s:present\n' "$cmd"
        else
            printf 'kde:%s:missing\n' "$cmd"
        fi
    done
}

kde_capabilities_json() {
    local wmctrl_present="false"
    command -v wmctrl >/dev/null 2>&1 && wmctrl_present="true"
    printf '{"compositor":"kde","display":{"list_outputs":true,"apply_layout":true,"mirror":true,"disable_output":true,"primary_output":true},"window_management":"%s","terminal_launch":true,"autostart":"desktop_entry","background_portal":true,"tray":"native"}' \
        "$wmctrl_present"
}

kde_list_outputs_json() {
    kscreen-doctor -j | jq -c '
        [.outputs[]
         | select(.connected == true)
         | . as $out
         | {
             name: .name,
             enabled: .enabled,
             modes: ([$out.modes[].name] | unique),
             currentMode: (($out.modes | map(select(.id == $out.currentModeId) | .name) | first) // ""),
             scale: (.scale // 1),
             pos: (((.pos.x // 0) | tostring) + "," + ((.pos.y // 0) | tostring))
           }
        ]
    '
}

kde_get_layout_json() {
    kscreen-doctor -j
}

kde_apply_layout() {
    local json="$1"
    kscreen-doctor "${@:2}"
}

kde_window_action() {
    local action="$1"
    local class_regex="$2"

    case "$action" in
        is_open)
            if ! command -v wmctrl >/dev/null 2>&1; then
                return 1
            fi
            wmctrl -lx 2>/dev/null | awk -v re="$class_regex" 'tolower($0) ~ re {found=1; exit} END {exit !found}'
            ;;
        close)
            if ! command -v wmctrl >/dev/null 2>&1; then
                return 1
            fi
            wmctrl -lx 2>/dev/null | awk -v re="$class_regex" 'tolower($0) ~ re {print $1}' | xargs -r wmctrl -i -c || true
            ;;
        focus)
            if ! command -v wmctrl >/dev/null 2>&1; then
                return 1
            fi
            wmctrl -lx 2>/dev/null | awk -v re="$class_regex" 'tolower($0) ~ re {print $1; exit}' | xargs -r wmctrl -i -a || true
            ;;
        fullscreen)
            kde_window_action focus "$class_regex"
            ;;
        *)
            return 1
            ;;
    esac
}

kde_open_terminal() {
    local cmd="$1"
    if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null; then
        exec "$TERMINAL" -e bash -c "$cmd"
    fi
    for t in konsole kitty foot alacritty wezterm gnome-terminal xterm; do
        if command -v "$t" >/dev/null 2>&1; then
            case "$t" in
                konsole)
                    exec konsole --hold -e bash -c "$cmd"
                    ;;
                *)
                    exec "$t" -e bash -c "$cmd"
                    ;;
            esac
        fi
    done
    log ERROR "No terminal emulator found. Run manually: $cmd"
    return 1
}

kde_move_steam_to_desk_monitor() {
    command -v wmctrl >/dev/null 2>&1 || { log "move_steam: wmctrl missing; skipping Steam repositioning"; return; }

    local attempt win_id pos=""

    for attempt in $(seq 1 15); do
        win_id="$(wmctrl -lx 2>/dev/null | awk '$3 ~ /\.steam$/ || $3 == "steam" { if (tolower($0) !~ /big picture/) { print $1; exit } }')"
        [[ -n "$win_id" ]] && break
        sleep 1
    done

    [[ -n "$win_id" ]] || { log "move_steam: Steam window not found; nothing to reposition"; return; }

    pos="$(kde_get_layout_json | jq -r --arg o "$DESK_OUTPUT" '
        [ .outputs[] | select(.name == $o and .enabled == true) ]
        | if length > 0 then (((.[0].pos.x // 0) | tostring) + "," + ((.[0].pos.y // 0) | tostring)) else empty end
    ' 2>/dev/null || true)"

    if [[ -z "$pos" ]]; then
        pos="${FALLBACK_DESK_POS:-0,0}"
    fi

    wmctrl -i -r "$win_id" -e "0,${pos},-1,-1" || true
    log "move_steam: Steam repositioned to the office display (${DESK_OUTPUT} @ ${pos})"
}

kde_switch_to_tv() {
    local json tv_line
    local tv_connected tv_enabled tv_priority tv_pos tv_scale tv_mode
    local -a args=()

    json="$(kde_get_layout_json)"
    tv_line="$(output_snapshot_tsv "$json" "$TV_OUTPUT")"

    log "switch_to_living_room_layout: config => KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}"
    log_layout_debug "switch_to_living_room_layout: before" "$json"

    [[ -n "$tv_line" ]] || die "Could not find the TV ($TV_OUTPUT)."
    IFS=$'\t' read -r tv_connected tv_enabled tv_priority tv_pos tv_scale tv_mode <<<"$tv_line"

    [[ "$tv_connected" == "true" ]] || die "The TV ($TV_OUTPUT) is not connected."

    tv_mode="$(resolve_mode "$json" "$TV_OUTPUT" "${tv_mode:-$FALLBACK_TV_MODE}")"

    if [[ "${KEEP_DESK_ENABLED:-false}" == "true" ]]; then
        if [[ "${MIRROR_DESK_TO_TV:-false}" == "true" ]]; then
            local mirror_mode
            mirror_mode="$(common_mirror_mode "$json" "$TV_OUTPUT" "$DESK_OUTPUT" "${tv_mode:-$FALLBACK_TV_MODE}")"
            if [[ -z "$mirror_mode" ]]; then
                show_error "Could not find a common mode between ${TV_OUTPUT} and ${DESK_OUTPUT}; mirroring may not work." || true
            fi

            args=("output.${TV_OUTPUT}.enable")
            [[ -n "$mirror_mode" ]] && args+=("output.${TV_OUTPUT}.mode.${mirror_mode}")
            args+=(
                "output.${TV_OUTPUT}.scale.${tv_scale:-$FALLBACK_TV_SCALE}"
                "output.${TV_OUTPUT}.position.0,0"
                "output.${TV_OUTPUT}.priority.1"
                "output.${DESK_OUTPUT}.enable"
            )
            [[ -n "$mirror_mode" ]] && args+=("output.${DESK_OUTPUT}.mode.${mirror_mode}")
            args+=(
                "output.${DESK_OUTPUT}.scale.${tv_scale:-$FALLBACK_TV_SCALE}"
                "output.${DESK_OUTPUT}.position.0,0"
                "output.${DESK_OUTPUT}.priority.2"
            )
            log "switch_to_living_room_layout: active config => TV primary + desktop mirrored on the couch${mirror_mode:+ (common mode: ${mirror_mode})}"
        else
            local desk_mode desk_x
            desk_mode="$(resolve_mode "$json" "$DESK_OUTPUT" "$FALLBACK_DESK_MODE")"
            desk_x="$(logical_width "${tv_mode:-$FALLBACK_TV_MODE}" "${tv_scale:-$FALLBACK_TV_SCALE}")"

            args=("output.${TV_OUTPUT}.enable")
            [[ -n "$tv_mode" ]] && args+=("output.${TV_OUTPUT}.mode.${tv_mode}")
            args+=(
                "output.${TV_OUTPUT}.scale.${tv_scale:-$FALLBACK_TV_SCALE}"
                "output.${TV_OUTPUT}.position.0,0"
                "output.${TV_OUTPUT}.priority.1"
                "output.${DESK_OUTPUT}.enable"
            )
            [[ -n "$desk_mode" ]] && args+=("output.${DESK_OUTPUT}.mode.${desk_mode}")
            args+=(
                "output.${DESK_OUTPUT}.scale.${FALLBACK_DESK_SCALE}"
                "output.${DESK_OUTPUT}.position.${desk_x},0"
                "output.${DESK_OUTPUT}.priority.2"
            )
            log "switch_to_living_room_layout: active config => TV primary + desktop next to it (desk_x=${desk_x})"
        fi
    else
        args=("output.${TV_OUTPUT}.enable")
        [[ -n "$tv_mode" ]] && args+=("output.${TV_OUTPUT}.mode.${tv_mode}")
        args+=(
            "output.${TV_OUTPUT}.scale.${tv_scale:-$FALLBACK_TV_SCALE}"
            "output.${TV_OUTPUT}.position.0,0"
            "output.${TV_OUTPUT}.priority.1"
            "output.${DESK_OUTPUT}.disable"
        )
        log "switch_to_living_room_layout: active config => TV primary and office display turned off"
    fi

    log "switch_to_living_room_layout: executing kscreen-doctor: ${args[*]}"
    kscreen-doctor "${args[@]}"

    local json_after
    json_after="$(kde_get_layout_json)"
    log_layout_debug "switch_to_living_room_layout: after" "$json_after"
    verify_primary_output "switch_to_living_room_layout" "$json_after"
}

kde_append_restore_args() {
    local -n args_ref="$1"
    local prefix="$2"
    local output="$3"
    local json="$4"

    local enabled_var="${prefix}_ENABLED"
    local mode_var="${prefix}_MODE"
    local scale_var="${prefix}_SCALE"
    local pos_var="${prefix}_POS"
    local priority_var="${prefix}_PRIORITY"

    if [[ "${!enabled_var:-false}" == "true" ]]; then
        args_ref+=("output.${output}.enable")

        if [[ -n "${!mode_var:-}" ]]; then
            local resolved_mode
            resolved_mode="$(resolve_mode "$json" "$output" "${!mode_var}")"
            [[ -n "$resolved_mode" ]] && args_ref+=("output.${output}.mode.${resolved_mode}")
        fi

        if [[ -n "${!scale_var:-}" ]]; then
            args_ref+=("output.${output}.scale.${!scale_var}")
        fi

        if [[ -n "${!pos_var:-}" ]]; then
            args_ref+=("output.${output}.position.${!pos_var}")
        fi

        if [[ -n "${!priority_var:-}" ]]; then
            args_ref+=("output.${output}.priority.${!priority_var}")
        fi
    else
        args_ref+=("output.${output}.disable")
    fi
}

kde_restore_fallback_layout() {
    local json tv_line
    local tv_connected tv_enabled tv_priority tv_pos tv_scale tv_mode
    local desk_mode tv_resolved_mode

    json="$(kde_get_layout_json)"
    tv_line="$(output_snapshot_tsv "$json" "$TV_OUTPUT")"

    if [[ -n "$tv_line" ]]; then
        IFS=$'\t' read -r tv_connected tv_enabled tv_priority tv_pos tv_scale tv_mode <<<"$tv_line"
    else
        tv_connected="false"
    fi

    desk_mode="$(resolve_mode "$json" "$DESK_OUTPUT" "$FALLBACK_DESK_MODE")"

    if [[ "$tv_connected" == "true" ]]; then
        tv_resolved_mode="$(resolve_mode "$json" "$TV_OUTPUT" "$FALLBACK_TV_MODE")"

        local -a args=("output.${DESK_OUTPUT}.enable")
        [[ -n "$desk_mode" ]] && args+=("output.${DESK_OUTPUT}.mode.${desk_mode}")
        args+=(
            "output.${DESK_OUTPUT}.scale.${FALLBACK_DESK_SCALE}"
            "output.${DESK_OUTPUT}.position.${FALLBACK_DESK_POS}"
            "output.${DESK_OUTPUT}.priority.${FALLBACK_DESK_PRIORITY}"
            "output.${TV_OUTPUT}.enable"
        )
        [[ -n "$tv_resolved_mode" ]] && args+=("output.${TV_OUTPUT}.mode.${tv_resolved_mode}")
        args+=(
            "output.${TV_OUTPUT}.scale.${FALLBACK_TV_SCALE}"
            "output.${TV_OUTPUT}.position.${FALLBACK_TV_POS}"
            "output.${TV_OUTPUT}.priority.${FALLBACK_TV_PRIORITY}"
        )

        kscreen-doctor "${args[@]}"
    else
        local -a args=("output.${DESK_OUTPUT}.enable")
        [[ -n "$desk_mode" ]] && args+=("output.${DESK_OUTPUT}.mode.${desk_mode}")
        args+=(
            "output.${DESK_OUTPUT}.scale.${FALLBACK_DESK_SCALE}"
            "output.${DESK_OUTPUT}.position.${FALLBACK_DESK_POS}"
            "output.${DESK_OUTPUT}.priority.${FALLBACK_DESK_PRIORITY}"
        )

        kscreen-doctor "${args[@]}"
    fi
}

kde_restore_layout() {
    local -a args=()
    local json

    if [[ ! -f "$SNAPSHOT_FILE" ]]; then
        log "restore_layout: snapshot missing; using desktop fallback"
        kde_restore_fallback_layout
        kde_move_steam_to_desk_monitor
        return
    fi

    source "$SNAPSHOT_FILE"

    json="$(kde_get_layout_json)"
    log_layout_debug "restore_layout: before" "$json"

    kde_append_restore_args args "DESK" "$DESK_OUTPUT" "$json"
    kde_append_restore_args args "TV" "$TV_OUTPUT" "$json"

    log "restore_layout: executing kscreen-doctor: ${args[*]}"
    kscreen-doctor "${args[@]}"

    local json_after
    json_after="$(kde_get_layout_json)"
    log_layout_debug "restore_layout: after" "$json_after"
    rm -f "$SNAPSHOT_FILE"

    kde_move_steam_to_desk_monitor
}

kde_play() {
    log "play: starting couch mode"
    require_commands
    start_session
    AUTO_RESTORE_ON_EXIT=1
    trap cleanup EXIT INT TERM
    controller_session_reset

    log "play: active config => KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}, EXIT_ON_ALL_CONTROLLERS_OFF=${EXIT_ON_ALL_CONTROLLERS_OFF}"

    if [[ "${EXIT_ON_ALL_CONTROLLERS_OFF:-false}" == "true" ]] \
        && ! command -v wmctrl >/dev/null 2>&1; then
        log "WARNING: wmctrl is missing; the automatic return when controllers turn off cannot close Big Picture."
    fi

    save_snapshot
    kde_switch_to_tv
    log "play: couch layout applied, opening Big Picture"
    launch_big_picture_and_wait
    log "play: restoring desktop layout"
    kde_restore_layout
    AUTO_RESTORE_ON_EXIT=0
    log "play: layout restored successfully"
}

kde_restore() {
    log "restore: starting manual restore"
    require_commands

    driver_close_big_picture

    local had_session=0
    if [[ -f "$SESSION_FILE" ]] && kill -0 "$(<"$SESSION_FILE")" 2>/dev/null; then
        had_session=1
    fi

    stop_active_session

    if [[ "$had_session" == "0" ]] || [[ -f "$SNAPSHOT_FILE" ]]; then
        kde_restore_layout
    fi

    rm -f "$SESSION_FILE"
    log "restore: layout restored successfully"
}

kde_watch() {
    require_commands
    command -v wmctrl >/dev/null 2>&1 || die "The optional wmctrl command is required to monitor Big Picture."
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
            log "watch: Big Picture detected externally; config={KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}, EXIT_ON_ALL_CONTROLLERS_OFF=${EXIT_ON_ALL_CONTROLLERS_OFF}}"
            save_snapshot
            kde_switch_to_tv
            controller_session_reset
            active=1
            log "watch: Big Picture detected, couch layout applied"
        elif [[ "$active" == "1" ]] && ! driver_big_picture_window_present; then
            kde_restore_layout
            active=0
            log "watch: Big Picture closed, desktop layout restored"
        elif [[ "$active" == "1" ]] \
            && [[ "${EXIT_ON_ALL_CONTROLLERS_OFF:-false}" == "true" ]] \
            && controllers_all_off; then
            log "watch: all controllers turned off; closing Big Picture and restoring desktop"
            driver_close_big_picture
            wait_for_big_picture_close
            kde_restore_layout
            controller_session_reset
            active=0
            log "watch: desktop layout restored after all controllers turned off"
        fi
        sleep 2
    done
}
