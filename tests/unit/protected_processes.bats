#!/usr/bin/env bats
#
# PROTECTED_PROCESSES (backend/lib/common.sh) and kProtectedProcesses
# (app/src/appcleanupmodel.cpp) are two copies of one list. AGENTS.md requires
# them to stay in sync and nothing enforced it: when they drifted, the GUI
# offered to close the user's own compositor.

load '../helpers/common'

setup() {
    oc_sandbox
}

bash_list() {
    oc_load_engine "" >/dev/null 2>&1
    printf '%s\n' "${PROTECTED_PROCESSES[@]}" | LC_ALL=C sort
}

cpp_list() {
    sed -n '/kProtectedProcesses = {/,/^};/p' "${OC_ROOT}/app/src/appcleanupmodel.cpp" \
        | grep -oE 'QStringLiteral\("[^"]+"\)' \
        | sed -E 's/QStringLiteral\("(.*)"\)/\1/' \
        | LC_ALL=C sort
}

@test "both protected-process lists are non-empty" {
    [[ "$(bash_list | wc -l)" -gt 10 ]]
    [[ "$(cpp_list | wc -l)" -gt 10 ]]
}

@test "the engine and the app protect exactly the same processes" {
    run diff <(bash_list) <(cpp_list)
    if [[ "$status" -ne 0 ]]; then
        echo "PROTECTED_PROCESSES (backend/lib/common.sh) and kProtectedProcesses"
        echo "(app/src/appcleanupmodel.cpp) have drifted apart:"
        echo "$output"
        return 1
    fi
}

@test "both lists cover the KDE and the Hyprland session" {
    local list
    list="$(bash_list)"
    for name in plasmashell kwin_wayland ksmserver \
                Hyprland waybar hyprlock uwsm xdg-desktop-portal-hyprland; do
        grep -qxF "$name" <<<"$list" || { echo "$name missing from the engine list"; return 1; }
    done
}
