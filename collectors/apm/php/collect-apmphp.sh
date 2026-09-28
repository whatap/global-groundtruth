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
# Sections: [1] collection environment, [2] host / platform, [3] PHP runtimes
# and SAPIs, [4] web server / application server layer, [5] WhaTap PHP agent
# installation on disk, [6] tracer binding per PHP runtime, [7] agent
# configuration, [8] agent process, service state and channels, [9] agent
# logs and web server error markers, [10] container / Kubernetes context;
# then status. The two halves of the agent and the question each section
# answers: README.md, "Why the two halves are the first fact" and "Facts
# collected".
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
# History: CHANGELOG.md (next to this file).
VERSION="0.8.8"
DOMAIN="apm"
TARGET="host/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"

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
progress()   { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null || :; }
have()       { command -v "$1" >/dev/null 2>&1; }

# _indent PREFIX -> stdin with PREFIX before every line; a last line without a
# newline is kept (and ended)
_indent() { awk -v p="$1" '{ print p $0 }'; }

# _emit_labeled LABEL BODY -> "LABEL: BODY" for a one-line BODY; else "LABEL:"
# and BODY's lines under it, indented
_emit_labeled() {
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then
        fact "$label: $body"
    else
        fact "$label:"
        printf '%s\n' "$body" | _indent '        '
    fi
}

# _tool_rows [--path] TOOL... -> one row per TOOL for the environment section's
# tool table: "present" or "absent", with --path "present (PATH)". The path is
# read back from a file in the run's directory, not a $(...) (a fork per tool);
# without the directory it is looked up again.
_tool_rows() {
    local wp=0 t p
    [ "${1:-}" = --path ] && { wp=1; shift; }
    for t in "$@"; do
        if ! command -v "$t" >/dev/null 2>&1; then printf '        %-12s absent\n' "$t"; continue; fi
        [ "$wp" = 1 ] || { printf '        %-12s present\n' "$t"; continue; }
        p=""
        [ -n "$_tmp_dir" ] && { command -v "$t" > "$_tmp_dir/cmdv"; } 2>/dev/null && IFS= read -r p < "$_tmp_dir/cmdv"
        [ -n "$p" ] || p="$(command -v "$t" 2>/dev/null)"
        printf '        %-12s present (%s)\n' "$t" "$p"
    done
}

# _optval NAME VALUE -> exit 2 when VALUE is empty or starts with '-' (then the
# next option was taken for the value: `--out --stdout`). This block comes
# before the option loop, which calls it.
_optval() {
    case "$2" in ''|-*) printf -- 'missing value for %s\n' "$1" >&2; exit 2 ;; esac
}
# ---- end emit helpers

# ---- CLI harness ------------------------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr
OPT_OUT=""        # --out DIR: directory of the --file report (empty = .)

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
  $(basename "$0") --out DIR  output directory for --file (default: .)

Environment:
  APM_INTERP_CAP=N  php binaries detailed per run (default 10, 1..999999)
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        --out)     _optval "$1" "${2-}"; OPT_OUT="$2"; shift ;;
        --out=*)   _optval --out "${1#*=}"; OPT_OUT="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

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
    # _run_init has usually read it already.
    [ -n "${_priv_uid:-}" ] || _priv_uid="$(id -u 2>/dev/null)"
    [ -n "$_priv_uid" ] || _priv_uid="$(awk '/^Uid:/{print $2; exit}' /proc/self/status 2>/dev/null)"
    if [ -z "$_priv_uid" ]; then
        PRIV_WHY="n/a (id -u failed and /proc/self/status is not readable)"
        PRIV_GAP=""
    elif [ "$_priv_uid" = 0 ]; then
        PRIV_WHY="root${SUDO_UID:+ (elevated by sudo from uid $SUDO_UID)}"
        PRIV_GAP=""
        # uid 0 in a container is often without CAP_SYS_PTRACE (bit 19 of
        # CapEff; docker's and k8s's defaults), and then another uid's
        # /proc/<pid>/{environ,root,cwd} are denied although the line says root.
        # The low 8 hex digits: all shells agree on 32 bits.
        _priv_cap="$(awk '/^CapEff:/{print substr($2, length($2) - 7); exit}' /proc/self/status 2>/dev/null)"
        case "$_priv_cap" in
            ''|*[!0-9a-fA-F]*) ;;
            *) [ "$(( (0x$_priv_cap >> 19) & 1 ))" = 0 ] \
                && PRIV_WHY="$PRIV_WHY without CAP_SYS_PTRACE (other uids' /proc/<pid>/environ, root, cwd are not readable: run as the target's uid, e.g. docker exec -u <uid> or kubectl exec)" ;;
        esac
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
# _out_dir_check  the output directory exists and is writable, before a run.
# _report_to_file --file mode's write; fails when the file is not written whole.
# probe, probe_merged, read_proc  a command's output (probe_merged: with its
#                 stderr) or a file's content as facts, or n/a with the reason
#                 (guideline 4).
# _why_124        the reason for a bounded call's 124: run deadline or its cap.
# Constraints:
# - POSIX sh only (apm collectors run under `sh -s`, often dash or busybox):
#   no SECONDS, no `type -t`, no ${v//x/y} outside a BASH_VERSION guard.
# - A cap returns 124 whatever timeout(1) returns for a kill (busybox: 143).
#   timeout(1) gets -k where it takes it, so a command deaf to TERM still ends;
#   without timeout(1) (busybox's counts as without), or for a shell function,
#   a watchdog that ends in KILL. A call that finishes leaves no process to
#   PID 1 (a killed tree's grandchildren still can).
# - Past RUN_DEADLINE nothing runs (124), so the report still reaches its footer.
# - Each call is logged with its time; only the command name and a subcommand
#   word, never arguments (they can hold a path or a credential).
RUN_DEADLINE="${RUN_DEADLINE:-300}"
_tmp_dir=""
_timeout_bin=""   # timeout(1), found in _run_init; empty = watchdog only
_run_t0=""
_errfile=""       # a probe's stderr (_run_init)
_timeout_k=""     # 5 when timeout(1) takes -k (_run_init)
_load0=""         # _host_load at _run_init
SLOW_SEC=3        # a bounded call at least this long is named in the status
_stdin_script=0   # 1 when the shell reads this script from stdin (sh -s)
_nl='
'
_tab="$(printf '\t')"

# Falls back to stderr when fd 3 is not open yet (an error before main).
warn() { { printf '!! %s\n' "$*" >&3; } 2>/dev/null || printf '!! %s\n' "$*" >&2 || :; }

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

# _run_init -> the private temp directory, the traps, timeout(1), and _errfile
# (the file a probe's stderr goes to, which _classify_err reads). Call it once
# in main, before anything creates a temp file.
_run_init() {
    _run_t0="$(date +%s 2>/dev/null)"
    _owner_pid="$$"
    _load0="$(_host_load)"
    # 16+ digits: a date without %N prints bare seconds
    [ -z "${EPOCHREALTIME:-}" ] && case "$(date +%s%N 2>/dev/null)" in *[!0-9]*|'') ;; ????????????????*) _ms_date=1 ;; esac
    case "$_run_t0" in ''|*[!0-9]*) _run_t0="" ;; esac
    # The traps come before the directory: set after it, a signal in between
    # left ggt.* behind (1 in ~300 runs of a stress test, 2026-09-28). A signal
    # during mktemp runs the trap once the assignment is done, and
    # _run_cleanup does nothing while _tmp_dir is still empty.
    trap '_run_cleanup' EXIT
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
    # no predictable fallback name: without mktemp, _tmp answers /dev/null
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ggt.XXXXXX" 2>/dev/null)"
    # Script read from stdin (`sh -s`)? Then fd 0 is the script: a bounded
    # command must not read it, and bash 5.2 kills a $(...) that duplicates it.
    # A shell started by its path (`/bin/bash -s`) has its own binary as $0:
    # that is stdin too. Taken for a file, bash 3.2 frees its fd-0 input buffer
    # twice after `4<&0`, and under musl it faults in a loop at full CPU.
    case "$0" in
        */*|*.sh) [ -f "$0" ] || _stdin_script=1
                  [ -e "/proc/$$/exe" ] && [ "$0" -ef "/proc/$$/exe" ] && _stdin_script=1 ;;
        *)        _stdin_script=1 ;;
    esac
    [ -n "$_tmp_dir" ] || warn "no private temp directory could be made under ${TMPDIR:-/tmp}; values that need one are reported as n/a"
    _errfile="$(_tmp probe.err)"
    # the uid, read once: reasons name it (${_priv_uid:-?}), _note_privilege judges it
    _priv_uid="$(id -u 2>/dev/null)"
    # caps from the environment: whole numbers or unused (0 = no limit to timeout(1))
    RUN_DEADLINE="$(_cap_or RUN_DEADLINE "$RUN_DEADLINE" 300)"
    CMD_TIMEOUT="$(_cap_or CMD_TIMEOUT "${CMD_TIMEOUT:-20}" 20)"
    [ -n "${_timeout_bin:-}" ] || _timeout_bin="$(command -v timeout 2>/dev/null)"
    # busybox timeout(1) runs CMD in its own pid and leaves its timer to PID 1,
    # a zombie per call under a PID 1 that does not reap: the watchdog instead
    case "$_timeout_bin" in /*) LC_ALL=C grep -q 'BusyBox v' "$_timeout_bin" 2>/dev/null && _timeout_bin="" ;; esac
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
# whole seconds.
_ms_date=0
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
        # The watchdog is ended by USR1, on which it KILLs and reaps its sleep:
        # a sleep left behind goes to PID 1, and a container's PID 1 that does
        # not reap keeps it as a zombie (one per call). No trap of this shell
        # is on USR1, so one that lands before the watchdog's trap is set ends
        # it at once, before it has a child. A TERM could land before dash
        # reset the inherited traps and be lost, and a KILL orphans the sleep.
        # The trap's own kill is KILL: a TERM to a sleep not yet exec'd is lost.
        ( trap '[ "$!" = "$p" ] || kill -KILL "$!" 2>/dev/null; wait; exit 0' USR1
          i=0
          # background sleep + wait, so the USR1 ends the watchdog at once
          while [ "$i" -lt "$t" ]; do sleep 1 & wait $!; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2 & wait $!
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        wait "$p"; rc=$?
        kill -USR1 "$w" 2>/dev/null; wait "$w" 2>/dev/null
    fi
    _now_ms; d=$((_ms - m0))
    case "$rc" in 124|137|143) [ "$((d / 1000))" -ge "$t" ] && rc=124 ;; esac
    if [ "$rc" = 124 ]; then
        if [ "$t" -lt "${CMD_TIMEOUT:-20}" ]; then w="cut at the deadline"; else w="capped at ${t}s"; fi
    else w="ran"; fi
    _time_log "$d" "$w" "$@"
    return "$rc"
}

# _out_dir_check -> the output directory OPT_OUT (empty: the working directory)
# exists, made when missing, and this uid can write into it; else false, saying
# so on the operator stream.
# Called before anything is collected, so an unwritable one fails at once
# rather than after a full run.
_out_dir_check() {
    local d="${OPT_OUT:-.}" dl="$RUN_DEADLINE"
    if [ ! -d "$d" ]; then
        # A deadline spent before the run (a tiny RUN_DEADLINE) must not stop
        # the report from being written: the mkdir gets the command cap alone.
        _past_deadline && RUN_DEADLINE=$(($(_elapsed) + ${CMD_TIMEOUT:-20}))
        _bounded mkdir -p -- "$d" 2>/dev/null
        RUN_DEADLINE="$dl"
    fi
    if [ ! -d "$d" ] || [ ! -w "$d" ] || [ ! -x "$d" ]; then
        warn "the report was not written: output directory $d is not writable by uid ${_priv_uid:-?}"
        return 1
    fi
}

_report_to_file() {
    # `true`, not `:`. A failed redirect on a special builtin exits dash.
    if ! { true > "$1"; } 2>/dev/null; then
        warn "the report was not written: $1 cannot be created by uid ${_priv_uid:-?}"
        return 1
    fi
    run_report > "$1" 2>/dev/null
    if ! tail -n 1 -- "$1" 2>/dev/null | grep -q '^==== END OF COLLECTION'; then
        warn "the report was not written whole: $1 does not end with the footer"
        return 1
    fi
}

# _why_124 -> why a bounded call returned 124: the run deadline, or its own cap
_why_124() {
    if _past_deadline; then printf 'run deadline reached: %ss' "$RUN_DEADLINE"
    else printf 'timed out: %ss' "$CMD_TIMEOUT"; fi
}

# probe "label" CMD [ARGS...] -> output as facts, or "label: n/a (<why>)".
# CMD may be a file, a shell function or a builtin; _bounded caps all three. A
# non-zero exit that still printed something is reported with its output, since
# for many commands the exit code is the answer (systemctl is-active prints
# "inactive" and exits 3). The reason of a failure is the collector's
# _classify_err, reading _errfile. PROBE_OUT / PROBE_RC: the last probe's stdout
# and exit status (127 when nothing ran), so a caller that also parses the
# output runs the command once.
# probe_merged "label" CMD [ARGS...] -> the same with stderr folded into stdout,
# for tools that answer on stderr (java -version). With no stderr to classify,
# a failed run with no output says its exit status.
PROBE_OUT=""; PROBE_RC=127
probe()        { _probe_run 2 "$@"; }
probe_merged() { _probe_run 1 "$@"; }
# shellcheck disable=SC2034  # PROBE_OUT / PROBE_RC are read by the caller
_probe_run() {
    local _pr_m="$1" label="$2" out rc; shift 2
    PROBE_OUT=""; PROBE_RC=127
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    if [ "$_pr_m" = 1 ]; then out="$(_bounded "$@" 2>&1)"; rc=$?
    else out="$(_bounded "$@" 2>"$_errfile")"; rc=$?; fi
    PROBE_OUT="$out"; PROBE_RC="$rc"
    if [ "$rc" -eq 124 ]; then
        fact "$label: n/a ($(_why_124))"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        [ -n "$out" ] && { _emit_labeled "$label (exit $rc)" "$out"; return; }
        if [ "$_pr_m" = 1 ]; then fact "$label: n/a (empty output, exit $rc)"
        else fact "$label: n/a ($(_classify_err))"; fi
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# read_proc "label" PATH [LINES] -> a /proc or /sys file's content (its last
# LINES lines when LINES is given), or "label: n/a (<why>)".
read_proc() {
    local label="$1" path="$2" cap="${3:-0}" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    if [ "$cap" -gt 0 ] 2>/dev/null; then out="$(tail -n "$cap" "$path" 2>/dev/null)"
    else out="$(cat "$path" 2>/dev/null)"; fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
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
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null || :; }

# _emit_time -> the run time; when a call was slow (SLOW_SEC), capped or not
# run, also the host load at start and end, the counts, and each such call as
# time.log has it (ms, outcome, command), in the order they happened. No sums
# or sorting: the reader or an analysis tool does that (CONTRACT.md, rule 1).
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
    fact "bounded calls that were slow (${SLOW_SEC}s+), stopped or not run, in order (ms, outcome, command):"
    awk -F'\t' -v s="$SLOW_SEC" '
        $2 != "ran" || $1 >= s * 1000 { if (++k <= 40) printf "%s ms  %s  %s\n", $1, $2, $3 }
        END { if (k > 40) printf "(%d more in this run)\n", k - 40 }' "$f" \
        | while IFS= read -r l; do fact "    $l"; done
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
_infofile=""
CMD_TIMEOUT="${CMD_TIMEOUT:-15}"
# _init_probe -> the php -i file, in the run's private directory: call it after
# _run_init, before the first php_info (run_report does, first thing)
_init_probe() { _infofile="$(_tmp probe.info)"; }

# ---- apm: probe helpers — DO NOT EDIT ---------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _classify_err -> the reason a probe failed, from _errfile. An unknown error is
# its first line; a line over 100 bytes keeps both ends, the first 45 and the
# last 52 bytes: the kind of error is at the start ("PHP Fatal error: ...",
# "Error: Cannot find module"), and after a long path the message is at the
# end ("<long path>: No module named pip").
_classify_err() {
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *[Pp]"ermission denied"*|*"peration not permitted"*) echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*)   echo "path not found";    return ;;
    esac
    if [ -n "$txt" ]; then printf 'error: %s' "$(printf '%s\n' "$txt" | awk 'NR == 1 { if (length($0) > 100) $0 = substr($0, 1, 45) "..." substr($0, length($0) - 51); print; exit }')"
    else echo "nonzero exit"; fi
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
# ---- end apm: probe helpers

# ---- apm: text helpers — DO NOT EDIT ----------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _U8CUT_AWK: the awk function u8cut(S, N) -> S cut to N bytes, then any UTF-8
# sequence left incomplete at its end dropped (cut -c and substr count bytes
# under LC_ALL=C, and a cut inside a character makes the report invalid
# UTF-8). The byte classes are looked up with index(), so mawk, busybox awk
# and gawk agree. One text for _u8cut and for the awk programs that cut a
# field (the process table), so every cut in every member is the same.
_U8CUT_AWK='function u8cut(s, n,   l, k, b, w, i) {
    if (length(s) <= n) return s
    if (!_u8n) {
        for (i = 128; i < 192; i++) _u8c = _u8c sprintf("%c", i)
        for (i = 192; i < 224; i++) _u8l2 = _u8l2 sprintf("%c", i)
        for (i = 224; i < 240; i++) _u8l3 = _u8l3 sprintf("%c", i)
        for (i = 240; i < 248; i++) _u8l4 = _u8l4 sprintf("%c", i)
        _u8n = 1 }
    s = substr(s, 1, n); l = length(s); k = l
    while (k > 0 && k > l - 3 && index(_u8c, substr(s, k, 1))) k--
    if (k > 0) {
        b = substr(s, k, 1); w = 1
        if (index(_u8l2, b)) w = 2; else if (index(_u8l3, b)) w = 3; else if (index(_u8l4, b)) w = 4
        if (w > 1 && l - k + 1 < w) s = substr(s, 1, k - 1)
    }
    return s }'

# _u8cut N -> each stdin line cut to N bytes on a UTF-8 boundary (u8cut above)
_u8cut() { awk -v n="$1" "$_U8CUT_AWK"' { print u8cut($0, n) }'; }

# /proc/<pid>/cmdline and environ are NUL-separated, and an entry may itself
# hold a newline or a CR. Printed as read, a newline puts the rest of the
# entry at column 0 of the report, where it reads as a section line of its
# own (an argument "x\n[5] Collection status" made one); inside a
# one-entry-per-line list it would read as one more entry. Every cmdline and
# environ the members read goes through one of these two, so an entry is one
# line of text.
# _proc_words FILE -> FILE on one line: each NUL, newline and CR as a space
# _proc_lines FILE -> one entry of FILE per line: each NUL as a newline, a
#   newline or CR inside an entry as a space
# Both print nothing (stderr silenced) when FILE cannot be read.
_proc_words() { { tr '\000\n\r' '   ' < "$1"; } 2>/dev/null; }
_proc_lines() { { tr '\000\n\r' '\n  ' < "$1"; } 2>/dev/null; }

# The same holds for a process's comm and for the targets of its exe, cwd and
# fd links: the process chose them. _oneline TEXT -> TEXT with each newline
# and CR as a space; it forks only when TEXT holds one.
_cr="$(printf '\r')"
_oneline() {
    case "$1" in
        *"$_nl"*|*"$_cr"*) printf '%s' "$1" | tr '\n\r' '  ' ;;
        *) printf '%s' "$1" ;;
    esac
}
# _comm PID -> /proc/PID/comm on one line, its lines joined by a space (empty
# when unreadable); read with the read builtin, no fork
_comm() {
    local l c=""
    { while IFS= read -r l; do c="${c:+$c }$l"; done < "/proc/$1/comm"; } 2>/dev/null
    _oneline "$c"
}
# _is_odd TEXT -> success when TEXT holds a newline or a CR
_is_odd() { case "$1" in *"$_nl"*|*"$_cr"*) return 0 ;; esac; return 1; }
# _link_text [-f] PATH -> readlink [-f] PATH on one line; fails as readlink does
_link_text() { local o; o="$(readlink "$@" 2>/dev/null)" || return 1; _oneline "$o"; }
# ---- end apm: text helpers

# ---- apm: file helpers — DO NOT EDIT ----------------------------------------
# members: apmnodejs apmphp apmpython
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

# _file_lines head|tail "label" PATH CAP -> the first or last CAP lines of the
# file, verbatim, or a reason. Configuration is dumped as is, never masked (the
# collector README, "What the report can contain").
_file_lines() {
    local how="$1" label="$2" path="$3" cap="$4" w=first total
    [ "$how" = tail ] && w=last
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$( { wc -l < "$path"; } 2>/dev/null | tr -d ' ')"
    fact "$label ($w $cap of ${total:-?} lines):"
    "$how" -n "$cap" "$path" 2>/dev/null | _indent '        '
}

# _sock_list TOOL FLAGS PORTS [NAMES] -> the socket table lines matching the
# ERE NAMES (default whatap) or naming one of PORTS (space-separated), header
# kept, first 50; exits with TOOL's status
_sock_list() {
    local pat rc
    pat=":($(printf '%s' "$3" | tr -s ' ' '|' | sed 's/^|//; s/|$//'))([^0-9]|\$)"
    "$1" "$2" > "$(_tmp sock.out)"; rc=$?
    awk -v p="$pat" -v n="${4:-whatap}" '(NR <= 2 && /State|Proto|Recv-Q/) || $0 ~ n || $0 ~ p' "$(_tmp sock.out)" 2>/dev/null | head -n 50
    return "$rc"
}

# _entry_line PATH -> one `ls -l`-like line with the full mtime: stat -c where
# it answers, else `ls -l` (minute precision)
_entry_line() {
    if have stat && stat -c '%A %h %U %G %s %y %N' -- "$1" 2>/dev/null; then return 0; fi
    _head_of 1 ls -l -- "$1"
}

# _pid_file_fact LABEL FILE -> the entry line of the agent pid file FILE, the
# pid it holds, and whether that process exists here (its comm, state and
# ppid); an unreadable FILE is said to be one, not taken for an empty one
_pid_file_fact() {
    local v
    probe "$1 entry" _entry_line "$2"
    [ -r "$2" ] || { fact "$1: n/a (permission denied: $2)"; return; }
    v="$(cat "$2" 2>/dev/null | tr -d ' \n')"
    if [ -n "$v" ] && [ -d "/proc/$v" ]; then
        fact "$1: $v (process exists; comm: $(_comm "$v"); state: $(awk '/^State:/{print $2" "$3}' "/proc/$v/status" 2>/dev/null); ppid: $(awk '/^PPid:/{print $2}' "/proc/$v/status" 2>/dev/null))"
    else
        fact "$1: ${v:-empty} (no process with this pid in this pid namespace)"
    fi
}
# ---- end apm: file helpers

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
        fact "$label: n/a ($(_why_124))"
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
    # The CGI SAPI prints phpinfo() as HTML; its rows become the CLI's
    # "name => value[ => value]" lines, so every reader below matches both.
    if grep -q '<td class="e">' "$_infofile" 2>/dev/null; then
        local _t _h
        _t="$(printf '\t')" _h="$(_tmp probe.info.html)"
        mv -f "$_infofile" "$_h" 2>/dev/null || return 0
        sed -e 's|<h1 class="p">PHP Version \([^<]*\)</h1>|PHP Version => \1|' \
            -e "s|</td><td class=\"v\">|$_t|g" -e 's|<[^>]*>||g' \
            -e 's|&nbsp;| |g; s|&quot;|"|g; s|&lt;|<|g; s|&gt;|>|g; s|&#039;|'"'"'|g; s|&amp;|\&|g' "$_h" 2>/dev/null \
            | awk -F"$_t" '{ o = ""; for (i = 1; i <= NF; i++) { f = $i; sub(/^ +/, "", f); sub(/ +$/, "", f); o = (i > 1) ? o " => " f : f } print o }' \
            > "$_infofile" 2>/dev/null
    fi
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

# ---- apm: process table — DO NOT EDIT ---------------------------------------
# members: apmnodejs apmphp apmpython
# _proc_table -> one line per process that has a command line, fields joined by
# the unit separator \037 (a whitespace IFS would merge empty fields):
#   pid comm exe argv0 cmdline
# Read in one pass over /proc: three readers for every pid instead of several
# forks per pid (readlink + basename per pid took 20 s on a 687-process host).
# exe is empty where /proc/<pid>/exe is not readable by this uid. `ls -l`
# prints a link target holding a newline over two lines, and the second can
# pose as the line of another pid: a line naming no /proc/<pid>/exe, or a pid
# named twice, makes the exe of the pids involved (the one named twice, and the
# one whose line came before) be read again with readlink, newlines and CRs as
# spaces; nothing else is re-read, so one process cannot make every pid cost a
# fork (rare: the common case
# stays one ls). A posing line can only name a pid that does not exist (an
# existing one has its own line), which no row joins. comm is at most 15
# bytes, shorter than any header line (17 bytes and more), and always ends in a newline:
# `head -n 16` reads every line of it in the same pass, and they are joined
# with spaces, the separator line head adds before the next header dropped.
# cmdline has
# its NULs, newlines and CRs turned into spaces and is cut at 300 bytes on a
# UTF-8 boundary (u8cut, text helpers).
# `head -n 1` stops at a newline, and after a file whose first line ended in
# one it prints a blank line before the next header (GNU and busybox alike;
# /dev/null gives the last pid a header after it). That blank line marks a
# command line holding a newline: only that pid's file is read again, whole,
# so the common case stays one pass and argv0 and the words after the newline
# are not lost. A process gone by then keeps what head read.
_us="$(printf '\037')"
_proc_table() {
    {
        ls -l /proc/[0-9]*/exe 2>/dev/null | awk '{
            if (index($0, "\r")) gsub(/\r/, " ")
            i = index($0, " -> "); q = ""
            for (f = 1; f <= NF; f++) if ($f ~ /^\/proc\/[0-9]+\/exe$/) { split($f, a, "/"); q = a[3]; break }
            if (q == "" || (q in s)) { if (pq != "") print "R\037" pq; if (q != "") print "R\037" q; next }
            s[q] = 1; pq = q; if (!i) next
            t = substr($0, i + 4); sub(/ \(deleted\)$/, "", t)
            print "E\037" q "\037" t }'
        head -n 16 /proc/[0-9]*/comm /dev/null 2>/dev/null | awk '
            function out() { if (p != "") { if (n > 1 && v == "") v = c; else if (n > 1) v = c " " v
                                 print "C\037" p "\037" v }
                             p = ""; n = 0; c = ""; v = "" }
            /^==> (\/proc\/[0-9]+\/comm|\/dev\/null) <==$/ { out(); if ($2 != "/dev/null") { split($2, a, "/"); p = a[3] }; next }
            p != "" { if (index($0, "\r") || index($0, "\037")) gsub(/[\r\037]/, " ")
                      if (n) c = (n > 1 ? c " " : "") v
                      v = $0; n++ }
            END { out() }'
        head -n 1 /proc/[0-9]*/cmdline /dev/null 2>/dev/null | tr '\000\037\r' '\001  ' | awk "$_U8CUT_AWK"'
            function emit(p, s,   i, c) {
                i = index(s, "\001"); if (i == 1 || s == "") return
                c = s; gsub(/\001/, " ", c); sub(/ +$/, "", c)
                print "A\037" p "\037" (i ? substr(s, 1, i - 1) : s) "\037" u8cut(c, 300) }
            st == 1 { d = $0; st = 2; next }
            st == 2 && $0 == "" {
                r = ""; f = "tr \"\\000\\012\\015\\037\" \"\\001   \" 2>/dev/null < /proc/" p "/cmdline"
                while ((f | getline l) > 0) r = r l
                close(f); emit(p, r != "" ? r : d); st = 0; next }
            st == 2 { emit(p, d); st = 0 }
            /^==> \/proc\/[0-9]+\/cmdline <==$/ { split($2, a, "/"); p = a[3]; st = 1 }
            END { if (st == 2) emit(p, d) }'
    } | awk -F'\037' '
        $1 == "R" { rr[$2] = 1; next }
        $1 == "E" { e[$2] = $3; next }
        $1 == "C" { c[$2] = $3; next }
        $1 == "A" { o[++n] = $2; a0[$2] = $3; cl[$2] = $4 }
        END {
            for (i = 1; i <= n; i++) { p = o[i]
                if (p in rr) { r = ""; k = 0; f = "readlink /proc/" p "/exe 2>/dev/null"
                           while ((f | getline l) > 0) r = r (k++ ? " " : "") l
                           close(f); gsub(/\r/, " ", r); sub(/ \(deleted\)$/, "", r); e[p] = r }
                print p "\037" c[p] "\037" e[p] "\037" a0[p] "\037" cl[p] } }'
}

# _note_hidepid -> sets D_HIDEPID when /proc is mounted with hidepid and this
# uid is not root: the scan then cannot see other users' processes
_note_hidepid() {
    case "$(id -u 2>/dev/null)" in
        0) ;;
        *) grep -qE '^[^ ]+ /proc proc [^ ]*hidepid=([12]|invisible|noaccess)' /proc/mounts 2>/dev/null \
               && D_HIDEPID="hidepid is set on /proc: other users' processes are not listed to uid $(id -u 2>/dev/null)" ;;
    esac
}
# ---- end apm: process table

# ---- discovery (internal; emits nothing) --------------------------------------
# Populates:
#   D_PHP_BINS    distinct php / php-fpm / php-cgi binaries (PATH, globs, procs),
#                 newline-joined
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
D_SCAN_DIRS=""      # absolute ini scan dirs the runtimes' php -i named, newline-joined
D_SCAN_REL=""       # "bin|entry" relative scan dir entries not resolved, newline-joined
# PHP binaries detailed per run. APM_INTERP_CAP in the environment raises it
# (the CLI flags are a shared block).
D_PHP_CAP=10   # set in discover
D_PHPINI_WHATAP=""  # php.ini files carrying whatap lines, filled in by section 6
D_DEFAULT_HOME="/usr/whatap/php"

# ---- apm: path helpers — DO NOT EDIT ----------------------------------------
# members: apmnodejs apmphp apmpython
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

# _quote_nl TEXT -> TEXT with each newline written as \n and each CR as \r
_quote_nl() { printf '%s' "$1" | awk '{ gsub(/\r/, "\\r") } NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

# D_ODD: candidate paths holding a newline or '|', the record delimiters, or a
# CR (a process's cwd or environ can hold any of them). They are reported,
# quoted, and counted as unread, never split into two records or looked up.
D_ODD="" D_ODD_HOME=""

# Membership tests bound by the record delimiter, so /opt/whatap is not taken
# for already listed when /data/opt/whatap is.
_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$p" in *"$_nl"*|*"$_cr"*|*"|"*)
        p="\"$(_quote_nl "$p")\""
        case "$D_ODD " in *" $p "*) ;; *) D_ODD="$D_ODD $p" ;; esac
        D_ODD_HOME=1; return ;; esac
    case "$_nl$D_HOMES" in *"$_nl$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES$_nl$p|$s"; else D_HOMES="$p|$s"; fi
}

# resolve_fs PATH -> prints a readable filesystem view of PATH: the path itself
# if it exists here, otherwise the same path seen through the root of a
# discovered agent or application process (/proc/<pid>/root<PATH>). Empty if
# neither is visible. This lets the collector run from a kubectl-debug
# ephemeral container (or any different mount namespace) and still read the
# target's files. The pid lists are each member's own (nodejs: GO APP, python:
# GO APP ODOO, php: AGENT WEB ALT); the ones a member does not have are empty.
resolve_fs() {
    local p="$1" pid
    # a relative path is never read against the collector's own cwd
    case "$p" in /*) ;; *) return 1 ;; esac
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    # shellcheck disable=SC2154  # each member sets only its own lists
    for pid in $D_GO_PIDS $D_APP_PIDS $D_ODOO_PIDS $D_AGENT_PIDS $D_WEB_PIDS $D_ALT_PIDS; do
        [ -e "/proc/$pid/root$p" ] && { printf '%s\n' "/proc/$pid/root$p"; return; }
    done
    return 1
}
# ---- end apm: path helpers

_add_svc() {  # _add_svc PATH
    local p="$1"
    [ -f "$p" ] || return
    case "$D_SERVICE_FILES" in *"|$p|"*) return ;; esac
    # the same file under another name (/lib -> usr/lib) is dumped once
    local q o="$IFS"
    IFS='|'
    for q in $D_SERVICE_FILES; do
        [ -n "$q" ] && [ "$p" -ef "$q" ] && { IFS="$o"; return; }
    done
    IFS="$o"
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
    { _proc_lines "/proc/$1/environ" | _K="$2" awk 'BEGIN { k = ENVIRON["_K"] "=" }
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
    _proc_words "/proc/$1/cmdline" | _u8cut 300
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

# _link_shown /proc/<pid>/{exe,cwd} -> the _link_target of it on one line for
# the report, or why there is none
_link_shown() {
    local t
    t="$(_link_target "$1")" && _oneline "$t" || echo 'n/a (unresolvable: exited, zombie, or permission denied)'
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
    D_PHP_CAP="$(_cap_or APM_INTERP_CAP "${APM_INTERP_CAP:-10}" 10)"
    local c p pid comm exe a0 cmd cwd envh d _php _alt

    _note_hidepid

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

    _disc_homes
    _disc_inis
}

# _disc_homes -> the agent home candidates, then the service files and the
# extension dirs they declare
_disc_homes() {
    local pid cwd envh exe d p
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
}

# _disc_inis -> the whatap ini file candidates
_disc_inis() {
    local p d
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
        g="environ/cwd/exe of $n whatap_php process(es) not readable by uid ${_priv_uid:-?} (pids: $(echo $D_UNREAD | cut -d' ' -f1-10))"
    fi
    if [ "${1:-}" = maps ] && [ -n "$D_MAPS_UNREAD" ] && [ -n "$PRIV_GAP" ]; then
        n="$(echo $D_MAPS_UNREAD | wc -w | tr -d ' ')"
        g="${g:+$g; }/proc/<pid>/maps of $n web/php process(es) not readable by uid ${_priv_uid:-?} (pids: $(echo $D_MAPS_UNREAD | cut -d' ' -f1-10))"
    fi
    [ -n "$D_HIDEPID" ] && g="${g:+$g; }$D_HIDEPID"
    [ -n "$D_DIR_UNREAD" ] && g="${g:+$g; }directory not readable by uid ${_priv_uid:-?}:$D_DIR_UNREAD"
    printf '%s' "$g"
}


# ---- numbers read from outside -------------------------------------------------
# A value from a config, a lock file or the environment is checked before any
# arithmetic or comparison: dash aborts the run on `$((x + 100))` with a
# 20-digit x, and `[ x -lt n ]` on "abc" prints "Illegal number" and is false.
# A value that fails is reported as a fact and not used.

# ---- apm: numbers — DO NOT EDIT ---------------------------------------------
# members: apmnodejs apmphp apmpython
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
# ---- end apm: numbers

# ---- apm: report helpers — DO NOT EDIT -------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _env_head -> the opening facts of the environment section: shell, uid,
# privilege, boot time and the collector's cwd
_env_head() {
    section "Collection environment"
    if [ -n "${BASH_VERSION:-}" ]; then fact "shell: bash $BASH_VERSION"
    else fact "shell: POSIX sh (non-bash)"; fi
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
}

# _cgroup_facts -> the cgroup version and the memory and cpu limits as this
# process's cgroup sees them (container-vs-host metric questions need them)
_cgroup_facts() {
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
}

# _container_facts -> the container markers, KUBERNETES_SERVICE_HOST and this
# process's cgroup lines
_container_facts() {
    local m
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
}

# _pid1_cmd -> pid 1's command line on one line (_proc_words), first 160 bytes
# (_u8cut); for probe "pid 1 command"
_pid1_cmd() { _proc_words /proc/1/cmdline | _u8cut 160; }

# _product_uuid -> the `ls -l` line of /sys/class/dmi/id/product_uuid and
# whether this run could read it, by opening and reading it (sysfs mode bits
# alone do not say). The value is printed only when it was read, as read. The
# open and the read are shell redirections and the uid is _note_privilege's,
# so a readable file costs one fork (ls); `cat` runs only to name the error
# of a failed open or read (its stderr, through _classify_err).
_product_uuid() {
    local f=/sys/class/dmi/id/product_uuid v="" l u="${_priv_uid:-?}"
    if [ ! -e "$f" ]; then fact "dmi product_uuid: n/a (path not found: $f)"; return; fi
    l="$(ls -l "$f" 2>/dev/null)"
    fact "dmi product_uuid (ls -l): ${l:-n/a (ls -l printed nothing)}"
    # `true`, not `:`: a redirection that fails on a special builtin ends a
    # POSIX shell (dash exited here)
    if ! { true < "$f"; } 2>/dev/null; then
        cat "$f" >/dev/null 2>"$_errfile"
        fact "dmi product_uuid readable by uid $u: no (open failed: $(_classify_err))"
        return
    fi
    { IFS= read -r v < "$f"; } 2>/dev/null
    if [ -n "$v" ]; then
        fact "dmi product_uuid readable by uid $u: yes"
        fact "dmi product_uuid: $(_oneline "$v")"
    elif cat "$f" >/dev/null 2>"$_errfile"; then
        fact "dmi product_uuid readable by uid $u: yes"
        fact "dmi product_uuid: (empty file)"
    else
        fact "dmi product_uuid readable by uid $u: no (opened, read failed: $(_classify_err))"
    fi
}
# ---- end apm: report helpers

# ---- apm: machine arch — DO NOT EDIT ---------------------------------------
# members: apmnodejs apmphp apmpython
# _kernel_arch -> the kernel line (uname -srm) and the machine arch, its last
# field (uname prints the fields in its own order, and a kernel release has no
# blank). Read from probe's PROBE_OUT: one uname call, no parse of the fact
# line. Without a machine field the reason is the kernel line's.
_kernel_arch() {
    probe "kernel" uname -srm
    case "$PROBE_RC:$PROBE_OUT" in
        0:*" "*) fact "machine arch: ${PROBE_OUT##* }" ;;
        *:*" "*) fact "machine arch (exit $PROBE_RC): ${PROBE_OUT##* }" ;;
        127:)    fact "machine arch: n/a (command not found: uname)" ;;
        124:)    fact "machine arch: n/a ($(_why_124))" ;;
        0:)      fact "machine arch: n/a (empty output)" ;;
        *:)      fact "machine arch: n/a ($(_classify_err))" ;;
        *)       fact "machine arch: n/a (no machine field in the uname -srm output)" ;;
    esac
}
# ---- end apm: machine arch

# ---- apm: conf bytes — DO NOT EDIT -----------------------------------------
# members: apmnodejs apmphp
# conf_bytes "label" PATH -> byte-level facts a plain `cat` hides: total bytes
# and CR (\r, 0x0D) count. Windows-edited config files reach Linux hosts
# through support cases; the reader compares these numbers against the dumped
# text. Nothing when PATH is absent or unreadable (the dump says why).
conf_bytes() {
    local label="$1" path="$2" sz cr
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$( { wc -c < "$path"; } 2>/dev/null | tr -d ' ')"
    cr="$( { tr -dc '\r' < "$path"; } 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}
# ---- end apm: conf bytes

# ---- apm: output directory — DO NOT EDIT ------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _out_check -> for --file, makes sure the --out directory (OPT_OUT, default:
# the working directory) exists and this uid can write into it, before anything
# is collected: an unwritable directory fails at once, not after a full run.
# With --stdout the report goes to stdout, and an --out given is named as not
# used. Fails (the reason on the operator stream) when the report cannot be
# written (the skeleton's _out_dir_check).
_out_check() {
    if [ "$OPT_STDOUT" = 1 ]; then
        [ -n "$OPT_OUT" ] && warn "--out $OPT_OUT is not used: the report goes to stdout (--out is for --file)"
        return 0
    fi
    _out_dir_check
}
# ---- end apm: output directory

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
_mods_names() { ls "$1"/modules/*/ 2>/dev/null | tr '\n' ' ' | _u8cut 1200; }

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
    [ -n "$edu" ] && agaps="${agaps:+$agaps; }extension_dir not readable by uid ${_priv_uid:-?}:$edu"
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
        na agent "no whatap home, whatap.so, whatap ini, service file or whatap_php process in the collector env, $D_DEFAULT_HOME, the known ini and unit paths, $pr, or the maps of $(echo $D_WEB_PIDS $D_ALT_PIDS | wc -w | tr -d ' ') web/php process(es)${D_MAPS_UNREAD:+ ($(echo $D_MAPS_UNREAD | wc -w | tr -d ' ') of them with maps not readable by uid ${_priv_uid:-?})}${absent:+; home candidate(s): $absent}"
    fi

    if [ "$iniread" = 1 ] || [ -n "$D_PHPINI_WHATAP" ]; then got conf
    elif [ -n "$iniblk" ]; then missed conf "whatap ini not readable: $iniblk$ph"
    elif [ -n "$gaps" ]; then missed conf "no whatap ini found in what this uid could read: $gaps$ph"
    else na conf "no whatap ini in the known ini locations, the ini scan dirs ($pr), the agent home(s), or a php.ini carrying whatap lines"; fi
}

# ---- report body ---------------------------------------------------------------
run_report() {
    _init_probe
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
    _env_head
    fact "tools:"
    _tool_rows --path php php-fpm apachectl httpd apache2 nginx ipcs ss netstat systemctl rpm dpkg apk readlink timeout stat awk tr sha256sum
}

# [2] host / platform
_rep_host() {
    section "Host / platform"
    _kernel_arch
    read_proc "os-release" /etc/os-release
    if have ldd; then probe "libc" sh -c "ldd --version 2>&1 | head -n 1"
    else fact "libc: n/a (command not found: ldd)"; fi
    probe "cpu count (nproc)" nproc
    _product_uuid
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | _indent '        '
    _cgroup_facts
    probe "local time" date
    probe "utc time" date -u
    probe "pid 1 command" _pid1_cmd
}

# [3] PHP runtimes: one block per distinct binary. `php -i` is executed
# once per binary and every field below is extracted from that capture.
_rep_runtimes() {
    section "PHP runtimes and SAPIs"
    fact "php binaries discovered: $(printf '%s\n' "$D_PHP_BINS" | grep -c .)"
    if [ -z "$D_PHP_BINS" ]; then
        fact "   none on PATH, in the known per-version install paths (distro, Sury, Remi, SCL, cPanel EA, Plesk, alt-php, LiteSpeed, source builds), or among running processes"
    fi
    local _n=0 php
    _php_probed=0 _php_unprobed_live=""
    # the file the PATH php-fpm resolves to, for section 4's reuse of its -v
    _fpm_path_key=""
    _which php-fpm
    [ -n "$_wp" ] && _fpm_path_key="$(readlink -f "$_wp" 2>/dev/null || echo "$_wp")"
    _php_total="$(printf '%s\n' "$D_PHP_BINS" | grep -c .)"
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
        _rep_php_bin "$php"
        php_run "   extensions loaded (php -m)" "$php" -m
    done 9<<EOF
$D_PHP_BINS
EOF
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

# _rep_php_bin PHP -> the facts of one php binary, from one `php -v` and one
# `php -i` capture
_rep_php_bin() {
    local php="$1"
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
        _php_record "$php"
    else
        fact "   php -i: n/a ($(_classify_err))"
        D_PHPI_FAIL="$D_PHPI_FAIL $php"
    fi
}

# _php_record PHP -> from the php -i capture of PHP, the paths the next reads
# need: its extension dir, its ini scan dirs, and the whatap ini files it
# parses or its scan dir holds. The values themselves are the php -i lines
# printed above; nothing here is printed again.
_php_record() {
    local php="$1"
    _f_ed="$(grep '^extension_dir =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//; s/ *=>.*//')"
    _f_sd="$(grep '^Scan this dir for additional' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//')"
    # PHP built without a scan dir prints "(none)": no scan dir is configured
    case "$_f_sd" in "(none)"|"no value") _f_sd="" ;; esac
    case "$_f_ed" in "(none)"|"no value") _f_ed="" ;; esac
    case "$_f_ed" in *"|"*) D_ODD="$D_ODD \"$_f_ed\""; _f_ed="" ;; esac
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
               else D_SCAN_UNRES="$D_SCAN_UNRES $php: $_d;"; D_SCAN_REL="$D_SCAN_REL$php|$_d$_nl"; fi ;;
        esac
        _f_sdr="${_f_sdr:+$_f_sdr:}$_d"
    done <<EOF
$(printf '%s' "$_f_sd" | tr ':' '\n')
EOF
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
        # section 6 lists it with the whatap ini names it holds
        case "$_nl$D_SCAN_DIRS$_nl" in *"$_nl$_d$_nl"*) ;; *) D_SCAN_DIRS="$D_SCAN_DIRS$_d$_nl" ;; esac
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
}

# [4] what actually serves the traffic
_rep_web() {
    section "Web server / application server layer"
    fact "web / application server binaries on PATH:"
    _tool_rows --path httpd apache2 apachectl php-fpm php5-fpm php-cgi nginx lighttpd frankenphp rr
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
            "$(_comm "$pid")" \
            "$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
        printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
        printf '           exe: %s\n' "$(_link_shown "/proc/$pid/exe")"
    done
    if [ -z "$D_ALT_PIDS" ]; then
        fact "persistent-worker PHP runtimes (swoole/octane/roadrunner/frankenphp/workerman/php-pm): none found by executable, or by command line of a PHP executable"
    else
        fact "persistent-worker PHP runtimes found:"
        for pid in $D_ALT_PIDS; do
            [ -d "/proc/$pid" ] || { printf '        -- pid %s: n/a (process exited)\n' "$pid"; continue; }
            printf '        -- pid %s comm=%s\n' "$pid" "$(_comm "$pid")"
            printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
            printf '           cwd: %s\n' "$(_link_shown "/proc/$pid/cwd")"
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

# [6] the binding: whatap.so in every extension_dir seen, the whatap ini
# files and ini directories, and the module mapped into live processes. Which
# runtime reads which extension_dir and scan dir, and its PHP API and thread
# safety, are the php -i lines of section 3; the reader matches them here.
_rep_binding() {
    section "Tracer binding (module, ini, load state)"
    _rep_binding_extdirs
    _rep_binding_inis
    _rep_binding_maps
}

# _rep_binding_extdirs -> whatap.so in each extension_dir seen (php -i of a
# runtime, or a service file), once per directory: ls, sha256, the symlink
# target and the file it resolves to
_rep_binding_extdirs() {
    if [ -z "$D_EXT_DIRS" ]; then
        fact "extension_dir values: none discovered (php -i and service files both empty)"
        return
    fi
    fact "whatap.so in each extension_dir seen (first source that named the dir):"
    printf '%s\n' "$D_EXT_DIRS" | grep -v '^$' | while IFS='|' read -r _d _s; do
        [ -n "$_d" ] || continue
        fsd="$(resolve_fs "$_d")"
        if [ -z "$fsd" ]; then fact "-- $_d   <- $_s: n/a ($(_absent_why "$_d"))"; continue; fi
        fact "-- $_d   <- $_s"
        [ "$fsd" != "$_d" ] && fact "   filesystem view: $fsd (read through a process root)"
        if [ ! -x "$fsd" ]; then
            fact "   whatap.so: n/a (permission denied: $fsd)"
        elif [ -e "$fsd/whatap.so" ]; then
            file_facts "   whatap.so" "$fsd/whatap.so"
            [ -L "$fsd/whatap.so" ] && printf '        resolved file: %s\n' "$(ls -lL "$fsd/whatap.so" 2>/dev/null)"
        else
            fact "   whatap.so: n/a (path not found: $_d/whatap.so)"
        fi
    done
}

# _rep_binding_inis -> whatap ini files, php.ini files with whatap lines, and
# the ini directory trees present
_rep_binding_inis() {
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
        grep -n -i whatap "$p" 2>/dev/null | head -n 30 | _indent '           '
    done
    [ "$_hit" = 0 ] && fact "   none found"
    fact "ini directories present and their whatap entries (known tree paths, then scan dirs php -i named in section 3):"
    _hit=0 _seen="|"
    for d in /etc/php.d /etc/php/*/cli/conf.d /etc/php/*/fpm/conf.d /etc/php/*/apache2/conf.d /etc/php/*/mods-available \
             /etc/php[0-9]*/conf.d /usr/local/etc/php/conf.d \
             /opt/remi/php*/root/etc/php.d /etc/opt/remi/php*/php.d \
             /opt/rh/*php*/root/etc/php.d /etc/opt/rh/*php*/php.d \
             /opt/cpanel/ea-php*/root/etc/php.d /opt/plesk/php/*/etc/php.d \
             /opt/alt/php*/etc/php.d /usr/local/lsws/lsphp*/etc/php.d; do
        [ -d "$d" ] || continue
        _hit=1 _seen="$_seen$d|"
        # a directory this uid cannot read lists no names: not "no entry"
        if [ -r "$d" ]; then
            _w="$(_names "$d" | grep -i whatap | tr '\n' ' ')"
            printf '        %-46s %s\n' "$d" "${_w:-(no whatap entry)}"
        else
            printf '        %-46s %s\n' "$d" "n/a (permission denied: $d)"
        fi
    done
    # a scan dir may be seen through a process root; a relative one no
    # process cwd resolved is in the status section
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        case "$_seen" in *"|$d|"*) continue ;; esac
        _hit=1 _seen="$_seen$d|"
        fd="$(resolve_fs "$d")" || { printf '        %-46s %s\n' "$d" "n/a ($(_absent_why "$d"))"; continue; }
        if [ -r "$fd" ] && [ -x "$fd" ]; then
            _w="$(_names "$fd" | grep 'whatap.*\.ini$' | tr '\n' ' ')"
            printf '        %-46s %s%s\n' "$d" "${_w:-(no *whatap*.ini)}" "$([ "$fd" != "$d" ] && printf '   (read at %s)' "$fd")"
        else
            printf '        %-46s %s\n' "$d" "n/a (permission denied: $fd)"
        fi
    done <<EOF
$D_SCAN_DIRS
EOF
    while IFS='|' read -r _b d; do
        [ -n "$d" ] || continue
        _hit=1
        printf '        %-46s %s\n' "$d" "n/a (relative scan dir of $_b, not resolved)"
    done <<EOF
$D_SCAN_REL
EOF
    [ "$_hit" = 0 ] && fact "   none of the known ini tree paths or php -i scan dirs exist on this host"
}

# _rep_binding_maps -> the whatap module mapped into running web/php processes
_rep_binding_maps() {
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
                printf '        pid %-7s comm=%-12s maps: %s\n' "$pid" "$(_comm "$pid")" "$_m"
            fi
        elif [ -e "/proc/$pid" ]; then
            D_MAPS_UNREAD="$D_MAPS_UNREAD $pid"
        fi
    done
    if [ -n "$D_MAPS_UNREAD" ]; then
        fact "   maps: n/a (not readable by uid ${_priv_uid:-?} for $(echo $D_MAPS_UNREAD | wc -w | tr -d ' ') process(es): $(echo $D_MAPS_UNREAD | cut -d' ' -f1-20))"
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
            _e="$( { _proc_lines "/proc/$pid/environ" | grep -E '^WHATAP_' | tr '\n' ' ' ; } 2>/dev/null )"
            if [ -n "$_e" ]; then _any=1; printf '        pid %-7s comm=%-16s %s\n' "$pid" "$(_comm "$pid")" "$_e"; fi
        else
            printf '        pid %-7s environ: n/a (permission denied: /proc/%s/environ)\n' "$pid" "$pid"
        fi
    done
    [ "$_any" = 0 ] && fact "   no WHATAP_* variable found in the environ of the processes inspected"
    # app_process_name drives the process-memory metric; the matching live
    # process count is the fact that makes it verifiable (section 4 details
    # at most 20 processes)
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
            if [ -e "$fshome/$f" ]; then printf '        %s: present, %s bytes\n' "$fshome/$f" "$({ wc -c < "$fshome/$f"; } 2>/dev/null | tr -d ' ')"
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
            printf '           comm: %s\n' "$(_comm "$pid")"
            printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
            printf '           exe: %s\n' "$(_link_shown "/proc/$pid/exe")"
            printf '           cwd: %s\n' "$(_link_shown "/proc/$pid/cwd")"
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
            _pid_file_fact "pid file $home/whatap_php.pid" "$fshome/whatap_php.pid"
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
                    _tot="$({ wc -l < "$_boot"; } 2>/dev/null | tr -d ' ')"
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
            printf '%s\n' "$_m" | _indent '        '
        else
            fact "   -- $p: no whatap / WA-coded line in the last 300 lines"
        fi
    done
    [ "$_hit" = 0 ] && fact "   none of the known web server error log paths exist and are readable here"
}

# [10] container / orchestration context
_rep_k8s() {
    section "Container / Kubernetes context"
    _container_facts
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

# ---- apm: main — DO NOT EDIT ------------------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# place: end
# The run itself; the last lines of every member. fd 3 = the terminal, saved
# before any redirection so progress() reaches the operator even in --file mode
# (which redirects both stdout and stderr). A member's own option checks that
# need warn go at the start of its run_report, before anything is collected.
# A closed stderr would make exec fail, which ends dash at once: fd 3 is then
# /dev/null, and the run goes on (the report does not need the terminal).
if (exec 3>&2); then exec 3>&2; else exec 3>/dev/null; fi

# No arguments -> print help and stop; a collection needs an explicit action flag.
[ "$ARGC" -eq 0 ] && { usage; exit 0; }

# Modifiers alone (e.g. --quiet) are not an action — say so and show help.
if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_run_init
_out_check || exit 1
if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="${TARGET#host/}"   # the name TARGET already resolved, not a second lookup
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="${OPT_OUT:-.}/$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
# ---- end apm: main
