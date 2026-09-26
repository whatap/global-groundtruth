#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — DB monitoring collector
# -----------------------------------------------------------------------------
# Collects facts about a WhaTap DB-monitoring installation. The DBX agent
# queries the monitored database over JDBC, so the agent host and the DB host
# are often DIFFERENT machines (and the DB itself may be a managed cloud
# service with no reachable host at all). This collector therefore discovers
# what is present on the host it runs on and adapts:
#
#   * DBX-side components found (dbx / dmx / prx / dbxc)  -> agent-host sections
#   * XOS / xcub / DB server processes found              -> DB-host sections
#   * neither                                             -> that fact itself
#
# Field procedure (see README.md):
#   1. run on the DBX agent host:      ./collect-db.sh --file
#   2. on-prem split topology: run the same command on the DB host too
#   3. run the matching sql/<engine>.sql through the DB client with the
#      monitoring account, and paste its output together with the reports
#
# CONTRACT ../../CONTRACT.md, guidelines ../../docs/collector-engineering.md;
# no set -e on purpose (the run must reach its footer). Config files are dumped
# verbatim; README.md, "What the report can contain", lists every place a
# secret can arrive from.
# -----------------------------------------------------------------------------

# bash only: arrays, `read -d`, $SECONDS. Another shell would run on and give
# wrong answers silently, so it stops here instead.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' "collect-db.sh needs bash (run it as ./collect-db.sh or bash collect-db.sh)" >&2
    exit 2
fi

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-db"
# 0.5.0  Discovery reads each /proc/<pid>/cmdline and comm with builtins, with
#        no fork per process: `$(tr)`, `$(cat)` and `$(_db_kind_of_comm)` per
#        pid made the scan cost about 15 ms per process (9.2 s -> 1.4 s on a
#        720-process host, 38.7 s -> 2.0 s with 2000 more). The report is
#        unchanged. The --sql terminal prompt waits no longer than what is
#        left of RUN_DEADLINE; a prompt nobody answers skips that instance
#        with the reason in the sql goal (2026-09-25).
# 0.5.1  A CMD_TIMEOUT from the environment is used (it was overwritten by a
#        fixed value after _run_init had checked it) (2026-09-26).
# 0.5.2  Readability refactor; report unchanged.
# 0.5.3  Each (file, key) of a config is read once per run: sections G, H, J,
#        K and L asked for the same keys again, 7 forks and 6 execs each
#        (72 reads -> 40 for 3 instances with --tls). Report unchanged.
# 0.6.0  The architecture is taken from the one `uname -smr` (no second
#        `uname -m`).
# 0.7.0  Round trips in ms: each section G tcp connect states its time in ms
#        (it was whole seconds, "0s"), and --sql states the JDBC connect time
#        and one trivial query's time (SELECT 1; SELECT 1 FROM DUAL on Oracle)
#        per instance, measured in the runner VM (2026-09-26).
# 0.8.0  TLS facts are part of every run: section K (one handshake per
#        instance whose section G connect succeeded) runs by default. Measured on
#        PostgreSQL 16 and MySQL 8.4, the handshake leaves the same server log
#        trace as the connect probe (one connection line with log_connections,
#        one aborted-connection note at log_error_verbosity=3, nothing
#        otherwise). --tls is refused, naming this; the tls goal is gone with
#        the flag. The handshakes of one run share 30 s (each at most 15 s);
#        instances left after that say so. The certificate parses are bounded. --out DIR (default .) and --home=DIR are accepted. An
#        output directory that cannot be written stops the run before it
#        collects (2026-09-26).
#        A value option given nothing, or a value starting with '-', exits 2
#        ("missing value for --out"); it took the next option as its value.
VERSION="0.8.0"
DOMAIN="db"
TARGET="db-host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness ---------------------------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr
OPT_OUT="."       # output directory for --file
OPT_HOMES=""      # newline-separated extra agent homes from --home
OPT_SQL=0         # Tier 2: run the SQL pack over JDBC (agent's own java + driver)

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Target: a WhaTap DB-monitoring host — the DBX agent host, the monitored DB
host (XOS side), or both when co-located. The script discovers which
components are present and reports the matching fact sections.
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")                  print this help (no collection)
  $(basename "$0") --file           write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout         print the facts report to stdout
  $(basename "$0") --quiet ..       silence progress on stderr (add to --file / --stdout)
  $(basename "$0") --out <dir> ..   output directory for --file (default: .)
  $(basename "$0") --home <dir> ..  add an agent install dir the process scan cannot see
                                    (repeatable; useful when no agent process is running)

Every run also sends one TLS handshake (openssl s_client) to each instance's
DB endpoint whose TCP connect succeeded: server TLS version, cipher,
certificate dates/signature (section K).

  Tier 2 (opt-in — announced on stderr before anything is sent):
  $(basename "$0") --file --sql   run the read-only SQL pack over JDBC using the
                                  agent's own java + jdbc/ driver (no DB client
                                  needed); asks for the monitoring account on
                                  the terminal, or reads WHATAP_GGT_USER /
                                  WHATAP_GGT_PW from the environment

The same SQL packs can also be run through a DB client where one exists:
  sql/postgresql.sql (psql)  sql/mysql.sql (mysql)  sql/oracle.sql (sqlplus)
  windows/mssql.sql (sqlcmd)
EOF
}

# _optval NAME VALUE -> VALUE, or exit 2 when it is empty or starts with '-'
# (then the next option was taken for the value: `--out --stdout`)
_optval() {
    case "$2" in ''|-*) printf -- 'missing value for %s\n' "$1" >&2; exit 2 ;; esac
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        --sql)     OPT_SQL=1 ;;
        --tls)     printf -- '--tls is no longer an option: TLS facts are now part of every run (section K)\n' >&2; exit 2 ;;
        --out)     _optval --out "${2:-}"; OPT_OUT="$2"; shift ;;
        --out=*)   _optval --out "${1#*=}"; OPT_OUT="${1#*=}" ;;
        --home)
            _optval --home "${2:-}"
            OPT_HOMES="$OPT_HOMES$2
"
            shift ;;
        --home=*)
            _optval --home "${1#*=}"
            OPT_HOMES="$OPT_HOMES${1#*=}
" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---- emit helpers — DO NOT EDIT ---------------------------------------------
# The report shape (../../docs/output-format.md): header, numbered sections,
# facts, footer. progress narrates on fd 3 (the terminal saved in main), never
# into the report, and --quiet silences it; keep its text a fact about the run.
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

# section "A. TITLE" -> the next numbered section, [n] A. TITLE, narrated too
section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}
subsection() { printf '\n    -- %s --\n' "$1"; }
fact()       { printf '    %s\n' "$1"; }
emit_footer() { printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'; }
progress()   { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }
have()       { command -v "$1" >/dev/null 2>&1; }
# ---- end emit helpers

# ---- privilege — DO NOT EDIT ------------------------------------------------
# What a run can read depends on the privilege it was given: a fact about this
# run (CONTRACT rule 1), stated in the environment section ([1]). Each goal that
# privilege blocked repeats it via _priv_hint, because the status roll-up is what
# reaches the operator while still logged in, and "what was missing" and "what
# would have obtained it" are one thought. Without it, bundles came back with no
# conf/ and nothing said the uid could not reach it.
PRIV_WHY="unknown"
PRIV_GAP=""   # what a further privilege would obtain; empty when the run is root

# _priv_hint -> " (not elevated: REASON)", or nothing when the run is root.
# Append it to the reason of any goal that a privilege blocked.
_priv_hint() { [ -n "$PRIV_GAP" ] && printf ' (not elevated: %s)' "$PRIV_GAP"; return 0; }

# _note_privilege -> set PRIV_WHY/PRIV_GAP for this process. Call it once,
# before the environment section prints PRIV_WHY.
_note_privilege() {
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
# Most counters a collector reports are cumulative since boot (/proc/diskstats,
# ZFS kstats, MySQL GLOBAL STATUS); without the boot time they cannot be read as
# a rate. It reads /proc, not `uptime`: that works without procps and on a run
# whose main collection failed early, the run whose counters most need it.
# _note_boot -> the two facts; call it in the environment section after privilege.
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
# warn            must-see operator text on fd 3 (the terminal saved in main);
#                 not silenced by --quiet and not lost in --file mode.
# _bounded CMD... every external command under CMD_TIMEOUT and RUN_DEADLINE.
# _tmp NAME       a path in this run's private directory, removed on exit.
# _report_to_file --file mode's write; fails when the file is not written whole.
# Constraints:
# - POSIX sh only (apm collectors run under `sh -s`, often dash or busybox):
#   no SECONDS, no `type -t`, no ${v//x/y} outside a BASH_VERSION guard.
# - A cap returns 124 whatever timeout(1) returns for a kill (busybox: 143).
#   timeout(1) gets -k where it takes it, so a command deaf to TERM still ends;
#   without timeout(1), or for a shell function, a watchdog that ends in KILL.
# - Past RUN_DEADLINE nothing runs (124), so the report still reaches its footer.
# - Each call is logged with its time; only the command name and a subcommand
#   word, never arguments (they can hold a path or a credential).
RUN_DEADLINE="${RUN_DEADLINE:-300}"
_tmp_dir=""
_timeout_bin=""   # timeout(1), found in _run_init; empty = watchdog only
_run_t0=""
_timeout_k=""     # 5 when timeout(1) takes -k (_run_init)
_load0=""         # _host_load at _run_init
SLOW_SEC=3        # a bounded call at least this long is named in the status
_stdin_script=0   # 1 when the shell reads this script from stdin (sh -s)
_nl='
'
_tab="$(printf '\t')"

# Falls back to stderr when fd 3 is not open yet (an error before main).
warn() { { printf '!! %s\n' "$*" >&3; } 2>/dev/null || printf '!! %s\n' "$*" >&2; }

# _elapsed -> seconds since _run_init; 0 without a clock, which disables the
# deadline rather than tripping it at once
# shellcheck disable=SC3028  # SECONDS only under BASH_VERSION
_elapsed() {
    if [ -n "${BASH_VERSION:-}" ]; then printf '%s' "${SECONDS:-0}"
    elif [ -n "$_run_t0" ]; then printf '%s' "$(( $(date +%s 2>/dev/null || echo "$_run_t0") - _run_t0 ))"
    else printf '0'; fi
}
_past_deadline() { [ "$(_elapsed)" -ge "$RUN_DEADLINE" ]; }

# _cmd_kind CMD -> "file", "shell" (function or builtin) or "" (not found)
_cmd_kind() {
    case "$(command -v "$1" 2>/dev/null)" in
        /*) printf 'file' ;;
        '') ;;
        *)  printf 'shell' ;;
    esac
}

# Only the process that ran _run_init removes the directory: jobs forked by
# _bounded_in inherit the traps and would remove it mid-run. The owner is told
# by its pid, not by a flag set around the fork, which left a Ctrl-C window.
_owner_pid=""
_run_cleanup() {
    local me
    if [ -n "${BASHPID:-}" ]; then me="$BASHPID"; else me="$(exec sh -c 'echo "$PPID"')"; fi
    [ "$me" = "$_owner_pid" ] || return 0
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
    _owner_pid="$$"
    _load0="$(_host_load)"
    # 16+ digits: a date without %N prints bare seconds
    [ -z "${EPOCHREALTIME:-}" ] && case "$(date +%s%N 2>/dev/null)" in *[!0-9]*|'') ;; ????????????????*) _ms_date=1 ;; esac
    _now_ms; _run_ms0="$_ms"
    case "$_run_t0" in ''|*[!0-9]*) _run_t0="" ;; esac
    # no predictable fallback name: without mktemp, _tmp answers /dev/null
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ggt.XXXXXX" 2>/dev/null)"
    # Script read from stdin (`sh -s`)? Then fd 0 is the script: a bounded
    # command must not read it, and bash 5.2 kills a $(...) that duplicates it.
    case "$0" in
        */*|*.sh) [ -f "$0" ] || _stdin_script=1 ;;
        *)        _stdin_script=1 ;;
    esac
    [ -n "$_tmp_dir" ] || warn "no private temp directory could be made under ${TMPDIR:-/tmp}; values that need one are reported as n/a"
    # caps from the environment: whole numbers or unused (0 = no limit to timeout(1))
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

# _kill_tree SIG PID -> signal PID and every descendant, found by PPid in
# /proc/<pid>/status. dash keeps a job in the caller's group even under set -m.
_kill_tree() {
    local sig="$1" all="$2" list="$2" next c
    while [ -n "$list" ]; do
        next=""
        for c in $list; do
            next="$next $(grep -l "^PPid:[[:space:]]*$c\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3)"
        done
        # shellcheck disable=SC2086,SC2116  # word-splitting squeezes the list
        list="$(echo $next)"
        all="$all $list"
    done
    # shellcheck disable=SC2086
    kill -"$sig" $all 2>/dev/null
}

# _now_ms -> _ms, ms since the epoch, in a variable so a call does not fork.
# EPOCHREALTIME (bash), else date +%s%N when it has %N (_ms_date=1), else
# whole seconds. Milliseconds let many short calls add up to their real time.
_ms_date=0
_run_ms0=0
_ms=0
# shellcheck disable=SC3028  # EPOCHREALTIME is empty outside bash
_now_ms() {
    local t="${EPOCHREALTIME:-}" f
    if [ -n "$t" ]; then
        # the locale's radix: EPOCHREALTIME can read 1790000000,123456
        f="${t#*[.,]}000"; f="${f%"${f#???}"}"
        _ms="${t%[.,]*}$f"
    elif [ "$_ms_date" = 1 ]; then
        t="$(date +%s%N 2>/dev/null)"; _ms="${t%??????}"
    else
        _ms="$(date +%s 2>/dev/null || echo 0)000"
    fi
}

# _time_log MS KIND CMD ARGS... -> one line for emit_status: the command name
# and, for a subcommand tool (kubectl get, zfs list), that word after any
# --opt=value. No other argument is kept; a name with odd bytes is "?".
_time_log() {
    [ -n "$_tmp_dir" ] || return 0
    local ms="$1" kind="$2" c="${3##*/}" w=""
    shift 3
    case "$c" in
        kubectl|oc|helm|zfs|zpool|systemctl|journalctl|timedatectl|chronyc|npm|pip|pip3|openssl|docker|crictl|ctr|ip)
            while [ $# -gt 0 ]; do case "$1" in -*=*) shift ;; *) break ;; esac; done
            case "${1:-}" in [a-z]*) case "$1" in *[!a-z0-9-]*) ;; *) w=" $1" ;; esac ;; esac ;;
    esac
    case "$c" in ''|*[!A-Za-z0-9._+-]*) c='?' ;; esac
    # braces: a redirect is opened before 2>/dev/null applies to it
    { printf '%s\t%s\t%s\n' "$ms" "$kind" "$c$w" >> "$_tmp_dir/time.log"; } 2>/dev/null
}

# _host_load -> one line: load average, PSI avg10 (cpu/io/memory), available
# memory, procs running/blocked. Read at start and end, so a slow call can be
# set against the load it ran under. /proc only.
_host_load() {
    LC_ALL=C awk '
        FILENAME == "/proc/loadavg" { la = "load " $1 " " $2 " " $3 }
        FILENAME ~ /^\/proc\/pressure\// {
            k = substr(FILENAME, 16)
            for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) p[k] = p[k] (p[k] == "" ? "" : "/") substr($i, 7)
        }
        /^MemTotal:/ { mt = $2 } /^MemAvailable:/ { ma = $2 }
        /^procs_running/ { pr = $2 } /^procs_blocked/ { pb = $2 }
        END {
            psi = ""; n = split("cpu io memory", K, " ")
            for (i = 1; i <= n; i++) if (K[i] in p) psi = psi " " K[i] " " p[K[i]]
            printf "%s; ", (la != "" ? la : "load n/a")
            if (psi != "") printf "psi avg10 (some/full)%s; ", psi
            if (mt) printf "mem available %d of %d MiB; ", ma / 1024, mt / 1024; else printf "mem n/a; "
            printf "procs running %s, blocked %s", (pr != "" ? pr : "n/a"), (pb != "" ? pb : "n/a")
        }' /proc/loadavg /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory /proc/meminfo /proc/stat 2>/dev/null
}

# _bounded CMD... -> CMD under the caps, with the caller's stdin (/dev/null when
# the script itself is on stdin). _bounded_in FILE CMD... -> FILE as its stdin;
# use it, not `< FILE` on the call.
_bounded() { _bounded_in "" "$@"; }

_bounded_in() {
    local in="$1" t="${CMD_TIMEOUT:-20}" left rc p w d m0
    shift
    left=$((RUN_DEADLINE - $(_elapsed)))
    [ "$left" -le 0 ] && { _time_log 0 "not run" "$@"; return 124; }
    _now_ms; m0="$_ms"
    [ "$left" -lt "$t" ] && t="$left"
    [ -z "$in" ] && [ "$_stdin_script" = 1 ] && in=/dev/null
    if [ -n "${_timeout_bin:-}" ] && [ "$(_cmd_kind "$1")" = file ]; then
        if [ -n "$in" ]; then "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@" < "$in"
        else                  "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@"; fi
        rc=$?
    else
        # The kill must reach all CMD started (an orphaned grandchild holds a
        # $(...) pipe open): set -m gives bash a job group, _kill_tree covers
        # dash. Inherited stdin goes through fd 4: an async list gets /dev/null
        # as stdin before its own redirections, so 0<&0 would hand dash /dev/null.
        set -m 2>/dev/null
        if [ -n "$in" ]; then "$@" < "$in" &
        else                  { "$@" 0<&4 4<&- & } 4<&0; fi
        p=$!
        set +m 2>/dev/null
        ( i=0
          # background sleep + wait, so a TERM ends the watchdog at once
          while [ "$i" -lt "$t" ]; do sleep 1 & wait $!; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        wait "$p"; rc=$?
        # KILL: a TERM can arrive before dash resets the inherited traps and be lost
        kill -KILL "$w" 2>/dev/null; wait "$w" 2>/dev/null
    fi
    _now_ms; d=$((_ms - m0))
    case "$rc" in 124|137|143) [ "$((d / 1000))" -ge "$t" ] && rc=124 ;; esac
    if [ "$rc" = 124 ]; then
        if [ "$t" -lt "${CMD_TIMEOUT:-20}" ]; then w="cut at the deadline"; else w="capped at ${t}s"; fi
    else w="ran"; fi
    _time_log "$d" "$w" "$@"
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
# Whether this run obtained what it came for is a fact about the run (CONTRACT.md,
# "Saying whether the collection worked"). A report full of n/a otherwise reads as
# finished and the gap surfaces days later; the status says, while the operator
# is still logged in: send this, or change something and run again.
#
#     goal   conf "module configs"                     # what this run is for
#     got    conf                                      # obtained
#     na     conf "this host runs no yard"             # legitimately absent
#     missed conf "uid 3103 cannot reach /data/whatap"  # this run was blocked
#
# `na` only when every input behind the absence was read and it IS the answer;
# one unreadable path, refused call or timeout makes it `missed`. Only `missed`
# makes a run INCOMPLETE. Resolve each goal once, after the last fallback:
# unresolved counts as "not reached", resolved twice differently counts as
# blocked, an undeclared resolution is listed. Records are KEY<TAB>VALUE lines;
# tabs and newlines in a reason are flattened.
_goals='' _res=''

_flat() { printf '%s' "$1" | tr '\n\t' '  '; }

goal() {
    case "$_nl$_goals" in *"$_nl$1$_tab"*) return 0 ;; esac
    _goals="$_goals$1$_tab$(_flat "$2")$_nl"
}
got()    { _res="$_res$1${_tab}got$_tab$_nl"; }
na()     { _res="$_res$1${_tab}na$_tab$(_flat "$2")$_nl"; }
missed() { _res="$_res$1${_tab}missed$_tab$(_flat "$2")$_nl"; }

# notice: like progress, but NOT silenced by --quiet; reserved for the status
# roll-up, the one line an automated caller wants most.
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null; }

# _emit_time -> the run time; when a call was slow (SLOW_SEC), capped or not
# run, also the host load at start and end and where the time went (bounded
# calls summed per command, largest first, and the time outside them).
_emit_time() {
    local f="${_tmp_dir:+$_tmp_dir/time.log}" counts
    fact "run time: $(_elapsed)s of ${RUN_DEADLINE}s allowed"
    [ -n "$f" ] && [ -s "$f" ] || return 0
    # calls, stopped at a cap or the deadline, not run, slow
    counts="$(awk -F'\t' -v s="$SLOW_SEC" '
        { n++ } $2 ~ /^(capped|cut)/ { c++ } $2 == "not run" { r++ } $2 != "not run" && $1 >= s * 1000 { w++ }
        END { printf "%d %d %d %d", n, c, r, w }' "$f")"
    set -- $counts
    [ "$2" -gt 0 ] || [ "$3" -gt 0 ] || [ "$4" -gt 0 ] || return 0
    fact "host load at start: ${_load0:-n/a}"
    fact "host load at end:   $(_host_load)"
    fact "bounded calls: $1; stopped at their cap or the deadline: $2; not run past the deadline: $3"
    fact "where the time went (every bounded call, summed per command, largest first):"
    _now_ms
    LC_ALL=C awk -F'\t' -v run="$((_ms - _run_ms0))" '
        $2 == "not run" { nr[$3]++; next }
        { ms[$3] += $1; n[$3]++; tot += $1; if ($2 != "ran") { o[$3, $2]++; if (!(($3, $2) in seen)) { seen[$3, $2] = 1; ol[$3] = ol[$3] SUBSEP $2 } } }
        END {
            for (k in ms) {
                x = ""; m = split(substr(ol[k], 2), L, SUBSEP)
                for (i = 1; i <= m; i++) x = x ", " o[k, L[i]] " " L[i]
                printf "%d\t%6.1fs  %s%s%s\n", ms[k], ms[k] / 1000, k, (n[k] > 1 ? " x" n[k] : ""), x
            }
            out = run - tot
            if (out > 0) printf "%d\t%6.1fs  (outside bounded calls: shell work and file reads)\n", out, out / 1000
        }' "$f" | sort -t "$_tab" -k1,1nr | head -n 10 | cut -f2- \
        | while IFS= read -r l; do fact "    $l"; done
    # every command lost to the deadline, whatever the table above kept
    awk -F'\t' '$2 == "not run" { c[$3]++ } END { for (k in c) printf "%s x%d\n", k, c[k] }' "$f" | sort \
        | while IFS= read -r l; do fact "         -   $l not run (deadline)"; done
}

# emit_status -> the roll-up section. Call it immediately before emit_footer.
# Also repeats each gap on fd 3 so the operator sees it while still logged in.
emit_status() {
    [ -n "$_goals" ] || return 0
    local k lab outs u why total=0 obtained=0 nacount=0 blocked=0 gaps='' nas='' oks='' stray deadline=''
    while IFS="$_tab" read -r k lab; do
        [ -n "$k" ] || continue
        total=$((total + 1))
        # every outcome recorded for this key, in order, and the distinct set
        outs="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { printf "%s%s", (n++ ? ", " : ""), $2 }')"
        u="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k && !s[$2]++ { printf "%s%s", (n++ ? " " : ""), $2 }')"
        case "$u" in
            got) obtained=$((obtained + 1)); oks="$oks $lab,"; continue ;;
            na)  nacount=$((nacount + 1))
                 nas="$nas$lab — $(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { print $3; exit }')$_nl"
                 continue ;;
        esac
        blocked=$((blocked + 1))
        why="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k && $2 == "missed" { printf "%s%s", (n++ ? "; " : ""), $3 }')"
        case "$u" in
            '')     why='not reached' ;;
            missed) ;;
            *)      why="resolved $(printf '%s' "$outs" | awk -F', ' '{print NF}') times: $outs${why:+ — $why}" ;;
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
    _emit_time
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

# ---- reasoned-absence helpers --------------------------------------------------
_errfile=""
NET_TIMEOUT=5
_init_probe() { _errfile="$(_tmp probe.err)"; _logwin="$(_tmp logwin)"; }

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

probe() {
    local label="$1"; shift
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    local out rc
    out="$(_bounded "$@" 2>"$_errfile")"; rc=$?
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# probe_merged: like probe but folds stderr into stdout (java -version etc.).
probe_merged() {
    local label="$1"; shift
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    local out rc
    out="$(_bounded "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# java_tls_policy LABEL JAVA_EXE -> the runtime's jdk.tls.disabledAlgorithms
# property. TLS-version and certificate-algorithm rejections seen in agent
# logs originate here as often as in the DB, and the value differs per JDK.
_TLSP_SEEN=""
java_tls_policy() {
    local label="$1" exe="$2" jh sec f prop
    [ -n "$exe" ] || { fact "$label: n/a (java path unknown)"; return; }
    exe="$(readlink -f "$exe" 2>/dev/null || printf '%s' "$exe")"
    jh="$(dirname "$(dirname "$exe")")"
    case " $_TLSP_SEEN " in *" $jh "*) fact "$label: same runtime as above ($jh)"; return ;; esac
    _TLSP_SEEN="$_TLSP_SEEN $jh"
    sec=""
    for f in "$jh/conf/security/java.security" "$jh/lib/security/java.security" "$jh/jre/lib/security/java.security"; do
        [ -f "$f" ] && { sec="$f"; break; }
    done
    [ -z "$sec" ] && { fact "$label: n/a (java.security not found under $jh)"; return; }
    fact "$label: $sec"
    prop="$(awk '/^jdk\.tls\.disabledAlgorithms=/{p=1} p{print; if ($0 !~ /\\$/) exit}' "$sec" 2>/dev/null)"
    if [ -n "$prop" ]; then _emit_labeled "jdk.tls.disabledAlgorithms" "$prop"
    else fact "jdk.tls.disabledAlgorithms: n/a (property not found in $sec)"; fi
}

# dump_file "label" PATH [MAXLINES] -> verbatim file content (framework policy:
# no masking), or a classified reason. Caps at MAXLINES (default 400).
dump_file() {
    local label="$1" path="$2" max="${3:-400}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    total="$(_bounded wc -l "$path" 2>/dev/null | awk '{print $1}')"
    fact "$label (verbatim, $total lines$( [ "${total:-0}" -gt "$max" ] && printf ', first %s shown' "$max" )):"
    _bounded head -n "$max" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# conf_get VAR FILE KEY -> sets VAR to the value of the last non-comment
# "KEY=..." line of FILE, trimmed. Sections D to L ask for the same keys of the
# same files, so each (file, key) is read once per run and then answered from
# _CONF_K/_CONF_V (the report is what the first read saw).
_CONF_K=(); _CONF_V=()
conf_get() {
    local _ck="$2
$3" _ci=0 _cv
    while [ "$_ci" -lt "${#_CONF_K[@]}" ]; do
        if [ "${_CONF_K[$_ci]}" = "$_ck" ]; then
            printf -v "$1" '%s' "${_CONF_V[$_ci]}"; return 0
        fi
        _ci=$((_ci + 1))
    done
    _cv="$(grep -E "^[[:space:]]*$3[[:space:]]*=" "$2" 2>/dev/null | grep -v '^[[:space:]]*#' \
        | tail -n1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    _CONF_K[${#_CONF_K[@]}]="$_ck"; _CONF_V[${#_CONF_V[@]}]="$_cv"
    printf -v "$1" '%s' "$_cv"
}

# tcp_probe "label" HOST PORT -> single bounded TCP connect attempt (load-safe:
# one attempt, NET_TIMEOUT cap through _bounded).
tcp_probe() {
    local label="$1" host="$2" port="$3" rc m0 t
    [ -n "$host" ] && [ -n "$port" ] || { fact "$label: n/a (not applicable: host/port not set)"; return; }
    _now_ms; m0="$_ms"
    CMD_TIMEOUT="$NET_TIMEOUT" _bounded bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
    rc=$?
    _now_ms
    # _now_ms falls back to whole seconds without EPOCHREALTIME or date %N
    if [ -n "${EPOCHREALTIME:-}" ] || [ "$_ms_date" = 1 ]; then t="$((_ms - m0)) ms"; else t="time n/a (no ms clock)"; fi
    if [ "$rc" -eq 0 ]; then
        fact "$label: tcp connect to $host:$port succeeded ($t)"
    elif [ "$rc" -eq 124 ]; then
        fact "$label: tcp connect to $host:$port timed out (${NET_TIMEOUT}s)"
        TCP_DOWN="$TCP_DOWN|$host:$port=tcp connect timed out (${NET_TIMEOUT}s, section G)|"
    else
        fact "$label: tcp connect to $host:$port did not connect (rc=$rc, $t)"
        TCP_DOWN="$TCP_DOWN|$host:$port=tcp connect did not connect (rc=$rc, section G)|"
    fi
}
# endpoints whose section G connect probe failed: "|host:port=reason|..."
TCP_DOWN=""
# tcp_down HOST PORT -> prints the recorded reason and returns 0 when the probe failed
tcp_down() {
    case "$TCP_DOWN" in
        *"|$1:$2="*) printf '%s' "$TCP_DOWN" | tr '|' '\n' | grep -F -m1 "$1:$2=" | cut -d= -f2- ; return 0 ;;
    esac
    return 1
}

# ---- discovery (run once) ------------------------------------------------------
# Parallel arrays of discovered processes and install dirs (bash 3.2 safe).
AG_PIDS=(); AG_KINDS=()      # whatap components: dbx dmx prx xos xcub dbxc
DBP_PIDS=(); DBP_KINDS=()    # database server processes on this host
HOME_DIRS=(); HOME_SRCS=()   # agent install dir candidates + how each was found
INST_DIRS=()                 # dirs containing a whatap.conf (one per agent instance)
XOS_CONFS=()                 # xos.conf files found under homes
UNRES_HOME=""                # "pid(kind) ..." whose install dir could not be read off /proc
UNRES_WHY=""                 # "pid: reason; ..." for the processes in UNRES_HOME
UNRES_PID=(); UNRES_CWD=(); UNRES_JAR=(); UNRES_W=(); UNRES_P=()   # per process, before --home matching
UNRES_BYHOME=""              # "pid(kind) -> home" resolved by a matching --home
UNRES_PRIV=0                 # 1 when a privilege gap left a process unresolved
OPT_HOME_ADDED=0             # --home dirs that resolved to an existing directory
OPT_HOME_BAD=""              # --home values that did not
OPT_HOME_OK=""               # --home dirs accepted, physical, one per line
ADD_HOME_DIR=""              # the physical dir the last successful add_home settled on
FIND_DENIED=""               # homes whose search for whatap.conf/xos.conf hit a denied entry
FIND_FAILED=""               # homes whose search timed out or failed otherwise
ADD_HOME_WHY=""              # why the last add_home rejected its dir
PROC_HIDDEN=""               # non-empty when /proc hides other users' processes

# _proc_hidden -> 0 when a non-root run sees /proc through hidepid=1|2|
# invisible|noaccess, i.e. other users' processes are hidden or unreadable
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

# _self_tree -> " pid " for this collector and each of its ancestors, so the
# shell that started the collector is never counted as a component process
_self_tree() {
    local p="$$" n=0
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$n" -lt 30 ]; do
        printf ' %s ' "$p"
        p="$(awk '/^PPid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"
        n=$((n + 1))
    done
}

# _kind_of_proc PID ARGS -> the component kind of one /proc process, or "".
# ARGS is the cmdline with one argument per line. The java agents (dbx, dmx,
# prx, xos) count only when the program is java (argv[0] or /proc/<pid>/exe)
# and an argument names the whatap.agent jar or class: a shell or an editor
# whose arguments merely mention the jar is not an agent.
_kind_of_proc() {
    local a0 w0 exe k
    a0="$(printf '%s\n' "$2" | head -n1)"; w0="${a0%% *}"; w0="${w0##*/}"
    case "$w0" in
        java|javaw|jsvc) ;;
        *) exe="$(readlink "/proc/$1/exe" 2>/dev/null)"; exe="${exe##*/}"
           case "$exe" in
               java|javaw|jsvc) ;;
               *) case "$w0" in *dbxc*) echo dbxc ;; *xcub*) echo xcub ;; esac
                  return ;;
           esac ;;
    esac
    k="$(printf '%s\n' "$2" | grep -oE 'whatap\.agent\.(dbx|dmx|prx|xos)' | head -n1)"
    printf '%s' "${k#whatap.agent.}"
}

# _has_glob PATTERN-EXPANSION... -> 0 when the shell glob matched a path (no fork)
_has_glob() { for _g in "$@"; do [ -e "$_g" ] && return 0; done; return 1; }

_kind_of_cmdline() {
    case "$1" in
        *whatap.agent.dbx*)  echo dbx ;;
        *whatap.agent.dmx*)  echo dmx ;;
        *whatap.agent.prx*)  echo prx ;;
        *whatap.agent.xos*)  echo xos ;;
        *dbxc*)              echo dbxc ;;
        *xcub*)              echo xcub ;;
        *)                   echo "" ;;
    esac
}

# _db_kind_of_comm COMM -> _DBK = the database engine a comm names, or "".
# It sets a variable instead of printing: discovery calls it for every pid,
# and a $(...) per pid is a fork per pid.
_DBK=""
_db_kind_of_comm() {
    case "$1" in
        postgres|postmaster)      _DBK=postgresql ;;
        mysqld|mariadbd)          _DBK=mysql/mariadb ;;
        ora_pmon*|oracle*)        _DBK=oracle ;;
        tbsvr*)                   _DBK=tibero ;;
        redis-server|valkey-serv*) _DBK=redis/valkey ;;
        mongod)                   _DBK=mongodb ;;
        sqlservr)                 _DBK=mssql ;;
        db2sysc)                  _DBK=db2 ;;
        cub_master|cub_server|cub_broker) _DBK=cubrid ;;
        *)                        _DBK="" ;;
    esac
}

# _read_nul FILE -> _RN = FILE with each NUL turned into a space and trailing
# newlines dropped: what $(tr '\0' ' ' < FILE) gave, without the two forks.
# A last argument with no NUL after it (setproctitle) is kept as it is.
_RN=""
_read_nul() {
    local c
    _RN=""
    while IFS= read -r -d '' c; do _RN="$_RN$c "; done 2>/dev/null < "$1"
    _RN="$_RN$c"
    _RN="${_RN%"${_RN##*[!"$_nl"]}"}"
}

add_home() { # DIR SRC — dedupe on DIR; returns 1 with ADD_HOME_WHY when DIR is unusable
    local d="$1" s="$2" i=0 r
    ADD_HOME_WHY=""
    [ -n "$d" ] || { ADD_HOME_WHY="empty path"; return 1; }
    case "$d" in *" (deleted)") ADD_HOME_WHY="$d: directory deleted"; return 1 ;; esac
    [ -d "$d" ] || { ADD_HOME_WHY="$d: not a directory or not reachable"; return 1; }
    # physical path: /proc/<pid>/cwd is physical, so every comparison is too
    r="$(cd "$d" 2>/dev/null && pwd -P)" || { ADD_HOME_WHY="$d: cannot be entered (permission denied)"; return 1; }
    d="$r"
    case "$d" in
        /|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/tmp|/var/tmp)
            ADD_HOME_WHY="$d: not taken as an install dir (a system root)"; return 1 ;;
    esac
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        [ "${HOME_DIRS[$i]}" = "$d" ] && { ADD_HOME_DIR="$d"; return 0; }
        i=$((i + 1))
    done
    HOME_DIRS[${#HOME_DIRS[@]}]="$d"
    HOME_SRCS[${#HOME_SRCS[@]}]="$s"
    ADD_HOME_DIR="$d"
}

add_inst() { # DIR — dedupe
    local d="$1" i=0
    [ -n "$d" ] && [ -d "$d" ] || return
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        [ "${INST_DIRS[$i]}" = "$d" ] && return
        i=$((i + 1))
    done
    INST_DIRS[${#INST_DIRS[@]}]="$d"
}

# 1) process scan: /proc when available, `ps` otherwise (AIX / HP-UX etc.)
_disc_procs() {
    local d pid cl args kind comm jarpath reljar cwd self
    self="$(_self_tree)"
    if [ -d /proc/1 ]; then
        for d in /proc/[0-9]*; do
            [ -r "$d/cmdline" ] || continue
            pid="${d#/proc/}"
            case "$self" in *" $pid "*) continue ;; esac
            # a cheap filter first: only a cmdline naming a component is read twice
            _read_nul "$d/cmdline"; cl="$_RN"
            [ -n "$cl" ] || continue
            case "$cl" in *whatap.agent.*|*dbxc*|*xcub*) ;; *) cl="" ;; esac
            kind=""
            if [ -n "$cl" ]; then
                args="$(tr '\0' '\n' 2>/dev/null < "$d/cmdline")"
                kind="$(_kind_of_proc "$pid" "$args")"
            fi
            if [ -n "$kind" ]; then
                AG_PIDS[${#AG_PIDS[@]}]="$pid"
                AG_KINDS[${#AG_KINDS[@]}]="$kind"
                cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
                local ok=0 why="" priv=0
                if [ -z "$cwd" ]; then why="/proc/$pid/cwd not readable"; priv=1
                elif add_home "$cwd" "cwd of $kind process $pid"; then ok=1
                else why="cwd $ADD_HOME_WHY"; case "$ADD_HOME_WHY" in *"permission denied"*) priv=1 ;; esac; fi
                # one argument per line, so a path with spaces stays whole; a
                # cmdline that is a single string (exec -a) falls back to the
                # span from the first "/" to the jar name
                jarpath="$(printf '%s\n' "$args" | grep -E '^/.*whatap\.agent\.[a-z]+[^/]*\.jar$' | head -n1)"
                [ -n "$jarpath" ] || jarpath="$(printf '%s\n' "$args" | grep -oE ' /.*whatap\.agent\.[a-z]+[^/]*\.jar' | head -n1 | sed 's/^ //')"
                reljar="$(printf '%s\n' "$args" | grep -E '^([^/ -][^ ]*)?whatap\.agent\.[a-z]+[^/ ]*\.jar$' | head -n1)"
                [ -n "$reljar" ] || reljar="$(printf '%s\n' "$args" | grep -oE '(^| )-jar ([^ /][^ ]*)?whatap\.agent\.[a-z]+[^ /]*\.jar' | head -n1 | sed 's/.*-jar //')"
                if [ -n "$jarpath" ]; then
                    if add_home "$(dirname "$jarpath")" "jar path of $kind process $pid"; then ok=1
                    else why="$why${why:+, }jar dir $ADD_HOME_WHY"; fi
                else
                    why="$why${why:+, }no absolute whatap.agent jar path in the cmdline"
                fi
                # a relative -jar path is resolved against the cwd; a cwd that
                # cannot be read or entered leaves the home of this process unknown
                if [ "$ok" = 0 ]; then
                    UNRES_PID[${#UNRES_PID[@]}]="$pid($kind)"
                    UNRES_CWD[${#UNRES_CWD[@]}]="${cwd% (deleted)}"
                    UNRES_JAR[${#UNRES_JAR[@]}]="$reljar"
                    UNRES_W[${#UNRES_W[@]}]="$why"
                    UNRES_P[${#UNRES_P[@]}]="$priv"
                fi
                continue
            fi
            comm=""
            IFS= read -r -d '' comm 2>/dev/null < "$d/comm"
            comm="${comm%"${comm##*[!"$_nl"]}"}"
            _db_kind_of_comm "$comm"; kind="$_DBK"
            if [ -n "$kind" ]; then
                DBP_PIDS[${#DBP_PIDS[@]}]="$pid"
                DBP_KINDS[${#DBP_KINDS[@]}]="$kind"
            fi
        done
    else
        # non-Linux fallback: parse `ps`, derive homes from absolute jar paths
        for pid in $(_bounded ps -ef 2>/dev/null | awk '/whatap\.agent\.|dbxc|xcub/ && !/awk/ {print $2}'); do
            cl="$(_bounded ps -o args= -p "$pid" 2>/dev/null)"
            kind="$(_kind_of_cmdline "$cl")"
            [ -n "$kind" ] || continue
            AG_PIDS[${#AG_PIDS[@]}]="$pid"
            AG_KINDS[${#AG_KINDS[@]}]="$kind"
            jarpath="$(printf '%s\n' "$cl" | tr ' ' '\n' | grep -E '^/.*whatap\.agent\.[a-z]+.*\.jar$' | head -n1)"
            if [ -n "$jarpath" ] && add_home "$(dirname "$jarpath")" "jar path of $kind process $pid (ps)"; then :
            else
                UNRES_PID[${#UNRES_PID[@]}]="$pid($kind)"; UNRES_CWD[${#UNRES_CWD[@]}]=""; UNRES_JAR[${#UNRES_JAR[@]}]=""
                UNRES_W[${#UNRES_W[@]}]="${jarpath:+jar dir $ADD_HOME_WHY}${jarpath:-no absolute whatap.agent jar path in ps args}"
                UNRES_P[${#UNRES_P[@]}]=0
            fi
        done
    fi
    _proc_hidden && PROC_HIDDEN="$PROC_STATE"
}

# 2) homes given on the command line, and the unresolved processes they match
_disc_homes() {
    local h
    if [ -n "$OPT_HOMES" ]; then
        while IFS= read -r h; do
            [ -n "$h" ] || continue
            if add_home "$h" "option --home"; then OPT_HOME_ADDED=$((OPT_HOME_ADDED + 1)); OPT_HOME_OK="$OPT_HOME_OK$ADD_HOME_DIR$_nl"
            else OPT_HOME_BAD="$OPT_HOME_BAD${OPT_HOME_BAD:+; }$ADD_HOME_WHY"; fi
        done <<EOF
$OPT_HOMES
EOF
    fi

    # an unresolved process counts as resolved by a --home only when the home
    # matches it: its known cwd is the home or under it, or its relative jar
    # path exists under the home. An unrelated --home resolves nothing.
    local ui=0 hh hr
    while [ "$ui" -lt "${#UNRES_PID[@]}" ]; do
        hr=""
        while IFS= read -r hh; do
            [ -n "$hh" ] || continue
            # already physical and accepted by add_home; a rejected --home matches nothing
            if [ -n "${UNRES_CWD[$ui]}" ]; then
                case "${UNRES_CWD[$ui]}/" in "$hh"/*) hr="$hh" ;; esac
            fi
            [ -z "$hr" ] && [ -n "${UNRES_JAR[$ui]}" ] && [ -f "$hh/${UNRES_JAR[$ui]}" ] && hr="$hh"
            [ -n "$hr" ] && break
        done <<EOF
$OPT_HOME_OK
EOF
        if [ -n "$hr" ]; then
            UNRES_BYHOME="$UNRES_BYHOME${UNRES_BYHOME:+; }${UNRES_PID[$ui]} -> $hr"
        else
            UNRES_HOME="$UNRES_HOME ${UNRES_PID[$ui]}"
            UNRES_WHY="$UNRES_WHY${UNRES_WHY:+; }${UNRES_PID[$ui]%%(*}: ${UNRES_W[$ui]}"
            [ "${UNRES_P[$ui]}" = 1 ] && UNRES_PRIV=1
        fi
        ui=$((ui + 1))
    done
    UNRES_HOME="${UNRES_HOME# }"
}

# 3) instances = dirs holding a whatap.conf under each home (depth-capped);
#    xos.conf files are recorded the same way
_disc_confs() {
    local h i=0 f
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        h="${HOME_DIRS[$i]}"
        # find exits non-zero on a denied entry: the search is then incomplete.
        # A cap (124) or another failure is told apart from a denial.
        local frc
        _bounded find "$h" -maxdepth 2 \( -name whatap.conf -o -name xos.conf \) \( -type f -o -type l \) > "$(_tmp confs)" 2>"$(_tmp confs.err)"
        frc=$?
        if [ "$frc" -eq 124 ]; then FIND_FAILED="$FIND_FAILED${FIND_FAILED:+; }$h (timed out: ${CMD_TIMEOUT}s)"
        elif [ "$frc" -ne 0 ]; then
            if grep -q 'ermission denied' "$(_tmp confs.err)" 2>/dev/null; then FIND_DENIED="$FIND_DENIED $h"
            else FIND_FAILED="$FIND_FAILED${FIND_FAILED:+; }$h (find exit $frc: $(head -n1 "$(_tmp confs.err)" 2>/dev/null | cut -c1-100))"; fi
        fi
        # line-wise: install paths can contain spaces
        while IFS= read -r f; do
            [ -n "$f" ] && add_inst "$(dirname "$f")"
        done <<EOF
$(grep '/whatap\.conf$' "$(_tmp confs)" 2>/dev/null | head -n 20)
EOF
        while IFS= read -r f; do
            [ -n "$f" ] && XOS_CONFS[${#XOS_CONFS[@]}]="$f"
        done <<EOF
$(grep '/xos\.conf$' "$(_tmp confs)" 2>/dev/null | head -n 20)
EOF
        i=$((i + 1))
    done
}

# 4) watched ports = defaults (6600 collection server, 3002 xos->dbx)
#    extended by whatap.server.port / xos_port values found in the confs
_disc_ports() {
    local i p wp xp ports="6600 3002"
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        conf_get wp "${INST_DIRS[$i]}/whatap.conf" 'whatap\.server\.port'
        conf_get xp "${INST_DIRS[$i]}/whatap.conf" xos_port
        for p in "$wp" "$xp"; do
            case "$p" in [0-9]*) ports="$ports $p" ;; esac
        done
        i=$((i + 1))
    done
    WATCH_PORTS="$(printf '%s\n' $ports | sort -un | tr '\n' ' ' | sed 's/ $//')"
    WATCH_PORTS_RE="$(printf '%s\n' $ports | sort -un | tr '\n' '|' | sed 's/|$//')"
}

discover() {
    _disc_procs
    _disc_homes
    _disc_confs
    _disc_ports
}
WATCH_PORTS="6600 3002"
WATCH_PORTS_RE="6600|3002"

# counts of discovered component kinds (computed after discover)
_count_kind() {
    local want="$1" i=0 n=0
    while [ "$i" -lt "${#AG_KINDS[@]}" ]; do
        [ "${AG_KINDS[$i]}" = "$want" ] && n=$((n + 1))
        i=$((i + 1))
    done
    echo "$n"
}

# ---- JDBC SQL-pack runner (Tier 2, --sql) --------------------------------------
# The DBX agent works over JDBC end-to-end: installing it never needed a DB
# client, so a client cannot be assumed anywhere. The one guaranteed path to
# the DB is the agent host itself — java (a DBX prerequisite) + the proven
# driver in jdbc/ + network reachability. This runner reuses exactly those.
# JDK 9+ -> jshell; JDK 8 -> jrunscript (Nashorn). Read-only; each statement
# capped at 20s, rows at 200; a SQL error prints as a fact and the run goes on.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
_JBIN=""
_JDBC_MODE=""

_write_runner_jsh() {
    cat > "$1" <<'JSHEOF'
import java.sql.*;
import java.nio.file.*;
import java.util.*;
String pack = System.getenv("WHATAP_GGT_PACK");
String url  = System.getenv("WHATAP_GGT_URL");
String usr  = System.getenv("WHATAP_GGT_USER");
String pw   = System.getenv("WHATAP_GGT_PW");
List<String> stmts = new ArrayList<>();
StringBuilder cur = new StringBuilder();
for (String line : Files.readAllLines(Paths.get(pack))) {
    String t = line.trim();
    if (t.isEmpty() || t.startsWith("--") || t.startsWith("\\")
        || t.matches("(?i)^(SET|WHENEVER|PROMPT|EXIT|GO|USE)\\b.*")) continue;
    cur.append(line).append('\n');
    if (t.endsWith(";")) {
        String s = cur.toString().trim();
        stmts.add(s.substring(0, s.length() - 1));
        cur.setLength(0);
    }
}
String ping = System.getenv("WHATAP_GGT_PING");
String mark = System.getenv("WHATAP_GGT_MARK");
DriverManager.setLoginTimeout(10);
long t0 = System.nanoTime();
try (Connection c = DriverManager.getConnection(url, usr, pw)) {
    long t1 = System.nanoTime();
    String rt = mark + " jdbc connect " + (t1 - t0) / 1000000 + " ms";
    if (ping != null && !ping.isEmpty()) {
        try (Statement st = c.createStatement()) {
            st.setQueryTimeout(20);
            long q0 = System.nanoTime();
            try (ResultSet rs = st.executeQuery(ping)) { while (rs.next()) { } }
            rt += "; " + ping + " " + (System.nanoTime() - q0) / 1000000 + " ms";
        } catch (SQLException e) {
            rt += "; " + ping + " failed: " + String.valueOf(e.getMessage()).split("\n")[0];
        }
    }
    System.out.println(rt);
    for (String s : stmts) {
        try (Statement st = c.createStatement()) {
            st.setQueryTimeout(20);
            boolean has = st.execute(s);
            if (has) {
                try (ResultSet rs = st.getResultSet()) {
                    ResultSetMetaData md = rs.getMetaData();
                    int n = md.getColumnCount();
                    StringBuilder h = new StringBuilder();
                    for (int i = 1; i <= n; i++) { if (i > 1) h.append(" | "); h.append(md.getColumnLabel(i)); }
                    System.out.println(h);
                    int rows = 0;
                    while (rs.next() && rows < 200) {
                        StringBuilder r = new StringBuilder();
                        for (int i = 1; i <= n; i++) { if (i > 1) r.append(" | "); String v = rs.getString(i); r.append(v == null ? "NULL" : v); }
                        System.out.println(r);
                        rows++;
                    }
                    if (rows >= 200) System.out.println("(truncated at 200 rows)");
                    System.out.println("(" + rows + " rows)");
                    System.out.println();
                }
            } else { System.out.println("(ok)"); }
        } catch (SQLException e) {
            System.out.println("SQL-ERROR: " + String.valueOf(e.getMessage()).split("\n")[0]);
            System.out.println();
        }
    }
} catch (SQLException e) {
    System.out.println("CONNECT-ERROR: " + String.valueOf(e.getMessage()).split("\n")[0]);
}
/exit
JSHEOF
}

_write_runner_js() {
    cat > "$1" <<'JSEOF'
var Files = java.nio.file.Files, Paths = java.nio.file.Paths, Sys = java.lang.System;
var pack = Sys.getenv("WHATAP_GGT_PACK"), url = Sys.getenv("WHATAP_GGT_URL");
var usr = Sys.getenv("WHATAP_GGT_USER"), pw = Sys.getenv("WHATAP_GGT_PW");
var text = new java.lang.String(Files.readAllBytes(Paths.get(pack)), "UTF-8");
var stmts = [], cur = "";
text.split("\n").forEach(function (line) {
    var t = line.trim();
    if (t === "" || t.indexOf("--") === 0 || t.indexOf("\\") === 0
        || /^(SET|WHENEVER|PROMPT|EXIT|GO|USE)\b/i.test(t)) return;
    cur += line + "\n";
    if (/;\s*$/.test(t)) { stmts.push(cur.replace(/;\s*$/m, "")); cur = ""; }
});
var ping = Sys.getenv("WHATAP_GGT_PING"), mark = Sys.getenv("WHATAP_GGT_MARK");
java.sql.DriverManager.setLoginTimeout(10);
var conn, t0 = Sys.nanoTime(), t1;
try { conn = java.sql.DriverManager.getConnection(url, usr, pw); t1 = Sys.nanoTime(); }
catch (e) { print("CONNECT-ERROR: " + ("" + e.message).split("\n")[0]); }
if (conn) {
    var rt = mark + " jdbc connect " + Math.floor((t1 - t0) / 1000000) + " ms";
    if (ping) {
        var ps;
        try {
            ps = conn.createStatement(); ps.setQueryTimeout(20);
            var q0 = Sys.nanoTime(), prs = ps.executeQuery(ping);
            while (prs.next()) { }
            rt += "; " + ping + " " + Math.floor((Sys.nanoTime() - q0) / 1000000) + " ms";
            ps.close();
        } catch (e) { rt += "; " + ping + " failed: " + ("" + e.message).split("\n")[0]; if (ps) ps.close(); }
    }
    print(rt);
    stmts.forEach(function (s) {
        var st;
        try {
            st = conn.createStatement(); st.setQueryTimeout(20);
            if (st.execute(s)) {
                var rs = st.getResultSet(), md = rs.getMetaData(), n = md.getColumnCount();
                var h = []; for (var i = 1; i <= n; i++) h.push(md.getColumnLabel(i)); print(h.join(" | "));
                var rows = 0;
                while (rs.next() && rows < 200) {
                    var r = []; for (var j = 1; j <= n; j++) { var v = rs.getString(j); r.push(v === null ? "NULL" : v); }
                    print(r.join(" | ")); rows++;
                }
                if (rows >= 200) print("(truncated at 200 rows)");
                print("(" + rows + " rows)"); print("");
            } else { print("(ok)"); }
            st.close();
        } catch (e) { print("SQL-ERROR: " + ("" + e.message).split("\n")[0]); print(""); if (st) st.close(); }
    });
    conn.close();
}
JSEOF
}

_pick_java_bindir() {
    _JBIN=""; _JDBC_MODE=""
    local i=0 exe
    while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
        exe="$(readlink "/proc/${AG_PIDS[$i]}/exe" 2>/dev/null)"
        case "$exe" in */java) _JBIN="$(dirname "$exe")"; break ;; esac
        i=$((i + 1))
    done
    [ -z "$_JBIN" ] && have java && _JBIN="$(dirname "$(command -v java)")"
    [ -n "$_JBIN" ] || return 1
    if [ -x "$_JBIN/jshell" ]; then _JDBC_MODE="jshell"
    elif [ -x "$_JBIN/jrunscript" ] && _bounded "$_JBIN/jrunscript" -e 'print(1)' >/dev/null 2>&1; then _JDBC_MODE="jrunscript"
    else return 1; fi
    return 0
}

_find_jdbc_jar() { # GLOB... -> first matching jar under any home/instance jdbc dir
    local d g j
    for d in "${HOME_DIRS[@]}" "${INST_DIRS[@]}"; do
        for g in "$@"; do
            for j in "$d"/jdbc/$g; do
                [ -f "$j" ] && { printf '%s' "$j"; return 0; }
            done
        done
    done
    return 1
}

CRED_USER=""; CRED_PW=""; CRED_WHY=""
# _get_creds LABEL -> 0 with CRED_USER/CRED_PW set, 1 = skip, with CRED_WHY
# for the sql goal. The terminal prompt waits no longer than what is left of
# RUN_DEADLINE: a run nobody answers still reaches its footer.
_get_creds() {
    local left rc
    CRED_USER="${WHATAP_GGT_USER:-}"; CRED_PW="${WHATAP_GGT_PW:-}"; CRED_WHY=""
    [ -n "$CRED_USER" ] && { fact "credentials: from WHATAP_GGT_USER env"; return 0; }
    if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
        fact "credentials: n/a (no terminal and WHATAP_GGT_USER unset — instance skipped)"
        CRED_WHY="no credentials (set WHATAP_GGT_USER / WHATAP_GGT_PW, or run it on a terminal)"
        return 1
    fi
    left=$((RUN_DEADLINE - $(_elapsed)))
    if [ "$left" -le 0 ]; then
        fact "credentials: n/a (run deadline reached — instance skipped)"
        CRED_WHY="no credentials (run deadline ${RUN_DEADLINE}s reached before the terminal prompt)"
        return 1
    fi
    printf '!! monitoring account user for %s (empty = skip this instance): ' "$1" > /dev/tty
    # read -t returns >128 on the timeout; end of input is "none entered"
    IFS= read -r -t "$left" CRED_USER < /dev/tty; rc=$?
    if [ "$rc" -gt 128 ]; then
        printf '\n' > /dev/tty
        CRED_USER=""
        fact "credentials: n/a (timed out: ${left}s waiting for terminal input — instance skipped)"
        CRED_WHY="no credentials (terminal prompt timed out after ${left}s, the rest of RUN_DEADLINE; set WHATAP_GGT_USER / WHATAP_GGT_PW)"
        return 1
    fi
    [ -z "$CRED_USER" ] && { fact "credentials: none entered — instance skipped"
        CRED_WHY="no credentials (set WHATAP_GGT_USER / WHATAP_GGT_PW, or run it on a terminal)"; return 1; }
    printf '!! password for %s: ' "$CRED_USER" > /dev/tty
    left=$((RUN_DEADLINE - $(_elapsed)))
    [ "$left" -gt 0 ] || left=1
    IFS= read -rs -t "$left" CRED_PW < /dev/tty; rc=$?
    if [ "$rc" -gt 128 ]; then
        printf '\n' > /dev/tty
        CRED_PW=""
        fact "credentials: n/a (timed out: ${left}s waiting for the password — instance skipped)"
        CRED_WHY="no credentials (password prompt timed out after ${left}s, the rest of RUN_DEADLINE; set WHATAP_GGT_USER / WHATAP_GGT_PW)"
        CRED_USER=""
        return 1
    fi
    printf '\n' > /dev/tty
    fact "credentials: entered on terminal (user=$CRED_USER)"
    return 0
}

_run_jdbc_pack() { # PACKFILE URL JAR [PING] -> runner output on stdout
    local rfile out
    # UTF-8 is forced on the runner VM: the report must carry DB text (Korean
    # query text etc.) byte-true even though the collector itself runs LC_ALL=C
    # credentials travel in the child's environment only, never on a command
    # line; the runner file lives in the run's private directory
    if [ "$_JDBC_MODE" = "jshell" ]; then
        rfile="$(_tmp runner.jsh)"
        _write_runner_jsh "$rfile"
        CMD_TIMEOUT=120 WHATAP_GGT_PACK="$1" WHATAP_GGT_URL="$2" WHATAP_GGT_USER="$CRED_USER" WHATAP_GGT_PW="$CRED_PW" WHATAP_GGT_PING="${4:-}" WHATAP_GGT_MARK="$RTT_MARK" \
            _bounded "$_JBIN/jshell" -q -J-Dfile.encoding=UTF-8 -R-Dfile.encoding=UTF-8 --class-path "$3" "$rfile" 2>&1
        echo "$?" > "$(_tmp runner.rc)"
    else
        rfile="$(_tmp runner.js)"
        _write_runner_js "$rfile"
        CMD_TIMEOUT=120 WHATAP_GGT_PACK="$1" WHATAP_GGT_URL="$2" WHATAP_GGT_USER="$CRED_USER" WHATAP_GGT_PW="$CRED_PW" WHATAP_GGT_PING="${4:-}" WHATAP_GGT_MARK="$RTT_MARK" \
            _bounded "$_JBIN/jrunscript" -J-Dfile.encoding=UTF-8 -cp "$3" "$rfile" 2>&1
        echo "$?" > "$(_tmp runner.rc)"
    fi
    rm -f "$rfile" 2>/dev/null
}

# The runner's timing line starts with a per-run token nobody else knows, so a
# pack row cannot pose as it. _rtt_split OUT -> RTT_LINE = the first line that
# starts with the token (token removed), RTT_REST = OUT without that one line.
RTT_MARK=""; RTT_LINE=""; RTT_REST=""
_rtt_split() {
    RTT_LINE=""; RTT_REST="$1"
    case "$_nl$1" in *"$_nl$RTT_MARK "*) ;; *) return 1 ;; esac
    local pre="${1%%"$RTT_MARK "*}" post
    post="${1#*"$RTT_MARK "}"
    RTT_LINE="${post%%"$_nl"*}"
    case "$post" in *"$_nl"*) post="${post#*"$_nl"}" ;; *) post="" ;; esac
    RTT_REST="$pre$post"; RTT_REST="${RTT_REST%"$_nl"}"
    return 0
}

# ---- log window helpers --------------------------------------------------------
LOG_TAIL_LINES=200      # verbatim tail of the newest agent log
LOG_SCAN_LINES=5000     # bounded window for pattern counting (never whole logs)
_logwin=""              # set by _init_probe, inside the run's private directory

newest_matching() { # DIR GLOB -> newest matching file path (mtime), or empty
    _bounded ls -1t "$1"/$2 2>/dev/null | head -n1
}

load_logwin() { # FILE -> fills $_logwin with its last LOG_SCAN_LINES lines
    : > "$_logwin" 2>/dev/null
    [ -n "$1" ] && [ -r "$1" ] && _bounded tail -n "$LOG_SCAN_LINES" "$1" > "$_logwin" 2>/dev/null
}

count_in_win() { # LABEL ERE
    local n
    n="$(grep -cE "$2" "$_logwin" 2>/dev/null)"
    fact "$1: ${n:-0} line(s) in last $LOG_SCAN_LINES log lines"
}

sample_in_win() { # LABEL ERE [N] -> first N matching lines, verbatim
    local out
    out="$(grep -E "$2" "$_logwin" 2>/dev/null | head -n "${3:-3}")"
    if [ -n "$out" ]; then _emit_labeled "$1 (sample)" "$out"; else fact "$1 (sample): n/a (no matching lines)"; fi
}

# ---- report body ----------------------------------------------------------------
# [1] collection environment; the tool list explains a later "command not found"
_rep_env() {
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "tools:"
    for t in ps ss netstat ip getent nslookup java systemctl crontab timeout find readlink; do
        if have "$t"; then printf '        %-12s present\n' "$t"
        else printf '        %-12s absent\n' "$t"; fi
    done
    fact "/proc: ${PROC_STATE:-n/a (mountinfo not read)}"
}

# A. host & platform: arch and Java are asked for in most cases
_rep_host() {
    section "A. Host & platform"
    probe "hostname" hostname
    read_proc "os-release" /etc/os-release
    # the machine is the last field of `uname -smr` (uname prints the fields
    # in its own order, and a kernel release has no blank)
    _k="$(probe "kernel" uname -smr)"
    printf '%s\n' "$_k"
    case "$_k" in
        "    kernel: n/a ("*) fact "architecture: n/a (${_k#    kernel: n/a (}" ;;
        "    kernel: "*" "*)  fact "architecture: ${_k##* }" ;;
        "    kernel (exit "*" "*)
                             _e="${_k#    kernel (exit }"; fact "architecture (exit ${_e%%)*}): ${_k##* }" ;;
        *)                   fact "architecture: n/a (no machine field in the uname -smr output)" ;;
    esac
    probe "cpu count" nproc
    if [ -r /proc/meminfo ]; then
        fact "memory: $(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%d MB total, %d MB available", t/1024, a/1024}' /proc/meminfo 2>/dev/null)"
    else
        fact "memory: n/a (path not found: /proc/meminfo)"
    fi
    if [ -f /.dockerenv ]; then fact "container: /.dockerenv present"
    elif [ -r /proc/1/cgroup ] && grep -qE 'docker|kubepods|containerd' /proc/1/cgroup 2>/dev/null; then
        fact "container: container hint in /proc/1/cgroup"
    else fact "container: no container marker found"; fi
    fact "system time: $(date '+%Y-%m-%d %H:%M:%S %Z(%z)' 2>/dev/null || echo unknown)"
    fact "system time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    read_proc "locale (LANG)" /etc/locale.conf 2>/dev/null || true
    fact "LANG env: ${LANG:-unset}"
    probe_merged "java on PATH" java -version
    if have java; then java_tls_policy "java on PATH security file" "$(command -v java)"; fi
}

# B. discovery result and host role
_rep_discovery() {
    section "B. Component discovery & host role"
    local i n_dbx n_dmx n_prx n_xos n_xcub n_dbxc
    n_dbx="$(_count_kind dbx)"; n_dmx="$(_count_kind dmx)"; n_prx="$(_count_kind prx)"
    n_xos="$(_count_kind xos)"; n_xcub="$(_count_kind xcub)"; n_dbxc="$(_count_kind dbxc)"
    fact "whatap component processes: dbx=$n_dbx dmx=$n_dmx prx=$n_prx xos=$n_xos xcub=$n_xcub dbxc=$n_dbxc"
    i=0
    while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
        fact "process: pid=${AG_PIDS[$i]} kind=${AG_KINDS[$i]}"
        i=$((i + 1))
    done
    fact "database server processes on this host: ${#DBP_PIDS[@]}"
    i=0
    while [ "$i" -lt "${#DBP_PIDS[@]}" ]; do
        [ "$i" -ge 20 ] && { fact "(more DB processes not listed: $(( ${#DBP_PIDS[@]} - 20 )))"; break; }
        fact "db process: pid=${DBP_PIDS[$i]} engine=${DBP_KINDS[$i]} comm=$(cat "/proc/${DBP_PIDS[$i]}/comm" 2>/dev/null || echo n/a)"
        i=$((i + 1))
    done
    # role statement, derived only from what was found
    local role_agent="no" role_dbhost="no"
    [ $((n_dbx + n_dmx + n_prx + n_dbxc)) -gt 0 ] && role_agent="yes"
    { [ $((n_xos + n_xcub)) -gt 0 ] || [ "${#DBP_PIDS[@]}" -gt 0 ]; } && role_dbhost="yes"
    fact "host role by discovery: dbx-agent-side=$role_agent db-host-side=$role_dbhost"
    if [ -n "$UNRES_HOME" ]; then
        fact "install dir of process(es) $UNRES_HOME: n/a ($UNRES_WHY)"
    fi
    [ -n "$OPT_HOME_BAD" ] && fact "--home not usable: $OPT_HOME_BAD"
    [ -n "$UNRES_BYHOME" ] && fact "install dir resolved by a matching --home: $UNRES_BYHOME"
    if [ "${#HOME_DIRS[@]}" -eq 0 ] && [ -z "$UNRES_HOME" ] && [ "${#AG_PIDS[@]}" -eq 0 ]; then
        fact "agent install dir: n/a (no whatap component process found and no --home given)"
    fi
    [ -n "$FIND_DENIED" ] && fact "whatap.conf/xos.conf search incomplete (a denied entry within depth 2) under:$FIND_DENIED"
    [ -n "$FIND_FAILED" ] && fact "whatap.conf/xos.conf search incomplete: $FIND_FAILED"
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        fact "install dir candidate: ${HOME_DIRS[$i]} (via ${HOME_SRCS[$i]})"
        i=$((i + 1))
    done
    fact "agent instances (dir with whatap.conf): ${#INST_DIRS[@]}"
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        fact "instance: ${INST_DIRS[$i]}"
        i=$((i + 1))
    done
}

# C. per-home inventory: layout, jars (= version facts), helper scripts
_rep_inventory() {
    local i
    section "C. Agent home inventory & component versions"
    if [ "${#HOME_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no install dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        local h="${HOME_DIRS[$i]}"
        subsection "home: $h"
        probe "top-level (depth 1)" ls -1 "$h"
        # component jar/binary file names carry version + build
        local jars
        jars="$(_bounded ls -l "$h"/whatap.agent.*.jar "$h"/whatap.agent.xos* "$h"/xos/whatap.agent.xos* 2>/dev/null)"
        if [ -n "$jars" ]; then _emit_labeled "whatap component files (name=version, with mtime)" "$jars"
        else fact "whatap component files: n/a (no whatap.agent.* under $h at depth 1)"; fi
        if [ -d "$h/jdbc" ]; then
            probe "jdbc drivers" ls -1 "$h/jdbc"
            if _has_glob "$h/jdbc"/orai18n*; then fact "orai18n jar: present in jdbc/"
            else fact "orai18n jar: not present in jdbc/"; fi
        else
            fact "jdbc drivers: n/a (path not found: $h/jdbc)"
        fi
        local f
        for f in uid.sh db.user start.sh startd.sh stop.sh prx.conf dbx.conf; do
            if [ -e "$h/$f" ]; then
                fact "$f: present ($(_bounded ls -l "$h/$f" 2>/dev/null | awk '{print $5" bytes, "$6" "$7" "$8}'))"
            else
                fact "$f: not present at $h"
            fi
        done
        local pidf
        for pidf in "$h"/*.pid "$h"/dbx "$h"/xcub-*.whatap; do
            [ -e "$pidf" ] && fact "pid file: $pidf ($(_bounded head -n1 "$pidf" 2>/dev/null | cut -c1-40))"
        done
        probe "dbxc-ctl version" "$h/dbxc-ctl" version
        i=$((i + 1))
    done
}

# D. configuration, verbatim (no masking)
_rep_conf() {
    local i
    section "D. Configuration (verbatim)"
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "whatap.conf: n/a (no instance dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local idir="${INST_DIRS[$i]}"
        subsection "instance: $idir"
        dump_file "whatap.conf" "$idir/whatap.conf"
        [ -f "$idir/dbx.conf" ] && dump_file "dbx.conf" "$idir/dbx.conf"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        local h="${HOME_DIRS[$i]}"
        [ -f "$h/prx.conf" ] && { subsection "oracle-pro watchdog conf: $h"; dump_file "prx.conf" "$h/prx.conf"; }
        local y
        for y in "$h"/dbxc*/config.yaml "$h"/config.yaml; do
            [ -f "$y" ] && { subsection "dbxc config: $y"; dump_file "config.yaml" "$y"; }
        done
        i=$((i + 1))
    done
}

# E. runtime processes, service registration, listeners
_rep_procs() {
    local i
    section "E. Runtime processes"
    if [ "${#AG_PIDS[@]}" -eq 0 ]; then
        fact "no whatap component process found on this host"
    fi
    i=0
    while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
        local pid="${AG_PIDS[$i]}" kind="${AG_KINDS[$i]}"
        subsection "$kind pid=$pid"
        probe "ps" ps -o user=,pid=,ppid=,etime=,rss=,args= -p "$pid"
        if [ -r "/proc/$pid/exe" ]; then
            local exe; exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
            fact "exe: ${exe:-n/a}"
            case "$exe" in
                *java*)
                    probe_merged "java runtime of pid $pid" "$exe" -version
                    java_tls_policy "security file of pid $pid runtime" "$exe"
                    ;;
            esac
        fi
        i=$((i + 1))
    done
    subsection "service registration & listeners"
    if have systemctl; then
        probe "systemd units matching whatap/dbx/xos" sh -c "systemctl list-units --all --no-legend 2>/dev/null | grep -iE 'whatap|dbx|xos' | head -n 10"
    else
        fact "systemd: n/a (command not found: systemctl)"
    fi
    probe "cron entries mentioning whatap" sh -c 'm="$(cat /etc/crontab /etc/cron.d/* 2>/dev/null | grep -i whatap | head -n 10)"; if [ -n "$m" ]; then printf "%s\n" "$m"; else echo none; fi'
    fact "watched ports (defaults + conf whatap.server.port/xos_port): $WATCH_PORTS"
    if have ss; then
        probe "sockets on watched ports" sh -c "ss -tunap 2>/dev/null | grep -E ':($WATCH_PORTS_RE)[[:space:]]' | head -n 20"
    elif have netstat; then
        probe "sockets on watched ports" sh -c "netstat -an 2>/dev/null | grep -E '[.:]($WATCH_PORTS_RE)[[:space:]]' | head -n 20"
    else
        fact "sockets: n/a (command not found: ss/netstat)"
    fi
}

# F. agent logs: a bounded window, never whole rotated logs
_rep_logs() {
    local i
    section "F. Agent logs"
    local logged=0
    i=0
    while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
        local h="${HOME_DIRS[$i]}" ldir=""
        for ldir in "$h/logs" "$h"; do
            _has_glob "$ldir"/whatap*.log && break
            ldir=""
        done
        if [ -z "$ldir" ]; then i=$((i + 1)); continue; fi
        logged=1
        subsection "log dir: $ldir"
        # paths travel as arguments ($1), never inside the script text
        probe "log files (newest 15)" sh -c 'ls -lt "$1" 2>/dev/null | head -n 16' sh "$ldir"
        local nlog; nlog="$(newest_matching "$ldir" 'whatap*.log')"
        if [ -n "$nlog" ]; then
            fact "newest agent log: $nlog"
            fact "newest agent log mtime: $(_bounded ls -l "$nlog" 2>/dev/null | awk '{print $6" "$7" "$8}')"
            fact "last log line (verbatim): $(_bounded tail -n1 "$nlog" 2>/dev/null | cut -c1-200)"
            fact "system time at collection: $(date '+%Y-%m-%d %H:%M:%S %Z(%z)' 2>/dev/null)"
            load_logwin "$nlog"
            local wa
            wa="$(grep -oE '\(WA[0-9]{3}\)' "$_logwin" 2>/dev/null | sort | uniq -c | sort -rn | head -n 15)"
            if [ -n "$wa" ]; then _emit_labeled "WA code histogram (last $LOG_SCAN_LINES lines)" "$wa"
            else fact "WA code histogram: n/a (no WA codes in last $LOG_SCAN_LINES lines)"; fi
            count_in_win "exception lines" 'Exception|SQLException|Error:'
            sample_in_win "exception lines" 'Exception|SQLException' 3
            count_in_win "connection error lines" 'CONNECTION ERROR|openConnection error|Communications link failure'
            count_in_win "activate/inactivate transitions" 'inactivated|activated'
            subsection "verbatim tail ($LOG_TAIL_LINES lines): $nlog"
            _bounded tail -n "$LOG_TAIL_LINES" "$nlog" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
        fi
        local plog; plog="$(newest_matching "$ldir" 'prx*.log')"
        if [ -n "$plog" ]; then
            subsection "oracle-pro prx log: $plog"
            fact "prx log mtime: $(_bounded ls -l "$plog" 2>/dev/null | awk '{print $6" "$7" "$8}')"
            probe "prx rss / restart lines (last 30 matches)" sh -c 'tail -n "$2" "$1" 2>/dev/null | grep -iE "rss|restart|start" | tail -n 30 | grep . || echo none' sh "$plog" "$LOG_SCAN_LINES"
        fi
        i=$((i + 1))
    done
    [ "$logged" = 0 ] && fact "agent logs: n/a (no whatap*.log under discovered homes)"
}

# G. topology & network: the agent host and DB host are often different
_rep_network() {
    local i
    section "G. Topology & network (per instance)"
    local myips
    myips="$(_bounded hostname -I 2>/dev/null || _bounded ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"
    fact "local ip addresses: ${myips:-n/a (hostname -I and ip unavailable)}"
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no instance dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
        subsection "instance: $idir"
        local dbms dbip dbport whost wport
        conf_get dbms "$cf" dbms
        conf_get dbip "$cf" db_ip
        conf_get dbport "$cf" db_port
        conf_get whost "$cf" 'whatap\.server\.host'
        conf_get wport "$cf" 'whatap\.server\.port'
        fact "dbms: ${dbms:-n/a (key not set in whatap.conf)}"
        fact "db_ip: ${dbip:-n/a (key not set)}   db_port: ${dbport:-n/a (key not set)}"
        fact "whatap.server.host: ${whost:-n/a (key not set)}   whatap.server.port: ${wport:-not set (the connect probe below uses 6600)}"
        # connection options, verbatim + key names split out — misspelled keys
        # are silently ignored by JDBC drivers, so the raw spelling is the fact
        local copt3 dbssl3
        conf_get copt3 "$cf" connect_option
        conf_get dbssl3 "$cf" db_ssl
        if [ -n "$copt3" ]; then
            fact "connect_option (verbatim): $copt3"
            fact "connect_option keys: $(printf '%s' "${copt3#\?}" | tr '&' '\n' | cut -d= -f1 | tr '\n' ',' | sed 's/,$//;s/,/, /g')"
        else
            fact "connect_option: not set"
        fi
        [ -n "$dbssl3" ] && fact "db_ssl: $dbssl3"
        # classify db_ip: loopback / one of this host's addresses / remote / DNS name
        if [ -n "$dbip" ]; then
            case "$dbip" in
                127.*|localhost|::1)
                    fact "db endpoint class: loopback" ;;
                *[a-zA-Z]*)
                    fact "db endpoint class: DNS name"
                    probe "db endpoint resolution" getent hosts "$dbip"
                    case "$dbip" in
                        *rds.amazonaws.com|*docdb.amazonaws.com|*cache.amazonaws.com|*redshift.amazonaws.com)
                            fact "db endpoint domain: AWS managed endpoint pattern ($dbip)" ;;
                        *database.azure.com|*windows.net)
                            fact "db endpoint domain: Azure managed endpoint pattern ($dbip)" ;;
                        *rds.aliyuncs.com|*ncloud.com|*ntruss.com)
                            fact "db endpoint domain: managed-cloud endpoint pattern ($dbip)" ;;
                    esac ;;
                *)
                    if [ -n "$myips" ] && printf '%s' " $myips " | grep -q " $dbip "; then
                        fact "db endpoint class: an address of this host"
                    else
                        fact "db endpoint class: not an address of this host"
                    fi ;;
            esac
            tcp_probe "db reachability" "$dbip" "${dbport:-}"
        fi
        if [ -n "$whost" ]; then
            local wh
            for wh in $(printf '%s' "$whost" | tr '/,' '  '); do
                tcp_probe "collection server reachability" "$wh" "${wport:-6600}"
            done
        fi
        i=$((i + 1))
    done
    fact "proxy env: http_proxy=${http_proxy:-unset} https_proxy=${https_proxy:-unset} no_proxy=${no_proxy:-unset}"
}

# H. engine-specific facts, driven by dbms= of each instance
_rep_engine() {
    local i
    section "H. Engine-specific facts (per instance)"
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no instance dir discovered)"
    fi
    i=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
        local dbms nlog2 ldir2=""
        conf_get dbms "$cf" dbms
        subsection "instance: $idir (dbms=${dbms:-unset})"
        # engine-relevant conf keys, verbatim lines (value + spelling as-is)
        # grep exit 1 (no line) is "none"; exit 2 (unreadable) stays an error
        probe "engine-relevant conf lines" sh -c 'grep -E "^[[:space:]]*(statements|statements_min_row|min_row|slow_query_log|connect_option|db_ssl|metalock|deadlock_interval|conn_fail_count|replication_name|skip_user|skip_whatap_session|cloud_watch|cloud_watch_metrics|cloud_watch_instance|aws_arn|aws_access_key|aws_secret_key|redis_autoscale|mslog|oname|whatap\.name|db=|db_user|plan_db|xos=|xos_port)" "$1"; r=$?; [ "$r" = 1 ] && { echo none; exit 0; }; exit "$r"' sh "$cf"
        # locate this instance's log window (instance logs/ first, then home)
        for ldir2 in "$idir/logs" "$idir" "$(dirname "$idir")/logs"; do
            _has_glob "$ldir2"/whatap*.log && break
            ldir2=""
        done
        nlog2=""
        [ -n "$ldir2" ] && nlog2="$(newest_matching "$ldir2" 'whatap*.log')"
        if [ -n "$nlog2" ]; then load_logwin "$nlog2"; else : > "$_logwin" 2>/dev/null; fi
        case "$dbms" in
            postgres*|pg)
                count_in_win "PgStatements.process lines" 'PgStatements\.process'
                count_in_win "PgObject.process lines" 'PgObject\.process'
                count_in_win "timeout lines" '[Tt]imeout'
                count_in_win "pg_stat_statements missing-relation lines" 'pg_stat_statements.*does not exist'
                count_in_win "authentication-type lines" 'authentication type .* not supported'
                ;;
            mysql|mariadb)
                count_in_win "WA310 lines" 'WA310'
                count_in_win "denied/permission lines" 'command denied|Access denied'
                count_in_win "sys.innodb_lock_waits lines" 'innodb_lock_waits'
                count_in_win "replication warning lines" 'Replication may have been broken|replication'
                ;;
            oracle)
                local oh
                oh="$(grep -oE 'ORA-[0-9]+' "$_logwin" 2>/dev/null | sort | uniq -c | sort -rn | head -n 10)"
                if [ -n "$oh" ]; then _emit_labeled "ORA code histogram (last $LOG_SCAN_LINES lines)" "$oh"
                else fact "ORA code histogram: n/a (no ORA codes in window)"; fi
                count_in_win "timeout lines" '[Tt]ime[d]? out|ORA-01013'
                ;;
            mssql)
                count_in_win "TLS/SSL negotiation lines" 'TLS|SSL|encrypt'
                count_in_win "login/permission lines" 'Login failed|permission'
                ;;
            tibero)
                local th
                th="$(grep -oE 'JDBC-[0-9]+' "$_logwin" 2>/dev/null | sort | uniq -c | sort -rn | head -n 10)"
                if [ -n "$th" ]; then _emit_labeled "JDBC code histogram (last $LOG_SCAN_LINES lines)" "$th"
                else fact "JDBC code histogram: n/a (no JDBC codes in window)"; fi
                count_in_win "read-timeout / connection-closed lines" 'Read time.?out|Connection closed'
                ;;
            redis|valkey)
                count_in_win "jedis/pool error lines" 'Jedis|resource from the pool|SocketTimeout'
                ;;
            mongo*)
                count_in_win "mongo timeout/format lines" 'MongoTimeout|numberFormatException'
                ;;
            cubrid)
                fact "engine-specific facts: none collected for dbms=cubrid"
                ;;
            "")
                fact "engine-specific facts: n/a (dbms key not set in whatap.conf)"
                ;;
            *)
                fact "engine-specific facts: none collected for dbms=$dbms"
                ;;
        esac
        # cloud overlay: CloudWatch / IAM traces regardless of engine
        local cw arn
        conf_get cw "$cf" cloud_watch
        arn=""; [ -n "$cw" ] || conf_get arn "$cf" aws_arn
        if [ -n "$cw" ] || [ -n "$arn" ]; then
            count_in_win "AWS credential/role lines" 'AssumeRole|sts|security token|expired'
            sample_in_win "AWS credential/role lines" 'AssumeRole|sts|security token.*expired' 3
        fi
        i=$((i + 1))
    done
    # oracle-pro watchdog pair (dmx/prx) — process-level, not per instance
    if [ "$(_count_kind dmx)" -gt 0 ] || [ "$(_count_kind prx)" -gt 0 ]; then
        subsection "oracle-pro dmx/prx pair"
        i=0
        while [ "$i" -lt "${#AG_PIDS[@]}" ]; do
            case "${AG_KINDS[$i]}" in
                dmx|prx) probe "${AG_KINDS[$i]} rss/etime" ps -o pid=,rss=,etime=,args= -p "${AG_PIDS[$i]}" ;;
            esac
            i=$((i + 1))
        done
        local rl
        i=0
        while [ "$i" -lt "${#HOME_DIRS[@]}" ]; do
            if [ -f "${HOME_DIRS[$i]}/prx.conf" ]; then
                conf_get rl "${HOME_DIRS[$i]}/prx.conf" rss_limit
                fact "prx.conf rss_limit: $rl"
            fi
            i=$((i + 1))
        done
    fi
}

# I. XOS / DB-host side: only when this host runs the DB or XOS
_rep_xos() {
    local i
    section "I. XOS / DB-host side facts"
    local xosseen=0
    if [ "$(_count_kind xos)" -gt 0 ] || [ "$(_count_kind xcub)" -gt 0 ] || [ "${#XOS_CONFS[@]}" -gt 0 ] || [ "${#DBP_PIDS[@]}" -gt 0 ]; then
        xosseen=1
    fi
    if [ "$xosseen" = 0 ]; then
        fact "n/a (not applicable: no xos/xcub process, xos.conf, or DB server process on this host)"
    else
        i=0
        while [ "$i" -lt "${#XOS_CONFS[@]}" ]; do
            local xc="${XOS_CONFS[$i]}"
            subsection "xos.conf: $xc"
            dump_file "xos.conf" "$xc"
            local sq
            conf_get sq "$xc" slow_query
            if [ -n "$sq" ]; then
                fact "slow_query target: $sq"
                if [ -r "$sq" ]; then
                    fact "slow_query target file: readable ($(_bounded ls -l "$sq" 2>/dev/null | awk '{print $5" bytes, mtime "$6" "$7" "$8}'))"
                    probe "slow_query target last 3 lines (verbatim)" tail -n 3 "$sq"
                    fact "lines with SQLSTATE prefix '00000:' in last 200: $(_bounded tail -n 200 "$sq" 2>/dev/null | grep -c '00000:' 2>/dev/null)"
                    fact "lines containing non-ASCII bytes in last 200: $(_bounded tail -n 200 "$sq" 2>/dev/null | grep -c '[^ -~]' 2>/dev/null)"
                elif [ -e "$sq" ]; then
                    fact "slow_query target file: n/a (permission denied: $sq)"
                else
                    fact "slow_query target file: n/a (path not found: $sq)"
                fi
            else
                fact "slow_query key: not set in $xc"
            fi
            i=$((i + 1))
        done
        # udp xos->dbx channel (xos_port, default 3002) — a known port-collision spot
        if have ss; then
            probe "udp sockets on watched ports" sh -c "ss -ulnap 2>/dev/null | grep -E ':($WATCH_PORTS_RE)' | head -n 5"
        fi
        # DB server processes: version / datadir / config paths, from the processes themselves
        i=0
        while [ "$i" -lt "${#DBP_PIDS[@]}" ]; do
            [ "$i" -ge 5 ] && { fact "(more DB processes not detailed: $(( ${#DBP_PIDS[@]} - 5 )))"; break; }
            local dpid="${DBP_PIDS[$i]}" dkind="${DBP_KINDS[$i]}" dexe
            subsection "db server process: $dkind pid=$dpid"
            probe "ps" ps -o user=,pid=,etime=,args= -p "$dpid"
            dexe="$(readlink "/proc/$dpid/exe" 2>/dev/null)"
            fact "exe: ${dexe:-n/a (readlink /proc/$dpid/exe unavailable)}"
            case "$dkind" in
                postgresql)     [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                mysql/mariadb)  [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                mongodb)        [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                redis/valkey)   [ -n "$dexe" ] && probe_merged "server version" "$dexe" --version ;;
                *)              fact "server version: n/a (not probed for $dkind)" ;;
            esac
            i=$((i + 1))
        done
    fi
}

# J. which SQL pack matches each instance (DB-internal facts come from it)
_rep_packs() {
    local i
    section "J. SQL pack per instance"
    i=0
    local said=0 packable=0
    while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
        local dbms
        conf_get dbms "${INST_DIRS[$i]}/whatap.conf" dbms
        case "$dbms" in
            postgres*|pg)   fact "instance ${INST_DIRS[$i]}: sql/postgresql.sql"; said=1; packable=1 ;;
            mysql|mariadb)  fact "instance ${INST_DIRS[$i]}: sql/mysql.sql"; said=1; packable=1 ;;
            oracle)         fact "instance ${INST_DIRS[$i]}: sql/oracle.sql"; said=1; packable=1 ;;
            mssql)          fact "instance ${INST_DIRS[$i]}: windows/mssql.sql (sqlcmd only in this version)"; said=1 ;;
            "")             ;;
            *)              fact "instance ${INST_DIRS[$i]}: no SQL pack for dbms=$dbms in this version"; said=1 ;;
        esac
        i=$((i + 1))
    done
    [ "$said" = 0 ] && fact "no instance with a dbms= key was discovered on this host"
    fact "--sql given: $( [ "$OPT_SQL" = 1 ] && echo "yes (section L)" || echo no)"
    [ "$packable" = 1 ] && [ "$OPT_SQL" = 0 ] && \
        warn "DB-internal facts (grants, parameters, monitoring views) come from the SQL pack: rerun with --sql, or run the pack above through a DB client"
    if [ "${#AG_PIDS[@]}" -gt 0 ] && [ "$(_count_kind xos)" -eq 0 ] && [ "${#DBP_PIDS[@]}" -eq 0 ]; then
        warn "no xos or DB server process on this host: when the DB host is a reachable on-prem server, run this same script there as well"
    fi
    if [ "${#AG_PIDS[@]}" -eq 0 ] && [ "${#DBP_PIDS[@]}" -gt 0 ]; then
        warn "DB server process(es) but no DBX component on this host: run this same script on the DBX agent host as well"
    fi
}

# K. TLS handshake probe: what the SERVER offers (TLS version, cipher,
# certificate dates and signature algorithm), the counterpart to the runtime
# policy in sections A/E and the connect_option in section G
_rep_tls() {
    local i
    section "K. TLS handshake probe"
    if ! have openssl; then
        fact "n/a (command not found: openssl)"
    elif [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no instance dir discovered)"
    else
        fact "openssl: $(_bounded openssl version 2>/dev/null)"
        # every handshake of the run shares TLS_BUDGET seconds, each at most 15
        local TLS_BUDGET=30 tls_t0="$SECONDS" tls_left tls_cap tls_f
        tls_f="$(_tmp tls.out)"
        i=0
        while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
            local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
            local dbms dbip dbport dbssl copt st out certinfo sig
            conf_get dbms "$cf" dbms
            conf_get dbip "$cf" db_ip
            conf_get dbport "$cf" db_port
            conf_get dbssl "$cf" db_ssl
            conf_get copt "$cf" connect_option
            subsection "instance: $idir (dbms=${dbms:-unset}, target ${dbip:-?}:${dbport:-?})"
            if [ -z "$dbip" ] || [ -z "$dbport" ]; then
                fact "n/a (not applicable: db_ip/db_port not set)"
                i=$((i + 1)); continue
            fi
            st=""
            case "$dbms" in
                mysql|mariadb)  st="-starttls mysql" ;;
                postgres*|pg)   st="-starttls postgres" ;;
                redis|valkey)
                    case "$dbssl$copt" in
                        *true*|*ssl*) st="" ;;
                        *) fact "n/a (not applicable: db_ssl/ssl option not set)"
                           i=$((i + 1)); continue ;;
                    esac ;;
                mssql)  fact "n/a (not applicable: dbms=mssql, TLS inside the TDS prelogin is not probed with openssl s_client)"
                        i=$((i + 1)); continue ;;
                oracle) fact "n/a (not applicable: dbms=oracle, TCPS/native negotiation not probed in this version)"
                        i=$((i + 1)); continue ;;
                *)      fact "n/a (not applicable: dbms=${dbms:-unset})"
                        i=$((i + 1)); continue ;;
            esac
            local down
            if down="$(tcp_down "$dbip" "$dbport")"; then
                fact "handshake: n/a (skipped: $down)"
                i=$((i + 1)); continue
            fi
            tls_left=$((TLS_BUDGET - (SECONDS - tls_t0)))
            if [ "$tls_left" -le 0 ]; then
                fact "handshake: n/a (not run: TLS probes stopped after ${TLS_BUDGET}s)"
                i=$((i + 1)); continue
            fi
            # min(CMD_TIMEOUT, 15, what is left of the budget)
            tls_cap=15; [ "$CMD_TIMEOUT" -lt "$tls_cap" ] && tls_cap="$CMD_TIMEOUT"
            [ "$tls_left" -lt "$tls_cap" ] && tls_cap="$tls_left"
            progress "sending 1 TLS handshake to $dbip:$dbport ($dbms)"
            local trc summ
            # shellcheck disable=SC2086
            out="$(CMD_TIMEOUT="$tls_cap" _bounded_in /dev/null openssl s_client $st -connect "$dbip:$dbport" 2>&1)"; trc=$?
            if [ "$trc" -eq 124 ]; then
                fact "handshake: n/a (timed out: ${tls_cap}s)"
                i=$((i + 1)); continue
            fi
            # A session exists only when openssl names a protocol and a cipher.
            # Without one, its verification lines ("Verification: OK", "Verify
            # return code: 0") describe no certificate and are left out, and
            # openssl's own reason is kept.
            if printf '%s\n' "$out" | grep -aqE '^New, (TLS|SSL)|^ *Protocol *: *(TLS|SSL)' \
               && printf '%s\n' "$out" | grep -aqE 'Cipher( is| *:) *[A-Z0-9]' \
               && ! printf '%s\n' "$out" | grep -aqE 'Cipher( is| *:) *(\(NONE\)|0000)'; then
                summ="$(printf '%s\n' "$out" \
                    | grep -aE '^New, |Protocol *:|Cipher *(is|:)|Server public key|Verification|Verify return code|verify error|error|alert ' \
                    | head -n 10)"
            else
                local tmsg
                tmsg="$(printf '%s\n' "$out" | grep -avE '^(CONNECTED|---|Verif|New, |Secure Renegotiation|Compression|Expansion|No ALPN|Early data|No client certificate|SSL handshake has read)' \
                    | grep -a -m1 . | cut -c1-160)"
                fact "session: none negotiated (${tmsg:-openssl exit $trc, no message})"
                summ="$(printf '%s\n' "$out" | grep -aE '^New, |Protocol *:|Cipher *(is|:)|error|alert ' | head -n 10)"
            fi
            if [ -n "$summ" ]; then _emit_labeled "handshake summary" "$summ"
            else _emit_labeled "handshake: no session lines; openssl output (first 5 lines, exit $trc)" "$(printf '%s\n' "$out" | head -n 5)"; fi
            # the parses read the handshake output from a private file, bounded
            certinfo=""
            printf '%s\n' "$out" >"$tls_f" 2>/dev/null \
                && certinfo="$(_bounded_in "$tls_f" openssl x509 -noout -subject -issuer -dates 2>/dev/null)"
            if [ -n "$certinfo" ]; then
                _emit_labeled "server certificate" "$certinfo"
                sig="$(_bounded_in "$tls_f" openssl x509 -noout -text 2>/dev/null | grep -m1 'Signature Algorithm' | sed 's/^ *//')"
                [ -n "$sig" ] && fact "certificate signature: $sig"
            else
                fact "server certificate: n/a (no certificate in handshake output)"
            fi
            i=$((i + 1))
        done
    fi
}

# L. SQL pack over JDBC (--sql), the agent-native path
_rep_sql() {
    local i
    section "L. SQL pack over JDBC (opt-in)"
    local sql_ok=0 sql_fail="" sql_na=""
    if [ "${#INST_DIRS[@]}" -eq 0 ]; then
        fact "n/a (no instance dir discovered)"
        sql_fail="no instance dir (whatap.conf) discovered on this host"
    elif ! _pick_java_bindir; then
        fact "n/a (no jshell or working jrunscript next to ${_JBIN:-any discovered java})"
        sql_fail="no jshell or working jrunscript next to ${_JBIN:-any discovered java} (run it on a host with a JDK 8+ java)"
    else
        fact "runner: $_JDBC_MODE from $_JBIN"
        i=0
        while [ "$i" -lt "${#INST_DIRS[@]}" ]; do
            local idir="${INST_DIRS[$i]}" cf="${INST_DIRS[$i]}/whatap.conf"
            local dbms dbip dbport dbname copt pack jar url alturl out ping
            # everything the agent itself uses to connect is reused from
            # whatap.conf (rule 2) — only credentials cannot come from it
            # (stored encrypted by uid.sh; this script does not decrypt)
            conf_get dbms "$cf" dbms
            conf_get dbip "$cf" db_ip
            conf_get dbport "$cf" db_port
            conf_get dbname "$cf" 'db'
            [ -z "$dbname" ] && conf_get dbname "$cf" plan_db
            conf_get copt "$cf" connect_option
            case "$copt" in ""|\?*) ;; *) copt="?$copt" ;; esac
            subsection "instance: $idir (dbms=${dbms:-unset})"
            pack=""; jar=""; url=""; alturl=""; ping="SELECT 1"
            case "$dbms" in
                postgres*|pg)
                    pack="$SCRIPT_DIR/sql/postgresql.sql"
                    jar="$(_find_jdbc_jar 'postgresql*.jar')"
                    url="jdbc:postgresql://$dbip:$dbport/${dbname:-postgres}$copt" ;;
                mysql|mariadb)
                    pack="$SCRIPT_DIR/sql/mysql.sql"
                    jar="$(_find_jdbc_jar 'mysql-connector*.jar' 'mariadb*.jar')"
                    url="jdbc:mysql://$dbip:$dbport/${dbname}$copt"
                    case "$jar" in *mariadb*) url="jdbc:mariadb://$dbip:$dbport/${dbname}$copt" ;; esac ;;
                oracle)
                    pack="$SCRIPT_DIR/sql/oracle.sql"
                    jar="$(_find_jdbc_jar 'ojdbc*.jar')"
                    url="jdbc:oracle:thin:@//$dbip:$dbport/$dbname"
                    alturl="jdbc:oracle:thin:@$dbip:$dbport:$dbname"
                    ping="SELECT 1 FROM DUAL" ;;
                *)
                    fact "n/a (not applicable: no JDBC pack for dbms=${dbms:-unset} in this version)"
                    sql_na="$sql_na $idir: no JDBC pack for dbms=${dbms:-unset};"
                    i=$((i + 1)); continue ;;
            esac
            if [ ! -f "$pack" ]; then
                fact "n/a (path not found: $pack)"
                sql_fail="$sql_fail $idir: path not found: $pack (keep the sql/ dir next to this script);"
                i=$((i + 1)); continue
            fi
            if [ -z "$jar" ]; then
                fact "n/a (no matching driver jar under any discovered jdbc/ dir)"
                sql_fail="$sql_fail $idir: no matching driver jar under any discovered jdbc/ dir;"
                i=$((i + 1)); continue
            fi
            fact "driver jar: $jar"
            fact "jdbc url: $url"
            local down
            if down="$(tcp_down "$dbip" "$dbport")"; then
                fact "pack: n/a (skipped: $down)"
                sql_fail="$sql_fail $idir: not sent: $down;"
                i=$((i + 1)); continue
            fi
            if ! _get_creds "$idir"; then
                sql_fail="$sql_fail $idir: $CRED_WHY;"
                i=$((i + 1)); continue
            fi
            warn "sending read-only SQL pack $(basename "$pack") to $dbip:$dbport as $CRED_USER over JDBC"
            [ -n "$RTT_MARK" ] || { _now_ms; RTT_MARK="GGT-RTT-$_ms-$RANDOM$RANDOM$RANDOM:"; }
            out="$(_run_jdbc_pack "$pack" "$url" "$jar" "$ping")"
            local jrc rtl=""; jrc="$(cat "$(_tmp runner.rc)" 2>/dev/null)"
            # the runner's timing line is a fact of its own, not pack output
            _rtt_split "$out" && { rtl="$RTT_LINE"; out="$RTT_REST"; }
            if [ -n "$alturl" ] && printf '%s' "$out" | grep -q '^CONNECT-ERROR'; then
                fact "first URL form did not connect; retrying SID form"
                fact "jdbc url (retry): $alturl"
                warn "retrying with SID-form URL $alturl"
                local out2
                out2="$(_run_jdbc_pack "$pack" "$alturl" "$jar" "$ping")"
                _rtt_split "$out2" && { rtl="$RTT_LINE"; out2="$RTT_REST"; }
                out="$out
--- retry with $alturl ---
$out2"
            fi
            if [ -n "$rtl" ]; then
                fact "db round trip (runner VM clock): $rtl"
            elif printf '%s\n' "$out" | grep -q '^CONNECT-ERROR'; then
                fact "db round trip (runner VM clock): n/a (did not connect)"
            elif [ -n "$out" ]; then
                fact "db round trip (runner VM clock): n/a (the runner printed no timing line)"
            fi
            if [ -n "$out" ]; then
                fact "pack output (verbatim):"
                printf '%s\n' "$out" | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
            else
                case "$jrc" in
                    124) fact "pack output: n/a (timed out: 120s or run deadline)" ;;
                    *)   fact "pack output: n/a (empty output, runner exit ${jrc:-unknown})" ;;
                esac
            fi
            # connected at least once (the retry output follows the first)
            if [ -z "$out" ]; then
                sql_fail="$sql_fail $idir: runner produced no output (exit ${jrc:-unknown}$( [ "$jrc" = 124 ] && echo ', timed out'));"
            elif printf '%s\n' "$out" | grep -q '^([0-9]* rows)$\|^SQL-ERROR: \|^(ok)$'; then
                sql_ok=$((sql_ok + 1))
            else
                local cerr
                cerr="$(printf '%s\n' "$out" | grep -m1 '^CONNECT-ERROR' | cut -c1-160)"
                [ -n "$cerr" ] || cerr="runner output: $(printf '%s\n' "$out" | grep -m1 . | cut -c1-120)"
                sql_fail="$sql_fail $idir: $cerr;"
            fi
            CRED_PW=""
            i=$((i + 1))
        done
    fi
    if [ -n "$sql_fail" ]; then sql_fail="${sql_fail# }"; missed sql "${sql_fail%;}"
    elif [ "$sql_ok" -gt 0 ]; then got sql
    else na sql "no instance with a JDBC pack:${sql_na%;}"; fi
}

# the components, home and conf goals, resolved after every section
_rep_goals() {
    # components: na only when the process scan could see every process
    if [ "${#AG_PIDS[@]}" -gt 0 ]; then got components
    elif [ -n "$PROC_HIDDEN" ]; then missed components "no whatap component process visible, and the process scan was incomplete ($PROC_HIDDEN)$(_priv_hint)"
    else na components "no dbx/dmx/prx/xos/xcub/dbxc process in the /proc scan; section B states the host role it does have"; fi
    # home: every component process mapped to a readable install dir
    # a --home that resolved stands in for the processes /proc could not map
    if [ -n "$OPT_HOME_BAD" ]; then
        missed home "--home not usable: $OPT_HOME_BAD"
    elif [ -n "$UNRES_HOME" ]; then
        missed home "install dir of process(es) $UNRES_HOME not resolved: $UNRES_WHY (or pass --home <dir>)$( [ "$UNRES_PRIV" = 1 ] && _priv_hint)"
    elif [ "${#HOME_DIRS[@]}" -gt 0 ]; then got home
    elif [ -n "$PROC_HIDDEN" ]; then missed home "no component process visible ($PROC_HIDDEN), no --home given$(_priv_hint)"
    else na home "no component process and no --home given"; fi
    # conf: every discovered config readable, and the search under each home complete
    local cbad="" ci=0
    while [ "$ci" -lt "${#INST_DIRS[@]}" ]; do
        [ -r "${INST_DIRS[$ci]}/whatap.conf" ] || cbad="$cbad ${INST_DIRS[$ci]}/whatap.conf"
        ci=$((ci + 1))
    done
    ci=0
    while [ "$ci" -lt "${#XOS_CONFS[@]}" ]; do
        [ -r "${XOS_CONFS[$ci]}" ] || cbad="$cbad ${XOS_CONFS[$ci]}"
        ci=$((ci + 1))
    done
    if [ -n "$cbad" ]; then missed conf "permission denied:$cbad$(_priv_hint)"
    elif [ -n "$FIND_DENIED" ]; then missed conf "search for whatap.conf/xos.conf hit a denied entry under:$FIND_DENIED$(_priv_hint)"
    elif [ -n "$FIND_FAILED" ]; then missed conf "search for whatap.conf/xos.conf incomplete: $FIND_FAILED"
    elif [ "${#INST_DIRS[@]}" -gt 0 ] || [ "${#XOS_CONFS[@]}" -gt 0 ]; then got conf
    elif [ -n "$UNRES_HOME" ] || [ -n "$OPT_HOME_BAD" ] || { [ "${#HOME_DIRS[@]}" -eq 0 ] && [ -n "$PROC_HIDDEN" ]; }; then
        missed conf "install dir not resolved for every component (see the home goal)$( { [ "$UNRES_PRIV" = 1 ] || [ -n "$PROC_HIDDEN" ]; } && _priv_hint)"
    elif [ "${#HOME_DIRS[@]}" -gt 0 ]; then na conf "no whatap.conf or xos.conf within depth 2 of the install dir(s) (all read)"
    else na conf "no install dir on this host to read a configuration from"; fi
}

run_report() {
    emit_header

    goal components "whatap DB-monitoring components on this host"
    goal home       "agent install dir of each component"
    goal conf       "component configuration (whatap.conf / xos.conf)"
    [ "$OPT_SQL" = 1 ] && goal sql "SQL pack over JDBC (--sql)"

    _rep_env
    _rep_host
    _rep_discovery
    _rep_inventory
    _rep_conf
    _rep_procs
    _rep_logs
    _rep_network
    _rep_engine
    _rep_xos
    _rep_packs
    _rep_tls
    [ "$OPT_SQL" = 1 ] && _rep_sql
    _rep_goals

    emit_status
    emit_footer
}

# ---- main -----------------------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_run_init
_init_probe

# The output directory is checked before collecting, so an unwritable one
# fails at once rather than after a full run.
if [ "$OPT_STDOUT" != 1 ]; then
    mkdir -p "$OPT_OUT" 2>/dev/null
    if [ ! -d "$OPT_OUT" ] || [ ! -w "$OPT_OUT" ] || [ ! -x "$OPT_OUT" ]; then
        warn "the report was not written: output directory $OPT_OUT is not writable by uid $(id -u 2>/dev/null || echo '?')"
        exit 1
    fi
fi

progress "discovering whatap DB components / DB server processes ..."
discover
progress "components: dbx=$(_count_kind dbx) dmx=$(_count_kind dmx) prx=$(_count_kind prx) xos=$(_count_kind xos) xcub=$(_count_kind xcub) dbxc=$(_count_kind dbxc); homes=${#HOME_DIRS[@]}; instances=${#INST_DIRS[@]}; db-procs=${#DBP_PIDS[@]}"

if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="$(hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="$OPT_OUT/$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
