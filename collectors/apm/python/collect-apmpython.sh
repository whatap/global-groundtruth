#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM Python agent collector
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap Python-agent developer repeatedly
# asks a field engineer for, from the host or container where a Python
# application (and the whatap-python agent) runs. Derived from an exhaustive
# review of #ask-dev-apm support threads (2025-02 .. 2026-07) and the
# whatap-python package source (2.1.2).
#
# Recurring field questions this report answers with facts:
#   * Which Python interpreter runs the app, and which whatap-python version
#     is installed where (wheel/dist-info vs legacy egg)?
#   * Is the Go common module (process name: whatap_python) actually running,
#     and from which WHATAP_HOME?
#   * Does WHATAP_HOME map to the whatap.conf the operator thinks it does?
#     What does whatap.conf / container.conf actually contain?
#   * Do whatap-hook.log (Python side) and whatap-boot-YYYYMMDD.log (Go side)
#     both exist, and what do their recent lines say?
#   * Is the UDP channel (net_udp_port, default 6600) listening, and is there
#     a TCP session toward the collection server?
#   * Is OpenTelemetry auto-instrumentation present in the same process
#     (co-instrumentation), and which WHATAP_* variables reached the process?
#   * Kubernetes/operator artifacts: /whatap-agent volume,
#     WHATAP_PYTHON_AGENT_PATH (symlink vs regular file), container.conf.
#
# THE CONTRACT (../../../CONTRACT.md):
#   1. Facts only. No conclusion is stated on any emitted line.
#   2. Discover, never assume. Resolve symlinks, process args, env, config.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned. Seed v0 by the Global team; ownership transfers to
#      the APM/Python agent developers.
#
# DESIGN GUIDELINES (../../../docs/collector-engineering.md): MECE sections,
# Tier-0 load-safe defaults (bounded reads, no whole-log grep), bash 3.2+,
# reasoned absence for every missing value.
#
# NOTE: no `set -e` — a collector must reach its footer even when every probe
# fails. Failures are handled locally by the helpers.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmpython"
# 0.7.0  The ten lookups per interpreter in section [3] run in one interpreter
#        start (_pyrun) instead of ten `python -c`, each still with its own
#        stdout, stderr and exit status, so every fact and n/a reason reads as
#        before. _env_pick and PYTHONPATH work in the shell, an interpreter
#        path already listed is not resolved again, and the detail list reads
#        each environ once. 12.9 s -> 7.5 s with 8 interpreters, 20.3 s ->
#        9.9 s with 300 more python processes (2026-09-25).
# 0.7.1  A lookup that hangs no longer takes the answers of the ones after it:
#        those never started, and each now runs alone under its own cap (the
#        one that hung says timed out, as before 0.7.0). The marker lines are
#        random per run and taken only in the order the driver prints them,
#        so a path or value holding marker-like text cannot replace another
#        lookup's answer (2026-09-25).
VERSION="0.7.1"
DOMAIN="apm"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Collects Python APM agent facts from the host or container where the Python
application runs (run it inside the container for containerized apps, e.g.
kubectl exec / docker exec).

Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet .. silence progress on stderr (add to --file / --stdout)
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers — DO NOT EDIT ---------------------------------------------
_section_n=0

emit_header() {
    printf '==== WhaTap Global Groundtruth Collection ====\n'
    printf 'Collector:      %s\n' "$COLLECTOR_NAME"
    printf 'Version:        %s\n' "$VERSION"
    printf 'Timestamp(UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf 'Domain:         %s\n' "$DOMAIN"
    printf 'Target:         %s\n' "$TARGET"
    printf '===============================================\n'
}

section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}

fact() {
    printf '    %s\n' "$1"
}

emit_footer() {
    printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'
}

# ---- privilege — DO NOT EDIT ------------------------------------------------
# What a collection can read is decided by the privilege it was given. That is a
# fact about this run, not a claim about the environment, so it stays inside
# CONTRACT rule 1 and belongs in the environment section ([1]) with the rest of the run's own facts.
#
# Two places, one sentence. The environment section says which privilege this run had. Every
# goal that privilege blocked repeats it on its own line, because the roll-up is
# what reaches the operator's terminal while they are still logged in, and "this
# is what was missing, this is what would have obtained it" is one thought.
#
# Real case: three collection-server bundles came back carrying no conf/ at all,
# and nothing in the report or the status said the uid could not reach it
# (Smartfren, 2026-09-23).
#
# A collector that elevates itself fills these in first, and _note_privilege
# then leaves them alone. What it fills in has to come from whatever refused it
# rather than from a guess: an account sudo does not permit and a run with no
# terminal to be asked on fail the same way, and they are answered by different
# people (collect-collmysql.sh 0.6.2).
PRIV_WHY="unknown"
PRIV_GAP=""   # what a further privilege would obtain; empty when the run is root

# _priv_hint -> " (not elevated: REASON)", or nothing when the run is root.
# Append it to the reason of any goal that a privilege blocked.
_priv_hint() { [ -n "$PRIV_GAP" ] && printf ' (not elevated: %s)' "$PRIV_GAP"; return 0; }

# _note_privilege -> describe this process. Call it once, before the environment section reads
# PRIV_WHY. It yields to a value already set, so a self-elevating collector can
# say something more exact.
_note_privilege() {
    [ "$PRIV_WHY" = unknown ] || return 0
    # No uid is not uid 0. A run that cannot tell says so, and claims no root.
    _priv_uid="$(id -u 2>/dev/null)"
    [ -n "$_priv_uid" ] || _priv_uid="$(awk '/^Uid:/{print $2; exit}' /proc/self/status 2>/dev/null)"
    if [ -z "$_priv_uid" ]; then
        PRIV_WHY="n/a (id -u failed and /proc/self/status is not readable)"
        PRIV_GAP=""
    elif [ "$_priv_uid" = 0 ]; then
        PRIV_WHY="root${SUDO_UID:+ (elevated by sudo from uid $SUDO_UID)}"
        PRIV_GAP=""
    else
        PRIV_WHY="not root (uid $_priv_uid)"
        PRIV_GAP="run again with sudo"
    fi
}
# ---- end privilege

# ---- boot time — DO NOT EDIT ------------------------------------------------
# Most of what a collector reports is cumulative since boot: /proc/diskstats,
# ZFS kstat trees, zpool iostat histograms, MySQL GLOBAL STATUS. Without the boot
# time those are sums with no denominator and cannot be read as a rate, so the
# reader either asks the site for it afterwards or reconstructs it. Both are work
# the collector could have done, and it belongs in the environment section ([1]) with the rest of the
# facts about this run.
#
# Two real cases, both 2026-09-23 Smartfren. A MySQL bundle whose section D kernel
# counters had no start time, so `uptime -s` had to be asked for by hand and a
# runbook carried a step to write that one line down. And a ZFS bundle whose
# 869-day uptime had to be rebuilt from kstat snaptime, a pool_create event and
# dmesg monotonic time before `try_hard` 29,727,745 could be stated as 34,209/day.
#
# It reads /proc rather than running `uptime` on purpose. It arrives on a host
# without procps, and it still arrives on a run whose main collection failed early
# (a refused login, an absent zpool), which is exactly the run whose counters most
# need a denominator.
#
# _note_boot -> emit the two facts. Call it from the environment section, after the privilege
# line. It prints rather than returning, because both values are always wanted
# together and neither is read back by the collector.
_note_boot() {
    _boot_btime="$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)"
    if [ -n "$_boot_btime" ]; then
        fact "host boot(UTC): $(date -u -d "@$_boot_btime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || echo "n/a (epoch $_boot_btime, date -d unavailable)")"
    else
        fact "host boot(UTC): n/a (no btime in /proc/stat)"
    fi
    fact "host uptime(s): $(cut -d. -f1 /proc/uptime 2>/dev/null || echo 'n/a (/proc/uptime not readable)')"
}
# ---- end boot time

# ---- run helpers — DO NOT EDIT ----------------------------------------------
# Four things every collector needs and none may get wrong on its own.
#
# warn. What the operator must see whatever --quiet says: a Tier 2 impact before
# it runs, a hard error, a skipped step. It goes to fd 3, the terminal saved in
# main, because --file mode discards the report body's stderr. Every collector
# once wrote warn to plain stderr, and in --file mode the "[Tier2] ... pauses
# the target JVM" line never reached the terminal while jstack still ran
# (apmjava 0.10.1, found 2026-09-25).
#
# _bounded CMD... Every external command runs under a cap. timeout(1) when the
# host has it and CMD is a file; otherwise a shell watchdog, which also covers
# shell functions and hosts without coreutils. Returns 124 on a cap, whatever
# the local timeout(1) returns for a kill (busybox gives 143). timeout(1) gets
# -k 5 where it takes it: without it a command that ignores SIGTERM ran on
# past its cap (`timeout 1 bash -c 'trap "" TERM; sleep 4'` took 4s; found
# 2026-09-25).
#
# RUN_DEADLINE. The whole run is bounded too. Past it, _bounded runs nothing and
# returns 124, so a host where every command hangs still yields a report that
# reaches its footer, and emit_status says the deadline was reached.
#
# _tmp NAME. One private directory per run, removed on exit and on INT, TERM
# and HUP. A Ctrl-C used to leave config copies and thread dumps in /tmp, and a
# $$-named path in a shared /tmp is one a root run follows through a planted
# symlink.
#
# _report_to_file FILE. --file mode's write, which says so and fails when the
# file cannot be written instead of printing "report written".
#
# POSIX sh only in the synced blocks, because the apm collectors are piped into
# `sh -s` inside containers, where sh is often dash or busybox: no SECONDS, no
# `type -t`, no ${v//x/y}. The first draft of this block used all three.
RUN_DEADLINE="${RUN_DEADLINE:-300}"
_tmp_dir=""
_run_t0=""
_timeout_k=""     # 5 when timeout(1) takes -k (_run_init)
_stdin_script=0   # 1 when the shell reads this script from stdin (sh -s)
_nl='
'
_tab="$(printf '\t')"

# Falls back to stderr when fd 3 is not open yet (an error before main).
warn() { { printf '!! %s\n' "$*" >&3; } 2>/dev/null || printf '!! %s\n' "$*" >&2; }

# _elapsed -> seconds since _run_init; 0 when no clock is available, which
# disables the deadline rather than tripping it at once
_elapsed() {
    if [ -n "${BASH_VERSION:-}" ]; then printf '%s' "${SECONDS:-0}"
    elif [ -n "$_run_t0" ]; then printf '%s' "$(( $(date +%s 2>/dev/null || echo "$_run_t0") - _run_t0 ))"
    else printf '0'; fi
}
_past_deadline() { [ "$(_elapsed)" -ge "$RUN_DEADLINE" ]; }

# _cmd_kind CMD -> "file", "shell" (function or builtin) or "" (not found)
_cmd_kind() {
    case "$(command -v "$1" 2>/dev/null)" in
        '') printf '' ;;
        /*) printf 'file' ;;
        *)  printf 'shell' ;;
    esac
}

_run_cleanup() {
    case "$_tmp_dir" in */ggt.*) rm -rf "$_tmp_dir" 2>/dev/null ;; esac
    _tmp_dir=""
}

# _cap_or NAME VALUE DEFAULT -> VALUE when it is 1..999999, else DEFAULT, and a
# warn naming what was ignored. A leading zero is refused too: $((030)) is 24.
_cap_or() {
    case "$2" in
        ''|*[!0-9]*|0*) ;;
        *) [ "${#2}" -le 6 ] && { printf '%s' "$2"; return 0; } ;;
    esac
    warn "$1=$2 ignored (not a whole number 1..999999 without leading zeros), using $3"
    printf '%s' "$3"
}

# _run_init -> the private temp directory, the traps, and timeout(1). Call it
# once in main, before anything creates a temp file.
_run_init() {
    _run_t0="$(date +%s 2>/dev/null)"
    case "$_run_t0" in ''|*[!0-9]*) _run_t0="" ;; esac
    # No predictable fallback name: without mktemp the run has no directory,
    # and _tmp answers /dev/null.
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ggt.XXXXXX" 2>/dev/null)"
    # Is this script read from stdin (`sh -s`, `kubectl exec ... sh -s`)? Then
    # fd 0 is the script itself: a bounded command must not read it, and bash
    # 5.2 kills a $(...) subshell that so much as duplicates fd 0 while it
    # reads its script from there (`true 4<&0` is enough; found 2026-09-25).
    case "$0" in
        */*|*.sh) [ -f "$0" ] || _stdin_script=1 ;;
        *)        _stdin_script=1 ;;
    esac
    [ -n "$_tmp_dir" ] || warn "no private temp directory could be made under ${TMPDIR:-/tmp}; values that need one are reported as n/a"
    # Caps from the environment are numbers or they are not used. `abc` made
    # every [ -lt ] fail and 0 means "no limit" to timeout(1) (found 2026-09-25).
    RUN_DEADLINE="$(_cap_or RUN_DEADLINE "$RUN_DEADLINE" 300)"
    CMD_TIMEOUT="$(_cap_or CMD_TIMEOUT "${CMD_TIMEOUT:-20}" 20)"
    trap '_run_cleanup' EXIT
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
    [ -n "${_timeout_bin:-}" ] || _timeout_bin="$(command -v timeout 2>/dev/null)"
    if [ -n "${_timeout_bin:-}" ] && "$_timeout_bin" -k 1 5 true </dev/null >/dev/null 2>&1; then
        _timeout_k=5
    fi
}

# _tmp NAME -> a path inside this run's directory. /dev/null when no directory
# could be made, so a write is lost rather than landing somewhere shared.
_tmp() { if [ -n "$_tmp_dir" ]; then printf '%s/%s' "$_tmp_dir" "$1"; else printf '/dev/null'; fi; }

# _kill_tree SIG PID -> signal PID and every descendant. dash starts a background
# job in the caller's process group even under set -m, so a group kill misses
# the grandchildren; /proc/<pid>/status names each process's parent.
_kill_tree() {
    local sig="$1" all="$2" list="$2" next c
    while [ -n "$list" ]; do
        next=""
        for c in $list; do
            next="$next $(grep -l "^PPid:[[:space:]]*$c\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3)"
        done
        list="$(echo $next)"
        all="$all $list"
    done
    # shellcheck disable=SC2086
    kill -"$sig" $all 2>/dev/null
}

# _bounded CMD... -> CMD under the caps. Its stdin is the caller's when this
# script was run from a file, and /dev/null when the script itself is on stdin.
# _bounded_in FILE CMD... -> the same, with FILE as CMD's stdin. Use it, not a
# `< FILE` on the call, for any bounded command that needs input.
_bounded() { _bounded_in "" "$@"; }

_bounded_in() {
    local in="$1" t="${CMD_TIMEOUT:-20}" left start rc p w
    shift
    start="$(_elapsed)"
    left=$((RUN_DEADLINE - start))
    [ "$left" -le 0 ] && return 124
    [ "$left" -lt "$t" ] && t="$left"
    if [ -n "${_timeout_bin:-}" ] && [ "$(_cmd_kind "$1")" = file ]; then
        if [ -n "$in" ];                   then "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@" < "$in"
        elif [ "$_stdin_script" = 1 ];     then "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@" < /dev/null
        else                                    "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@"; fi
        rc=$?
    else
        # The kill has to reach whatever CMD started: an orphaned grandchild
        # holds a $(...) pipe open and the caller waits for it anyway. bash
        # under set -m gives the job its own group; _kill_tree covers dash.
        # stdin through fd 4 when it is passed on: POSIX gives an async list
        # /dev/null as stdin before its own redirections, so a plain 0<&0
        # hands dash /dev/null.
        set -m 2>/dev/null
        if [ -n "$in" ];                   then "$@" < "$in" &
        elif [ "$_stdin_script" = 1 ];     then "$@" < /dev/null &
        else                                    { "$@" 0<&4 4<&- & } 4<&0; fi
        p=$!
        set +m 2>/dev/null
        ( i=0
          while [ "$i" -lt "$t" ]; do sleep 1; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        wait "$p"; rc=$?
        kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    fi
    case "$rc" in 124|137|143) [ $(( $(_elapsed) - start )) -ge "$t" ] && rc=124 ;; esac
    return "$rc"
}

_report_to_file() {
    # `true`, not `:`. A failed redirect on a special builtin exits dash.
    if ! { true > "$1"; } 2>/dev/null; then
        warn "the report was not written: $1 cannot be created by uid $(id -u 2>/dev/null || echo '?')"
        return 1
    fi
    run_report > "$1" 2>/dev/null
    if ! tail -n 1 "$1" 2>/dev/null | grep -q '^==== END OF COLLECTION'; then
        warn "the report was not written whole: $1 does not end with the footer"
        return 1
    fi
}
# ---- end run helpers

# ---- collection completeness — DO NOT EDIT ----------------------------------
# A collector knows, at the host, whether it obtained what it came for. Saying so
# is a fact about THIS COLLECTION RUN, not a claim about the environment, so it
# stays inside CONTRACT rule 1. (Rule 1 is spelled out for this case in
# CONTRACT.md, "Saying whether the collection worked".)
#
# Why it exists. A report full of `n/a (permission denied)` reads as finished to
# an operator whose terminal only said ">> done.". They package it and send it,
# and the gap surfaces days later in another time zone. Real case: two of three
# collection-server bundles came back carrying no conf/ at all, and nobody knew
# until the files had crossed a time zone (Smartfren, 2026-09-23). Every fact
# needed to catch that was already on the host while the operator was still
# logged in.
#
# It also serves rule 3 ("one field command → paste output"): deciding whether a
# run is worth sending is interpretation, and the field is not asked to do it.
#
# The status answers ONE question for the operator: send this, or change
# something and run again? So there are three outcomes, not two.
#
#     goal   conf "module configs"                     # what this run is for
#     got    conf                                      # obtained
#     na     conf "this host runs no yard"             # legitimately absent
#     missed conf "uid 3103 cannot reach /data/whatap"  # this run was blocked
#
# `na` and `missed` are both absences, and telling them apart is the whole point.
# An absence is `na` when it IS the answer and no re-run would change it: no ZFS
# on a host that does not use ZFS, no DBX component on a database host, no binary
# logs when log_bin is off. An absence is `missed` when this run was blocked and
# running it differently would get the value: a permission, a missing tool, a
# timeout, an unreadable path.
#
# Only `missed` makes a run INCOMPLETE. Marking a normal environment INCOMPLETE
# would teach the field to ignore the line, and then it protects nothing.
#
# `na` needs every input behind the absence to have been read. One unreadable
# path, one refused call, one timeout, and it is `missed` (output-format.md,
# "Three outcomes"). A non-root run that sees no agent process because it cannot
# read other users' /proc/<pid>/environ has not seen that there is no agent.
#
# Declare a goal once, then resolve it exactly once, after the last fallback. A
# goal left unresolved counts as missed with reason "not reached": the run ended
# before that step. A goal resolved twice with different outcomes counts as
# blocked and says so, because the second call usually hides the first (missed
# then na turned a refused read into COMPLETE). A resolution for a goal never
# declared is listed. A requested opt-in is a goal; an unrequested one is not.
#
# Storage is one line per record, KEY<TAB>VALUE, so a reason cannot shift the
# others: tabs and newlines inside a reason are flattened on the way in.
_goals='' _res=''

_flat() { printf '%s' "$1" | tr '\n\t' '  '; }

goal() {
    case "$_nl$_goals" in *"$_nl$1$_tab"*) return 0 ;; esac
    _goals="$_goals$1$_tab$(_flat "$2")$_nl"
}
got()    { _res="$_res$1${_tab}got$_tab$_nl"; }
na()     { _res="$_res$1${_tab}na$_tab$(_flat "$2")$_nl"; }
missed() { _res="$_res$1${_tab}missed$_tab$(_flat "$2")$_nl"; }

# notice: like progress, but NOT silenced by --quiet. Reserved for the
# completeness roll-up. --quiet exists to keep run narration out of automation
# logs; the one line that decides whether a run is worth sending is not
# narration, and an automated caller wants it most of all.
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null; }

# emit_status -> the roll-up section. Call it immediately before emit_footer.
# Also repeats each gap on fd 3 so the operator sees it while still logged in.
emit_status() {
    [ -n "$_goals" ] || return 0
    local k lab outs total=0 obtained=0 nacount=0 blocked=0 gaps='' nas='' oks='' stray deadline=''
    while IFS="$_tab" read -r k lab; do
        [ -n "$k" ] || continue
        total=$((total + 1))
        # every outcome recorded for this key, in order, and the distinct set
        outs="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { printf "%s%s", (n++ ? ", " : ""), $2 }')"
        case "$outs" in
            got|got,\ got*)
                case "$outs" in *na*|*missed*) ;; *)
                    obtained=$((obtained + 1)); oks="$oks $lab,"; continue ;; esac ;;
        esac
        case "$outs" in
            na|na,\ na*)
                case "$outs" in *got*|*missed*) ;; *)
                    nacount=$((nacount + 1))
                    nas="$nas$lab — $(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { print $3; exit }')$_nl"
                    continue ;; esac ;;
        esac
        blocked=$((blocked + 1))
        local why
        why="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k && $2 == "missed" { printf "%s%s", (n++ ? "; " : ""), $3 }')"
        case "$outs" in
            '')           why='not reached' ;;
            missed|missed,\ missed*)
                case "$outs" in *got*|*na*) why="resolved $(printf '%s' "$outs" | awk -F', ' '{print NF}') times: $outs${why:+ — $why}" ;; esac ;;
            *)            why="resolved $(printf '%s' "$outs" | awk -F', ' '{print NF}') times: $outs${why:+ — $why}" ;;
        esac
        gaps="$gaps$lab — $why$_nl"
    done <<EOF
$_goals
EOF
    stray="$(printf '%s' "$_res" | _G="$_goals" awk -F'\t' '
        BEGIN { n = split(ENVIRON["_G"], L, "\n"); for (i = 1; i <= n; i++) { split(L[i], f, "\t"); if (f[1] != "") d[f[1]] = 1 } }
        $1 != "" && !($1 in d) && !($1 in seen) { seen[$1] = 1; printf "%s%s", (c++ ? ", " : ""), $1 }')"
    _past_deadline && deadline="reached at ${RUN_DEADLINE}s; commands after it were not run"
    section "Collection status"
    fact "goals: $total declared, $obtained obtained, $nacount not applicable here, $blocked blocked"
    [ -n "$oks" ] && fact "obtained:${oks%,}"
    if [ -n "$nas" ]; then
        fact "not applicable to this host (this is an answer, not a gap):"
        printf '%s' "$nas" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
    fi
    [ -n "$stray" ] && fact "resolved but never declared: $stray"
    [ -n "$deadline" ] && fact "run deadline: $deadline"
    if [ "$blocked" -eq 0 ] && [ -z "$deadline" ]; then
        fact "status: COMPLETE"
        notice "status: COMPLETE — nothing was blocked${nas:+ ($nacount not applicable to this host)}"
    else
        if [ -n "$gaps" ]; then
            fact "blocked (running this differently would obtain these):"
            printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
        fi
        fact "status: INCOMPLETE"
        notice "status: INCOMPLETE — $blocked of $total goals blocked${deadline:+, run deadline reached}"
        printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && notice "  $l"; done
    fi
}
# ---- end collection completeness

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- reasoned-absence helpers -------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
CMD_TIMEOUT="${CMD_TIMEOUT:-15}"
# Call after _run_init: the error file lives in the run's private directory.
_init_probe() { _errfile="$(_tmp probe.err)"; }
_end_probe() { :; }   # _run_cleanup removes the directory

_classify_err() {
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *[Pp]"ermission denied"*|*"peration not permitted"*) echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*)   echo "path not found";    return ;;
    esac
    if [ -n "$txt" ]; then printf 'error: %s' "$(printf '%s' "$txt" | head -n1 | cut -c1-100)"
    else echo "nonzero exit"; fi
}

_emit_labeled() {
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then
        fact "$label: $body"
    else
        fact "$label:"
        printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
    fi
}

# probe "label" CMD [ARGS...] -> output as facts, or "label: n/a (<why>)".
# CMD may be a file, a shell function or a builtin; _bounded caps all three. A
# non-zero exit that still printed something is reported with its output.
probe() {
    local label="$1"; shift
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    _past_deadline && { fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"; return; }
    local out rc
    out="$(_bounded "$@" 2>"$_errfile")"; rc=$?
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    if [ "$rc" -ne 0 ]; then
        [ -n "$out" ] && { _emit_labeled "$label (exit $rc)" "$out"; return; }
        fact "$label: n/a ($(_classify_err))"; return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# _head_of N CMD... -> the first N lines of CMD's stdout, with CMD's own exit
# status (a `CMD | head` pipeline reports head's, and hides a failed CMD as
# empty output).
_head_of() {
    local n="$1" rc; shift
    "$@" > "$(_tmp head.out)"; rc=$?
    head -n "$n" "$(_tmp head.out)" 2>/dev/null
    return "$rc"
}

# _ls_head DIR N -> `ls -la DIR`, first N lines, failing when ls fails. Takes the
# path as an argument, so a quote or a space in it cannot break a `sh -c` string.
_ls_head() { _head_of "$2" ls -la -- "$1"; }

# read_proc "label" PATH -> content of a /proc or /sys file, or a reason.
read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# dump_file "label" PATH [CAP] -> the file's content verbatim (line-capped),
# or a classified reason. Framework policy: configuration is dumped verbatim,
# never masked (see collectors/apm/python/README.md, "What the report can contain").
dump_file() {
    local label="$1" path="$2" cap="${3:-400}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (first $cap of ${total:-?} lines):"
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# tail_file "label" PATH [CAP] -> the file's LAST lines (bounded read).
tail_file() {
    local label="$1" path="$2" cap="${3:-200}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (last $cap of ${total:-?} lines):"
    tail -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# head_file "label" PATH [CAP] -> the file's FIRST lines (bounded read).
head_file() {
    local label="$1" path="$2" cap="${3:-120}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (first $cap of ${total:-?} lines):"
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# pyprobe "label" PY_EXE CODE -> run a short python -c snippet under _bounded.
# Never imports the `whatap` package itself (importing it has side effects);
# only importlib/pkg metadata lookups are used. Leaves the output in _pyout and
# the exit status in _pyrc, so a caller can resolve a goal from it.
_pyout="" _pyrc=0
pyprobe() {
    local label="$1" py="$2" code="$3" out rc
    _pyout="" _pyrc=1
    [ -x "$py" ] || { fact "$label: n/a (not executable: $py)"; return; }
    _past_deadline && { _pyrc=124; fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"; return; }
    out="$(_bounded "$py" -c "$code" 2>"$_errfile")"; rc=$?
    _pyout="$out" _pyrc="$rc"
    [ "$rc" -eq 124 ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    if [ "$rc" -ne 0 ]; then
        local err
        err="$(grep -E 'Error|Exception' "$_errfile" 2>/dev/null | tail -n1 | cut -c1-140)"
        [ -z "$err" ] && err="$(_classify_err)"
        fact "$label: n/a ($err)"
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# _pyrun PY CODE... -> run every CODE in ONE interpreter start instead of one
# `PY -c CODE` each (ten starts per interpreter took 8.9 s of a 12 s run on a
# host with 8 interpreters). _PYDRV runs each CODE on its own: fresh globals,
# its stdout and stderr captured apart, an uncaught exception printed by
# sys.excepthook exactly as `python -c` prints it, and its exit status. It
# prints, per CODE, "<marker> N start" before running it, then "<marker> N
# out", the stdout, "<marker> N err", the stderr and "<marker> N rc R",
# flushing after each, so a CODE that finished before a timeout keeps its
# result. Python 2.4+ and 3 syntax: no `with`, no `except X as e`. The CODE
# importing pkg_resources (it rewires namespace packages on import) runs
# last; the report order stays as listed.
# _pyreport N LABEL CODE then reports CODE N as pyprobe would have.
#
# The marker is random per run and a marker line counts only when it is the
# one expected next (same CODE, same order as the driver runs them): a CODE
# that prints a path holding a newline and marker-like text cannot replace
# another CODE's answer.
#
# Limits for whoever adds a CODE (each differs from a `python -c` of its own):
#   * output of an atexit hook or of the interpreter's start-up (sitecustomize)
#     is printed once and is added to EVERY CODE's stdout, as each `python -c`
#     would have printed it;
#   * os.write(1, ...) / os.write(2, ...) and child processes bypass the
#     capture: that output is dropped, not attributed to the CODE;
#   * sys.stdout / sys.stderr are StringIO objects while a CODE runs: no
#     .buffer, no .fileno(), no binary writes;
#   * sys.argv is the driver's (the marker and every CODE), not ['-c'];
#   * a CODE that ends the process (os._exit, a crash) or hangs stops the
#     CODEs after it: _pyreport then runs those alone with pyprobe.
_pym_rand=""
{ read -r _pym_rand < /proc/sys/kernel/random/uuid; } 2>/dev/null
[ -n "$_pym_rand" ] || _pym_rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$_pym_rand" ] || _pym_rand="$$.$(date +%s 2>/dev/null)"
_PYM="@@ggt-pyprobe-$_pym_rand@@"
_PYDRV='
import sys
try:
    from StringIO import StringIO
except ImportError:
    from io import StringIO
m = sys.argv[1]
codes = sys.argv[2:]
order = [i for i in range(len(codes)) if "pkg_resources" not in codes[i]] + [i for i in range(len(codes)) if "pkg_resources" in codes[i]]
out = sys.stdout
err = sys.stderr
for i in order:
    out.write("%s %d start\n" % (m, i + 1))
    out.flush()
    o = StringIO()
    e = StringIO()
    rc = 0
    sys.stdout = o
    sys.stderr = e
    try:
        try:
            exec(compile(codes[i], "<string>", "exec"), {"__name__": "__main__"})
        except SystemExit:
            c = sys.exc_info()[1].code
            if c is None:
                rc = 0
            elif isinstance(c, int):
                rc = c & 255
            else:
                e.write(str(c) + "\n")
                rc = 1
        except:
            t, v, tb = sys.exc_info()
            sys.excepthook(t, v, tb)
            rc = 1
    finally:
        sys.stdout = out
        sys.stderr = err
    ob = o.getvalue()
    eb = e.getvalue()
    out.write("%s %d out\n" % (m, i + 1))
    try:
        out.write(ob)
    except:
        x = StringIO()
        sys.stderr = x
        sys.excepthook(*sys.exc_info())
        sys.stderr = err
        eb = eb + x.getvalue()
        ob = ""
        rc = 1
    if not ob.endswith("\n"):
        out.write("\n")
    out.write("%s %d err\n" % (m, i + 1))
    try:
        out.write(eb)
    except:
        eb = repr(eb)
        out.write(eb)
    if not eb.endswith("\n"):
        out.write("\n")
    out.write("%s %d rc %d\n" % (m, i + 1, rc))
    out.flush()
'
_pyrun_py="" _pyrun_rc=0 _pyrun_pre="" _pyrun_post="" _pyrun_err="" _pyrun_started=0
_pyrun() {
    local l n c ord="" cur="" step="" acc="" seen=0 i=1
    _pyrun_py="$1"; shift
    _pyrun_rc=0 _pyrun_pre="" _pyrun_post="" _pyrun_err="" _pyrun_started=0
    while [ "$i" -le "$#" ]; do eval "_pyr_$i='' _pyo_$i='' _pye_$i='' _pys_$i=''"; i=$((i + 1)); done
    [ -x "$_pyrun_py" ] || { _pyrun_rc=noexec; return; }
    _past_deadline && { _pyrun_rc=deadline; return; }
    # the order the driver runs them in: pkg_resources last
    i=0; for c in "$@"; do i=$((i + 1)); case "$c" in *pkg_resources*) ;; *) ord="$ord $i" ;; esac; done
    i=0; for c in "$@"; do i=$((i + 1)); case "$c" in *pkg_resources*) ord="$ord $i" ;; esac; done
    _pyrun_out="$(_bounded "$_pyrun_py" -c "$_PYDRV" "$_PYM" "$@" 2>"$(_tmp pyrun.err)")"; _pyrun_rc=$?
    [ -s "$(_tmp pyrun.err)" ] && _pyrun_err="$(cat "$(_tmp pyrun.err)" 2>/dev/null)"
    # Split on the marker lines, accepting only the one expected next: after
    # "N rc R" comes "M start" for the next CODE M in $ord, then "M out",
    # "M err", "M rc R". Any other line is content. What the interpreter
    # printed outside the markers (a sitecustomize at start-up, an atexit
    # hook) is what every `python -c` would have printed around its own
    # output, so each CODE gets it too.
    set -- $ord
    cur="${1:-}"; step=start
    while IFS= read -r l; do
        case "$step:$l" in
            "start:$_PYM $cur start")
                [ "$seen" = 0 ] && _pyrun_pre="$acc"; seen=1
                eval "_pys_$cur=1"; _pyrun_started=1; step=out; acc=""; continue ;;
            "out:$_PYM $cur out")   step=err; acc=""; continue ;;
            "err:$_PYM $cur err")   eval "_pyo_$cur=\$acc"; step=rc; acc=""; continue ;;
            "rc:$_PYM $cur rc "*)
                n="${l#"$_PYM $cur rc "}"
                case "$n" in
                    ''|*[!0-9]*) ;;
                    *) eval "_pye_$cur=\$acc _pyr_$cur=\$n"
                       shift; cur="${1:-}"; step=start; [ -n "$cur" ] || step=end
                       acc=""; continue ;;
                esac ;;
        esac
        # content: dropped between "start" and "out" (nothing a CODE prints
        # through sys.stdout arrives there)
        [ "$step" = out ] || acc="$acc$l$_nl"
    done <<EOF
$_pyrun_out
EOF
    if [ "$seen" = 1 ]; then [ "$step" = end ] && _pyrun_post="$acc"; else _pyrun_pre="$acc"; fi
}

# _pyreport N LABEL CODE -> the facts pyprobe gives for CODE, from the result of
# CODE N in the last _pyrun. A CODE with no status of its own:
#   * it started and the cap stopped it: timed out (it was running);
#   * the cap stopped the interpreter before any CODE started: timed out,
#     as each `python -c` would have been;
#   * it never started because a CODE before it hung or ended the process,
#     or the interpreter cannot run the driver: run alone with pyprobe, under
#     its own cap, as before _pyrun. Past the run deadline it is not run, and
#     the reason says why.
_pyreport() {
    local n="$1" label="$2" out rc err started
    case "$_pyrun_rc" in
        noexec)   _pyout="" _pyrc=1; fact "$label: n/a (not executable: $_pyrun_py)"; return ;;
        deadline) _pyout="" _pyrc=124; fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"; return ;;
    esac
    eval "rc=\$_pyr_$n out=\$_pyo_$n err=\$_pye_$n started=\$_pys_$n"
    if [ -z "$rc" ]; then
        if [ "$_pyrun_rc" = 124 ] && { [ "$started" = 1 ] || [ "$_pyrun_started" = 0 ]; }; then
            _pyout="" _pyrc=124
            if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
            else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
            return
        fi
        if [ "$_pyrun_rc" = 124 ] && _past_deadline; then
            _pyout="" _pyrc=124
            fact "$label: n/a (not run: the lookup before it did not finish within ${CMD_TIMEOUT}s, and the run deadline was reached: ${RUN_DEADLINE}s)"
            return
        fi
        pyprobe "$label" "$_pyrun_py" "$3"; return
    fi
    # $(...) drops the trailing newlines
    out="$_pyrun_pre$out$_pyrun_post"
    while :; do case "$out" in *"$_nl") out="${out%"$_nl"}" ;; *) break ;; esac; done
    _pyout="$out" _pyrc="$rc"
    if [ "$rc" -ne 0 ]; then
        { [ -n "$_pyrun_err" ] && printf '%s\n' "$_pyrun_err"; printf '%s' "$err"; } > "$_errfile" 2>/dev/null
        local e
        e="$(grep -E 'Error|Exception' "$_errfile" 2>/dev/null | tail -n1 | cut -c1-140)"
        [ -z "$e" ] && e="$(_classify_err)"
        fact "$label: n/a ($e)"
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# ---- process table (internal; emits nothing) ----------------------------------
# _proc_table -> one line per process that has a command line, fields joined by
# the unit separator \037 (a whitespace IFS would merge empty fields):
#   pid comm exe argv0 cmdline
# Read in one pass over /proc: three readers for every pid instead of several
# forks per pid (readlink + basename per pid took 20 s on a 687-process host).
# exe is empty where /proc/<pid>/exe is not readable by this uid. cmdline has
# its NULs turned into spaces and is cut at 300 characters.
_us="$(printf '\037')"
_proc_table() {
    {
        ls -l /proc/[0-9]*/exe 2>/dev/null | awk '{
            i = index($0, " -> "); if (!i) next
            for (f = 1; f <= NF; f++) if ($f ~ /^\/proc\/[0-9]+\/exe$/) {
                split($f, a, "/"); t = substr($0, i + 4); sub(/ \(deleted\)$/, "", t)
                print "E\037" a[3] "\037" t; break } }'
        head -n 1 /proc/[0-9]*/comm /dev/null 2>/dev/null | awk '
            /^==> \/proc\/[0-9]+\/comm <==$/ { split($2, a, "/"); p = a[3]; next }
            p != "" { print "C\037" p "\037" $0; p = "" }'
        head -n 1 /proc/[0-9]*/cmdline /dev/null 2>/dev/null | tr '\000\037' '\001 ' | awk '
            /^==> \/proc\/[0-9]+\/cmdline <==$/ { split($2, a, "/"); p = a[3]; next }
            p != "" { split($0, v, "\001"); c = $0; gsub(/\001/, " ", c); sub(/ +$/, "", c)
                      if (v[1] != "") print "A\037" p "\037" v[1] "\037" substr(c, 1, 300)
                      p = "" }'
    } | awk -F'\037' '
        $1 == "E" { e[$2] = $3; next }
        $1 == "C" { c[$2] = $3; next }
        $1 == "A" { o[++n] = $2; a0[$2] = $3; cl[$2] = $4 }
        END { for (i = 1; i <= n; i++) { p = o[i]; print p "\037" c[p] "\037" e[p] "\037" a0[p] "\037" cl[p] } }'
}

# ---- discovery (internal; emits nothing) --------------------------------------
# Populates:
#   D_PY_EXES   distinct python interpreter paths, newline-joined; those of
#               whatap-marked processes first (PATH + running processes)
#   D_GO_PIDS   pids of the Go common module (comm: whatap_python)
#   D_APP_PIDS  pids of python processes, whatap-marked first
#   D_HOMES     distinct WHATAP_HOME candidates with their discovery source
#   D_UNREAD    pids of candidate processes whose environ or cwd this uid could
#               not read (their WHATAP_HOME is unknown, not absent)
#   D_HIDEPID   non-empty when /proc hides other users' processes from this uid
D_PY_EXES=""
D_GO_PIDS=""
D_APP_PIDS=""
D_ODOO_PIDS=""      # odoo processes (setproctitle may rename comm to odoo*)
D_HOMES=""          # newline-joined "path|source" records
D_PKG_DIRS=""       # newline-joined whatap package dirs seen in process environ
D_UNREAD=""
D_HIDEPID=""
D_PY_LIVE=""        # interpreter paths of running processes, newline-joined
# Interpreters detailed and probed per run (set in discover). APM_INTERP_CAP
# in the environment raises it (the CLI flags are a shared block).
D_PY_CAP=8 D_CAP_NOTE=""
D_LOCK_FILE="${WHATAP_LOCK_FILE:-/tmp/whatap-python.lock}"
D_LLM_LOCK_FILE="/tmp/whatap-python-llm.lock"

# resolve_fs PATH -> prints a readable filesystem view of PATH: the path itself
# if it exists here, otherwise the same path seen through the root of a
# discovered agent/app process (/proc/<pid>/root<PATH>). Empty if neither is
# visible. This lets the collector run from a kubectl-debug ephemeral container
# (or any different mount namespace) and still read the target's files.
resolve_fs() {
    local p="$1" pid
    # a relative path is never read against the collector's own cwd
    case "$p" in /*) ;; *) return 1 ;; esac
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    for pid in $D_GO_PIDS $D_APP_PIDS $D_ODOO_PIDS; do
        [ -e "/proc/$pid/root$p" ] && { printf '%s\n' "/proc/$pid/root$p"; return; }
    done
    return 1
}

# _absent_why PATH [SOURCE] -> why resolve_fs found nothing: "permission denied:
# <dir>" when an existing ancestor cannot be searched by this uid, or when the
# process named in SOURCE ("... pid N") has a root this uid cannot enter;
# otherwise "path not found: PATH".
_absent_why() {
    local p="$1" s="${2:-}" d pid i=0
    # a relative path has no ancestor to walk; the ${d%/*} walk below only
    # shrinks an absolute one (and is capped anyway)
    case "$p" in /*) ;; *) printf 'relative path, not resolved: %s' "$p"; return ;; esac
    d="${p%/*}"
    while [ -n "$d" ] && [ ! -e "$d" ] && [ "$i" -lt 256 ]; do d="${d%/*}"; i=$((i + 1)); done
    if [ -n "$d" ] && [ ! -e "$d" ]; then printf 'not resolved (path depth over 256): %s' "$p"; return; fi
    if [ -n "$d" ] && [ -e "$d" ] && [ ! -x "$d" ]; then printf 'permission denied: %s' "$d"; return; fi
    case "$s" in
        *" pid "*)
            pid="${s##* pid }"; pid="${pid%% *}"
            if [ -d "/proc/$pid" ] && [ ! -e "/proc/$pid/root/" ]; then
                printf 'permission denied: /proc/%s/root' "$pid"; return
            fi ;;
    esac
    printf 'path not found: %s' "$p"
}

# _abs_for_pid PID PATH -> PATH, made absolute against the cwd of PID when it
# is relative (a relative WHATAP_HOME in a process environ is relative to that
# process). Fails when PATH is relative and that cwd cannot be read: the path
# is then never tested against the collector's own cwd.
_abs_for_pid() {
    local c
    case "$2" in
        /*) printf '%s' "$2" ;;
        *)  c="$(readlink -f "/proc/$1/cwd" 2>/dev/null)"
            [ -n "$c" ] || return 1
            printf '%s/%s' "$c" "${2#./}" ;;
    esac
}

# _home_from_pid PID PATH SOURCE -> add PATH (from the environ of PID) as a home
# candidate. A relative PATH whose process cwd cannot be read is an unread
# input while the process lives (D_UNREAD), and a fact once it has exited
# (D_GONE).
D_GONE=""
_home_from_pid() {
    local v
    if v="$(_abs_for_pid "$1" "$2")"; then _add_home "$v" "$3"
    elif [ -e "/proc/$1" ]; then D_UNREAD="$D_UNREAD $1"
    else D_GONE="${D_GONE}pid $1: $2$_nl"; fi
}

# _home_from_self VALUE NAME -> add a home candidate from the collector's own
# environment. It belongs to this process, so a relative VALUE is taken
# against the collector's physical cwd (the operator set it and ran the
# collector from there); values from other processes use their cwd instead.
_home_from_self() {
    local c
    case "$1" in
        /*) _add_home "$1" "env $2 (collector shell)" ;;
        *)  c="$(pwd -P 2>/dev/null)"
            if [ -n "$c" ]; then _add_home "$c/${1#./}" "collector environment $2, relative to the collector's cwd $(_quote_nl "$c")"
            else _add_home "$1" "env $2 (collector shell)"; fi ;;
    esac
}

# _quote_nl TEXT -> TEXT with each newline written as \n
_quote_nl() { printf '%s' "$1" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

# D_ODD: candidate paths holding a newline or '|', the record delimiters. They
# are reported and counted as unread, never split into two records.
D_ODD="" D_ODD_HOME=""

# Membership tests bound by the record delimiter, so /opt/whatap is not taken
# for already listed when /data/opt/whatap is.
_add_pkg_dir() {
    local d="$1"
    [ -n "$d" ] || return
    case "$_nl$D_PKG_DIRS$_nl" in *"$_nl$d$_nl"*) return ;; esac
    if [ -n "$D_PKG_DIRS" ]; then D_PKG_DIRS="$D_PKG_DIRS$_nl$d"; else D_PKG_DIRS="$d"; fi
}

_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$p" in *"$_nl"*|*"|"*) D_ODD="$D_ODD \"$(_quote_nl "$p")\"" D_ODD_HOME=1; return ;; esac
    case "$_nl$D_HOMES" in *"$_nl$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES$_nl$p|$s"; else D_HOMES="$p|$s"; fi
}

# Identity is the INVOCATION path, not its readlink target: a virtualenv's
# bin/python usually symlinks to the base interpreter, but sys.prefix (and so
# site-packages, where whatap-python lives) is derived from the path used to
# invoke it. Collapsing to the resolved binary would hide the venv install.
# Dedup key: dirname + resolved target (so bin/python and bin/python3 of the
# same env collapse, while base and venv interpreters stay distinct).
D_PY_KEYS=""
_add_py() {
    local p="$1" k
    [ -n "$p" ] || return
    [ -x "$p" ] || return
    case "$p" in *-config|*-dbg|*-coverage) return ;; esac   # not interpreters
    # a path already listed has the same key: no readlink per process for it
    case "$_nl$D_PY_EXES$_nl" in *"$_nl$p$_nl"*) return ;; esac
    k="${p%/*}|$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_PY_KEYS" in *"$_nl$k$_nl"*) return ;; esac
    D_PY_KEYS="$D_PY_KEYS$_nl$k$_nl"
    if [ -n "$D_PY_EXES" ]; then D_PY_EXES="$D_PY_EXES$_nl$p"; else D_PY_EXES="$p"; fi
}

# _is_py NAME -> success when NAME is a python interpreter's file name
_is_py() { case "$1" in python|python[0-9]*|pypy|pypy[0-9]*) return 0 ;; esac; return 1; }

# _read_proc_env PID -> sets _env to the process environ, one variable per line;
# returns 1 (and adds PID to D_UNREAD) when this uid cannot read it
_read_proc_env() {
    _env=""
    if [ ! -r "/proc/$1/environ" ]; then
        [ -e "/proc/$1/environ" ] && D_UNREAD="$D_UNREAD $1"
        return 1
    fi
    _env="$( { tr '\0' '\n' < "/proc/$1/environ"; } 2>/dev/null )"
    return 0
}

# _env_pick NAME... -> sets _ev_NAME to the value of NAME= in _env (empty if
# none; the last line wins when a name repeats), for each NAME, in one pass
# with shell builtins only: a $(...) per variable costs a fork per variable per
# process. The lines are split by IFS, not by a `read` loop over a here-doc,
# which costs a builtin call per line.
_ev_WHATAP_HOME="" _ev_PYTHONPATH=""
_env_pick() {
    local l n _o _p=""
    # a name absent from the whole environ is settled by one match on it,
    # without walking the lines
    for n in "$@"; do
        eval "_ev_$n=''"
        case "$_nl$_env" in *"$_nl$n="*) _p="$_p$n$_nl" ;; esac
    done
    [ -n "$_p" ] || return 0
    _o="$IFS"; IFS="$_nl"; set -f
    for l in $_env; do
        for n in $_p; do
            case "$l" in "$n="*) eval "_ev_$n=\${l#*=}" ;; esac
        done
    done
    set +f; IFS="$_o"
}

discover() {
    progress "discovery: interpreters, processes, agent homes"
    _cap_from APM_INTERP_CAP "${APM_INTERP_CAP:-}" 8; D_PY_CAP="$_cap" D_CAP_NOTE="$_cap_note"
    local c p pid comm exe a0 cmd cwd envh _b _py _mk _pym="" _pyr="" _am="" _ar="" _d _o
    _env=""

    case "$(id -u 2>/dev/null)" in
        0) ;;
        *) grep -qE '^[^ ]+ /proc proc [^ ]*hidepid=([12]|invisible|noaccess)' /proc/mounts 2>/dev/null \
               && D_HIDEPID="hidepid is set on /proc: other users' processes are not listed to uid $(id -u 2>/dev/null)" ;;
    esac

    # Process scan. A python process is matched by its comm, by argv0, or by
    # /proc/<pid>/exe. comm alone misses every app started from a shebang
    # script (gunicorn, uvicorn, celery, odoo-bin, whatap-start-agent): the
    # kernel names the process after the script, and puts the interpreter from
    # the #! line into argv0. exe covers argv0 rewritten by setproctitle, for
    # the processes this uid may resolve. Runs FIRST so the interpreters of
    # live application processes take the detail slots before PATH/system
    # interpreters when the cap applies.
    while IFS="$_us" read -r pid comm exe a0 cmd; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$$" ] && continue
        case "$comm" in whatap_python*) D_GO_PIDS="$D_GO_PIDS $pid"; continue ;; esac
        _py=0
        case "$comm" in python*) _py=1 ;; esac
        _is_py "${a0##*/}" && _py=1
        _is_py "${exe##*/}" && _py=1
        case "$comm" in
            odoo*) D_ODOO_PIDS="$D_ODOO_PIDS $pid" ;;
            *) [ "$_py" = 1 ] || continue
               case "$cmd" in *odoo*) D_ODOO_PIDS="$D_ODOO_PIDS $pid" ;; esac ;;
        esac
        # whatap markers: the command line names whatap, or the environ
        # carries WHATAP_* or the bootstrap on PYTHONPATH
        _mk=0
        case "$cmd" in *whatap*) _mk=1 ;; esac
        if _read_proc_env "$pid"; then
            _env_pick WHATAP_HOME PYTHONPATH
            [ -n "$_ev_WHATAP_HOME" ] && _home_from_pid "$pid" "$_ev_WHATAP_HOME" "environ of python pid $pid"
            # whatap package dir derived from the process's PYTHONPATH bootstrap
            # entry — usable even when the interpreter cannot be executed
            # split on ':' (and newline) in this shell, globbing off
            envh="$_ev_PYTHONPATH"
            _o="$IFS"; IFS=":$_nl"; set -f
            for _d in $envh; do
                case "$_d" in */whatap/bootstrap) _add_pkg_dir "${_d%/bootstrap}"; _mk=1 ;; esac
            done
            set +f; IFS="$_o"
            case "$_nl$_env" in *"${_nl}WHATAP_"*) _mk=1 ;; esac
        fi
        [ "$_py" = 1 ] || continue
        if [ "$_mk" = 1 ]; then _am="$_am $pid"; else _ar="$_ar $pid"; fi
        # argv0 keeps the venv invocation path; /proc/<pid>/exe is already
        # symlink-resolved by the kernel and would lose it. A relative argv0
        # with a directory part is resolved against the process's cwd.
        p=""
        if _is_py "${a0##*/}"; then
            case "$a0" in
                /*) p="$a0" ;;
                */*) cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
                     [ -n "$cwd" ] && [ -x "$cwd/${a0#./}" ] && p="$cwd/${a0#./}" ;;
            esac
        fi
        [ -n "$p" ] || p="$exe"
        [ -n "$p" ] || continue
        if [ "$_mk" = 1 ]; then _pym="$_pym$p$_nl"; else _pyr="$_pyr$p$_nl"; fi
    done <<EOF
$(_proc_table)
EOF
    D_APP_PIDS="$(echo $_am $_ar)"
    D_PY_LIVE="$_pym$_pyr"
    while IFS= read -r p; do [ -n "$p" ] && _add_py "$p"; done <<EOF
$_pym$_pyr
EOF

    # interpreters on PATH
    for c in python3 python; do
        p="$(command -v "$c" 2>/dev/null)"
        [ -n "$p" ] && _add_py "$p"
    done

    # multiple interpreter versions commonly coexist on one VM — enumerate the
    # usual install locations (shallow globs only, no directory walk)
    for p in /usr/bin/python2* /usr/bin/python3* /usr/local/bin/python2* /usr/local/bin/python3* /opt/python*/bin/python3*; do
        [ -x "$p" ] && _add_py "$p"
    done

    # agent home candidates
    [ -n "${WHATAP_HOME:-}" ] && _home_from_self "$WHATAP_HOME" WHATAP_HOME
    [ -n "${WHATAP_HOME_BATCH:-}" ] && _home_from_self "$WHATAP_HOME_BATCH" WHATAP_HOME_BATCH
    if [ -r "$D_LOCK_FILE" ]; then
        # lock file records "port<TAB>home" per agent home
        while IFS= read -r _l || [ -n "$_l" ]; do
            p="$(printf '%s\n' "$_l" | awk '{print $2}')"
            [ -n "$p" ] && _add_home "$p" "port registry $D_LOCK_FILE"
        done < "$D_LOCK_FILE"
    fi
    for pid in $D_GO_PIDS; do
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        if [ -n "$cwd" ]; then _add_home "$cwd" "cwd of whatap_python pid $pid"
        elif [ -e "/proc/$pid" ]; then D_UNREAD="$D_UNREAD $pid"; fi
        if _read_proc_env "$pid"; then
            _env_pick WHATAP_HOME
            [ -n "$_ev_WHATAP_HOME" ] && _home_from_pid "$pid" "$_ev_WHATAP_HOME" "environ of whatap_python pid $pid"
        fi
    done
    D_UNREAD="$(printf '%s\n' $D_UNREAD | sort -un | tr '\n' ' ' | sed 's/ $//')"
    # operator auto-injection default mount
    [ -d /whatap-agent ] && _add_home "/whatap-agent" "operator injection volume /whatap-agent"
}

# _scan_gaps -> the inputs of the agent-home search this run could not read,
# as one phrase; empty when every one was read
_scan_gaps() {
    local n g=""
    if [ -n "$D_UNREAD" ]; then
        n="$(echo $D_UNREAD | wc -w | tr -d ' ')"
        g="environ/cwd of $n candidate process(es) not readable by uid $(id -u 2>/dev/null || echo '?') (pids: $(echo $D_UNREAD | cut -d' ' -f1-10))"
    fi
    [ -n "$D_HIDEPID" ] && g="${g:+$g; }$D_HIDEPID"
    printf '%s' "$g"
}


# ---- numbers read from outside -------------------------------------------------
# A value from a config, a lock file or the environment is checked before any
# arithmetic or comparison: dash aborts the run on `$((x + 100))` with a
# 20-digit x, and `[ x -lt n ]` on "abc" prints "Illegal number" and is false.
# A value that fails is reported as a fact and not used.

# _num_norm V MAXDIGITS -> V without leading zeros when it is 1..MAXDIGITS
# digits (a leading zero would read as octal in $((...))); fails otherwise
_num_norm() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#v}" -le "$2" ] || return 1
    while :; do case "$v" in 0?*) v="${v#0}" ;; *) break ;; esac; done
    printf '%s' "$v"
}

# _port_norm V -> V as a port (1..65535), or fails
_port_norm() {
    local v
    v="$(_num_norm "$1" 5)" || return 1
    [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || return 1
    printf '%s' "$v"
}

# _cap_from NAME VALUE DEFAULT -> sets _cap to VALUE when it is 1..999999, else
# to DEFAULT, and _cap_note to why VALUE was ignored (empty when unset or used)
_cap_from() {
    local v
    _cap="$3" _cap_note=""
    [ -n "$2" ] || return 0
    if v="$(_num_norm "$2" 6)" && [ "$v" -ge 1 ]; then _cap="$v"; return 0; fi
    _cap_note="$1=$(_quote_nl "$2") ignored (not a number 1..999999), using $3"
}

# _conf_vals KEY FILE... -> the raw values of KEY= in FILEs, one per line
_conf_vals() {
    local k="$1"; shift
    [ "$#" -gt 0 ] || return 0
    awk -F= -v k="$k" '{ gsub(/[ \t\r]/, "") } $1 == k && $2 != "" { print $2 }' "$@" 2>/dev/null
}

# _registry_vals FILE -> the raw first field of each port registry line
_registry_vals() { [ -r "$1" ] && awk 'NF { print $1 }' "$1" 2>/dev/null; return 0; }

# _ports_add LABEL <<VALUES -> the valid ports among VALUES (one per line) join
# _pl, and "; PORTS (LABEL)" joins _plab; refused values join _pbad
_ports_add() {
    local v n got=""
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        if n="$(_port_norm "$v")"; then
            case " $got " in *" $n "*) ;; *) got="${got:+$got }$n" ;; esac
        else _pbad="${_pbad:+$_pbad; }$(_quote_nl "$v") ($1)"; fi
    done
    [ -n "$got" ] && { _pl="$_pl $got"; _plab="$_plab; $got ($1)"; }
    return 0
}

# _uniq_ports PORT... -> the distinct ports, space-joined (validated numbers only)
_uniq_ports() { [ "$#" -gt 0 ] || return 0; printf '%s\n' "$@" | sort -un | tr '\n' ' ' | sed 's/ $//'; }

# _home_confs -> the readable whatap.conf of every visible agent home, one per
# line
_home_confs() {
    local h src f
    while IFS='|' read -r h src; do
        [ -n "$h" ] || continue
        f="$(resolve_fs "$h")" || continue
        [ -r "$f/whatap.conf" ] && [ -f "$f/whatap.conf" ] && printf '%s\n' "$f/whatap.conf"
    done <<EOF
$D_HOMES
EOF
}

# _net_ports -> sets _udp_ports / _tcp_ports to the ports the readable agent
# configs name, or 6600 when none names one, and states which it used
_net_ports() {
    local f
    set --
    while IFS= read -r f; do [ -n "$f" ] && set -- "$@" "$f"; done <<EOF
$(_home_confs)
EOF
    # the 66xx range is always matched: an agent on a port no readable conf
    # or registry names (a non-root run, a non-default port) still shows
    _pl="" _plab="" _pbad=""
    _ports_add "net_udp_port in $# readable whatap.conf" <<EOF
$(_conf_vals net_udp_port "$@")
EOF
    _ports_add "port registry $(_quote_nl "$D_LOCK_FILE")" <<EOF
$(_registry_vals "$D_LOCK_FILE")
EOF
    _ports_add "port registry $D_LLM_LOCK_FILE" <<EOF
$(_registry_vals "$D_LLM_LOCK_FILE")
EOF
    # shellcheck disable=SC2086  # validated port numbers only
    _pl="$(_uniq_ports $_pl)"
    _udp_ports="66[0-9][0-9] $_pl" _udp_label="66xx${_pl:+ $_pl}"
    fact "udp port filter: 66xx (range)$_plab"
    [ -n "$_pbad" ] && fact "udp port values ignored (not a port 1..65535): $_pbad"
    _pl="" _plab="" _pbad=""
    _ports_add "whatap.server.port / whatap_server_port in $# readable whatap.conf" <<EOF
$(_conf_vals whatap.server.port "$@"; _conf_vals whatap_server_port "$@")
EOF
    # shellcheck disable=SC2086
    _pl="$(_uniq_ports 6600 $_pl)"
    _tcp_ports="$_pl" _tcp_label="$_pl"
    fact "tcp port filter: 6600$_plab"
    [ -n "$_pbad" ] && fact "tcp port values ignored (not a port 1..65535): $_pbad"
}

# _sock_list TOOL FLAGS PORTS -> the socket table lines naming whatap or one of
# PORTS (space-separated), header kept, first 50; exits with TOOL's status
_sock_list() {
    local pat rc
    pat=":($(printf '%s' "$3" | tr -s ' ' '|' | sed 's/^|//; s/|$//'))([^0-9]|\$)"
    "$1" "$2" > "$(_tmp sock.out)"; rc=$?
    awk -v p="$pat" '(NR <= 2 && /State|Proto|Recv-Q/) || /whatap/ || $0 ~ p' "$(_tmp sock.out)" 2>/dev/null | head -n 50
    return "$rc"
}

# _resolve_goals -> resolve `agent` and `conf` once, from what discovery and
# the interpreter probes read. An absence is `na` only when every input behind
# it was read: an unreadable environ/cwd, hidepid, a blocked home path or a
# failed interpreter probe makes it `missed`.
_resolve_goals() {
    local h src fs why seen=0 homes_seen=0 blocked="" absent="" unres="" gaps agaps pr n ph
    while IFS='|' read -r h src; do
        [ -n "$h" ] || continue
        if ! fs="$(resolve_fs "$h")"; then
            why="$(_absent_why "$h" "$src")"
            case "$why" in
                permission*) blocked="$blocked; $h ($why)" ;;
                relative*|"not resolved"*) unres="$unres; $h ($why)" ;;
                *)           absent="$absent; $h ($why)" ;;
            esac
            continue
        fi
        homes_seen=1
        if [ -d "$fs" ] && [ ! -x "$fs" ]; then blocked="$blocked; $h (permission denied: $fs)"
        elif [ -r "$fs/whatap.conf" ] && [ -f "$fs/whatap.conf" ]; then seen=1
        elif [ -e "$fs/whatap.conf" ]; then blocked="$blocked; $fs/whatap.conf (permission denied)"
        else absent="$absent; $fs/whatap.conf (path not found)"; fi
    done <<EOF
$D_HOMES
EOF
    blocked="${blocked#; }" absent="${absent#; }"
    gaps="$(_scan_gaps)"
    unres="${unres#; }"
    [ -n "$unres" ] && gaps="${gaps:+$gaps; }home candidate(s) not resolved: $unres"
    [ -n "$D_ODD" ] && gaps="${gaps:+$gaps; }path(s) with a newline or '|', not followed:$D_ODD"
    ph=""; [ -n "$blocked$D_UNREAD$D_HIDEPID" ] && ph="$(_priv_hint)"
    # agent-only inputs: the interpreter lookups
    agaps="$gaps"
    [ -n "$_py_fail" ] && agaps="${agaps:+$agaps; }whatap package lookup failed for interpreter(s):$_py_fail"
    [ -n "$_py_unprobed_live" ] && agaps="${agaps:+$agaps; }$(printf '%s' "$_py_unprobed_live" | grep -c .) interpreter(s) of running processes not probed (cap $D_PY_CAP; set APM_INTERP_CAP=<n> in the environment to raise it): $(printf '%s' "$_py_unprobed_live" | tr '\n' ' ')"
    if [ "$_py_probed" -lt "$_py_total" ]; then pr="$_py_probed of $_py_total interpreter(s) probed (cap $D_PY_CAP; the others serve no running process)"
    else pr="all $_py_total interpreter(s) probed"; fi

    if [ "$homes_seen" = 1 ] || [ -n "$D_PKG_DIRS" ] || [ "$_py_whatap" = 1 ] || [ -n "$D_GO_PIDS" ]; then
        got agent
    elif [ -n "$blocked" ] || [ -n "$agaps" ]; then
        missed agent "no whatap home or package found in what this uid could read: ${blocked:+$blocked; }$agaps$ph"
    else
        n="$(echo $D_APP_PIDS | wc -w | tr -d ' ')"
        na agent "no whatap home or package in the collector env, port registry $D_LOCK_FILE, /whatap-agent, the environ of $n python process(es) (all readable); $pr${absent:+; home candidate(s): $absent}"
    fi

    if [ "$seen" = 1 ]; then got conf
    elif [ -n "$blocked" ]; then missed conf "whatap.conf not readable: $blocked$ph"
    elif [ -n "$D_ODD$unres" ] || { [ -z "$D_HOMES" ] && [ -n "$gaps" ]; }; then missed conf "no agent home found in what this uid could read: $gaps$ph"
    elif [ -z "$D_HOMES" ]; then na conf "no agent home found to hold a whatap.conf (every source read)"
    else na conf "no whatap.conf in any agent home: $absent"; fi
}

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    goal agent "whatap-python package / agent home"
    goal conf  "agent configuration"

    # [1] capability preamble: every downstream "command not found" is
    # pre-explained here.
    section "Collection environment"
    if [ -n "${BASH_VERSION:-}" ]; then fact "shell: bash $BASH_VERSION"
    else fact "shell: POSIX sh (non-bash)"; fi
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in python3 python pip3 ss netstat readlink timeout file stat awk tr; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present (%s)\n' "$t" "$(command -v "$t")"
        else printf '        %-12s absent\n' "$t"; fi
    done

    discover

    # [1] host / platform
    section "Host / platform"
    probe "kernel" uname -srm
    probe "machine arch" uname -m
    read_proc "os-release" /etc/os-release
    probe "cpu count (nproc)" nproc
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    # container / cgroup context — memory and cpu limits as the container sees
    # them (facts behind container-vs-host metric questions)
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        fact "cgroup: v2 (unified)"
        read_proc "cgroup memory.max" /sys/fs/cgroup/memory.max
        read_proc "cgroup cpu.max" /sys/fs/cgroup/cpu.max
    elif [ -d /sys/fs/cgroup/memory ]; then
        fact "cgroup: v1"
        read_proc "cgroup memory.limit_in_bytes" /sys/fs/cgroup/memory/memory.limit_in_bytes
        read_proc "cgroup cpu cfs_quota_us" /sys/fs/cgroup/cpu/cpu.cfs_quota_us
        read_proc "cgroup cpu cfs_period_us" /sys/fs/cgroup/cpu/cpu.cfs_period_us
    else
        fact "cgroup: n/a (path not found: /sys/fs/cgroup)"
    fi
    fact "container markers:"
    for m in /.dockerenv /run/.containerenv; do
        if [ -e "$m" ]; then printf '        %-22s present\n' "$m"; else printf '        %-22s absent\n' "$m"; fi
    done
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        printf '        %-22s %s\n' "KUBERNETES_SERVICE_HOST" "$KUBERNETES_SERVICE_HOST"
    else
        printf '        %-22s not set\n' "KUBERNETES_SERVICE_HOST"
    fi
    probe "self cgroup (first 5 lines)" sh -c "head -n 5 /proc/self/cgroup"
    probe "local time" date
    probe "pid 1 command" sh -c "tr '\0' ' ' < /proc/1/cmdline | cut -c1-160"

    # [2] python runtimes + whatap-python package (per distinct interpreter)
    section "Python runtimes and whatap-python package"
    if [ -z "$D_PY_EXES" ]; then
        fact "python interpreters: n/a (none found on PATH or among running processes)"
    fi
    local _pycount=0 py
    _py_whatap=0 _py_fail="" _py_probed=0 _py_unprobed_live=""
    _py_total="$(printf '%s\n' "$D_PY_EXES" | grep -c .)"
    [ -n "$D_CAP_NOTE" ] && fact "$D_CAP_NOTE"
    # newline-split, no globbing: fd 9 carries the list, so a probe that
    # reads stdin cannot eat it
    while IFS= read -r py <&9; do
        [ -n "$py" ] || continue
        _pycount=$((_pycount + 1))
        if [ "$_pycount" -gt "$D_PY_CAP" ]; then
            fact "-- more interpreters found but not detailed (cap: $D_PY_CAP): $(printf '%s\n' "$D_PY_EXES" | tail -n +"$_pycount" | tr '\n' ' ')"
            # one that serves a running process is an input this run did not read
            while IFS= read -r _l; do
                [ -n "$_l" ] || continue
                case "$_nl$D_PY_LIVE" in *"$_nl$_l$_nl"*) _py_unprobed_live="$_py_unprobed_live$_l$_nl" ;; esac
            done <<EOF
$(printf '%s\n' "$D_PY_EXES" | tail -n +"$_pycount")
EOF
            break
        fi
        _py_probed=$_pycount
        fact "-- interpreter: $py"
        fact "   resolves to: $(readlink -f "$py" 2>/dev/null || echo "$py")"
        _pc1='import sys; print(sys.version.replace(chr(10)," "))'
        _pc2='import sys; print(sys.prefix); print(getattr(sys,"base_prefix",sys.prefix))'
        _pc3='import importlib.metadata as m; print(m.version("whatap-python"))'
        _pc4='import importlib.util as u; s=u.find_spec("whatap"); print(s.origin if s and s.origin else "not found")'
        _pc5='
import importlib.util as u, os, glob
s=u.find_spec("whatap")
if not (s and s.origin): print("not found")
else:
    sp=os.path.dirname(os.path.dirname(s.origin))
    hits=glob.glob(os.path.join(sp,"whatap_python-*"))
    print("\n".join(os.path.basename(h) for h in hits) if hits else "no whatap_python-* metadata dir in "+sp)'
        _pc6='import importlib.metadata as m; print(m.version("setuptools"))'
        _pc7='import pkg_resources; print("ok")'
        # Go module binaries shipped inside the package, vs this machine arch
        _pc8='
import importlib.util as u, os
s=u.find_spec("whatap")
if not (s and s.origin): print("not found")
else:
    d=os.path.join(os.path.dirname(s.origin),"agent")
    if not os.path.isdir(d): print("no agent dir: "+d)
    else:
        for root,_,files in os.walk(d):
            for f in files:
                p=os.path.join(root,f)
                print("%s  %d bytes  exec=%s" % (p, os.path.getsize(p), os.access(p,os.X_OK)))'
        _pc9='
import importlib.util as u, os
s=u.find_spec("whatap")
print(os.path.exists(os.path.join(os.path.dirname(s.origin),"bootstrap","sitecustomize.py")) if s and s.origin else "not found")'
        # hook surface of the INSTALLED agent version (trace/mod tree) — this
        # differs between agent versions, so it is reported per install
        _pc10='
import importlib.util as u, os
s=u.find_spec("whatap")
if not (s and s.origin): print("not found")
else:
    base=os.path.join(os.path.dirname(s.origin),"trace","mod")
    if not os.path.isdir(base): print("no trace/mod dir: "+base)
    else:
        groups={}
        for root,dirs,files in os.walk(base):
            rel=os.path.relpath(root,base)
            cat="core" if rel=="." else rel.replace(os.sep,"/")
            for f in sorted(files):
                if f.endswith(".py") and f not in ("__init__.py","util.py"):
                    groups.setdefault(cat,[]).append(f[:-3])
        for k in sorted(groups): print(k+": "+", ".join(sorted(groups[k])))'
        # one interpreter start for all ten lookups (see _pyrun)
        _pyrun "$py" "$_pc1" "$_pc2" "$_pc3" "$_pc4" "$_pc5" "$_pc6" "$_pc7" "$_pc8" "$_pc9" "$_pc10"
        _pyreport 1 "version" "$_pc1"
        _pyreport 2 "sys.prefix / base_prefix" "$_pc2"
        _pyreport 3 "whatap-python version" "$_pc3"
        _pyreport 4 "whatap package location" "$_pc4"
        case "$_pyrc" in
            0) case "$_pyout" in /*) _py_whatap=1 ;; esac ;;
            # an interpreter that cannot run the lookup at all (python2: no
            # importlib.util) has answered it: there is nothing to look up with.
            # A timeout or any other failure left the input unread.
            *) if [ "$_pyrc" != 124 ] && grep -qE '^(ImportError|ModuleNotFoundError|SyntaxError|AttributeError)' "$_errfile" 2>/dev/null; then :
               else _py_fail="$_py_fail $py"; fi ;;
        esac
        _pyreport 5 "whatap_python-* metadata dirs next to the package" "$_pc5"
        _pyreport 6 "setuptools version" "$_pc6"
        _pyreport 7 "import pkg_resources" "$_pc7"
        _pyreport 8 "bundled Go module binaries" "$_pc8"
        _pyreport 9 "bootstrap/sitecustomize.py present" "$_pc9"
        _pyreport 10 "instrumentation modules bundled in installed agent (trace/mod)" "$_pc10"
        probe "installed packages ($py -m pip list, first 200)" _head_of 200 env PIP_DISABLE_PIP_VERSION_CHECK=1 "$py" -m pip list --format=freeze
    done 9<<EOF
$D_PY_EXES
EOF
    fact "console scripts on PATH:"
    for c in whatap-start-agent whatap-stop-agent whatap-setting-config whatap-llm-setting-config whatap-start-batch-agent; do
        p="$(command -v "$c" 2>/dev/null)"
        if [ -n "$p" ]; then printf '        %-28s %s\n' "$c" "$p"
        else printf '        %-28s not on PATH\n' "$c"; fi
    done
    # fallback that needs no interpreter execution (e.g. distroless images
    # inspected from a kubectl-debug ephemeral container): package dirs derived
    # from the PYTHONPATH of running processes, version read from metadata files
    if [ -n "$D_PKG_DIRS" ]; then
        fact "whatap package dirs seen in process environ (no interpreter execution):"
        printf '%s\n' "$D_PKG_DIRS" | while IFS= read -r d; do
            [ -n "$d" ] || continue
            fsd="$(resolve_fs "$d")"
            if [ -z "$fsd" ]; then printf '        -- %s: n/a (%s)\n' "$d" "$(_absent_why "$d")"; continue; fi
            if [ "$fsd" != "$d" ]; then printf '        -- %s (read via %s)\n' "$d" "$fsd"
            else printf '        -- %s\n' "$d"; fi
            sp="$(dirname "$fsd")"
            meta="$(ls "$sp"/whatap_python-*.dist-info/METADATA "$sp"/whatap_python-*.egg-info/PKG-INFO "$sp"/EGG-INFO/PKG-INFO 2>/dev/null | head -n1)"
            if [ -n "$meta" ]; then
                printf '           metadata: %s\n' "$meta"
                printf '           %s\n' "$(grep -m1 '^Version:' "$meta" 2>/dev/null || echo 'Version: n/a (no Version line in metadata)')"
            else
                printf '           metadata: n/a (no whatap_python-* dist-info/egg-info next to %s)\n' "$fsd"
            fi
            if [ -d "$fsd/agent" ]; then printf '           agent binaries dir: present\n'
            else printf '           agent binaries dir: absent\n'; fi
            # library inventory of this environment, from metadata dir names —
            # needs neither pip nor a runnable interpreter
            _dists="$(ls "$sp" 2>/dev/null | grep -E '\.dist-info$|\.egg-info$|\.egg$' | sed 's/\.dist-info$//; s/\.egg-info$//')"
            if [ -n "$_dists" ]; then
                printf '           installed distributions in %s (%s total, first 200):\n' "$sp" "$(printf '%s\n' "$_dists" | wc -l | tr -d ' ')"
                printf '%s\n' "$_dists" | head -n 200 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            else
                printf '           installed distributions: n/a (no dist-info/egg-info entries in %s)\n' "$sp"
            fi
            # hook surface of this install (shell glob; two levels, no walk)
            _mods="$(for f in "$fsd"/trace/mod/*.py "$fsd"/trace/mod/*/*.py; do [ -f "$f" ] && basename "$f" .py; done 2>/dev/null | grep -vE '^(__init__|util)$' | sort -u | tr '\n' ' ')"
            if [ -n "$_mods" ]; then printf '           instrumentation modules bundled in installed agent: %s\n' "$_mods"
            else printf '           instrumentation modules: n/a (no trace/mod entries under %s)\n' "$fsd"; fi
        done
    fi

    # [3] runtime processes
    section "Runtime processes"
    local pid n
    if [ -z "$D_GO_PIDS" ]; then
        fact "Go common module (whatap_python) processes: none found in /proc"
    else
        fact "Go common module (whatap_python) processes:"
        for pid in $D_GO_PIDS; do
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s\n' "$pid"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-300)"
            printf '           cwd: %s\n' "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "n/a (permission denied or gone)")"
            printf '           uid/state: %s\n' "$(awk '/^Uid:/{u=$2} /^State:/{s=$2" "$3} END{print u" / "s}' "/proc/$pid/status" 2>/dev/null)"
            if [ -r "/proc/$pid/environ" ]; then
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^(WHATAP_HOME|WHATAP_VERSION|whatap\.port|python\.version)=' | while IFS= read -r _l; do printf '           env %s\n' "$_l"; done
            else
                printf '           env: n/a (permission denied: /proc/%s/environ)\n' "$pid"
            fi
        done
    fi
    n="$(echo $D_APP_PIDS | wc -w | tr -d ' ')"
    if [ "${n:-0}" -eq 0 ]; then
        fact "python processes: none found in /proc"
    else
        fact "python processes found: $n (whatap-marked processes listed first; detailing first 20)"
        local shown=0
        for pid in $D_APP_PIDS; do
            shown=$((shown + 1))
            [ "$shown" -gt 20 ] && { fact "-- remaining $((n - 20)) python processes not detailed (cap: 20)"; break; }
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           exe: %s\n' "$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo n/a)"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-300)"
            if [ -r "/proc/$pid/environ" ]; then
                # one read of the environ: the bootstrap line, then which
                # python environment this process actually runs in, WHATAP_*
                # and OTEL_*, each group in environ order
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | awk '
                    /^PYTHONPATH=.*whatap\/bootstrap/ { b = 1 }
                    /^(VIRTUAL_ENV|PYTHONPATH|PYTHONHOME)=/ { v = v "           env " substr($0, 1, 300) "\n" }
                    /^WHATAP_/ { w = w "           env " $0 "\n" }
                    /^OTEL_/ { o = o "           env " substr($0, 1, 200) "\n" }
                    END { printf "           PYTHONPATH contains whatap/bootstrap: %s\n%s%s%s", (b ? "yes" : "no"), v, w, o }'
            else
                printf '           environ: n/a (permission denied: /proc/%s/environ)\n' "$pid"
            fi
            # libraries the process has ACTUALLY loaded, from its memory map.
            # Only C-extension packages appear here (pure-Python imports are
            # not memory-mapped); it also reveals which site-packages the
            # live process really loads from.
            if cat "/proc/$pid/maps" >/dev/null 2>&1; then
                _so="$(awk '$NF ~ /site-packages\/.*\.so/ {print $NF}' "/proc/$pid/maps" 2>/dev/null | sort -u)"
                if [ -n "$_so" ]; then
                    printf '           site-packages in use (from loaded C extensions):\n'
                    printf '%s\n' "$_so" | sed 's#\(.*/site-packages\)/.*#\1#' | sort -u | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                    printf '           loaded C-extension packages:\n'
                    printf '%s\n' "$_so" | sed 's#.*/site-packages/##' | sed 's#/.*##' | sed 's#\.cpython.*##; s#\.so.*##' | sort -u | head -n 40 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                else
                    printf '           loaded C-extension packages: none in maps\n'
                fi
            else
                printf '           maps: n/a (permission denied: /proc/%s/maps)\n' "$pid"
            fi
        done
    fi

    # [4] agent homes and configuration
    section "Agent homes and configuration"
    fact "env WHATAP_HOME (collector shell): $(_quote_nl "${WHATAP_HOME:-not set}")"
    fact "env WHATAP_HOME_BATCH (collector shell): $(_quote_nl "${WHATAP_HOME_BATCH:-not set}")"
    fact "env WHATAP_LOCK_FILE (collector shell): $(_quote_nl "${WHATAP_LOCK_FILE:-not set}")"
    if [ -z "$D_HOMES" ]; then
        if [ -n "$D_ODD_HOME" ]; then fact "agent home candidates: none followed (the refused ones are listed above)"
        else fact "agent home candidates: none discovered (env, port registry, process scan all empty)"; fi
    fi
    [ -n "$D_ODD" ] && fact "path(s) with a newline or '|', not followed:$D_ODD"
    [ -n "$D_GONE" ] && printf '%s' "$D_GONE" | while IFS= read -r _l; do [ -n "$_l" ] && fact "relative WHATAP_HOME of a process that exited, not resolved: $_l"; done
    if [ -n "$D_HOMES" ]; then
        fact "agent home candidates discovered:"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _s; do printf '        %s   <- %s\n' "$_p" "$_s"; done
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")"
            if [ -z "$fshome" ]; then fact "   n/a ($(_absent_why "$home" "$_src"))"; continue; fi
            [ "$fshome" != "$home" ] && fact "   filesystem view: $fshome (read through a process root)"
            dump_file "   whatap.conf" "$fshome/whatap.conf" 400
            dump_file "   container.conf" "$fshome/container.conf" 200
            if [ -e "$fshome/whatap_python" ]; then
                fact "   whatap_python entry: $(ls -l "$fshome/whatap_python" 2>/dev/null | head -n1)"
                fact "   whatap_python resolved: $(readlink -f "$fshome/whatap_python" 2>/dev/null || echo 'n/a (unresolvable)')"
            else
                fact "   whatap_python entry: n/a (path not found: $fshome/whatap_python)"
            fi
            for pf in whatap_python.pid whatap_python.pid.llm whatap_python.pid.batch; do
                if [ -f "$fshome/$pf" ]; then
                    _pid="$(cat "$fshome/$pf" 2>/dev/null | tr -d ' \n')"
                    if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
                        fact "   $pf: $_pid (process exists; comm: $(cat "/proc/$_pid/comm" 2>/dev/null))"
                    else
                        fact "   $pf: ${_pid:-empty} (no process with this pid in this pid namespace)"
                    fi
                fi
            done
            for sf in security.conf paramkey.txt; do
                if [ -e "$fshome/$sf" ]; then fact "   $sf: present, $(wc -c < "$fshome/$sf" 2>/dev/null | tr -d ' ') bytes (content not collected: key material)"
                else fact "   $sf: absent"; fi
            done
            if [ -d "$fshome/logs" ]; then
                probe "   logs dir listing" _ls_head "$fshome/logs" 100
            else
                fact "   logs dir: n/a (path not found: $fshome/logs)"
            fi
            [ -d "$fshome/run" ] && fact "   run dir (agent sockets): present" || fact "   run dir (agent sockets): absent"
            [ -d "$fshome/whatap-python-llm" ] && fact "   whatap-python-llm dir (LLM Go module): present" || fact "   whatap-python-llm dir (LLM Go module): absent"
        done
    fi

    # [5] network endpoints + port registry
    section "Network endpoints and port registry"
    _net_ports
    if have ss; then
        probe "udp sockets (whatap-named or port $_udp_label)" _sock_list ss -uanp "$_udp_ports"
        probe "tcp sessions (whatap-named or port $_tcp_label)" _sock_list ss -tnp "$_tcp_ports"
    elif have netstat; then
        probe "udp sockets (whatap-named or port $_udp_label)" _sock_list netstat -uanp "$_udp_ports"
        probe "tcp sessions (whatap-named or port $_tcp_label)" _sock_list netstat -tnp "$_tcp_ports"
    else
        fact "socket listing: n/a (command not found: ss, netstat); raw tables follow"
        probe "raw /proc/net/udp (first 30 lines)" sh -c "head -n 30 /proc/net/udp"
        probe "raw /proc/net/tcp (first 30 lines)" sh -c "head -n 30 /proc/net/tcp"
    fi
    dump_file "port registry (format: port<TAB>home)" "$D_LOCK_FILE" 50
    dump_file "LLM port registry" "$D_LLM_LOCK_FILE" 50

    # [6] agent logs (bounded tails only; never a whole-log grep)
    section "Agent logs"
    if [ -z "$D_HOMES" ]; then
        fact "no agent home discovered; no log locations to read"
    else
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")"
            if [ -z "$fshome" ]; then fact "   n/a ($(_absent_why "$home" "$_src"))"; continue; fi
            # hook log: the banner and the "successfully injected <module>"
            # lines (= which libraries the agent hooked in THIS process) are at
            # the START of the file, so read its head as well as its tail
            _hook="$fshome/logs/whatap-hook.log"
            head_file "   whatap-hook.log (first lines)" "$_hook" 120
            tail_file "   whatap-hook.log (recent lines)" "$_hook" 80
            if [ -r "$_hook" ]; then
                fact "   'successfully injected' lines in whatap-hook.log (first 400 lines): $(head -n 400 "$_hook" 2>/dev/null | grep -c 'successfully injected' 2>/dev/null)"
            fi
            # newest Go-side boot log only (flat dir; ls -t, no deep find)
            _boot="$(ls -t "$fshome"/logs/whatap-boot-*.log 2>/dev/null | head -n 1)"
            if [ -n "$_boot" ]; then
                head_file "   $(basename "$_boot") (Go-side boot log, first lines)" "$_boot" 60
                tail_file "   $(basename "$_boot") (Go-side boot log, recent lines)" "$_boot" 120
            else
                fact "   whatap-boot-*.log: n/a (no such file in $fshome/logs)"
            fi
        done
    fi

    # [8] odoo application facts — Odoo has its own web framework, prefork
    # worker model, and config file; agent support depends on the Odoo version
    # and the traffic dispatcher (http vs json vs websocket/longpolling vs
    # cron), so a support case needs these facts. Cheap no-op on non-Odoo hosts.
    section "Odoo application facts"
    local opid _oc _ocands="" _rcands="" _c
    if [ -z "$D_ODOO_PIDS" ]; then
        fact "odoo processes: none found in /proc (by comm or cmdline)"
    else
        fact "odoo processes:"
        for opid in $D_ODOO_PIDS; do
            [ -d "/proc/$opid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$opid"; continue; }
            printf '        -- pid %s (ppid %s)\n' "$opid" "$(awk '/^PPid:/{print $2}' "/proc/$opid/status" 2>/dev/null)"
            printf '           comm: %s\n' "$(cat "/proc/$opid/comm" 2>/dev/null)"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$opid/cmdline" 2>/dev/null | cut -c1-300)"
            printf '           cwd: %s\n' "$(readlink -f "/proc/$opid/cwd" 2>/dev/null || echo "n/a (permission denied or gone)")"
            printf '           uid: %s\n' "$(awk '/^Uid:/{print $2}' "/proc/$opid/status" 2>/dev/null)"
        done
    fi

    # odoo package version — read release.py as text; the odoo module is never
    # imported and no odoo code runs
    _pycount=0
    while IFS= read -r py <&9; do
        [ -n "$py" ] || continue
        _pycount=$((_pycount + 1))
        [ "$_pycount" -gt "$D_PY_CAP" ] && break
        _c="$(_bounded "$py" -c '
import importlib.util as u, os
s = u.find_spec("odoo")
loc = ""
if s:
    if s.origin: loc = os.path.dirname(s.origin)
    elif s.submodule_search_locations:
        for _p in s.submodule_search_locations: loc = _p; break
print(os.path.join(loc, "release.py") if loc else "")' 2>/dev/null)"
        [ -n "$_c" ] && _rcands="$_rcands$_c$_nl"
    done 9<<EOF
$D_PY_EXES
EOF
    _rcands="$_rcands/usr/lib/python3/dist-packages/odoo/release.py$_nl"
    for opid in $D_ODOO_PIDS; do
        _c="$(readlink -f "/proc/$opid/cwd" 2>/dev/null)"
        [ -n "$_c" ] && _rcands="$_rcands$_c/odoo/release.py$_nl"
    done
    while IFS= read -r _d; do
        [ -n "$_d" ] && _rcands="$_rcands${_d%/*}/odoo/release.py$_nl"
    done <<EOF
$D_PKG_DIRS
EOF
    _found_rel=0
    _seen_rel=""
    while IFS= read -r _c <&9; do
        [ -n "$_c" ] || continue
        case "$_seen_rel" in *"$_nl$_c$_nl"*) continue ;; esac
        _seen_rel="$_seen_rel$_nl$_c$_nl"
        _fs="$(resolve_fs "$_c")" || continue
        [ -f "$_fs" ] || continue
        _found_rel=1
        fact "odoo release file: $_fs"
        grep -E '^(version|version_info|serie|product_name)' "$_fs" 2>/dev/null | head -n 6 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    done 9<<EOF
$_rcands
EOF
    [ "$_found_rel" = 0 ] && fact "odoo release file: n/a (no odoo/release.py found via interpreters, process cwd, dist-packages, or site-packages)"

    # odoo configuration — path from cmdline -c/--config, env ODOO_RC, then
    # the packaged default locations
    for opid in $D_ODOO_PIDS; do
        _oc="$(tr '\0' '\n' < "/proc/$opid/cmdline" 2>/dev/null | awk 'p==1{print;exit} $0=="-c"||$0=="--config"{p=1;next} sub(/^--config=/,""){print;exit} sub(/^-c/,"") && length($0)>0 {print;exit}')"
        [ -z "$_oc" ] && _oc="$(tr '\0' '\n' < "/proc/$opid/environ" 2>/dev/null | grep '^ODOO_RC=' | head -n1 | cut -d= -f2-)"
        if [ -n "$_oc" ]; then
            fact "odoo config path (pid $opid): $_oc"
            case "$_ocands" in *"|$_oc|"*) ;; *) _ocands="$_ocands|$_oc|" ;; esac
        else
            [ -n "$D_ODOO_PIDS" ] && fact "odoo config path (pid $opid): not specified on cmdline or ODOO_RC env"
        fi
    done
    for _c in /etc/odoo/odoo.conf /etc/odoo.conf; do
        if _fs="$(resolve_fs "$_c")" && [ -f "$_fs" ]; then
            case "$_ocands" in *"|$_c|"*) ;; *) _ocands="$_ocands|$_c|"; fact "odoo config path (packaged default): $_c" ;; esac
        fi
    done
    if [ -z "$_ocands" ]; then
        fact "odoo config file: n/a (no path on cmdline/ODOO_RC and no packaged default present)"
    else
        printf '%s\n' "$_ocands" | tr '|' '\n' | grep -v '^$' | while IFS= read -r _oc; do
            _fs="$(resolve_fs "$_oc")" || { fact "-- odoo config $_oc: n/a (path not visible from this mount namespace)"; continue; }
            [ -r "$_fs" ] || { fact "-- odoo config $_oc: n/a (permission denied: $_fs)"; continue; }
            _skip="$(grep -cE '^[[:space:]]*(db_password|admin_passwd)[[:space:]]*=' "$_fs" 2>/dev/null)"
            fact "-- odoo config $_oc (data scope: db_password/admin_passwd lines not collected — ${_skip:-0} such line(s) omitted; first 200 lines):"
            grep -vE '^[[:space:]]*(db_password|admin_passwd)[[:space:]]*=' "$_fs" 2>/dev/null | head -n 200 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            # where the http-worker traceback goes: the logfile key, or stdout
            _lf="$(grep -E '^[[:space:]]*logfile[[:space:]]*=' "$_fs" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            if [ -n "$_lf" ] && [ "$_lf" != "None" ] && [ "$_lf" != "False" ]; then
                fact "   odoo logfile key: $_lf"
                _lfs="$(resolve_fs "$_lf")" && tail_file "   odoo logfile (worker log)" "$_lfs" 120 || fact "   odoo logfile: n/a (path not visible: $_lf)"
            else
                fact "   odoo logfile key: not set"
            fi
        done
    fi

    # listening sockets of odoo processes (default http 8069, gevent/longpolling 8072)
    probe "odoo listening tcp sockets (odoo or ports 8069/8072)" sh -c "ss -ltnp 2>/dev/null | awk 'NR==1 || /odoo/ || /:8069 / || /:8072 /' | head -n 30"

    # systemd unit facts (VM installs; absent inside containers)
    if have systemctl; then
        probe "systemd odoo units" _head_of 20 systemctl list-units --all 'odoo*'
        probe "systemd odoo unit file(s)" _head_of 80 systemctl cat 'odoo*'
    else
        fact "systemd odoo units: n/a (command not found: systemctl)"
    fi

    # agent hook evidence for odoo, per agent home (count only; the raw lines
    # are in the log section's whatap-hook.log head)
    if [ -n "$D_HOMES" ]; then
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            _fh="$(resolve_fs "$home")" || { fact "hook.log 'injected odoo' lines (home $home): n/a ($(_absent_why "$home"))"; continue; }
            _hk="$_fh/logs/whatap-hook.log"
            [ -r "$_hk" ] && fact "hook.log 'injected odoo' lines (first 400 lines, home $home): $(head -n 400 "$_hk" 2>/dev/null | grep -c 'injected odoo' 2>/dev/null)"
        done
    fi

    # [9] kubernetes / operator injection artifacts
    section "Kubernetes / operator injection context"
    if [ -d /whatap-agent ]; then
        probe "/whatap-agent listing" _ls_head /whatap-agent 50
    else
        fact "/whatap-agent: n/a (path not found: /whatap-agent)"
    fi
    if [ -n "${WHATAP_PYTHON_AGENT_PATH:-}" ]; then
        fact "env WHATAP_PYTHON_AGENT_PATH: $WHATAP_PYTHON_AGENT_PATH"
        if [ -L "$WHATAP_PYTHON_AGENT_PATH" ]; then
            fact "WHATAP_PYTHON_AGENT_PATH file type: symlink -> $(readlink -f "$WHATAP_PYTHON_AGENT_PATH" 2>/dev/null)"
        elif [ -e "$WHATAP_PYTHON_AGENT_PATH" ]; then
            fact "WHATAP_PYTHON_AGENT_PATH file type: regular file"
        else
            fact "WHATAP_PYTHON_AGENT_PATH file type: n/a (path not found)"
        fi
    else
        fact "env WHATAP_PYTHON_AGENT_PATH: not set (collector shell)"
    fi
    for v in POD_NAME NODE_NAME POD_NAMESPACE OKIND ONAME ONODE; do
        eval "_val=\${$v:-}"
        [ -n "$_val" ] && fact "env $v: $_val"
    done
    [ -d /var/run/secrets/kubernetes.io ] && fact "/var/run/secrets/kubernetes.io: present" || fact "/var/run/secrets/kubernetes.io: absent"
    read_proc "container hostname (/etc/hostname)" /etc/hostname

    # Resolved here, not at the point of use: the config dumps above run inside
    # `| while` pipelines, and an assignment made in a subshell does not survive.
    _resolve_goals
    emit_status
    emit_footer
}

# ---- main — DO NOT EDIT --------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_run_init
_init_probe
if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="$(hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="./$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
_end_probe
