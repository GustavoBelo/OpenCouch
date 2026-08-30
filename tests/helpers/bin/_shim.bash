# Shared helper for the fake host commands used by the test suite.
#
# Every shim records its full argv so tests can assert on the exact command
# line the engine produced -- that is what catches a layout applied with the
# wrong position format, mode or scale. Multi-line arguments (a batch of
# hl.monitor{} specs handed to `hyprctl eval`) collapse onto one line joined by
# " | ", so one recorded call stays one grep-able line.
oc_record() {
    local line="$*"
    printf '%s\n' "${line//$'\n'/ | }" >>"${OC_CALLLOG:-/dev/null}"
}
