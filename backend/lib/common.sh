# common.sh — shared functions for the open-couch-engine dispatcher.
# Sourced by the dispatcher and all drivers.

# Both are synced by packaging/build-engine.sh — ENGINE_VERSION from
# app/version.txt, MIN_VERSION from kMinEngineVersion in app/src/engineclient.cpp.
# Do not edit manually.
ENGINE_VERSION="1.7.0"
MIN_VERSION="1.7.0"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/open-couch-engine"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/open-couch-engine"
CONFIG_FILE="${CONFIG_DIR}/config.env"
SNAPSHOT_FILE="${STATE_DIR}/layout.env"
SESSION_FILE="${STATE_DIR}/session.pid"
LOG_FILE="${STATE_DIR}/open-couch-engine.log"
HISTORY_DIR="${STATE_DIR}/history"
LOG_MAX_BYTES=524288
MAX_HISTORY_LOGS=50

DRIVER_NAME=""

REQUIRED_HOST_COMMANDS=()
OPTIONAL_HOST_COMMANDS=()
# Never listed to the user and never closed. Keep in sync with
# kProtectedProcesses in app/src/appcleanupmodel.cpp.
PROTECTED_PROCESSES=(
    # KDE Plasma
    plasmashell kwin_wayland kwin_x11 kwin_wayland_wrapper ksmserver systemsettings
    # Hyprland and its usual session components
    Hyprland hyprpaper hypridle hyprlock hyprsunset hyprpolkitagent
    waybar swaync mako wofi rofi uwsm xdg-desktop-portal-hyprland
    # Shared
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-kde
    steam steamwebhelper open-couch opencouch open-couch-engine Xwayland
)

DESK_OUTPUT="DP-1"
TV_OUTPUT="HDMI-A-1"

FALLBACK_DESK_MODE="1920x1080@300"
FALLBACK_DESK_SCALE="1"
FALLBACK_DESK_POS="0,0"
FALLBACK_DESK_PRIORITY="1"

FALLBACK_TV_MODE="3840x2160@120"
FALLBACK_TV_SCALE="1.7"
FALLBACK_TV_POS="1920,0"
FALLBACK_TV_PRIORITY="2"

KEEP_DESK_ENABLED="false"
MIRROR_DESK_TO_TV="false"

AUTO_RESTORE_ON_EXIT=0
WATCH_BIG_PICTURE="${WATCH_BIG_PICTURE:-false}"
EXIT_ON_ALL_CONTROLLERS_OFF="${EXIT_ON_ALL_CONTROLLERS_OFF:-false}"
CLOSE_APPS_ENABLED="${CLOSE_APPS_ENABLED:-false}"
CLOSE_APPS_WAIT_SECONDS="${CLOSE_APPS_WAIT_SECONDS:-5}"
APPS_TO_CLOSE="${APPS_TO_CLOSE:-}"
CONTROLLER_DEBOUNCE_SECS="${CONTROLLER_DEBOUNCE_SECS:-10}"
CONTROLLER_MIN_USAGE_SECS="${CONTROLLER_MIN_USAGE_SECS:-60}"

controller_usage_secs=0
controllers_off_since=""
controllers_last_poll=""

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
}

version_gte() {
    local current="$1"
    local minimum="$2"
    local current_major current_minor current_patch
    local minimum_major minimum_minor minimum_patch

    [[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    current_major=$((10#${BASH_REMATCH[1]}))
    current_minor=$((10#${BASH_REMATCH[2]}))
    current_patch=$((10#${BASH_REMATCH[3]}))

    [[ "$minimum" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    minimum_major=$((10#${BASH_REMATCH[1]}))
    minimum_minor=$((10#${BASH_REMATCH[2]}))
    minimum_patch=$((10#${BASH_REMATCH[3]}))

    (( current_major > minimum_major ||
       (current_major == minimum_major && current_minor > minimum_minor) ||
       (current_major == minimum_major && current_minor == minimum_minor &&
        current_patch >= minimum_patch) ))
}

in_terminal() {
    [[ -t 1 || -t 2 ]]
}

archive_log() {
    local ts dest i
    mkdir -p "$HISTORY_DIR"
    ts="$(date '+%Y%m%d-%H%M%S')"
    dest="${HISTORY_DIR}/open-couch-engine-${ts}.log"
    i=1
    while [[ -e "$dest" ]]; do
        dest="${HISTORY_DIR}/open-couch-engine-${ts}.log.${i}"
        i=$((i + 1))
    done
    if [[ -f "$LOG_FILE" ]]; then
        cp "$LOG_FILE" "$dest"
    else
        : >"$dest"
    fi
    find "$HISTORY_DIR" -maxdepth 1 -type f -name 'open-couch-engine-*.log*' -printf '%f\n' 2>/dev/null \
        | LC_ALL=C sort \
        | head -n -"$MAX_HISTORY_LOGS" \
        | while read -r f; do rm -f "${HISTORY_DIR}/${f}"; done
    printf '%s\n' "$dest"
}

log() {
    mkdir -p "$STATE_DIR"
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > LOG_MAX_BYTES )); then
        archive_log >/dev/null 2>&1 || true
        : >"$LOG_FILE"
    fi
    # Accepts either `log "message"` or `log LEVEL "message"`.
    local message="$1"
    if (( $# > 1 )); then
        message="$1: $2"
    fi
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$$] ${message}"
    printf '%s\n' "$line" >>"$LOG_FILE"
    printf '%s\n' "$line" >&2
}

show_error() {
    local message="$1"
    log "ERROR: $message"
    if in_terminal; then
        printf 'open-couch-engine: %s\n' "$message" >&2
        return
    fi

    if command -v zenity >/dev/null 2>&1; then
        timeout 15 zenity --error --title="Open Couch" --text="$message" >/dev/null 2>&1 || true
    else
        printf 'open-couch-engine: %s\n' "$message" >&2
    fi
}

die() {
    show_error "$1"
    exit 1
}

on_error() {
    local exit_code=$?
    show_error "Unexpected failure (command: '${BASH_COMMAND}', line ${BASH_LINENO[0]:-?}, exit ${exit_code}). The display layout may be incomplete; try running 'open-couch-engine restore' again."
}

trap on_error ERR

require_commands() {
    local cmd
    local -a missing=()
    for cmd in "${REQUIRED_HOST_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]} > 0)); then
        die "Missing dependencies: ${missing[*]}. Install them on the host and try again."
    fi
}

log_missing_host_components() {
    local cmd
    local -a missing_required=()
    local -a missing_optional=()

    for cmd in "${REQUIRED_HOST_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_required+=("$cmd")
    done

    for cmd in "${OPTIONAL_HOST_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_optional+=("$cmd")
    done

    if ((${#missing_required[@]} > 0)); then
        log "ERROR: Missing required host components: ${missing_required[*]}. Couch Mode will not work until they are installed."
    fi

    if ((${#missing_optional[@]} > 0)); then
        log "WARNING: Missing optional host component(s): ${missing_optional[*]} — Big Picture monitoring and automatic return when controllers turn off are disabled."
    fi
}

output_snapshot_tsv() {
    local json="$1"
    local output="$2"

    jq -r --arg output "$output" '
        .outputs[]
        | select(.name == $output)
        | . as $out
        | [
            (.connected | tostring),
            (.enabled | tostring),
            ((.priority // "") | tostring),
            ((((.pos.x // 0) | tostring) + "," + ((.pos.y // 0) | tostring))),
            ((.scale // 1) | tostring),
            (($out.modes | map(select(.id == $out.currentModeId) | .name) | first) // "")
        ]
        | @tsv
    ' <<<"$json"
}

output_debug_line() {
    local json="$1"
    local output="$2"
    local line

    line="$(jq -r --arg name "$output" '
        .outputs[]
        | select(.name == $name)
        | . as $out
        | "name=\(.name); connected=\(.connected|tostring); enabled=\(.enabled|tostring); priority=\(.priority // "n/a"); pos=\((((.pos.x // 0) | tostring) + "," + ((.pos.y // 0) | tostring))); scale=\(.scale // 1); mode=\(($out.modes | map(select(.id == $out.currentModeId) | .name) | first) // "n/a")"
    ' <<<"$json" 2>/dev/null)"

    if [[ -n "$line" ]]; then
        printf '%s\n' "$line"
    else
        printf '%s\n' "name=${output}; not found"
    fi
}

log_layout_debug() {
    local stage="$1"
    local json="$2"
    local primary_output desk_summary tv_summary

    primary_output="$(jq -r '
        [ .outputs[] | select(.enabled == true) | {name, priority:(.priority // 0)} ]
        | if length == 0 then "unknown" else (sort_by(.priority | tonumber) | .[0].name) end
    ' <<<"$json" 2>/dev/null || printf '%s\n' 'unknown')"

    desk_summary="$(output_debug_line "$json" "$DESK_OUTPUT")"
    tv_summary="$(output_debug_line "$json" "$TV_OUTPUT")"

    log "${stage}: primary_output=${primary_output}; config={KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}, EXIT_ON_ALL_CONTROLLERS_OFF=${EXIT_ON_ALL_CONTROLLERS_OFF}}; desk={${desk_summary}}; tv={${tv_summary}}"
}

verify_primary_output() {
    local stage="$1"
    local json="$2"
    local expected_primary="$TV_OUTPUT"
    local actual_primary

    actual_primary="$(jq -r '
        [ .outputs[] | select(.enabled == true) | {name, priority:(.priority // 0)} ]
        | if length == 0 then "unknown" else (sort_by(.priority | tonumber) | .[0].name) end
    ' <<<"$json" 2>/dev/null || printf '%s\n' 'unknown')"

    if [[ "$actual_primary" == "$expected_primary" ]]; then
        log "${stage}: confirmation: the TV (${TV_OUTPUT}) is the active primary output."
    else
        log "${stage}: WARNING: the active primary output is ${actual_primary:-unknown}, but the expected one is ${expected_primary}. This may explain Big Picture opening on the wrong display; check kscreen-doctor priority/pos and the compositor."
    fi
}

mode_exists() {
    local json="$1"
    local output="$2"
    local mode="$3"

    [[ -n "$mode" ]] || return 1

    jq -e --arg output "$output" --arg mode "$mode" '
        .outputs[]
        | select(.name == $output)
        | .modes[]
        | select(.name == $mode)
    ' >/dev/null 2>&1 <<<"$json"
}

resolve_mode() {
    local json="$1"
    local output="$2"
    local desired_mode="$3"

    if mode_exists "$json" "$output" "$desired_mode"; then
        printf '%s' "$desired_mode"
        return 0
    fi

    if [[ -n "$desired_mode" ]]; then
        show_error "Warning: the mode '${desired_mode}' is no longer available on ${output} (probably because the cable was reconnected). Using the best equivalent mode." || true
    fi

    local resolution
    resolution="${desired_mode%%@*}"

    if [[ -n "$resolution" ]]; then
        jq -r --arg output "$output" --arg resolution "$resolution" '
            .outputs[]
            | select(.name == $output)
            | .modes[]
            | select((.name | startswith($resolution + "@")))
            | [.refreshRate, .name]
            | @tsv
        ' <<<"$json" | LC_ALL=C sort -rn -k1 | head -n1 | cut -f2
    fi
}

logical_width() {
    local mode="$1"
    local scale="$2"
    local w

    w="${mode%%x*}"
    if [[ "$w" =~ ^[0-9]+$ ]] && [[ "$scale" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        awk -v w="$w" -v s="$scale" 'BEGIN { printf "%d\n", (w / s) + 0.999 }'
    else
        printf '%s\n' "1920"
    fi
}

common_mirror_mode() {
    local json="$1"
    local output_a="$2"
    local output_b="$3"
    local desired_mode="$4"

    if mode_exists "$json" "$output_a" "$desired_mode" && mode_exists "$json" "$output_b" "$desired_mode"; then
        printf '%s\n' "$desired_mode"
        return 0
    fi

    jq -r --arg a "$output_a" --arg b "$output_b" '
        ( [ .outputs[] | select(.name == $a) | .modes[].name ] | unique ) as $ma
        | ( [ .outputs[] | select(.name == $b) | .modes[].name ] | unique ) as $mb
        | [ $ma[] | select(. as $m | $mb | index($m)) ] as $common
        | $common
        | map(. as $n | [($n | split("@")[0] | split("x")[0] | tonumber), ($n | split("@")[1] | tonumber), $n])
        | sort_by(.[0], .[1])
        | reverse
        | .[0][2]
    ' <<<"$json" 2>/dev/null || true
}

save_var() {
    local name="$1"
    local value="$2"
    printf '%s=%q\n' "$name" "$value" >>"$SNAPSHOT_FILE"
}

save_snapshot() {
    local json desk_line tv_line
    local desk_connected desk_enabled desk_priority desk_pos desk_scale desk_mode
    local tv_connected tv_enabled tv_priority tv_pos tv_scale tv_mode

    json="$(driver_get_layout_json)"

    desk_line="$(output_snapshot_tsv "$json" "$DESK_OUTPUT")"
    tv_line="$(output_snapshot_tsv "$json" "$TV_OUTPUT")"

    [[ -n "$desk_line" ]] || die "Could not find the office display ($DESK_OUTPUT)."
    [[ -n "$tv_line" ]] || die "Could not find the TV ($TV_OUTPUT)."

    IFS=$'\t' read -r desk_connected desk_enabled desk_priority desk_pos desk_scale desk_mode <<<"$desk_line"
    IFS=$'\t' read -r tv_connected tv_enabled tv_priority tv_pos tv_scale tv_mode <<<"$tv_line"

    [[ "$tv_connected" == "true" ]] || die "The TV ($TV_OUTPUT) is not connected."

    mkdir -p "$STATE_DIR"
    : >"$SNAPSHOT_FILE"

    save_var "DESK_OUTPUT" "$DESK_OUTPUT"
    save_var "DESK_ENABLED" "$desk_enabled"
    save_var "DESK_PRIORITY" "$desk_priority"
    save_var "DESK_POS" "$desk_pos"
    save_var "DESK_SCALE" "$desk_scale"
    save_var "DESK_MODE" "${desk_mode:-$FALLBACK_DESK_MODE}"

    save_var "TV_OUTPUT" "$TV_OUTPUT"
    save_var "TV_ENABLED" "$tv_enabled"
    save_var "TV_PRIORITY" "$tv_priority"
    save_var "TV_POS" "$tv_pos"
    save_var "TV_SCALE" "$tv_scale"
    save_var "TV_MODE" "${tv_mode:-$FALLBACK_TV_MODE}"
}

driver_name_from_id() {
    local id="$1"
    case "$id" in
        kde)        printf 'KDE Plasma' ;;
        hyprland)   printf 'Hyprland' ;;
        gnome)      printf 'GNOME' ;;
        generic-x11) printf 'Generic X11' ;;
        *)          printf '%s' "$id" ;;
    esac
}

steam_main_pids() {
    pgrep -u "$USER" -x steam || true
}

# Default implementation, used by any driver that does not provide its own
# <driver>_big_picture_window_present. load_driver() wires the dispatch.
default_big_picture_window_present() {
    driver_window_action is_open '([Ss]team|[Bb]ig.?[Pp]icture)'
}

controllers_connected() {
    local -a devices=(/dev/input/js*)
    if [[ -e "${devices[0]:-}" ]]; then
        printf '%s\n' "${#devices[@]}"
    else
        printf '%s\n' "0"
    fi
}

controller_session_reset() {
    controller_usage_secs=0
    controllers_off_since=""
    controllers_last_poll=""
}

controllers_all_off() {
    local count now delta
    count="$(controllers_connected)"
    now="$(date +%s)"

    if [[ -n "$controllers_last_poll" ]]; then
        delta=$(( now - controllers_last_poll ))
        if (( delta > 0 )) && (( count > 0 )); then
            controller_usage_secs=$(( controller_usage_secs + delta ))
        fi
    fi
    controllers_last_poll="$now"

    if (( count > 0 )); then
        controllers_off_since=""
        return 1
    fi

    if (( controller_usage_secs < CONTROLLER_MIN_USAGE_SECS )); then
        controllers_off_since=""
        return 1
    fi

    if [[ -z "$controllers_off_since" ]]; then
        controllers_off_since="$now"
        return 1
    fi

    if (( now - controllers_off_since >= CONTROLLER_DEBOUNCE_SECS )); then
        return 0
    fi
    return 1
}

is_protected_process() {
    local name="$1"
    local lower_name="${name,,}"
    if [[ "$lower_name" == xwayland* ]]; then
        return 0
    fi
    local protected
    for protected in "${PROTECTED_PROCESSES[@]}"; do
        if [[ "${protected,,}" == "$lower_name" ]]; then
            return 0
        fi
    done
    return 1
}

close_tracked_apps() {
    local apps_raw="${APPS_TO_CLOSE:-}"
    [[ -n "$apps_raw" ]] || return 0
    local -a apps=()
    IFS=',' read -ra apps <<< "$apps_raw"
    local app
    for app in "${apps[@]}"; do
        app="$(printf '%s' "$app" | xargs)"
        [[ -n "$app" ]] || continue
        if is_protected_process "$app"; then
            log "app-cleanup: skipping protected process $app"
            continue
        fi
        if pkill -x "$app" 2>/dev/null; then
            log "app-cleanup: closed $app"
        else
            log "app-cleanup: no process found for $app"
        fi
    done
}

desktop_process_names() {
    local exec_line="$1"
    local -a names=()
    if [[ "$exec_line" == *"flatpak run"* ]]; then
        local cmd
        cmd="$(printf '%s' "$exec_line" | grep -oE -- '--command=[^[:space:]]+' 2>/dev/null | head -n1 | cut -d= -f2- || true)"
        if [[ -n "$cmd" ]]; then
            cmd="${cmd#\"}"
            cmd="${cmd%\"}"
            cmd="${cmd#\'}"
            cmd="${cmd%\'}"
            if [[ "$cmd" == *"/"* ]]; then
                cmd="$(basename "$cmd" 2>/dev/null || printf '%s' "$cmd")"
                cmd="$(printf '%s' "$cmd" | xargs 2>/dev/null || printf '%s' "$cmd")"
                [[ -n "$cmd" ]] && names+=("$cmd")
            fi
        fi
        local appid
        appid="$(printf '%s' "$exec_line" | grep -oE '[A-Za-z0-9_-]+\.[A-Za-z0-9._-]+' 2>/dev/null | grep -E '\.' | head -n1 || true)"
        if [[ -n "$appid" ]]; then
            local last="${appid##*.}"
            last="$(printf '%s' "$last" | xargs 2>/dev/null || printf '%s' "$last")"
            [[ -n "$last" ]] && names+=("$last")
        fi
        if ((${#names[@]} == 0)); then
            names+=("flatpak")
        fi
    else
        local cleaned
        cleaned="$(printf '%s' "$exec_line" | sed -E 's/ %[fFuUdDnNiCkKvVm]//g; s/^ *//; s/ *$//')"
        local -a parts=()
        read -ra parts <<< "$cleaned"
        local token=""
        local p
        for p in "${parts[@]}"; do
            if [[ "$p" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                if [[ "$p" != /* && "$p" != *":"* ]]; then
                    continue
                fi
            fi
            if [[ "$p" == "env" ]]; then
                continue
            fi
            token="$p"
            break
        done
        [[ -n "$token" ]] || token="${parts[0]:-}"
        token="${token#\"}"
        token="${token%\"}"
        token="${token#\'}"
        token="${token%\'}"
        local pname
        pname="$(basename "$token" 2>/dev/null || printf '%s' "$token")"
        pname="$(printf '%s' "$pname" | xargs 2>/dev/null || printf '%s' "$pname")"
        [[ -n "$pname" ]] && names+=("$pname")
    fi
    printf '%s\n' "${names[@]}"
}

list_apps() {
    local -A seen=()
    local -a entries=()
    local -A visited=()
    local -a search_dirs=()
    search_dirs+=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
    local xdg_dirs_str="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    local -a xdg_dirs=()
    IFS=':' read -ra xdg_dirs <<< "$xdg_dirs_str"
    local d
    for d in "${xdg_dirs[@]}"; do
        [[ -n "$d" ]] || continue
        search_dirs+=("$d/applications")
    done
    search_dirs+=("$HOME/.local/share/flatpak/exports/share/applications")
    search_dirs+=("/var/lib/flatpak/exports/share/applications")
    search_dirs+=("/var/lib/snapd/desktop/applications")
    local dir file
    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        [[ -n "${visited[$dir]:-}" ]] && continue
        visited["$dir"]=1
        while IFS= read -r -d '' file; do
            if grep -qE '^[[:space:]]*NoDisplay[[:space:]]*=[[:space:]]*true' "$file" 2>/dev/null; then
                continue
            fi
            if grep -qE '^[[:space:]]*Hidden[[:space:]]*=[[:space:]]*true' "$file" 2>/dev/null; then
                continue
            fi
            local f_type
            f_type="$(grep -m1 -E '^[[:space:]]*Type[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | xargs 2>/dev/null || true)"
            if [[ -n "$f_type" && "$f_type" != "Application" ]]; then
                continue
            fi
            local f_name f_exec f_icon
            f_name="$(grep -m1 -E '^[[:space:]]*Name[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
            f_exec="$(grep -m1 -E '^[[:space:]]*Exec[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
            f_icon="$(grep -m1 -E '^[[:space:]]*Icon[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
            [[ -n "$f_name" && -n "$f_exec" ]] || continue
            local -a pnames=()
            while IFS= read -r pn; do
                [[ -n "$pn" ]] || continue
                pnames+=("$pn")
            done < <(desktop_process_names "$f_exec")
            if ((${#pnames[@]} == 0)); then
                continue
            fi
            local pname
            for pname in "${pnames[@]}"; do
                if is_protected_process "$pname"; then
                    continue
                fi
                local lower="${pname,,}"
                if [[ -n "${seen[$lower]:-}" ]]; then
                    continue
                fi
                seen["$lower"]=1
                local icon_val="${f_icon:-application-x-executable}"
                local json_entry
                json_entry="$(jq -c -n --arg processName "$pname" --arg displayName "$f_name" --arg icon "$icon_val" '{processName:$processName, displayName:$displayName, icon:$icon}')"
                entries+=("$json_entry")
            done
        done < <(find "$dir" -maxdepth 2 \( -type f -o -type l \) -name "*.desktop" -print0 2>/dev/null)
    done
    if ((${#entries[@]} == 0)); then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "${entries[@]}" | jq -s -c 'sort_by(.displayName | ascii_downcase)'
}

list_running_apps() {
    local -A seen=()
    local -A desktop_name=()
    local -A desktop_icon=()
    local -A visited=()
    local -a search_dirs=()
    search_dirs+=("${XDG_DATA_HOME:-$HOME/.local/share}/applications")
    local xdg_dirs_str="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    local -a xdg_dirs=()
    IFS=':' read -ra xdg_dirs <<< "$xdg_dirs_str"
    local d
    for d in "${xdg_dirs[@]}"; do
        [[ -n "$d" ]] || continue
        search_dirs+=("$d/applications")
    done
    search_dirs+=("$HOME/.local/share/flatpak/exports/share/applications")
    search_dirs+=("/var/lib/flatpak/exports/share/applications")
    search_dirs+=("/var/lib/snapd/desktop/applications")
    local dir file
    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        [[ -n "${visited[$dir]:-}" ]] && continue
        visited["$dir"]=1
        while IFS= read -r -d '' file; do
            if grep -qE '^[[:space:]]*NoDisplay[[:space:]]*=[[:space:]]*true' "$file" 2>/dev/null; then
                continue
            fi
            if grep -qE '^[[:space:]]*Hidden[[:space:]]*=[[:space:]]*true' "$file" 2>/dev/null; then
                continue
            fi
            local f_type
            f_type="$(grep -m1 -E '^[[:space:]]*Type[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | xargs 2>/dev/null || true)"
            if [[ -n "$f_type" && "$f_type" != "Application" ]]; then
                continue
            fi
            local f_name f_exec f_icon
            f_name="$(grep -m1 -E '^[[:space:]]*Name[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
            f_exec="$(grep -m1 -E '^[[:space:]]*Exec[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
            f_icon="$(grep -m1 -E '^[[:space:]]*Icon[[:space:]]*=' "$file" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
            [[ -n "$f_name" && -n "$f_exec" ]] || continue
            local -a pnames=()
            while IFS= read -r pn; do
                [[ -n "$pn" ]] || continue
                pnames+=("$pn")
            done < <(desktop_process_names "$f_exec")
            local pname
            for pname in "${pnames[@]}"; do
                if is_protected_process "$pname"; then
                    continue
                fi
                local lower="${pname,,}"
                if [[ -z "${desktop_name[$lower]:-}" ]]; then
                    desktop_name["$lower"]="$f_name"
                    desktop_icon["$lower"]="${f_icon:-application-x-executable}"
                fi
            done
        done < <(find "$dir" -maxdepth 2 \( -type f -o -type l \) -name "*.desktop" -print0 2>/dev/null)
    done

    local current_user
    current_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
    [[ -n "$current_user" ]] || current_user="${USER:-$(whoami 2>/dev/null || true)}"

    local -a pids=()
    if command -v pgrep >/dev/null 2>&1 && [[ -n "$current_user" ]]; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            pids+=("$pid")
        done < <(pgrep -u "$current_user" 2>/dev/null || true)
    fi
    if ((${#pids[@]} == 0)); then
        while IFS= read -r pid _; do
            [[ -n "$pid" ]] || continue
            if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
                continue
            fi
            pids+=("$pid")
        done < <(ps -u "$current_user" -o pid= 2>/dev/null || ps -eo pid= 2>/dev/null || true)
    fi

    local -a entries=()
    local pid pname exe_name comm_raw displayName icon windowTitle cmd json_entry lower
    for pid in "${pids[@]}"; do
        [[ -n "$pid" ]] || continue
        if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
            continue
        fi
        if [[ ! -d "/proc/$pid" ]]; then
            continue
        fi
        exe_name="$(basename "$(readlink "/proc/$pid/exe" 2>/dev/null)" 2>/dev/null || true)"
        exe_name="$(printf '%s' "$exe_name" | xargs 2>/dev/null || printf '%s' "$exe_name")"
        if [[ -n "$exe_name" ]]; then
            pname="$exe_name"
        else
            comm_raw="$(tr -d '\0' < "/proc/$pid/comm" 2>/dev/null | xargs 2>/dev/null || true)"
            if [[ -z "$comm_raw" ]]; then
                comm_raw="$(ps -p "$pid" -o comm= 2>/dev/null | xargs 2>/dev/null || true)"
            fi
            pname="$comm_raw"
            pname="$(printf '%s' "$pname" | xargs 2>/dev/null || printf '%s' "$pname")"
        fi
        [[ -n "$pname" ]] || continue
        if is_protected_process "$pname"; then
            continue
        fi
        lower="${pname,,}"
        if [[ -n "${seen[$lower]:-}" ]]; then
            continue
        fi
        displayName="${desktop_name[$lower]:-}"
        icon="${desktop_icon[$lower]:-}"
        if [[ -z "$displayName" ]]; then
            continue
        fi
        seen["$lower"]=1
        [[ -n "$icon" ]] || icon="application-x-executable"
        cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | xargs 2>/dev/null | cut -c1-300 || true)"
        windowTitle="$cmd"
        [[ -n "$windowTitle" ]] || windowTitle="$displayName"
        json_entry="$(jq -c -n --arg processName "$pname" --argjson pid "$pid" --arg displayName "$displayName" --arg windowTitle "$windowTitle" --arg icon "$icon" '{processName:$processName, pid:$pid, displayName:$displayName, windowTitle:$windowTitle, icon:$icon}')"
        entries+=("$json_entry")
    done

    if ((${#entries[@]} == 0)); then
        printf '[]\n'
        return 0
    fi
    printf '%s\n' "${entries[@]}" | jq -s -c 'sort_by(.displayName | ascii_downcase)'
}

wait_for_big_picture_close() {
    local attempt

    for attempt in $(seq 1 30); do
        if ! driver_big_picture_window_present; then
            return 0
        fi
        sleep 1
    done
    return 0
}

wait_for_new_steam_pid() {
    local existing_pids="$1"
    local pid
    local attempt

    for attempt in $(seq 1 90); do
        while read -r pid; do
            [[ -n "$pid" ]] || continue
            if [[ "$existing_pids" != *" $pid "* ]]; then
                printf '%s\n' "$pid"
                return 0
            fi
        done < <(steam_main_pids)

        sleep 1
    done

    return 1
}

wait_for_big_picture_window() {
    local attempt

    for attempt in $(seq 1 60); do
        if driver_big_picture_window_present; then
            return 0
        fi
        sleep 1
    done

    return 1
}

wait_for_pid_exit() {
    local pid="$1"

    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
    done
}

wait_for_steam_exit_or_bpm_exit() {
    local steam_pid="$1"
    local bpm_seen="$2"

    while kill -0 "$steam_pid" 2>/dev/null; do
        if [[ "$bpm_seen" == "1" ]] && ! driver_big_picture_window_present; then
            return 0
        fi

        if [[ "${EXIT_ON_ALL_CONTROLLERS_OFF:-false}" == "true" ]] && controllers_all_off; then
            controller_session_reset
            driver_close_big_picture
            log "controllers: all controllers turned off; closing Big Picture and returning to desktop"
            return 0
        fi

        sleep 2
    done

    return 0
}

# Default implementation, used by any driver that does not provide its own
# <driver>_close_big_picture. load_driver() wires the dispatch.
default_close_big_picture() {
    log "Closing Big Picture (keeping Steam open in desktop mode)"
    driver_window_action close '([Ss]team|[Bb]ig.?[Pp]icture)' || true
    sleep 0.5
}

launch_big_picture_and_wait() {
    local existing_pids steam_pid launcher_pid bpm_seen
    local -a steam_launcher=()

    existing_pids=" $(steam_main_pids | tr '\n' ' ') "

    if command -v bazzite-steam-bpm >/dev/null 2>&1; then
        steam_launcher=(bazzite-steam-bpm)
        log "play: using Bazzite's Big Picture launcher"
    elif command -v steam >/dev/null 2>&1; then
        # The URI works both when Steam is already running and when it needs
        # to start.
        steam_launcher=(steam steam://open/bigpicture)
        log "play: using the default Steam Big Picture launcher"
    else
        die "Could not find Steam or the bazzite-steam-bpm launcher."
    fi

    log "play: trying to start Big Picture with launcher=${steam_launcher[*]} and config={KEEP_DESK_ENABLED=${KEEP_DESK_ENABLED}, MIRROR_DESK_TO_TV=${MIRROR_DESK_TO_TV}, DESK_OUTPUT=${DESK_OUTPUT}, TV_OUTPUT=${TV_OUTPUT}, EXIT_ON_ALL_CONTROLLERS_OFF=${EXIT_ON_ALL_CONTROLLERS_OFF}}"

    "${steam_launcher[@]}" >/dev/null 2>&1 &
    launcher_pid=$!

    # If Steam was already running, the launcher reuses the existing process
    # (no new PID).  Use the existing one directly instead of waiting 90s.
    local trimmed_pids
    trimmed_pids="${existing_pids// /}"
    if [[ -n "$trimmed_pids" ]]; then
        steam_pid="$(pgrep -u "$USER" -n -x steam || true)"
        log "play: Steam was already running, reusing existing PID=${steam_pid}"
    else
        steam_pid="$(wait_for_new_steam_pid "$existing_pids" || true)"
        if [[ -z "$steam_pid" ]]; then
            steam_pid="$(pgrep -u "$USER" -n -x steam || true)"
        fi
    fi

    [[ -n "$steam_pid" ]] || die "Could not detect Steam opening in Big Picture."

    log "play: Steam detected: PID=${steam_pid}; launcher_pid=${launcher_pid}"

    bpm_seen=0
    if wait_for_big_picture_window; then
        bpm_seen=1
        log "play: Big Picture detected, monitoring until it closes or Steam exits"
    else
        log "play: could not detect the Big Picture window; will wait for Steam to close"
    fi

    if [[ "${CLOSE_APPS_ENABLED:-false}" == "true" && -n "${APPS_TO_CLOSE:-}" ]]; then
        (
            sleep "${CLOSE_APPS_WAIT_SECONDS:-5}"
            close_tracked_apps
        ) &
        disown
    fi

    wait_for_steam_exit_or_bpm_exit "$steam_pid" "$bpm_seen"

    if kill -0 "$steam_pid" 2>/dev/null; then
        log "play: Big Picture closed (Steam still open in desktop mode)"
        :
    else
        log "play: Steam exited"
        wait "$launcher_pid" || true
    fi
}

start_session() {
    local existing_pid

    mkdir -p "$STATE_DIR"

    if [[ -f "$SESSION_FILE" ]]; then
        existing_pid="$(<"$SESSION_FILE")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            die "Couch mode is already running."
        fi
    fi

    printf '%s\n' "$$" >"$SESSION_FILE"
}

clear_session_file() {
    if [[ -f "$SESSION_FILE" ]]; then
        local session_pid
        session_pid="$(<"$SESSION_FILE")"
        if [[ "$session_pid" == "$$" ]]; then
            rm -f "$SESSION_FILE"
        fi
    fi
}

cleanup() {
    local status=$?

    if [[ "$AUTO_RESTORE_ON_EXIT" == "1" ]]; then
        # Never silence this: swallowing the output once hid the fact that the
        # function being called did not exist, leaving the desk monitor off.
        if ! driver_restore_layout; then
            log "ERROR: automatic layout restore failed on exit; run 'open-couch-engine restore'"
        fi
    fi

    clear_session_file
    exit "$status"
}

stop_active_session() {
    local session_pid=""

    if [[ -f "$SESSION_FILE" ]]; then
        session_pid="$(<"$SESSION_FILE")"
    fi

    if [[ -n "$session_pid" ]] && [[ "$session_pid" != "$$" ]] && kill -0 "$session_pid" 2>/dev/null; then
        kill "$session_pid" || true
        local waited=0
        while kill -0 "$session_pid" 2>/dev/null; do
            sleep 0.2
            waited=$((waited + 1))
            if (( waited > 50 )); then
                break
            fi
        done
    fi

    rm -f "$SESSION_FILE"
}

print_log() {
    if [[ -f "$LOG_FILE" ]]; then
        cat "$LOG_FILE"
    fi
}

export_log() {
    local dest
    dest="${HOME}/open-couch-log-$(date '+%Y%m%d-%H%M%S').txt"
    if [[ -f "$LOG_FILE" ]]; then
        cp "$LOG_FILE" "$dest"
    else
        : >"$dest"
    fi
    printf '%s\n' "$dest"
}

clear_log() {
    local dest
    dest="$(archive_log)"
    : >"$LOG_FILE"
    log "log cleared; previous content archived in $(basename "${dest}")"
}

append_log_message() {
    local raw="${1:-}"
    local message

    message="$(printf '%s' "$raw" | tr -d '\000-\037\177')"
    message="${message:0:500}"
    message="${message#"${message%%[![:space:]]*}"}"
    message="${message%"${message##*[![:space:]]}"}"

    [[ -n "$message" ]] || return 0
    log "$message"
}

valid_history_id() {
    [[ "$1" =~ ^open-couch-engine-[0-9]{8}-[0-9]{6}(\.log(\.[0-9]+)?)?$ ]]
}

log_history() {
    mkdir -p "$HISTORY_DIR"
    find "$HISTORY_DIR" -maxdepth 1 -type f -name 'open-couch-engine-*.log*' -printf '%f\t%s\n' 2>/dev/null \
        | LC_ALL=C sort -r \
        | jq -Rn '
            [inputs
             | select(length > 0)
             | split("\t") as $p
             | {id: $p[0],
                size: ($p[1] | tonumber),
                timestamp: ($p[0] | sub("^open-couch-engine-"; "") | sub("\\.log(\\.[0-9]+)?$"; ""))}]'
}

print_history_log() {
    local id="$1"
    valid_history_id "$id" || die "Invalid history log id."
    local src="${HISTORY_DIR}/${id}"
    [[ -f "$src" ]] || die "History log not found: ${id}."
    cat "$src"
}

export_history_log() {
    local id="$1"
    valid_history_id "$id" || die "Invalid history log id."
    local src="${HISTORY_DIR}/${id}"
    [[ -f "$src" ]] || die "History log not found: ${id}."
    local dest="${HOME}/open-couch-log-${id}"
    cp "$src" "$dest"
    printf '%s\n' "$dest"
}

print_capabilities_json() {
    if [[ -n "$DRIVER_NAME" ]]; then
        driver_capabilities_json
    else
        printf '{"compositor":"unknown","display":{"list_outputs":false},"note":"no_driver"}'
    fi
}

print_detect() {
    if [[ -n "$DRIVER_NAME" ]]; then
        printf '%s\n' "$DRIVER_NAME"
    else
        printf '%s\n' "unknown"
    fi
}
