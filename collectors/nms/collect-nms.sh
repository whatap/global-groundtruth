#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — NMS Control Manager collector (seeded v0)
# -----------------------------------------------------------------------------
# Gathers the environment facts that NMS support cases ask for over and over
# (fact list derived from the #nms-support channel history 2025-04 ~ 2026-07;
# see cases/2026-07-03-nms-support-channel-analysis/analysis.md in the analysis
# workspace for the question -> section traceability), cross-checked against
# the official docs:
#   https://docs.whatap.io/nms/supported-spec   (OS/python matrix, ports)
#   https://docs.whatap.io/nms/install-agent    (repo setup, wtinitset, units)
#
# Runs on the host where the WhaTap NMS Control Manager (whatap-nms package,
# rpm on RHEL-family / deb on Debian-family) is — or was supposed to be —
# installed.
#
# THE CONTRACT (../../CONTRACT.md):
#   1. Facts only. No diagnosis, no likely-cause, no recommendation, no fix.
#   2. Discover, never assume. The install root comes from rpm -ql, services
#      from systemd state, ports from ss/netstat/proc — never hardcoded guesses.
#      A value we cannot obtain is a fact with a reason (n/a (...)).
#   3. One field command -> paste. `./collect-nms.sh --file`, send the .txt.
#   4. Domain-team owned. Seeded v0 by the Global team (framework owner);
#      ongoing ownership belongs to the NMS development team.
#
# DESIGN (../../docs/collector-engineering.md):
#   * MECE sections [1]..[10] — every fact lives in exactly one place.
#   * Load-safe: Tier 0 default is read-only and near-instant. Log reads are
#     tail-bounded; no recursive du/find; the two outbound reachability probes
#     are single HEAD requests capped at 5s each (closed-network detection is
#     itself a recurring support question). The SNMP probe is Tier 2, opt-in,
#     single GET requests only — never a walk.
#   * Portable: bash 3.2+, /proc first, command chains with fallbacks,
#     no set -e / set -u.
#   * Reasoned absence: probe/read_proc/dump helpers classify every miss.
# -----------------------------------------------------------------------------

# bash only: arrays, `read -d`, $SECONDS. Another shell would run on and give
# wrong answers silently, so it stops here instead.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' "collect-nms.sh needs bash (run it as ./collect-nms.sh or bash collect-nms.sh)" >&2
    exit 2
fi

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-nms"
VERSION="0.6.0"
DOMAIN="nms"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness -------------------------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr
OPT_SNMP=0        # Tier 2: timed SNMP GET probe against one device
SNMP_HOST=""
SNMP_COMM=""
SNMP_PORT="161"

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Target: the WhaTap NMS Control Manager host (whatap-nms rpm).
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet    silence progress on stderr (add to --file / --stdout)

  Tier 2 (opt-in, sends 3 SNMP GET requests to the target device — announced
  on stderr before running; single GETs only, never a walk):
  $(basename "$0") --file --snmp <device-ip> <community> [port]
      SNMPv2c GET of sysDescr.0 / sysUpTime.0 / ifNumber.0 with per-request
      elapsed time (the manager polls with a first-response timeout, so the
      elapsed time next to a present/absent answer is a load-bearing fact).
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        --snmp)
            OPT_SNMP=1
            if [ $# -lt 3 ]; then
                printf -- '--snmp needs: --snmp <device-ip> <community> [port]\n' >&2; exit 2
            fi
            SNMP_HOST="$2"; SNMP_COMM="$3"; shift 2
            case "${2:-}" in
                [0-9]*) SNMP_PORT="$2"; shift ;;
            esac
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers ------------------------------------------------------------
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

subsection() { printf '\n    -- %s --\n' "$1"; }

fact() { printf '    %s\n' "$1"; }

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
# the local timeout(1) returns for a kill (busybox gives 143).
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
# warn naming what was ignored
_cap_or() {
    case "$2" in
        ''|*[!0-9]*|0*) ;;
        *) [ "${#2}" -le 6 ] && { printf '%s' "$2"; return 0; } ;;
    esac
    warn "$1=$2 ignored (not a number 1..999999), using $3"
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
        if [ -n "$in" ];                   then "$_timeout_bin" "$t" "$@" < "$in"
        elif [ "$_stdin_script" = 1 ];     then "$_timeout_bin" "$t" "$@" < /dev/null
        else                                    "$_timeout_bin" "$t" "$@"; fi
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

# ---- reasoned-absence helpers --------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=20
_init_probe() {
    _errfile="$(_tmp probe.err)"
    have timeout && _timeout_bin="$(command -v timeout)"
}
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null; }

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
# non-zero exit that still printed something is reported with its output, since
# for many commands the exit code is the answer (systemctl is-active prints
# "inactive" and exits 3).
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

# probe_merged: like probe but folds stderr into stdout (python --version etc.).
probe_merged() {
    local label="$1"; shift
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    _past_deadline && { fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"; return; }
    local out rc
    out="$(_bounded "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    if [ -z "$out" ]; then
        if [ "$rc" -ne 0 ]; then fact "$label: n/a (empty output, exit $rc)"; else fact "$label: n/a (empty output)"; fi
        return
    fi
    if [ "$rc" -ne 0 ]; then _emit_labeled "$label (exit $rc)" "$out"
    else _emit_labeled "$label" "$out"; fi
}

# curl_reach URL -> one bounded HEAD request. curl prints its -w line even on
# failure (HTTP 000), and its exit code names the failure, so both are stated.
_curl_rc_name() {
    case "$1" in
        5) echo "could not resolve proxy" ;;
        6) echo "could not resolve host" ;;
        7) echo "failed to connect" ;;
        28) echo "operation timed out" ;;
        35) echo "TLS connect error" ;;
        47) echo "too many redirects" ;;
        52) echo "empty reply from server" ;;
        56) echo "failure receiving network data" ;;
        60) echo "peer certificate cannot be authenticated" ;;
        *) echo "see curl(1) EXIT CODES" ;;
    esac
}
curl_reach() {
    local url="$1" out rc
    out="$(_bounded curl -sI --max-time 5 -o /dev/null -w 'HTTP %{http_code} in %{time_total}s' "$url" 2>"$_errfile")"; rc=$?
    if [ "$rc" -eq 0 ]; then fact "$url: $out"
    elif [ "$rc" -eq 124 ]; then fact "$url: n/a (timed out: ${CMD_TIMEOUT}s)"
    else fact "$url: ${out:-no -w output}; curl rc=$rc ($(_curl_rc_name "$rc"))"; fi
}

# read_proc "label" PATH -> content of a /proc or /sys file, or a reason.
read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# tail_file PATH N -> last N lines of a file (bounded read), or a reason.
tail_file() {
    local path="$1" n="${2:-60}"
    [ -e "$path" ] || { fact "n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "(empty file)"; return; }
    tail -n "$n" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# dump_file PATH [CAP] -> a file's content verbatim (line-capped), or a reason.
# Framework policy (docs/authoring-guide.md step 3): configuration is dumped
# verbatim, never masked — a value has to be readable to be verified or refuted
# against the other side (e.g. a community string compared with the device),
# and genuinely sensitive WhaTap material is stored encrypted anyway.
dump_file() {
    local path="$1" cap="${2:-400}"
    [ -e "$path" ] || { fact "n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "(empty file)"; return; }
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do
        printf '        %s\n' "$_l"
    done
}

# file_meta PATH -> "bytes / mtime" one-liner for a file.
file_meta() {
    local path="$1" sz
    # size from stat (no read needed); an unreadable file is said so
    sz="$(_bounded stat -c %s "$path" 2>/dev/null)"
    [ -n "$sz" ] || sz="$({ wc -c < "$path"; } 2>/dev/null | tr -d ' ')"
    [ -r "$path" ] || sz="${sz:-n/a} (not readable)"
    printf '%s bytes, mtime %s' \
        "${sz:-n/a}" \
        "$(date -u -r "$path" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)"
}

# now_s -> seconds (sub-second when the platform provides it) for elapsed-time
# measurement. %N is not universal; detect once and fall back to whole seconds.
_now_ns_ok=""
now_s() {
    if [ -z "$_now_ns_ok" ]; then
        case "$(date +%N 2>/dev/null)" in
            [0-9]*) _now_ns_ok=yes ;;
            *)      _now_ns_ok=no ;;
        esac
    fi
    if [ "$_now_ns_ok" = yes ]; then date +%s.%N; else date +%s; fi
}

elapsed_s() {  # elapsed_s START END -> "X.XXX" (awk does the float math)
    awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'
}

# systemd helper — avoid `--value` (unsupported on systemd < 230)
sd_show() { have systemctl && _bounded systemctl show -p "$1" "$2.service" 2>/dev/null | cut -d= -f2-; }

# ---- discovery ----------------------------------------------------------------
# Install root: resolved from the package manifest first (Contract rule 2) —
# rpm on RHEL-family, dpkg on Debian-family (both are official install paths,
# docs.whatap.io/nms/install-agent). The path seen in field sessions
# (/usr/share/whatap-nms) is only a fallback that is used when it exists on disk.
NMS_ROOT=""
NMS_ROOT_SRC=""
NMS_PKG="whatap-nms"
NMS_PIDS=""          # pids whose cmdline names wtnms / icmptcphealthd / whatap-nms
PKG_SCAN=""          # which package manifests were read
PROC_HIDDEN=""       # non-empty when /proc hides other users' processes
PROC_SCAN_CUT=""     # non-empty when the /proc scan stopped early
PROC_STATE=""         # what the run knows about /proc visibility, for [1]
_proc_hidden() {
    # hidepid=1|noaccess: other users' /proc/<pid> entries are listed but not
    # readable; hidepid=2|invisible: they are not listed at all. A run holding
    # the gid= group is exempt. Unread mountinfo is not "no hidepid".
    local o hp g
    if [ "$(id -u 2>/dev/null)" = 0 ]; then PROC_STATE="run as root (hidepid does not apply)"; return 1; fi
    if [ ! -r /proc/self/mountinfo ]; then
        PROC_STATE="n/a (/proc/self/mountinfo not readable; visibility of other users' processes unknown)"; return 0
    fi
    # the last /proc mount in mountinfo is the one on top
    o="$(awk '$5 == "/proc" {o = $6 "," $NF} END {print o}' /proc/self/mountinfo 2>/dev/null)"
    if [ -z "$o" ]; then
        PROC_STATE="n/a (no /proc mount in /proc/self/mountinfo; visibility of other users' processes unknown)"; return 0
    fi
    hp="$(printf '%s' "$o" | tr ',' '\n' | sed -n 's/^hidepid=//p' | tail -n1)"
    g="$(printf '%s' "$o" | tr ',' '\n' | sed -n 's/^gid=//p' | tail -n1)"
    case "$hp" in
        ""|0|off) PROC_STATE="no hidepid option on the /proc mount"; return 1 ;;
    esac
    if [ -n "$g" ] && id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
        PROC_STATE="mounted with hidepid=$hp, gid=$g, a group of this run (other users' processes readable)"; return 1
    fi
    case "$hp" in
        1|noaccess) PROC_STATE="mounted with hidepid=$hp${g:+ (gid=$g is not a group of this run)}: other users' /proc/<pid> entries listed but not readable" ;;
        *)          PROC_STATE="mounted with hidepid=$hp${g:+ (gid=$g is not a group of this run)}: other users' processes not listed" ;;
    esac
    return 0
}
PKG_FAIL=""          # a package-manifest query that failed or timed out
PKG_MANIFEST=""      # the rpm/dpkg file list of the package, when it answered
# _pkg_list TOOL ARGS... -> fills PKG_MANIFEST; a "not installed" answer is an
# answer, a timeout or any other failure goes to PKG_FAIL
_pkg_list() {
    local out rc err
    out="$(_bounded "$@" 2>"$(_tmp pkg.err)")"; rc=$?
    err="$(head -n1 "$(_tmp pkg.err)" 2>/dev/null | cut -c1-120)"
    if [ "$rc" -eq 0 ]; then PKG_MANIFEST="$out"; return 0; fi
    case "$out $err" in
        *"is not installed"*|*"not installed"*) return 1 ;;
    esac
    if [ "$rc" -eq 124 ]; then PKG_FAIL="${PKG_FAIL:+$PKG_FAIL; }$1 $2 timed out (${CMD_TIMEOUT}s)"
    else PKG_FAIL="${PKG_FAIL:+$PKG_FAIL; }$1 $2 exit $rc${err:+: $err}"; fi
    return 1
}
# _self_tree -> this collector's own pid and its ancestors, so the parent shell
# that ran "bash collect-nms.sh" (or a wrapper naming whatap-nms) is never
# counted as an nms process
_self_tree() {
    local p="$$" n=0
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$n" -lt 30 ]; do
        printf ' %s ' "$p"
        p="$(awk '/^PPid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"
        n=$((n + 1))
    done
}
discover_root() {
    # match a path whose component is the whatap-nms directory itself, and skip
    # documentation paths (/usr/share/doc/whatap-nms sorts before the real root
    # in the dpkg manifest — caught in live validation on Ubuntu 24.04)
    local p="" _mgrep='/whatap-nms\(/\|$\)' _d _a0 _self
    if have rpm; then
        PKG_SCAN="rpm"
        _pkg_list rpm -ql "$NMS_PKG" && p="$(printf '%s\n' "$PKG_MANIFEST" | grep -v '/doc/' | grep -m1 "$_mgrep")"
        [ -n "$p" ] && NMS_ROOT_SRC="rpm manifest"
    fi
    if [ -z "$p" ] && have dpkg; then
        PKG_SCAN="${PKG_SCAN:+$PKG_SCAN, }dpkg"
        _pkg_list dpkg -L "$NMS_PKG" && p="$(printf '%s\n' "$PKG_MANIFEST" | grep -v '/doc/' | grep -m1 "$_mgrep")"
        [ -n "$p" ] && NMS_ROOT_SRC="dpkg manifest"
    fi
    if [ -n "$p" ]; then
        # trim to the .../whatap-nms directory component
        NMS_ROOT="$(printf '%s\n' "$p" | sed 's#\(/whatap-nms\)/.*#\1#')"
        [ -d "$NMS_ROOT" ] || { NMS_ROOT=""; NMS_ROOT_SRC=""; }
    fi
    # process scan on the executable, not on any argument: argv[0] whose
    # basename is an nms binary, or an argv[0] under a .../whatap-nms/ tree
    # (the bundled venv python that runs uvicorn). "less .../whatap-nms/x.log"
    # names the path only as an argument and is not counted.
    _self="$(_self_tree)"
    # one pass, no fork per process: argv[0] is read with the read builtin up
    # to its NUL; /proc/<pid>/exe is read only for a relative interpreter
    # argv[0] (python3, uvicorn), whose executable may sit under the venv
    local _n=0 _via _exe
    for _d in /proc/[0-9]*; do
        _n=$((_n + 1))
        if [ $((_n % 200)) -eq 0 ] && _past_deadline; then PROC_SCAN_CUT="run deadline reached after $_n /proc entries"; break; fi
        case "$_self" in *" ${_d#/proc/} "*) continue ;; esac
        _a0=""
        IFS= read -r -d '' _a0 2>/dev/null < "$_d/cmdline"
        [ -n "$_a0" ] || continue
        _via="argv[0]"
        case "${_a0##*/}" in
            wtnms*|icmptcphealthd|icmphealthd) ;;
            *)  case "$_a0" in
                    */whatap-nms/*) ;;
                    /*) continue ;;
                    python*|uvicorn*|gunicorn*)
                        _exe="$(readlink "$_d/exe" 2>/dev/null)"
                        case "$_exe" in */whatap-nms/*) _a0="$_exe"; _via="/proc/<pid>/exe" ;; *) continue ;; esac ;;
                    *) continue ;;
                esac ;;
        esac
        NMS_PIDS="$NMS_PIDS ${_d#/proc/}"
        if [ -z "$NMS_ROOT" ]; then
            # a relative argv[0] is resolved through /proc/<pid>/exe when readable
            case "$_a0" in /*) ;; *) _exe="$(readlink "$_d/exe" 2>/dev/null)"; [ -n "$_exe" ] && { _a0="$_exe"; _via="/proc/<pid>/exe"; } ;; esac
            case "$_a0" in
                /*/whatap-nms/*)
                    p="${_a0%%/whatap-nms/*}/whatap-nms"
                    [ -d "$p" ] && { NMS_ROOT="$p"; NMS_ROOT_SRC="$_via of pid ${_d#/proc/}"; } ;;
            esac
        fi
    done
    NMS_PIDS="${NMS_PIDS# }"
    _proc_hidden && PROC_HIDDEN="$PROC_STATE"
    if [ -z "$NMS_ROOT" ] && [ -d /usr/share/whatap-nms ]; then
        NMS_ROOT=/usr/share/whatap-nms; NMS_ROOT_SRC="on-disk path"
    fi
}

NMS_UNITS="uvicorn nmscore icmptcphealthd icmphealthd"

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    goal install "NMS installation on disk"
    goal conf    "NMS configuration files"
    goal logs    "NMS logs"
    [ "$OPT_SNMP" = 1 ] && goal snmp "SNMP GET probe (--snmp)"

    # [1] capability preamble — pre-explains every downstream "command not found"
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "tools:"
    for t in systemctl journalctl ss netstat ip rpm dnf yum dpkg apt-cache apt-mark \
             wtinitset python3 pip3 snmpget snmpwalk timeout curl wget getenforce \
             timedatectl chronyc ntpstat; do
        if have "$t"; then printf '        %-14s present\n' "$t"
        else printf '        %-14s absent\n' "$t"; fi
    done
    discover_root
    # why the root is unknown, when the reason is a blocked input rather than
    # an empty one; install, conf and logs all rest on it
    ROOT_BLOCK=""
    if [ -z "$NMS_ROOT" ]; then
        if [ -n "$PKG_FAIL" ]; then ROOT_BLOCK="package manifest not read: $PKG_FAIL"
        elif [ -n "$NMS_PIDS" ]; then ROOT_BLOCK="nms processes seen (pids $NMS_PIDS) but no install root resolved from their argv[0], exe or a package manifest"
        elif [ -n "$PROC_HIDDEN" ]; then ROOT_BLOCK="no install root in ${PKG_SCAN:-any package manifest} or /usr/share/whatap-nms, and the process scan was incomplete (/proc $PROC_HIDDEN)$(_priv_hint)"
        elif [ -n "$PROC_SCAN_CUT" ]; then ROOT_BLOCK="no install root in ${PKG_SCAN:-any package manifest} or /usr/share/whatap-nms, and the process scan stopped early ($PROC_SCAN_CUT)"
        fi
    fi
    fact "/proc: ${PROC_STATE:-n/a (mountinfo not read)}"
    if [ -n "$NMS_ROOT" ]; then fact "nms install root (resolved): $NMS_ROOT (via $NMS_ROOT_SRC)"
    else fact "nms install root: n/a (no path from ${PKG_SCAN:-no package manifest (rpm, dpkg absent)}, no nms process argv[0] under a whatap-nms tree, /usr/share/whatap-nms not present)"; fi
    [ -n "$PKG_FAIL" ] && fact "package manifest query: n/a ($PKG_FAIL)"

    # [2] host & platform — asked as "OS 종류와" in field sessions (2026-01-20)
    section "A. Host & platform"
    probe "hostname" hostname
    read_proc "os-release" /etc/os-release
    probe "kernel" uname -smr
    probe "cpu count" nproc
    if [ -r /proc/meminfo ]; then
        fact "memory: $(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d MB total, %d MB available", t/1024, a/1024}' /proc/meminfo 2>/dev/null)"
    else
        fact "memory: n/a (path not found: /proc/meminfo)"
    fi
    probe "virtualization" systemd-detect-virt
    probe "selinux" getenforce

    # [3] time & clock — the backend rejects packs as "future data" when the
    # manager host clock drifts (observed delta ~3157s, 2026-06-18)
    section "B. Time & clock synchronization"
    fact "host clock (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    probe "timedatectl" timedatectl
    probe "chrony tracking" chronyc tracking
    probe "ntpstat" ntpstat

    # [4] python runtime — "python버전 알려주세요" (2026-01-20); the rpm %post
    # builds a venv with the system python and needs >= 3.9 (2026-07-02)
    section "C. Python runtime"
    probe_merged "python3 --version" python3 --version
    if have python3; then
        fact "python3 resolves to: $(readlink -f "$(command -v python3)" 2>/dev/null || command -v python3)"
    fi
    fact "python3* binaries on PATH dirs (/usr/bin, /usr/local/bin):"
    ls -1 /usr/bin/python3* /usr/local/bin/python3* 2>/dev/null | while IFS= read -r _p; do
        printf '        %s\n' "$_p"
    done
    [ -z "$(ls -1 /usr/bin/python3* /usr/local/bin/python3* 2>/dev/null)" ] && fact "    (none found)"
    probe_merged "pip3 --version" pip3 --version

    # [5] package & repository — exclude= lines and a repo missing the package
    # are both field-observed causes of "whatap-nms not found" (2026-06-04 / 07-02).
    # Both official install paths are covered: rpm/dnf (RHEL family) and
    # dpkg/apt (Debian family) — docs.whatap.io/nms/install-agent.
    section "D. Package & repository"
    if have rpm; then
        probe "rpm -qi $NMS_PKG" rpm -qi "$NMS_PKG"
    elif have dpkg; then
        probe "dpkg -s $NMS_PKG" dpkg -s "$NMS_PKG"
    else
        fact "installed package: n/a (command not found: rpm, dpkg)"
    fi
    subsection "whatap repo definitions"
    local _found_repo=0 _rf
    for _rf in /etc/yum.repos.d/*.repo; do
        [ -e "$_rf" ] || continue
        if grep -qi whatap "$_rf" 2>/dev/null; then
            _found_repo=1
            fact "$_rf ($(file_meta "$_rf")):"
            tail_file "$_rf" 40
        fi
    done
    for _rf in /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
        [ -e "$_rf" ] || continue
        if grep -qi whatap "$_rf" 2>/dev/null; then
            _found_repo=1
            fact "$_rf ($(file_meta "$_rf")):"
            tail_file "$_rf" 40
        fi
    done
    [ "$_found_repo" = 0 ] && fact "no yum/apt repo definition mentions whatap (/etc/yum.repos.d, /etc/apt/sources.list*)"
    subsection "repo signing key on disk"
    if [ -e /etc/apt/trusted.gpg.d/whatap-release.gpg ]; then
        fact "/etc/apt/trusted.gpg.d/whatap-release.gpg: present ($(file_meta /etc/apt/trusted.gpg.d/whatap-release.gpg))"
    elif have rpm; then
        probe "rpm gpg-pubkey packages" sh -c 'rpm -q gpg-pubkey --qf "%{NAME}-%{VERSION}-%{RELEASE} %{SUMMARY}\n" 2>/dev/null | grep -i whatap; :'
    else
        fact "n/a (no apt key file at /etc/apt/trusted.gpg.d/whatap-release.gpg and command not found: rpm)"
    fi
    subsection "package-manager exclude / hold directives"
    probe "exclude lines (/etc/dnf/dnf.conf, /etc/yum.conf)" sh -c 'grep -Hn "^[[:space:]]*exclude" /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null; :'
    if have apt-mark; then
        probe "apt-mark showhold" sh -c 'apt-mark showhold 2>/dev/null; :'
    fi
    subsection "whatap packages visible to the package manager"
    if have dnf; then
        probe "dnf list available (whatap repos only)" dnf -q --disablerepo="*" --enablerepo="whatap*" list available --showduplicates
        probe "dnf list installed whatap*" dnf -q list installed "whatap*"
    elif have yum; then
        probe "yum list available (whatap repos only)" yum -q --disablerepo="*" --enablerepo="whatap*" list available
        probe "yum list installed whatap*" yum -q list installed "whatap*"
    elif have apt-cache; then
        probe "apt-cache policy $NMS_PKG" apt-cache policy "$NMS_PKG"
    else
        fact "n/a (command not found: dnf, yum, apt-cache)"
    fi
    # install/upgrade attempts and their outcomes stay on record even after a
    # failed or purged install — the package-manager logs are the durable trace
    # of a broken post-install step (bounded greps, current + one rotation)
    subsection "package install/upgrade history ($NMS_PKG)"
    if have dnf; then
        probe "dnf history" dnf -q history list "$NMS_PKG"
    fi
    probe "dpkg.log entries (last 20)" sh -c 'grep -h "whatap-nms" /var/log/dpkg.log /var/log/dpkg.log.1 2>/dev/null | tail -n 20; :'
    probe "apt history entries (last 30 lines)" sh -c 'grep -h -B2 -A4 "whatap-nms" /var/log/apt/history.log 2>/dev/null | tail -n 30; :'

    # [6] deployment layout — venv/wheelhouse state is where rpm %post pip
    # installs break (bcrypt case, 2025-05-30)
    section "E. Deployment layout (on-disk)"
    if [ -n "$NMS_ROOT" ]; then
        fact "root: $NMS_ROOT"
        subsection "top-level entries (shallow listing only)"
        probe "ls" ls -la "$NMS_ROOT"
        subsection "bundled virtualenv"
        if [ -x "$NMS_ROOT/vpyenv/bin/python3" ]; then
            probe_merged "vpyenv python" "$NMS_ROOT/vpyenv/bin/python3" --version
            probe_merged "vpyenv pip" "$NMS_ROOT/vpyenv/bin/python3" -m pip --version
        else
            fact "vpyenv/bin/python3: n/a (path not found: $NMS_ROOT/vpyenv/bin/python3)"
        fi
        if [ -d "$NMS_ROOT/whlhouse" ]; then
            fact "whlhouse wheel count: $(ls -1 "$NMS_ROOT"/whlhouse/*.whl 2>/dev/null | wc -l | tr -d ' ')"
        else
            fact "whlhouse: n/a (path not found: $NMS_ROOT/whlhouse)"
        fi
        subsection "requirements files"
        local _req _any_req=0
        for _req in "$NMS_ROOT"/requirements*; do
            [ -e "$_req" ] || continue
            _any_req=1
            fact "$_req: $(wc -l < "$_req" 2>/dev/null | tr -d ' ') lines, $(file_meta "$_req")"
        done
        [ "$_any_req" = 0 ] && fact "no requirements* file directly under $NMS_ROOT"
        subsection "filesystem free space at root"
        probe "df" df -h "$NMS_ROOT"
    else
        fact "n/a (install root not resolved)"
    fi

    # [7] runtime services & processes — the three units and their start order
    # (uvicorn -> nmscore -> icmptcphealthd) are the standard field checklist
    # (2026-01-09); icmphealthd is the pre-rename unit (<= v0.42.x era)
    section "F. Runtime services & processes"
    if have systemctl; then
        local _u _ls
        for _u in $NMS_UNITS; do
            _ls="$(sd_show LoadState "$_u")"
            if [ "$_ls" = "loaded" ]; then
                fact "$_u.service: active=$(_bounded systemctl is-active "$_u.service" 2>/dev/null) enabled=$(_bounded systemctl is-enabled "$_u.service" 2>/dev/null) restarts=$(sd_show NRestarts "$_u")"
                fact "    since: $(sd_show ActiveEnterTimestamp "$_u")"
                fact "    unit file: $(sd_show FragmentPath "$_u")"
                fact "    ExecStart: $(sd_show ExecStart "$_u" | cut -c1-200)"
            else
                fact "$_u.service: n/a (LoadState=${_ls:-unknown})"
            fi
        done
    else
        fact "systemd: n/a (command not found: systemctl)"
    fi
    subsection "nms-related processes (/proc scan of argv[0]: wtnms* / icmptcphealthd / icmphealthd / under a whatap-nms tree)"
    if [ -n "$NMS_PIDS" ]; then
        local _pid
        for _pid in $NMS_PIDS; do
            if have ps; then probe "pid $_pid" ps -o pid=,ppid=,user=,rss=,etime=,args= -p "$_pid"
            else fact "pid $_pid: $(tr '\0' ' ' 2>/dev/null < "/proc/$_pid/cmdline" | cut -c1-200)"; fi
        done
    elif [ -n "$PROC_HIDDEN" ]; then
        fact "no matching process visible ($PROC_HIDDEN)"
    else
        fact "no matching process in the /proc scan"
    fi

    # [8] network endpoints — UDP 514 (syslog) is shared territory: a co-located
    # WhaTap collection server binds it first and the manager then cannot
    # (2025-07-15); 162/udp is trap intake, 5000/tcp the manager UI
    section "G. Network endpoints"
    subsection "listening TCP sockets"
    if have ss; then probe "ss -ltnp" sh -c "ss -ltnp 2>/dev/null | head -n 40"
    elif have netstat; then probe "netstat -ltnp" sh -c "netstat -ltnp 2>/dev/null | head -n 40"
    else read_proc "/proc/net/tcp (raw, LISTEN rows are state 0A)" /proc/net/tcp; fi
    subsection "listening UDP sockets"
    if have ss; then probe "ss -lunp" sh -c "ss -lunp 2>/dev/null | head -n 40"
    elif have netstat; then probe "netstat -lunp" sh -c "netstat -lunp 2>/dev/null | head -n 40"
    else read_proc "/proc/net/udp (raw)" /proc/net/udp; fi
    subsection "ports of record (channel cases + docs: 161/162/514/1514/5000/5141/6600/8443)"
    if have ss; then
        probe "matching sockets" sh -c "ss -ltnup 2>/dev/null | awk '/:(161|162|514|1514|5000|5141|6600|8443)([[:space:]]|\$)/'; :"
    elif have netstat; then
        probe "matching sockets" sh -c "netstat -ltnup 2>/dev/null | awk '/:(161|162|514|1514|5000|5141|6600|8443)([[:space:]]|\$)/'; :"
    else
        fact "n/a (command not found: ss, netstat)"
    fi
    subsection "outbound connections of nms processes (manager -> WhaTap server)"
    if have ss; then
        probe "established (wtnms*)" sh -c "ss -tnp state established 2>/dev/null | grep -E 'wtnms|icmptcphealthd|uvicorn' | head -n 20; :"
        # ss -p names another user's socket owner only to root; a non-root
        # run lists every :6600 session and says the owner is not visible
        if [ "$(id -u 2>/dev/null)" != 0 ]; then
            probe "established to :6600 (owner not visible to uid $(id -u 2>/dev/null))" sh -c "ss -tn state established 2>/dev/null | awk '\$3 ~ /:6600\$/ || \$4 ~ /:6600\$/ || \$5 ~ /:6600\$/' | head -n 10; :"
        elif [ -n "$NMS_PIDS" ]; then
            probe "established to :6600 by nms pids ($NMS_PIDS)" sh -c "ss -tnp state established 2>/dev/null | awk '\$4 ~ /:6600\$/ || \$5 ~ /:6600\$/' | grep -E 'pid=($(printf '%s' "$NMS_PIDS" | tr ' ' '|')),' | head -n 10; :"
        else
            fact "established to :6600 by nms pids: n/a (no nms process found)"
        fi
    else
        fact "n/a (command not found: ss)"
    fi
    subsection "name resolution / routing / proxy"
    probe "resolv.conf (comment lines omitted)" sh -c 'grep -Ev "^[[:space:]]*(#|$)" /etc/resolv.conf; :'
    probe "default route" sh -c "ip route show default 2>/dev/null | head -n 3"
    probe "proxy variables in current environment" sh -c "env | grep -i proxy; :"
    probe "proxy variables in /etc/environment" sh -c 'grep -i proxy /etc/environment 2>/dev/null; :'

    # [9] outbound reachability — closed networks break the rpm %post pip step
    # ("ResolutionImpossible", 2026-06-09); two bounded HEAD requests, 5s cap each
    section "H. Outbound reachability (2 bounded HEAD requests, 5s cap each)"
    local _url
    for _url in https://repo.whatap.io https://pypi.org; do
        if have curl; then
            curl_reach "$_url"
        elif have wget; then
            probe "$_url" sh -c "wget -q --spider -T 5 -t 1 $_url && echo reachable"
        else
            fact "$_url: n/a (command not found: curl, wget)"
        fi
    done

    # [10] configuration — nmscore.conf keys named in past cases:
    # MAX_REPETITIONS, IFX_32BIT_PPS_FALLBACK, ssl settings, syslog port.
    # wtinitset is the official configuration tool (docs.whatap.io/nms/
    # install-agent): -a sets the access key, -s the WhaTap server IP
    # (multi-IP "a/b" form exists), -v prints the current configuration.
    section "I. Configuration (verbatim)"
    subsection "wtinitset -v"
    probe_merged "wtinitset -v" wtinitset -v
    subsection "discovered *.conf files"
    local _cfgs="" _cf
    # the package manifest already read in discovery (rpm or dpkg)
    _cfgs="$(printf '%s\n' "$PKG_MANIFEST" | grep '\.conf$' | head -n 20)"
    if [ -n "$NMS_ROOT" ]; then
        # etc/nmscore.conf is the documented location (FAQ: vi /usr/share/whatap-nms/etc/nmscore.conf);
        # etc/mibmods.toml is the MIB module registry (live-install observation)
        _cfgs="$(printf '%s\n%s\n%s\n%s\n%s\n' "$_cfgs" \
            "$(ls -1 "$NMS_ROOT"/*.conf 2>/dev/null)" \
            "$(ls -1 "$NMS_ROOT"/etc/*.conf 2>/dev/null)" \
            "$(ls -1 "$NMS_ROOT"/etc/*.toml 2>/dev/null)" \
            "$(ls -1 "$NMS_ROOT"/conf/*.conf 2>/dev/null)")"
    fi
    _cfgs="$(printf '%s\n' "$_cfgs" "$(ls -1 /etc/whatap-nms/*.conf 2>/dev/null)" | grep -v '^$' | sort -u)"
    # the conf goal: every discovered file read, and the dirs searched readable
    local _cf_bad="" _cf_n=0 _cfd
    while IFS= read -r _cf; do
        [ -n "$_cf" ] && [ -e "$_cf" ] || continue
        _cf_n=$((_cf_n + 1))
        [ -r "$_cf" ] || _cf_bad="$_cf_bad $_cf"
    done <<EOF
$_cfgs
EOF
    for _cfd in /etc/whatap-nms ${NMS_ROOT:+"$NMS_ROOT" "$NMS_ROOT/etc" "$NMS_ROOT/conf"}; do
        [ -d "$_cfd" ] || continue
        { [ -r "$_cfd" ] && [ -x "$_cfd" ]; } || _cf_bad="$_cf_bad $_cfd/"
    done
    [ -n "$_cf_bad" ] && fact "not readable (permission denied):$_cf_bad"
    if [ -n "$PKG_FAIL" ] && [ "$_cf_n" -eq 0 ]; then missed conf "package manifest not read: $PKG_FAIL"
    elif [ -n "$_cf_bad" ]; then missed conf "permission denied:$_cf_bad$(_priv_hint)"
    elif [ "$_cf_n" -gt 0 ]; then got conf
    elif [ -n "$NMS_ROOT" ]; then missed conf "install root $NMS_ROOT resolved, no *.conf found under it, its etc/ or /etc/whatap-nms"
    elif [ -n "$ROOT_BLOCK" ]; then missed conf "no install root resolved ($ROOT_BLOCK)"
    else na conf "no install root resolved; no *.conf in /etc/whatap-nms"; fi
    if [ -n "$_cfgs" ]; then
        printf '%s\n' "$_cfgs" | while IFS= read -r _cf; do
            [ -e "$_cf" ] || { fact "$_cf: n/a (listed in package manifest, path not found on disk)"; continue; }
            fact "$_cf ($(file_meta "$_cf")):"
            dump_file "$_cf" 400
        done
        # keys of record, extracted flat in case a dump above hit its line cap:
        # MANAGER_WEB_PORT / MANAGER_HTTPS_* (UI port is configurable — FAQ),
        # MAX_REPETITIONS, IFX_32BIT_PPS_FALLBACK (named in past cases)
        subsection "keys of record across discovered conf files"
        probe "grep" sh -c "printf '%s\n' \"$_cfgs\" | while IFS= read -r f; do [ -e \"\$f\" ] && grep -HnE '^[[:space:]]*(MANAGER_WEB_PORT|MANAGER_HTTPS_ENABLED|MANAGER_HTTPS_WEB_PORT|MAX_REPETITIONS|IFX_32BIT_PPS_FALLBACK)' \"\$f\"; done; :"
    else
        if [ -n "$_cf_bad" ]; then fact "no *.conf read (see the not-readable entries above)"
        else fact "no *.conf discovered via package manifest, install root, or /etc/whatap-nms"; fi
    fi

    # [11] logs & events — pkg-install-error.log is the first artifact support
    # asks for on an install failure (2026-06-09); /var/log/nmscore/nmscore.log
    # is the artifact the FAQ names for MIB module-load and engine issues
    section "J. Logs & recent events"
    local _logdir=/var/log/whatap-nms _lg_bad="" _lg_n=0 _lgd _lgf
    for _lgd in /var/log/whatap-nms /var/log/nmscore; do
        [ -d "$_lgd" ] || continue
        if [ ! -r "$_lgd" ] || [ ! -x "$_lgd" ]; then _lg_bad="$_lg_bad $_lgd/"; continue; fi
        for _lgf in "$_lgd"/*.log; do
            [ -e "$_lgf" ] || continue
            _lg_n=$((_lg_n + 1))
            [ -r "$_lgf" ] || _lg_bad="$_lg_bad $_lgf"
        done
    done
    if [ -n "$_lg_bad" ]; then missed logs "permission denied:$_lg_bad$(_priv_hint)"
    elif [ "$_lg_n" -gt 0 ]; then got logs
    elif [ -n "$ROOT_BLOCK" ]; then missed logs "no *.log read, and the install was not resolved ($ROOT_BLOCK)"
    elif [ -n "$NMS_ROOT" ] || [ -n "$NMS_PIDS" ]; then na logs "no *.log in /var/log/whatap-nms or /var/log/nmscore (absent, or read and empty)"
    else na logs "no install root or nms process; /var/log/whatap-nms and /var/log/nmscore absent or empty"; fi
    if [ -d "$_logdir" ] && { [ ! -r "$_logdir" ] || [ ! -x "$_logdir" ]; }; then
        fact "$_logdir: n/a (permission denied)"
    elif [ -d "$_logdir" ]; then
        subsection "log inventory ($_logdir)"
        probe "ls" ls -la "$_logdir"
        subsection "pkg-install-error.log (last 60 lines)"
        tail_file "$_logdir/pkg-install-error.log" 60
        subsection "other *.log tails (last 25 lines each, first 8 files)"
        local _lf _cnt=0
        for _lf in "$_logdir"/*.log; do
            [ -e "$_lf" ] || continue
            [ "$_lf" = "$_logdir/pkg-install-error.log" ] && continue
            _cnt=$((_cnt + 1))
            [ "$_cnt" -gt 8 ] && { fact "(further *.log files not tailed: cap 8)"; break; }
            fact "$_lf ($(file_meta "$_lf")):"
            tail_file "$_lf" 25
        done
        [ "$_cnt" = 0 ] && fact "no additional *.log file in $_logdir"
    else
        fact "$_logdir: n/a (path not found)"
    fi
    local _coredir=/var/log/nmscore
    if [ -d "$_coredir" ] && { [ ! -r "$_coredir" ] || [ ! -x "$_coredir" ]; }; then
        fact "$_coredir: n/a (permission denied)"
    elif [ -d "$_coredir" ]; then
        subsection "nms engine log inventory ($_coredir)"
        probe "ls" ls -la "$_coredir"
        subsection "nmscore.log (last 80 lines)"
        tail_file "$_coredir/nmscore.log" 80
    else
        fact "$_coredir: n/a (path not found)"
    fi
    if have journalctl; then
        local _u2 _ls2
        for _u2 in $NMS_UNITS; do
            _ls2="$(sd_show LoadState "$_u2")"
            [ "$_ls2" = "loaded" ] || continue
            subsection "journal: $_u2.service (last 60 lines)"
            probe "journalctl" journalctl -u "$_u2.service" -n 60 --no-pager -q
        done
    else
        fact "journalctl: n/a (command not found: journalctl)"
    fi

    # [12] Tier 2 — timed SNMP probe (opt-in). Field debugging showed the answer
    # AND its arrival time both matter: a device answering in ~2-3s against a
    # manager first-response timeout of ~3s collects nothing, while no answer at
    # all points at device-side SNMP policy / filtering (2025-07-03 session).
    if [ "$OPT_SNMP" = 1 ]; then
        section "K. SNMP probe (opt-in) — target $SNMP_HOST:$SNMP_PORT, SNMPv2c"
        if have snmpget; then
            local _oid _name _t0 _t1 _out _rc _snmpdir _okn=0 _fails=""
            # the community string reaches snmpget through a mode-600 snmp.conf
            # in the run's private directory, never through its command line
            _snmpdir="$(_tmp snmpconf)"
            # net-snmp reads SNMPCONFPATH instead of its default search path,
            # so the default path (system snmp.conf) is kept in front and the
            # private file comes last, where its values win. "mibs :" loads no
            # MIB module: numeric OIDs are asked, and a host without MIB files
            # does not bury the reply under "Cannot find module" lines
            local _snmpdef
            _snmpdef="$(_bounded net-snmp-config --snmpconfpath 2>/dev/null)"
            [ -n "$_snmpdef" ] || _snmpdef="/etc/snmp:/usr/share/snmp:/usr/local/etc/snmp:/usr/local/share/snmp:${HOME:-/nonexistent}/.snmp"
            case "$SNMP_COMM" in
                *[[:space:]\#\"\']*|"")
                    fact "n/a (community string is empty or holds whitespace, '#' or a quote; snmp.conf cannot carry it)"
                    warn "--snmp: community string is empty or holds whitespace, '#' or a quote; SNMP probe not sent"
                    missed snmp "community string not usable in snmp.conf (empty, whitespace, '#' or a quote)"
                    _snmpdir="" ;;
            esac
            if [ -z "$_snmpdir" ]; then :
            elif mkdir -m 700 "$_snmpdir" 2>/dev/null \
                && ( umask 077; printf 'defVersion 2c\ndefCommunity %s\nmibs :\n' "$SNMP_COMM" > "$_snmpdir/snmp.conf" ) 2>/dev/null; then
                for _oid in "sysDescr.0=1.3.6.1.2.1.1.1.0" "sysUpTime.0=1.3.6.1.2.1.1.3.0" "ifNumber.0=1.3.6.1.2.1.2.1.0"; do
                    _name="${_oid%%=*}"
                    warn "sending 1 SNMP GET ($_name) to $SNMP_HOST:$SNMP_PORT"
                    _t0="$(now_s)"
                    _out="$(SNMPCONFPATH="$_snmpdef:$_snmpdir" CMD_TIMEOUT=15 _bounded snmpget -t 10 -r 0 "$SNMP_HOST:$SNMP_PORT" "${_oid#*=}" 2>&1)"; _rc=$?
                    _t1="$(now_s)"
                    fact "$_name: rc=$_rc elapsed=$(elapsed_s "$_t0" "$_t1")s"
                    if [ -n "$_out" ]; then _emit_labeled "    reply" "$(printf '%s\n' "$_out" | grep -v '^$' | head -n 5 | cut -c1-160)"
                    else fact "    reply: (no output)"; fi
                    if [ "$_rc" -eq 0 ]; then _okn=$((_okn + 1)); else _fails="$_fails $_name(rc=$_rc)"; fi
                done
                if [ "$_okn" -eq 3 ]; then got snmp
                else missed snmp "SNMP GET without a reply:$_fails"; fi
            else
                fact "n/a (snmp.conf could not be written in the run's private directory)"
                missed snmp "snmp.conf could not be written in the run's private directory"
            fi
        else
            fact "n/a (command not found: snmpget)"
            missed snmp "command not found: snmpget"
        fi
    fi

    if [ -n "$NMS_ROOT" ]; then got install
    elif [ -n "$ROOT_BLOCK" ]; then missed install "$ROOT_BLOCK"
    else na install "no whatap-nms path in ${PKG_SCAN:-any package manifest (rpm, dpkg absent)}, no nms process in the /proc scan, /usr/share/whatap-nms not present"; fi

    emit_status
    emit_footer
}

# ---- main ----------------------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

if [ "$OPT_SNMP" = 1 ]; then
    case "$SNMP_COMM" in
        *[[:space:]\#\"\']*|"") ;;   # rejected in section K, nothing is sent
        *) warn "Tier 2 --snmp enabled: this run sends 3 SNMP GET requests to $SNMP_HOST:$SNMP_PORT (single GETs, no walk)." ;;
    esac
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
