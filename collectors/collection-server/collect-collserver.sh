#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collection-server collector
# -----------------------------------------------------------------------------
# Gathers facts about a WhaTap backend host (yard/proxy/gateway/keeper/account/
# notihub/eureka/front/...) so a remote developer does not have to ask the field
# engineer twenty questions. Emits the shared report shape (docs/output-format.md)
# to a single .txt file; with --bundle it also archives real logs, configs and
# host snapshots as a tar.gz.
#
# Tier 0 (the default report) never pauses a JVM (jstack/jmap), walks a large
# tree (recursive du) or reads whole rotated logs; those are opt-in.
#
# Rules: ../../CONTRACT.md and ../../docs/collector-engineering.md. No `set -e`:
# the report always reaches its footer.
# -----------------------------------------------------------------------------

# bash only (arrays for the discovered JVMs). Checked first, so sh or dash
# stops with a sentence instead of a syntax error.
[ -n "${BASH_VERSION:-}" ] || { echo "collect-collserver.sh needs bash" >&2; exit 2; }

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
# 0.9.2  Readability refactor; report unchanged.
# 0.9.1  No *.hprof found is "none", not "n/a (empty output)", and only when
#        every directory searched could be listed (a symlink this uid cannot
#        follow is not absent; a missing home is "path not found", a dangling
#        symlink says so); otherwise n/a with the uid, also next to dumps
#        found elsewhere. A process counts as a whatap module only when it is
#        java and names a server/opslake jar or the yard boot class.
# 0.9.0  An absence is `na` only when every input behind it was read (conf/,
#        logs/, hidepid, cmdlines, the process scan, a JVM whose home was not
#        found, unit files, install paths). WHATAP_HOME is also found from a
#        JVM's cwd, $WHATAP_HOME and common install paths. Every external
#        command is bounded (a hung systemctl is asked once); discovery is one
#        grep over /proc and one `systemctl show`. The bundle is built in the
#        private directory; bad numeric options exit 2, a failed write exits 1;
#        output is handed back under sudo. Needs bash.
COLLECTOR_NAME="whatap-collserver"
VERSION="0.9.2"
DOMAIN="collection-server"
TARGET="collection-server/$(hostname 2>/dev/null || echo unknown)"   # refined after WHATAP_HOME is resolved

# ---- options ----------------------------------------------------------------
OPT_BUNDLE=0
OPT_FILE=0           # write the Tier 0 report to a .txt file
OPT_STDOUT=0
OPT_QUIET=0          # suppress progress narration on stderr
OPT_HOME=""
OPT_OUT="."
OPT_HOURS=24
OPT_MAXLOG_MB=5      # bundle: per-file log copy cap (tail keeps the newest end)
OPT_MAXTOTAL_MB=100  # bundle: cap on ALL copied logs together
OPT_ROTATED=0        # bundle: copy rotated logs too (opt-in)
OPT_LOG_DAYS=14      # bundle: with --with-rotated, only from the last N days
OPT_THREADS=0        # Tier 2: jstack iterations (0 = off)
OPT_HISTO=0          # Tier 2: jmap -histo (no :live)
OPT_HEAP=0           # Tier 2: full heap dump
OPT_DU=0             # Tier 2: recursive du of yardbase
OPT_TIMEREF=0        # Tier 2: compare clock to an external time source (network call)
TIMEREF_SERVER="pool.ntp.org"
# RUN_DEADLINE as the caller gave it (empty when not given), read before the run
# helpers default it: a Tier 2 heap dump or thread dump needs more than the
# default, and an explicit value from the caller wins over that.
_RUN_DEADLINE_ENV="${RUN_DEADLINE:-}"

usage() {
    cat <<'EOF'
Run on the collection-server host. Produces one facts .txt or a tar.gz.
Run with no arguments (or --help) to print this help — a collection needs an
explicit action flag (--file / --stdout / --bundle) so nothing starts by accident.

  collect-collserver.sh                          print this help (no collection)
  collect-collserver.sh --file                   Tier 0 facts report -> one .txt file
  collect-collserver.sh --stdout                 print the report to stdout instead of a file
  collect-collserver.sh --bundle                 Tier 0 report + Tier 1 artifacts -> tar.gz
  collect-collserver.sh --quiet ...              silence progress on stderr (for automation)
  collect-collserver.sh --home DIR               force WHATAP_HOME (else auto-resolved)
  collect-collserver.sh --out DIR                output directory (default: .)
  collect-collserver.sh --bundle --hours N       journal window for the bundle (default: 24)
  collect-collserver.sh --bundle --max-log-mb M    per-file log copy cap (default: 5)
  collect-collserver.sh --bundle --max-total-mb M  cap on all copied logs together (default: 100)
  collect-collserver.sh --bundle --with-rotated    also copy rotated logs (default: current logs only)
  collect-collserver.sh --bundle --log-days N      with --with-rotated, only the last N days (default: 14)

  Logs are the whole size of a bundle on a busy collection server. Current logs
  are always copied; rotated ones are opt-in. Whatever is left out is listed,
  with the reason, in logs/SELECTION.txt and summarized in the report.

  Tier 2 (opt-in, may add load — printed to stderr before running):
  collect-collserver.sh --bundle --threads[=N]   jstack -l each JVM N times (default N=1)
  collect-collserver.sh --bundle --histo         jmap -histo (NOT :live, no full GC)
  collect-collserver.sh --bundle --heap          full heap dump (large, pauses the JVM)
  collect-collserver.sh --bundle --du            recursive du of yardbase (data-disk I/O)
  collect-collserver.sh --file --time-ref[=SRV]  also compare the clock to an external NTP/
                                      HTTP source (network call; clock not set)
EOF
}

ARGC=$#              # 0 args -> usage (handled in main, below)
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) OPT_BUNDLE=1 ;;
        --file) OPT_FILE=1 ;;
        --stdout) OPT_STDOUT=1 ;;
        --quiet) OPT_QUIET=1 ;;
        --home) OPT_HOME="$2"; shift ;;
        --home=*) OPT_HOME="${1#*=}" ;;
        --out) OPT_OUT="$2"; shift ;;
        --out=*) OPT_OUT="${1#*=}" ;;
        --hours) OPT_HOURS="$2"; shift ;;
        --hours=*) OPT_HOURS="${1#*=}" ;;
        --max-log-mb) OPT_MAXLOG_MB="$2"; shift ;;
        --max-log-mb=*) OPT_MAXLOG_MB="${1#*=}" ;;
        --max-total-mb) OPT_MAXTOTAL_MB="$2"; shift ;;
        --max-total-mb=*) OPT_MAXTOTAL_MB="${1#*=}" ;;
        --with-rotated) OPT_ROTATED=1 ;;
        --log-days) OPT_LOG_DAYS="$2"; shift ;;
        --log-days=*) OPT_LOG_DAYS="${1#*=}" ;;
        --threads) OPT_THREADS=1 ;;
        --threads=*) OPT_THREADS="${1#*=}" ;;
        --histo) OPT_HISTO=1 ;;
        --heap) OPT_HEAP=1 ;;
        --du) OPT_DU=1 ;;
        --time-ref) OPT_TIMEREF=1 ;;
        --time-ref=*) OPT_TIMEREF=1; TIMEREF_SERVER="${1#*=}" ;;
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

# ---- reasoned-absence helpers (see docs/collector-engineering.md) -----------
_errfile=""
_init_probe() { _errfile="$(_tmp probe.err)"; }

_classify_err() {
    # reads a stderr file, prints a short classified reason
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *[Pp]"ermission denied"*|*"peration not permitted"*|*"peration not supported"*)
            echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*|*"o such device"*)
            echo "path not found"; return ;;
    esac
    if [ -n "$txt" ]; then
        printf 'error: %s' "$(printf '%s' "$txt" | head -n1 | cut -c1-100)"
    else
        echo "nonzero exit"
    fi
}

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

_emit_labeled() {
    # $1 label ; $2 body (may be multi-line)
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then
        fact "$label: $body"
    else
        fact "$label:"
        printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
    fi
}

# probe "label" CMD [ARGS...] -> emits output as facts, or "label: n/a (<why>)".
# Every call goes through _bounded (run helpers), so a hung command costs at
# most CMD_TIMEOUT and the run still reaches its footer. A non-zero exit that
# still printed something is reported with its output and exit code.
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
    if [ "$rc" -ne 0 ]; then
        [ -n "$out" ] && { _emit_labeled "$label (exit $rc)" "$out"; return; }
        fact "$label: n/a ($(_classify_err))"; return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# probe_merged: like probe but folds stderr into stdout (for tools that print to
# stderr, e.g. `java -version`).
probe_merged() {
    local label="$1"; shift
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    local out rc
    out="$(_bounded "$@" 2>&1)"; rc=$?
    [ "$rc" -eq 124 ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# read_proc "label" PATH -> emits a /proc or /sys file's content with a reason.
read_proc() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then fact "$label: n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "$label: n/a (permission denied: $path)"; return; fi
    local out; out="$(cat "$path" 2>"$_errfile")"
    if [ -z "$out" ]; then fact "$label: n/a (empty output)"; return; fi
    _emit_labeled "$label" "$out"
}

# dump_file PATH -> emits a file's full content (bounded), or a reason.
dump_file() {
    local path="$1" cap="${2:-4000}"
    if [ ! -e "$path" ]; then fact "n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "n/a (permission denied: $path)"; return; fi
    if [ ! -s "$path" ]; then fact "(empty file)"; return; fi
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# ---- portable helpers -------------------------------------------------------
# cmdline_of PID -> sets _CL to the process's argv joined by spaces (the bytes
# `tr '\0' ' '` gives), with builtins only: no fork per process.
_CL=""
cmdline_of() {
    local a=""
    _CL=""
    while IFS= read -r -d '' a; do _CL="$_CL$a "; done < "/proc/$1/cmdline" 2>/dev/null
    _CL="$_CL$a"
}

# _whatap_cmdlines -> /proc/<pid>/cmdline paths that name a whatap module, in
# /proc order. One bounded grep over every entry instead of a read per process,
# fed through xargs so a host with tens of thousands of processes does not hit
# ARG_MAX. Its exit status is kept: grep answers 0 (match) or 1 (none), and 2
# when a process vanished mid-scan, which xargs reports as 123; anything else
# (a cap, a failed exec) means the table was not read, and says so.
CMDLINE_SCAN_WHY=""
_whatap_cmdlines() {
    # The list goes through a file and _bounded_in, not a pipe into _bounded:
    # with the script on stdin (bash -s), _bounded gives its command /dev/null
    # as stdin, and a piped list would arrive empty and read as "no JVM".
    local lst; lst="$(_tmp cmdlines.lst)"
    if have xargs && [ "$lst" != /dev/null ] && printf '%s\0' /proc/[0-9]*/cmdline > "$lst" 2>/dev/null; then
        _bounded_in "$lst" xargs -0 grep -lsE 'whatap\.server\.|whatap\.opslake\.|\.yard\.boot'
    else
        # No xargs or no private directory: the paths as arguments (bounded by ARG_MAX).
        _bounded grep -lsE 'whatap\.server\.|whatap\.opslake\.|\.yard\.boot' /proc/[0-9]*/cmdline
    fi
}
_scan_cmdlines() {
    local rc
    _SCAN_OUT="$(_whatap_cmdlines)"; rc=$?
    case "$rc" in
        0|1|2|123) CMDLINE_SCAN_WHY="" ;;
        124) CMDLINE_SCAN_WHY="the /proc/<pid>/cmdline scan did not finish within ${CMD_TIMEOUT}s" ;;
        *)   CMDLINE_SCAN_WHY="the /proc/<pid>/cmdline scan failed (xargs/grep exit $rc)" ;;
    esac
}

get_listen_ports() {
    if have ss; then
        _bounded ss -ltn 2>/dev/null | awk 'NR>1{n=split($4,a,":"); print a[n]}'
    elif have netstat; then
        _bounded netstat -ltn 2>/dev/null | awk '/^tcp/{n=split($4,a,":"); print a[n]}'
    else
        # /proc/net/tcp{,6}: state 0A == LISTEN; local port is hex after ':'
        awk '$4=="0A"{split($2,a,":"); print a[2]}' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
            | while IFS= read -r h; do [ -n "$h" ] && printf '%d\n' "$((16#$h))"; done
    fi
}

fstype_of() {
    local p="$1"
    if have findmnt; then _bounded findmnt -no FSTYPE -T "$p" 2>/dev/null && return; fi
    if have stat; then _bounded stat -f -c '%T' "$p" 2>/dev/null && return; fi
    echo ""
}

source_of() {
    local p="$1"
    have findmnt && _bounded findmnt -no SOURCE -T "$p" 2>/dev/null
}

# systemd helpers — avoid `--value` (unsupported on systemd <230 / Ubuntu 16.04).
# Bounded: systemctl waits on D-Bus, and a wedged systemd would hang every call.
# Fail fast: once one systemctl call hits the cap, the rest are skipped rather
# than each costing CMD_TIMEOUT again. The mark is a file in the run's private
# directory because most calls run inside $(...), where a variable would not
# survive.
_sd() {
    local mark="" rc
    [ -n "$_tmp_dir" ] && mark="$_tmp_dir/systemctl.hung"
    [ -n "$mark" ] && [ -e "$mark" ] && return 124
    _bounded systemctl "$@" 2>/dev/null; rc=$?
    if [ "$rc" -eq 124 ] && [ -n "$mark" ]; then
        : > "$mark"
        warn "systemctl did not answer within ${CMD_TIMEOUT}s; further systemctl calls are skipped"
    fi
    return "$rc"
}

# One `systemctl show` for every unit this run asks about, not one per question.
# It prints one block per unit (blank-line separated, properties in systemd's
# order); each block is filed under its Id. sd_show answers from here and asks
# systemctl only for a unit that was not prefetched.
_SD_CACHE=""   # lines: <unit><TAB><Prop>=<value>
_SD_KNOWN=" "  # units the prefetch answered for
_sd_prefetch() {
    have systemctl || return 0
    local out line id="" blk=""
    out="$(_sd show -p Id -p LoadState -p WorkingDirectory -p NRestarts "$@")"
    [ -n "$out" ] || return 0
    # A trailing blank line closes the last block.
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            case "$line" in Id=*) id="${line#Id=}" ;; esac
            blk="$blk$line$_nl"
            continue
        fi
        if [ -n "$id" ]; then
            _SD_KNOWN="$_SD_KNOWN$id "
            while IFS= read -r line; do
                [ -n "$line" ] && _SD_CACHE="$_SD_CACHE$id$_tab$line$_nl"
            done <<EOB
$blk
EOB
        fi
        id=""; blk=""
    done <<EOF
$out

EOF
}
# _sd_cached PROP UNIT -> the prefetched value; false when UNIT was not prefetched
_sd_cached() {
    case "$_SD_KNOWN" in *" $2 "*) ;; *) return 1 ;; esac
    local l
    while IFS= read -r l; do
        case "$l" in "$2$_tab$1="*) printf '%s\n' "${l#*=}"; return 0 ;; esac
    done <<EOF
$_SD_CACHE
EOF
    return 0
}
sd_show() {
    have systemctl || return 0
    _sd_cached "$1" "$2.service" && return 0
    _sd show -p "$1" "$2.service" | cut -d= -f2-
}
unit_loaded() { [ "$(sd_show LoadState "$1")" = "loaded" ]; }
sd_state() { _sd "$1" "$2.service"; }

WHATAP_UNITS="yard proxy gateway keeper account notihub eureka front router billing crane flexreport"

# Places a WhaTap backend is commonly unpacked to. They are only READ: a
# candidate becomes WHATAP_HOME when it holds a module config or a server jar,
# and an unreadable one keeps "not installed here" from being concluded.
WHATAP_HOME_CANDIDATES="/whatap /data/whatap /opt/whatap /app/whatap /home/whatap /usr/local/whatap /whatap/server /data/whatap/server"

# _dir_ok DIR -> true when this uid can list DIR (read + search)
_dir_ok() { [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ]; }

# _path_state P -> ok (listable), absent (the nearest existing ancestor was
# searched and P is not there), notdir, dangling:TARGET, or unlistable
_path_state() {
    local p="$1" a t
    _dir_ok "$p" && { printf ok; return; }
    if [ -e "$p" ]; then [ -d "$p" ] && printf unlistable || printf notdir; return; fi
    if [ -L "$p" ]; then
        t="$(readlink "$p")"; a="$t"
        case "$a" in /*) ;; *) a="$(dirname "$p")/$a" ;; esac
        a="$(dirname "$a")"
        if [ -d "$a" ] && [ -x "$a" ]; then printf 'dangling:%s' "$t"; else printf unlistable; fi
        return
    fi
    a="$(dirname "$p")"
    while [ ! -e "$a" ] && [ "$a" != / ] && [ "$a" != . ]; do a="$(dirname "$a")"; done
    if [ -x "$a" ]; then printf absent; else printf unlistable; fi
}

# _looks_like_home DIR -> true when DIR holds a module config or a server jar
_looks_like_home() {
    local d="$1" u f
    for u in $WHATAP_UNITS; do [ -f "$d/conf/$u.conf" ] && return 0; done
    for f in "$d"/lib/whatap.server.*.jar "$d"/lib/whatap.opslake.*.jar "$d"/*.yard.boot*; do
        [ -e "$f" ] && return 0
    done
    return 1
}

# ---- discovery (run once) ---------------------------------------------------
# PIDS[] and MODS[] are parallel indexed arrays of discovered whatap JVMs.
# _is_whatap_server PID CMDLINE -> true for a java process that runs a WhaTap
# backend module: a whatap.server.*.jar / whatap.opslake.*.jar on its command
# line, or the yard boot class. "whatap.server." alone is not enough: the
# WhaTap Java agent passes -Dwhatap.server.host=..., and `tail -f
# whatap.server.log` names it too.
_is_whatap_server() {
    [[ "$2" =~ whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar || "$2" =~ [A-Za-z0-9_]\.yard\.boot ]] || return 1
    local comm="" a0="${2%% *}"
    IFS= read -r comm < "/proc/$1/comm" 2>/dev/null
    [ "$comm" = java ] || [ "${a0##*/}" = java ]
}

PROC_SEEN=0          # /proc/<pid> entries looked at
PROC_UNREAD=0        # of those, cmdline not readable by this uid
discover_services() {
    PIDS=(); MODS=()
    local d pid cl mod
    # Accounting first, with builtins only: how many entries there were, and
    # how many this uid could not read (the absence rule needs both).
    for d in /proc/[0-9]*; do
        [ -d "$d" ] || continue
        PROC_SEEN=$((PROC_SEEN + 1))
        # A process that exited during the scan is gone, not unreadable.
        if [ ! -r "$d/cmdline" ]; then
            if [ -d "$d" ]; then PROC_UNREAD=$((PROC_UNREAD + 1)); else PROC_SEEN=$((PROC_SEEN - 1)); fi
        fi
    done
    local f
    _scan_cmdlines
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        d="${f%/cmdline}"
        cmdline_of "${d#/proc/}"; cl="$_CL"
        _is_whatap_server "${d#/proc/}" "$cl" || continue
        pid="${d#/proc/}"
        # The module name comes from the jar, not the first whatap.server.*
        # token: "-Dwhatap.server.home=" would win every time.
        if [[ "$cl" =~ whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar ]]; then
            mod=""; [[ "${BASH_REMATCH[0]}" =~ whatap\.(server|opslake)\.[a-zA-Z0-9]+ ]] && mod="${BASH_REMATCH[0]}"
        else
            mod="$(printf '%s\n' "$cl" | tr ' ' '\n' | grep -oE 'whatap\.(server|opslake)\.[a-zA-Z0-9]+' | grep -vE '\.(home|conf|path|timezone)$' | head -n1)"
        fi
        [ -z "$mod" ] && mod="whatap.(unknown-module)"
        PIDS[${#PIDS[@]}]="$pid"
        MODS[${#MODS[@]}]="$mod"
    done <<EOF
$_SCAN_OUT
EOF
}

WHOME=""
WHOME_SRC=""
resolve_home() {
    local i pid cl v unit wd
    if [ -n "$OPT_HOME" ]; then WHOME="$OPT_HOME"; WHOME_SRC="option --home"; return; fi
    # from a running JVM's -Dwhatap.server.home=
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; cmdline_of "$pid"; cl="$_CL"
        v="$(printf '%s\n' "$cl" | grep -oE '[-]Dwhatap\.server\.home=[^ ]+' | head -n1 | cut -d= -f2-)"
        if [ -n "$v" ]; then WHOME="$v"; WHOME_SRC="process $pid (-Dwhatap.server.home)"; return; fi
        i=$((i + 1))
    done
    # from a running JVM's working directory (start scripts cd into the home)
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"
        wd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
        if [ -n "$wd" ] && [ "$wd" != "/" ] && _looks_like_home "$wd"; then
            WHOME="$wd"; WHOME_SRC="process $pid working directory"; return
        fi
        i=$((i + 1))
    done
    # from a systemd unit WorkingDirectory
    if have systemctl; then
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            wd="$(sd_show WorkingDirectory "$unit")"
            if [ -n "$wd" ] && [ "$wd" != "/" ]; then WHOME="$wd"; WHOME_SRC="systemd $unit.service WorkingDirectory"; return; fi
        done
    fi
    # from script location (if collect-collserver.sh was copied into $WHATAP_HOME/bin)
    local sd; sd="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -n "$sd" ] && [ -d "$sd/../conf" ] && [ -d "$sd/../logs" ]; then
        WHOME="$(cd "$sd/.." && pwd)"; WHOME_SRC="script parent dir"; return
    fi
    # from this shell's WHATAP_HOME, then the common install paths. A path that
    # exists but cannot be listed is remembered: it may be the installation.
    local c
    HOME_UNREAD=""
    for c in ${WHATAP_HOME:-} $WHATAP_HOME_CANDIDATES; do
        [ -e "$c" ] || continue
        if ! _dir_ok "$c"; then HOME_UNREAD="$HOME_UNREAD $c"; continue; fi
        if [ -d "$c/conf" ] && ! _dir_ok "$c/conf"; then HOME_UNREAD="$HOME_UNREAD $c/conf"; continue; fi
        if _looks_like_home "$c"; then
            WHOME="$c"
            if [ "$c" = "${WHATAP_HOME:-}" ]; then WHOME_SRC="environment WHATAP_HOME"
            else WHOME_SRC="install path $c (holds a module conf or server jar)"; fi
            return
        fi
    done
    WHOME=""; WHOME_SRC="n/a (not resolved)"
}
HOME_UNREAD=""

# _proc_why -> empty when the process table was fully visible to this uid,
# otherwise what hid part of it.
_proc_why() {
    local why="" uid; uid="$(id -u 2>/dev/null || echo '?')"
    if [ "$uid" != 0 ] && grep -qE '^[^ ]+ /proc proc [^ ]*hidepid=([12]|invisible|noaccess)' /proc/mounts 2>/dev/null; then
        why="/proc is mounted with hidepid, so processes of other users are not visible to uid $uid"
    elif [ "$PROC_SEEN" -eq 0 ]; then
        why="no /proc/<pid> entry was visible to uid $uid"
    elif [ "$PROC_UNREAD" -gt 0 ]; then
        why="$PROC_UNREAD of $PROC_SEEN /proc/<pid>/cmdline not readable by uid $uid"
    fi
    if [ -n "$CMDLINE_SCAN_WHY" ]; then printf '%s' "$CMDLINE_SCAN_WHY"; return; fi
    [ -n "$why" ] && printf '%s%s' "$why" "$(_priv_hint)"
}

# _absence_why -> empty when every input behind "no WhaTap here" was read and
# came back empty, otherwise what could not be read or what contradicts it. The
# inputs: the process table, the systemd unit files, and the install paths.
_absence_why() {
    local why uid; uid="$(id -u 2>/dev/null || echo '?')"
    why="$(_proc_why)"
    # A whatap JVM is running and its home was not found: that is never "not
    # installed here", whatever the rest of the host shows.
    if [ "${#PIDS[@]}" -gt 0 ]; then
        local p0="${PIDS[0]}" cwd c
        cwd="$(readlink "/proc/$p0/cwd" 2>/dev/null)"
        if [ -z "$cwd" ]; then c="its cwd is not readable by uid $uid$(_priv_hint)"
        else c="its cwd $cwd holds no module conf or server jar"; fi
        why="whatap JVM pid $p0 (${MODS[0]}) running, home not resolved: no -Dwhatap.server.home, $c${why:+; $why}"
    fi
    if have systemctl; then
        local uf rc re
        uf="$(_sd list-unit-files --no-pager)"; rc=$?
        if [ "$rc" -ne 0 ] && [ -z "$uf" ]; then
            why="${why:+$why; }systemctl list-unit-files failed (exit $rc)"
        else
            re="^($(printf '%s' "$WHATAP_UNITS" | tr ' ' '|'))\\.service"
            if printf '%s\n' "$uf" | grep -qE "$re"; then
                why="${why:+$why; }whatap unit file installed ($(printf '%s\n' "$uf" | grep -oE "$re" | tr '\n' ' ' | sed 's/ $//')) but WHATAP_HOME not resolved from it"
            fi
        fi
    fi
    [ -n "$HOME_UNREAD" ] && why="${why:+$why; }uid $uid cannot list${HOME_UNREAD}$(_priv_hint)"
    printf '%s' "$why"
}

# _no_whatap_na -> the na reason, stating what was read
NO_WHATAP_NA="no whatap home in any readable process, unit or install path (checked: -Dwhatap.server.home and cwd of whatap JVMs, systemd units, script dir, \$WHATAP_HOME, $WHATAP_HOME_CANDIDATES)"

YARDBASE=""
resolve_yardbase() {
    local v
    if [ -n "$WHOME" ] && [ -f "$WHOME/conf/yard.conf" ]; then
        v="$(grep -E '^[[:space:]]*yardbase[[:space:]]*=' "$WHOME/conf/yard.conf" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d ' \r')"
        [ -n "$v" ] && YARDBASE="$v"
    fi
    if [ -z "$YARDBASE" ] && [ -n "$WHOME" ] && [ -d "$WHOME/yardbase" ]; then YARDBASE="$WHOME/yardbase"; fi
    # resolve relative to WHATAP_HOME
    case "$YARDBASE" in
        ""|/*) : ;;
        *) [ -n "$WHOME" ] && YARDBASE="$WHOME/$YARDBASE" ;;
    esac
}

# time_ref_probe: opt-in external time comparison (--time-ref). Makes ONE network
# call and NEVER sets the clock. Tries ntpdate -q, then sntp, then an HTTPS Date
# header. Emitted as facts (raw output + numeric delta); the reader interprets.
time_ref_probe() {
    warn "[time-ref] querying $TIMEREF_SERVER — this makes a network call (the clock is not modified)"
    progress "querying external time reference ($TIMEREF_SERVER) — network call"
    if have ntpdate; then
        probe "ntpdate -q $TIMEREF_SERVER (query only)" ntpdate -q "$TIMEREF_SERVER"
    elif have sntp; then
        probe "sntp $TIMEREF_SERVER" sntp "$TIMEREF_SERVER"
    elif have curl; then
        local hdr rt lt d
        hdr="$(curl -sI --max-time 10 https://www.google.com 2>"$_errfile" | grep -i '^date:' | head -n1 | cut -d' ' -f2-)"
        if [ -n "$hdr" ]; then
            fact "HTTP Date header (https://www.google.com): $hdr"
            rt="$(date -u -d "$hdr" +%s 2>/dev/null)"; lt="$(date -u +%s 2>/dev/null)"
            if [ -n "$rt" ] && [ -n "$lt" ]; then d=$((lt - rt)); fact "local clock minus reference: ${d}s (1s resolution + network latency)"; fi
        else
            fact "external time: n/a ($(_classify_err))"
        fi
    else
        fact "external time: n/a (command not found: ntpdate/sntp/curl)"
    fi
}

# =============================================================================
# Report body (Tier 0 — MECE domains A..G)
# =============================================================================
run_report() {
    emit_header

    # What this run is for. `home` and `conf` are the two that decide whether a
    # bundle is worth sending: without the WhaTap config files nothing about an
    # upgrade or a misbehaving module can be settled remotely.
    goal services "running whatap modules"
    goal home     "WHATAP_HOME contents"
    goal conf     "module configs"
    goal logs     "log inventory"
    # yardbase only matters on a host that runs yard. Declaring it everywhere
    # would mark a healthy web/proxy-only host INCOMPLETE for a path it is not
    # supposed to have.
    _runs_yard=0
    _i=0; while [ "$_i" -lt "${#MODS[@]}" ]; do
        case "${MODS[$_i]}" in *yard*) _runs_yard=1 ;; esac
        _i=$((_i + 1))
    done
    [ "$_runs_yard" = 1 ] && goal yardbase "yard data path"
    # journal: only where there is a systemd unit whose journal could exist.
    # On a host that runs the modules some other way, an absent journal is the
    # shape of the host, not a gap, so no goal is declared at all.
    _has_unit=0
    if have systemctl; then
        for _u in $WHATAP_UNITS; do unit_loaded "$_u" && { _has_unit=1; break; }; done
    fi
    [ "$_has_unit" = 1 ] && goal journal "systemd journal for whatap units"

    section "Collection environment"
    fact "collector: $COLLECTOR_NAME $VERSION"
    fact "bash: ${BASH_VERSION:-unknown}"
    # Just the uid and, under sudo, the login it came from. Whether that uid is
    # root is the `privilege:` line's job two lines down; saying it twice in
    # adjacent lines only makes the reader check whether they disagree.
    fact "uid: $(id -u 2>/dev/null || echo unknown)$( [ -n "${SUDO_USER:-}" ] && printf ' (via sudo from %s)' "$SUDO_USER" )"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "tools:"
    local t
    for t in ss netstat findmnt df stat systemctl journalctl timedatectl chronyc ntpq zfs zpool jstack jmap jcmd java timeout du tar ps awk; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"; else printf '        %-12s absent\n' "$t"; fi
    done

    # -- A. Host & platform ---------------------------------------------------
    section "A. Host & platform"
    probe "hostname" hostname
    probe "kernel" uname -sr
    probe "arch" uname -m
    read_proc "os-release" /etc/os-release
    probe "date(UTC)" date -u +%Y-%m-%dT%H:%M:%SZ
    fact "timezone: $( { cat /etc/timezone 2>/dev/null; } || date +%Z 2>/dev/null || echo n/a )"
    read_proc "uptime" /proc/uptime
    fact "nproc: $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo n/a)"
    if have free; then probe "memory (free -m)" free -m; else read_proc "meminfo" /proc/meminfo; fi
    read_proc "loadavg" /proc/loadavg
    subsection "cgroup limits (container-aware)"
    read_proc "cgroup v2 memory.max" /sys/fs/cgroup/memory.max
    read_proc "cgroup v2 cpu.max" /sys/fs/cgroup/cpu.max
    read_proc "cgroup v1 memory.limit_in_bytes" /sys/fs/cgroup/memory/memory.limit_in_bytes
    probe_merged "java -version" java -version

    # -- B. Time & clock synchronization --------------------------------------
    # The running NTP daemon's own offset is read (no network call); an
    # external comparison is opt-in (--time-ref).
    section "B. Time & clock synchronization"
    probe "timedatectl" timedatectl
    fact "system timezone: $( { cat /etc/timezone 2>/dev/null; } || { readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'; } || echo 'n/a' )"
    fact "local time: $(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo n/a)"
    fact "UTC time:   $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo n/a)"
    read_proc "clocksource" /sys/devices/system/clocksource/clocksource0/current_clocksource
    # Raw value: systemd-detect-virt prints "none" and exits 1 when it detects
    # no hypervisor; that is its answer, printed as it gave it.
    if have systemd-detect-virt; then
        fact "systemd-detect-virt: $(_bounded systemd-detect-virt 2>/dev/null || true)"
    else
        fact "systemd-detect-virt: n/a (command not found: systemd-detect-virt)"
    fi
    # WhaTap servers run with -Duser.timezone (yard forces GMT); surface it per JVM.
    local jtz="" _ti _tz
    _ti=0
    while [ "$_ti" -lt "${#PIDS[@]}" ]; do
        cmdline_of "${PIDS[$_ti]}"
        _tz="$(printf '%s\n' "$_CL" | grep -oE '[-]Duser\.timezone=[^ ]+' | head -n1)"
        [ -n "$_tz" ] && jtz="$jtz ${MODS[$_ti]}=${_tz#*=}"
        _ti=$((_ti + 1))
    done
    fact "JVM -Duser.timezone (running servers):${jtz:- n/a (no running whatap JVM or flag unset)}"
    subsection "NTP client offset (reads the running daemon — no network call)"
    if have chronyc; then
        probe "chronyc tracking" chronyc tracking
        probe "chronyc sources" chronyc -n sources
    elif have ntpq; then
        probe "ntpq -pn" ntpq -pn
    elif have timedatectl; then
        probe "timedatectl timesync-status" timedatectl timesync-status
    else
        fact "NTP offset: n/a (no chrony/ntpd/timesyncd client found)"
    fi
    subsection "time-sync service state"
    if have systemctl; then
        local _sd _sany=0
        for _sd in chrony chronyd systemd-timesyncd ntp ntpd ntpsec; do
            unit_loaded "$_sd" || continue
            _sany=1
            fact "$_sd.service: active=$(sd_state is-active "$_sd") enabled=$(sd_state is-enabled "$_sd")"
        done
        [ "$_sany" = 0 ] && fact "no chrony/ntpd/timesyncd *.service loaded"
    else
        fact "time-sync service: n/a (command not found: systemctl)"
    fi
    if [ "$OPT_TIMEREF" = 1 ]; then
        subsection "external time reference (opt-in --time-ref; network call)"
        time_ref_probe
    fi

    # -- C. Storage & filesystem (infra focus) --------------------------------
    section "C. Storage & filesystem"
    # The goal exists only on a host that runs yard; elsewhere the facts are
    # printed and nothing is resolved.
    if [ -n "$YARDBASE" ]; then
        fact "yardbase path: $YARDBASE ($( [ -d "$YARDBASE" ] && echo present || echo 'path not found' ))"
        if [ "$_runs_yard" = 1 ]; then
            if _dir_ok "$YARDBASE"; then got yardbase
            else missed yardbase "resolved to $YARDBASE, not reachable by uid $(id -u 2>/dev/null || echo '?')$(_priv_hint)"; fi
        fi
    else
        fact "yardbase path: n/a (not resolved from yard.conf or WHATAP_HOME/yardbase)"
        [ "$_runs_yard" = 1 ] && missed yardbase "not resolved from yard.conf or WHATAP_HOME/yardbase; pass --home DIR"
    fi
    # The filesystem of yardbase, else of WHATAP_HOME. With neither resolved
    # there is no path to ask about: n/a, never the filesystem of the cwd.
    local ypath fstype src
    ypath="$YARDBASE"; [ -z "$ypath" ] && ypath="$WHOME"
    if [ -n "$ypath" ]; then
        fact "filesystem checked for: $ypath"
        fstype="$(fstype_of "$ypath")"; [ -z "$fstype" ] && fstype="n/a (findmnt/stat returned nothing)"
        src="$(source_of "$ypath")"; [ -z "$src" ] && src="n/a"
        fact "yardbase filesystem type: $fstype"
        fact "yardbase mount source: $src"
        if have findmnt; then probe "mount (findmnt)" findmnt -no FSTYPE,SOURCE,TARGET,OPTIONS -T "$ypath"; fi
        probe "capacity (df -h)" df -h "$ypath"
    else
        fstype="n/a (not resolved)"; src="n/a"
        fact "yardbase filesystem type: n/a (neither yardbase nor WHATAP_HOME resolved)"
        fact "yardbase mount source: n/a (neither yardbase nor WHATAP_HOME resolved)"
    fi
    subsection "ZFS (only if this host runs ZFS)"
    if have zfs || have zpool; then
        probe "zfs version" zfs version
        probe "zpool list" zpool list -o name,size,alloc,free,cap,frag,health,ashift
        probe "zpool status" zpool status
        if [ "$fstype" = "zfs" ] && [ -n "$src" ] && [ "$src" != "n/a" ]; then
            probe "zfs get (yardbase dataset)" zfs get -H used,available,recordsize,compression,compressratio,atime,logbias,sync,primarycache,secondarycache,dedup,quota,refquota "$src"
        else
            fact "zfs get (yardbase dataset): n/a (not applicable: yardbase fstype is $fstype)"
        fi
        read_proc "ARC stats" /proc/spl/kstat/zfs/arcstats
    else
        fact "zfs / zpool: n/a (command not found: zfs, zpool)"
    fi
    subsection "data directory markers"
    if [ -n "$YARDBASE" ] && [ -d "$YARDBASE" ]; then
        fact "YARDB_LOCK: $( [ -e "$YARDBASE/YARDB_LOCK" ] && echo "present ($(date -u -r "$YARDBASE/YARDB_LOCK" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo mtime-unknown))" || echo absent )"
        # shallow listing only — never a deep find/du in Tier 0
        probe "pcode dirs (depth 1)" ls -1 "$YARDBASE"
    else
        fact "YARDB_LOCK / pcode dirs: n/a (yardbase not present)"
    fi
    if [ -n "$WHOME" ]; then
        for sub in keeperbase logsink db; do
            fact "$sub dir: $( [ -d "$WHOME/$sub" ] && echo present || echo absent )"
        done
    fi

    # -- D. Deployment layout (on-disk) ---------------------------------------
    section "D. Deployment layout (on-disk)"
    fact "WHATAP_HOME: ${WHOME:-n/a}"
    fact "WHATAP_HOME resolved by: $WHOME_SRC"
    if [ -n "$WHOME" ] && _dir_ok "$WHOME"; then
        probe "top-level (depth 1)" ls -1 "$WHOME"
        if _dir_ok "$WHOME/lib"; then probe "lib jars" ls -1 "$WHOME/lib"; else fact "lib jars: n/a ($(home_why lib))"; fi
        if _dir_ok "$WHOME/conf"; then probe "conf files" ls -1 "$WHOME/conf"; else fact "conf files: n/a ($(home_why conf))"; fi
        got home
    else
        fact "layout: n/a ($(home_why))"
        if [ -z "$WHOME" ] && [ -z "$_ABSENCE_WHY" ]; then na home "$NO_WHATAP_NA"
        elif [ -z "$WHOME" ]; then missed home "$(home_why)$(home_fix); $_ABSENCE_WHY"
        else missed home "$(home_why)$(home_fix)"; fi
    fi

    # -- E. Runtime processes (current state) ---------------------------------
    section "E. Runtime processes (current state)"
    if [ "${#PIDS[@]}" -eq 0 ]; then
        fact "no whatap.server.* / whatap.opslake.* JVM among $((PROC_SEEN - PROC_UNREAD)) readable /proc/<pid>/cmdline ($PROC_UNREAD not readable)"
        _pwhy="$(_proc_why)"
        if [ -z "$_pwhy" ]; then na services "no whatap JVM in any of the $PROC_SEEN /proc/<pid>/cmdline entries"
        else missed services "$_pwhy"; fi
    else
        got services
    fi
    local i pid mod cl jar xmx xx rss st
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"; cmdline_of "$pid"; cl="$_CL"
        subsection "$mod (pid $pid)"
        jar="$(printf '%s\n' "$cl" | grep -oE 'whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar' | head -n1)"; [ -z "$jar" ] && jar="n/a"
        xmx="$(printf '%s\n' "$cl" | grep -oE '[-]Xm[sx][0-9]+[kKmMgG]?' | tr '\n' ' ')"; [ -z "$xmx" ] && xmx="n/a"
        xx="$(printf '%s\n' "$cl" | grep -oE '[-]XX:[^ ]+' | tr '\n' ' ')"; [ -z "$xx" ] && xx="n/a"
        rss="$(awk '/^VmRSS/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"; [ -z "$rss" ] && rss="n/a"
        st="$(_bounded ps -o lstart= -p "$pid" 2>/dev/null)"; [ -z "$st" ] && st="n/a"
        fact "jar(version): $jar"
        fact "heap flags: $xmx"
        fact "-XX flags: $xx"
        fact "RSS: $rss"
        fact "started: $st"
        i=$((i + 1))
    done
    subsection "PID run-files"
    if [ -n "$WHOME" ] && _dir_ok "$WHOME"; then
        probe "*.run" sh -c 'ls -1 "$1"/*.run' sh "$WHOME"
    else fact "*.run: n/a ($(home_why))"; fi
    subsection "listening ports (module default port numbers)"
    local lports p name port
    lports=" $(get_listen_ports | tr '\n' ' ') "
    for p in "yard-data 6610" "yard-data-alt 6600" "yard-web 7710" "yard-sync 6620" "yard-rpc 7770" \
             "proxy-web 7700" "eureka 6761" "keeper 6789" "gateway-http 8800" "gateway-grpc 8870" \
             "notihub 6500" "front 8080" "account 18080"; do
        name="${p% *}"; port="${p#* }"
        case "$lports" in *" $port "*) fact "port $port ($name default): LISTEN" ;; *) fact "port $port ($name default): not listening" ;; esac
    done
    if have ss; then probe "ss -ltnp (whatap procs)" sh -c 'ss -ltnp 2>/dev/null | grep -E "whatap|java" || true'
    elif have netstat; then probe "netstat -ltnp (whatap procs)" sh -c 'netstat -ltnp 2>/dev/null | grep -E "whatap|java" || true'
    else fact "socket->pid map: n/a (command not found: ss/netstat)"; fi
    subsection "systemd unit state (installed units only)"
    if have systemctl; then
        local any=0
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            any=1
            fact "$unit.service: active=$(sd_state is-active "$unit") enabled=$(sd_state is-enabled "$unit") restarts=$(sd_show NRestarts "$unit")"
        done
        [ "$any" = 0 ] && fact "no whatap *.service units are installed (LoadState != loaded)"
    else
        fact "systemd: n/a (command not found: systemctl — non-systemd host or container)"
    fi

    # -- F. Configuration (raw) -----------------------------------------------
    section "F. Configuration"
    # conf/ must be listable before its glob means anything: an unreadable
    # directory hands back the literal pattern, not "no *.conf".
    if [ -n "$WHOME" ] && _dir_ok "$WHOME/conf"; then
        local cf _cfn=0 _cfu=""
        for cf in "$WHOME"/conf/*.conf; do
            [ -e "$cf" ] || { fact "no *.conf files under $WHOME/conf"; break; }
            _cfn=$((_cfn + 1))
            [ -r "$cf" ] || _cfu="$_cfu $(basename "$cf")"
            fact "$(basename "$cf") ($(wc -c < "$cf" 2>/dev/null | tr -d ' ') bytes, mtime $(date -u -r "$cf" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)):"
            dump_file "$cf"
        done
        if [ -n "$_cfu" ]; then missed conf "uid $(id -u 2>/dev/null || echo '?') cannot read$_cfu under $WHOME/conf$(_priv_hint)"
        elif [ "$_cfn" -gt 0 ]; then got conf
        else na conf "conf/ is readable and holds no *.conf"; fi
    else
        fact "conf/: n/a ($(home_why conf))"
        if [ -z "$WHOME" ] && [ -z "$_ABSENCE_WHY" ]; then na conf "$NO_WHATAP_NA"
        elif [ -z "$WHOME" ]; then missed conf "$(home_why conf)$(home_fix); $_ABSENCE_WHY"
        elif [ -d "$WHOME/conf" ] || [ ! -x "$WHOME" ]; then missed conf "$(home_why conf)$(home_fix)"
        else missed conf "$(home_why conf)"; fi
    fi

    # -- G. Logs & recent events ----------------------------------------------
    section "G. Logs & recent events"
    if [ -n "$WHOME" ] && _dir_ok "$WHOME/logs"; then
        # Current logs are listed one by one; rotated ones (logback
        # "<base>.<yyyyMMdd>.<i>.log", often hundreds) are summarized per base.
        subsection "current logs (non-rotated) — name / size / mtime"
        local _f _cur=0
        for _f in "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log; do
            [ -f "$_f" ] || continue
            case "$_f" in *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;; esac
            _cur=1
            fact "$(printf '%s\t%s bytes\t%s' "${_f#"$WHOME"/}" "$(wc -c < "$_f" 2>/dev/null | tr -d ' ')" "$(date -u -r "$_f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)")"
        done
        if [ "$_cur" = 0 ]; then
            fact "no non-rotated *.log found under $WHOME/logs"
            na logs "logs/ is readable and holds no non-rotated *.log"
        else
            got logs
        fi

        subsection "rotated logs (summary per base: count / total bytes / date span)"
        # ls -l is metadata only (no content read) — safe with hundreds of files.
        local _rot
        _rot="$(ls -l "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log 2>/dev/null | awk '
            { p=$NF }
            p ~ /\.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9]+\.log$/ {
                m=split(p,a,"/"); fn=a[m]
                sub(/\.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9]+\.log$/, "", fn)
                match(p, /\.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\./); d=substr(p,RSTART+1,8)
                c[fn]++; s[fn]+=$5
                if (mn[fn]==""||d<mn[fn]) mn[fn]=d
                if (d>mx[fn]) mx[fn]=d
            }
            END { for (b in c) printf "%s: %d files, %d bytes total, %s..%s\n", b, c[b], s[b], mn[b], mx[b] }
        ' | sort)"
        if [ -n "$_rot" ]; then printf '%s\n' "$_rot" | while IFS= read -r _l; do fact "$_l"; done
        else fact "no rotated logs"; fi

        # What this bundle actually carries, as opposed to what exists on the host
        # above. Without this the reader cannot tell "no such log" from "we left
        # it out", and the two lead to different next steps.
        if [ "$LOGSEL_RAN" = 1 ]; then
            subsection "logs copied into this bundle (selection)"
            fact "policy: $LOGSEL_REASON; caps ${OPT_MAXLOG_MB}MB per file, ${OPT_MAXTOTAL_MB}MB total"
            fact "copied: $LOGSEL_KEPT_N files, $LOGSEL_KEPT_BYTES bytes ($LOGSEL_TRUNC_N truncated to their newest end)"
            fact "not copied: $LOGSEL_DROP_N files, $LOGSEL_DROP_BYTES bytes"
            fact "per-file detail with the reason for each: logs/SELECTION.txt"
        fi

        subsection "recent ERROR/WARN/Exception counts (current logs only, last 2MB each)"
        for _f in "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log; do
            [ -f "$_f" ] || continue
            case "$_f" in *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;; esac
            local c; c="$(tail -c 2097152 "$_f" 2>/dev/null | grep -cE 'ERROR|WARN|Exception' 2>/dev/null)"
            fact "${_f#"$WHOME"/}: ${c:-0}"
        done
        subsection "per-service log tails (base logs, newest-first, 40 lines each)"
        # Each base *.log, newest first, without rotated files and the
        # _self/_api/access/checker/gc streams: 40 lines each, at most 12 logs.
        # `ls -1t` because a glob cannot sort; read line by line from a heredoc
        # so a name with a space survives and _lc stays in this shell.
        local TAIL_LINES=40 LOG_TAIL_FILES=12 _lc=0 _lf _lslist
        _lslist="$(ls -1t "$WHOME"/logs/*.log 2>/dev/null)"
        while IFS= read -r _lf; do
            [ -n "$_lf" ] && [ -f "$_lf" ] || continue
            # skip secondary streams and rotated (logback ".<yyyyMMdd>.<i>.log") files
            case "$_lf" in
                *_self.log|*_api.log|*access*|*checker*|*/gc*.log) continue ;;
                *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;;
            esac
            _lc=$((_lc + 1))
            if [ "$_lc" -gt "$LOG_TAIL_FILES" ]; then
                fact "(further base logs not tailed: at most $LOG_TAIL_FILES are tailed; all are in the inventory above)"
                break
            fi
            fact "${_lf#"$WHOME"/} (mtime $(date -u -r "$_lf" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)):"
            tail -n "$TAIL_LINES" "$_lf" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
        done <<EOF
$_lslist
EOF
        [ "$_lc" -eq 0 ] && fact "no base service logs found (only _self/_api/access streams, or none)"
        subsection "self-mon / checker"
        fact "yard_self.log: $( ls "$WHOME"/logs/*_self.log >/dev/null 2>&1 && echo present || echo 'n/a (path not found)' )"
        local chk; chk="$(_bounded find "$WHOME/logs" -maxdepth 2 -name '*checker*.log' 2>/dev/null | head -n1)"
        if [ -n "$chk" ]; then fact "$chk (last 20 lines):"; tail -n 20 "$chk" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else fact "checker log: n/a (path not found)"; fi
    else
        fact "logs/: n/a ($(home_why logs))"
        if [ -z "$WHOME" ] && [ -z "$_ABSENCE_WHY" ]; then na logs "$NO_WHATAP_NA"
        elif [ -z "$WHOME" ]; then missed logs "$(home_why logs)$(home_fix); $_ABSENCE_WHY"
        elif [ -d "$WHOME/logs" ] || [ ! -x "$WHOME" ]; then missed logs "$(home_why logs)$(home_fix)"
        else missed logs "$(home_why logs)"; fi
    fi
    subsection "heap dumps / GC log / restart"
    if [ -n "$WHOME" ]; then
        # "none" only when every directory searched was read. A directory is
        # skipped as absent only when its parent was listed and holds no such
        # entry; a symlink this uid cannot follow is not absent.
        local _hp="" _hu="" _f _hd _uid; _uid="$(id -u 2>/dev/null || echo '?')"
        local _st
        for _hd in "$WHOME" "$WHOME/logs"; do
            _st="$(_path_state "$_hd")"
            case "$_st" in
                ok)         for _f in "$_hd"/*.hprof; do [ -e "$_f" ] && _hp=1; done ;;
                # the home missing is said once; a logs/ missing from a listed home is no gap
                absent)     [ "$_hd" = "$WHOME" ] && _hu="$_hu$_nl$_hd: n/a (path not found)" ;;
                notdir)     _hu="$_hu$_nl$_hd: n/a (not a directory)" ;;
                dangling:*) _hu="$_hu$_nl$_hd: n/a (dangling symlink to ${_st#dangling:})" ;;
                *)          _hu="$_hu$_nl$_hd: n/a (uid $_uid cannot list)" ;;
            esac
            [ "$_hd" = "$WHOME" ] && [ "$_st" = absent ] && break
        done
        if [ -n "$_hp" ]; then probe "*.hprof" sh -c 'ls -la "$1"/*.hprof "$1"/logs/*.hprof 2>/dev/null || true' sh "$WHOME"
        elif [ -z "$_hu" ]; then fact "*.hprof: none (no *.hprof in $WHOME or $WHOME/logs)"; fi
        if [ -n "$_hu" ]; then
            [ -z "$_hp" ] && fact "*.hprof: n/a (not every directory searched was read)"
            printf '%s\n' "$_hu" | while IFS= read -r _l; do [ -n "$_l" ] && fact "*.hprof in $_l"; done
        fi
        fact "gc log: $( ls "$WHOME"/logs/gc*.log >/dev/null 2>&1 && echo present || echo 'absent (no logs/gc*.log)' )"
        if [ -f "$WHOME/restart.out" ]; then fact "restart.out (last 20 lines):"; tail -n 20 "$WHOME/restart.out" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else fact "restart.out: n/a (path not found)"; fi
    fi
    subsection "journal errors (last ${OPT_HOURS}h, bounded, installed units only)"
    _jwhy="$(journal_why)"
    _jhits=0; _jfail=""
    if have journalctl; then
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            local jout
            jout="$(_bounded journalctl -u "$unit.service" -p err --since "${OPT_HOURS} hours ago" -n 20 --no-pager 2>/dev/null)"
            case "$?" in
                0|1) ;;
                124) _jfail="$_jfail $unit (timed out: ${CMD_TIMEOUT}s)"; fact "$unit.service: n/a (timed out: ${CMD_TIMEOUT}s)"; continue ;;
                *)   [ -z "$jout" ] && { _jfail="$_jfail $unit (journalctl failed)"; fact "$unit.service: n/a (journalctl failed)"; continue; } ;;
            esac
            case "$jout" in
                ''|*'-- No entries --'*) ;;
                *) _jhits=$((_jhits + 1))
                   fact "$unit.service (last 20 err):"
                   printf '%s\n' "$jout" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done ;;
            esac
        done
    fi
    # An empty journal has two causes that print the same thing. Say which.
    # Resolved only where the goal was declared (a loaded whatap unit).
    if [ "$_has_unit" != 1 ]; then
        fact "journal: n/a (no whatap unit is loaded, so no unit journal was read)"
    elif [ -n "$_jwhy" ]; then
        fact "journal: n/a ($_jwhy)"
        missed journal "$_jwhy$(_priv_hint)"
    elif [ -n "$_jfail" ]; then
        missed journal "journalctl did not answer for:$_jfail"
    elif [ "$_jhits" -gt 0 ]; then
        got journal
    else
        fact "journal: readable by uid $(id -u 2>/dev/null || echo '?'); no err entries for the loaded whatap units in the last ${OPT_HOURS}h"
        na journal "the system journal is readable and holds no entries for the whatap units in the last ${OPT_HOURS}h"
    fi

    emit_status
    emit_footer
}

# =============================================================================
# Bundle (Tier 1 default; Tier 2 opt-in)
# =============================================================================
# home_why [SUB] -> why a WHATAP_HOME-relative path produced nothing. "Not
# resolved" (needs --home) and "resolved but unreadable by this uid" (needs the
# owning account) lead to different next steps.
home_why() {
    local sub="$1" path="$WHOME"
    [ -n "$sub" ] && path="$WHOME/$sub"
    local uid; uid="$(id -u 2>/dev/null || echo '?')"
    if [ -z "$WHOME" ]; then
        printf 'WHATAP_HOME not resolved'
    elif [ ! -d "$WHOME" ]; then
        # stat() on WHOME itself failed, so its parent is not searchable by us.
        printf 'WHATAP_HOME resolved to %s (via %s) but uid %s cannot reach it' \
            "$WHOME" "$WHOME_SRC" "$uid"
    elif [ ! -x "$WHOME" ]; then
        # WHOME stats but we cannot search it, so every path under it would come
        # back "not found". Say permission, not absence — they are different bugs.
        printf 'uid %s cannot search %s (no execute permission)' \
            "$uid" "$WHOME"
    elif [ ! -d "$path" ]; then
        printf 'path not found: %s' "$path"
    elif [ ! -r "$path" ]; then
        printf 'uid %s cannot read %s' "$uid" "$path"
    elif [ ! -x "$path" ]; then
        printf 'uid %s cannot search %s (no execute permission)' "$uid" "$path"
    else
        printf 'unreadable: %s' "$path"
    fi
}

# home_fix -> how running this differently obtains what home_why says is
# missing. It goes only into goal reasons, never into a fact line (CONTRACT 1).
home_fix() {
    if [ -z "$WHOME" ]; then printf '; pass --home DIR'
    elif [ ! -d "$WHOME" ] || [ ! -x "$WHOME" ]; then printf '; run with sudo or as the account that owns the installation'
    else _priv_hint; fi
}

# journal_why -> empty when this uid can read the SYSTEM journal, otherwise the
# reason. journalctl does not fail for an unprivileged user: it narrows to that
# user's entries and prints "-- No entries --", the same as a quiet unit.
journal_why() {
    have journalctl || { printf 'command not found: journalctl'; return; }
    [ "$(id -u 2>/dev/null)" = 0 ] && return
    local d f uid; uid="$(id -u 2>/dev/null || echo '?')"
    for d in /var/log/journal /run/log/journal; do
        [ -d "$d" ] || continue
        if [ ! -x "$d" ]; then
            printf 'uid %s cannot search %s' "$uid" "$d"; return
        fi
        for f in "$d"/*/system.journal; do
            [ -e "$f" ] || continue
            [ -r "$f" ] && return
            printf 'uid %s cannot read %s (groups: %s)' \
                "$uid" "$f" "$(id -nG 2>/dev/null | tr ' ' ',')"
            return
        done
    done
    printf 'no system journal file under /var/log/journal or /run/log/journal'
}

collect_conf() {
    local dest="$1"
    [ -n "$WHOME" ] && _dir_ok "$WHOME/conf" || { warn "conf: not copied ($(home_why conf))"; return; }
    mkdir -p "$dest" 2>/dev/null
    if _bounded cp -a "$WHOME/conf/." "$dest/" 2>/dev/null; then progress "conf: copied $WHOME/conf"
    else warn "conf: copy of $WHOME/conf was incomplete (a file could not be read by uid $(id -u 2>/dev/null || echo '?'))"; fi
}

# Results of the last collect_logs run, read back by the report's G section.
LOGSEL_RAN=0 LOGSEL_KEPT_N=0 LOGSEL_KEPT_BYTES=0 LOGSEL_SRC_BYTES=0
LOGSEL_TRUNC_N=0 LOGSEL_DROP_N=0 LOGSEL_DROP_BYTES=0 LOGSEL_REASON=""

collect_logs() {
    local dest="$1"
    [ -n "$WHOME" ] && _dir_ok "$WHOME/logs" || { warn "logs: not copied ($(home_why logs))"; return; }

    # Two caps: one huge file and many large files are different failures (a
    # per-file cap alone once gave a 393MB bundle, 99.95% logs).
    #   * per-file cap  — tail, so the newest end of a big log survives
    #   * total cap     — stop once all copied logs together reach it
    #   * rotated logs  — opt-in; current logs alone answer most questions
    # What is not copied is listed with its reason, so it does not read as absent.
    local cap=$((OPT_MAXLOG_MB * 1024 * 1024))
    local total_cap=$((OPT_MAXTOTAL_MB * 1024 * 1024))
    local days="$OPT_LOG_DAYS"
    local list sel
    list="$(_tmp logsel.list)"
    sel="$dest/SELECTION.txt"
    mkdir -p "$dest" 2>/dev/null

    # Candidates, newest first. Current (non-rotated) logs sort ahead of rotated
    # ones so the total cap never spends itself on history before the live logs.
    _bounded find "$WHOME/logs" -maxdepth 2 -type f \( -name '*.log' -o -name '*.log.*' \) 2>/dev/null |
    while IFS= read -r f; do
        local kind=current
        case "$f" in
            *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log|*.log.[0-9]*|*.log.gz) kind=rotated ;;
        esac
        printf '%s\t%s\t%s\n' "$kind" "$(date -u -r "$f" +%s 2>/dev/null || echo 0)" "$f"
    done | sort -t"$(printf '\t')" -k1,1 -k2,2nr > "$list"

    : > "$sel"
    printf 'log selection by %s %s\n' "$COLLECTOR_NAME" "$VERSION" >> "$sel"
    printf 'caps: %sMB per file, %sMB total; rotated logs: %s\n' \
        "$OPT_MAXLOG_MB" "$OPT_MAXTOTAL_MB" \
        "$([ "$OPT_ROTATED" = 1 ] && printf 'included (last %sd)' "$days" || printf 'not copied (--with-rotated to include)')" >> "$sel"
    printf '\nstate\tkept_bytes\tsource_bytes\tfile\treason\n' >> "$sel"

    LOGSEL_RAN=1 LOGSEL_KEPT_N=0 LOGSEL_KEPT_BYTES=0 LOGSEL_SRC_BYTES=0
    LOGSEL_TRUNC_N=0 LOGSEL_DROP_N=0 LOGSEL_DROP_BYTES=0

    # Redirect (not a pipe) so the loop runs in this shell and the totals survive.
    # The middle field is the mtime the candidate list was sorted on; it is
    # consumed into _ because only the order it produced is wanted here.
    local kind f rel sub sz take
    while IFS="$(printf '\t')" read -r kind _ f; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        rel="${f#"$WHOME"/logs/}"
        sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"; [ -z "$sz" ] && sz=0
        LOGSEL_SRC_BYTES=$((LOGSEL_SRC_BYTES + sz))

        if [ "$kind" = rotated ] && [ "$OPT_ROTATED" != 1 ]; then
            LOGSEL_DROP_N=$((LOGSEL_DROP_N + 1)); LOGSEL_DROP_BYTES=$((LOGSEL_DROP_BYTES + sz))
            printf 'dropped\t0\t%s\t%s\trotated log, --with-rotated not given\n' "$sz" "$rel" >> "$sel"
            continue
        fi
        if [ "$kind" = rotated ] && [ -z "$(_bounded find "$f" -mtime "-$days" 2>/dev/null)" ]; then
            LOGSEL_DROP_N=$((LOGSEL_DROP_N + 1)); LOGSEL_DROP_BYTES=$((LOGSEL_DROP_BYTES + sz))
            printf 'dropped\t0\t%s\t%s\trotated log older than %s days\n' "$sz" "$rel" "$days" >> "$sel"
            continue
        fi

        take="$sz"; [ "$take" -gt "$cap" ] && take="$cap"
        if [ $((LOGSEL_KEPT_BYTES + take)) -gt "$total_cap" ]; then
            LOGSEL_DROP_N=$((LOGSEL_DROP_N + 1)); LOGSEL_DROP_BYTES=$((LOGSEL_DROP_BYTES + sz))
            printf 'dropped\t0\t%s\t%s\ttotal cap %sMB reached\n' "$sz" "$rel" "$OPT_MAXTOTAL_MB" >> "$sel"
            continue
        fi

        sub="$(dirname "$rel")"; mkdir -p "$dest/$sub" 2>/dev/null
        if [ "$sz" -le "$cap" ]; then
            cp -a "$f" "$dest/$rel" 2>/dev/null
            printf 'kept\t%s\t%s\t%s\t-\n' "$sz" "$sz" "$rel" >> "$sel"
        else
            tail -c "$cap" "$f" > "$dest/$rel" 2>/dev/null
            printf 'truncated to last %sMB of %s bytes\n' "$OPT_MAXLOG_MB" "$sz" > "$dest/$rel.trunc"
            LOGSEL_TRUNC_N=$((LOGSEL_TRUNC_N + 1))
            printf 'truncated\t%s\t%s\t%s\tper-file cap %sMB, tail kept\n' "$cap" "$sz" "$rel" "$OPT_MAXLOG_MB" >> "$sel"
        fi
        LOGSEL_KEPT_N=$((LOGSEL_KEPT_N + 1)); LOGSEL_KEPT_BYTES=$((LOGSEL_KEPT_BYTES + take))
    done < "$list"
    rm -f "$list" 2>/dev/null

    # kept_bytes is what landed in the bundle; a truncated file contributes its
    # cap, not its source size. So kept_bytes + dropped_bytes does not add up to
    # the candidate total, and the third line says where the rest went.
    printf '\ncandidates: %s files, %s bytes on the host\n' \
        "$((LOGSEL_KEPT_N + LOGSEL_DROP_N))" "$LOGSEL_SRC_BYTES" >> "$sel"
    printf 'copied:     %s files, %s bytes in this bundle (%s truncated)\n' \
        "$LOGSEL_KEPT_N" "$LOGSEL_KEPT_BYTES" "$LOGSEL_TRUNC_N" >> "$sel"
    printf 'not copied: %s files, %s bytes; plus %s bytes cut off the tail-truncated ones\n' \
        "$LOGSEL_DROP_N" "$LOGSEL_DROP_BYTES" \
        "$((LOGSEL_SRC_BYTES - LOGSEL_DROP_BYTES - LOGSEL_KEPT_BYTES))" >> "$sel"

    LOGSEL_REASON="$([ "$OPT_ROTATED" = 1 ] && printf 'current + rotated within %sd' "$days" || printf 'current logs only')"
    progress "logs: copied $LOGSEL_KEPT_N files ($LOGSEL_KEPT_BYTES bytes), left out $LOGSEL_DROP_N ($LOGSEL_DROP_BYTES bytes) — see logs/SELECTION.txt"
    # How to obtain what was left out is a way to run this differently, so it
    # goes to the operator rather than into the report's facts.
    if [ "$LOGSEL_DROP_N" -gt 0 ]; then
        if [ "$OPT_ROTATED" = 1 ]; then
            warn "logs: $LOGSEL_DROP_N files not copied; --max-total-mb / --max-log-mb / --log-days copy more"
        else
            warn "logs: $LOGSEL_DROP_N files not copied; --with-rotated (and a larger --max-total-mb) copies more"
        fi
    fi
}

collect_fs() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have findmnt && _bounded findmnt > "$dest/findmnt.txt" 2>/dev/null
    have df && _bounded df -T > "$dest/df-T.txt" 2>/dev/null
    cat /proc/self/mountinfo > "$dest/mountinfo.txt" 2>/dev/null
    if have zpool; then
        _bounded zpool status -v > "$dest/zpool-status.txt" 2>&1
        _bounded zpool list > "$dest/zpool-list.txt" 2>&1
        _bounded zpool history > "$dest/zpool-history.txt" 2>&1
    fi
    if have zfs; then
        _bounded zfs list -o space > "$dest/zfs-list.txt" 2>&1
        [ -n "$YARDBASE" ] && _bounded zfs get all "$(source_of "$YARDBASE")" > "$dest/zfs-get.txt" 2>&1
    fi
    cat /proc/spl/kstat/zfs/arcstats > "$dest/arcstats.txt" 2>/dev/null
    progress "fs: snapshot written"
}

collect_os() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have ps && _bounded ps aux > "$dest/ps-aux.txt" 2>/dev/null
    have ss && _bounded ss -s > "$dest/ss-summary.txt" 2>/dev/null
    have ss && _bounded ss -ltnp > "$dest/ss-listen.txt" 2>/dev/null
    have df && _bounded df -h > "$dest/df-h.txt" 2>/dev/null
    have free && _bounded free -m > "$dest/free.txt" 2>/dev/null
    cat /proc/loadavg > "$dest/loadavg.txt" 2>/dev/null
    # dmesg is refused for an unprivileged uid under kernel.dmesg_restrict=1:
    # keep what it said rather than a 0-byte file.
    { _bounded dmesg 2>&1 || true; } | tail -n 200 > "$dest/dmesg-tail.txt" 2>/dev/null
    [ -s "$dest/dmesg-tail.txt" ] || printf 'dmesg produced no output and no message (uid %s)\n' \
        "$(id -u 2>/dev/null || echo '?')" > "$dest/dmesg-tail.txt" 2>/dev/null
    have top && _bounded top -bn1 2>/dev/null | head -n 40 > "$dest/top.txt" 2>/dev/null
    local i pid
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"
        { cat "/proc/$pid/status"; echo '--- limits ---'; cat "/proc/$pid/limits"; } > "$dest/proc-$pid.txt" 2>/dev/null
        i=$((i + 1))
    done
    progress "os: snapshot written"
}

collect_time() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have timedatectl && _bounded timedatectl > "$dest/timedatectl.txt" 2>&1
    have timedatectl && _bounded timedatectl timesync-status > "$dest/timesync-status.txt" 2>&1
    if have chronyc; then
        _bounded chronyc tracking    > "$dest/chrony-tracking.txt"   2>&1
        _bounded chronyc -n sources  > "$dest/chrony-sources.txt"    2>&1
        _bounded chronyc sourcestats > "$dest/chrony-sourcestats.txt" 2>&1
    fi
    have ntpq && _bounded ntpq -pn > "$dest/ntpq.txt" 2>&1
    cat /sys/devices/system/clocksource/clocksource0/current_clocksource > "$dest/clocksource.txt" 2>/dev/null
    readlink -f /etc/localtime > "$dest/localtime.txt" 2>/dev/null
    progress "time: snapshot written"
}

collect_journal() {
    local dest="$1"; have journalctl || { warn "journal: skipped (journalctl absent)"; return; }
    mkdir -p "$dest" 2>/dev/null
    # Capped twice: by time (CMD_TIMEOUT) and by size (JOURNAL_LINES per unit,
    # newest kept), because a unit that restarts in a loop logs millions of lines.
    local unit JOURNAL_LINES=20000
    for unit in $WHATAP_UNITS; do
        unit_loaded "$unit" || continue
        _bounded journalctl -u "$unit.service" --since "${OPT_HOURS} hours ago" -n "$JOURNAL_LINES" --no-pager > "$dest/$unit.journal.txt" 2>&1
        [ $? -eq 124 ] && printf '\n(journalctl stopped at the %ss cap)\n' "$CMD_TIMEOUT" >> "$dest/$unit.journal.txt"
    done
    progress "journal: last ${OPT_HOURS}h written (at most $JOURNAL_LINES lines per unit)"
}

# ---- Tier 2 (opt-in) --------------------------------------------------------
collect_threads() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    local n="$OPT_THREADS"; [ "$n" -lt 1 ] 2>/dev/null && n=1
    local i pid mod k
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"
        warn "[Tier2] thread dump: pid $pid ($mod) x$n — may cause a JVM safepoint pause"
        k=1
        while [ "$k" -le "$n" ]; do
            if have jstack; then
                CMD_TIMEOUT=60 _bounded jstack -l "$pid" > "$dest/$mod-$pid.jstack.$k.txt" 2>&1
                [ $? -eq 124 ] && printf '\n(jstack stopped at the 60s cap)\n' >> "$dest/$mod-$pid.jstack.$k.txt"
            else
                # kill is a shell builtin and returns at once; the dump itself is
                # written by the JVM to its own stdout, not here.
                kill -3 "$pid" 2>/dev/null
                printf 'jstack absent; sent SIGQUIT to %s (output goes to the JVM stdout/journal)\n' "$pid" > "$dest/$mod-$pid.sigquit.$k.txt"
            fi
            k=$((k + 1))
        done
        i=$((i + 1))
    done
}

collect_histo() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have jmap || { warn "[Tier2] histo: jmap absent"; return; }
    local i pid mod
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"
        warn "[Tier2] jmap -histo: pid $pid ($mod) — walks the live heap (no full GC)"
        CMD_TIMEOUT=120 _bounded jmap -histo "$pid" 2>&1 | head -n 200 > "$dest/$mod-$pid.histo.txt" 2>/dev/null
        i=$((i + 1))
    done
}

collect_heap() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have jmap || { warn "[Tier2] heap: jmap absent"; return; }
    local i pid mod
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"
        warn "[Tier2] FULL HEAP DUMP: pid $pid ($mod) — large file and a JVM pause"
        CMD_TIMEOUT=900 _bounded jmap -dump:format=b,file="$dest/$mod-$pid.hprof" "$pid" > "$dest/$mod-$pid.heap.log" 2>&1
        [ $? -eq 124 ] && warn "[Tier2] heap dump of pid $pid stopped at the 900s cap; the .hprof is incomplete"
        i=$((i + 1))
    done
}

collect_du() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$YARDBASE" ] && [ -d "$YARDBASE" ] || { warn "[Tier2] du: yardbase absent"; return; }
    warn "[Tier2] recursive du of $YARDBASE — reads data-disk metadata"
    CMD_TIMEOUT=120 _bounded du --max-depth=1 -h "$YARDBASE" > "$dest/yardbase-du.txt" 2>&1
    [ $? -eq 124 ] && printf '\n(du stopped at the 120s cap; totals above are partial)\n' >> "$dest/yardbase-du.txt"
}

do_bundle() {
    local work tarball
    # The work dir lives in the run's private directory, so an interrupted run
    # (Ctrl-C, a lost ssh session) leaves no copy of configs or logs behind.
    work="$(_tmp bundle)"
    case "$work" in /dev/null) warn "the bundle was not written: no private temp directory could be created under ${TMPDIR:-/tmp}"; return 1 ;; esac
    mkdir -p "$work" 2>/dev/null || { warn "the bundle was not written: cannot create $work"; return 1; }
    # Logs are selected before the report is written, so section G can say what
    # this bundle carries and what it left out.
    collect_logs    "$work/logs"
    run_report > "$work/report.txt" 2>/dev/null
    progress "report: written to bundle"
    collect_conf    "$work/conf"
    collect_fs      "$work/fs"
    collect_time    "$work/time"
    collect_os      "$work/os"
    collect_journal "$work/journal"
    [ "$OPT_THREADS" -ge 1 ] 2>/dev/null && collect_threads "$work/jvm"
    [ "$OPT_HISTO" = 1 ] && collect_histo "$work/jvm"
    [ "$OPT_HEAP" = 1 ] && collect_heap "$work/jvm"
    [ "$OPT_DU" = 1 ] && collect_du "$work/fs"

    tarball="$OPT_OUT/$BASENAME.tar.gz"
    have tar || { warn "the bundle was not written: tar: command not found"; return 1; }
    # -C instead of `cd "$work"`: $tarball stays relative to the caller's cwd.
    # Not bounded by CMD_TIMEOUT: this is a local write of what the run already
    # collected, and a cap would leave a truncated archive behind.
    if tar -C "$work" -czf "$tarball" . 2>/dev/null && [ -s "$tarball" ]; then
        # Under sudo the tarball is root-owned, and the operator who started
        # the run then cannot move or delete the one file they came for.
        _give_back "$tarball"
        progress "bundle: $tarball"
    else
        rm -f "$tarball" 2>/dev/null
        warn "the bundle was not written: tar could not write $tarball"
        return 1
    fi
}

# _give_back FILE -> under sudo, hand FILE to the account that ran sudo
_give_back() {
    if [ "$(id -u 2>/dev/null)" = 0 ] && [ -n "${SUDO_UID:-}" ]; then
        chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$1" 2>/dev/null
    fi
}

# _need_int NAME VALUE -> exit 2 unless VALUE is a non-negative integer
_need_int() {
    case "$2" in
        ''|*[!0-9]*) warn "$1 takes a non-negative integer; got '$2'"; exit 2 ;;
    esac
}

# =============================================================================
# main
# =============================================================================
# fd 3 = the terminal, saved before any stdout/stderr redirection so progress()
# still reaches the operator even in --file mode (which redirects both).
exec 3>&2

# No arguments -> print help and stop; a collection needs an explicit action flag.
[ "$ARGC" -eq 0 ] && { usage; exit 0; }

# An action flag is required. Modifiers alone (--home/--out/--hours/--quiet/...) are
# not enough — say so and show help rather than silently doing nothing.
if [ "$OPT_BUNDLE" = 0 ] && [ "$OPT_STDOUT" = 0 ] && [ "$OPT_FILE" = 0 ]; then
    warn "no action flag given — need one of --file / --stdout / --bundle"
    usage >&2
    exit 2
fi

# Numeric options are checked before anything runs, not half way into a bundle.
_need_int --hours "$OPT_HOURS"
_need_int --max-log-mb "$OPT_MAXLOG_MB"
_need_int --max-total-mb "$OPT_MAXTOTAL_MB"
_need_int --log-days "$OPT_LOG_DAYS"
_need_int --threads "$OPT_THREADS"

# Tier 2 JVM work is capped per call (jstack 60s, jmap -histo 120s, heap dump
# 900s); the run deadline is raised to fit them unless the caller set one.
if [ -z "$_RUN_DEADLINE_ENV" ]; then
    [ "$OPT_THREADS" -ge 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + 120))
    [ "$OPT_HISTO" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + 300))
    [ "$OPT_HEAP" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + 1800))
    [ "$OPT_DU" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + 120))
fi

_run_init
_init_probe

# The output directory is checked before collecting, so an unwritable one
# fails at once rather than after a full run.
if [ "$OPT_STDOUT" != 1 ] || [ "$OPT_BUNDLE" = 1 ]; then
    mkdir -p "$OPT_OUT" 2>/dev/null
    if [ ! -d "$OPT_OUT" ] || [ ! -w "$OPT_OUT" ] || [ ! -x "$OPT_OUT" ]; then
        warn "the report was not written: output directory $OPT_OUT is not writable by uid $(id -u 2>/dev/null || echo '?')"
        exit 1
    fi
fi

progress "discovering WhaTap services / resolving WHATAP_HOME ..."
discover_services
# every unit sd_show will be asked about, in one call
_pf=""; for _u in $WHATAP_UNITS chrony chronyd systemd-timesyncd ntp ntpd ntpsec; do _pf="$_pf $_u.service"; done
# shellcheck disable=SC2086
_sd_prefetch $_pf
resolve_home
resolve_yardbase
# What kept "no WhaTap here" from being read off this host; empty when every
# input was read. Computed once: it runs systemctl list-unit-files.
_ABSENCE_WHY=""
[ -z "$WHOME" ] && _ABSENCE_WHY="$(_absence_why)"
TARGET="collection-server/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)${WHOME:+@$WHOME}"
progress "WHATAP_HOME: ${WHOME:-n/a} (via $WHOME_SRC); whatap JVMs found: ${#PIDS[@]}"

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-collserver-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (Tier 0 report + Tier 1 artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle || exit 1
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (Tier 0 report, read-only)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (Tier 0 report, read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    _give_back "$OUTFILE"
    progress "report written: $OUTFILE"
fi
exit 0
