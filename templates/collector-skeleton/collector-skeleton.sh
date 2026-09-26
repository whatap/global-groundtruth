#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collector skeleton
# -----------------------------------------------------------------------------
# Copy this file to collectors/<domain>/<name>.sh and fill it in. It already
# emits the shared report shape (see ../../docs/output-format.md), so you only
# add fact sections. Then run ../../tools/validate.sh against your copy.
#
# THE CONTRACT (../../CONTRACT.md) — read before editing:
#   1. Facts only: no diagnosis, cause, recommendation or fix. Report what IS.
#   2. Discover, never assume: resolve paths from the host; a value not found
#      is printed as a fact ("n/a (reason)"), never a guess.
#   3. One field command -> paste. Nothing asks the engineer to interpret.
#   4. Domain-team owned.
#
# DESIGN GUIDELINES (../../docs/collector-engineering.md):
#   * MECE sections     — every fact lives in exactly one section.
#   * Load-safe by tier — the default run is read-only and instant; expensive
#                         probes are opt-in and announced.
#   * Portable          — /proc & /sys first, fallback chains, bash 3.2+.
#   * Reasoned absence  — a missing value carries its reason (probe/read_proc).
#   * Bounded           — every external command through probe or _bounded; the
#                         run has a deadline and still reaches its footer.
#
# NOTE: no `set -e` on purpose — the run must always reach its footer.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata — EDIT THESE ----------------------------------------
COLLECTOR_NAME="whatap-skeleton"       # whatap-<token>, for collect-<token>.sh
VERSION="0.0.0"                        # x.y.z, bumped in every change
DOMAIN="server"                        # k8s | server | apm | db | nms | collection-server
# <kind>/<name>[@<qualifier>]: an identity, no spaces, never an outcome of the run
TARGET="host/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
# Guideline 5 (../../docs/collector-engineering.md): no-args prints usage — a run
# needs an explicit action flag (--file / --stdout) so nothing starts by accident;
# and progress is narrated on stderr (fd 3, see main) so the operator sees it
# working while the report on stdout stays byte-for-byte clean. --quiet silences it.
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet .. silence progress on stderr (add to --file / --stdout)
EOF
}

ARGC=$#           # 0 args -> usage (handled in main, below)
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

# section "TITLE"  -> starts the next numbered section (and narrates it to fd 3)
section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}

# fact "text"  -> one fact line under the current section
fact() {
    printf '    %s\n' "$1"
}

# try CMD [ARGS...]  -> prints the command's output as fact lines; prints "n/a"
# if the command fails or produces nothing. Simplest form; prefer `probe` below
# when you want the reason an output is missing (Contract rule 2 + guideline 4).
try() {
    local out
    if out="$("$@" 2>/dev/null)" && [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do fact "$line"; done
    else
        fact "n/a"
    fi
}

emit_footer() {
    printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'
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

# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any redirection). It NEVER lands in the report — stdout stays the report
# even in --file mode. Silenced by --quiet. Keep the text a fact about collection
# state (no judgment words) so validate.sh keeps passing.
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- reasoned-absence helpers — recommended, keep or trim as needed ---------
# These implement guideline 4 (../../docs/collector-engineering.md): a value you
# cannot obtain is reported WITH a classified reason, so the reader can tell
# "not installed" from "no permission" from "timed out". Reason strings stay
# free of judgment words so validate.sh keeps passing.
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
# Per-command cap (s); with many network probes, lower it or probe reachability once.
CMD_TIMEOUT="${CMD_TIMEOUT:-20}"
# Call after _run_init: the error file lives in the run's private directory.
_init_probe() { _errfile="$(_tmp probe.err)"; }

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

# read_proc "label" PATH -> content of a /proc or /sys file, or a reason.
read_proc() {
    local label="$1" path="$2" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    out="$(cat "$path" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# ---- report body — EDIT HERE ------------------------------------------------
# Add your fact sections inside run_report(); leave the CLI harness, the helpers,
# and the header/footer shape alone. Each `section` also narrates itself to the
# terminal (guideline 5), so you get progress for free.
run_report() {
    emit_header

    # Declare what this run is for, before collecting anything. Keep the list
    # short: a goal is something whose absence makes the bundle not worth
    # sending, not every value the collector happens to print.
    goal identity "host identity"
    goal example  "the thing this collector exists to obtain"

    # Guideline 4: a capability preamble makes every downstream "command not found"
    # self-explanatory. List the tools your collector relies on.
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown)"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    # Say why this collector needs the denominator, then call it. Nearly every
    # cumulative value a collector reports is since-boot.
    _note_boot
    fact "tools:"
    for t in ss findmnt systemctl; do   # <- replace with the tools you use
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"
        else printf '        %-12s absent\n' "$t"; fi
    done

    # Placeholder: a discovered value, reported as a fact (with a reason if absent).
    section "Host identity"
    probe "hostname" hostname
    probe "kernel" uname -sr
    if hostname >/dev/null 2>&1 || [ -r /proc/sys/kernel/hostname ]; then got identity
    else missed identity "neither hostname nor /proc/sys/kernel/hostname answered"; fi

    # Placeholder: resolve rather than assume (Contract rule 2). Replace the target
    # with whatever your domain actually needs to resolve.
    section "Example resolved value"
    fact "replace this section with your domain's facts"
    fact "when a value is absent, print it as a fact with its reason — n/a (...)"
    missed example "replace this with got/missed at the point the value is resolved"

    # Always last, immediately before the footer.
    emit_status
    emit_footer
}

# ---- main — DO NOT EDIT -----------------------------------------------------
# fd 3 = the terminal, saved before any redirection so progress() reaches the
# operator even in --file mode (which redirects both stdout and stderr).
exec 3>&2

# No arguments -> print help and stop; a collection needs an explicit action flag.
[ "$ARGC" -eq 0 ] && { usage; exit 0; }

# Modifiers alone (e.g. --quiet) are not an action — say so and show help.
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
    HOST="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="./$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
