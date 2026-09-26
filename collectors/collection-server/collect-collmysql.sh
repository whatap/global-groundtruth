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
# THE CONTRACT (../../CONTRACT.md):
#   1. Facts only. No emitted line states a conclusion.
#   2. Discover, never assume. Resolve datadir, log_bin_basename, the socket and
#      the replication role from the server itself, never from a hardcoded path.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned.
#
# Binary-log attribution (section E) is the reason this collector exists: it
# decodes binary logs with mysqlbinlog and counts events per table, so a reader
# can tell which table produces the volume instead of inferring it. That probe
# reads log files and is therefore opt-in (--binlog), not part of the default
# report.
#
# NOTE: no `set -e`. A collector must always reach its footer.
# -----------------------------------------------------------------------------

# bash only: arrays hold the client's arguments. Checked before any of them is
# parsed, so sh or dash stops here with a sentence instead of a syntax error.
[ -n "${BASH_VERSION:-}" ] || { echo "collect-collmysql.sh needs bash" >&2; exit 2; }

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
# ---- collector metadata -----------------------------------------------------
# 0.8.0  Never elevates itself and never re-runs itself: the operator runs it
#        with sudo when root is needed (a packaged MySQL that admits root over
#        the unix socket, a binary log directory only root reads), and the goal
#        that root would have obtained says so in its reason. --no-sudo is
#        accepted and warns that it is no longer needed. No credential on a
#        command line: a password in --mysql-args (-pX, --password=X and every
#        spelling the client takes as one) ends the run with exit 2; the
#        password comes from a bare -p (asked once on the terminal), MYSQL_PWD
#        or the operator's --defaults-file / --defaults-extra-file, and reaches
#        the client only through a mode-600 option file in the run's private
#        directory. Every wait is bounded: the -p prompt waits PROMPT_TIMEOUT
#        (60s) or what is left of RUN_DEADLINE, and restores the terminal on
#        Ctrl-C. External commands run bounded; the client argv is built word
#        by word. A refused SHOW BINARY LOGS is n/a with the error and blocks
#        the binlog goal; the binlog decode reads mysqlbinlog's own exit status
#        and a failed or capped decode is blocked; a NULL log_bin_basename is
#        unresolved, never the cwd; --sample raises the deadline by both
#        samplers. No local mysqld and no connection arguments is blocked.
#        Caps from the environment that are not whole numbers 1..999999 are
#        dropped with a warning. Needs bash, and says so under sh.
# 0.6.4  The report names the account. Section 0 says what the connection was
#        attempted with, which survives a refusal, and section A says which
#        grant row the server matched, which a refusal never reaches. On
#        2026-09-23 both reports said only "access denied" and nothing said
#        which account had been tried.
# 0.6.3  Section 0 states the host's boot time and uptime, read from /proc. The
#        kernel counters in section D are totals since boot, so a report without
#        it carries a sum with no denominator. It is deliberately not SQL: the
#        run that most needs the denominator is the one whose login failed, and
#        on 2026-09-23 it had to be asked for by hand afterwards.
# 0.6.2  The reason an elevation did not happen comes from sudo's own words.
#        0.6.1 chose between "no terminal" and "this account" by testing
#        /dev/tty, so an account that is not in sudoers was reported as a
#        missing terminal whenever the run had none, and the guide then sent
#        the operator to `ssh -t`, which changes nothing for that account.
#        Measured on debian bookworm with a real sudo: the two states are told
#        apart only by `sudo -v`, since `sudo -n true` answers "a password is
#        required" for both.
# 0.6.1  The elevation no longer decides for sudo whether it can ask. 0.6.0
#        gated the interactive attempt on `[ -t 0 ]`, so a run started as
#        `ssh host './collect-collmysql.sh ...'` skipped it without a word and
#        reported the same reason as an account sudo had actually refused. Now
#        sudo is always asked and answers for itself, and the four ways a run
#        can stay unelevated are four different reasons.
# 0.6.0  Runs itself under sudo when the account is allowed to. On a packaged
#        Ubuntu MySQL the root@localhost account authenticates by unix socket,
#        so an elevated run needs no credentials at all, and root also reads
#        the binary log directory that section I attributes events from. The
#        run continues unelevated when sudo is absent or refused, so a host
#        that forbids it still produces the host-side facts. --no-sudo opts out.
# 0.5.0  Collection status section + operator notice on stderr. Goals: mysql
#        login, host-side facts, and binary log attribution when --binlog is
#        given. The binlog n/a reason now separates "path not resolved" from
#        "path not readable" — they are answered by different things.
COLLECTOR_NAME="whatap-collmysql"
VERSION="0.8.0"
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

# ---- emit helpers -----------------------------------------------------------
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

# section "A. TITLE" -> the next numbered section; the letter is part of the
# title (output-format.md, "Fact sections")
section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}

fact() { printf '    %s\n' "$1"; }
sub()  { printf '        %s\n' "$1"; }

emit_footer() { printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'; }

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT="${CMD_TIMEOUT:-20}"
case "$CMD_TIMEOUT" in ''|*[!0-9]*) CMD_TIMEOUT=20 ;; esac
_init_probe() { _errfile="$(_tmp probe.err)"; }

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
# Where the time went. _bounded logs every call it makes or refuses, with its
# time in ms, and emit_status sums them per command when any call was slow
# (SLOW_SEC), capped or not run. A report that says "run deadline reached" used to
# leave the reader guessing which command ate the time (2026-09-25). Only the
# command's name and a subcommand word are kept, never its arguments, which
# can hold a path or a credential.
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
_load0=""         # _host_load at _run_init
SLOW_SEC=3        # a bounded call at least this long is named in the status
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

# _in_child=1 in the background jobs _bounded_in forks. They inherit the traps,
# and bash can deliver the watchdog's TERM before the job has reset them, so a
# killed watchdog ran this cleanup and removed the whole run's directory mid-run
# (found 2026-09-25: lost within 1 to 176 `_bounded true` calls under bash).
_in_child=0
_run_cleanup() {
    [ "$_in_child" = 1 ] && return 0
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
    _load0="$(_host_load)"
    # 16+ digits: a date that drops %N silently prints bare seconds (10 digits)
    [ -z "${EPOCHREALTIME:-}" ] && case "$(date +%s%N 2>/dev/null)" in *[!0-9]*|'') ;; ????????????????*) _ms_date=1 ;; esac
    _now_ms; _run_ms0="$_ms"
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

# _now_ms -> _ms, milliseconds since the epoch. A variable, not output: every
# bounded call is timed twice, and $(...) would fork each time. bash has
# EPOCHREALTIME (no fork); elsewhere date +%s%N when it gives nanoseconds
# (_ms_date=1, set in _run_init), else whole seconds. Timing in ms lets forty
# 0.3s calls add up to the 12s they took, which whole seconds counted as 0.
_ms_date=0
_run_ms0=0
_ms=0
_now_ms() {
    local t="${EPOCHREALTIME:-}" f
    if [ -n "$t" ]; then
        f="${t#*.}000"; f="${f%"${f#???}"}"
        _ms="${t%.*}$f"
    elif [ "$_ms_date" = 1 ]; then
        t="$(date +%s%N 2>/dev/null)"; _ms="${t%??????}"
    else
        _ms="$(date +%s 2>/dev/null || echo 0)000"
    fi
}

# _time_log MS KIND CMD ARGS... -> one line for emit_status: the command's name,
# and for a tool whose first word is a subcommand (kubectl get, zfs list) that
# word, after any --opt=value. Nothing else of the call, so no argument can
# carry a path or a secret into the report; a name with odd bytes is "?".
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

# _host_load -> one line on how busy the host is: load average, pressure stall
# (PSI) avg10 for cpu/io/memory, available memory, and the processes running
# and blocked on I/O. Read at the start and at the end of the run, so a slow or
# capped call in the status can be set against the load it ran under. Only
# /proc files, no command per process.
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

# _bounded CMD... -> CMD under the caps. Its stdin is the caller's when this
# script was run from a file, and /dev/null when the script itself is on stdin.
# _bounded_in FILE CMD... -> the same, with FILE as CMD's stdin. Use it, not a
# `< FILE` on the call, for any bounded command that needs input.
_bounded() { _bounded_in "" "$@"; }

_bounded_in() {
    local in="$1" t="${CMD_TIMEOUT:-20}" left rc p w d m0
    shift
    left=$((RUN_DEADLINE - $(_elapsed)))
    [ "$left" -le 0 ] && { _time_log 0 "not run" "$@"; return 124; }
    _now_ms; m0="$_ms"
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
        _in_child=1
        set -m 2>/dev/null
        if [ -n "$in" ];                   then "$@" < "$in" &
        elif [ "$_stdin_script" = 1 ];     then "$@" < /dev/null &
        else                                    { "$@" 0<&4 4<&- & } 4<&0; fi
        p=$!
        set +m 2>/dev/null
        ( i=0
          # sleep in the background and wait: a TERM then ends the watchdog at
          # once, where dash let a foreground sleep finish (60-280ms a call)
          while [ "$i" -lt "$t" ]; do sleep 1 & wait $!; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        _in_child=0
        wait "$p"; rc=$?
        kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
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

# _emit_time -> the run time; and when a call was slow (SLOW_SEC), capped or not
# run, the host load at the start and the end of the run and where the time
# went: every bounded call summed per command, largest first, with how many
# were capped, and the time spent outside them. A "run deadline reached" can
# then be read against the load and the facts above it.
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
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null; }

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
    _past_deadline && { fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"; return; }
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
# arguments were given. _mysql_ok records once whether the client can connect,
# so every later section states a reason instead of failing silently.
MYSQL_BIN=""
MYSQL_OK=0
MYSQL_WHY="not attempted"

# ---- credentials (this collector only) ---------------------------------------
# No credential on a command line (a child's argv is world-readable in ps and
# /proc/<pid>/cmdline) and none in a child's environment. The client gets the
# password from a mode-600 option file in the run's private directory, and only
# that file's path is on its command line. Where the password may come from:
#   a bare -p / --password in --mysql-args: asked once, on the terminal;
#   MYSQL_PWD: read, then unset before any child starts;
#   the operator's --defaults-file / --defaults-extra-file.
# A password written into --mysql-args is on this collector's own command line
# already; the collector refuses it rather than hand it on.
_PW=""; _PW_SRC=""; _PW_WHY=""; CNF=""

# _pw_opt NAME -> what the mysql client does with a long option NAME (without
# =VALUE), as measured on the 5.6, 5.7.32, 8.0.46 and 8.4.10 clients
# (2026-09-25):
#   "pw"   the value is the password: --password, --password1..3 (8.0.27+),
#          a unique prefix of password (--pas .. --passwor; 5.6 accepts those,
#          5.7 and 8.x reject them), after any run of the prefixes loose-,
#          maximum-, skip-, enable-, disable- whose last one is loose- or
#          maximum- (8.0.46 logs in with --skip-loose-password=X and
#          --enable-loose-password=X);
#   "drop" the same names whose last prefix is skip-/enable-/disable-
#          (--skip-password=X, --loose-enable-password=X: the client does not
#          use the value), and any other name that spells password;
#   ""     anything else.
# "_" and "-" are the same character in an option name (--loose_password). The
# set is the union over those clients, so a spelling one of them takes as a
# password never stays on a command line; the price is that --pass=X logs in
# where an 8.x client would have refused the option.
_pw_opt() {
    local n="${1#--}" pre last=""
    n="$(printf '%s' "$n" | tr '_' '-')"
    while :; do
        pre="${n%%-*}"
        case "$pre" in loose|maximum|skip|enable|disable) last="$pre"; n="${n#*-}" ;; *) break ;; esac
        [ -n "$n" ] || break
    done
    case "$n" in
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
    local w out="" prompt=0 inargs=""
    set -f
    for w in $MYSQL_ARGS; do
        case "$w" in
            --*=*) [ -n "$(_pw_opt "${w%%=*}")" ] && { inargs="${w%%=*}=..."; continue; } ;;
            --*)   case "$(_pw_opt "$w")" in pw) prompt=1; continue ;; drop) continue ;; esac ;;
            -?*)   # A cluster of short options (-BpX, -Np): p takes the rest of
                   # the word as the password, unless an option that takes an
                   # argument (-u, -h, -P, -D, -S, -e, -R, -#) came first.
                   if _short_pw "$w"; then
                       if [ -n "$_SP_PW" ]; then inargs="${_SP_KEPT:--}p..."; continue; fi
                       prompt=1; [ -n "$_SP_KEPT" ] && out="$out${out:+ }$_SP_KEPT"; continue
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
    elif [ -n "$_PW" ]; then _PW_SRC="terminal prompt"; fi
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

# sql "label" "SQL" -> rows as facts, or a classified reason
sql() {
    local label="$1" q="$2" out rc
    if [ "$MYSQL_OK" != 1 ]; then fact "$label: n/a ($MYSQL_WHY)"; return; fi
    out="$(mysql_q "$q")"; rc=$?
    [ "$rc" -eq 124 ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: none"; return; }
    _emit_labeled "$label" "$out"
}

sqlv() {
    local label="$1" q="$2" out rc
    if [ "$MYSQL_OK" != 1 ]; then fact "$label: n/a ($MYSQL_WHY)"; return; fi
    out="$(mysql_vertical "$q")"; rc=$?
    [ "$rc" -eq 124 ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
    [ -z "$out" ] && { fact "$label: none"; return; }
    _emit_labeled "$label" "$out"
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
    mysql_q "SELECT 1" >/dev/null 2>&1
    case "$?" in
        0)   MYSQL_OK=1; MYSQL_WHY="ok" ;;
        124) if _past_deadline; then MYSQL_WHY="run deadline reached (${RUN_DEADLINE}s) before the login"
             else MYSQL_WHY="timed out: ${CMD_TIMEOUT}s"; fi ;;
        *)   MYSQL_WHY="$(_classify_err)" ;;
    esac
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
    # What the connection was attempted WITH. Section A reports what the server
    # matched, but only a successful login reaches section A, and a refused one
    # is exactly when the question is asked. With no arguments the client takes
    # the account name from the OS uid and goes over the unix socket, so a run
    # started with sudo attempts root@localhost without anything being passed.
    # The password itself is never printed: it is not report content but a
    # credential this run was handed. Where it came from is printed.
    if [ -n "$DEFAULTS_FILE$EXTRA_FILE" ] || [ -n "$MYSQL_ARGS" ]; then
        fact "connection attempted with:${DEFAULTS_FILE:+ --defaults-file=$DEFAULTS_FILE}${EXTRA_FILE:+ --defaults-extra-file=$EXTRA_FILE}${MYSQL_ARGS:+ $MYSQL_ARGS}"
    else
        fact "connection attempted with: no arguments (client defaults: account from uid $(id -u 2>/dev/null || echo '?') = $(id -un 2>/dev/null || echo unknown), unix socket)"
    fi
    if [ -n "$CNF" ]; then fact "password: from $_PW_SRC, handed to the client in a mode-600 option file"
    elif [ -n "$_PW_WHY" ]; then fact "password: n/a ($_PW_WHY)"
    else fact "password: none given to this collector"; fi
    fact "mysql connection: $MYSQL_WHY"
    if [ "$MYSQL_OK" = 1 ]; then got login
    elif [ -z "$MYSQL_BIN" ]; then missed login "command not found: mysql or mariadb client"
    elif [ -n "$_PW_WHY" ]; then missed login "$MYSQL_WHY; $_PW_WHY"
    elif [ -z "$MYSQL_ARGS" ] && [ -z "$DEFAULTS_FILE$EXTRA_FILE" ] \
         && ! (_bounded ps -eo args 2>/dev/null | grep -qE "[m]ysqld|[m]ariadbd"); then
        # The backend's MySQL is often on another host. No local server and no
        # connection arguments is therefore a run that asked nowhere, not an
        # answer: --mysql-args would obtain it.
        missed login "no local mysqld found and no --mysql-args given (client without arguments: $MYSQL_WHY)"
    else missed login "$MYSQL_WHY$(_priv_hint)"; fi
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
    sql "server_uuid"    "SELECT @@server_uuid"
    sql "uptime(s)"      "SHOW GLOBAL STATUS LIKE 'Uptime'"
    # super_read_only arrived in 5.7; asking for both in one row loses read_only
    # on 5.6 and on MariaDB.
    sql "read_only"      "SELECT @@read_only"
    sql "super_read_only" "SELECT @@super_read_only"
    sql "port / socket"  "SELECT @@port, @@socket"
    sql "datadir"        "SELECT @@datadir"
    # pgrep -f would match this collector's own timeout wrapper, so filter the
    # process table instead and drop the matcher processes themselves.
    # `; true` would turn a missing ps into "empty output", which reads as
    # "no mysqld here". Fail loudly when the tool is absent; stay silent-but-
    # zero when the tool ran and simply matched nothing.
    probe "local mysqld process" sh -c \
        "command -v ps >/dev/null || { echo 'command not found: ps' >&2; exit 3; }; \
         ps -eo pid,user,args 2>/dev/null | grep -E '[m]ysqld|[m]ariadbd' | grep -v timeout; true"
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
    # 8.4 removed SHOW MASTER STATUS; 5.7/8.0 do not know SHOW BINARY LOG
    # STATUS. Ask both so one of them always answers with the binlog position.
    sqlv "binary log status"   "SHOW BINARY LOG STATUS"
    sqlv "source status"       "SHOW MASTER STATUS"
    sql  "connected replicas"  "SHOW REPLICAS"
    sql  "connected slaves"    "SHOW SLAVE HOSTS"
    sql  "galera wsrep"        "SHOW STATUS LIKE 'wsrep_cluster_size'"
    # MEMBER_ROLE arrived in 8.0; naming it breaks the whole row on 5.7.
    sql  "group replication"   "SELECT MEMBER_HOST, MEMBER_STATE FROM performance_schema.replication_group_members"
    sql  "semi-sync"           "SHOW STATUS LIKE 'Rpl_semi_sync%_status'"

    section "C. Binary log inventory and retention"
    sql "log_bin"                     "SELECT @@log_bin"
    sql "log_bin_basename"            "SELECT @@log_bin_basename"
    sql "log_bin_index"               "SELECT @@log_bin_index"
    sql "max_binlog_size"             "SELECT @@max_binlog_size"
    sql "binlog_expire_logs_seconds"  "SHOW VARIABLES LIKE 'binlog_expire_logs_seconds'"
    sql "expire_logs_days"            "SHOW VARIABLES LIKE 'expire_logs_days'"
    sql "binlog_row_image"            "SHOW VARIABLES LIKE 'binlog_row_image'"
    sql "binlog_rows_query_log_events" "SHOW VARIABLES LIKE 'binlog_rows_query_log_events'"
    sql "sync_binlog"                 "SELECT @@sync_binlog"
    # A host whose binary logs accumulate can hold thousands of files, and the
    # full listing would be the whole report. Report the inventory as totals
    # plus both ends; section I attributes the content.
    if [ "$MYSQL_OK" != 1 ]; then
        fact "binary logs: n/a ($MYSQL_WHY)"
    else
        # A refusal is not an empty list: without REPLICATION CLIENT the server
        # answers ERROR 1227, which used to read as "binary logs: none".
        _BL_INV_WHY=""
        _bl_rows="$(mysql_q "SHOW BINARY LOGS")"; _bl_rc=$?
        if [ "$_bl_rc" -ne 0 ]; then
            if [ "$_bl_rc" -eq 124 ]; then _BL_INV_WHY="timed out: ${CMD_TIMEOUT}s"
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

    # Growth rate is measured from file mtimes, so it needs no second sample.
    # NULL (log_bin off, or a server that does not report it) and a bare file
    # name both leave no directory: dirname would answer ".", the cwd of this
    # run, and that is not where the server writes.
    BINLOG_DIR=""
    LOG_BIN="$(mysql_val "SELECT @@log_bin" 2>/dev/null)"
    BINLOG_BASE="$(mysql_val "SELECT @@log_bin_basename" 2>/dev/null)"
    case "$BINLOG_BASE" in
        /*) BINLOG_DIR="$(dirname "$BINLOG_BASE" 2>/dev/null)" ;;
    esac
    if [ -n "$BINLOG_DIR" ] && [ -d "$BINLOG_DIR" ] && [ -r "$BINLOG_DIR" ]; then
        fact "binlog directory: $BINLOG_DIR"
        # The server-supplied path is an argument, never part of the script text.
        probe "newest binlog files (mtime, bytes)" sh -c \
            'ls -l --time-style=+%Y-%m-%dT%H:%M:%SZ "$1" 2>/dev/null | grep -E "\.[0-9]{6}\$" | tail -20' sh "$BINLOG_DIR"
        probe "binlog total bytes" sh -c 'du -sb "$1" 2>/dev/null | cut -f1' sh "$BINLOG_DIR"
    elif [ -n "$BINLOG_DIR" ]; then
        fact "binlog directory: $BINLOG_DIR (not readable by uid $(id -u 2>/dev/null || echo '?'))"
    else
        if [ "$MYSQL_OK" != 1 ]; then fact "binlog directory: n/a (not queried: $MYSQL_WHY)"
        else fact "binlog directory: n/a (@@log_bin_basename is not an absolute path: ${BINLOG_BASE:-empty})"; fi
    fi

    section "D. Storage and I/O"
    probe "df -hT" df -hT
    probe "mount points" sh -c "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || mount"
    DATADIR="$(mysql_val "SELECT @@datadir" 2>/dev/null)"
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
    # The goal is declared only when --binlog was given, and resolved once,
    # after every file: obtained only when every selected file was decoded to
    # its end. A decode that failed (mysqlbinlog could not open a file, Errcode
    # 13) or stopped at the cap is a gap, however many counters it printed.
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
    elif [ ! -r "$BINLOG_DIR" ] || [ ! -x "$BINLOG_DIR" ]; then
        fact "n/a (binary log directory $BINLOG_DIR not readable by uid $(id -u 2>/dev/null || echo '?'))"
        missed binlog "run as uid $(id -u 2>/dev/null || echo '?'); $BINLOG_DIR is $(stat -c '%U:%G %a' "$BINLOG_DIR" 2>/dev/null || echo 'not readable') and not readable by this uid$(_priv_hint)"
    else
        fact "decoding the $BINLOG_FILES newest binary logs under $BINLOG_DIR"
        _bl_list="$(ls -1td -- "$BINLOG_DIR"/*.[0-9][0-9][0-9][0-9][0-9][0-9] 2>/dev/null | head -n "$BINLOG_FILES")"
        if [ -z "$_bl_list" ]; then
            fact "n/a (no binary log files matched under $BINLOG_DIR)"
            na binlog "$BINLOG_DIR is readable and holds no <basename>.NNNNNN file"
        else
            _bl_ok=0; _bl_gap=""
            _sum="$(_tmp binlog.sum)"
            while IFS= read -r _bl; do
                [ -n "$_bl" ] || continue
                _path="$_bl"; _bl="${_bl##*/}"
                _bytes="$(ls -l "$_path" 2>/dev/null | awk '{print $5}')"
                fact "file: $_bl ($_bytes bytes)"
                # A production binary log is max_binlog_size (1 GiB by default),
                # and decoded row events run about 1.15x that. Holding it in a
                # shell variable and walking it six times costs gigabytes of RSS
                # on a host that is already short of I/O, so stream it once
                # through awk and keep only the counters. The decoder's own exit
                # status is the one read (PIPESTATUS), not awk's: awk always
                # succeeds and always prints its END block.
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
_end_probe
