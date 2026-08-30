#!/usr/bin/env bats
#
# packaging/build-engine.sh concatenates lib/ + drivers/ + dispatcher.sh into
# the single backend/open-couch-engine that ships. Two things must hold for that
# to be safe, and both are checked here rather than trusted.

load '../helpers/common'

WORK=""

setup() {
    oc_sandbox
    # A throwaway copy of everything the build reads, so nothing here can touch
    # the repository.
    WORK="${OC_TMP}/tree"
    mkdir -p "${WORK}/backend" "${WORK}/app/src" "${WORK}/packaging"
    cp -a "${OC_ROOT}/backend/dispatcher.sh" "${OC_ROOT}/backend/lib" \
          "${OC_ROOT}/backend/drivers" "${WORK}/backend/"
    cp -a "${OC_ROOT}/app/version.txt" "${WORK}/app/"
    cp -a "${OC_ROOT}/app/src/engineclient.cpp" "${WORK}/app/src/"
    cp -a "${OC_ROOT}/packaging/build-engine.sh" "${WORK}/packaging/"
}

@test "the build fails when a driver defines an unprefixed top-level function" {
    # This is the guard against the regression that cost the most: an
    # unprefixed function in one driver silently replaces the shared
    # implementation from lib/common.sh for EVERY compositor.
    printf '\nbig_picture_window_present() {\n    return 0\n}\n' \
        >>"${WORK}/backend/drivers/hyprland.sh"

    run bash "${WORK}/packaging/build-engine.sh"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"unprefixed top-level function"* ]]
    [[ "$output" == *"big_picture_window_present"* ]]
}

@test "the guard covers every driver, not just Hyprland" {
    for driver in generic gnome hyprland kde; do
        setup
        printf '\nsome_helper() {\n    return 0\n}\n' \
            >>"${WORK}/backend/drivers/${driver}.sh"
        run bash "${WORK}/packaging/build-engine.sh"
        [[ "$status" -ne 0 ]] || { echo "${driver}.sh leaked without failing the build"; return 1; }
    done
}

@test "a correctly prefixed function does not trip the guard" {
    printf '\nhyprland_some_helper() {\n    return 0\n}\n' \
        >>"${WORK}/backend/drivers/hyprland.sh"
    run bash "${WORK}/packaging/build-engine.sh"
    [[ "$status" -eq 0 ]]
}

@test "the committed engine is exactly what the sources generate" {
    # backend/open-couch-engine is a generated artifact. If it drifts, what
    # ships stops being what the tests and reviews looked at.
    run bash "${WORK}/packaging/build-engine.sh"
    [[ "$status" -eq 0 ]]
    diff -u "${OC_ROOT}/backend/open-couch-engine" "${WORK}/backend/open-couch-engine"
}

@test "the generated engine is syntactically valid" {
    run bash -n "${OC_ROOT}/backend/open-couch-engine"
    [[ "$status" -eq 0 ]]
}

@test "the engine version comes from app/version.txt and the minimum from engineclient.cpp" {
    bash "${WORK}/packaging/build-engine.sh" >/dev/null

    local app_version min_version
    app_version="$(sed -n 's/^VERSION=\(.*\)$/\1/p' "${OC_ROOT}/app/version.txt")"
    min_version="$(sed -n 's/.*kMinEngineVersion[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${OC_ROOT}/app/src/engineclient.cpp")"

    grep -q "^ENGINE_VERSION=\"${app_version}\"" "${WORK}/backend/lib/common.sh"
    grep -q "^MIN_VERSION=\"${min_version}\"" "${WORK}/backend/lib/common.sh"

    # And the artifact reports it.
    run "${OC_ROOT}/backend/open-couch-engine" version
    [[ "$output" == "$app_version" ]]
}

@test "the build refuses a version.txt it cannot parse" {
    printf 'VERSION=not-a-version\nRELEASE_DATE=2026-01-01\n' >"${WORK}/app/version.txt"
    run bash "${WORK}/packaging/build-engine.sh"
    [[ "$status" -ne 0 ]]
}

@test "no driver function is unprefixed in the current sources" {
    # Same rule as the build guard, asserted directly on the repository so a
    # failure points at the file instead of at a build log.
    local f driver leaked
    for f in "${OC_ROOT}"/backend/drivers/*.sh; do
        driver="$(basename "$f" .sh)"
        leaked="$(grep -nE '^[a-z_][a-z0-9_]*\(\) *\{' "$f" | grep -vE ":${driver}_" || true)"
        [[ -z "$leaked" ]] || { echo "${f}: ${leaked}"; return 1; }
    done
}
