#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collection-server MySQL facts
# -----------------------------------------------------------------------------
# The WhaTap backend keeps its account/notihub metadata in MySQL. This collector
# reports that database's identity, HA/replication state, binary-log inventory
# and growth, storage and I/O counters, and the per-table attribution of binary
# log content. It reports measurements and the settings that govern them; the
# reader decides what they mean (CONTRACT rule 1).
#
# Binary-log attribution (section I) is the reason this collector exists: it
# decodes binary logs with mysqlbinlog and counts events per table, so a reader
# can tell which table produces the volume instead of inferring it. That probe
# reads log files and is therefore opt-in (--binlog), not part of the default
# report.
#
# Rules: ../../CONTRACT.md and ../../docs/authoring-guide.md. No `set -e`: the
# report always reaches its footer.
# -----------------------------------------------------------------------------

# bash only: arrays hold the client's arguments. Checked before any of them is
# parsed, so sh or dash stops here with a sentence instead of a syntax error.
[ -n "${BASH_VERSION:-}" ] || { echo "collect-collmysql.sh needs bash" >&2; exit 2; }

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
# 0.9.0  Binary log sizes come from SHOW BINARY LOGS only: section C lists
#        the directory once for the mtimes (no du; the listing sums the files
#        only when SHOW BINARY LOGS gave no list), and section I takes the
#        newest files and their sizes from those rows, not from ls per file.
#        A SQL call cut by the run deadline says "run deadline reached", not
#        "timed out". A cut or refused SHOW BINARY LOGS is no list. The
#        login check is the client's status, whose Connection line ([1]
#        "connected to:") classifies the target: a TCP address neither this
#        host nor a local mysqld's network namespace owns is a remote server
#        (a gap, no local process looked at). SHOW BINARY LOG STATUS falls
#        back to SHOW MASTER STATUS only on its syntax error (before 8.2,
#        MariaDB) instead of asking both. Otherwise the
#        binary logs are read only through the server's own process: the
#        local mysqld/mariadbd whose pid file (@@pid_file through
#        /proc/<pid>/root, or here when that root cannot be entered) holds its
#        pid and was written with the server's start (mtime against now -
#        Uptime), whose auto.cnf holds @@server_uuid where readable, and whose
#        binlog directory holds the server's newest log with nothing newer (a
#        newer one: SHOW BINARY LOGS asked once more, and it must list it). Its /proc/<pid>/root<binlog dir> is read and a
#        "binlog files: via pid ..." line says so. None (a remote server, a
#        copied datadir), two, or an unreadable pid file is
#        a gap with the reason. Paths come from a readable @@log_bin_index
#        (logs in more than one directory; such a file is named by its
#        path); a selected file that is not there, or a name listed twice
#        with no index, is named and blocks the goal.
# 0.8.3  @@log_bin, @@log_bin_basename and @@datadir are asked for once (the
#        value shown is the value used), and one ps serves both the login
#        reason and section A. Report unchanged.
# 0.8.2  Readability refactor; report unchanged.
# 0.8.1  --connect-expired-password passes through. An empty line or end of
#        input at the -p prompt says so instead of "none given", next to the
#        shared privilege hint on a failed login.
#        A word after a bare -p (a database name to the client) is warned about.
# 0.8.0  Never elevates or re-runs itself (--no-sudo warns it is not needed).
#        No credential on a command line: a password in --mysql-args ends the
#        run (exit 2); it comes from a bare -p, MYSQL_PWD or an option file and
#        reaches the client in a mode-600 file. Every wait is bounded; refused
#        SHOW BINARY LOGS, a failed or capped decode, a NULL log_bin_basename and
#        no local mysqld without arguments are gaps with reasons. Needs bash.
COLLECTOR_NAME="whatap-collmysql"
VERSION="0.9.0"
DOMAIN="collection-server"
TARGET="collection-server-mysql/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness ------------------------------------------------------------
OPT_FILE=0
OPT_STDOUT=0
OPT_QUIET=0
OPT_BINLOG=0          # decode binary logs and attribute events per table
BINLOG_FILES=2        # how many of the newest binary logs to decode
OPT_SAMPLE=0          # interval iostat/vmstat sampling
SAMPLE_SEC=5
SAMPLE_COUNT=6
# The /proc the binary logs are found through (a fake tree in tools/test-collmysql.sh).
PROC_ROOT="${COLLMYSQL_PROC:-/proc}"
# Caps come from the environment only, and are whole numbers 1..999999 or they
# are dropped here, before anything reads them (the rule of _cap_or in the run
# helpers). _CAP_BAD is warned about once fd 3 is open.
_cap_ok() { case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac; [ "${#1}" -le 6 ]; }
_CAP_BAD=""
for _cv in CMD_TIMEOUT RUN_DEADLINE BINLOG_TIMEOUT PROMPT_TIMEOUT; do
    eval "_cx=\${$_cv:-}"
    if [ -n "$_cx" ] && ! _cap_ok "$_cx"; then _CAP_BAD="$_CAP_BAD $_cv=$_cx"; unset "$_cv"; fi
done
# RUN_DEADLINE as the caller set it decides whether the deadline is raised to
# fit a binlog decode and the samplers.
_RUN_DEADLINE_ENV="${RUN_DEADLINE:-}"
BINLOG_TIMEOUT="${BINLOG_TIMEOUT:-300}"   # per-file cap for the mysqlbinlog decode
# The most the -p prompt may wait, so an unanswered prompt does not spend the
# whole deadline and leave every later fact "deadline reached".
PROMPT_TIMEOUT="${PROMPT_TIMEOUT:-60}"
MYSQL_ARGS=""         # extra arguments handed to the mysql client
DEFAULTS_FILE=""
EXTRA_FILE=""
OPT_NOSUDO=0

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")                     print this help (no collection)
  $(basename "$0") --file              write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout            print the facts report to stdout

  --defaults-file PATH        option file handed to the mysql client (credentials)
  --defaults-extra-file PATH  option file read in addition to the client's own
  --mysql-args "ARGS"         extra arguments for the mysql client, e.g. "-h 10.0.0.5 -P 3306 -u whatap -p"
                              A bare -p asks for the password once, on the terminal.
                              A password on the command line (-pSECRET,
                              --password=SECRET, ...) is refused (exit 2): use -p,
                              MYSQL_PWD or an option file.
  --binlog[=N]                decode the N newest binary logs and count events per
                              table (default N=$BINLOG_FILES). Reads log files; off by default.
                              Each file is streamed once and capped at ${BINLOG_TIMEOUT}s
  --sample[=SEC]              add SEC-interval iostat/vmstat samples (default $SAMPLE_SEC s x $SAMPLE_COUNT)
  --quiet                     silence progress on stderr

Privilege: the collector runs at the privilege it was started with and never
elevates itself. A packaged MySQL often admits root over the unix socket with
no password, and the binary log directory is often readable by root only; run
it with sudo for those:  sudo ./$(basename "$0") --stdout

Connection: with neither an option file nor --mysql-args, the mysql client is
invoked with no connection arguments, so it uses its own option files
(~/.my.cnf, /etc/my.cnf). Every section reports "n/a (<reason>)" when the client
cannot connect, so a run without credentials still produces the host-side facts.

Environment: CMD_TIMEOUT, RUN_DEADLINE, BINLOG_TIMEOUT, PROMPT_TIMEOUT (seconds).
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        # Field scripts written for 0.6/0.7 pass it; it changes nothing now.
        --no-sudo) OPT_NOSUDO=1 ;;
        --binlog)  OPT_BINLOG=1 ;;
        --binlog=*) OPT_BINLOG=1; BINLOG_FILES="${1#*=}" ;;
        --sample)  OPT_SAMPLE=1 ;;
        --sample=*) OPT_SAMPLE=1; SAMPLE_SEC="${1#*=}" ;;
        --defaults-file) shift; DEFAULTS_FILE="${1:-}" ;;
        --defaults-file=*) DEFAULTS_FILE="${1#*=}" ;;
        --defaults-extra-file) shift; EXTRA_FILE="${1:-}" ;;
        --defaults-extra-file=*) EXTRA_FILE="${1#*=}" ;;
        --mysql-args) shift; MYSQL_ARGS="${1:-}" ;;
        --mysql-args=*) MYSQL_ARGS="${1#*=}" ;;
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

sub()  { printf '        %s\n' "$1"; }

_errfile=""
_init_probe() { _errfile="$(_tmp probe.err)"; }

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

_classify_err() {
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *"ccess denied"*)                                    echo "access denied"; return ;;
        *[Pp]"ermission denied"*|*"peration not permitted"*) echo "permission denied"; return ;;
        *"an't connect"*|*"onnection refused"*)              echo "cannot connect"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*)   echo "path not found"; return ;;
    esac
    # MariaDB's client echoes the statement between dashed rules before the
    # error, so the first line is often "--------------". Prefer the line that
    # actually carries the error.
    if [ -n "$txt" ]; then
        local line
        line="$(printf '%s\n' "$txt" | grep -m1 -E 'ERROR|error|denied|failed' 2>/dev/null)"
        [ -z "$line" ] && line="$(printf '%s\n' "$txt" | grep -m1 -vE '^[-[:space:]]*$' 2>/dev/null)"
        [ -z "$line" ] && line="$(printf '%s' "$txt" | head -n1)"
        printf 'error: %s' "$(printf '%s' "$line" | cut -c1-120)"
    else echo "nonzero exit"; fi
}

_emit_labeled() {
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then fact "$label: $body"
    else fact "$label:"; printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do sub "$_l"; done
    fi
}

# probe "label" CMD... -> output as facts, or "label: n/a (<why>)". Bounded by
# _bounded (run helpers) at CMD_TIMEOUT and the run deadline.
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

read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# ---- mysql client -----------------------------------------------------------
# Rule 2: the connection is discovered from the operator's option files unless
# arguments were given. _resolve_mysql records once whether the client connects,
# so every later section states a reason instead of failing silently.
MYSQL_BIN=""
MYSQL_OK=0
MYSQL_WHY="not attempted"

# ---- credentials (this collector only) ---------------------------------------
# No credential in a child's argv (world-readable) or environment: the client
# reads the password from a mode-600 option file in the private directory. It
# comes from a bare -p (asked once on the terminal), MYSQL_PWD (unset before any
# child starts) or the operator's option files; one written into --mysql-args is
# refused.
_PW=""; _PW_SRC=""; _PW_WHY=""; CNF=""

# _pw_opt NAME -> what the mysql client (measured: 5.6, 5.7.32, 8.0.46, 8.4.10)
# does with a long option NAME (without =VALUE), "_" and "-" being one character:
#   "pw"   the value is the password: --password, --password1..3, a prefix
#          --pas..--passwor (5.6), after loose-/maximum-/skip-/enable-/disable-
#          prefixes whose last one is loose- or maximum-;
#   "drop" the same names ending in skip-/enable-/disable- (value unused), and
#          any other name that spells password;
#   ""     anything else.
# The union over those clients, so no spelling any of them takes stays on a
# command line.
_pw_opt() {
    local n="${1#--}" pre last=""
    n="$(printf '%s' "$n" | tr '_' '-')"
    while :; do
        pre="${n%%-*}"
        case "$pre" in loose|maximum|skip|enable|disable) last="$pre"; n="${n#*-}" ;; *) break ;; esac
        [ -n "$n" ] || break
    done
    case "$n" in
        # A real flag with no value (8.0 client): not a password.
        connect-expired-password) return 1 ;;
        password|password[123]|pas|pass|passw|passwo|passwor)
            case "$last" in skip|enable|disable) printf 'drop' ;; *) printf 'pw' ;; esac
            return 0 ;;
    esac
    # Not a spelling any client takes, but it names a password: it does not
    # stay on a command line either (--PASSWORD=, --pass-word=, --loose--password=).
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '_-')" in *password*) printf 'drop'; return 0 ;; esac
    return 1
}

# _tty_restore -> the terminal settings saved before the password prompt
_STTY_SAVED=""
_tty_restore() {
    if [ -n "$_STTY_SAVED" ]; then stty "$_STTY_SAVED" </dev/tty 2>/dev/null
    else stty echo </dev/tty 2>/dev/null; fi
}

# _short_pw WORD -> true when a short-option cluster holds -p. Sets _SP_KEPT
# (the cluster without p and what follows it) and _SP_PW (the rest after p,
# empty for "ask").
_SP_KEPT=""; _SP_PW=""
_short_pw() {
    local w="${1#-}" i=0 c pre=""
    while [ "$i" -lt "${#w}" ]; do
        c="${w:$i:1}"
        case "$c" in
            p) _SP_PW="${w:$((i + 1))}"; _SP_KEPT="${pre:+-$pre}"; return 0 ;;
            u|h|P|D|S|e|R|'#') return 1 ;;
        esac
        pre="$pre$c"; i=$((i + 1))
    done
    return 1
}


# _prompt_budget -> seconds the prompt may wait: PROMPT_TIMEOUT or what is left
# of the run, whichever is less
_prompt_budget() {
    local left=$((RUN_DEADLINE - $(_elapsed)))
    [ "$left" -gt "$PROMPT_TIMEOUT" ] && left="$PROMPT_TIMEOUT"
    printf '%s' "$left"
}

_take_password() {
    local w out="" prompt=0 inargs="" afterp=0
    set -f
    for w in $MYSQL_ARGS; do
        # A word after a bare -p is the database name to the client, not the
        # password; if it was meant as one it now sits on every command line.
        # Warned about (never repeated), not changed: it is the operator's call.
        if [ "$afterp" = 1 ]; then
            case "$w" in -*) ;; *) warn "the word after a bare -p / --password in --mysql-args is taken as a database name by the client; if it is a password, use the prompt" ;; esac
            afterp=0
        fi
        case "$w" in
            --*=*) [ -n "$(_pw_opt "${w%%=*}")" ] && { inargs="${w%%=*}=..."; continue; } ;;
            --*)   case "$(_pw_opt "$w")" in pw) prompt=1; afterp=1; continue ;; drop) continue ;; esac ;;
            -?*)   # A cluster of short options (-BpX, -Np): p takes the rest of
                   # the word as the password, unless an option that takes an
                   # argument (-u, -h, -P, -D, -S, -e, -R, -#) came first.
                   if _short_pw "$w"; then
                       if [ -n "$_SP_PW" ]; then inargs="${_SP_KEPT:--}p..."; continue; fi
                       prompt=1; afterp=1; [ -n "$_SP_KEPT" ] && out="$out${out:+ }$_SP_KEPT"; continue
                   fi ;;
        esac
        out="$out${out:+ }$w"
    done
    set +f
    if [ -n "$inargs" ]; then
        warn "a password in --mysql-args ($inargs) is refused: no credential goes on a command line; use a bare -p (asked on the terminal), MYSQL_PWD or --defaults-file"
        exit 2
    fi
    MYSQL_ARGS="$out"
    if [ -n "${MYSQL_PWD:-}" ]; then
        # A value with a newline cannot survive an option file (a line ends
        # there), and would log in as access denied with nothing saying why.
        case "$MYSQL_PWD" in
            *"$_nl"*) warn "MYSQL_PWD holds a newline, which the mysql option file cannot carry; use --defaults-file"; exit 2 ;;
        esac
        [ "$prompt" = 1 ] || { _PW="$MYSQL_PWD"; _PW_SRC=MYSQL_PWD; }
    fi
    unset MYSQL_PWD
    [ -z "$_PW" ] && [ "$prompt" = 1 ] || return 0
    if ! { : </dev/tty; } 2>/dev/null; then
        _PW_WHY="-p given and this run has no terminal to ask for the password on"; return 0
    fi
    # Echo off before the prompt, so a password typed ahead is not shown, and
    # back on however the read ends: a Ctrl-C at the prompt used to leave the
    # operator's terminal without echo.
    local left prc=0; left="$(_prompt_budget)"
    [ "$left" -lt 1 ] && left=1
    _STTY_SAVED="$(stty -g </dev/tty 2>/dev/null)"
    trap '_tty_restore; _run_cleanup; exit 129' HUP
    trap '_tty_restore; _run_cleanup; exit 130' INT
    trap '_tty_restore; _run_cleanup; exit 143' TERM
    stty -echo </dev/tty 2>/dev/null
    printf 'MySQL password (asked once, for every query of this run): ' >/dev/tty
    IFS= read -r -t "$left" _PW </dev/tty || prc=$?
    _tty_restore
    # the run helpers' traps again
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
    printf '\n' >/dev/tty
    if [ "$prc" -gt 128 ]; then
        _PW=""; _PW_WHY="password prompt not answered within ${left}s"
        warn "$_PW_WHY; continuing without a password"
    elif [ -n "$_PW" ]; then _PW_SRC="terminal prompt"
    elif [ "$prc" = 0 ]; then _PW_WHY="prompt answered with an empty line"
    else _PW_WHY="prompt answered with end of input"; fi
}

# _load_password -> write the client option file for the password this run holds
_load_password() {
    [ -n "$_PW" ] || return 0
    # Option-file syntax: the value in double quotes, with \ and " escaped, so a
    # password holding #, ; or spaces survives the parse.
    local q inc="${DEFAULTS_FILE:-$EXTRA_FILE}"
    q="$(printf '%s' "$_PW" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    case "$inc" in ''|/*) ;; *) inc="$PWD/$inc" ;; esac
    CNF="$(_tmp client.cnf)"
    [ "$CNF" = /dev/null ] && { CNF=""; _PW_WHY="no private directory for the client option file"; return 0; }
    ( umask 077
      {
          # The client reads one --defaults-file only and one extra file only,
          # so the operator's file is included from ours rather than lost.
          [ -n "$inc" ] && printf '!include %s\n' "$inc"
          printf '[client]\npassword="%s"\n' "$q"
      } > "$CNF" ) 2>/dev/null || { CNF=""; _PW_WHY="the client option file could not be written"; }
}

# MYSQL_ARGV -> the client's arguments, one word each. Built once: an unquoted
# $(...) split a --defaults-file path with a space in two and let a glob
# character in an argument match files in the working directory.
MYSQL_ARGV=()
_build_client_argv() {
    local w
    MYSQL_ARGV=()
    if [ -n "$CNF" ]; then
        if [ -n "$DEFAULTS_FILE" ]; then MYSQL_ARGV=("--defaults-file=$CNF")
        else MYSQL_ARGV=("--defaults-extra-file=$CNF"); fi
    elif [ -n "$DEFAULTS_FILE" ]; then
        MYSQL_ARGV=("--defaults-file=$DEFAULTS_FILE")
        [ -n "$EXTRA_FILE" ] && MYSQL_ARGV=("${MYSQL_ARGV[@]}" "--defaults-extra-file=$EXTRA_FILE")
    elif [ -n "$EXTRA_FILE" ]; then
        MYSQL_ARGV=("--defaults-extra-file=$EXTRA_FILE")
    fi
    set -f
    for w in $MYSQL_ARGS; do MYSQL_ARGV[${#MYSQL_ARGV[@]}]="$w"; done
    set +f
}

# mysql_q "SQL" -> raw tab-separated rows on stdout, nonzero on failure
mysql_q() {
    [ -n "$MYSQL_BIN" ] || return 127
    _bounded "$MYSQL_BIN" "${MYSQL_ARGV[@]}" -N -B -e "$1" 2>"$_errfile"
}

# mysql_vertical "SQL" -> \G style output (for STATUS commands)
mysql_vertical() {
    [ -n "$MYSQL_BIN" ] || return 127
    _bounded "$MYSQL_BIN" "${MYSQL_ARGV[@]}" -e "$1\G" 2>"$_errfile"
}

# sql "label" "SQL" [VAR] -> rows as facts, or a classified reason. VAR, when
# given, also receives what mysql_val would return for the same SQL (the last
# field of the first row, empty without a login), so a value the report shows
# and later uses is asked for once.
sql() {
    local label="$1" q="$2" var="${3:-}" out rc _l
    if [ "$MYSQL_OK" != 1 ]; then
        [ -n "$var" ] && printf -v "$var" '%s' ""
        fact "$label: n/a ($MYSQL_WHY)"; return
    fi
    out="$(mysql_q "$q")"; rc=$?
    if [ -n "$var" ]; then
        # awk '{print $NF}' of the first line: a line with no field is kept whole
        _l="${out%%$'\n'*}"
        # shellcheck disable=SC2086
        set -f; set -- $_l; set +f
        [ "$#" -gt 0 ] && eval "_l=\${$#}"
        printf -v "$var" '%s' "$_l"
    fi
    [ "$rc" -eq 124 ] && { fact "$label: n/a ($(_why_124))"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: none"; return; }
    _emit_labeled "$label" "$out"
}

sqlv() {
    local label="$1" q="$2" out rc
    if [ "$MYSQL_OK" != 1 ]; then fact "$label: n/a ($MYSQL_WHY)"; return; fi
    out="$(mysql_vertical "$q")"; rc=$?
    [ "$rc" -eq 124 ] && { fact "$label: n/a ($(_why_124))"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: none"; return; }
    _emit_labeled "$label" "$out"
}

# _why_124 -> why a bounded call returned 124: the run deadline, or its own cap
_why_124() {
    if _past_deadline; then printf 'run deadline reached: %ss' "$RUN_DEADLINE"
    else printf 'timed out: %ss' "$CMD_TIMEOUT"; fi
}

# one scalar value, empty on failure (used for discovery, not for output)
mysql_val() {
    [ "$MYSQL_OK" = 1 ] || return 1
    mysql_q "$1" 2>/dev/null | head -n1 | awk '{print $NF}'
}

_resolve_mysql() {
    local c
    for c in mysql mariadb; do have "$c" && { MYSQL_BIN="$(command -v $c)"; break; }; done
    if [ -z "$MYSQL_BIN" ]; then MYSQL_WHY="command not found: mysql"; return; fi
    # The client's own status: the login check, and where it connected (the
    # host or socket after option files and the environment are applied).
    local st rc l
    st="$(mysql_q "status" 2>/dev/null)"; rc=$?
    MYSQL_CONN=""
    while IFS= read -r l; do
        case "$l" in Connection:*) l="${l#Connection:}"; MYSQL_CONN="${l#"${l%%[![:space:]]*}"}" ;; esac
    done <<EOF
$st
EOF
    case "$rc" in
        0)   MYSQL_OK=1; MYSQL_WHY="ok" ;;
        124) if _past_deadline; then MYSQL_WHY="run deadline reached (${RUN_DEADLINE}s) before the login"
             else MYSQL_WHY="timed out: ${CMD_TIMEOUT}s"; fi ;;
        *)   MYSQL_WHY="$(_classify_err)" ;;
    esac
}

# _local_ips FIB_TRIE -> the IPv4 addresses a network namespace owns (its
# "/32 host LOCAL" entries), one per line. No fork.
_local_ips() {
    local l prev=""
    while IFS= read -r l; do
        case "$l" in
            *"/32 host LOCAL"*) [ -n "$prev" ] && printf '%s\n' "$prev" ;;
            *"-- "[0-9]*) prev="${l##*-- }" ;;
        esac
    done < "$1" 2>/dev/null
}

# _bl_target -> where the client connected, classified: _BL_TGT is "local"
# (a socket, loopback or an address of this host), "ips" (addresses in
# _BL_TGT_IPS, not this host's: a local mysqld's own network namespace may
# still own one, e.g. a container reached on its bridge address), or
# "unknown" (no Connection line, IPv6, a name that did not resolve).
# _BL_TGT_WHY says it in words.
_bl_target() {
    _BL_TGT="unknown"; _BL_TGT_IPS=""; _BL_TGT_WHY="not known (${MYSQL_CONN:-no Connection line})"
    local h="${MYSQL_CONN% via *}" how="${MYSQL_CONN##* via }" ip own
    [ -n "$MYSQL_CONN" ] || return 0
    case "$how" in *[Ss]ocket*|*[Pp]ipe*|*[Mm]emory*)
        _BL_TGT="local"; _BL_TGT_WHY="local ($MYSQL_CONN)"; return 0 ;;
    esac
    case "$h" in
        [Ll]ocalhost|::1|127.*) _BL_TGT="local"; _BL_TGT_WHY="local ($MYSQL_CONN)"; return 0 ;;
        *:*) return 0 ;;
        *[!0-9.]*) have getent && _BL_TGT_IPS="$(_bounded getent ahostsv4 "$h" 2>/dev/null | awk '!s[$1]++ {print $1}')"
                   [ -n "$_BL_TGT_IPS" ] || { _BL_TGT_WHY="not known ($h did not resolve here)"; return 0; } ;;
        *) _BL_TGT_IPS="$h" ;;
    esac
    own="$_nl$(_local_ips "$PROC_ROOT/net/fib_trie")$_nl"
    while IFS= read -r ip; do
        case "$ip" in 127.*) _BL_TGT="local"; _BL_TGT_WHY="local ($MYSQL_CONN, loopback)"; return 0 ;; esac
        case "$own" in *"$_nl$ip$_nl"*) _BL_TGT="local"; _BL_TGT_WHY="local ($MYSQL_CONN, $ip is an address of this host)"; return 0 ;; esac
    done <<EOF
$_BL_TGT_IPS
EOF
    _BL_TGT="ips"
    _BL_TGT_WHY="$MYSQL_CONN, ${_BL_TGT_IPS//$_nl/ } not an address of this host"
}

# _binlog_proc -> the local mysqld/mariadbd that is the server connected to;
# its logs are read through /proc/P/root. P qualifies when:
# 1. @@pid_file through /proc/P/root holds P's pid in its namespace (last
#    NSpid field); when this uid may not enter that root, the pid file as
#    this run sees it holds P's pid;
# 2. that pid file was written at or after the server's start (now - Uptime,
#    both wall clock; 3 s early allowed) and within 1800 s of it (mysqld
#    writes it after InnoDB recovery): another server's is older or newer;
# 3. where readable, the auto.cnf under P's datadir holds @@server_uuid;
# 4. P's binlog directory holds the server's newest log at no less than the
#    listed size and nothing newer (a newer file: SHOW BINARY LOGS is asked
#    once more, and it must now list it).
# 0. First, where the client connected (its status): a TCP address that this
#    host does not own is remote unless P's network namespace owns it; a
#    socket, loopback or own address goes on to 1-4; unknown too.
# One stat per candidate that passes 1, one ls per candidate that passes 3.
# Sets _BL_PID, _BL_ROOT, _BL_VIA, _BL_LS (the listing), or _BL_WHY (a fact),
# _BL_ADVICE (how to run it differently: for the goal reason only) and
# _BL_PRIV=1 when a pid file could not be read for want of privilege.
_binlog_proc() {
    _BL_PID=""; _BL_ROOT=""; _BL_VIA=""; _BL_WHY=""; _BL_PRIV=0; _BL_LS=""; _BL_ADVICE=""
    if [ "$MYSQL_OK" != 1 ]; then _BL_WHY="not queried: $MYSQL_WHY"; return; fi
    local pf="$PID_FILE" d c p ns l v st rt how u lsout chk last="" lsz="" rows2 asked=0
    local srv="" hits=0 cand=0 unread="" other="" ok="" mt r2last="" r2sz=""
    case "$pf" in
        '') _BL_WHY="@@pid_file gave no path, so the server's process cannot be identified"; return ;;
        /*) ;;
        *) pf="${DATADIR%/}/$pf" ;;
    esac
    case "$_NOW_AT_Q$SRV_UPTIME" in *[!0-9]*|'') ;; *) srv=$((_NOW_AT_Q - SRV_UPTIME)) ;; esac
    # 0. where the client connected: a TCP address that neither this host nor
    # a local mysqld's network namespace owns is a remote server
    _bl_target
    local netns_ok ip mine owned=0
    if [ -n "$_bl_rows" ]; then
        l="${_bl_rows%"$_nl"}"; l="${l##*"$_nl"}"; set -f; set -- $l; set +f; last="${1:-}"; lsz="${2:-}"
    fi
    for d in "$PROC_ROOT"/[0-9]*; do
        c=""; IFS= read -r c < "$d/comm" 2>/dev/null
        case "$c" in mysqld|mariadbd) ;; *) continue ;; esac
        p="${d##*/}"
        st=""; IFS= read -r st < "$d/stat" 2>/dev/null; st="${st##*) }"
        case "$st" in Z*|X*) continue ;; esac      # a zombie holds no files
        cand=$((cand + 1)); v=""
        if [ "$_BL_TGT" = ips ]; then
            netns_ok=0; mine="$_nl$(_local_ips "$d/net/fib_trie")$_nl"
            while IFS= read -r ip; do
                [ -n "$ip" ] && case "$mine" in *"$_nl$ip$_nl"*) netns_ok=1 ;; esac
            done <<EOF
$_BL_TGT_IPS
EOF
            if [ "$netns_ok" = 0 ]; then other="$other $p(its network namespace does not own ${_BL_TGT_IPS//$_nl/ })"; continue; fi
            owned=$((owned + 1))
        fi
        # 1. the pid file
        if [ -d "$d/root/." ]; then
            rt="$d/root"; how="read through $rt"; ns="$p"
            while IFS= read -r l; do
                case "$l" in NSpid:*) set -f; set -- $l; set +f; eval "ns=\${$#}" ;; esac
            done < "$d/status" 2>/dev/null
            # absent only when its directory could be searched (a datadir of
            # mode 700 hides it from a mysql-group user: unreadable, not absent)
            v="$rt$pf"; v="${v%/*}"
            if [ ! -e "$rt$pf" ] && [ -x "${v:-/}" ]; then other="$other $p(pid file absent)"; v=""; continue; fi
            v=""
            [ -r "$rt$pf" ] || { unread="$unread $p"; continue; }
            IFS= read -r v < "$rt$pf" 2>/dev/null
        else
            # a root this uid may not enter (another uid; no CAP_SYS_PTRACE in
            # a container): the pid file as seen here, holding P's own pid
            rt=""; how="read here"; ns="$p"
            v="${pf%/*}"
            if [ ! -e "$pf" ] && [ -x "${v:-/}" ]; then other="$other $p(pid file absent here; /proc/$p/root not enterable by uid $(id -u 2>/dev/null || echo '?'))"; v=""; continue; fi
            v=""
            [ -r "$pf" ] || { unread="$unread $p"; continue; }
            IFS= read -r v < "$pf" 2>/dev/null
        fi
        if [ "$v" != "$ns" ]; then other="$other $p(pid file holds ${v:-nothing})"; continue; fi
        # 2. the pid file written with the server's start
        mt="$(_bounded stat -c %Y -- "$rt$pf" 2>/dev/null)"
        case "$mt$srv" in
            *[!0-9]*|'') other="$other $p(pid file time or server start unknown)"; continue ;;
        esac
        if [ "$mt" -lt $((srv - 3)) ] || [ "$mt" -gt $((srv + 1800)) ]; then
            other="$other $p(pid file written at $mt, the server started at $srv)"; continue
        fi
        # 2. the uuid, where MySQL keeps one
        if [ -n "$SRV_UUID" ] && [ -n "$DATADIR" ] && [ -r "$rt${DATADIR%/}/auto.cnf" ]; then
            u=""
            while IFS= read -r l; do case "$l" in server-uuid=*) u="${l#server-uuid=}" ;; esac; done < "$rt${DATADIR%/}/auto.cnf"
            if [ -n "$u" ] && [ "$u" != "$SRV_UUID" ]; then other="$other $p(auto.cnf server-uuid $u, the server's $SRV_UUID)"; continue; fi
        fi
        # 3. the server's newest log, and nothing newer
        lsout=""
        if [ -n "$last" ] && [ -n "$BINLOG_DIR" ] && [ -r "$rt$BINLOG_DIR" ] && [ -x "$rt$BINLOG_DIR" ]; then
            lsout="$(_bounded ls -l --time-style=+%Y-%m-%dT%H:%M:%SZ -- "$rt$BINLOG_DIR" 2>/dev/null)"
            chk="$(_bl_newest "$lsout" "$last" "$lsz")"
            case "$chk" in
                N\ *)
                    # a newer file only: a rotation since SHOW BINARY LOGS, or
                    # another server's log. Asked once more, once per run.
                    if [ "$asked" = 0 ]; then
                        asked=1; rows2="$(mysql_q "SHOW BINARY LOGS")" || rows2=""
                        if [ -n "$rows2" ]; then
                            l="${rows2%"$_nl"}"; l="${l##*"$_nl"}"; set -f; set -- $l; set +f
                            r2last="${1:-}"; r2sz="${2:-}"
                            # the listing's newest is now listed (rotation may
                            # have gone on since): the fresh rows count
                            case "$_nl$rows2" in *"$_nl${chk#N }$_tab"*)
                                _bl_rows="$rows2"; last="$r2last"; lsz="$r2sz"; chk="" ;;
                            esac
                        fi
                    fi
                    [ -n "$chk" ] && chk="holds ${chk#N }, which SHOW BINARY LOGS does not list (asked again; its newest: ${r2last:-$last})" ;;
            esac
            [ -n "$chk" ] && { other="$other $p($chk)"; continue; }
        fi
        ok="$ok$p|$rt|$how|$ns|$mt$_nl"
        hits=$((hits + 1)); _BL_LS="$lsout"
    done
    if [ "$hits" = 1 ]; then
        IFS='|' read -r _BL_PID _BL_ROOT how ns mt <<EOF
$ok
EOF
        l="$_BL_TGT_WHY"; [ "$_BL_TGT" = ips ] && l="$l, owned by its network namespace"
        _BL_VIA="via pid $_BL_PID (connection $l; pid file $pf, $how, holds its pid $ns, written $((mt - srv))s after the server started${last:+, holds the newest log $last})"
        return
    fi
    _BL_LS=""
    if [ "$hits" -gt 1 ]; then
        _BL_WHY="more than one local mysqld/mariadbd has the server's pid file $pf (with its start), uuid and newest log, so which one is the server is not known"
    elif [ -n "$unread" ]; then
        _BL_PRIV=1
        _BL_WHY="the server's pid file $pf could not be read for mysqld/mariadbd pid${unread} by uid $(id -u 2>/dev/null || echo '?')"
    elif [ "$_BL_TGT" = ips ] && [ "$owned" = 0 ]; then
        _BL_WHY="the server is remote (connected to $_BL_TGT_WHY, nor of a local mysqld's network namespace)"
        _BL_ADVICE="; run the collector on the database host to read its binary logs"
    elif [ "$cand" = 0 ]; then
        _BL_WHY="the server's process (pid file $pf) is not on this host: no mysqld or mariadbd process runs here"
    else
        _BL_WHY="the server's process (pid file $pf) is not on this host: no local mysqld/mariadbd is it:$other"
    fi
}

# _bl_newest LISTING LAST SIZE -> empty when the listing holds LAST at no less
# than SIZE bytes and no newer file of its name; else "N NAME" for a newer
# file only, or the reason.
_bl_newest() {
    printf '%s\n' "$1" | awk -v last="$2" -v lsz="$3" '
        function num(f) { sub(/.*\./, "", f); return f + 0 }
        function pre(f) { sub(/\.[0-9]+$/, "", f); return f }
        $NF ~ /\.[0-9][0-9][0-9][0-9][0-9][0-9]$/ {
            if ($NF == last) { found = 1; sz = $5 }
            if (pre($NF) == pre(last) && num($NF) > num(last) && num($NF) > nn) { newer = $NF; nn = num($NF) }
        }
        END {
            if (!found) print "no " last ", the server'"'"'s newest log"
            else if (sz + 0 < lsz + 0) print last " is " sz " bytes, the server'"'"'s " lsz
            else if (newer != "") print "N " newer
        }'
}


# ---- report body ------------------------------------------------------------
run_report() {
    emit_header

    # This collector's sections are lettered by hand, so the roll-up carries one too.

    # Nearly everything here comes from SQL, so the login is the goal that
    # decides whether a run answers anything at all. `binlog` is declared only
    # when it was asked for: without --binlog its absence is a choice, not a gap.
    goal login  "mysql login"
    goal host   "host-side facts (process, sockets, disk)"
    [ "$OPT_BINLOG" = 1 ] && goal binlog "binary log content attribution"

    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown)"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    # Section D's kernel counters are totals since boot.
    _note_boot
    # The whole run is bounded by this, raised for what this run was asked to do.
    fact "run deadline(s): $RUN_DEADLINE"
    fact "tools:"
    for t in mysql mysqlbinlog iostat vmstat ss findmnt lsblk timeout; do
        if have "$t"; then sub "$(printf '%-12s present' "$t")"
        else sub "$(printf '%-12s absent' "$t")"; fi
    done
    fact "mysql client: ${MYSQL_BIN:-n/a (command not found)}"
    # What the connection was attempted with: it survives a refused login, which
    # never reaches section A. The password is never printed, only its source.
    if [ -n "$DEFAULTS_FILE$EXTRA_FILE" ] || [ -n "$MYSQL_ARGS" ]; then
        fact "connection attempted with:${DEFAULTS_FILE:+ --defaults-file=$DEFAULTS_FILE}${EXTRA_FILE:+ --defaults-extra-file=$EXTRA_FILE}${MYSQL_ARGS:+ $MYSQL_ARGS}"
    else
        fact "connection attempted with: no arguments (client defaults: account from uid $(id -u 2>/dev/null || echo '?') = $(id -un 2>/dev/null || echo unknown), unix socket)"
    fi
    if [ -n "$CNF" ]; then fact "password: from $_PW_SRC, handed to the client in a mode-600 option file"
    elif [ -n "$_PW_WHY" ]; then fact "password: n/a ($_PW_WHY)"
    else fact "password: none given to this collector"; fi
    fact "mysql connection: $MYSQL_WHY"
    [ "$MYSQL_OK" = 1 ] && fact "connected to: ${MYSQL_CONN:-n/a (no Connection line in the client status)}"
    # One process list answers both whether a mysqld runs here (the login
    # reason below) and section A's process line. Not pgrep -f: it would match
    # this run's timeout wrapper.
    _PS_OUT=""; _PS_RC=127
    if have ps; then _PS_OUT="$(_bounded ps -eo pid,user,args 2>/dev/null)"; _PS_RC=$?; fi
    if [ "$MYSQL_OK" = 1 ]; then got login
    elif [ -z "$MYSQL_BIN" ]; then missed login "command not found: mysql or mariadb client"
    elif [ -z "$MYSQL_ARGS" ] && [ -z "$DEFAULTS_FILE$EXTRA_FILE" ] && [ -z "$_PW_WHY" ] \
         && ! printf '%s\n' "$_PS_OUT" | grep -qE '^ *[0-9]+ +[^ ]+ .*(mysqld|mariadbd)'; then
        # The backend's MySQL is often on another host. No local server and no
        # connection arguments is therefore a run that asked nowhere, not an
        # answer: --mysql-args would obtain it.
        missed login "no local mysqld found and no --mysql-args given (client without arguments: $MYSQL_WHY)$(_priv_hint)"
    # The prompt's outcome and the shared privilege hint both belong to the
    # reason. The hint says only that the run was not elevated, as in every
    # collector; it does not claim that sudo would fix this login.
    else missed login "$MYSQL_WHY${_PW_WHY:+; $_PW_WHY}$(_priv_hint)"; fi
    fact "binlog decode tier: $([ "$OPT_BINLOG" = 1 ] && echo "on (newest $BINLOG_FILES files)" || echo "off")"
    fact "sampling tier: $([ "$OPT_SAMPLE" = 1 ] && echo "on (${SAMPLE_SEC}s x ${SAMPLE_COUNT})" || echo "off")"

    section "A. Server identity and version"
    # Which account the server matched, not which one was asked for. They differ
    # when a host pattern matches something wider than the literal name, and the
    # difference is the grant row a later "access denied" belongs to.
    sql "connected as"   "SELECT CONCAT(USER(), ' -> matched ', CURRENT_USER())"
    sql "version"        "SELECT VERSION()"
    sql "server host"    "SELECT @@hostname"
    sql "server_id"      "SELECT @@server_id"
    sql "server_uuid"    "SELECT @@server_uuid" SRV_UUID
    # The clock just before Uptime is asked: now - Uptime is then the earliest
    # the server can have started (wall clock), which its pid file's mtime is
    # compared with (_binlog_proc); a slow answer cannot push it later.
    _NOW_AT_Q=""
    if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; then
        printf -v _NOW_AT_Q '%(%s)T' -1
    else _NOW_AT_Q="$(date +%s 2>/dev/null)"; fi
    sql "uptime(s)"      "SHOW GLOBAL STATUS LIKE 'Uptime'" SRV_UPTIME
    # super_read_only arrived in 5.7; asking for both in one row loses read_only
    # on 5.6 and on MariaDB.
    sql "read_only"      "SELECT @@read_only"
    sql "super_read_only" "SELECT @@super_read_only"
    sql "port / socket"  "SELECT @@port, @@socket"
    sql "datadir"        "SELECT @@datadir" DATADIR
    sql "pid_file"       "SELECT @@pid_file" PID_FILE
    # From the process list taken for the login reason. A missing ps is an
    # error, not "empty output"; no match is empty output.
    if [ "$_PS_RC" = 127 ] && ! have ps; then
        fact "local mysqld process: n/a (error: command not found: ps)"
    elif [ "$_PS_RC" = 124 ]; then
        if _past_deadline; then fact "local mysqld process: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "local mysqld process: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
    else
        _l="$(printf '%s\n' "$_PS_OUT" | grep -E '[m]ysqld|[m]ariadbd' | grep -v timeout)"
        if [ -n "$_l" ]; then _emit_labeled "local mysqld process" "$_l"
        else fact "local mysqld process: n/a (empty output)"; fi
    fi
    probe "listening sockets" sh -c \
        "command -v ss >/dev/null || command -v netstat >/dev/null || { echo 'command not found: ss, netstat' >&2; exit 3; }; \
         { ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null; } | grep -E ':3306|:33060'; true"
    # These two are the part that survives a failed login, so they are their own
    # goal: a run with no SQL at all is still worth sending if they came back.
    if have ps || have ss || have netstat; then got host
    else missed host "no ps, ss or netstat on this host"; fi

    section "B. HA and replication"
    sql  "binlog_format"       "SELECT @@binlog_format"
    sql  "gtid_mode"           "SELECT @@gtid_mode"
    sql  "enforce_gtid_consistency" "SELECT @@enforce_gtid_consistency"
    sql  "log_replica_updates" "SHOW VARIABLES LIKE 'log_slave_updates'"
    sqlv "replica status"      "SHOW REPLICA STATUS"
    sqlv "slave status"        "SHOW SLAVE STATUS"
    # 8.2 renamed SHOW MASTER STATUS (8.4 removed it); before 8.2 and on
    # MariaDB the new name is a syntax error (1064), answered by the old one.
    if [ "$MYSQL_OK" != 1 ]; then fact "binary log status: n/a ($MYSQL_WHY)"
    else
        _o="$(mysql_vertical "SHOW BINARY LOG STATUS")"; _rc=$?
        _e=""; [ "$_rc" -ne 0 ] && [ "$_rc" -ne 124 ] && _e="$(cat "$_errfile" 2>/dev/null)"
        case "$_e" in
            *"ERROR 1064"*) sqlv "binary log status (SHOW MASTER STATUS)" "SHOW MASTER STATUS" ;;
            *) if [ "$_rc" -eq 124 ]; then fact "binary log status: n/a ($(_why_124))"
               elif [ "$_rc" -ne 0 ]; then fact "binary log status: n/a ($(_classify_err))"
               elif [ -z "$_o" ]; then fact "binary log status: none"
               else _emit_labeled "binary log status" "$_o"; fi ;;
        esac
    fi
    sql  "connected replicas"  "SHOW REPLICAS"
    sql  "connected slaves"    "SHOW SLAVE HOSTS"
    sql  "galera wsrep"        "SHOW STATUS LIKE 'wsrep_cluster_size'"
    # MEMBER_ROLE arrived in 8.0; naming it breaks the whole row on 5.7.
    sql  "group replication"   "SELECT MEMBER_HOST, MEMBER_STATE FROM performance_schema.replication_group_members"
    sql  "semi-sync"           "SHOW STATUS LIKE 'Rpl_semi_sync%_status'"

    section "C. Binary log inventory and retention"
    sql "log_bin"                     "SELECT @@log_bin" LOG_BIN
    sql "log_bin_basename"            "SELECT @@log_bin_basename" BINLOG_BASE
    sql "log_bin_index"               "SELECT @@log_bin_index" BINLOG_INDEX
    sql "max_binlog_size"             "SELECT @@max_binlog_size"
    sql "binlog_expire_logs_seconds"  "SHOW VARIABLES LIKE 'binlog_expire_logs_seconds'"
    sql "expire_logs_days"            "SHOW VARIABLES LIKE 'expire_logs_days'"
    sql "binlog_row_image"            "SHOW VARIABLES LIKE 'binlog_row_image'"
    sql "binlog_rows_query_log_events" "SHOW VARIABLES LIKE 'binlog_rows_query_log_events'"
    sql "sync_binlog"                 "SELECT @@sync_binlog"
    # A host whose binary logs accumulate can hold thousands of files, and the
    # full listing would be the whole report. Report the inventory as totals
    # plus both ends; section I attributes the content.
    # _bl_rows (name, bytes per row) also serves the directory listing below
    # and section I, so no file is stat'ed for a size the server already gave.
    _bl_rows=""; _BL_INV_WHY=""
    if [ "$MYSQL_OK" != 1 ]; then
        fact "binary logs: n/a ($MYSQL_WHY)"
    else
        # A refusal is not an empty list: without REPLICATION CLIENT the server
        # answers ERROR 1227, which used to read as "binary logs: none".
        _bl_rows="$(mysql_q "SHOW BINARY LOGS")"; _bl_rc=$?
        if [ "$_bl_rc" -ne 0 ]; then
            # a cut or refused answer is no list, however many rows it printed
            _bl_rows=""
            if [ "$_bl_rc" -eq 124 ]; then _BL_INV_WHY="$(_why_124)"
            else _BL_INV_WHY="$(_classify_err)"; fi
            fact "binary logs: n/a (SHOW BINARY LOGS: $_BL_INV_WHY)"
        elif [ -z "$_bl_rows" ]; then
            fact "binary logs: none"
        else
            fact "binary logs: $(printf '%s\n' "$_bl_rows" | wc -l | tr -d ' ') files, $(printf '%s\n' "$_bl_rows" | awk '{s+=$2} END {printf "%.0f", s+0}') bytes total (SHOW BINARY LOGS)"
            fact "binary logs (oldest 3, name bytes):"
            printf '%s\n' "$_bl_rows" | head -3 | while IFS= read -r _l; do sub "$_l"; done
            fact "binary logs (newest 20, name bytes):"
            printf '%s\n' "$_bl_rows" | tail -20 | while IFS= read -r _l; do sub "$_l"; done
        fi
    fi
    sql "binlog cache use / disk use" "SHOW GLOBAL STATUS LIKE 'Binlog_cache%'"
    sql "Binlog_bytes_written"        "SHOW GLOBAL STATUS LIKE 'Binlog%bytes%'"

    # Growth comes from file mtimes (no second sample). A NULL or bare-name
    # log_bin_basename leaves no directory, not dirname's ".".
    BINLOG_DIR=""
    case "$BINLOG_BASE" in
        /*) BINLOG_DIR="${BINLOG_BASE%/*}"; BINLOG_DIR="${BINLOG_DIR:-/}" ;;
    esac
    # The files are the server process's (_binlog_proc), read through its
    # /proc/<pid>/root: LDIR is BINLOG_DIR as that process sees it.
    _binlog_proc
    LDIR=""; [ -n "$BINLOG_DIR" ] && [ -n "$_BL_PID" ] && LDIR="$_BL_ROOT$BINLOG_DIR"
    if [ -z "$BINLOG_DIR" ]; then
        if [ "$MYSQL_OK" != 1 ]; then fact "binlog directory: n/a (not queried: $MYSQL_WHY)"
        else fact "binlog directory: n/a (@@log_bin_basename is not an absolute path: ${BINLOG_BASE:-empty})"; fi
    elif [ -z "$LDIR" ]; then
        fact "binlog directory: $BINLOG_DIR (not listed: $_BL_WHY)"
    elif [ -d "$LDIR" ] && [ -r "$LDIR" ]; then
        fact "binlog directory: $BINLOG_DIR"
        fact "binlog files: $_BL_VIA, $LDIR"
        # One listing: the mtimes are what only the directory has (growth).
        # Sizes and the total are SHOW BINARY LOGS' above; without that list
        # (refused, timed out) the same listing sums the binlog files. Not du:
        # with the logs in the datadir it walks the whole datadir.
        _tot=""; [ -z "$_bl_rows" ] && _tot=1
        # the listing _binlog_proc took to check the newest log, when it did
        if [ -n "$_BL_LS" ]; then _ls="$_BL_LS"; _rc=0
        else _ls="$(_bounded ls -l --time-style=+%Y-%m-%dT%H:%M:%SZ -- "$LDIR" 2>"$_errfile")"; _rc=$?; fi
        _ls="$(printf '%s\n' "$_ls" | awk -v tot="$_tot" '
            $NF ~ /\.[0-9][0-9][0-9][0-9][0-9][0-9]$/ { n++; s += $5; l[n] = $0 }
            END {
                for (i = (n > 20 ? n - 19 : 1); i <= n; i++) print l[i]
                if (tot && n) printf "total: %d files, %.0f bytes (directory listing)\n", n, s
            }')"
        if [ "$_rc" -eq 124 ]; then fact "newest binlog files (mtime, bytes): n/a ($(_why_124))"
        elif [ -n "$_ls" ]; then _emit_labeled "newest binlog files (mtime, bytes)" "$_ls"
        elif [ "$_rc" -ne 0 ]; then fact "newest binlog files (mtime, bytes): n/a ($(_classify_err))"
        else fact "newest binlog files (mtime, bytes): n/a (empty output)"; fi
    else
        fact "binlog directory: $BINLOG_DIR (not readable by uid $(id -u 2>/dev/null || echo '?') at $LDIR)"
    fi

    section "D. Storage and I/O"
    probe "df -hT" df -hT
    probe "mount points" sh -c "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount"
    if [ -n "$DATADIR" ] && [ -d "$DATADIR" ]; then
        fact "datadir: $DATADIR"
        probe "datadir filesystem" sh -c 'df -hT "$1" 2>/dev/null | tail -n +2' sh "$DATADIR"
    else
        fact "datadir: ${DATADIR:-n/a (not resolved)} (not present on this host)"
    fi
    read_proc "kernel diskstats" /proc/diskstats
    sql "Innodb_data counters"        "SHOW GLOBAL STATUS LIKE 'Innodb_data_%'"
    sql "Innodb_os_log counters"      "SHOW GLOBAL STATUS LIKE 'Innodb_os_log%'"
    sql "Innodb_buffer_pool reads"    "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%'"
    sql "Innodb_buffer_pool pages"    "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_pages_%'"
    sql "Innodb_row operations"       "SHOW GLOBAL STATUS LIKE 'Innodb_rows_%'"
    sql "Com_ counters"               "SHOW GLOBAL STATUS WHERE Variable_name IN ('Com_select','Com_insert','Com_update','Com_delete','Com_commit','Queries')"

    section "E. InnoDB configuration"
    sql "innodb_page_size"               "SELECT @@innodb_page_size"
    sql "innodb_buffer_pool_size"        "SELECT @@innodb_buffer_pool_size"
    sql "innodb_flush_log_at_trx_commit" "SELECT @@innodb_flush_log_at_trx_commit"
    sql "innodb_flush_method"            "SHOW VARIABLES LIKE 'innodb_flush_method'"
    sql "innodb_doublewrite"             "SELECT @@innodb_doublewrite"
    sql "innodb_io_capacity"             "SHOW VARIABLES LIKE 'innodb_io_capacity%'"
    sql "innodb_log_file settings"       "SHOW VARIABLES LIKE 'innodb_log_file%'"
    sql "innodb_redo_log_capacity"       "SHOW VARIABLES LIKE 'innodb_redo_log_capacity'"
    sqlv "engine status"                 "SHOW ENGINE INNODB STATUS"

    section "F. Schema footprint"
    sql "schemas (name, tables, data MB, index MB)" \
        "SELECT table_schema, COUNT(*), ROUND(SUM(data_length)/1024/1024,1), ROUND(SUM(index_length)/1024/1024,1) FROM information_schema.tables GROUP BY table_schema ORDER BY SUM(data_length+index_length) DESC"
    sql "largest 25 tables (schema, table, rows, data MB, index MB)" \
        "SELECT table_schema, table_name, table_rows, ROUND(data_length/1024/1024,1), ROUND(index_length/1024/1024,1) FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY data_length+index_length DESC LIMIT 25"
    sql "tables whose name contains lock/metering/event/audit" \
        "SELECT table_schema, table_name, table_rows FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') AND (table_name LIKE '%lock%' OR table_name LIKE '%meter%' OR table_name LIKE '%event%' OR table_name LIKE '%audit%') ORDER BY table_rows DESC"
    # A reader asking "is this query scanning?" needs the index the deployed
    # schema has, not the one the entity declares.
    sql "indexes of the 15 largest tables (schema, table, index, seq, column, cardinality)" \
        "SELECT s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX, s.COLUMN_NAME, s.CARDINALITY FROM information_schema.statistics s JOIN (SELECT table_schema, table_name FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') ORDER BY data_length+index_length DESC LIMIT 15) t ON t.table_schema = s.TABLE_SCHEMA AND t.table_name = s.TABLE_NAME ORDER BY s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME, s.SEQ_IN_INDEX"
    sql "columns of DeniedIPAddress and ApmRegion" \
        "SELECT table_schema, table_name, column_name, is_nullable, column_type FROM information_schema.columns WHERE table_name IN ('DeniedIPAddress','ApmRegion') ORDER BY table_schema, table_name, ordinal_position"

    section "G. Per-table I/O and index wait, from performance_schema"
    sql "performance_schema enabled" "SELECT @@performance_schema"
    sql "top 20 tables by I/O wait (schema, table, count, latency ns)" \
        "SELECT OBJECT_SCHEMA, OBJECT_NAME, COUNT_STAR, SUM_TIMER_WAIT FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema') ORDER BY SUM_TIMER_WAIT DESC LIMIT 20"
    sql "top 20 tables by rows written (schema, table, inserts, updates, deletes)" \
        "SELECT OBJECT_SCHEMA, OBJECT_NAME, COUNT_INSERT, COUNT_UPDATE, COUNT_DELETE FROM performance_schema.table_io_waits_summary_by_table WHERE OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema') ORDER BY COUNT_INSERT+COUNT_UPDATE+COUNT_DELETE DESC LIMIT 20"
    sql "top 15 statements by total latency (digest, count, latency ns, rows examined)" \
        "SELECT LEFT(DIGEST_TEXT,120), COUNT_STAR, SUM_TIMER_WAIT, SUM_ROWS_EXAMINED FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_TIMER_WAIT DESC LIMIT 15"
    sql "top 15 statements by rows examined (digest, count, rows examined, rows sent)" \
        "SELECT LEFT(DIGEST_TEXT,120), COUNT_STAR, SUM_ROWS_EXAMINED, SUM_ROWS_SENT FROM performance_schema.events_statements_summary_by_digest ORDER BY SUM_ROWS_EXAMINED DESC LIMIT 15"
    sql "file I/O by event (event, count read, bytes read, count write, bytes written)" \
        "SELECT EVENT_NAME, COUNT_READ, SUM_NUMBER_OF_BYTES_READ, COUNT_WRITE, SUM_NUMBER_OF_BYTES_WRITE FROM performance_schema.file_summary_by_event_name WHERE COUNT_STAR > 0 ORDER BY SUM_NUMBER_OF_BYTES_WRITE DESC LIMIT 15"

    section "H. Current activity"
    sql "processlist"            "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO,120) FROM information_schema.processlist ORDER BY TIME DESC LIMIT 30"
    sql "threads connected/running" "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections')"
    sql "max_connections"        "SELECT @@max_connections"

    section "I. Binary log content attribution"
    # Obtained only when every selected file was decoded to its end; a failed
    # or capped decode is a gap, however many counters it printed.
    if [ "$OPT_BINLOG" != 1 ]; then
        fact "n/a (not requested: --binlog not given)"
    elif [ "$MYSQL_OK" = 1 ] && [ "$LOG_BIN" = 0 ]; then
        # Checked before the decoder: a server that writes no binary log has
        # nothing to decode, whatever tools the host has.
        fact "n/a (@@log_bin is 0 on this server)"
        na binlog "@@log_bin is 0 on this server, so it writes no binary log"
    elif ! have mysqlbinlog; then
        fact "n/a (command not found: mysqlbinlog)"
        missed binlog "command not found: mysqlbinlog"
    elif [ -z "$BINLOG_DIR" ]; then
        # Splitting these two matters: an unresolved path is answered by getting
        # a login, an unreadable one by getting a different account. The old
        # wording covered both and answered neither (Smartfren, 2026-09-23).
        if [ "$MYSQL_OK" != 1 ]; then fact "n/a (binary log directory not resolved: @@log_bin_basename not queried: $MYSQL_WHY)"
        else fact "n/a (binary log directory not resolved: @@log_bin_basename is ${BINLOG_BASE:-empty})"; fi
        missed binlog "binary log directory not resolved (@@log_bin_basename ${BINLOG_BASE:-unavailable}; mysql connection: $MYSQL_WHY)"
    elif [ -z "$LDIR" ]; then
        # Same-named files elsewhere on this host would be another server's.
        fact "n/a ($_BL_WHY)"
        if [ "$_BL_PRIV" = 1 ]; then missed binlog "$_BL_WHY$(_priv_hint)"
        else missed binlog "$_BL_WHY$_BL_ADVICE"; fi
    elif [ ! -r "$LDIR" ] || [ ! -x "$LDIR" ]; then
        fact "n/a (binary log directory $LDIR not readable by uid $(id -u 2>/dev/null || echo '?'))"
        missed binlog "run as uid $(id -u 2>/dev/null || echo '?'); $LDIR is $(stat -c '%U:%G %a' "$LDIR" 2>/dev/null || echo 'not readable') and not readable by this uid$(_priv_hint)"
    else
        fact "decoding the $BINLOG_FILES newest binary logs under $BINLOG_DIR ($_BL_VIA, $LDIR)"
        # "path<TAB>bytes", newest first. The newest files and their sizes are
        # the last rows of SHOW BINARY LOGS (section C). Their paths come from
        # @@log_bin_index when it is readable and lists the same names in the
        # same order (logs in more than one directory), else BINLOG_DIR/name.
        # A selected file that is not here, or a name listed twice with no
        # index to tell them apart, is named and blocks the goal. Only without
        # that list does one directory listing (by mtime) supply both.
        _bl_list=""; _bl_gap=""
        if [ -n "$_bl_rows" ]; then
            _bl_idx=""
            case "$BINLOG_INDEX" in /*) [ -f "$_BL_ROOT$BINLOG_INDEX" ] && [ -r "$_BL_ROOT$BINLOG_INDEX" ] && _bl_idx="$_BL_ROOT$BINLOG_INDEX" ;; esac
            # index entries are the server's paths: they get the same root
            _bl_sel="$(printf '%s\n' "$_bl_rows" | awk -v d="$LDIR" -v rt="$_BL_ROOT" -v dd="${DATADIR%/}" -v idx="$_bl_idx" -v n="$BINLOG_FILES" '
                NF { r++; name[r] = $1; size[r] = $2; cnt[$1]++ }
                END {
                    use = 0
                    if (idx != "") {
                        k = 0
                        while ((getline l < idx) > 0) if (l != "") p[++k] = l
                        use = (k == r)
                        for (i = 1; i <= k && use; i++) { b = p[i]; sub(/.*\//, "", b); if (b != name[i]) use = 0 }
                    }
                    for (i = r; i >= 1 && i > r - n; i--) {
                        if (use) {
                            q = p[i]
                            if (q !~ /^\//) { sub(/^\.\//, "", q); q = dd "/" q }
                            q = rt q
                            print "F\t" q "\t" size[i] "\t" (cnt[name[i]] > 1)
                        } else if (cnt[name[i]] > 1) print "D\t" name[i] "\t" cnt[name[i]]
                        else print "F\t" d "/" name[i] "\t" size[i] "\t0"
                    }
                }')"
            while IFS="$_tab" read -r _k _p _b _dup; do
                case "$_k" in
                    F) if [ -f "$_p" ]; then _bl_list="$_bl_list$_p$_tab$_b$_tab${_dup:-0}$_nl"
                       else
                           fact "skipped: ${_p##*/} (listed by SHOW BINARY LOGS; $_p is not a file on this host)"
                           _bl_gap="$_bl_gap${_bl_gap:+; }${_p##*/}: not a file at $_p on this host"
                       fi ;;
                    D) fact "skipped: $_p (SHOW BINARY LOGS lists it $_b times and @@log_bin_index ${BINLOG_INDEX:-?} is not readable here, so which file is meant is not known)"
                       _bl_gap="$_bl_gap${_bl_gap:+; }$_p: listed $_b times, no readable index to tell them apart" ;;
                esac
            done <<EOF
$_bl_sel
EOF
            _bl_src="SHOW BINARY LOGS"
        else
            _bl_list="$(_bounded ls -ltd --time-style=+%s -- "$LDIR"/*.[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null \
                | head -n "$BINLOG_FILES" \
                | awk '{ sz = $5; for (i = 1; i <= 6; i++) sub(/^[^ ]+ +/, ""); print $0 "\t" sz }')"
            _bl_src=""
        fi
        if [ -z "$_bl_list" ] && [ -n "$_bl_src" ]; then
            fact "n/a (none of the $BINLOG_FILES newest files SHOW BINARY LOGS lists could be read on this host)"
            missed binlog "none of the $BINLOG_FILES newest files SHOW BINARY LOGS lists was decoded: $_bl_gap"
        elif [ -z "$_bl_list" ]; then
            fact "n/a (no binary log files matched under $LDIR)"
            na binlog "$LDIR is readable and holds no <basename>.NNNNNN file"
        else
            _bl_ok=0
            _sum="$(_tmp binlog.sum)"
            while IFS= read -r _bl; do
                [ -n "$_bl" ] || continue
                # path<TAB>bytes[<TAB>1 when the name is listed more than once]
                _path="${_bl%%"$_tab"*}"; _bytes="${_bl#*"$_tab"}"; _dup=0
                case "$_bytes" in *"$_tab"*) _dup="${_bytes#*"$_tab"}"; _bytes="${_bytes%%"$_tab"*}" ;; esac
                _bl="${_path##*/}"
                # a name the index lists in two directories is told apart by its path
                if [ "$_dup" = 1 ]; then fact "file: $_path ($_bytes bytes)"
                else fact "file: $_bl ($_bytes bytes)"; fi
                # A decoded 1 GiB log is ~1.15 GiB: stream it once through awk,
                # never into a variable. The status read is the decoder's
                # (PIPESTATUS), not awk's.
                CMD_TIMEOUT="$BINLOG_TIMEOUT" _bounded mysqlbinlog --no-defaults \
                    --base64-output=DECODE-ROWS -v "$_path" 2>"$_errfile" | awk '
                    /^### INSERT INTO / { c["INSERT " $4]++; rows++; next }
                    /^### UPDATE /      { c["UPDATE " $3]++; rows++; next }
                    /^### DELETE FROM / { c["DELETE " $4]++; rows++; next }
                    # MySQL writes BEGIN; MariaDB writes START TRANSACTION
                    /^BEGIN/ || /^START TRANSACTION/ { begins++; next }
                    # Only the event header line, not the SET pseudo_thread_id it
                    # emits. MariaDB opens transactions with a GTID event instead,
                    # so this counts statement and DDL events, not transactions.
                    /^#[0-9]/ && /thread_id=/ { queries++ }
                    /^#[0-9][0-9][0-9][0-9][0-9][0-9] / {
                        if (first == "") first = $1 " " $2; last = $1 " " $2
                    }
                    END {
                        for (k in c) printf "T\t%d\t%s\n", c[k], k
                        printf "S\trows\t%d\n",    rows + 0
                        printf "S\tbegins\t%d\n",  begins + 0
                        printf "S\tqueries\t%d\n", queries + 0
                        printf "S\tfirst\t%s\n",   first
                        printf "S\tlast\t%s\n",    last
                    }' > "$_sum" 2>/dev/null
                _rc="${PIPESTATUS[0]}"
                if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 124 ]; then
                    _why="$(_classify_err)"
                    sub "n/a (mysqlbinlog exit $_rc: $_why)"
                    case "$_why" in *permission*) _why="$_why$(_priv_hint)" ;; esac
                    _bl_gap="$_bl_gap${_bl_gap:+; }$_bl: mysqlbinlog exit $_rc, $_why"
                    continue
                fi
                if [ "$_rc" -eq 124 ]; then
                    sub "decoding stopped at the ${BINLOG_TIMEOUT}s cap; the counts below cover the part decoded before it"
                    _bl_gap="$_bl_gap${_bl_gap:+; }$_bl: decode stopped at the ${BINLOG_TIMEOUT}s cap (partial)"
                else
                    _bl_ok=$((_bl_ok + 1))
                fi
                _rows="$(awk -F'\t' '$2=="rows"{print $3}' "$_sum")"
                if [ "${_rows:-0}" -eq 0 ]; then
                    sub "events per table: none (no row events decoded)"
                else
                    sub "events per table (count, table):"
                    awk -F'\t' '$1=="T"{printf "%12d %s\n", $2, $3}' "$_sum" \
                        | sort -rn | head -30 \
                        | while IFS= read -r _l; do printf '            %s\n' "$_l"; done
                fi
                sub "row events (count): ${_rows:-0}"
                sub "transactions (BEGIN count): $(awk -F'\t' '$2=="begins"{print $3}' "$_sum")"
                sub "statement and DDL events (Query, count): $(awk -F'\t' '$2=="queries"{print $3}' "$_sum")"
                sub "first event timestamp: $(awk -F'\t' '$2=="first"{print $3}' "$_sum")"
                sub "last event timestamp:  $(awk -F'\t' '$2=="last"{print $3}' "$_sum")"
            done <<EOF
$_bl_list
EOF
            rm -f "$_sum" 2>/dev/null
            [ -n "${_BL_INV_WHY:-}" ] && _bl_gap="$_bl_gap${_bl_gap:+; }SHOW BINARY LOGS: $_BL_INV_WHY"
            if [ -z "$_bl_gap" ] && [ "$_bl_ok" -gt 0 ]; then got binlog
            else missed binlog "${_bl_gap:-no file was decoded}"; fi
        fi
    fi

    section "J. Interval samples"
    if [ "$OPT_SAMPLE" != 1 ]; then
        fact "n/a (not requested: --sample not given)"
    else
        _ct="$CMD_TIMEOUT"; CMD_TIMEOUT=$(( SAMPLE_SEC * SAMPLE_COUNT + 30 ))
        probe "iostat -x" iostat -x "$SAMPLE_SEC" "$SAMPLE_COUNT"
        probe "vmstat" vmstat "$SAMPLE_SEC" "$SAMPLE_COUNT"
        CMD_TIMEOUT="$_ct"
    fi

    section "K. MySQL error log"
    ERRLOG="$(mysql_val "SELECT @@log_error" 2>/dev/null)"
    if [ -n "$ERRLOG" ] && [ -r "$ERRLOG" ]; then
        fact "log_error: $ERRLOG"
        probe "last 60 lines" tail -n 60 "$ERRLOG"
    else
        fact "log_error: ${ERRLOG:-n/a (not resolved)} (not readable from this host)"
        probe "journal (mysql/mariadb, last 60)" sh -c \
            "journalctl -u mysql -u mysqld -u mariadb -n 60 --no-pager 2>/dev/null"
    fi

    emit_status
    emit_footer
}

# ---- main -------------------------------------------------------------------
exec 3>&2
[ -n "$_CAP_BAD" ] && warn "ignored from the environment (not a whole number 1..999999 without leading zeros):$_CAP_BAD; the defaults are used"
[ "$OPT_NOSUDO" = 1 ] && warn "--no-sudo is no longer needed: the collector never elevates"

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_need_int() {
    case "$2" in ''|*[!0-9]*) warn "$1 takes a non-negative integer; got '$2'"; exit 2 ;; esac
}
_need_int --binlog "$BINLOG_FILES"
_need_int --sample "$SAMPLE_SEC"
[ "$BINLOG_FILES" -lt 1 ] && BINLOG_FILES=1
[ "$SAMPLE_SEC" -lt 1 ] && SAMPLE_SEC=1
# The decode is capped per file; the run deadline is raised to fit it and the
# samplers (iostat and vmstat run one after the other), unless the caller set one.
if [ -z "$_RUN_DEADLINE_ENV" ]; then
    [ "$OPT_BINLOG" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + BINLOG_FILES * BINLOG_TIMEOUT))
    [ "$OPT_SAMPLE" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + 2 * (SAMPLE_SEC * SAMPLE_COUNT + 30)))
fi

# The private directory first, because the client option file goes into it.
_run_init
_take_password
_load_password
_init_probe
_build_client_argv
_resolve_mysql
# An identity only. Whether the login worked is the status section's business.
TARGET="collection-server-mysql/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"

if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="$(hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="./$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    # Written as root when the operator ran it with sudo, so give it back to
    # them; otherwise they cannot move or delete their own report.
    if _report_to_file "$OUTFILE"; then
        [ -n "${SUDO_UID:-}" ] && [ "$(id -u 2>/dev/null || echo 0)" = 0 ] \
            && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$OUTFILE" 2>/dev/null
        progress "report written: $OUTFILE"
    else
        exit 1
    fi
fi
