# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# This host, as tools/capture-compare.sh runs it: every shell collector, in
# help / bad-argument / --stdout / deadline mode, plus the stdin and dash
# shapes for apm and sh for collection-server. Live host state differs
# between runs; see capture-compare.sh for how to read noise.
DESC="this host, every shell collector (capture-compare.sh behaviour)"
COLLECTORS="$(cd "$REPO/collectors" && ls */collect-*.sh */*/collect-*.sh 2>/dev/null | tr '\n' ' ')"
local_target
argsets() {
    printf '%s\n' "help|-|bash||" "badarg|-|bash||--no-such-arg" "stdout|-|bash||--stdout" \
        "dl|-|bash|RUN_DEADLINE=2 CMD_TIMEOUT=1|--stdout"
    case "$1" in
        apm/*) printf '%s\n' "dash|-|dash||--stdout" "dashs|-|dash -s||--stdout" "bashs|-|bash -s||--stdout" ;;
        collection-server/*) printf '%s\n' "sh|-|sh||--stdout" ;;
    esac
}
