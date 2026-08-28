#!/usr/bin/env bash
set -euo pipefail

# dispatcher.sh — command dispatcher for open-couch-engine.
#
# This is the SOURCE of the engine. In development it sources lib/ and drivers/
# directly; packaging/build-engine.sh concatenates everything into the single
# distributable backend/open-couch-engine. Never edit that generated file.

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ENGINE_DIR

# shellcheck source=lib/common.sh
source "${ENGINE_DIR}/lib/common.sh"
# shellcheck source=lib/detect.sh
source "${ENGINE_DIR}/lib/detect.sh"
# shellcheck source=drivers/generic.sh
source "${ENGINE_DIR}/drivers/generic.sh"
# shellcheck source=drivers/gnome.sh
source "${ENGINE_DIR}/drivers/gnome.sh"
# shellcheck source=drivers/hyprland.sh
source "${ENGINE_DIR}/drivers/hyprland.sh"
# shellcheck source=drivers/kde.sh
source "${ENGINE_DIR}/drivers/kde.sh"

load_config

COMPOSITOR="$(detect_compositor)"
if [[ "$COMPOSITOR" != "unknown" ]]; then
    if ! load_driver "$COMPOSITOR"; then
        log "WARNING: could not load driver for compositor '${COMPOSITOR}'; limited functionality available"
    fi
fi

usage() {
    cat <<'EOF'
Usage:
  open-couch-engine play
  open-couch-engine restore
  open-couch-engine status
  open-couch-engine outputs
  open-couch-engine check
  open-couch-engine version
  open-couch-engine watch
  open-couch-engine detect
  open-couch-engine capabilities
  open-couch-engine config-path
  open-couch-engine log
  open-couch-engine append-log <message>
  open-couch-engine clear-log
  open-couch-engine log-history
  open-couch-engine print-history-log <id>
  open-couch-engine export-history-log <id>
  open-couch-engine export-log
  open-couch-engine list-running
  open-couch-engine list-apps
  open-couch-engine close-tracked-apps
EOF
}

main() {
    case "${1:-}" in
        play)
            if [[ -z "$DRIVER_NAME" ]]; then
                die "No supported compositor detected. Supported: KDE Plasma, Hyprland."
            fi
            driver_play
            ;;
        restore)
            if [[ -z "$DRIVER_NAME" ]]; then
                die "No supported compositor detected."
            fi
            driver_restore
            ;;
        status)
            if [[ -n "$DRIVER_NAME" ]]; then
                require_commands
            fi
            print_status
            ;;
        outputs)
            if [[ -n "$DRIVER_NAME" ]]; then
                require_commands
            fi
            list_outputs
            ;;
        check)
            # Never report OK without a driver: that would hide a KDE session
            # missing kscreen-doctor, which falls through detection as 'unknown'.
            if [[ -z "$DRIVER_NAME" ]]; then
                die "No supported compositor detected. Supported: KDE Plasma, Hyprland."
            fi
            require_commands
            printf 'Host dependencies OK\n'
            ;;
        version)
            printf '%s\n' "$ENGINE_VERSION"
            ;;
        watch)
            if [[ -z "$DRIVER_NAME" ]]; then
                die "No supported compositor detected."
            fi
            driver_watch
            ;;
        detect)
            print_detect
            ;;
        capabilities)
            print_capabilities_json
            ;;
        config-path)
            printf '%s\n' "$CONFIG_FILE"
            ;;
        log)
            print_log
            ;;
        append-log)
            append_log_message "${2:-}"
            ;;
        clear-log)
            clear_log
            ;;
        log-history)
            log_history
            ;;
        print-history-log)
            print_history_log "${2:-}"
            ;;
        export-history-log)
            export_history_log "${2:-}"
            ;;
        export-log)
            export_log
            ;;
        list-running)
            list_running_apps
            ;;
        list-apps)
            list_apps
            ;;
        close-tracked-apps)
            close_tracked_apps
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

print_status() {
    log "Status refresh requested"
    log "Config: DESK_OUTPUT=$DESK_OUTPUT TV_OUTPUT=$TV_OUTPUT DESK_MODE=$FALLBACK_DESK_MODE DESK_SCALE=$FALLBACK_DESK_SCALE DESK_POS=$FALLBACK_DESK_POS DESK_PRIORITY=$FALLBACK_DESK_PRIORITY TV_MODE=$FALLBACK_TV_MODE TV_SCALE=$FALLBACK_TV_SCALE TV_POS=$FALLBACK_TV_POS TV_PRIORITY=$FALLBACK_TV_PRIORITY KEEP_DESK=$KEEP_DESK_ENABLED MIRROR=$MIRROR_DESK_TO_TV RESTORE=$AUTO_RESTORE_ON_EXIT WATCH_BP=$WATCH_BIG_PICTURE EXIT_ON_ALL_CONTROLLERS_OFF=$EXIT_ON_ALL_CONTROLLERS_OFF CLOSE_APPS_ENABLED=$CLOSE_APPS_ENABLED CLOSE_APPS_WAIT_SECONDS=$CLOSE_APPS_WAIT_SECONDS APPS_TO_CLOSE=$APPS_TO_CLOSE"
    log_missing_host_components
    if version_gte "${ENGINE_VERSION:-0.0.0}" "$MIN_VERSION"; then
        log "Engine version: ${ENGINE_VERSION:-unknown} (meets minimum requirement: $MIN_VERSION)"
    else
        log "Engine version: ${ENGINE_VERSION:-unknown} (below minimum requirement: $MIN_VERSION)"
    fi
    if [[ -n "$DRIVER_NAME" ]]; then
        log "Compositor: $(driver_name_from_id "$DRIVER_NAME")"
    else
        log "Compositor: unknown"
    fi
    if [[ -n "$DRIVER_NAME" ]]; then
        driver_get_layout_json | jq -c --arg desk "$DESK_OUTPUT" --arg tv "$TV_OUTPUT" '
            [
                (.outputs[] | select(.name == $desk) | . as $out | {
                    role: "desk",
                    name: .name,
                    enabled: .enabled,
                    connected: .connected,
                    priority: (.priority // null),
                    pos: (((.pos.x // 0) | tostring) + "," + ((.pos.y // 0) | tostring)),
                    scale: (.scale // 1),
                    mode: (($out.modes | map(select(.id == $out.currentModeId) | .name) | first) // "")
                }),
                (.outputs[] | select(.name == $tv) | . as $out | {
                    role: "tv",
                    name: .name,
                    enabled: .enabled,
                    connected: .connected,
                    priority: (.priority // null),
                    pos: (((.pos.x // 0) | tostring) + "," + ((.pos.y // 0) | tostring)),
                    scale: (.scale // 1),
                    mode: (($out.modes | map(select(.id == $out.currentModeId) | .name) | first) // "")
                })
            ]
        '
    else
        printf '[]\n'
    fi
}

list_outputs() {
    if [[ -n "$DRIVER_NAME" ]]; then
        driver_list_outputs_json
    else
        printf '[]\n'
    fi
}

main "$@"
