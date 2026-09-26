#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM PHP agent collector
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap PHP-agent developer repeatedly asks a
# field engineer for, from the host or container where the PHP application (and
# the whatap-php agent) runs. Derived from an exhaustive review of #ask-dev-apm
# support threads (2025-06 .. 2026-08) and from the shipped whatap-php package
# itself (rpm 2.14-2 and the Alpine tarball: install.sh, whatap-php service
# wrapper, whatap-php.service, template.ini, modules/, whatap_php, whatap.so).
#
# The PHP agent has two halves that are installed and configured separately:
#   * the tracer  — a Zend extension (whatap.so) loaded into every Apache /
#     PHP-FPM / CLI worker, built per PHP API version (whatap[_zts]_<API>.so),
#   * the agent   — a Go process (whatap_php, or whatap_php_static on musl)
#     that receives from the tracer over UDP and talks to the collection server.
# install.sh resolves the environment once (php binary, extension_dir, ini scan
# dir) and writes the result into the service files. Almost every support case
# is about a mismatch between what it resolved then and what runs now.
#
# Recurring field questions this report answers with facts:
#   * Which PHP binaries/SAPIs exist, at which version, PHP API and thread
#     safety (NTS/ZTS) — and which extension_dir and ini files does each use?
#   * On a host carrying **several PHP versions** (Sury/ondrej, Remi, SCL,
#     cPanel EasyApache, Plesk, CloudLinux alt-php, LiteSpeed lsphp, or a
#     source build next to the distro one): which of them is the tracer bound
#     to, which one serves the traffic, and where does `php` on PATH point?
#   * Is whatap.so present in that extension_dir, and which
#     whatap[_zts]_<API>.so does the symlink actually point to?
#   * Is the extension actually mapped into the live Apache/PHP-FPM workers, or
#     only configured on disk? Does starting PHP emit a load warning?
#   * Where did install.sh put whatap.ini, and does that ini tree belong to the
#     SAPI that serves traffic (cli vs fpm vs apache2 trees differ)?
#   * What do whatap.ini / the [whatap] block in php.ini actually contain
#     (accesskey, server host, app_name, app_process_name, hook options)?
#   * Is whatap_php running, from which home, with which WHATAP_* environment
#     (WHATAP_CONFIG_HOME is written by install.sh into the unit/init script)?
#   * Is the UDP channel (net_udp_port, default 6600) bound, is there a TCP
#     session to the collection server, and does the SysV shared memory /
#     semaphore pair the agent uses exist?
#   * Which application server model runs the app (Apache prefork/worker/event,
#     PHP-FPM pools, or a persistent-worker runtime such as Swoole/Octane,
#     RoadRunner, FrankenPHP)?
#   * What do the agent logs (whatap-boot-*.log, whatap-install-*.log) and the
#     web server error log (WA*-coded lines from whatap.so) say?
#
# The PHP binaries found are executed read-only, with -v / -m / -i only
# — the same calls the vendor installer makes. No application code is run. The
# agent binary is only ever executed with its `version` argument (running it
# bare would start an agent).
#
# Rules: ../../../CONTRACT.md, ../../../docs/collector-engineering.md; no set -e.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmphp"
# 0.6.0  Section 4 reuses the `php-fpm -v` of section 3 also when section 3
#        ran it under a name that resolves to the PATH php-fpm (a running
#        php-fpm8.2 found before the php-fpm link to it); the machine arch is
#        taken from the one `uname -srm` (no second `uname -m`).
# 0.5.4  _proc_env compares the variable name literally; PATH lookups read
#        their answer back from a file instead of a second lookup in a $(...).
# 0.5.3  "ini directory trees present" prints "(no whatap entry)" for a tree
#        without one (the column was blank) and names an unreadable tree;
#        section 4 reuses the `php-fpm -v` section 3 ran on the same binary.
# 0.5.2  A directory this uid can read but not enter lists its names again
#        (the refactor's _names dropped them; ls did not).
# 0.5.1  Readability refactor; report unchanged.
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
Collects PHP APM agent facts from the host or container where the PHP
application runs (run it inside the container for containerized apps, e.g.
kubectl exec / docker exec, as root or as the web server user where possible).

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

# ---- reasoned-absence helpers -------------------------------------------------
_errfile=""
_infofile=""
CMD_TIMEOUT="${CMD_TIMEOUT:-15}"
# Call after _run_init: the error and php -i files live in the run's private directory.
_init_probe() { _errfile="$(_tmp probe.err)"; _infofile="$(_tmp probe.info)"; }

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

# _names DIR -> the names in DIR, as `ls DIR` lists them (no dot files, sorted).
# Only an unmatched glob is skipped: in a DIR this uid can read but not enter,
# -e fails on every entry although ls lists them all.
_names() {
    local n
    for n in "$1"/*; do
        [ "$n" = "$1/*" ] && [ ! -e "$n" ] && [ ! -L "$n" ] && continue
        printf '%s\n' "${n##*/}"
    done
    return 0
}

# _file_lines head|tail "label" PATH CAP -> the first or last CAP lines of the
# file, verbatim, or a reason. Configuration is dumped as is, never masked (the
# collector README, "What the report can contain").
_file_lines() {
    local how="$1" label="$2" path="$3" cap="$4" w=first total
    [ "$how" = tail ] && w=last
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label ($w $cap of ${total:-?} lines):"
    "$how" -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# conf_bytes "label" PATH -> byte-level facts a plain `cat` hides: total bytes
# and CR (\r, 0x0D) count. Windows-edited ini files reach Linux hosts through
# support cases; the reader compares these numbers against the dumped text.
conf_bytes() {
    local label="$1" path="$2" sz cr
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
    cr="$(tr -dc '\r' < "$path" 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}

# file_facts "label" PATH -> ls -l line, size, mtime and (when available) the
# SHA-256 of a binary artifact, so two hosts can be compared byte-for-byte.
file_facts() {
    local label="$1" path="$2" sum=""
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    fact "$label:"
    printf '        %s\n' "$(ls -ld "$path" 2>/dev/null)"
    if [ -f "$path" ]; then
        if have sha256sum; then sum="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
        elif have shasum; then sum="$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')"; fi
        if [ -n "$sum" ]; then printf '        sha256: %s\n' "$sum"
        else printf '        sha256: n/a (command not found: sha256sum, shasum)\n'; fi
    fi
    if [ -L "$path" ]; then
        printf '        symlink target: %s\n' "$(readlink "$path" 2>/dev/null)"
        printf '        resolves to: %s\n' "$(readlink -f "$path" 2>/dev/null || echo 'n/a (unresolvable)')"
    fi
}

# php_run "label" PHP_BIN [ARGS...] -> run a PHP binary with read-only flags
# under _bounded; stdout becomes facts and any stderr is emitted as its own
# labeled block (a PHP startup warning about the extension lands there). The
# output stays in _php_out for the caller.
_php_out=""
php_run() {
    local label="$1" php="$2"; shift 2
    _php_out="" _php_rc="" _php_err=""
    [ -x "$php" ] || { fact "$label: n/a (not executable: $php)"; return; }
    local out rc err
    out="$(_bounded "$php" "$@" 2>"$_errfile")"; rc=$?
    _php_out="$out"
    err="$(head -c 2000 "$_errfile" 2>/dev/null)"
    _php_rc="$rc" _php_err="$err"
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    if [ -n "$out" ]; then _emit_labeled "$label" "$out"
    elif [ "$rc" -ne 0 ]; then fact "$label: n/a ($(_classify_err))"
    else fact "$label: n/a (empty output)"; fi
    [ -n "$err" ] && _emit_labeled "$label (stderr)" "$err"
    return 0
}

# php_info PHP_BIN -> capture `php -i` into $_infofile (0 on success). Used by
# php_info_grep so one execution serves every extracted field.
php_info() {
    local php="$1"
    : > "$_infofile" 2>/dev/null
    [ -x "$php" ] || return 1
    _bounded "$php" -i > "$_infofile" 2>"$_errfile"
    [ -s "$_infofile" ] || return 1
    return 0
}

# php_info_grep "label" PATTERN [CAP] -> lines of the captured `php -i` output
# matching PATTERN, or a reason.
php_info_grep() {
    local label="$1" pat="$2" cap="${3:-20}" out
    out="$(grep -E "$pat" "$_infofile" 2>/dev/null | head -n "$cap")"
    [ -z "$out" ] && { fact "$label: n/a (no matching line in php -i output)"; return; }
    _emit_labeled "$label" "$out"
}

# php_info_block "label" START_PATTERN [CAP] -> a multi-line, comma-continued
# block of the captured `php -i` output (the "Additional .ini files parsed"
# list wraps across lines: every line but the last ends with a comma).
php_info_block() {
    local label="$1" pat="$2" cap="${3:-40}" out
    out="$(awk -v p="$pat" -v cap="$cap" '
        $0 ~ p {inb=1}
        inb {print; n++; if (n >= cap || $0 !~ /,[[:space:]]*$/) exit}
    ' "$_infofile" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (no matching line in php -i output)"; return; }
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
#   D_PHP_BINS    distinct php / php-fpm / php-cgi binaries (PATH, globs, procs),
#                 newline-joined
#   D_PHP_FACTS   one record per detailed runtime, filled in by section 3
#   D_AGENT_PIDS  pids of the Go agent (comm: whatap_php / whatap_php_stat*)
#   D_WEB_PIDS    pids of httpd / apache2 / php-fpm / php-cgi / php / lsphp
#                 processes (by comm, argv0 or exe)
#   D_ALT_PIDS    pids of persistent-worker PHP runtimes (swoole/octane/rr/...)
#   D_HOMES       agent home candidates with their discovery source
#   D_SERVICE_FILES  service/unit/init files that carry the resolved install env
#   D_EXT_DIRS    extension_dir values seen (php -i, service files)
#   D_INI_FILES   whatap ini files found on disk
#   D_UNREAD      pids of whatap_php processes whose environ, cwd or exe this uid
#                 could not read (their home is unknown, not absent)
#   D_HIDEPID     non-empty when /proc hides other users' processes from this uid
#   D_PHPI_FAIL   php binaries whose `php -i` did not run (their ini scan dir and
#                 extension_dir are unknown), filled in by section 3
#   D_MAPS_UNREAD pids whose /proc/<pid>/maps this uid could not read, filled
#                 in by section 6
D_PHP_BINS=""
D_PHP_KEYS=""
D_PHP_FACTS=""      # newline-joined "bin|version|sapi|api|threadsafety|extdir|scandir|loaded|loadmsg"
D_AGENT_PIDS=""
D_WEB_PIDS=""
D_ALT_PIDS=""
D_HOMES=""
D_SERVICE_FILES=""
D_EXT_DIRS=""
D_INI_FILES=""
D_UNREAD=""
D_HIDEPID=""
D_PHPI_FAIL=""
D_MAPS_UNREAD=""
D_DIR_UNREAD=""     # ini scan dirs / extension_dirs that exist but cannot be listed
D_PHP_LIVE=""       # "exe|pid" of running php processes, newline-joined
D_SCAN_UNRES=""     # relative ini scan dir entries no process cwd resolved
# PHP binaries detailed per run. APM_INTERP_CAP in the environment raises it
# (the CLI flags are a shared block).
D_PHP_CAP=10 D_CAP_NOTE=""   # set in discover
D_PHPINI_WHATAP=""  # php.ini files carrying whatap lines, filled in by section 6
D_DEFAULT_HOME="/usr/whatap/php"

# resolve_fs PATH -> a readable filesystem view of PATH: the path itself if it
# exists here, otherwise the same path seen through the root of a discovered
# agent/web process (/proc/<pid>/root<PATH>). Empty if neither is visible. This
# lets the collector run from an ephemeral debug container and still read the
# target's files.
resolve_fs() {
    local p="$1" pid
    # a relative path is never read against the collector's own cwd
    case "$p" in /*) ;; *) return 1 ;; esac
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    for pid in $D_AGENT_PIDS $D_WEB_PIDS $D_ALT_PIDS; do
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

_add_svc() {  # _add_svc PATH
    local p="$1"
    [ -f "$p" ] || return
    case "$D_SERVICE_FILES" in *"|$p|"*) return ;; esac
    D_SERVICE_FILES="$D_SERVICE_FILES|$p|"
}

_add_ext_dir() {  # _add_ext_dir DIR SOURCE
    local d="$1" s="$2"
    [ -n "$d" ] || return
    case "$d" in /*) ;; *) return ;; esac
    case "$d" in *"|"*|*"$_nl"*) D_ODD="$D_ODD \"$(_quote_nl "$d")\""; return ;; esac
    case "$_nl$D_EXT_DIRS" in *"$_nl$d|"*) return ;; esac
    if [ -n "$D_EXT_DIRS" ]; then D_EXT_DIRS="$D_EXT_DIRS$_nl$d|$s"; else D_EXT_DIRS="$d|$s"; fi
}

# _add_ini PATH -> record a whatap ini file. PATH may be seen through a process
# root; the file that exists is the one recorded.
_add_ini() {
    local p
    case "$1" in *"|"*|*"$_nl"*) D_ODD="$D_ODD \"$(_quote_nl "$1")\""; return ;; esac
    p="$(resolve_fs "$1")" || return
    [ -f "$p" ] || return
    case "$D_INI_FILES" in *"|$p|"*) return ;; esac
    D_INI_FILES="$D_INI_FILES|$p|"
}

# Dedup key for PHP binaries: the resolved target. Distinct names that resolve
# to one binary (php / php8.2 / php-cli) are one runtime; php-fpm and php-cgi
# are separate binaries and stay separate entries.
_add_php() {
    local p="$1" k
    [ -n "$p" ] || return
    case "$p" in *"|"*|*"$_nl"*) D_ODD="$D_ODD \"$(_quote_nl "$p")\""; return ;; esac
    [ -x "$p" ] || return
    case "$p" in *-config|*.ini|*.conf) return ;; esac
    k="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_PHP_KEYS" in *"|$k|"*) return ;; esac
    D_PHP_KEYS="$D_PHP_KEYS|$k|"
    if [ -n "$D_PHP_BINS" ]; then D_PHP_BINS="$D_PHP_BINS$_nl$p"; else D_PHP_BINS="$p"; fi
}

# _is_php NAME -> success when NAME is a PHP binary's file name
_is_php() { case "$1" in php|php[0-9]*|php-*|php5-*|lsphp*) return 0 ;; esac; return 1; }

# _proc_env PID NAME -> value of NAME= in the process environ (empty if none).
# The braces put the input redirection inside the silenced subshell: a process
# that exits mid-scan would otherwise make the SHELL print "No such file".
# NAME is compared literally; the first entry wins.
_proc_env() {
    { tr '\0' '\n' < "/proc/$1/environ" | _K="$2" awk 'BEGIN { k = ENVIRON["_K"] "=" }
          index($0, k) == 1 { print substr($0, length(k) + 1); exit }' ; } 2>/dev/null
}

# _which NAME -> sets _wp to the path `command -v NAME` prints, empty when
# there is none. The path is read back from a file under the run's directory,
# not captured by a $(...); without that file it is looked up again.
_which() {
    _wp=""
    if [ -n "$_tmp_dir" ] && command -v "$1" > "$_tmp_dir/cmdv" 2>/dev/null && IFS= read -r _wp < "$_tmp_dir/cmdv"; then
        return 0
    fi
    command -v "$1" >/dev/null 2>&1 && _wp="$(command -v "$1" 2>/dev/null)"
    return 0
}

_proc_cmd() {
    { tr '\0' ' ' < "/proc/$1/cmdline" | cut -c1-300 ; } 2>/dev/null
}

# _link_target /proc/<pid>/{exe,cwd} -> the resolved target, but only when it
# resolves to something that exists and is not the link path itself. A zombie's
# /proc/<pid>/exe resolves to the link path on some readlink implementations,
# which would otherwise be reported as a real binary (and its dirname taken for
# an agent home).
_link_target() {
    local l="$1" t
    t="$(readlink -f "$l" 2>/dev/null)" || return 1
    [ -n "$t" ] || return 1
    [ "$t" = "$l" ] && return 1
    [ -e "$t" ] || return 1
    printf '%s\n' "$t"
}

# _proc_start PID -> process start time, from ps when it supports lstart,
# otherwise from the timestamp of the /proc/<pid> directory.
_proc_start() {
    local s
    s="$( { ps -o lstart= -p "$1" ; } 2>/dev/null | head -n1 )"
    [ -n "$s" ] || s="$( { ls -ld "/proc/$1" ; } 2>/dev/null | awk '{print $6, $7, $8}')"
    [ -n "$s" ] || s="n/a (ps lstart unsupported and /proc/$1 unreadable)"
    printf '%s\n' "$s"
}

discover() {
    progress "discovery: php binaries, web/app processes, agent home, ini files"
    _cap_from APM_INTERP_CAP "${APM_INTERP_CAP:-}" 10; D_PHP_CAP="$_cap" D_CAP_NOTE="$_cap_note"
    local c p pid comm exe a0 cmd cwd envh d _php _alt

    case "$(id -u 2>/dev/null)" in
        0) ;;
        *) grep -qE '^[^ ]+ /proc proc [^ ]*hidepid=([12]|invisible|noaccess)' /proc/mounts 2>/dev/null \
               && D_HIDEPID="hidepid is set on /proc: other users' processes are not listed to uid $(id -u 2>/dev/null)" ;;
    esac

    # Process scan over a table read once for every pid. A PHP process is
    # matched by comm, argv0 or exe: a script started from `#!/usr/bin/php`
    # carries the script's name as comm and the interpreter as argv0.
    while IFS="$_us" read -r pid comm exe a0 cmd; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$$" ] && continue
        # /proc/<pid>/comm is capped at 15 characters, so the musl build
        # whatap_php_static appears as whatap_php_stat
        case "$comm" in whatap_php*) D_AGENT_PIDS="$D_AGENT_PIDS $pid"; continue ;; esac
        # persistent-worker runtimes are matched on the executable (comm,
        # argv0 or exe), and their markers only on the command line of a PHP
        # executable, so an editor or `tail` naming swoole is not one
        _alt=0
        case "$comm|${a0##*/}|${exe##*/}" in
            frankenphp*|*"|frankenphp"*|rr\|*|*\|rr\|*|*\|rr|roadrunner*|*"|roadrunner"*) _alt=1 ;;
        esac
        [ "$_alt" = 1 ] && { D_ALT_PIDS="$D_ALT_PIDS $pid"; continue; }
        _php=0
        _is_php "$comm" && _php=1
        _is_php "${a0##*/}" && _php=1
        _is_php "${exe##*/}" && _php=1
        case "$comm" in httpd*|apache2*|lighttpd*) _php=2 ;; esac
        [ "$_php" = 0 ] && continue
        D_WEB_PIDS="$D_WEB_PIDS $pid"
        # only PHP binaries join the runtime list — an httpd/apache2 binary
        # carries PHP as a module and cannot be run with -i
        _is_php "${exe##*/}" && { _add_php "$exe"; D_PHP_LIVE="$D_PHP_LIVE$exe|$pid$_nl"; }
        [ "$_php" = 1 ] || continue
        case "$cmd" in
            *octane*|*swoole*|*roadrunner*|*workerman*|*"php-pm"*|*"artisan queue"*|*"artisan horizon"*)
                D_ALT_PIDS="$D_ALT_PIDS $pid" ;;
        esac
    done <<EOF
$(_proc_table)
EOF

    # php binaries on PATH and in the usual install locations (shallow globs
    # only — no directory walk)
    for c in php php-fpm php-cgi php5 php5-fpm php-zts zts-php lsphp; do
        _which "$c"; p="$_wp"
        [ -n "$p" ] && _add_php "$p"
    done
    # Several PHP versions on one host is the normal case, not the exception,
    # and each distribution/panel keeps them in its own tree. Enumerate the
    # known shapes (shallow globs, no directory walk); anything else still
    # arrives through the process scan and the PATH lookup above.
    for p in /usr/bin/php /usr/bin/php[0-9]* /usr/sbin/php-fpm* /usr/bin/php-fpm* \
             /usr/bin/php-cgi* /usr/local/bin/php /usr/local/bin/php[0-9]* \
             /usr/local/sbin/php-fpm* /usr/local/php*/bin/php /usr/local/php*/sbin/php-fpm \
             /opt/*/bin/php /opt/*/sbin/php-fpm \
             /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
             /opt/rh/*php*/root/usr/bin/php /opt/rh/*php*/root/usr/sbin/php-fpm \
             /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/sbin/php-fpm \
             /opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm \
             /opt/alt/php*/usr/bin/php /opt/alt/php*/usr/sbin/php-fpm \
             /usr/local/lsws/lsphp*/bin/php /usr/local/lsws/lsphp*/bin/lsphp; do
        [ -x "$p" ] && [ -f "$p" ] && _add_php "$p"
    done

    # agent home candidates
    [ -n "${WHATAP_HOME:-}" ] && _home_from_self "$WHATAP_HOME" WHATAP_HOME
    [ -d "$D_DEFAULT_HOME" ] && _add_home "$D_DEFAULT_HOME" "package install path (present on disk)"
    for pid in $D_AGENT_PIDS; do
        cwd="$(_link_target "/proc/$pid/cwd")"
        [ -n "$cwd" ] && [ -d "$cwd" ] && _add_home "$cwd" "cwd of whatap_php pid $pid"
        [ -r "/proc/$pid/environ" ] || { [ -e "/proc/$pid/environ" ] && D_UNREAD="$D_UNREAD $pid"; }
        envh="$(_proc_env "$pid" WHATAP_HOME)"
        [ -n "$envh" ] && _home_from_pid "$pid" "$envh" "environ of whatap_php pid $pid"
        exe="$(_link_target "/proc/$pid/exe")"
        if [ -n "$exe" ] && [ -f "$exe" ]; then _add_home "${exe%/*}" "exe path of whatap_php pid $pid"
        elif [ -z "$cwd" ] && [ -e "/proc/$pid" ]; then D_UNREAD="$D_UNREAD $pid"; fi
    done
    D_UNREAD="$(printf '%s\n' $D_UNREAD | sort -un | tr '\n' ' ' | sed 's/ $//')"

    # service / unit / init files: install.sh writes the resolved php
    # environment into every one of them that exists
    _add_svc "$D_DEFAULT_HOME/whatap-php"
    _add_svc "/etc/init.d/whatap-php"
    _add_svc "/usr/lib/systemd/system/whatap-php.service"
    _add_svc "/lib/systemd/system/whatap-php.service"
    _add_svc "/etc/systemd/system/whatap-php.service"
    _add_svc "/etc/rc.d/whatap_php"
    while IFS='|' read -r d _s; do
        [ -n "$d" ] || continue
        p="$(resolve_fs "$d/whatap-php")" && _add_svc "$p"
    done <<EOF
$D_HOMES
EOF

    # extension dirs declared by the service files
    while IFS= read -r d; do
        [ -n "$d" ] && _add_ext_dir "$d" "WHATAP_PHP_EXT_HOME in a service file"
    done <<EOF
$(printf '%s\n' "$D_SERVICE_FILES" | tr '|' '\n' | grep -v '^$' | while IFS= read -r p; do
    grep -h 'WHATAP_PHP_EXT_HOME=' "$p" 2>/dev/null | sed 's/.*WHATAP_PHP_EXT_HOME=//; s/"$//'
done)
EOF

    # whatap ini files: the installer copies template.ini to
    # <ini scan dir>/whatap.ini, and falls back to the agent home when PHP
    # reports no scan dir. Shallow globs over the known ini tree shapes
    # (RHEL, Debian/Ubuntu per-version+per-SAPI, Alpine, source builds).
    for p in /etc/php.d/whatap.ini /etc/php/conf.d/whatap.ini \
             /etc/php[0-9]*/conf.d/whatap.ini /etc/php[0-9]*/php.d/whatap.ini \
             /etc/php/*/mods-available/whatap.ini /etc/php/*/*/conf.d/*whatap.ini \
             /etc/php/*/conf.d/*whatap.ini \
             /usr/local/etc/php/conf.d/whatap.ini /usr/local/etc/php/conf.d/*whatap.ini \
             /usr/local/lib/php.d/whatap.ini \
             /opt/remi/php*/root/etc/php.d/whatap.ini /etc/opt/remi/php*/php.d/whatap.ini \
             /opt/rh/*php*/root/etc/php.d/whatap.ini /etc/opt/rh/*php*/php.d/whatap.ini \
             /opt/cpanel/ea-php*/root/etc/php.d/whatap.ini \
             /opt/plesk/php/*/etc/php.d/whatap.ini \
             /opt/alt/php*/etc/php.d/whatap.ini \
             /usr/local/lsws/lsphp*/etc/php.d/whatap.ini /usr/local/lsws/lsphp*/etc/php/*/mods-available/whatap.ini \
             "$D_DEFAULT_HOME"/whatap.ini; do
        _add_ini "$p"
    done
    while IFS='|' read -r d _s; do
        [ -n "$d" ] && _add_ini "$d/whatap.ini"
    done <<EOF
$D_HOMES
EOF
}

# _scan_gaps -> the inputs of the installation search this run could not read,
# as one phrase; empty when every one was read
# _scan_gaps [maps] -> as above; with "maps", also the web/php processes whose
# maps a non-root run could not read. maps answer whether the module is loaded,
# not where an ini is, and a root run that still cannot read them has no other
# way to run, so they never block conf and never block a root run.
_scan_gaps() {
    local n g=""
    if [ -n "$D_UNREAD" ]; then
        n="$(echo $D_UNREAD | wc -w | tr -d ' ')"
        g="environ/cwd/exe of $n whatap_php process(es) not readable by uid $(id -u 2>/dev/null || echo '?') (pids: $(echo $D_UNREAD | cut -d' ' -f1-10))"
    fi
    if [ "${1:-}" = maps ] && [ -n "$D_MAPS_UNREAD" ] && [ -n "$PRIV_GAP" ]; then
        n="$(echo $D_MAPS_UNREAD | wc -w | tr -d ' ')"
        g="${g:+$g; }/proc/<pid>/maps of $n web/php process(es) not readable by uid $(id -u 2>/dev/null || echo '?') (pids: $(echo $D_MAPS_UNREAD | cut -d' ' -f1-10))"
    fi
    [ -n "$D_HIDEPID" ] && g="${g:+$g; }$D_HIDEPID"
    [ -n "$D_DIR_UNREAD" ] && g="${g:+$g; }directory not readable by uid $(id -u 2>/dev/null || echo '?'):$D_DIR_UNREAD"
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

# _net_ports -> sets _udp_ports / _tcp_ports to the ports the readable whatap
# ini files name, or 6600 when none names one, and states which it used
_net_ports() {
    local f
    set --
    while IFS= read -r f; do [ -n "$f" ] && [ -r "$f" ] && set -- "$@" "$f"; done <<EOF
$(printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u)
EOF
    # the 66xx range is always matched: an agent on a port no readable ini
    # names (a non-root run, a non-default port) still shows
    _pl="" _plab="" _pbad=""
    _ports_add "whatap.net_udp_port in $# readable whatap ini file(s)" <<EOF
$(_conf_vals whatap.net_udp_port "$@")
EOF
    # shellcheck disable=SC2086  # validated port numbers only
    _pl="$(_uniq_ports $_pl)"
    _udp_ports="66[0-9][0-9] $_pl" _udp_label="66xx${_pl:+ $_pl}"
    fact "udp port filter: 66xx (range)$_plab"
    [ -n "$_pbad" ] && fact "udp port values ignored (not a port 1..65535): $_pbad"
    _pl="" _plab="" _pbad=""
    _ports_add "whatap.server.port in $# readable whatap ini file(s)" <<EOF
$(_conf_vals whatap.server.port "$@")
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

# _nonblank_head FILE N -> FILE without blank and ;-comment lines, first N;
# no such line is an empty answer, not a failure
_nonblank_head() {
    grep -vE '^[[:space:]]*(;|$)' "$1" > "$(_tmp nb.out)"
    [ $? -le 1 ] || return 2
    head -n "$2" "$(_tmp nb.out)"
}

# _mods_count HOME / _mods_names HOME -> the shipped tracer modules per arch
_mods_count() {
    local d
    for d in "$1"/modules/*; do
        [ -d "$d" ] && printf '%s: %s files\n' "${d##*/}" "$(ls "$d" 2>/dev/null | wc -l | tr -d ' ')"
    done
}
_mods_names() { ls "$1"/modules/*/ 2>/dev/null | tr '\n' ' ' | cut -c1-1200; }

# _resolve_goals -> resolve `agent` and `conf` once. An absence is `na` only
# when every input behind it was read: an unreadable environ/cwd/exe or maps,
# hidepid, a blocked home path or a php -i that did not run makes it `missed`.
# conf is the whatap ini the tracer and the agent both read (section 7), not a
# whatap.conf.
_resolve_goals() {
    local h src fs why homes_seen=0 so=0 blocked="" absent="" unres="" gaps agaps ph aph pr _t edu="" d p inis=0 iniread=0 iniblk=""
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
    done <<EOF
$D_HOMES
EOF
    while IFS='|' read -r d src; do
        [ -n "$d" ] || continue
        fs="$(resolve_fs "$d")" || continue
        if [ ! -x "$fs" ]; then
            case " $edu " in *" $fs "*) ;; *) edu="$edu $fs" ;; esac
            continue
        fi
        [ -e "$fs/whatap.so" ] && so=1
    done <<EOF
$D_EXT_DIRS
EOF
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        inis=$((inis + 1))
        if [ -r "$p" ]; then iniread=1; else iniblk="$iniblk; $p (permission denied)"; fi
    done <<EOF
$(printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u)
EOF
    blocked="${blocked#; }" absent="${absent#; }" iniblk="${iniblk#; }"
    gaps="$(_scan_gaps)" agaps="$(_scan_gaps maps)"
    unres="${unres#; }"
    [ -n "$unres" ] && gaps="${gaps:+$gaps; }home candidate(s) not resolved: $unres"
    [ -n "$unres" ] && agaps="${agaps:+$agaps; }home candidate(s) not resolved: $unres"
    ph=""; [ -n "$blocked$iniblk$D_UNREAD$D_HIDEPID$D_DIR_UNREAD" ] && ph="$(_priv_hint)"
    [ -n "$edu" ] && agaps="${agaps:+$agaps; }extension_dir not readable by uid $(id -u 2>/dev/null || echo '?'):$edu"
    aph="$ph"; [ -n "$D_MAPS_UNREAD$edu" ] && aph="$(_priv_hint)"
    [ -n "$D_PHPI_FAIL" ] && gaps="${gaps:+$gaps; }php -i did not run for:$D_PHPI_FAIL" \
        && agaps="${agaps:+$agaps; }php -i did not run for:$D_PHPI_FAIL"
    [ -n "$D_SCAN_UNRES" ] && gaps="${gaps:+$gaps; }relative ini scan dir or parsed ini, not resolved (no readable cwd of a process of that binary):$D_SCAN_UNRES"
    if [ -n "$_php_unprobed_live" ]; then
        _t="$(printf '%s' "$_php_unprobed_live" | grep -c .) php binary(ies) of running processes not probed (cap $D_PHP_CAP; set APM_INTERP_CAP=<n> in the environment to raise it): $(printf '%s' "$_php_unprobed_live" | tr '\n' ' ')"
        gaps="${gaps:+$gaps; }$_t" agaps="${agaps:+$agaps; }$_t"
    fi
    [ -n "$D_ODD" ] && gaps="${gaps:+$gaps; }path(s) with a newline or '|', not followed:$D_ODD" \
        && agaps="${agaps:+$agaps; }path(s) with a newline or '|', not followed:$D_ODD"
    if [ "${_php_probed:-0}" -lt "${_php_total:-0}" ]; then pr="${_php_probed:-0} of $_php_total php runtime(s) probed with php -i (cap $D_PHP_CAP; the others run no live process)"
    else pr="all ${_php_total:-0} php runtime(s) probed with php -i"; fi

    if [ "$homes_seen" = 1 ] || [ "$so" = 1 ] || [ "$inis" -gt 0 ] || [ -n "$D_PHPINI_WHATAP" ] \
       || [ -n "$D_SERVICE_FILES" ] || [ -n "$D_AGENT_PIDS" ]; then
        got agent
    elif [ -n "$blocked" ] || [ -n "$agaps" ]; then
        missed agent "no whatap home, whatap.so, whatap ini or service file found in what this uid could read: ${blocked:+$blocked; }$agaps$aph"
    else
        na agent "no whatap home, whatap.so, whatap ini, service file or whatap_php process in the collector env, $D_DEFAULT_HOME, the known ini and unit paths, $pr, or the maps of $(echo $D_WEB_PIDS $D_ALT_PIDS | wc -w | tr -d ' ') web/php process(es)${D_MAPS_UNREAD:+ ($(echo $D_MAPS_UNREAD | wc -w | tr -d ' ') of them with maps not readable by uid $(id -u 2>/dev/null || echo '?'))}${absent:+; home candidate(s): $absent}"
    fi

    if [ "$iniread" = 1 ] || [ -n "$D_PHPINI_WHATAP" ]; then got conf
    elif [ -n "$iniblk" ]; then missed conf "whatap ini not readable: $iniblk$ph"
    elif [ -n "$gaps" ]; then missed conf "no whatap ini found in what this uid could read: $gaps$ph"
    else na conf "no whatap ini in the known ini locations, the ini scan dirs ($pr), the agent home(s), or a php.ini carrying whatap lines"; fi
}

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    goal agent "whatap-php agent installation"
    goal conf  "agent configuration"

    _rep_env
    discover
    _rep_host
    _rep_runtimes
    _rep_web
    _rep_install
    _rep_binding
    _rep_conf
    _rep_agent
    _rep_logs
    _rep_k8s

    # Resolved here, not at the point of use: the config dumps above run inside
    # `| while` pipelines, and an assignment made in a subshell does not survive.
    _resolve_goals
    emit_status
    emit_footer
}

# [1] capability preamble: every downstream "command not found" is
# pre-explained here.
_rep_env() {
    section "Collection environment"
    if [ -n "${BASH_VERSION:-}" ]; then fact "shell: bash $BASH_VERSION"
    else fact "shell: POSIX sh (non-bash)"; fi
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in php php-fpm apachectl httpd apache2 nginx ipcs ss netstat systemctl rpm dpkg apk readlink timeout stat awk tr sha256sum; do
        _which "$t"
        if [ -n "$_wp" ]; then printf '        %-12s present (%s)\n' "$t" "$_wp"
        else printf '        %-12s absent\n' "$t"; fi
    done
}

# [2] host / platform
_rep_host() {
    section "Host / platform"
    # the machine is the last field of `uname -srm` (uname prints the fields
    # in its own order, and a kernel release has no blank)
    _k="$(probe "kernel" uname -srm)"
    printf '%s\n' "$_k"
    case "$_k" in
        "    kernel: n/a ("*) fact "machine arch: n/a (${_k#    kernel: n/a (}" ;;
        "    kernel: "*" "*)  fact "machine arch: ${_k##* }" ;;
        "    kernel (exit "*" "*)
                             _e="${_k#    kernel (exit }"; fact "machine arch (exit ${_e%%)*}): ${_k##* }" ;;
        *)                   fact "machine arch: n/a (no machine field in the uname -srm output)" ;;
    esac
    read_proc "os-release" /etc/os-release
    if have ldd; then probe "libc" sh -c "ldd --version 2>&1 | head -n 1"
    else fact "libc: n/a (command not found: ldd)"; fi
    probe "cpu count (nproc)" nproc
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
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
    probe "local time" date
    probe "utc time" date -u
    probe "pid 1 command" sh -c "tr '\0' ' ' < /proc/1/cmdline | cut -c1-160"
}

# [3] PHP runtimes: one block per distinct binary. `php -i` is executed
# once per binary and every field below is extracted from that capture.
_rep_runtimes() {
    section "PHP runtimes and SAPIs"
    fact "php binaries discovered: $(printf '%s\n' "$D_PHP_BINS" | grep -c .)"
    if [ -z "$D_PHP_BINS" ]; then
        fact "   none on PATH, in the known per-version install paths (distro, Sury, Remi, SCL, cPanel EA, Plesk, alt-php, LiteSpeed, source builds), or among running processes"
    fi
    local _n=0 php _mods=""
    _php_probed=0 _php_unprobed_live=""
    # the file the PATH php-fpm resolves to, for section 4's reuse of its -v
    _fpm_path_key=""
    _which php-fpm
    [ -n "$_wp" ] && _fpm_path_key="$(readlink -f "$_wp" 2>/dev/null || echo "$_wp")"
    _php_total="$(printf '%s\n' "$D_PHP_BINS" | grep -c .)"
    [ -n "$D_CAP_NOTE" ] && fact "$D_CAP_NOTE"
    # newline-split, no globbing; fd 9 so a probe reading stdin cannot eat it
    while IFS= read -r php <&9; do
        [ -n "$php" ] || continue
        _n=$((_n + 1))
        if [ "$_n" -gt "$D_PHP_CAP" ]; then
            fact "-- more php binaries found but not detailed (cap: $D_PHP_CAP): $(printf '%s\n' "$D_PHP_BINS" | tail -n +"$_n" | tr '\n' ' ')"
            # one that runs a live process is an input this run did not read
            while IFS= read -r _l; do
                [ -n "$_l" ] || continue
                case "$_nl$D_PHP_LIVE" in *"$_nl$_l|"*) _php_unprobed_live="$_php_unprobed_live$_l$_nl" ;; esac
            done <<EOF
$(printf '%s\n' "$D_PHP_BINS" | tail -n +"$_n")
EOF
            break
        fi
        _php_probed=$_n
        fact "-- php binary: $php"
        fact "   resolves to: $(readlink -f "$php" 2>/dev/null || echo "$php")"
        php_run "   version" "$php" -v
        # the php-fpm on PATH run here with -v, under this name or another
        # that resolves to the same file (a running /usr/sbin/php-fpm8.2 is
        # listed first, the PATH php-fpm linking to it is folded into it):
        # section 4 shows the same output instead of running it again, when it
        # finished in time and wrote nothing to stderr (section 4 shows stdout
        # and stderr together)
        case "$php" in
            */php-fpm*)
                if [ -n "$_php_rc" ] && [ "$_php_rc" != 124 ] && [ -z "$_php_err" ] \
                    && [ -n "$_fpm_path_key" ] \
                    && [ "$(readlink -f "$php" 2>/dev/null || echo "$php")" = "$_fpm_path_key" ]; then
                    _fpm_v_seen=1 _fpm_v_out="$_php_out"
                fi ;;
        esac
        if php_info "$php"; then
            php_info_grep "   php version / system" '^(PHP Version|System) =>' 4
            php_info_grep "   SAPI" '^Server API =>' 2
            php_info_grep "   ini paths" '^(Configuration File \(php\.ini\) Path|Loaded Configuration File|Scan this dir for additional \.ini files) =>' 4
            php_info_block "   additional ini files parsed" '^Additional \.ini files parsed =>' 40
            php_info_grep "   php api / build" '^(PHP API|PHP Extension|Zend Extension|Zend Extension Build|PHP Extension Build|Debug Build|Thread Safety|Zend Signal Handling) =>' 10
            php_info_grep "   extension_dir" '^extension_dir =>' 2
            php_info_grep "   opcache" '^opcache\.(enable|enable_cli|jit|jit_buffer_size|preload) =>' 8
            php_info_grep "   whatap directives visible to this binary (local => master)" '^whatap\.' 80
            # everything the binding section needs, taken from this one capture
            # (a host with several PHP versions gets one record per version)
            _f_ver="$(grep '^PHP Version =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//')"
            _f_sapi="$(grep '^Server API =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//')"
            _f_api="$(grep '^PHP API =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//')"
            _f_ts="$(grep '^Thread Safety =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//')"
            _f_ed="$(grep '^extension_dir =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//; s/ *=>.*//')"
            _f_sd="$(grep '^Scan this dir for additional' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//')"
            # PHP built without a scan dir prints "(none)": no scan dir is configured
            case "$_f_sd" in "(none)"|"no value") _f_sd="" ;; esac
            case "$_f_ed" in "(none)"|"no value") _f_ed="" ;; esac
            case "$_f_ed" in *"|"*) D_ODD="$D_ODD \"$_f_ed\""; _f_ed="" ;; esac
            if grep -q '^whatap\.' "$_infofile" 2>/dev/null; then _f_ld="yes"; else _f_ld="no"; fi
            _f_wn="$( { grep -h 'Unable to load dynamic library' "$_infofile" "$_errfile" | head -n1 | cut -c1-200 ; } 2>/dev/null )"
            [ -n "$_f_wn" ] || _f_wn="none in the php -i output"
            # a relative scan dir entry is relative to the cwd of the PHP
            # process; resolved through a live process of this binary, else
            # recorded as not resolved
            _f_sdr="" _ppid=""
            case "$_nl$D_PHP_LIVE" in *"$_nl$php|"*) _ppid="${D_PHP_LIVE#*"$php|"}"; _ppid="${_ppid%%"$_nl"*}" ;; esac
            # split on ':' only, never globbed: each entry is read as a line.
            # An entry holding '|' (the record delimiter) is refused.
            while IFS= read -r _d; do
                [ -n "$_d" ] || continue
                case "$_d" in *"|"*) D_ODD="$D_ODD \"$_d\""; continue ;; esac
                case "$_d" in
                    /*) ;;
                    *) if [ -n "$_ppid" ] && _a="$(_abs_for_pid "$_ppid" "$_d")"; then _d="$_a"
                       else D_SCAN_UNRES="$D_SCAN_UNRES $php: $_d;"; fi ;;
                esac
                _f_sdr="${_f_sdr:+$_f_sdr:}$_d"
            done <<EOF
$(printf '%s' "$_f_sd" | tr ':' '\n')
EOF
            # the record is '|'-separated; the shown scan dir keeps its '|' as \001
            D_PHP_FACTS="$D_PHP_FACTS
$php|$_f_ver|$_f_sapi|$_f_api|$_f_ts|$_f_ed|$(printf '%s' "$_f_sd" | tr '|' '\001')|$_f_sdr|$_f_ld|$_f_wn"
            _add_ext_dir "$_f_ed" "php -i of $php"
            # ini files this binary parses, and the whatap ini its own scan dir
            # would hold — discovered per runtime, not guessed from a path list
            grep -E '^(Loaded Configuration File|Additional \.ini files parsed) =>' "$_infofile" 2>/dev/null \
                | sed 's/^[^=]*=> *//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
                | grep -i whatap > "$(_tmp ini.list)" 2>/dev/null
            # _tmp gives /dev/null when there is no private dir: nothing to read back
            # a relative entry follows the scan-dir rule: resolved through a
            # live process of this binary, never against the collector's cwd
            if [ "$(_tmp ini.list)" != /dev/null ] && [ -s "$(_tmp ini.list)" ]; then
                while IFS= read -r _p; do
                    case "$_p" in
                        /*) _add_ini "$_p" ;;
                        *) if [ -n "$_ppid" ] && _a="$(_abs_for_pid "$_ppid" "$_p")"; then _add_ini "$_a"
                           else D_SCAN_UNRES="$D_SCAN_UNRES $php: parsed ini $_p;"; fi ;;
                    esac
                done < "$(_tmp ini.list)"
            fi
            # the scan dir may list several directories, colon-separated
            # (PHP_INI_SCAN_DIR), and may be seen through a process root
            while IFS= read -r _d; do
                case "$_d" in /*) ;; *) continue ;; esac   # recorded in D_SCAN_UNRES
                # a scan dir this uid cannot list hides its ini files: a gap,
                # not an empty dir
                _fd="$(resolve_fs "$_d")" || continue
                if [ ! -r "$_fd" ] || [ ! -x "$_fd" ]; then
                    case " $D_DIR_UNREAD " in *" $_fd "*) ;; *) D_DIR_UNREAD="$D_DIR_UNREAD $_fd" ;; esac
                    continue
                fi
                for _p in "$_d"/whatap.ini "$_d"/*whatap*.ini; do _add_ini "$_p"; done
            done <<EOF
$(printf '%s' "$_f_sdr" | tr ':' '\n')
EOF
        else
            fact "   php -i: n/a ($(_classify_err))"
            D_PHPI_FAIL="$D_PHPI_FAIL $php"
            D_PHP_FACTS="$D_PHP_FACTS
$php||||||||no|php -i did not run"
        fi
        php_run "   extensions loaded (php -m)" "$php" -m
        # co-resident tracers and profilers, from the module list just taken
        _o="$(printf '%s\n' "$_php_out" | grep -iE 'newrelic|datadog|ddtrace|elastic|opentelemetry|otel|tideways|blackfire|xdebug|xhprof|pinpoint|scoutapm|instana' | tr '\n' ' ')"
        [ -n "$_o" ] && _mods="$_mods$(printf '        %-40s %s' "$php" "$_o")$_nl"
    done 9<<EOF
$D_PHP_BINS
EOF
    # they occupy the same hook surface
    fact "other APM / profiler extensions among the loaded module lists above:"
    if [ -n "$_mods" ]; then printf '%s' "$_mods"
    else fact "   none found (searched: newrelic, datadog/ddtrace, elastic, opentelemetry, tideways, blackfire, xdebug, xhprof, pinpoint, scoutapm, instana)"; fi
    fact "what the php commands on PATH resolve to:"
    for c in php php-fpm php-cgi; do
        _which "$c"; p="$_wp"
        if [ -n "$p" ]; then printf '        %-10s %s -> %s\n' "$c" "$p" "$(readlink -f "$p" 2>/dev/null || echo 'n/a (unresolvable)')"
        else printf '        %-10s not on PATH\n' "$c"; fi
    done
    if have update-alternatives; then
        probe "update-alternatives php entries" sh -c "update-alternatives --display php 2>&1 | head -n 20"
    elif have alternatives; then
        probe "alternatives php entries" sh -c "alternatives --display php 2>&1 | head -n 20"
    else
        fact "alternatives php entries: n/a (command not found: update-alternatives, alternatives)"
    fi
}

# [4] what actually serves the traffic
_rep_web() {
    section "Web server / application server layer"
    fact "web / application server binaries on PATH:"
    for c in httpd apache2 apachectl php-fpm php5-fpm php-cgi nginx lighttpd frankenphp rr; do
        _which "$c"; p="$_wp"
        if [ -n "$p" ]; then printf '        %-12s present (%s)\n' "$c" "$p"
        else printf '        %-12s absent\n' "$c"; fi
    done
    for c in apachectl httpd apache2; do
        if have "$c"; then
            probe "$c -V (MPM, SERVER_CONFIG_FILE, compile settings)" sh -c "$c -V 2>&1 | head -n 30"
            probe "$c loaded modules (php / mpm entries)" sh -c "$c -M 2>&1 | grep -iE 'php|mpm|proxy_fcgi' | head -n 20"
            break
        fi
    done
    if have php-fpm && [ "${_fpm_v_seen:-0}" = 1 ] && ! _past_deadline; then
        # the first 3 lines of the `php-fpm -v` section 3 ran, as the probe
        # below prints them (past the deadline the probe says so instead)
        _o="$(printf '%s\n' "$_fpm_v_out" | head -n 3)"
        if [ -n "$_o" ]; then _emit_labeled "php-fpm version" "$_o"
        else fact "php-fpm version: n/a (empty output)"; fi
    elif have php-fpm; then probe "php-fpm version" sh -c "php-fpm -v 2>&1 | head -n 3"
    else fact "php-fpm version: n/a (command not found: php-fpm)"; fi
    fact "php-fpm configuration files on disk:"
    _found=0
    for p in /etc/php-fpm.conf /etc/php-fpm.d/*.conf /etc/php/*/fpm/php-fpm.conf /etc/php/*/fpm/pool.d/*.conf \
             /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.d/*.conf /etc/php[0-9]*/php-fpm.conf /etc/php[0-9]*/php-fpm.d/*.conf; do
        [ -f "$p" ] || continue
        _found=1
        printf '        %s\n' "$(ls -l "$p" 2>/dev/null)"
    done
    [ "$_found" = 0 ] && fact "   none found in the known php-fpm config locations"
    for p in /etc/php-fpm.d/www.conf /etc/php/*/fpm/pool.d/www.conf /usr/local/etc/php-fpm.d/www.conf /etc/php[0-9]*/php-fpm.d/www.conf; do
        [ -f "$p" ] || continue
        probe "   pool settings in $p" _nonblank_head "$p" 60
    done
    if have nginx; then probe "nginx version" sh -c "nginx -v 2>&1 | head -n 2"
    else fact "nginx version: n/a (command not found: nginx)"; fi
    # one FPM service per PHP version is the usual multi-version layout
    if have systemctl; then probe "systemd php-fpm units" _head_of 20 systemctl list-units --all --type=service --no-pager --no-legend 'php*'
    else fact "systemd php-fpm units: n/a (command not found: systemctl)"; fi
    fact "web / php processes found: $(echo $D_WEB_PIDS | wc -w | tr -d ' ')"
    _shown=0
    for pid in $D_WEB_PIDS; do
        _shown=$((_shown + 1))
        [ "$_shown" -gt 20 ] && { fact "-- remaining processes not detailed (cap: 20)"; break; }
        [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
        printf '        -- pid %s (ppid %s) comm=%s uid=%s\n' "$pid" \
            "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)" \
            "$(cat "/proc/$pid/comm" 2>/dev/null)" \
            "$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
        printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
        printf '           exe: %s\n' "$(_link_target "/proc/$pid/exe" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
    done
    if [ -z "$D_ALT_PIDS" ]; then
        fact "persistent-worker PHP runtimes (swoole/octane/roadrunner/frankenphp/workerman/php-pm): none found by executable, or by command line of a PHP executable"
    else
        fact "persistent-worker PHP runtimes found:"
        for pid in $D_ALT_PIDS; do
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s comm=%s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
            printf '           cwd: %s\n' "$(_link_target "/proc/$pid/cwd" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
        done
    fi
}

# [5] the agent package as it sits on disk
_rep_install() {
    section "WhaTap PHP agent installation on disk"
    fact "env WHATAP_HOME (collector shell): $(_quote_nl "${WHATAP_HOME:-not set}")"
    [ -n "$D_ODD" ] && fact "path(s) with a newline or '|', not followed:$D_ODD"
    [ -n "$D_GONE" ] && printf '%s' "$D_GONE" | while IFS= read -r _l; do [ -n "$_l" ] && fact "relative WHATAP_HOME of a process that exited, not resolved: $_l"; done
    if [ -z "$D_HOMES" ]; then
        if [ -n "$D_ODD_HOME" ]; then fact "agent home candidates: none followed (the refused paths are listed above)"
        else fact "agent home candidates: none discovered (env, $D_DEFAULT_HOME, process scan all empty)"; fi
    else
        fact "agent home candidates discovered:"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _s; do printf '        %s   <- %s\n' "$_p" "$_s"; done
    fi
    printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")"
        if [ -z "$fshome" ]; then fact "-- home $home: n/a ($(_absent_why "$home" "$_src"))"; continue; fi
        fact "-- home: $home"
        [ "$fshome" != "$home" ] && fact "   filesystem view: $fshome (read through a process root)"
        probe "   listing" _ls_head "$fshome" 40
        for b in whatap_php whatap_php_static; do
            file_facts "   agent binary $b" "$fshome/$b"
        done
        # the agent binary prints its build when called with `version`; calling
        # it bare would start an agent, so only this argument is ever used
        if [ -x "$fshome/whatap_php" ]; then
            probe "   whatap_php version" "$fshome/whatap_php" version
        elif [ -x "$fshome/whatap_php_static" ]; then
            probe "   whatap_php_static version" "$fshome/whatap_php_static" version
        else
            fact "   agent binary version: n/a (no executable whatap_php / whatap_php_static in $fshome)"
        fi
        _file_lines head "   ChangeLog (top: shipped agent version and date)" "$fshome/ChangeLog" 6
        file_facts "   install.sh" "$fshome/install.sh"
        _file_lines head "   template.ini (installer's ini template)" "$fshome/template.ini" 60
        # the PHP-version -> Zend API table the INSTALLED installer uses, read
        # from that installer rather than assumed
        if [ -r "$fshome/install.sh" ]; then
            _map="$(sed -n '/get_php_api_version()/,/^}/p' "$fshome/install.sh" 2>/dev/null | grep -oE '"[0-9]+\.[0-9]+"\) PHP_API="[0-9]+"' | tr -d '"' | sed 's/) PHP_API=/ -> /' | tr '\n' ' ')"
            if [ -n "$_map" ]; then fact "   php version -> PHP API map in this install.sh: $_map"
            else fact "   php version -> PHP API map: n/a (no get_php_api_version block in $fshome/install.sh)"; fi
        fi
        if [ -d "$fshome/modules" ]; then
            probe "   shipped tracer modules per arch (count)" _mods_count "$fshome"
            probe "   shipped tracer modules (names)" _mods_names "$fshome"
        else
            fact "   modules dir: n/a (path not found: $fshome/modules)"
        fi
        [ -d "$fshome/lib/Whatap" ] && probe "   bundled PHP API helpers" ls -- "$fshome/lib/Whatap" \
            || fact "   bundled PHP API helpers (lib/Whatap): absent"
    done
    fact "package manager records:"
    if have rpm; then probe "   rpm -q whatap-php" sh -c "rpm -q whatap-php 2>&1 | head -n 3"
    else fact "   rpm: n/a (command not found: rpm)"; fi
    if have dpkg; then probe "   dpkg -l whatap-php" sh -c "dpkg -l whatap-php 2>&1 | tail -n 3"
    else fact "   dpkg: n/a (command not found: dpkg)"; fi
    if have apk; then probe "   apk info whatap-php" sh -c "apk info -v whatap-php 2>&1 | head -n 3"
    else fact "   apk: n/a (command not found: apk)"; fi
}

# [6] the binding, reported per PHP runtime — on a host with several PHP
# versions the tracer is bound to some of them and not to others, and each
# version has its own extension_dir and its own ini scan dir.
_rep_binding() {
    section "Tracer binding per PHP runtime (module, ini, load state)"
    if [ -z "$D_PHP_FACTS" ]; then
        fact "no PHP runtime was detailed in section 3; only the extension_dir view below applies"
    else
        printf '%s\n' "$D_PHP_FACTS" | grep -v '^$' | while IFS='|' read -r _p _v _sapi _api _ts _ed _sd _sdr _ld _wn; do
            [ -n "$_p" ] || continue
            fact "-- runtime: $_p"
            fact "   PHP ${_v:-n/a}, SAPI ${_sapi:-n/a}, PHP API ${_api:-n/a}, Thread Safety ${_ts:-n/a}"
            if [ -n "$_ed" ]; then
                fact "   extension_dir: $_ed"
                fsd="$(resolve_fs "$_ed")"
                if [ -z "$fsd" ]; then
                    fact "   whatap.so there: n/a ($(_absent_why "$_ed"))"
                elif [ ! -x "$fsd" ]; then
                    fact "   whatap.so there: n/a (permission denied: $fsd)"
                elif [ -e "$fsd/whatap.so" ]; then
                    fact "   whatap.so there: $(ls -l "$fsd/whatap.so" 2>/dev/null)"
                    _t="$(readlink -f "$fsd/whatap.so" 2>/dev/null)"
                    if [ -n "$_t" ]; then
                        _b="$(basename "$_t")"
                        fact "   it resolves to: $_b (name encodes: thread-safe build = $(case "$_b" in *_zts_*) echo yes ;; *) echo no ;; esac), PHP API = $(echo "$_b" | grep -oE '[0-9]{8}' | head -n1))"
                    fi
                else
                    fact "   whatap.so there: n/a (path not found: $_ed/whatap.so)"
                fi
            else
                fact "   extension_dir: n/a (php -i reported none)"
            fi
            if [ -n "$_sd" ]; then
                fact "   ini scan dir: $(printf '%s' "$_sd" | tr '\001' '|')"
                # one line per entry, absolute or not (refused entries are
                # listed with the other refused paths)
                while IFS= read -r _d; do
                    [ -n "$_d" ] || continue
                    case "$_d" in /*) ;; *) fact "   -- $_d: n/a (relative scan dir, not resolved)"; continue ;; esac
                    _fd="$(resolve_fs "$_d")" || { fact "   -- $_d: n/a ($(_absent_why "$_d"))"; continue; }
                    if [ ! -r "$_fd" ] || [ ! -x "$_fd" ]; then fact "   -- $_d: n/a (permission denied: $_fd)"; continue; fi
                    _i=""
                    for _q in "$_fd"/*whatap*.ini; do [ -f "$_q" ] && _i="$_i $_q"; done
                    if [ -n "$_i" ]; then fact "   -- $_d: whatap ini:$_i"
                    else fact "   -- $_d: no *whatap*.ini"; fi
                done <<EOF
$(printf '%s' "$_sdr" | tr ':' '\n')
EOF

            else
                fact "   ini scan dir: none configured (php -i reports none)"
            fi
            fact "   whatap.* directives registered in this runtime: $_ld"
            fact "   dynamic-library load message: $_wn"
        done
    fi
    if [ -z "$D_EXT_DIRS" ]; then
        fact "extension_dir values: none discovered (php -i and service files both empty)"
    else
        fact "every extension_dir seen, its source, and whether a discovered runtime reported it:"
        printf '%s\n' "$D_EXT_DIRS" | grep -v '^$' | while IFS='|' read -r _d _s; do
            [ -n "$_d" ] || continue
            _u="no"
            case "$D_PHP_FACTS" in *"|$_d|"*) _u="yes" ;; esac
            printf '        %-50s <- %-42s runtime-reported: %s\n' "$_d" "$_s" "$_u"
        done
        # a dir that only the service files name belongs to a PHP install that
        # no runtime found here reports — its module facts are collected too
        printf '%s\n' "$D_EXT_DIRS" | grep -v '^$' | while IFS='|' read -r _d _s; do
            [ -n "$_d" ] || continue
            case "$D_PHP_FACTS" in *"|$_d|"*) continue ;; esac
            fsd="$(resolve_fs "$_d")"
            if [ -z "$fsd" ]; then fact "-- extension_dir $_d (no runtime reported it): n/a ($(_absent_why "$_d"))"; continue; fi
            fact "-- extension_dir $_d (no runtime reported it):"
            if [ -e "$fsd/whatap.so" ]; then
                file_facts "   whatap.so" "$fsd/whatap.so"
            else
                fact "   whatap.so: n/a (path not found: $_d/whatap.so)"
            fi
        done
    fi
    fact "whatap ini files found on disk:"
    if [ -z "$D_INI_FILES" ]; then
        fact "   none found (searched the RHEL, Debian/Ubuntu per-SAPI, Alpine, source-build and agent-home ini locations)"
    else
        printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do
            printf '        %s\n' "$(ls -l "$p" 2>/dev/null)"
        done
    fi
    fact "php.ini files carrying whatap lines:"
    _hit=0
    for p in /etc/php.ini /etc/php/*/*/php.ini /etc/php[0-9]*/php.ini /usr/local/etc/php/php.ini /usr/local/lib/php.ini /opt/remi/php*/root/etc/php.ini; do
        [ -f "$p" ] || continue
        _c="$(grep -c -i whatap "$p" 2>/dev/null)"
        [ "${_c:-0}" -gt 0 ] || continue
        _hit=1
        D_PHPINI_WHATAP="$D_PHPINI_WHATAP $p"
        fact "   -- $p (${_c} whatap line(s)):"
        grep -n -i whatap "$p" 2>/dev/null | head -n 30 | while IFS= read -r _l; do printf '           %s\n' "$_l"; done
    done
    [ "$_hit" = 0 ] && fact "   none found"
    fact "ini directory trees present:"
    _hit=0
    for d in /etc/php.d /etc/php/*/cli/conf.d /etc/php/*/fpm/conf.d /etc/php/*/apache2/conf.d /etc/php/*/mods-available \
             /etc/php[0-9]*/conf.d /usr/local/etc/php/conf.d \
             /opt/remi/php*/root/etc/php.d /etc/opt/remi/php*/php.d \
             /opt/rh/*php*/root/etc/php.d /etc/opt/rh/*php*/php.d \
             /opt/cpanel/ea-php*/root/etc/php.d /opt/plesk/php/*/etc/php.d \
             /opt/alt/php*/etc/php.d /usr/local/lsws/lsphp*/etc/php.d; do
        [ -d "$d" ] || continue
        _hit=1
        # a directory this uid cannot read lists no names: not "no entry"
        if [ -r "$d" ]; then
            _w="$(_names "$d" | grep -i whatap | tr '\n' ' ')"
            printf '        %-46s %s\n' "$d" "${_w:-(no whatap entry)}"
        else
            printf '        %-46s %s\n' "$d" "n/a (permission denied: $d)"
        fi
    done
    [ "$_hit" = 0 ] && fact "   none of the known ini tree paths exist on this host"
    fact "live load status — whatap module mapped into running processes (from /proc/<pid>/maps):"
    _any=0
    _nread=0
    for pid in $D_WEB_PIDS $D_ALT_PIDS; do
        # access(2) says maps is readable even when opening it is refused
        # (ptrace access check), so the read itself is the test
        if _m="$(awk '$NF ~ /whatap/ {print $NF}' "/proc/$pid/maps" 2>/dev/null)"; then
            _nread=$((_nread + 1))
            _m="$(printf '%s\n' "$_m" | sort -u | tr '\n' ' ')"
            if [ -n "$_m" ] && [ "$_m" != " " ]; then
                _any=1
                printf '        pid %-7s comm=%-12s maps: %s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)" "$_m"
            fi
        elif [ -e "/proc/$pid" ]; then
            D_MAPS_UNREAD="$D_MAPS_UNREAD $pid"
        fi
    done
    if [ -n "$D_MAPS_UNREAD" ]; then
        fact "   maps: n/a (not readable by uid $(id -u 2>/dev/null || echo '?') for $(echo $D_MAPS_UNREAD | wc -w | tr -d ' ') process(es): $(echo $D_MAPS_UNREAD | cut -d' ' -f1-20))"
    fi
    if [ "$_any" = 0 ]; then
        if [ -z "$D_WEB_PIDS$D_ALT_PIDS" ]; then
            fact "   no web/php processes found to inspect"
        else
            fact "   no whatap module path in the memory maps of the $_nread process(es) whose maps were read"
        fi
    fi
}

# [7] configuration content, verbatim
_rep_conf() {
    section "Agent configuration (verbatim)"
    if [ -z "$D_INI_FILES" ]; then
        fact "whatap ini files: none found to dump"
    else
        printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do
            conf_bytes "-- $p" "$p"
            _file_lines head "   content" "$p" 300
        done
    fi
    fact "service / unit / init files written by install.sh:"
    if [ -z "$D_SERVICE_FILES" ]; then
        fact "   none found (searched agent home, /etc/init.d, systemd unit dirs, /etc/rc.d)"
    else
        printf '%s\n' "$D_SERVICE_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do
            _file_lines head "-- $p" "$p" 120
        done
    fi
    fact "WHATAP_* environment of the running processes:"
    _any=0
    for pid in $D_AGENT_PIDS $D_WEB_PIDS $D_ALT_PIDS; do
        if [ -r "/proc/$pid/environ" ]; then
            _e="$( { tr '\0' '\n' < "/proc/$pid/environ" | grep -E '^WHATAP_' | tr '\n' ' ' ; } 2>/dev/null )"
            if [ -n "$_e" ]; then _any=1; printf '        pid %-7s comm=%-16s %s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)" "$_e"; fi
        else
            printf '        pid %-7s environ: n/a (permission denied: /proc/%s/environ)\n' "$pid" "$pid"
        fi
    done
    [ "$_any" = 0 ] && fact "   no WHATAP_* variable found in the environ of the processes inspected"
    # app_process_name drives the process-memory metric; the matching live
    # process count is the fact that makes it verifiable
    _apn="$(printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do grep -h '^[[:space:]]*whatap\.app_process_name' "$p" 2>/dev/null; done | head -n1 | sed 's/.*= *//')"
    if [ -n "$_apn" ]; then
        fact "whatap.app_process_name configured value: $_apn"
        fact "processes whose comm matches that value right now: $(_proc_table | awk -F'\037' -v n="$_apn" '$2 == n' | wc -l | tr -d ' ')"
    else
        fact "whatap.app_process_name: not set in any ini file found"
    fi
    # key material: presence only, by data scope (this is not masking of a
    # dumped file — the file is not collected at all)
    fact "agent key material files (content not collected: key material):"
    [ -z "$D_HOMES" ] && fact "   n/a (no agent home discovered)"
    printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")" || { fact "   -- home $home: n/a ($(_absent_why "$home" "$_src"))"; continue; }
        for f in security.conf paramkey.txt; do
            if [ -e "$fshome/$f" ]; then printf '        %s: present, %s bytes\n' "$fshome/$f" "$(wc -c < "$fshome/$f" 2>/dev/null | tr -d ' ')"
            else printf '        %s: absent\n' "$fshome/$f"; fi
        done
    done
}

# [8] the agent process and its channels
_rep_agent() {
    section "Agent process, service state and channels"
    if [ -z "$D_AGENT_PIDS" ]; then
        fact "whatap_php processes: none found in /proc (matched by comm whatap_php*)"
    else
        fact "whatap_php processes:"
        for pid in $D_AGENT_PIDS; do
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           comm: %s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
            printf '           exe: %s\n' "$(_link_target "/proc/$pid/exe" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
            printf '           cwd: %s\n' "$(_link_target "/proc/$pid/cwd" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
            printf '           uid/state/threads: %s\n' "$(awk '/^Uid:/{u=$2} /^State:/{s=$2" "$3} /^Threads:/{t=$2} END{print u" / "s" / "t}' "/proc/$pid/status" 2>/dev/null)"
            _rss="$(awk '/^VmRSS:/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"
            printf '           rss: %s\n' "${_rss:-n/a (no VmRSS line: zombie or permission denied)}"
            printf '           start time: %s\n' "$(_proc_start "$pid")"
        done
    fi
    printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")" || { fact "pid file $home/whatap_php.pid: n/a ($(_absent_why "$home" "$_src"))"; continue; }
        if [ -f "$fshome/whatap_php.pid" ]; then
            _pid="$(cat "$fshome/whatap_php.pid" 2>/dev/null | tr -d ' \n')"
            if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
                fact "pid file $home/whatap_php.pid: $_pid (process exists; comm: $(cat "/proc/$_pid/comm" 2>/dev/null))"
            else
                fact "pid file $home/whatap_php.pid: ${_pid:-empty} (no process with this pid in this pid namespace)"
            fi
        else
            fact "pid file $home/whatap_php.pid: n/a (path not found)"
        fi
    done
    if have systemctl; then
        probe "systemd unit enabled (whatap-php)" systemctl is-enabled whatap-php
        probe "systemd unit active (whatap-php)" systemctl is-active whatap-php
        probe "systemd unit status (first 20 lines)" _head_of 20 systemctl status whatap-php --no-pager
    else
        fact "systemd unit state (whatap-php): n/a (command not found: systemctl)"
    fi
    probe "sysv service status" sh -c "[ -x /etc/init.d/whatap-php ] && /etc/init.d/whatap-php status 2>&1 | head -n 5 || echo 'n/a (path not found: /etc/init.d/whatap-php)'"
    _net_ports
    if have ss; then
        probe "udp sockets (whatap-named or port $_udp_label)" _sock_list ss -uanp "$_udp_ports"
        probe "tcp sessions (whatap-named or port $_tcp_label)" _sock_list ss -tnp "$_tcp_ports"
    elif have netstat; then
        probe "udp sockets (whatap-named or port $_udp_label)" _sock_list netstat -uanp "$_udp_ports"
        probe "tcp sessions (whatap-named or port $_tcp_label)" _sock_list netstat -tnp "$_tcp_ports"
    else
        fact "socket listing: n/a (command not found: ss, netstat); raw tables follow"
        probe "raw /proc/net/udp (first 30 lines)" head -n 30 /proc/net/udp
        probe "raw /proc/net/tcp (first 30 lines)" head -n 30 /proc/net/tcp
    fi
    # the tracer and the agent also share SysV shared memory + a semaphore;
    # install.sh removes key 6600 (0x19c8) on uninstall
    probe "sysv shared memory segments" sh -c "ipcs -m 2>/dev/null | head -n 30"
    probe "sysv semaphore arrays" sh -c "ipcs -s 2>/dev/null | head -n 30"
}

# [9] logs
_rep_logs() {
    section "Agent logs and web server error markers"
    if [ -z "$D_HOMES" ]; then
        fact "no agent home discovered; no agent log locations to read"
    else
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
            [ -n "$home" ] || continue
            fact "-- home: $home"
            fshome="$(resolve_fs "$home")" || { fact "   n/a ($(_absent_why "$home" "$_src"))"; continue; }
            if [ -d "$fshome/logs" ]; then
                probe "   logs dir listing" _ls_head "$fshome/logs" 60
                _boot="$(ls -t "$fshome"/logs/whatap-boot-*.log 2>/dev/null | head -n 1)"
                if [ -n "$_boot" ]; then
                    _file_lines head "   $(basename "$_boot") (first lines: startup banner and configuration)" "$_boot" 80
                    _tot="$(wc -l < "$_boot" 2>/dev/null | tr -d ' ')"
                    if [ "${_tot:-0}" -gt 80 ]; then
                        _file_lines tail "   $(basename "$_boot") (recent lines)" "$_boot" 150
                    else
                        fact "   $(basename "$_boot"): ${_tot:-?} lines total — the block above is the whole file"
                    fi
                else
                    fact "   whatap-boot-*.log: n/a (no such file in $fshome/logs)"
                fi
                _inst="$(ls -t "$fshome"/logs/whatap-install-*.log 2>/dev/null | head -n 1)"
                if [ -n "$_inst" ]; then
                    _file_lines tail "   $(basename "$_inst") (what install.sh resolved on this host)" "$_inst" 120
                else
                    fact "   whatap-install-*.log: n/a (no such file in $fshome/logs)"
                fi
            else
                fact "   logs dir: n/a (path not found: $fshome/logs)"
            fi
        done
    fi
    # the tracer writes its own messages (WA-coded) to the web server error log
    fact "web server error logs — last 300 lines scanned for whatap / WA-coded lines:"
    _hit=0
    for p in /var/log/httpd/error_log /var/log/apache2/error.log /var/log/php-fpm/error.log \
             /var/log/php-fpm.log /var/log/php[0-9]*-fpm.log /var/log/php/*.log \
             /usr/local/var/log/php-fpm.log /var/log/nginx/error.log; do
        [ -f "$p" ] || continue
        [ -r "$p" ] || { fact "   -- $p: n/a (permission denied)"; continue; }
        _hit=1
        _m="$(tail -n 300 "$p" 2>/dev/null | grep -E 'whatap|WA[0-9]{3}|Whatap' | tail -n 40)"
        if [ -n "$_m" ]; then
            fact "   -- $p (matching lines, last 40):"
            printf '%s\n' "$_m" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "   -- $p: no whatap / WA-coded line in the last 300 lines"
        fi
    done
    [ "$_hit" = 0 ] && fact "   none of the known web server error log paths exist and are readable here"
}

# [10] container / orchestration context
_rep_k8s() {
    section "Container / Kubernetes context"
    fact "container markers:"
    for m in /.dockerenv /run/.containerenv; do
        if [ -e "$m" ]; then printf '        %-22s present\n' "$m"; else printf '        %-22s absent\n' "$m"; fi
    done
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        printf '        %-22s %s\n' "KUBERNETES_SERVICE_HOST" "$KUBERNETES_SERVICE_HOST"
    else
        printf '        %-22s not set\n' "KUBERNETES_SERVICE_HOST"
    fi
    probe "self cgroup (first 5 lines)" head -n 5 /proc/self/cgroup
    printf '%s\n' "$D_HOMES" | while IFS='|' read -r home _src; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")" || { fact "container.conf in $home: n/a ($(_absent_why "$home" "$_src"))"; continue; }
        _file_lines head "container.conf in $home" "$fshome/container.conf" 60
    done
    for v in POD_NAME NODE_NAME POD_NAMESPACE OKIND ONAME ONODE; do
        eval "_val=\${$v:-}"
        [ -n "$_val" ] && fact "env $v: $_val"
    done
    [ -d /var/run/secrets/kubernetes.io ] && fact "/var/run/secrets/kubernetes.io: present" || fact "/var/run/secrets/kubernetes.io: absent"
    read_proc "container hostname (/etc/hostname)" /etc/hostname
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
