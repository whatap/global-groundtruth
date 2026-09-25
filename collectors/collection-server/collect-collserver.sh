#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collection-server collector (seeded v0)
# -----------------------------------------------------------------------------
# Gathers facts about a WhaTap backend host (yard/proxy/gateway/keeper/account/
# notihub/eureka/front/...) so a remote developer does not have to ask the field
# engineer twenty questions. Emits the shared report shape (docs/output-format.md)
# to a single .txt file; with --bundle it also archives real logs, configs and
# host snapshots as a tar.gz.
#
# THE CONTRACT (../../CONTRACT.md) — facts only, no diagnosis / no judgment.
# DESIGN GUIDELINES (../../docs/collector-engineering.md):
#   * MECE sections     — every fact lives in exactly one domain (A..F below).
#   * Load-safe by tier — Tier 0 (default report) never runs a command that can
#                         pause a JVM (jstack/jmap), walk a huge tree (recursive
#                         du) or read whole rotated logs. Heavy probes are opt-in.
#   * Portable          — read /proc and /sys first; fall back through command
#                         chains; target bash 3.2+; assume nothing about the OS.
#   * Reasoned absence  — a value we cannot obtain is a fact too, carrying WHY
#                         (command not found / permission denied / path not found
#                         / timed out / not applicable / empty output).
#
# NOTE: no `set -e` / no `set -u`. A collector must run to completion and emit
# its footer even when individual steps fail; each step guards itself.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-collserver"
# 0.7.0  sudo is a first-class way to run this. The collector only reads the
#        host; it writes into a mktemp work dir and the output tarball and
#        nowhere else, so root adds reach without adding reach into anything
#        else. Two things follow. The bundle is handed back to the invoking
#        user (SUDO_UID) so the operator who started the run can still move and
#        delete the one file they came for, and the header records that the run
#        came through sudo and from whom. The blocked-goal reasons name sudo
#        alongside the owning account: one of them gets the module configs, and
#        only root also gets the system journal and dmesg.
# 0.6.0  the systemd journal is a goal of its own, and an empty one now says
#        which kind of empty it is. journalctl does not fail for an
#        unprivileged uid: it narrows to that user's own entries and prints
#        "-- No entries --", which reads the same as a unit that logged nothing.
#        journal_why() reports whether this uid can read the system journal, so
#        the two are told apart. dmesg keeps its error message instead of
#        leaving a 0-byte file. Reason: all three Smartfren bundles carried 8-9
#        unit journals of exactly "-- No entries --" and a 0-byte dmesg-tail.txt,
#        and nothing in the report or the status mentioned either (2026-09-23).
# 0.5.0  the report ends with a Collection status section, and the operator is
#        told on stderr when a run did not obtain what it came for (even under
#        --quiet). Goals: running modules, WHATAP_HOME contents, module configs,
#        log inventory, and yard data path on hosts that run yard.
# 0.4.1  D/F/G say WHY a WHATAP_HOME-relative path came back empty. "WHATAP_HOME
#        not resolved" was printed even when the report had just printed the
#        resolved path, and permission problems were reported as "path not
#        found". Four reasons now: not resolved / resolved but unreachable /
#        unsearchable / genuinely absent. Reason: two Smartfren bundles carried
#        no conf/ at all and the stated reason sent the reader after root access
#        when the fix was to run as the owning account (2026-09-23).
# 0.4.0  bundle logs get a total cap, not just a per-file one. Rotated logs are
#        opt-in (--with-rotated) and the per-file default drops 50MB -> 5MB. What
#        is left out is written to logs/SELECTION.txt with a reason per file and
#        summarized in the report's G section. Reason: a production collection
#        server produced a 393MB bundle that the field could not move; 99.95% of
#        it was logs (sf-whatap-web02-bsd, 2026-09-23).
VERSION="0.8.1"
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

# ---- shared emit helpers (shape is fixed by the framework) ------------------
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

section() { _section_n=$((_section_n + 1)); printf '\n[%d] %s\n' "$_section_n" "$1"; progress "[$_section_n] $1"; }
subsection() { printf '\n    -- %s --\n' "$1"; }
fact() { printf '    %s\n' "$1"; }

# try CMD...  -> output as facts, or a bare "n/a" (kept for simple cases).
try() {
    local out
    if out="$("$@" 2>/dev/null)" && [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do fact "$line"; done
    else
        fact "n/a"
    fi
}

emit_footer() { printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'; }

# ---- reasoned-absence helpers (see docs/collector-engineering.md) -----------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_init_errfile() { _errfile="$(_tmp probe.err)"; }
_timeout_bin=""
CMD_TIMEOUT=20

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

# probe "label" CMD [ARGS...] -> emits output as facts, or "label: n/a (<why>)"
probe() {
    local label="$1"; shift
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        fact "$label: n/a (command not found: $bin)"; return
    fi
    local out rc
    if [ -n "$_timeout_bin" ]; then
        out="$("$_timeout_bin" "$CMD_TIMEOUT" "$@" 2>"$_errfile")"; rc=$?
    else
        out="$("$@" 2>"$_errfile")"; rc=$?
    fi
    if [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ]; then
        fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return
    fi
    if [ "$rc" -ne 0 ]; then
        fact "$label: n/a ($(_classify_err))"; return
    fi
    if [ -z "$out" ]; then
        fact "$label: n/a (empty output)"; return
    fi
    _emit_labeled "$label" "$out"
}

# probe_merged: like probe but folds stderr into stdout (for tools that print to
# stderr, e.g. `java -version`).
probe_merged() {
    local label="$1"; shift
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        fact "$label: n/a (command not found: $bin)"; return
    fi
    local out rc
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$@" 2>&1)"; rc=$?
    else out="$("$@" 2>&1)"; rc=$?; fi
    if [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ]; then fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; fi
    if [ -z "$out" ]; then fact "$label: n/a (empty output)"; return; fi
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


# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any stdout/stderr redirection). It NEVER lands in the report — stdout stays
# byte-for-byte the report even in --file mode. Silenced by --quiet. Keep the text a
# fact about collection state (no judgment words) so validate.sh keeps passing.
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- portable helpers -------------------------------------------------------
cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

get_listen_ports() {
    if have ss; then
        ss -ltn 2>/dev/null | awk 'NR>1{n=split($4,a,":"); print a[n]}'
    elif have netstat; then
        netstat -ltn 2>/dev/null | awk '/^tcp/{n=split($4,a,":"); print a[n]}'
    else
        # /proc/net/tcp{,6}: state 0A == LISTEN; local port is hex after ':'
        awk '$4=="0A"{split($2,a,":"); print a[2]}' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
            | while IFS= read -r h; do [ -n "$h" ] && printf '%d\n' "$((16#$h))"; done
    fi
}

fstype_of() {
    local p="$1"
    if have findmnt; then findmnt -no FSTYPE -T "$p" 2>/dev/null && return; fi
    if have stat; then stat -f -c '%T' "$p" 2>/dev/null && return; fi
    echo ""
}

source_of() {
    local p="$1"
    have findmnt && findmnt -no SOURCE -T "$p" 2>/dev/null
}

# systemd helpers — avoid `--value` (unsupported on systemd <230 / Ubuntu 16.04)
sd_show() { have systemctl && systemctl show -p "$1" "$2.service" 2>/dev/null | cut -d= -f2-; }
unit_loaded() { [ "$(sd_show LoadState "$1")" = "loaded" ]; }

WHATAP_UNITS="yard proxy gateway keeper account notihub eureka front router billing crane flexreport"

# ---- discovery (run once) ---------------------------------------------------
# PIDS[] and MODS[] are parallel indexed arrays of discovered whatap JVMs.
discover_services() {
    PIDS=(); MODS=()
    local d pid cl mod
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cl="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$cl" in
            *whatap.server.*|*whatap.opslake.*|*.yard.boot*)
                pid="${d#/proc/}"
                # module name comes from the jar (reliable), not the first cmdline
                # token — otherwise "-Dwhatap.server.home=" would win every time.
                local _jar _mod
                _jar="$(printf '%s\n' "$cl" | grep -oE 'whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar' | head -n1)"
                if [ -n "$_jar" ]; then
                    _mod="$(printf '%s' "$_jar" | grep -oE 'whatap\.(server|opslake)\.[a-zA-Z0-9]+' | head -n1)"
                else
                    _mod="$(printf '%s\n' "$cl" | tr ' ' '\n' | grep -oE 'whatap\.(server|opslake)\.[a-zA-Z0-9]+' | grep -vE '\.(home|conf|path|timezone)$' | head -n1)"
                fi
                mod="$_mod"
                [ -z "$mod" ] && mod="whatap.(unknown-module)"
                PIDS[${#PIDS[@]}]="$pid"
                MODS[${#MODS[@]}]="$mod"
                ;;
        esac
    done
}

WHOME=""
WHOME_SRC=""
resolve_home() {
    local i pid cl v unit wd
    if [ -n "$OPT_HOME" ]; then WHOME="$OPT_HOME"; WHOME_SRC="option --home"; return; fi
    # from a running JVM's -Dwhatap.server.home=
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; cl="$(cmdline_of "$pid")"
        v="$(printf '%s\n' "$cl" | grep -oE '[-]Dwhatap\.server\.home=[^ ]+' | head -n1 | cut -d= -f2-)"
        if [ -n "$v" ]; then WHOME="$v"; WHOME_SRC="process $pid (-Dwhatap.server.home)"; return; fi
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
    WHOME=""; WHOME_SRC="n/a (not resolved)"
}

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
    fact "note: every 'n/a (...)' below names why a value was not obtained"

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
    # Clock skew on a collection server puts data in the wrong time buckets and
    # trips time-based queries/alerts. These are facts about the clock and its
    # sync state (no judgment). "Wrong" needs a reference: the running NTP daemon
    # already computed its offset, so Tier 0 harvests that with NO network call;
    # an external comparison is opt-in (--time-ref) because it hits the network.
    section "B. Time & clock synchronization"
    probe "timedatectl" timedatectl
    fact "system timezone: $( { cat /etc/timezone 2>/dev/null; } || { readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'; } || echo 'n/a' )"
    fact "local time: $(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo n/a)"
    fact "UTC time:   $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo n/a)"
    read_proc "clocksource" /sys/devices/system/clocksource/clocksource0/current_clocksource
    fact "virtualization: $(systemd-detect-virt 2>/dev/null || echo 'n/a (command not found or bare metal)')"
    # WhaTap servers run with -Duser.timezone (yard forces GMT); surface it per JVM.
    local jtz="" _ti _tz
    _ti=0
    while [ "$_ti" -lt "${#PIDS[@]}" ]; do
        _tz="$(cmdline_of "${PIDS[$_ti]}" | grep -oE '[-]Duser\.timezone=[^ ]+' | head -n1)"
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
            fact "$_sd.service: active=$(systemctl is-active "$_sd.service" 2>/dev/null) enabled=$(systemctl is-enabled "$_sd.service" 2>/dev/null)"
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
    if [ -n "$YARDBASE" ]; then
        fact "yardbase path: $YARDBASE ($( [ -d "$YARDBASE" ] && echo present || echo 'path not found' ))"
        if [ -d "$YARDBASE" ]; then got yardbase
        else missed yardbase "resolved to $YARDBASE, not reachable by uid $(id -u 2>/dev/null || echo '?')$(_priv_hint)"; fi
    else
        fact "yardbase path: n/a (not resolved from yard.conf or WHATAP_HOME/yardbase)"
        missed yardbase "not resolved from yard.conf or WHATAP_HOME/yardbase"
    fi
    local ypath fstype src
    ypath="$YARDBASE"; [ -z "$ypath" ] && ypath="$WHOME"; [ -z "$ypath" ] && ypath="."
    fstype="$(fstype_of "$ypath")"; [ -z "$fstype" ] && fstype="n/a (not resolved)"
    src="$(source_of "$ypath")"; [ -z "$src" ] && src="n/a"
    fact "yardbase filesystem type: $fstype"
    fact "yardbase mount source: $src"
    if have findmnt; then probe "mount (findmnt)" findmnt -no FSTYPE,SOURCE,TARGET,OPTIONS -T "$ypath"; fi
    probe "capacity (df -h)" df -h "$ypath"
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
        fact "n/a (not applicable: zfs/zpool commands absent — this host does not run ZFS)"
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
    if [ -n "$WHOME" ] && [ -d "$WHOME" ]; then
        probe "top-level (depth 1)" ls -1 "$WHOME"
        if [ -d "$WHOME/lib" ]; then probe "lib jars" ls -1 "$WHOME/lib"; else fact "lib jars: n/a ($(home_why lib))"; fi
        if [ -d "$WHOME/conf" ]; then probe "conf files" ls -1 "$WHOME/conf"; else fact "conf files: n/a ($(home_why conf))"; fi
        got home
    else
        fact "layout: n/a ($(home_why))"
        if _no_whatap_here; then na home "WhaTap is not installed on this host"
        else missed home "$(home_why)"; fi
    fi

    # -- E. Runtime processes (current state) ---------------------------------
    section "E. Runtime processes (current state)"
    if [ "${#PIDS[@]}" -eq 0 ]; then
        fact "no whatap.server.* / whatap.opslake.* JVM found in /proc (none running, or /proc unreadable)"
        if [ -r /proc ]; then na services "no whatap module is running on this host"
        else missed services "/proc is not readable by uid $(id -u 2>/dev/null || echo '?')$(_priv_hint)"; fi
    else
        got services
    fi
    local i pid mod cl jar xmx xx rss st
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"; cl="$(cmdline_of "$pid")"
        subsection "$mod (pid $pid)"
        jar="$(printf '%s\n' "$cl" | grep -oE 'whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar' | head -n1)"; [ -z "$jar" ] && jar="n/a"
        xmx="$(printf '%s\n' "$cl" | grep -oE '[-]Xm[sx][0-9]+[kKmMgG]?' | tr '\n' ' ')"; [ -z "$xmx" ] && xmx="n/a"
        xx="$(printf '%s\n' "$cl" | grep -oE '[-]XX:[^ ]+' | tr '\n' ' ')"; [ -z "$xx" ] && xx="n/a"
        rss="$(awk '/^VmRSS/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"; [ -z "$rss" ] && rss="n/a"
        st="$(ps -o lstart= -p "$pid" 2>/dev/null)"; [ -z "$st" ] && st="n/a"
        fact "jar(version): $jar"
        fact "heap flags: $xmx"
        fact "-XX flags: $xx"
        fact "RSS: $rss"
        fact "started: $st"
        i=$((i + 1))
    done
    subsection "PID run-files"
    if [ -n "$WHOME" ] && [ -d "$WHOME" ]; then probe "*.run" ls -1 "$WHOME"/*.run; else fact "*.run: n/a ($(home_why))"; fi
    subsection "listening ports"
    local lports p name port
    lports=" $(get_listen_ports | tr '\n' ' ') "
    for p in "yard-data 6610" "yard-data-alt 6600" "yard-web 7710" "yard-sync 6620" "yard-rpc 7770" \
             "proxy-web 7700" "eureka 6761" "keeper 6789" "gateway-http 8800" "gateway-grpc 8870" \
             "notihub 6500" "front 8080" "account 18080"; do
        name="${p% *}"; port="${p#* }"
        case "$lports" in *" $port "*) fact "$name ($port): LISTEN" ;; *) fact "$name ($port): not listening" ;; esac
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
            fact "$unit.service: active=$(systemctl is-active "$unit.service" 2>/dev/null) enabled=$(systemctl is-enabled "$unit.service" 2>/dev/null) restarts=$(sd_show NRestarts "$unit")"
        done
        [ "$any" = 0 ] && fact "no whatap *.service units are installed (LoadState != loaded)"
    else
        fact "systemd: n/a (command not found: systemctl — non-systemd host or container)"
    fi

    # -- F. Configuration (raw) -----------------------------------------------
    section "F. Configuration"
    if [ -n "$WHOME" ] && [ -d "$WHOME/conf" ]; then
        local cf _cfn=0
        for cf in "$WHOME"/conf/*.conf; do
            [ -e "$cf" ] || { fact "no *.conf files under $WHOME/conf"; break; }
            _cfn=$((_cfn + 1))
            fact "$(basename "$cf") ($(wc -c < "$cf" 2>/dev/null | tr -d ' ') bytes, mtime $(date -u -r "$cf" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)):"
            dump_file "$cf"
        done
        # A readable but empty conf/ is not the same as an unreadable one.
        if [ "$_cfn" -gt 0 ]; then got conf; else na conf "conf/ is readable and holds no *.conf"; fi
    else
        fact "conf/: n/a ($(home_why conf))"
        if _no_whatap_here; then na conf "WhaTap is not installed on this host"
        else missed conf "$(home_why conf)"; fi
    fi

    # -- G. Logs & recent events ----------------------------------------------
    section "G. Logs & recent events"
    if [ -n "$WHOME" ] && [ -d "$WHOME/logs" ]; then
        # A production yard accumulates hundreds of rotated logs (logback
        # "<base>.<yyyyMMdd>.<i>.log"). Listing each drowns the report and reading
        # the tail of every one is real disk load — so current logs are listed
        # individually while rotated ones are summarized per base (metadata only).
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
            if [ "$LOGSEL_DROP_N" -gt 0 ]; then
                if [ "$OPT_ROTATED" = 1 ]; then
                    fact "to collect more: raise --max-total-mb / --max-log-mb, or --log-days for older rotated logs"
                else
                    fact "to collect more: re-run with --with-rotated, and raise --max-total-mb if needed"
                fi
            fi
        fi

        subsection "recent ERROR/WARN/Exception counts (current logs only, last 2MB each)"
        for _f in "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log; do
            [ -f "$_f" ] || continue
            case "$_f" in *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;; esac
            local c; c="$(tail -c 2097152 "$_f" 2>/dev/null | grep -cE 'ERROR|WARN|Exception' 2>/dev/null)"
            fact "${_f#"$WHOME"/}: ${c:-0}"
        done
        subsection "per-service log tails (base logs, newest-first, 40 lines each)"
        # A collection server co-locates many service logs (yard/proxy/gateway/
        # keeper/account/notihub/eureka/front) — tail each base *.log, not just
        # one. Sorted by mtime (ls -t) so the actively-written logs come first;
        # excludes rotated .log.<date> and the _self/_api/access/checker/gc
        # streams. Bounded: 40 lines each, at most 12 logs (rest are in inventory).
        local TAIL_LINES=40 LOG_TAIL_FILES=12 _lc=0 _lf _lslist
        # `ls -1t` and not a glob: this wants newest-first and a glob cannot
        # sort. Read it one line at a time so a log name containing a space
        # survives, and feed the loop with a heredoc so it stays in this shell
        # (a pipe would put _lc in a subshell and lose the count).
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
                fact "(+ more base logs not tailed — see inventory above; use --bundle for full logs)"
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
        local chk; chk="$(find "$WHOME/logs" -maxdepth 2 -name '*checker*.log' 2>/dev/null | head -n1)"
        if [ -n "$chk" ]; then fact "$chk (last 20 lines):"; tail -n 20 "$chk" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else fact "checker log: n/a (path not found)"; fi
    else
        fact "logs/: n/a ($(home_why logs))"
        if _no_whatap_here; then na logs "WhaTap is not installed on this host"
        else missed logs "$(home_why logs)"; fi
    fi
    subsection "heap dumps / GC log / restart"
    if [ -n "$WHOME" ]; then
        probe "*.hprof" sh -c "ls -la $WHOME/*.hprof $WHOME/logs/*.hprof 2>/dev/null || true"
        fact "gc log: $( ls "$WHOME"/logs/gc*.log >/dev/null 2>&1 && echo present || echo 'n/a (not enabled by default)' )"
        if [ -f "$WHOME/restart.out" ]; then fact "restart.out (last 20 lines):"; tail -n 20 "$WHOME/restart.out" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else fact "restart.out: n/a (path not found)"; fi
    fi
    subsection "journal errors (last ${OPT_HOURS}h, bounded, installed units only)"
    _jwhy="$(journal_why)"
    _jhits=0
    if have journalctl; then
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            local jout
            jout="$(journalctl -u "$unit.service" -p err --since "${OPT_HOURS} hours ago" -n 20 --no-pager 2>/dev/null)"
            case "$jout" in
                ''|*'-- No entries --'*) ;;
                *) _jhits=$((_jhits + 1))
                   fact "$unit.service (last 20 err):"
                   printf '%s\n' "$jout" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done ;;
            esac
        done
    fi
    # An empty journal has two causes that print the same thing. Say which.
    if [ -n "$_jwhy" ]; then
        fact "journal: n/a ($_jwhy)"
        missed journal "$_jwhy"
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
# Why a WHATAP_HOME-relative path produced nothing. "not resolved" and "resolved
# but this account cannot read it" lead to different next steps: the first needs
# --home, the second needs a different account. The collector used to print
# "WHATAP_HOME not resolved" for both, two lines after printing the resolved
# path, which reads as a contradiction and sends the reader the wrong way.
#
# Real case (Smartfren, 2026-09-23): three hosts, collector run as uid 3103 on
# all three, WhaTap installed under uid 1001 (whatap). On web02-bsd uid 3103
# could traverse /data/whatap and conf/ + logs/ came back; on both web01 hosts
# it could not, and the bundles carried no conf/ at all. The report blamed
# "WHATAP_HOME not resolved" and the reader concluded the collector needed root.
# It did not. It needed the account that owns the installation.
# _no_whatap_here -> true when nothing on this host says WhaTap is installed.
# Then an unresolved WHATAP_HOME is not a blocked run, it is the answer, and
# passing --home would only point the collector at a path that is not there.
_no_whatap_here() {
    [ -z "$WHOME" ] || return 1
    [ "${#PIDS[@]}" -eq 0 ] || return 1
    if have systemctl && systemctl list-unit-files 2>/dev/null \
        | grep -qE '^(yard|proxy|gateway|keeper|account|notihub|eureka|front|flexreport)\.service'; then
        return 1
    fi
    return 0
}

home_why() {
    local sub="$1" path="$WHOME"
    [ -n "$sub" ] && path="$WHOME/$sub"
    local uid; uid="$(id -u 2>/dev/null || echo '?')"
    if [ -z "$WHOME" ]; then
        printf 'WHATAP_HOME not resolved; pass --home DIR'
    elif [ ! -d "$WHOME" ]; then
        # stat() on WHOME itself failed, so its parent is not searchable by us.
        printf 'WHATAP_HOME resolved to %s (via %s) but uid %s cannot reach it; run with sudo or as the account that owns the installation' \
            "$WHOME" "$WHOME_SRC" "$uid"
    elif [ ! -x "$WHOME" ]; then
        # WHOME stats but we cannot search it, so every path under it would come
        # back "not found". Say permission, not absence — they are different bugs.
        printf 'uid %s cannot search %s (no execute permission); run with sudo or as the account that owns the installation' \
            "$uid" "$WHOME"
    elif [ ! -d "$path" ]; then
        printf 'path not found: %s' "$path"
    elif [ ! -r "$path" ]; then
        printf 'uid %s cannot read %s' "$uid" "$path"
    else
        printf 'unreadable: %s' "$path"
    fi
}

# journal_why -> empty when this uid can read the SYSTEM journal, otherwise the
# reason it cannot. This exists because journalctl does not fail for an
# unprivileged user: it silently narrows to that user's own entries and prints
# "-- No entries --" for every unit, which is byte-identical to a unit that
# logged nothing. Without this probe the report cannot tell a quiet host from a
# journal it was never allowed to open, and the reader cannot either.
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
            printf 'uid %s cannot read %s (groups: %s); journalctl then shows only entries from this user; run with sudo' \
                "$uid" "$f" "$(id -nG 2>/dev/null | tr ' ' ',')"
            return
        done
    done
    printf 'no system journal file under /var/log/journal or /run/log/journal'
}

collect_conf() {
    local dest="$1"
    [ -n "$WHOME" ] && [ -d "$WHOME/conf" ] || { warn "conf: skipped (no WHATAP_HOME/conf)"; return; }
    mkdir -p "$dest" 2>/dev/null
    cp -a "$WHOME/conf/." "$dest/" 2>/dev/null
    progress "conf: copied $WHOME/conf"
}

# Results of the last collect_logs run, read back by the report's G section.
LOGSEL_RAN=0 LOGSEL_KEPT_N=0 LOGSEL_KEPT_BYTES=0 LOGSEL_SRC_BYTES=0
LOGSEL_TRUNC_N=0 LOGSEL_DROP_N=0 LOGSEL_DROP_BYTES=0 LOGSEL_REASON=""

collect_logs() {
    local dest="$1"
    [ -n "$WHOME" ] && [ -d "$WHOME/logs" ] || { warn "logs: skipped (no WHATAP_HOME/logs)"; return; }

    # Two caps, because one file being huge and many files being large are
    # different failures. The per-file cap alone let a production collection
    # server produce a 393MB bundle whose logs were 99.95% of it (sf-whatap-web02
    # -bsd, 2026-09-23: 129 log files, 412,175,707 bytes; everything else was
    # 220,834). The field could not get that file out. So:
    #   * per-file cap  — tail, so the newest end of a big log survives
    #   * total cap     — stop once all copied logs together reach it
    #   * rotated logs  — opt-in; current logs alone answer most questions
    # Whatever is not copied is written down with its reason. CONTRACT.md 1 says
    # facts only: a file we left out is a fact, and it must not read as a file
    # that did not exist.
    local cap=$((OPT_MAXLOG_MB * 1024 * 1024))
    local total_cap=$((OPT_MAXTOTAL_MB * 1024 * 1024))
    local days="$OPT_LOG_DAYS"
    local list sel
    list="$(mktemp 2>/dev/null || echo "/tmp/.collsel.$$.list")"
    sel="$dest/SELECTION.txt"
    mkdir -p "$dest" 2>/dev/null

    # Candidates, newest first. Current (non-rotated) logs sort ahead of rotated
    # ones so the total cap never spends itself on history before the live logs.
    find "$WHOME/logs" -maxdepth 2 -type f \( -name '*.log' -o -name '*.log.*' \) 2>/dev/null |
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
        if [ "$kind" = rotated ] && [ -z "$(find "$f" -mtime "-$days" 2>/dev/null)" ]; then
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
}

collect_fs() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have findmnt && findmnt > "$dest/findmnt.txt" 2>/dev/null
    have df && df -T > "$dest/df-T.txt" 2>/dev/null
    cat /proc/self/mountinfo > "$dest/mountinfo.txt" 2>/dev/null
    if have zpool; then
        zpool status -v > "$dest/zpool-status.txt" 2>/dev/null
        zpool list > "$dest/zpool-list.txt" 2>/dev/null
        zpool history > "$dest/zpool-history.txt" 2>/dev/null
    fi
    if have zfs; then
        zfs list -o space > "$dest/zfs-list.txt" 2>/dev/null
        [ -n "$YARDBASE" ] && zfs get all "$(source_of "$YARDBASE")" > "$dest/zfs-get.txt" 2>/dev/null
    fi
    cat /proc/spl/kstat/zfs/arcstats > "$dest/arcstats.txt" 2>/dev/null
    progress "fs: snapshot written"
}

collect_os() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have ps && ps aux > "$dest/ps-aux.txt" 2>/dev/null
    have ss && ss -s > "$dest/ss-summary.txt" 2>/dev/null
    have ss && ss -ltnp > "$dest/ss-listen.txt" 2>/dev/null
    have df && df -h > "$dest/df-h.txt" 2>/dev/null
    have free && free -m > "$dest/free.txt" 2>/dev/null
    cat /proc/loadavg > "$dest/loadavg.txt" 2>/dev/null
    # dmesg is refused for an unprivileged uid when kernel.dmesg_restrict=1, and
    # discarding stderr turned that into a 0-byte file carrying no reason. Keep
    # whatever the command said instead (all three Smartfren bundles: 0 bytes).
    { dmesg 2>&1 || true; } | tail -n 200 > "$dest/dmesg-tail.txt" 2>/dev/null
    [ -s "$dest/dmesg-tail.txt" ] || printf 'dmesg produced no output and no message (uid %s)\n' \
        "$(id -u 2>/dev/null || echo '?')" > "$dest/dmesg-tail.txt" 2>/dev/null
    have top && top -bn1 2>/dev/null | head -n 40 > "$dest/top.txt" 2>/dev/null
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
    have timedatectl && timedatectl > "$dest/timedatectl.txt" 2>&1
    have timedatectl && timedatectl timesync-status > "$dest/timesync-status.txt" 2>&1
    if have chronyc; then
        chronyc tracking    > "$dest/chrony-tracking.txt"   2>&1
        chronyc -n sources  > "$dest/chrony-sources.txt"    2>&1
        chronyc sourcestats > "$dest/chrony-sourcestats.txt" 2>&1
    fi
    have ntpq && ntpq -pn > "$dest/ntpq.txt" 2>&1
    cat /sys/devices/system/clocksource/clocksource0/current_clocksource > "$dest/clocksource.txt" 2>/dev/null
    readlink -f /etc/localtime > "$dest/localtime.txt" 2>/dev/null
    progress "time: snapshot written"
}

collect_journal() {
    local dest="$1"; have journalctl || { warn "journal: skipped (journalctl absent)"; return; }
    mkdir -p "$dest" 2>/dev/null
    local unit
    for unit in $WHATAP_UNITS; do
        unit_loaded "$unit" || continue
        journalctl -u "$unit.service" --since "${OPT_HOURS} hours ago" --no-pager > "$dest/$unit.journal.txt" 2>/dev/null
    done
    progress "journal: last ${OPT_HOURS}h written"
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
            if have jstack; then jstack -l "$pid" > "$dest/$mod-$pid.jstack.$k.txt" 2>&1
            else kill -3 "$pid" 2>/dev/null; printf 'jstack absent; sent SIGQUIT to %s (output goes to the JVM stdout/journal)\n' "$pid" > "$dest/$mod-$pid.sigquit.$k.txt"; fi
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
        jmap -histo "$pid" 2>&1 | head -n 200 > "$dest/$mod-$pid.histo.txt" 2>/dev/null
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
        jmap -dump:format=b,file="$dest/$mod-$pid.hprof" "$pid" > "$dest/$mod-$pid.heap.log" 2>&1
        i=$((i + 1))
    done
}

collect_du() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$YARDBASE" ] && [ -d "$YARDBASE" ] || { warn "[Tier2] du: yardbase absent"; return; }
    warn "[Tier2] recursive du of $YARDBASE — reads data-disk metadata"
    if have timeout; then timeout 120 du --max-depth=1 -h "$YARDBASE" > "$dest/yardbase-du.txt" 2>&1
    else du --max-depth=1 -h "$YARDBASE" > "$dest/yardbase-du.txt" 2>&1; fi
}

do_bundle() {
    local work tarball
    work="$(mktemp -d 2>/dev/null || echo "$OPT_OUT/$BASENAME.tmp.$$")"
    mkdir -p "$work" 2>/dev/null
    # Logs are selected BEFORE the report is written so the report can state what
    # this bundle carries and what it left out (G section, "logs copied into this
    # bundle"). The report otherwise describes the host only, and the reader
    # cannot tell an absent log from a dropped one.
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
    if have tar; then
        # Use -C instead of `cd "$work"`: with a relative --out (the default "."),
        # a `cd` into $work would make $tarball land INSIDE $work and then be
        # deleted with it. -C changes only where tar reads inputs; $tarball stays
        # relative to the caller's CWD. Only remove $work if tar actually wrote it.
        if tar -C "$work" -czf "$tarball" . 2>/dev/null && [ -f "$tarball" ]; then
            # Under sudo the tarball is root-owned, and the operator who started
            # the run then cannot move or delete the one file they came for.
            if [ "$(id -u 2>/dev/null)" = 0 ] && [ -n "${SUDO_UID:-}" ]; then
                chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$tarball" 2>/dev/null
            fi
            progress "bundle: $tarball"
            rm -rf "$work" 2>/dev/null
        else
            warn "tar failed — artifacts left under $work"
        fi
    else
        warn "tar: command not found — artifacts left under $work"
    fi
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

_run_init
_init_errfile
have timeout && _timeout_bin="$(command -v timeout)"
mkdir -p "$OPT_OUT" 2>/dev/null

progress "discovering WhaTap services / resolving WHATAP_HOME ..."
discover_services
resolve_home
resolve_yardbase
TARGET="collection-server/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)${WHOME:+@$WHOME}"
progress "WHATAP_HOME: ${WHOME:-n/a} (via $WHOME_SRC); whatap JVMs found: ${#PIDS[@]}"

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-collserver-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (Tier 0 report + Tier 1 artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (Tier 0 report, read-only)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (Tier 0 report, read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi

[ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null
exit 0
