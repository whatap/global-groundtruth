#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM Node.js agent collector
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap Node.js-agent developer repeatedly
# asks a field engineer for, from the host or container where a Node.js
# application (and the whatap npm package) runs. Derived from an exhaustive
# review of #ask-dev-apm Node.js support threads (2025-06 .. 2026-08), the
# `whatap` npm package source (2.0.6 latest + 0.5.27 legacy), docs.whatap.io,
# and the operator apm-init-nodejs image (1.0.1).
#
# Recurring field questions this report answers with facts:
#   * Which whatap package version is installed where? (0.5.x and 1.x/2.x have
#     different architectures: 0.5.x sends TCP directly from the app process;
#     1.x/2.x spawn a native master agent process `whatap_nodejs` and talk to
#     it over local UDP, and the master opens the TCP session to the server.)
#   * Where is WHATAP_HOME / whatap.conf, and what does it actually contain —
#     including byte-level facts (size, CR bytes) that plain `cat` hides?
#   * Is the `whatap_nodejs` master agent process running, from which home,
#     spawned by which app (env NODEJS_PARENT_APP_PID)?
#   * How is the app launched (node -r whatap? pm2? next-server?) and which
#     WHATAP_* / NODE_OPTIONS variables reached the process?
#   * pid / lock / port-registry files: agent-<id>.pid, whatap_nodejs.pid[.llm],
#     whatap_port_<pid>, /tmp/whatap-nodejs.lock.
#   * Agent logs: logs/whatap-hook-YYYYMMDD.log (2.x), logs/whatap-YYYYMMDD.log
#     (0.5.x), whatap-boot-* (master agent side) — and which WHATAP-NNN codes
#     appear in the recent lines.
#   * Kubernetes/operator artifacts: /whatap-agent volume seeded by
#     apm-init-nodejs, WHATAP_NODEJS_AGENT_PATH, container.conf.
#   * When the install is healthy but no transactions appear: which modules
#     the installed agent can hook (lib/observers, section 3), which
#     libraries the app declares and has installed (package.json deps +
#     node_modules names, section 8), and which observers actually engaged
#     in this process (hook-log observer lines, section 7).
#
# THE CONTRACT (../../../CONTRACT.md):
#   1. Facts only. No conclusion is stated on any emitted line.
#   2. Discover, never assume. Resolve symlinks, process args, env, config.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned. Seed v0 by the Global team; ownership transfers to
#      the APM/Node.js agent developers.
#
# DESIGN GUIDELINES (../../../docs/collector-engineering.md): MECE sections,
# Tier-0 load-safe defaults (bounded reads, no whole-log grep), bash 3.2+ and
# POSIX-sh compatible (dash/busybox ash), reasoned absence for every missing
# value. The Node.js interpreter is only ever executed as `node --version`;
# the whatap module itself is never loaded (requiring it starts an agent).
#
# NOTE: no `set -e` — a collector must reach its footer even when every probe
# fails. Failures are handled locally by the helpers.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmnodejs"
# 0.6.0  Less work per node process: _env_pick settles an absent name with one
#        match and splits the environ with IFS instead of a read loop, NODE_PATH
#        is split in the shell, the cwd each process resolved in discovery is
#        reused by the report, and the detail list reads each environ once.
#        The report is unchanged; 8.4 s -> 4.9 s on a host with 168 node
#        processes, 18.3 s -> 9.5 s with 300 more (2026-09-25).
VERSION="0.6.0"
DOMAIN="apm"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Collects Node.js APM agent facts from the host or container where the Node.js
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
# never masked (see collectors/apm/nodejs/README.md, "What the report can contain").
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

# conf_bytes "label" PATH -> byte-level facts about a config file that plain
# `cat` hides: total bytes and CR (\r, 0x0D) byte count. Windows-edited conf
# files reach Linux hosts through support cases; the reader compares these
# numbers against the dumped text.
conf_bytes() {
    local label="$1" path="$2" sz cr
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
    cr="$(tr -dc '\r' < "$path" 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}

# ndprobe "label" NODE_EXE [ARGS...] -> run the node binary under _bounded.
# Only ever used with --version; the whatap module is never loaded (a
# require('whatap') starts an agent — the opposite of read-only collection).
ndprobe() {
    local label="$1" nd="$2"; shift 2
    [ -x "$nd" ] || { fact "$label: n/a (not executable: $nd)"; return; }
    probe "$label" "$nd" "$@"
}

# pkg_json_field "FIELD" PATH -> first "FIELD": "value" from a package.json,
# read as text (no interpreter execution).
pkg_json_field() {
    local field="$1" path="$2"
    grep -m1 "\"$field\"" "$path" 2>/dev/null | sed 's/^[[:space:]]*//; s/,[[:space:]]*$//'
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
#   D_NODE_EXES  distinct node binary paths, newline-joined (running processes + PATH)
#   D_GO_PIDS    pids of the master agent (comm: whatap_nodejs)
#   D_APP_PIDS   pids of node processes (by comm, argv0 or exe), whatap-marked first
#   D_PM2_PIDS   pids of pm2 daemons (by command line)
#   D_HOMES      distinct WHATAP_HOME candidates with their discovery source
#   D_PKG_DIRS   distinct node_modules/whatap package dirs (symlink-resolved)
#   D_CONF_NAMES distinct conf file names ("whatap.conf" + WHATAP_CONF values)
#   D_UNREAD     pids of candidate processes whose environ or cwd this uid could
#                not read (their WHATAP_HOME is unknown, not absent)
#   D_HIDEPID    non-empty when /proc hides other users' processes from this uid
D_NODE_EXES=""
D_GO_PIDS=""
D_APP_PIDS=""
D_PM2_PIDS=""
D_HOMES=""          # newline-joined "path|source" records
D_PKG_DIRS=""       # newline-joined "dir|source" records
D_CONF_NAMES="whatap.conf"
D_UNREAD=""
D_HIDEPID=""
D_NPM_ROOT=""       # `npm root -g`, run once
D_LOCK_FILE="${WHATAP_LOCK_FILE:-/tmp/whatap-nodejs.lock}"

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
    for pid in $D_GO_PIDS $D_APP_PIDS; do
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
_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$p" in *"$_nl"*|*"|"*) D_ODD="$D_ODD \"$(_quote_nl "$p")\"" D_ODD_HOME=1; return ;; esac
    case "$_nl$D_HOMES" in *"$_nl$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES$_nl$p|$s"; else D_HOMES="$p|$s"; fi
}

_add_pkg_dir() {  # _add_pkg_dir DIR SOURCE  (dedup on the resolved dir)
    local d="$1" s="$2" r
    [ -n "$d" ] || return
    r="$(readlink -f "$d" 2>/dev/null || echo "$d")"
    case "$r" in *"$_nl"*|*"|"*) D_ODD="$D_ODD \"$(_quote_nl "$r")\""; return ;; esac
    case "$_nl$D_PKG_DIRS" in *"$_nl$r|"*) return ;; esac
    if [ -n "$D_PKG_DIRS" ]; then D_PKG_DIRS="$D_PKG_DIRS$_nl$r|$s"; else D_PKG_DIRS="$r|$s"; fi
}

_add_conf_name() {
    local n="$1"
    [ -n "$n" ] || return
    case "$_nl$D_CONF_NAMES$_nl" in *"$_nl$n$_nl"*) return ;; esac
    D_CONF_NAMES="$D_CONF_NAMES$_nl$n"
}

# Dedup key for node binaries: the resolved target (nvm/asdf install one
# binary per version; unlike python virtualenvs, node module resolution does
# not depend on the invocation path, so collapsing to the target is correct).
D_NODE_KEYS=""
_add_node() {
    local p="$1" k
    [ -n "$p" ] || return
    [ -x "$p" ] || return
    # /proc/<pid>/exe targets are already resolved: skip the readlink for them
    case "$D_NODE_KEYS" in *"$_nl$p$_nl"*) return ;; esac
    k="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_NODE_KEYS" in *"$_nl$k$_nl"*) return ;; esac
    D_NODE_KEYS="$D_NODE_KEYS$_nl$k$_nl"
    if [ -n "$D_NODE_EXES" ]; then D_NODE_EXES="$D_NODE_EXES$_nl$p"; else D_NODE_EXES="$p"; fi
}

# _is_node NAME -> success when NAME is a node binary's file name
_is_node() { case "$1" in node|nodejs|node[0-9]*) return 0 ;; esac; return 1; }

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
# which costs a builtin call per line; ${v#*X} cuts are no cheaper, as they
# rescan the string for each position.
_ev_WHATAP_HOME="" _ev_WHATAP_CONF_DIR="" _ev_WHATAP_CONF="" _ev_NODE_OPTIONS="" _ev_NODE_PATH=""
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

# _cwd_of PID -> _cw = the cwd discovery resolved for a node PID ("" when it
# could not be read), so the report does not fork a readlink per process again
_cw=""
_cwd_of() { eval "_cw=\${_cw_$1:-}"; }

# _proc_env PID NAME -> value of NAME= in the process environ (empty if none)
_proc_env() {
    { tr '\0' '\n' < "/proc/$1/environ" | grep "^$2=" | head -n1 | cut -d= -f2- ; } 2>/dev/null
}

# _app_root_markers DIR -> success if DIR looks like an app root that carries
# whatap artifacts (conf, package dir, or a copied master agent binary)
_app_root_markers() {
    local d="$1"
    [ -n "$d" ] || return 1
    [ -f "$d/whatap.conf" ] && return 0
    [ -e "$d/node_modules/whatap" ] && return 0
    [ -e "$d/whatap_nodejs" ] && return 0
    return 1
}

discover() {
    progress "discovery: node processes, master agents, homes, package dirs"
    local pid comm exe a0 cmd cwd v _nd _mk _am="" _ar="" _ndm="" _ndr="" _d
    _env=""

    case "$(id -u 2>/dev/null)" in
        0) ;;
        *) grep -qE '^[^ ]+ /proc proc [^ ]*hidepid=([12]|invisible|noaccess)' /proc/mounts 2>/dev/null \
               && D_HIDEPID="hidepid is set on /proc: other users' processes are not listed to uid $(id -u 2>/dev/null)" ;;
    esac

    # Process scan. node processes may not be named "node": pm2 and
    # next-server rename the process title, so comm, argv0 and the resolved
    # binary each decide. The table is read once for every pid; environ and
    # cwd are read only for the matches.
    while IFS="$_us" read -r pid comm exe a0 cmd; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$$" ] && continue
        case "$comm" in whatap_nodejs*) D_GO_PIDS="$D_GO_PIDS $pid"; continue ;; esac
        case "$cmd" in *"PM2"*"God Daemon"*|*"pm2"*[Dd]"aemon"*) D_PM2_PIDS="$D_PM2_PIDS $pid" ;; esac
        _nd=0
        case "$comm" in node*|next-server*|PM2*) _nd=1 ;; esac
        _is_node "${a0##*/}" && _nd=1
        _is_node "${exe##*/}" && _nd=1
        [ "$_nd" = 1 ] || continue
        # whatap markers (cmdline, env, cwd install) put a process ahead of
        # unrelated node processes (IDE helpers, build daemons) in the detail cap
        _mk=0
        case "$cmd" in *whatap*) _mk=1 ;; esac
        if _read_proc_env "$pid"; then
            _env_pick WHATAP_HOME WHATAP_CONF_DIR WHATAP_CONF NODE_OPTIONS NODE_PATH
            [ -n "$_ev_WHATAP_HOME" ] && _home_from_pid "$pid" "$_ev_WHATAP_HOME" "environ of node pid $pid"
            [ -n "$_ev_WHATAP_CONF_DIR" ] && _home_from_pid "$pid" "$_ev_WHATAP_CONF_DIR" "environ WHATAP_CONF_DIR of node pid $pid"
            [ -n "$_ev_WHATAP_CONF" ] && _add_conf_name "$_ev_WHATAP_CONF"
            case "$_nl$_env" in *"${_nl}WHATAP_"*) _mk=1 ;; esac
            case "$_ev_NODE_OPTIONS" in *whatap*) _mk=1 ;; esac
            # package dirs referenced by NODE_PATH
            # split on ':' (and newline) in this shell, globbing off
            v="$_ev_NODE_PATH"
            _oifs="$IFS"; IFS=":$_nl"; set -f
            for _d in $v; do
                case "$_d" in /*) [ -e "$_d/whatap/package.json" ] && _add_pkg_dir "$_d/whatap" "NODE_PATH of node pid $pid" ;; esac
            done
            set +f; IFS="$_oifs"
        fi
        # the agent's fallback home is the app root / process cwd — count the
        # cwd as a candidate only when whatap artifacts are visible in it
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        eval "_cw_$pid=\$cwd"
        if [ -z "$cwd" ]; then
            [ -e "/proc/$pid" ] && D_UNREAD="$D_UNREAD $pid"
        elif _app_root_markers "$cwd"; then
            _add_home "$cwd" "cwd of node pid $pid (whatap artifacts present)"
            _mk=1
        fi
        [ -n "$cwd" ] && [ -e "$cwd/node_modules/whatap/package.json" ] && _add_pkg_dir "$cwd/node_modules/whatap" "cwd of node pid $pid"
        if [ "$_mk" = 1 ]; then _am="$_am $pid"; [ -n "$exe" ] && _ndm="$_ndm$exe$_nl"
        else _ar="$_ar $pid"; [ -n "$exe" ] && _ndr="$_ndr$exe$_nl"; fi
    done <<EOF
$(_proc_table)
EOF
    D_APP_PIDS="$(echo $_am $_ar)"
    # binaries of whatap-marked processes take the detail slots first
    while IFS= read -r exe; do [ -n "$exe" ] && _add_node "$exe"; done <<EOF
$_ndm$_ndr
EOF

    # node binaries on PATH and common install locations (shallow globs only)
    for v in node nodejs; do
        exe="$(command -v "$v" 2>/dev/null)"
        [ -n "$exe" ] && _add_node "$exe"
    done
    for exe in /usr/local/bin/node /opt/node*/bin/node /usr/local/nodejs*/bin/node; do
        [ -x "$exe" ] && _add_node "$exe"
    done

    # agent home candidates
    [ -n "${WHATAP_HOME:-}" ] && _home_from_self "$WHATAP_HOME" WHATAP_HOME
    [ -n "${WHATAP_CONF_DIR:-}" ] && _home_from_self "$WHATAP_CONF_DIR" WHATAP_CONF_DIR
    [ -n "${WHATAP_CONF:-}" ] && _add_conf_name "$WHATAP_CONF"
    # port registry: one line per app group, "<udp-port>\t<home>:<id8>"
    if [ -r "$D_LOCK_FILE" ]; then
        while IFS= read -r _l || [ -n "$_l" ]; do
            v="$(printf '%s\n' "$_l" | awk '{print $2}')"
            v="${v%:*}"     # strip the trailing :<app-identifier>
            [ -n "$v" ] && _add_home "$v" "port registry $D_LOCK_FILE"
        done < "$D_LOCK_FILE"
    fi
    for pid in $D_GO_PIDS; do
        cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        if [ -n "$cwd" ]; then _add_home "$cwd" "cwd of whatap_nodejs pid $pid"
        elif [ -e "/proc/$pid" ]; then D_UNREAD="$D_UNREAD $pid"; fi
        if _read_proc_env "$pid"; then
            _env_pick WHATAP_HOME
            [ -n "$_ev_WHATAP_HOME" ] && _home_from_pid "$pid" "$_ev_WHATAP_HOME" "environ of whatap_nodejs pid $pid"
        fi
    done
    D_UNREAD="$(printf '%s\n' $D_UNREAD | sort -un | tr '\n' ' ' | sed 's/ $//')"
    # operator auto-injection default mount (apm-init-nodejs seeds it)
    [ -d /whatap-agent ] && _add_home "/whatap-agent" "operator injection volume /whatap-agent"
    [ -e /whatap-agent/node_modules/whatap/package.json ] && _add_pkg_dir "/whatap-agent/node_modules/whatap" "operator injection volume"

    # global installs: `npm root -g` once, and <prefix>/lib/node_modules of
    # every node binary found, which is where npm puts them without npm
    # having to run
    if have npm; then
        D_NPM_ROOT="$(_bounded npm root -g 2>/dev/null)" || D_NPM_ROOT=""
        [ -e "$D_NPM_ROOT/whatap/package.json" ] && _add_pkg_dir "$D_NPM_ROOT/whatap" "npm root -g"
    fi
    while IFS= read -r exe; do
        [ -n "$exe" ] || continue
        v="$(readlink -f "$exe" 2>/dev/null || echo "$exe")"
        v="${v%/*}"; v="${v%/*}"
        [ -e "$v/lib/node_modules/whatap/package.json" ] && _add_pkg_dir "$v/lib/node_modules/whatap" "global prefix of $exe"
    done <<EOF
$D_NODE_EXES
EOF
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

# _home_confs -> every readable conf file (whatap.conf and the WHATAP_CONF
# names) of every visible agent home, one per line
_home_confs() {
    local h src f cn
    while IFS='|' read -r h src; do
        [ -n "$h" ] || continue
        f="$(resolve_fs "$h")" || continue
        while IFS= read -r cn; do
            [ -n "$cn" ] || continue
            [ -r "$f/$cn" ] && [ -f "$f/$cn" ] && printf '%s\n' "$f/$cn"
        done <<EOF2
$D_CONF_NAMES
EOF2
    done <<EOF
$D_HOMES
EOF
}

# _net_ports -> sets _udp_ports / _tcp_ports to the ports the readable agent
# configs name (udp: net_udp_port and net_udp_port+100, the LLM channel), or
# 6600 when none names one, and states which it used
_net_ports() {
    local f p q lp=""
    set --
    while IFS= read -r f; do [ -n "$f" ] && set -- "$@" "$f"; done <<EOF
$(_home_confs)
EOF
    # the 66xx/67xx range is always matched: an agent on a port no readable
    # conf or registry names (a non-root run, a non-default port) still shows
    _pl="" _plab="" _pbad=""
    _ports_add "net_udp_port in $# readable conf file(s)" <<EOF
$(_conf_vals net_udp_port "$@")
EOF
    # the LLM channel is net_udp_port + 100; only validated ports reach here
    for p in $_pl; do
        q=$((p + 100))
        [ "$q" -le 65535 ] && lp="${lp:+$lp }$q"
    done
    [ -n "$lp" ] && { _pl="$_pl $lp"; _plab="$_plab; $lp (net_udp_port + 100)"; }
    _ports_add "port registry $(_quote_nl "$D_LOCK_FILE")" <<EOF
$(_registry_vals "$D_LOCK_FILE")
EOF
    # shellcheck disable=SC2086  # validated port numbers only
    _pl="$(_uniq_ports $_pl)"
    _udp_ports="6[67][0-9][0-9] $_pl" _udp_label="66xx 67xx${_pl:+ $_pl}"
    fact "udp port filter: 66xx 67xx (range)$_plab"
    [ -n "$_pbad" ] && fact "udp port values ignored (not a port 1..65535): $_pbad"
    _pl="" _plab="" _pbad=""
    _ports_add "whatap.server.port / whatap_server_port in $# readable conf file(s)" <<EOF
$(_conf_vals whatap.server.port "$@"; _conf_vals whatap_server_port "$@")
EOF
    # shellcheck disable=SC2086
    _pl="$(_uniq_ports 6600 $_pl)"
    _tcp_ports="$_pl" _tcp_label="$_pl"
    fact "tcp port filter: 6600$_plab"
    [ -n "$_pbad" ] && fact "tcp port values ignored (not a port 1..65535): $_pbad"
}

# _sock_list TOOL FLAGS PORTS -> the socket table lines naming whatap or node,
# or one of PORTS (space-separated), header kept, first 50; exits with TOOL's
# status
_sock_list() {
    local pat rc
    pat=":($(printf '%s' "$3" | tr -s ' ' '|' | sed 's/^|//; s/|$//'))([^0-9]|\$)"
    "$1" "$2" > "$(_tmp sock.out)"; rc=$?
    awk -v p="$pat" '(NR <= 2 && /State|Proto|Recv-Q/) || /whatap/ || /node/ || $0 ~ p' "$(_tmp sock.out)" 2>/dev/null | head -n 50
    return "$rc"
}

# _resolve_goals -> resolve `agent` and `conf` once, from what discovery read.
# An absence is `na` only when every input behind it was read: an unreadable
# environ/cwd, hidepid, a blocked home path or a failed `npm root -g` makes it
# `missed`. conf looks at every name section 5 dumps (whatap.conf and the
# WHATAP_CONF values).
_resolve_goals() {
    local h src fs why cn seen=0 homes_seen=0 blocked="" absent="" unres="" gaps n ph
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
        if [ -d "$fs" ] && [ ! -x "$fs" ]; then blocked="$blocked; $h (permission denied: $fs)"; continue; fi
        while IFS= read -r cn; do
            [ -n "$cn" ] || continue
            if [ -r "$fs/$cn" ] && [ -f "$fs/$cn" ]; then seen=1
            elif [ -e "$fs/$cn" ]; then blocked="$blocked; $fs/$cn (permission denied)"
            else absent="$absent; $fs/$cn (path not found)"; fi
        done <<EOF2
$D_CONF_NAMES
EOF2
    done <<EOF
$D_HOMES
EOF
    blocked="${blocked#; }" absent="${absent#; }"
    gaps="$(_scan_gaps)"
    unres="${unres#; }"
    [ -n "$unres" ] && gaps="${gaps:+$gaps; }home candidate(s) not resolved: $unres"
    [ -n "$D_ODD" ] && gaps="${gaps:+$gaps; }path(s) with a newline or '|', not followed:$D_ODD"
    ph=""; [ -n "$blocked$D_UNREAD$D_HIDEPID" ] && ph="$(_priv_hint)"
    if have npm && [ -z "$D_NPM_ROOT" ]; then gaps="${gaps:+$gaps; }npm root -g returned nothing (failed or timed out)"; fi

    if [ "$homes_seen" = 1 ] || [ -n "$D_PKG_DIRS" ] || [ -n "$D_GO_PIDS" ]; then
        got agent
    elif [ -n "$blocked" ] || [ -n "$gaps" ]; then
        missed agent "no whatap home or package found in what this uid could read: ${blocked:+$blocked; }$gaps$ph"
    else
        n="$(echo $D_APP_PIDS | wc -w | tr -d ' ')"
        na agent "no whatap home or package in the collector env, port registry $D_LOCK_FILE, /whatap-agent, the global node_modules, or the environ/cwd/NODE_PATH of $n node process(es) (all readable)${absent:+; home candidate(s): $absent}"
    fi

    if [ "$seen" = 1 ]; then got conf
    elif [ -n "$blocked" ]; then missed conf "conf file not readable: $blocked$ph"
    elif [ -n "$D_ODD$unres" ] || { [ -z "$D_HOMES" ] && [ -n "$gaps" ]; }; then missed conf "no agent home found in what this uid could read: $gaps$ph"
    elif [ -z "$D_HOMES" ]; then na conf "no agent home found to hold a conf file (every source read)"
    else na conf "no conf file in any agent home: $absent"; fi
}

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    goal agent "whatap npm package / agent home"
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
    for t in node npm pnpm yarn pm2 ss netstat lsof readlink timeout file stat awk tr; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present (%s)\n' "$t" "$(command -v "$t")"
        else printf '        %-12s absent\n' "$t"; fi
    done

    discover

    # [2] host / platform
    section "Host / platform"
    probe "kernel" uname -srm
    probe "machine arch" uname -m
    read_proc "os-release" /etc/os-release
    probe "cpu count (nproc)" nproc
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    # container / cgroup context — the agent reports host-view CPU (Node os
    # module), so container-vs-host metric questions need these limits
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

    # [3] node runtimes + whatap package installs
    section "Node.js runtimes and whatap package installs"
    if [ -z "$D_NODE_EXES" ]; then
        fact "node binaries: n/a (none found on PATH or among running processes)"
    fi
    local _ndcount=0 nd
    # newline-split, no globbing; fd 9 so a probe reading stdin cannot eat it
    while IFS= read -r nd <&9; do
        [ -n "$nd" ] || continue
        _ndcount=$((_ndcount + 1))
        if [ "$_ndcount" -gt 8 ]; then
            fact "-- more node binaries found but not detailed (cap: 8): $(printf '%s\n' "$D_NODE_EXES" | tail -n +9 | tr '\n' ' ')"
            break
        fi
        fact "-- node binary: $nd"
        fact "   resolves to: $(readlink -f "$nd" 2>/dev/null || echo "$nd")"
        ndprobe "   version" "$nd" --version
    done 9<<EOF
$D_NODE_EXES
EOF
    probe "npm version" npm --version
    if ! have npm; then fact "global node_modules (npm root -g): n/a (command not found: npm)"
    elif [ -z "$D_NPM_ROOT" ]; then fact "global node_modules (npm root -g): n/a (no output: failed or timed out after ${CMD_TIMEOUT}s)"
    elif [ -e "$D_NPM_ROOT/whatap/package.json" ]; then fact "global node_modules (npm root -g): $D_NPM_ROOT (whatap present)"
    else fact "global node_modules (npm root -g): $D_NPM_ROOT (no whatap in it)"; fi
    if [ -z "$D_PKG_DIRS" ]; then
        fact "whatap package dirs: none discovered (process cwd, NODE_PATH, npm root -g, <prefix>/lib/node_modules of each node binary, /whatap-agent)"
    else
        fact "whatap package installs discovered (read as text; the module is never loaded):"
        printf '%s\n' "$D_PKG_DIRS" | while IFS='|' read -r d src; do
            [ -n "$d" ] || continue
            printf '        -- %s   <- %s\n' "$d" "$src"
            fsd="$(resolve_fs "$d")"
            if [ -z "$fsd" ]; then printf '           n/a (%s)\n' "$(_absent_why "$d" "$src")"; continue; fi
            [ "$fsd" != "$d" ] && printf '           filesystem view: %s (read through a process root)\n' "$fsd"
            pj="$fsd/package.json"
            if [ -r "$pj" ]; then
                printf '           %s\n' "$(pkg_json_field version "$pj")"
                printf '           %s\n' "$(pkg_json_field releaseDate "$pj")"
                printf '           engines: %s\n' "$(grep -A2 -m1 '"engines"' "$pj" 2>/dev/null | grep '"node"' | sed 's/^[[:space:]]*//; s/,[[:space:]]*$//')"
            else
                printf '           package.json: n/a (not readable: %s)\n' "$pj"
            fi
            # build id of the bundled master agent binaries (2.x line only)
            if [ -r "$fsd/build.txt" ]; then
                printf '           build.txt (first 4 lines):\n'
                head -n 4 "$fsd/build.txt" 2>/dev/null | cut -c1-160 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            fi
            if [ -d "$fsd/agent" ]; then
                printf '           bundled master agent binaries (agent/):\n'
                for b in "$fsd"/agent/*/*/whatap_nodejs "$fsd"/agent/*/whatap_nodejs.exe; do
                    [ -f "$b" ] && printf '             %s  %s bytes\n' "$b" "$(wc -c < "$b" 2>/dev/null | tr -d ' ')"
                done
            else
                printf '           bundled master agent binaries: none (agent/ absent)\n'
            fi
            if [ -d "$fsd/lib/observers" ]; then
                printf '           instrumentation modules bundled in installed agent (lib/observers): %s\n' \
                    "$(ls "$fsd/lib/observers" 2>/dev/null | sed 's/\.js$//; s/-observer$//' | tr '\n' ' ')"
            else
                printf '           instrumentation modules: n/a (no lib/observers under %s)\n' "$fsd"
            fi
            [ -f "$fsd/whatap.conf" ] && printf '           whatap.conf template in package dir: present\n'
            if [ -f "$fsd/paramkey.txt" ]; then
                printf '           paramkey.txt in package dir: present, %s bytes (content not collected: key material)\n' "$(wc -c < "$fsd/paramkey.txt" 2>/dev/null | tr -d ' ')"
            fi
        done
    fi

    # [4] runtime processes
    section "Runtime processes"
    local pid n
    if [ -z "$D_GO_PIDS" ]; then
        fact "master agent (whatap_nodejs) processes: none found in /proc"
    else
        fact "master agent (whatap_nodejs) processes:"
        for pid in $D_GO_PIDS; do
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-300)"
            printf '           cwd: %s\n' "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "n/a (permission denied or gone)")"
            printf '           uid/state: %s\n' "$(awk '/^Uid:/{u=$2} /^State:/{s=$2" "$3} END{print u" / "s}' "/proc/$pid/status" 2>/dev/null)"
            if [ -r "/proc/$pid/environ" ]; then
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^(WHATAP_|whatap\.|node\.version|APP_IDENTIFIER|APP_NAME|NODEJS_PARENT_APP_PID|PM2_)' | cut -c1-300 | while IFS= read -r _l; do printf '           env %s\n' "$_l"; done
            else
                printf '           env: n/a (permission denied: /proc/%s/environ)\n' "$pid"
            fi
        done
    fi
    n="$(echo $D_APP_PIDS | wc -w | tr -d ' ')"
    if [ "${n:-0}" -eq 0 ]; then
        fact "node processes: none found in /proc"
    else
        fact "node processes found: $n (whatap-marked processes listed first; detailing first 20)"
        local shown=0
        for pid in $D_APP_PIDS; do
            shown=$((shown + 1))
            [ "$shown" -gt 20 ] && { fact "-- remaining $((n - 20)) node processes not detailed (cap: 20)"; break; }
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           comm: %s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           exe: %s\n' "$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo n/a)"
            printf '           cmdline: %s\n' "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-300)"
            _cwd_of "$pid"; cwd="$_cw"
            printf '           cwd: %s\n' "${cwd:-n/a (permission denied or gone)}"
            # whatap attach markers: "-r whatap" on the cmdline, or a require
            # via NODE_OPTIONS (both reach the same preload path)
            if tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE '^(-r|--require)$|^--require=.*whatap'; then
                printf '           cmdline carries -r/--require: yes\n'
            else
                printf '           cmdline carries -r/--require: no\n'
            fi
            if [ -r "/proc/$pid/environ" ]; then
                # one read of the environ; three groups, each in environ order
                tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | awk '
                    /^(NODE_OPTIONS|NODE_PATH|NODE_ENV|NEXT_RUNTIME)=/ { a = a "           env " substr($0, 1, 300) "\n" }
                    /^WHATAP_/ { w = w "           env " substr($0, 1, 300) "\n" }
                    /^(POD_NAME|NODE_NAME|NODE_IP|PM2_HOME|pm_id|name|instances|APP_NAME)=/ { k = k "           env " substr($0, 1, 200) "\n" }
                    END { printf "%s%s%s", a, w, k }'

            else
                printf '           environ: n/a (permission denied: /proc/%s/environ)\n' "$pid"
            fi
            if [ -n "$cwd" ] && [ -e "$cwd/node_modules/whatap" ]; then
                printf '           cwd/node_modules/whatap: present -> %s\n' "$(readlink -f "$cwd/node_modules/whatap" 2>/dev/null)"
            else
                printf '           cwd/node_modules/whatap: absent\n'
            fi
        done
    fi

    # [5] agent homes and configuration
    section "Agent homes and configuration"
    fact "env WHATAP_HOME (collector shell): $(_quote_nl "${WHATAP_HOME:-not set}")"
    fact "env WHATAP_CONF (collector shell): $(_quote_nl "${WHATAP_CONF:-not set}")"
    fact "env WHATAP_CONF_DIR (collector shell): $(_quote_nl "${WHATAP_CONF_DIR:-not set}")"
    fact "env WHATAP_LOCK_FILE (collector shell): $(_quote_nl "${WHATAP_LOCK_FILE:-not set}")"
    [ -n "$D_ODD" ] && fact "path(s) with a newline or '|', not followed:$D_ODD"
    [ -n "$D_GONE" ] && printf '%s' "$D_GONE" | while IFS= read -r _l; do [ -n "$_l" ] && fact "relative WHATAP_HOME of a process that exited, not resolved: $_l"; done
    if [ -z "$D_HOMES" ]; then
        if [ -n "$D_ODD_HOME" ]; then fact "agent home candidates: none followed (the refused ones are listed above)"
        else fact "agent home candidates: none discovered (env, port registry, process scan all empty)"; fi
    else
        fact "agent home candidates discovered:"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _s; do printf '        %s   <- %s\n' "$_p" "$_s"; done
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")"
            if [ -z "$fshome" ]; then fact "   n/a ($(_absent_why "$home" "$_src"))"; continue; fi
            [ "$fshome" != "$home" ] && fact "   filesystem view: $fshome (read through a process root)"
            printf '%s\n' "$D_CONF_NAMES" | sort -u | while IFS= read -r cn; do
                [ -n "$cn" ] || continue
                dump_file "   $cn" "$fshome/$cn" 400
                conf_bytes "   $cn byte facts" "$fshome/$cn"
            done
            dump_file "   container.conf" "$fshome/container.conf" 200
            # master agent binary placed into the home by the 2.x agent
            if [ -e "$fshome/whatap_nodejs" ]; then
                fact "   whatap_nodejs entry: $(ls -l "$fshome/whatap_nodejs" 2>/dev/null | head -n1)"
                fact "   whatap_nodejs resolved: $(readlink -f "$fshome/whatap_nodejs" 2>/dev/null || echo 'n/a (unresolvable)')"
            else
                fact "   whatap_nodejs entry: n/a (path not found: $fshome/whatap_nodejs)"
            fi
            # pid files: agent-<id8>.pid per app group + legacy names
            _pidseen=0
            for pf in "$fshome"/agent-*.pid "$fshome/whatap_nodejs.pid" "$fshome/whatap_nodejs.pid.llm"; do
                [ -f "$pf" ] || continue
                _pidseen=1
                _pid="$(cat "$pf" 2>/dev/null | tr -d ' \n')"
                if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
                    fact "   $(basename "$pf"): $_pid (process exists; comm: $(cat "/proc/$_pid/comm" 2>/dev/null))"
                else
                    fact "   $(basename "$pf"): ${_pid:-empty} (no process with this pid in this pid namespace)"
                fi
            done
            [ "$_pidseen" = 0 ] && fact "   pid files (agent-*.pid, whatap_nodejs.pid*): none present"
            # startup lock files (held for seconds during agent start)
            _lk="$(ls "$fshome"/agent-*.lock 2>/dev/null | tr '\n' ' ')"
            if [ -n "$_lk" ]; then fact "   agent-*.lock files present: $_lk"
            else fact "   agent-*.lock files: none present"; fi
            # per-process UDP port files: whatap_port_<pid> containing net_udp_port=N
            _pp=0
            for pf in "$fshome"/whatap_port_*; do
                [ -f "$pf" ] || continue
                _pp=$((_pp + 1))
                [ "$_pp" -gt 20 ] && { fact "   more whatap_port_* files not detailed (cap: 20)"; break; }
                _owner="${pf##*whatap_port_}"
                if [ -d "/proc/$_owner" ]; then _alive="process exists"; else _alive="no such process"; fi
                fact "   $(basename "$pf"): $(head -n1 "$pf" 2>/dev/null | cut -c1-80) ($_alive)"
            done
            [ "$_pp" = 0 ] && fact "   whatap_port_<pid> files: none present"
            [ -d "$fshome/run" ] && fact "   run dir: present" || fact "   run dir: absent"
            for sf in security.conf paramkey.txt; do
                if [ -e "$fshome/$sf" ]; then fact "   $sf: present, $(wc -c < "$fshome/$sf" 2>/dev/null | tr -d ' ') bytes (content not collected: key material)"
                else fact "   $sf: absent"; fi
            done
            if [ -d "$fshome/logs" ]; then
                probe "   logs dir listing" _ls_head "$fshome/logs" 100
            else
                fact "   logs dir: n/a (path not found: $fshome/logs)"
            fi
        done
    fi

    # [6] network endpoints and port registry
    section "Network endpoints and port registry"
    # 2.x: app -> master agent is connected UDP to 127.0.0.1:<net_udp_port>
    # (default 6600, LLM default base+100); master agent -> collection server
    # is outbound TCP 6600. 0.5.x: the app itself holds the TCP session.
    _net_ports
    if have ss; then
        probe "udp sockets (whatap- or node-named, or port $_udp_label)" _sock_list ss -uanp "$_udp_ports"
        probe "tcp sessions (whatap- or node-named, or port $_tcp_label)" _sock_list ss -tnp "$_tcp_ports"
    elif have netstat; then
        probe "udp sockets (whatap- or node-named, or port $_udp_label)" _sock_list netstat -uanp "$_udp_ports"
        probe "tcp sessions (whatap- or node-named, or port $_tcp_label)" _sock_list netstat -tnp "$_tcp_ports"
    else
        fact "socket listing: n/a (command not found: ss, netstat); raw tables follow"
        probe "raw /proc/net/udp (first 30 lines)" sh -c "head -n 30 /proc/net/udp"
        probe "raw /proc/net/tcp (first 30 lines)" sh -c "head -n 30 /proc/net/tcp"
    fi
    dump_file "port registry $D_LOCK_FILE (format: udp-port<TAB>home:app-identifier)" "$D_LOCK_FILE" 50
    [ -e "$D_LOCK_FILE.lock" ] && fact "$D_LOCK_FILE.lock (registry write lock): present" || fact "$D_LOCK_FILE.lock (registry write lock): absent"

    # [7] agent logs (bounded reads only; never a whole-log grep)
    section "Agent logs"
    # 2.x hook log: logs/<conf-name>-hook-YYYYMMDD.log; 0.5.x: logs/whatap-YYYYMMDD.log
    # (no "-hook-"); rotation off: logs/whatap.log; master agent side: whatap-boot-*.
    # The startup banner goes to the app's stdout, not to these files.
    if [ -z "$D_HOMES" ]; then
        fact "no agent home discovered; no log locations to read"
    else
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")"
            if [ -z "$fshome" ]; then fact "   n/a ($(_absent_why "$home" "$_src"))"; continue; fi
            if [ ! -d "$fshome/logs" ]; then fact "   logs dir: n/a (path not found: $fshome/logs)"; continue; fi
            _hook="$(ls -t "$fshome"/logs/*-hook-*.log 2>/dev/null | head -n 1)"
            if [ -n "$_hook" ]; then
                head_file "   $(basename "$_hook") (hook log, first lines)" "$_hook" 80
                tail_file "   $(basename "$_hook") (hook log, recent lines)" "$_hook" 120
                # which observers engaged (or could not engage) in THIS
                # process — startup writes one line per observer attempt
                fact "   observer lines in the first 400 lines of $(basename "$_hook"):"
                head -n 400 "$_hook" 2>/dev/null | grep -iE 'observer|unable to load|injected' | head -n 40 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                fact "   [WHATAP-*] codes in the last 400 lines of $(basename "$_hook"):"
                tail -n 400 "$_hook" 2>/dev/null | grep -oE '\[WHATAP[-A-Za-z0-9]*\]' | sort | uniq -c | sort -rn | head -n 20 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            else
                fact "   *-hook-*.log: n/a (no such file in $fshome/logs)"
            fi
            _leg="$(ls -t "$fshome"/logs/whatap-2*.log "$fshome"/logs/whatap-1*.log 2>/dev/null | grep -v -- '-hook-' | grep -v -- '-boot-' | head -n 1)"
            if [ -n "$_leg" ]; then
                head_file "   $(basename "$_leg") (agent log, first lines)" "$_leg" 80
                tail_file "   $(basename "$_leg") (agent log, recent lines)" "$_leg" 120
            fi
            tail_file "   whatap.log (rotation-off log)" "$fshome/logs/whatap.log" 120
            _boot="$(ls -t "$fshome"/logs/whatap-boot-*.log "$fshome"/whatap-boot-*.log 2>/dev/null | head -n 1)"
            if [ -n "$_boot" ]; then
                head_file "   $(basename "$_boot") (master agent boot log, first lines)" "$_boot" 60
                tail_file "   $(basename "$_boot") (master agent boot log, recent lines)" "$_boot" 120
                fact "   [WA*] codes in the last 400 lines of $(basename "$_boot"):"
                tail -n 400 "$_boot" 2>/dev/null | grep -oE '\[WA[0-9][0-9A-Za-z-]*\]' | sort | uniq -c | sort -rn | head -n 20 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            else
                fact "   whatap-boot-*.log: n/a (no such file under $fshome)"
            fi
            _req="$(ls -t "$fshome"/logs/reqlog-*.log "$fshome"/logs/reqlog.log 2>/dev/null | head -n1)"
            [ -n "$_req" ] && fact "   request log present: $_req ($(wc -l < "$_req" 2>/dev/null | tr -d ' ') lines)" || fact "   request log (reqlog*): none present"
        done
    fi

    # [8] application and launcher facts — how the app is started decides how
    # the agent attaches (require order, pm2 cluster, Next.js custom server),
    # so support cases need these facts. Cheap no-op when not applicable.
    section "Application and launcher facts (pm2 / Next.js / package manifests)"
    probe "pm2 version" pm2 --version
    _pm2d="$(echo $D_PM2_PIDS | cut -d' ' -f1-5)"
    if [ -n "$_pm2d" ]; then
        fact "pm2 daemon process(es): $_pm2d"
        for p in $_pm2d; do
            printf '        pid %s cmdline: %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-200)"
            printf '        pid %s PM2_HOME: %s\n' "$p" "$(_proc_env "$p" PM2_HOME)"
        done
    else
        fact "pm2 daemon process: none found in /proc"
    fi
    # app roots = distinct cwds of node processes (cap 8): manifests + files
    # the agent developers ask for verbatim in support threads
    _roots="" _rn=0
    for pid in $D_APP_PIDS; do
        # the cwd discovery resolved; a process that has exited since is skipped
        [ -d "/proc/$pid" ] || continue
        _cwd_of "$pid"; cwd="$_cw"
        [ -n "$cwd" ] || continue
        [ "$cwd" = "/" ] && continue
        case "$_roots" in *"|$cwd|"*) continue ;; esac
        _roots="$_roots|$cwd|"
        _rn=$((_rn + 1))
        [ "$_rn" -gt 8 ] && { fact "-- more app roots found but not detailed (cap: 8)"; break; }
        fact "-- app root (cwd of node pid $pid): $cwd"
        if [ -r "$cwd/package.json" ]; then
            fact "   package.json name: $(pkg_json_field name "$cwd/package.json")"
            fact "   package.json whatap lines: $(grep -n 'whatap' "$cwd/package.json" 2>/dev/null | head -n 5 | tr '\n' ' ')"
            fact "   package.json scripts block:"
            awk '/"scripts"/{f=1} f{print; if(/}/ && f>1) exit; f++}' "$cwd/package.json" 2>/dev/null | head -n 15 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            # declared runtime libraries — read next to the agent's bundled
            # observer list in the installs section (same report, two sides
            # of one comparison a reader makes)
            fact "   package.json dependencies block:"
            awk '/"dependencies"/{f=1} f{print; if(/}/ && f>1) exit; f++}' "$cwd/package.json" 2>/dev/null | head -n 60 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "   package.json: n/a (not readable or absent in $cwd)"
        fi
        # libraries actually installed (top-level names only; no tree walk)
        if [ -d "$cwd/node_modules" ]; then
            _nmn="$(ls "$cwd/node_modules" 2>/dev/null | grep -v '^\.' | wc -l | tr -d ' ')"
            fact "   node_modules top-level packages (${_nmn:-?} total, first 150):"
            ls "$cwd/node_modules" 2>/dev/null | grep -v '^\.' | head -n 150 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            _sc="$(ls -d "$cwd"/node_modules/@*/* 2>/dev/null | head -n 50 | awk -F/ '{print $(NF-1)"/"$NF}' | tr '\n' ' ')"
            [ -n "$_sc" ] && fact "   scoped packages (first 50): $_sc"
        else
            fact "   node_modules: n/a (path not found: $cwd/node_modules)"
        fi
        for e in ecosystem.config.js ecosystem.config.cjs ecosystem.config.json ecosystem.json; do
            [ -f "$cwd/$e" ] && dump_file "   $e" "$cwd/$e" 120
        done
        for ncf in next.config.js next.config.mjs next.config.ts; do
            if [ -f "$cwd/$ncf" ]; then
                fact "   $ncf lines naming whatap / serverExternalPackages / transpilePackages:"
                grep -nE 'whatap|serverExternalPackages|transpilePackages|externals' "$cwd/$ncf" 2>/dev/null | head -n 10 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            fi
        done
        for itf in instrumentation.ts instrumentation.js src/instrumentation.ts src/instrumentation.js; do
            if [ -f "$cwd/$itf" ]; then
                fact "   $itf lines naming whatap / register:"
                grep -nE 'whatap|register|NEXT_RUNTIME' "$cwd/$itf" 2>/dev/null | head -n 10 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            fi
        done
        [ -d "$cwd/.next" ] && fact "   .next build dir: present$([ -d "$cwd/.next/standalone" ] && echo ' (standalone output present)')" || fact "   .next build dir: absent"
        if [ -d "$cwd/node_modules/.pnpm" ]; then
            fact "   pnpm store: present; whatap entries: $(ls -d "$cwd"/node_modules/.pnpm/whatap@* 2>/dev/null | tr '\n' ' ')"
        fi
    done
    [ -z "$_roots" ] && fact "app roots: none (no node process cwd readable)"

    # [9] kubernetes / operator injection context
    section "Kubernetes / operator injection context"
    if [ -d /whatap-agent ]; then
        probe "/whatap-agent listing" _ls_head /whatap-agent 50
        # apm-init-nodejs contract: seeds node_modules/whatap and copies the
        # arch-matched master agent binary to a stable path agent/whatap_nodejs
        if [ -e /whatap-agent/node_modules/whatap/agent/whatap_nodejs ]; then
            fact "/whatap-agent/node_modules/whatap/agent/whatap_nodejs (arch-resolved stable path): present"
        else
            fact "/whatap-agent/node_modules/whatap/agent/whatap_nodejs (arch-resolved stable path): absent"
        fi
    else
        fact "/whatap-agent: n/a (path not found: /whatap-agent)"
    fi
    if [ -n "${WHATAP_NODEJS_AGENT_PATH:-}" ]; then
        fact "env WHATAP_NODEJS_AGENT_PATH: $WHATAP_NODEJS_AGENT_PATH"
        if [ -L "$WHATAP_NODEJS_AGENT_PATH" ]; then
            fact "WHATAP_NODEJS_AGENT_PATH file type: symlink -> $(readlink -f "$WHATAP_NODEJS_AGENT_PATH" 2>/dev/null)"
        elif [ -e "$WHATAP_NODEJS_AGENT_PATH" ]; then
            fact "WHATAP_NODEJS_AGENT_PATH file type: regular file"
        else
            fact "WHATAP_NODEJS_AGENT_PATH file type: n/a (path not found)"
        fi
    else
        fact "env WHATAP_NODEJS_AGENT_PATH: not set (collector shell)"
    fi
    for v in POD_NAME NODE_NAME NODE_IP WHATAP_OKIND WHATAP_ONODE WHATAP_MICRO_ENABLED WHATAP_LICENSE WHATAP_HOST WHATAP_PORT APP_NAME APP_PROCESS_NAME; do
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
