#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — Kubernetes collector (seeded v0)
# -----------------------------------------------------------------------------
# Gathers facts about a WhaTap Kubernetes monitoring install (operator,
# WhatapAgent CR, node-agent DaemonSet, master-agent, webhooks, helm state)
# so a remote developer does not have to ask the field engineer twenty
# questions. Runs wherever kubectl (or oc) can reach the cluster — a bastion,
# an engineer workstation — NOT on the node. Node-level facts (container log
# real path, runtime sockets, cgroup version) are collected best-effort by
# exec'ing into running whatap node-agent pods.
#
# THE CONTRACT (../../CONTRACT.md) — facts only, no diagnosis / no judgment.
# DESIGN GUIDELINES (../../docs/collector-engineering.md):
#   * MECE sections     — every fact lives in exactly one domain (A..J below):
#                         declared state in C/D/E, observed events in F, all
#                         log streams in G, image index in H, in-pod facts in I,
#                         APM auto-instrumentation of application pods in J.
#   * Load-safe by tier — Tier 0 (default report) is read-only API GETs with
#                         bounded --tail and a per-call timeout; full logs and
#                         yaml archives are --bundle; per-node exec fan-out is
#                         opt-in (--exec-per-node) and announced first.
#   * Portable          — kubectl falls back to oc; helm facts degrade to
#                         release-secret names when the binary is absent;
#                         no jq; bash 3.2+; no mapfile / assoc arrays.
#   * Reasoned absence  — a value we cannot obtain is a fact too, carrying WHY
#                         (command not found / permission denied / path not
#                         found / timed out / not applicable / empty output).
#
# OUTPUT IS VERBATIM: framework policy (docs/authoring-guide.md step 3) — no
# masking; a value has to be readable to be verified or refuted against the
# other side. `get secret -o yaml|json` is not used anywhere: secrets appear as
# name/type tables, and the one Secret field read is the webhook certificate
# Secret's public `cert.pem`, of which only the fingerprint is printed. Other
# places a secret can arrive from (pod env values, helm values, the operator
# env, in-container whatap.conf) are listed in README.md, "What the report can
# contain".
#
# NOTE: no `set -e` / no `set -u`. A collector must run to completion and emit
# its footer even when individual steps fail; each step guards itself.
# -----------------------------------------------------------------------------

# bash only: arrays, `read -d`, $SECONDS. Another shell would run on and give
# wrong answers silently, so it stops here instead.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' "collect-k8s.sh needs bash (run it as ./collect-k8s.sh or bash collect-k8s.sh)" >&2
    exit 2
fi

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-k8s"
# 0.8.0  Fewer API round trips: the jsonpath reads of one object or list are
#        asked in one call and split on marker lines (the cluster-scoped
#        WhatapAgent list, the crd, each whatap webhook configuration, the
#        node-agent daemonset, the first node), a list read twice is read once,
#        and the in-pod probes of a pod run in one `kubectl exec`, each through
#        its own sh -c with its own exit status. A merged call that fails
#        gives every read it replaced that failure; one that fails on a
#        template is made again read by read. The report is unchanged; 105 ->
#        75 calls and 24.6 s -> 18.0 s on a 4-node lab cluster (2026-09-25).
# 0.8.1  A probe that hangs inside the per-pod exec no longer takes the
#        answers of the ones after it: those never started, and each now runs
#        in its own exec under its own cap. The marker lines of the merged
#        calls are random per run and taken only in the expected order, so a
#        CR value or a probe output holding marker-like text cannot replace
#        another read's answer (2026-09-25).
# 0.8.2  When a probe run alone after a hang also times out, the probes
#        after it in that pod are not run (each would wait a full cap for the
#        same cause): a common hang costs about two caps per pod, not five
#        (2026-09-25).
# 0.8.3  Only a first re-run that also times out stops the re-runs. Once a
#        probe run alone has answered, the pod still answers, so a later
#        hang is that probe's own and the ones after it are still run
#        (two separate hangs lost the last answer in 0.8.2; 2026-09-25).
# 0.8.4  A CMD_TIMEOUT from the environment is used (it was overwritten by a
#        fixed value after _run_init had checked it) (2026-09-26).
VERSION="0.8.4"
DOMAIN="k8s"
TARGET="k8s-cluster/unresolved"      # refined after CLI/context/namespace discovery

# ---- options ----------------------------------------------------------------
OPT_FILE=0           # write the Tier 0 report to a .txt file
OPT_STDOUT=0
OPT_BUNDLE=0         # Tier 1: report + yaml/log artifacts as tar.gz
OPT_QUIET=0          # suppress progress narration on stderr
OPT_OUT="."
OPT_NS=""            # skip namespace discovery (RBAC-scoped kubeconfigs)
OPT_CONTEXT=""       # kubeconfig context passthrough
OPT_KUBECONFIG=""    # kubeconfig path passthrough
OPT_TAIL=200         # Tier 0 log tail lines per container
OPT_EXEC_ALL=0       # Tier 2: run in-pod probes on every node-agent pod
OPT_APM_EXEC=0       # Tier 2: exec into --apm-target application containers
APM_TGTS=()          # opt-in: namespaces (ns or ns/workload) to inspect for injection facts

usage() {
    cat <<'EOF'
Run wherever kubectl (or oc) reaches the cluster. Produces one facts .txt or a
tar.gz. Run with no arguments (or --help) to print this help — a collection
needs an explicit action flag (--file / --stdout / --bundle) so nothing starts
by accident.

  collect-k8s.sh                          print this help (no collection)
  collect-k8s.sh --file                   Tier 0 facts report -> one .txt file
  collect-k8s.sh --stdout                 print the report to stdout instead
  collect-k8s.sh --bundle                 Tier 0 report + yaml/log artifacts -> tar.gz
  collect-k8s.sh --quiet ...              silence progress on stderr (for automation)
  collect-k8s.sh --out DIR                output directory (default: .)
  collect-k8s.sh --namespace NS           skip namespace discovery (RBAC-scoped access)
  collect-k8s.sh --context CTX            kubeconfig context to use (multi-cluster bastion)
  collect-k8s.sh --kubeconfig PATH        kubeconfig file to use
  collect-k8s.sh --tail N                 Tier 0 log lines per container (default: 200)
  collect-k8s.sh --apm-target NS[/NAME]   inspect an application namespace for whatap APM
                                          auto-instrumentation facts (repeatable, max 5):
                                          workload template env (as declared) vs pod env
                                          (as admitted), init-container state, mounts,
                                          init/startup logs, namespace events

  Tier 2 (opt-in, wider fan-out — announced on stderr before running):
  collect-k8s.sh --exec-per-node          run the in-pod probes on EVERY running
                                          node-agent pod (max 30) instead of 2 samples
  collect-k8s.sh --apm-exec               also run read-only probes INSIDE the
                                          --apm-target application containers
                                          (agent home listing, conf, agent logs)

Section J runs even with no --apm-target: it always reports the cluster-wide
inventory of pods carrying a whatap APM init container.

Output is verbatim (framework policy: no masking). Secrets appear as
name/type tables; the one Secret field read is the webhook certificate
Secret's public cert.pem, printed as a fingerprint only. README.md, "What the
report can contain", lists every place a secret can arrive from.
EOF
}

ARGC=$#              # 0 args -> usage (handled in main, below)
while [ $# -gt 0 ]; do
    case "$1" in
        --file) OPT_FILE=1 ;;
        --stdout) OPT_STDOUT=1 ;;
        --bundle) OPT_BUNDLE=1 ;;
        --quiet) OPT_QUIET=1 ;;
        --out) OPT_OUT="$2"; shift ;;
        --out=*) OPT_OUT="${1#*=}" ;;
        --namespace|-n) OPT_NS="$2"; shift ;;
        --namespace=*) OPT_NS="${1#*=}" ;;
        --context) OPT_CONTEXT="$2"; shift ;;
        --context=*) OPT_CONTEXT="${1#*=}" ;;
        --kubeconfig) OPT_KUBECONFIG="$2"; shift ;;
        --kubeconfig=*) OPT_KUBECONFIG="${1#*=}" ;;
        --tail) OPT_TAIL="$2"; shift ;;
        --tail=*) OPT_TAIL="${1#*=}" ;;
        --exec-per-node) OPT_EXEC_ALL=1 ;;
        --apm-exec) OPT_APM_EXEC=1 ;;
        --apm-target) APM_TGTS[${#APM_TGTS[@]}]="$2"; shift ;;
        --apm-target=*) APM_TGTS[${#APM_TGTS[@]}]="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
case "$OPT_TAIL" in ''|*[!0-9]*) OPT_TAIL=200 ;; esac

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

emit_footer() { printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'; }

# ---- reasoned-absence helpers (see docs/collector-engineering.md) -----------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_init_errfile() { _errfile="$(_tmp probe.err)"; }
_timeout_bin=""
CMD_TIMEOUT="${CMD_TIMEOUT:-20}"

# _cutw N -> each line cut to N characters at a word boundary, marked "..."
_cutw() {
    awk -v n="$1" '{ if (length($0) <= n) { print; next }
        s = substr($0, 1, n); i = n
        while (i > 0 && substr(s, i, 1) != " ") i--
        if (i > n / 2) s = substr(s, 1, i - 1)
        print s " ..." }'
}

_classify_err() {
    # reads a stderr file, prints a short classified reason. kubectl's own
    # errors are matched first and by their exact wording, so a missing
    # context or an unreachable API server is never read as a missing path.
    local txt="" first=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    first="$(printf '%s' "$txt" | head -n1 | sed 's/^Error from server ([A-Za-z]*): //; s/^error: //' | _cutw 160)"
    case "$txt" in
        *"context \""*"\" does not exist"*|*"context was not found for specified context"*)
            printf 'context not found: %s' "$first"; return ;;
        *"(Forbidden)"*|*" is forbidden: "*)
            printf 'forbidden: %s' "$first"; return ;;
        *"(Unauthorized)"*|*"must be logged in to the server"*)
            printf 'unauthorized: %s' "$first"; return ;;
        *"connection refused"*|*" was refused"*)
            printf 'connection refused: %s' "$first"; return ;;
        *"context deadline exceeded"*|*"Client.Timeout"*|*"i/o timeout"*|*"TLS handshake timeout"*|*"(Timeout)"*)
            printf 'API request timed out: %s' "$first"; return ;;
        *"no such host"*|*"no route to host"*|*"network is unreachable"*|*"Unable to connect to the server"*)
            printf 'API server unreachable: %s' "$first"; return ;;
        *"doesn't have a resource type"*|*"the server could not find the requested resource"*|*"o matches for kind"*)
            echo "not applicable: resource type not present"; return ;;
        *"(NotFound)"*)
            printf 'object not found: %s' "$first"; return ;;
        *"executable file not found"*)
            printf 'command not found in container: %s' "$first"; return ;;
        *"command not found"*)
            printf 'command not found: %s' "$first"; return ;;
        *[Pp]"ermission denied"*|*"peration not permitted"*|*"peration not supported"*)
            echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"o such device"*)
            echo "path not found"; return ;;
    esac
    if [ -n "$txt" ]; then
        printf 'error: %s' "$first"
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

# Only the process that ran _run_init removes the directory. The background
# jobs _bounded_in forks inherit the traps, and a job killed before it reset
# them ran this cleanup mid-run (lost within 1..176 `_bounded true` calls under
# bash, 2026-09-25). A flag set around the fork left a window in which a Ctrl-C
# to the run itself skipped the cleanup, so the process is identified instead.
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
        # the locale's radix: EPOCHREALTIME can read 1790000000,123456
        f="${t#*[.,]}000"; f="${f%"${f#???}"}"
        _ms="${t%[.,]*}$f"
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
        wait "$p"; rc=$?
        # KILL: a TERM can reach the watchdog before dash has reset the traps it
        # inherited and be lost, and it then ran a full 1s round (p90 ~1s a call)
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

# ---- env-table helpers (APM auto-instrumentation facts) ----------------------
# The operator's mutating webhook acts on PODS at CREATE, so a workload template
# carries env as declared by the application owner and a running pod carries env
# as admitted after mutation. Both are dumped through the same shape below so the
# two can be compared line by line.
#
# _envpath ROOT -> a jsonpath emitting one "C<TAB>container" line, then one
# "E<TAB>name<TAB>value<TAB>valueFrom" line per env entry and one
# "F<TAB>prefix<TAB>configMap<TAB>secret<TAB>optional" line per envFrom source.
# The container name is unreachable from inside the inner ranges, hence the
# separate C line.
#
# envFrom is collected because a container whose `.env[]` is empty is not a
# container without environment: `envFrom` pulls whole ConfigMaps/Secrets in,
# and `env` entries override what `envFrom` supplies. A loader variable
# (NODE_OPTIONS, PYTHONPATH, JAVA_TOOL_OPTIONS) arriving that way is invisible
# in `.env[]` yet present in the process.
_envpath() {
    # single backslashes here on purpose: $e is substituted through %s, which
    # printf copies verbatim (only the FORMAT string's escapes are processed)
    local e='{range .env[*]}{"E\t"}{.name}{"\t"}{.value}{"\t"}{.valueFrom}{"\n"}{end}{range .envFrom[*]}{"F\t"}{.prefix}{"\t"}{.configMapRef.name}{"\t"}{.secretRef.name}{"\t"}{.configMapRef.optional}{.secretRef.optional}{"\n"}{end}'
    printf 'jsonpath={range %s.containers[*]}{"C\\t"}{.name}{"\\n"}%s{end}{range %s.initContainers[*]}{"C\\tinit:"}{.name}{"\\n"}%s{end}' "$1" "$e" "$1" "$e"
}

# _emit_env_table "label" RAW -> render the C/E/F stream as a per-container env
# table, then list any env name occurring more than once in the same container.
# Kubernetes resolves a duplicated env name to its FIRST occurrence, so the
# repetition itself is a fact worth stating (values are printed verbatim).
_emit_env_table() {
    local label="$1" raw="$2" rendered dups
    if [ -z "$raw" ]; then fact "$label: n/a (empty output)"; return; fi
    rendered="$(printf '%s\n' "$raw" | awk -F'\t' '
        $1=="C" { c=$2; printf "container %s\n", c; next }
        $1=="E" { printf "  %s = %s%s\n", $2, $3, ($4=="" ? "" : "   valueFrom=" $4); next }
        $1=="F" { printf "  envFrom%s%s%s%s\n", ($3=="" ? "" : " configMap=" $3), ($4=="" ? "" : " secret=" $4), ($2=="" ? "" : " prefix=" $2), ($5=="" ? "" : " optional=" $5) }')"
    if [ -n "$rendered" ]; then _emit_labeled "$label" "$rendered"
    else fact "$label: n/a (no containers or no env entries)"; fi
    dups="$(printf '%s\n' "$raw" | awk -F'\t' '
        $1=="C" { c=$2; next }
        $1=="E" { k=c "|" $2; n[k]++; if (n[k]==2) order[++m]=k }
        END { for (i=1;i<=m;i++) { split(order[i],a,"|"); printf "%s: %s occurs %d times\n", a[1], a[2], n[order[i]] } }')"
    if [ -n "$dups" ]; then
        _emit_labeled "$label / repeated env names" "$dups"
    else
        fact "$label / repeated env names: none"
    fi
}

# probe "label" CMD [ARGS...] -> emits output as facts, or "label: n/a (<why>)".
# Every call runs under _bounded (CMD_TIMEOUT, RUN_DEADLINE).
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
        fact "$label: n/a ($(_classify_err))"; return
    fi
    if [ -z "$out" ]; then
        fact "$label: n/a (empty output)"; return
    fi
    _emit_labeled "$label" "$out"
}


# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any stdout/stderr redirection). It NEVER lands in the report — stdout stays
# byte-for-byte the report even in --file mode. Silenced by --quiet. Keep the text a
# fact about collection state (no judgment words) so validate.sh keeps passing.
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- kubectl/oc plumbing -----------------------------------------------------
KCTL_BIN=""
KOPTS=()

k8s_cli_discover() {
    if have kubectl; then KCTL_BIN="kubectl"
    elif have oc; then KCTL_BIN="oc"
    else KCTL_BIN=""; fi
    KOPTS=()
    KOPTS[${#KOPTS[@]}]="--request-timeout=15s"
    [ -n "$OPT_CONTEXT" ] && KOPTS[${#KOPTS[@]}]="--context=$OPT_CONTEXT"
    [ -n "$OPT_KUBECONFIG" ] && KOPTS[${#KOPTS[@]}]="--kubeconfig=$OPT_KUBECONFIG"
}

# run_k ARGS... -> low-level CLI call, bounded twice: kubectl's own
# --request-timeout (in KOPTS) and _bounded (CMD_TIMEOUT, RUN_DEADLINE).
# Sets K_OUT / K_RC; stderr lands in $_errfile for _classify_err.
# Once the reachability check has failed (API_OK=0), every API call is skipped
# with that one reason instead of timing each out; local ones (config,
# version --client) still run.
K_OUT=""; K_RC=1
API_OK=""            # "" = not checked yet, 1 = answered, 0 = not usable
API_WHY=""           # the reason, when API_OK=0
run_k() {
    K_OUT=""; K_RC=1
    [ -n "$KCTL_BIN" ] || { : > "$_errfile" 2>/dev/null; return 1; }
    if [ "$API_OK" = 0 ]; then
        case "$1 $2" in
            "config "*|"version --client") ;;
            *) K_RC=125; return 1 ;;
        esac
    fi
    K_OUT="$(_bounded "$KCTL_BIN" "${KOPTS[@]}" "$@" 2>"$_errfile")"; K_RC=$?
    return "$K_RC"
}

_k_reason() {
    # prints the n/a reason for the last run_k (assumes K_RC != 0 or empty K_OUT)
    if [ -z "$KCTL_BIN" ]; then echo "command not found: kubectl/oc"; return; fi
    if [ "$K_RC" -eq 125 ]; then echo "skipped: $API_WHY"; return; fi
    if [ "$K_RC" -eq 124 ]; then
        if _past_deadline; then echo "run deadline reached: ${RUN_DEADLINE}s"
        else echo "timed out: ${CMD_TIMEOUT}s"; fi
        return
    fi
    if [ "$K_RC" -ne 0 ]; then _classify_err; return; fi
    echo "empty output"
}

# k8s_api_check -> one reachability call before anything depends on the API.
# /version is readable by every authenticated and anonymous identity by
# default, so a refusal there is still an answer from the server: forbidden
# counts as reachable and the per-call reasons below say what was refused.
k8s_api_check() {
    if [ -z "$KCTL_BIN" ]; then API_OK=0; API_WHY="command not found: kubectl/oc"; return; fi
    local saved="$CMD_TIMEOUT" why
    CMD_TIMEOUT=10
    run_k get --raw /version --request-timeout=5s
    # the reason is built while the check's own cap is still in force
    why="$(_k_reason)"
    CMD_TIMEOUT="$saved"
    if [ "$K_RC" -eq 0 ]; then API_OK=1; return; fi
    case "$(cat "$_errfile" 2>/dev/null)" in
        *"(Forbidden)"*|*" is forbidden: "*) API_OK=1; return ;;
    esac
    API_WHY="API check (get --raw /version, 5s) failed: $why"
    API_OK=0
}

# kprobe "label" ARGS... -> emits CLI output as facts, or "label: n/a (<why>)"
kprobe() {
    local label="$1"; shift
    if run_k "$@" && [ -n "$K_OUT" ]; then _emit_labeled "$label" "$K_OUT"
    else fact "$label: n/a ($(_k_reason))"; fi
}

# kfilter "label" "ERE" ARGS... -> CLI output filtered to lines matching ERE
kfilter() {
    local label="$1" pat="$2"; shift 2
    if run_k "$@"; then
        local out; out="$(printf '%s\n' "$K_OUT" | grep -Ei "$pat")"
        if [ -n "$out" ]; then _emit_labeled "$label" "$out"; else fact "$label: n/a (empty output)"; fi
    else
        fact "$label: n/a ($(_k_reason))"
    fi
}

# kval ARGS... -> capture-only: prints stdout on success, nothing on failure.
# It runs inside $(...), so its outcome travels through a file: _kv_why right
# after the call prints the reason of a failed call, or nothing when it
# answered. A fact then says n/a (<reason>) for a failed list and "none" only
# for one that answered empty (decision 1 holds for fact lines too).
kval() {
    if run_k "$@"; then : > "$(_tmp kval.why)" 2>/dev/null; printf '%s\n' "$K_OUT"
    else _k_reason > "$(_tmp kval.why)" 2>/dev/null; return 1; fi
}
# Without a private temp directory the outcome cannot travel back, and an
# empty list is then not claimed to be an empty answer.
_kv_why() {
    if [ -z "$_tmp_dir" ]; then echo "call outcome not recorded: no private temp directory"; return; fi
    cat "$(_tmp kval.why)" 2>/dev/null
}
# _none_or_na WHY WHAT -> "none <WHAT>" when WHY is empty, else "n/a (WHY)"
_none_or_na() { if [ -n "$1" ]; then printf 'n/a (%s)' "$1"; else printf 'none %s' "$2"; fi; }

# emit_log_tail POD CONTAINER LINES [previous] -> bounded log tail
emit_log_tail() {
    local pod="$1" cont="$2" lines="$3" prev="${4:-}"
    local label="logs $pod/$cont"
    [ -n "$prev" ] && label="$label (previous instance)"
    local rc
    if [ -n "$prev" ]; then run_k logs -n "$NS" "$pod" -c "$cont" --tail="$lines" --previous; rc=$?
    else run_k logs -n "$NS" "$pod" -c "$cont" --tail="$lines"; rc=$?; fi
    if [ "$rc" -eq 0 ] && [ -n "$K_OUT" ]; then
        _emit_labeled "$label" "$K_OUT"
    else
        fact "$label: n/a ($(_k_reason))"
    fi
}

# emit_log_head_ns NS POD CONTAINER BYTES -> the FIRST bytes of a container log.
# `logs --limit-bytes` without `--tail` returns the log from its beginning, which
# is where an agent prints its boot banner (the Node.js agent banner goes to the
# application stdout only) — a tail would miss it on a long-running pod.
emit_log_head_ns() {
    local ns="$1" pod="$2" cont="$3" bytes="$4"
    if run_k logs -n "$ns" "$pod" -c "$cont" --limit-bytes="$bytes" && [ -n "$K_OUT" ]; then
        _emit_labeled "log head $pod/$cont (first ${bytes}B)" "$K_OUT"
    else
        fact "log head $pod/$cont (first ${bytes}B): n/a ($(_k_reason))"
    fi
}

# pod_exec_probe_ns NS "label" POD CONTAINER CMDSTRING -> output of a read-only
# command run inside a pod in any namespace, or a classified reason.
pod_exec_probe_ns() {
    local ns="$1" label="$2" pod="$3" cont="$4" cmd="$5"
    if run_k exec -n "$ns" "$pod" -c "$cont" -- sh -c "$cmd" && [ -n "$K_OUT" ]; then
        _emit_labeled "$label" "$K_OUT"
    else
        fact "$label: n/a ($(_k_reason))"
    fi
}

# pod_exec_probe "label" POD CONTAINER CMDSTRING -> same, in the whatap namespace.
pod_exec_probe() { pod_exec_probe_ns "$NS" "$1" "$2" "$3" "$4"; }

# ---- merged calls ----------------------------------------------------------------
# Every kubectl call is a round trip to the API server: 105 of them took 20 of
# the 25 s a run spent on a lab cluster, and a remote API multiplies that. So
# the jsonpath reads of one object (or one list) are asked in ONE call, each
# template preceded by a marker line, and split back afterwards.
#
# km_get GROUP ARGS... -> `ARGS -o jsonpath=<KM_T joined>`, stored as GROUP:
#   GROUP_USE=1, GROUP_RC / GROUP_ERR (exit status and stderr of the call),
#   GROUP_FB=1 when the failure names jsonpath (a template error: one template
#   would otherwise fail all of them), GROUP_K / GROUP_S (marker keys and the
#   text after each, trailing newlines dropped as $(...) drops them).
# Templates carry their marker: _km_mark KEY, or inside a range over items
# {"\n<marker> "}{.metadata.name}{"/KEY\n"} with the KEYs listed, in order,
# in KM_IKEYS.
# The marker is random per run, and a marker line counts only when it is the
# one expected next (the _km_mark keys in KM_T order, then per item the
# KM_IKEYS in order, one item name throughout): a value holding a newline and
# marker-like text stays part of the value.
# kg_run GROUP KEY ARGS... then stands in for `run_k ARGS` of the template it
# replaced: K_OUT / K_RC / $_errfile as that call would have left them. A
# failed merged call fails every template the same way; a template error or a
# key the call did not print runs the original call instead.
_km_rand=""
{ read -r _km_rand < /proc/sys/kernel/random/uuid; } 2>/dev/null
[ -n "$_km_rand" ] || _km_rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
[ -n "$_km_rand" ] || _km_rand="$$.$(date +%s 2>/dev/null)"
_KM_M="@@ggt-seg-$_km_rand@@"
KM_T=()
KM_IKEYS=""
_km_mark() { printf '{"\\n%s %s\\n"}' "$_KM_M" "$1"; }
km_get() {
    local g="$1" tpl="" i=0 l key="" acc="" n=0 t ks="" ik="" nm="" want
    shift
    while [ "$i" -lt "${#KM_T[@]}" ]; do
        t="${KM_T[$i]}"; tpl="$tpl$t"
        # the keys _km_mark wrote, in order
        case "$t" in "{\"\\n$_KM_M "*"\\n\"}") t="${t#"{\"\\n$_KM_M "}"; ks="$ks ${t%"\\n\"}"}" ;; esac
        i=$((i + 1))
    done
    eval "${g}_USE=1 ${g}_FB=0 ${g}_ERR='' ${g}_K=() ${g}_S=()"
    run_k "$@" -o "jsonpath=$tpl"
    eval "${g}_RC=\$K_RC"
    if [ "$K_RC" -ne 0 ]; then
        eval "${g}_ERR=\"\$(cat \"\$_errfile\" 2>/dev/null)\""
        grep -qi 'jsonpath' "$_errfile" 2>/dev/null && eval "${g}_FB=1"
        return 1
    fi
    set -- $ks
    while IFS= read -r l; do
        want=""
        case "$l" in
            "$_KM_M "*)
                t="${l#"$_KM_M "}"
                if [ "$#" -gt 0 ]; then
                    [ "$t" = "$1" ] && { want="$t"; shift; }
                elif [ -n "$KM_IKEYS" ]; then
                    # per item: the first KM_IKEYS key under any name, then
                    # the rest in order under that same name
                    [ -n "$ik" ] || { ik="$KM_IKEYS "; nm=""; }
                    case "$t" in
                        */"${ik%% *}")
                            if [ -z "$nm" ] || [ "${t%/*}" = "$nm" ]; then
                                nm="${t%/*}"; want="$t"; ik="${ik#* }"
                            fi ;;
                    esac
                fi ;;
        esac
        if [ -n "$want" ]; then
            if [ -n "$key" ]; then
                while :; do case "$acc" in *"$_nl") acc="${acc%"$_nl"}" ;; *) break ;; esac; done
                eval "${g}_K[\${#${g}_K[@]}]=\$key; ${g}_S[\${#${g}_S[@]}]=\$acc"
            fi
            key="$want"; acc=""; n=0
            continue
        fi
        [ -n "$key" ] || continue
        if [ "$n" = 0 ]; then acc="$l"; else acc="$acc$_nl$l"; fi
        n=$((n + 1))
    done <<EOF
$K_OUT
EOF
    if [ -n "$key" ]; then
        while :; do case "$acc" in *"$_nl") acc="${acc%"$_nl"}" ;; *) break ;; esac; done
        eval "${g}_K[\${#${g}_K[@]}]=\$key; ${g}_S[\${#${g}_S[@]}]=\$acc"
    fi
    KM_IKEYS=""
    return 0
}

# _kg GROUP KEY -> 0 with KG_V = the text for KEY; 1 when the merged call
# failed (KG_RC / KG_ERR); 2 when the original call has to be made
KG_V="" KG_RC=0 KG_ERR=""
_kg() {
    local g="$1" k="$2" use rc fb n i=0 kk
    eval "use=\${${g}_USE:-0}"
    [ "$use" = 1 ] || return 2
    eval "rc=\$${g}_RC fb=\$${g}_FB"
    if [ "$rc" -ne 0 ]; then
        [ "$fb" = 1 ] && return 2
        KG_RC="$rc"; eval "KG_ERR=\$${g}_ERR"
        return 1
    fi
    eval "n=\${#${g}_K[@]}"
    while [ "$i" -lt "$n" ]; do
        eval "kk=\${${g}_K[$i]}"
        [ "$kk" = "$k" ] && { eval "KG_V=\${${g}_S[$i]}"; return 0; }
        i=$((i + 1))
    done
    return 2
}

kg_run() {
    local g="$1" k="$2" r
    shift 2
    _kg "$g" "$k"; r=$?
    case "$r" in
        0) K_OUT="$KG_V"; K_RC=0; return 0 ;;
        1) K_OUT=""; K_RC="$KG_RC"; printf '%s\n' "$KG_ERR" > "$_errfile" 2>/dev/null; return "$K_RC" ;;
    esac
    run_k "$@"
}
# kg_probe GROUP KEY "label" ARGS... -> kprobe, from the merged call
kg_probe() {
    local g="$1" k="$2" label="$3"
    shift 3
    if kg_run "$g" "$k" "$@" && [ -n "$K_OUT" ]; then _emit_labeled "$label" "$K_OUT"
    else fact "$label: n/a ($(_k_reason))"; fi
}
# kg_kval GROUP KEY ARGS... -> kval, from the merged call (for $(...))
kg_kval() {
    local g="$1" k="$2"
    shift 2
    if kg_run "$g" "$k" "$@"; then : > "$(_tmp kval.why)" 2>/dev/null; printf '%s\n' "$K_OUT"
    else _k_reason > "$(_tmp kval.why)" 2>/dev/null; return 1; fi
}

# _whg WEBHOOK -> _WHG = the merged-call group of that webhook configuration
_WHG=""
_whg() { local w j=0; _WHG="WHG_none"; for w in $WEBHOOKS; do [ "$w" = "$1" ] && { _WHG="WHG$j"; return; }; j=$((j + 1)); done; }

# kr_keep GROUP KEY -> keep the last run_k as GROUP/KEY, for a later kg_run of
# the same call
kr_keep() {
    eval "${1}_USE=1 ${1}_FB=0 ${1}_RC=\$K_RC ${1}_ERR='' ${1}_K=(\"\$2\") ${1}_S=(\"\$K_OUT\")"
    [ "$K_RC" -ne 0 ] && eval "${1}_ERR=\"\$(cat \"\$_errfile\" 2>/dev/null)\""
    return 0
}

# _pod_probes_run POD CONTAINER CMD... -> every CMD in one `kubectl exec`, each
# through its own `sh -c` (a CMD that does not parse fails alone, as it did in
# its own exec). Per CMD the pod prints "<marker> N/start", then N/out, the
# stdout, N/err, the stderr, and N/rc with the exit status on the next line;
# the marker is the per-run random one of km_get, passed as $1, and a marker
# line counts only when it is the one expected next. Stored as PX_K / PX_S
# (keys N/out, N/err, N/rc; N/start with an empty text);
# _pod_probe_emit N "label" CMD then reports CMD N as pod_exec_probe did.
_PX_DRV='m=$1; shift; i=0; for c in "$@"; do i=$((i + 1)); echo "$m $i/start"; echo "$m $i/out"; { e=$( { sh -c "$c" 2>&1 1>&3 3>&-; } ); } 3>&1; r=$?; echo; echo "$m $i/err"; printf "%s\n" "$e"; echo "$m $i/rc"; echo "$r"; done'
PX_POD="" PX_CONT="" PX_RERUN_TO=0
_pod_probes_run() {
    local pod="$1" cont="$2" l key="" acc="" n=0 ni=1 st=start
    shift 2
    PX_POD="$pod" PX_CONT="$cont" PX_RERUN_TO=0 PX_ERR="" PX_K=() PX_S=()
    run_k exec -n "$NS" "$pod" -c "$cont" -- sh -c "$_PX_DRV" sh "$_KM_M" "$@"
    PX_RC=$K_RC
    [ "$K_RC" -ne 0 ] && PX_ERR="$(cat "$_errfile" 2>/dev/null)"
    # a call cut short keeps what the probes before the cut printed
    while IFS= read -r l; do
        if [ "$l" = "$_KM_M $ni/$st" ]; then
            if [ -n "$key" ]; then
                while :; do case "$acc" in *"$_nl") acc="${acc%"$_nl"}" ;; *) break ;; esac; done
                PX_K[${#PX_K[@]}]="$key"; PX_S[${#PX_S[@]}]="$acc"
            fi
            key="$ni/$st"; acc=""; n=0
            case "$st" in
                start) st=out ;; out) st=err ;; err) st=rc ;;
                rc) st=start; ni=$((ni + 1)) ;;
            esac
            continue
        fi
        [ -n "$key" ] || continue
        if [ "$n" = 0 ]; then acc="$l"; else acc="$acc$_nl$l"; fi
        n=$((n + 1))
    done <<EOF
$K_OUT
EOF
    if [ -n "$key" ]; then
        while :; do case "$acc" in *"$_nl") acc="${acc%"$_nl"}" ;; *) break ;; esac; done
        PX_K[${#PX_K[@]}]="$key"; PX_S[${#PX_S[@]}]="$acc"
    fi
}
_px() { local i=0; KG_V=""; while [ "$i" -lt "${#PX_K[@]}" ]; do [ "${PX_K[$i]}" = "$1" ] && { KG_V="${PX_S[$i]}"; return 0; }; i=$((i + 1)); done; return 1; }
# A probe with no status of its own: one that started and was cut off takes
# the exec's reason (a timeout says timed out); when no probe started at all
# the exec's reason stands for each, as each exec would have failed alike;
# one that never started while a probe before it did (it hung, or the stream
# broke) runs alone in its own exec under its own cap. Past the run deadline
# it is not run, and the reason says why. Once one such re-run also times
# out, the rest are not run either: each would wait a full cap for the same
# cause.
_pod_probe_emit() {
    local n="$1" label="$2" cmd="$3" out err rc
    if _px "$n/rc"; then
        rc="$KG_V"; _px "$n/out"; out="$KG_V"; _px "$n/err"; err="$KG_V"
        # what `kubectl exec` itself adds for a command that exits non-zero
        if [ "$rc" != 0 ]; then
            { [ -n "$err" ] && printf '%s\n' "$err"; printf 'command terminated with exit code %s\n' "$rc"; } > "$_errfile" 2>/dev/null
            K_RC="$rc"
        else
            K_RC=0
        fi
        K_OUT="$out"
    elif ! _px "$n/start" && _px "1/start"; then
        if _past_deadline; then
            fact "$label: n/a (not run: the probe before it did not finish within ${CMD_TIMEOUT}s, and the run deadline was reached: ${RUN_DEADLINE}s)"
            return
        fi
        if [ "$PX_RERUN_TO" = 1 ]; then
            fact "$label: n/a (not run: the probes before it did not finish within ${CMD_TIMEOUT}s)"
            return
        fi
        pod_exec_probe "$label" "$PX_POD" "$PX_CONT" "$cmd"
        # 1 stops the re-runs, 2 keeps them: a re-run that answered shows the
        # pod still answers, so a later hang is that probe's own
        if [ "$K_RC" != 124 ]; then PX_RERUN_TO=2
        elif [ "$PX_RERUN_TO" = 0 ]; then PX_RERUN_TO=1; fi
        return
    else
        K_OUT=""; K_RC="$PX_RC"
        [ "$K_RC" -eq 0 ] && K_RC=1
        printf '%s\n' "$PX_ERR" > "$_errfile" 2>/dev/null
    fi
    if [ "$K_RC" -eq 0 ] && [ -n "$K_OUT" ]; then _emit_labeled "$label" "$K_OUT"
    else fact "$label: n/a ($(_k_reason))"; fi
}

# ---- discovery (run once, before the report) ---------------------------------
NS=""; NS_SRC=""; NS_ALL=""
k8s_ns_discover() {
    if [ -n "$OPT_NS" ]; then NS="$OPT_NS"; NS_SRC="option --namespace"; return; fi
    [ -n "$KCTL_BIN" ] || { NS_SRC="n/a (command not found: kubectl/oc)"; return; }
    [ "$API_OK" = 0 ] && { NS_SRC="n/a (skipped: $API_WHY)"; return; }
    local out fails=""
    # 1) server-side label select on the two known whatap labels
    if run_k get pods -A -l name=whatap-node-agent -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\n"}{end}'; then
        out="$(printf '%s\n' "$K_OUT" | sort -u | grep -v '^$')"
        if [ -n "$out" ]; then
            NS="$(printf '%s\n' "$out" | head -n1)"; NS_ALL="$out"; NS_SRC="pods labeled name=whatap-node-agent"; return
        fi
    else fails="$fails; label name=whatap-node-agent: $(_k_reason)"; fi
    if run_k get pods -A -l app.kubernetes.io/name=whatap-operator -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\n"}{end}'; then
        out="$(printf '%s\n' "$K_OUT" | sort -u | grep -v '^$')"
        if [ -n "$out" ]; then
            NS="$(printf '%s\n' "$out" | head -n1)"; NS_ALL="$out"; NS_SRC="pods labeled app.kubernetes.io/name=whatap-operator"; return
        fi
    else fails="$fails; label app.kubernetes.io/name=whatap-operator: $(_k_reason)"; fi
    # 2) last resort: one cluster-wide pod scan by name prefix
    if run_k get pods -A --no-headers; then
        out="$(printf '%s\n' "$K_OUT" | awk '$2 ~ /^whatap-/ {print $1}' | sort -u)"
        if [ -n "$out" ]; then
            NS="$(printf '%s\n' "$out" | head -n1)"; NS_ALL="$out"; NS_SRC="pod name scan (whatap-*)"; return
        fi
    else fails="$fails; pod name scan: $(_k_reason)"; fi
    if [ -n "$fails" ]; then NS_SRC="n/a (no whatap workloads in the pod lists that answered; failed:${fails#;})"
    else NS_SRC="n/a (no whatap workloads in any namespace: labels name=whatap-node-agent, app.kubernetes.io/name=whatap-operator, pod names whatap-*)"; fi
}

WA_CRD=""            # full CRD name, e.g. whatapagents.monitoring.whatap.com
WA_SCOPE=""          # Cluster | Namespaced
CRD_TABLE=""         # whatap CRD table lines (name + age)
CR_NAMES=()          # discovered WhatapAgent CR instance names
CR_NSS=()            # matching namespaces ("" when cluster-scoped)
DS_NAME=""           # node-agent DaemonSet name (short)
DS_CONTAINERS=""     # container names in the DS pod template (space-separated)
OP_DEPLOY=""         # operator Deployment name (short)
WHATAP_DEPLOYS=""    # all whatap-ish Deployments in NS (table lines)
WEBHOOKS=""          # whatap mutating/validating webhook config names (full, one per line)
WEBHOOK_HOOKS=""     # per-hook names inside those configs (e.g. mpod.kb.io) — the label the
                     # API server uses in its own admission metrics
WHATAP_CROLES=""     # whatap-related ClusterRole names
ALL_HOOKS=""         # every admission hook in the cluster as "config<TAB>hookName" — the
                     # API server keys its metrics by hook NAME alone, and kubebuilder
                     # scaffolds generic names (mpod.kb.io), so a name used by a second
                     # operator would silently share whatap's counters
ALL_HOOKS_WHY=""     # why ALL_HOOKS is empty
DSC_WHY="" DS_WHY="" OP_WHY="" DEP_WHY="" HS_WHY="" WH_WHY="" SP_WHY=""   # why the list behind each failed
HELM_SECRETS=""      # sh.helm.release.v1.* secret names mentioning whatap

# jsonpath templates read both on their own and inside a merged call
T_CRD_VERSIONS='{range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
T_CR_ENV1='{.spec.features.k8sAgent.nodeAgent.envs[*].name}'
T_CR_ENV2='{.spec.features.k8sAgent.nodeAgent.nodeAgentContainer.envs[*].name}'
T_CR_ENV3='{.spec.features.k8sAgent.nodeAgent.nodeHelperContainer.envs[*].name}'
T_CR_MF='{range .metadata.managedFields[*]}{.manager}{" op="}{.operation}{" subresource="}{.subresource}{" time="}{.time}{"\n"}{end}'
T_CR_ID='{"apiVersion="}{.apiVersion}{" name="}{.metadata.name}{" k8sAgent.namespace="}{.spec.features.k8sAgent.namespace}{" k8sAgent.enabled="}{.spec.features.k8sAgent.enabled}{" apm.instrumentation.enabled="}{.spec.features.apm.instrumentation.enabled}{" targets="}{.spec.features.apm.instrumentation.targets[*].name}'
T_CR_TG='{range .spec.features.apm.instrumentation.targets[*]}{"name="}{.name}{" lang="}{.language}{" enabled="}{.enabled}{" versions="}{.whatapApmVersions}{" mode="}{.config.mode}{" configMapRef="}{.config.configMapRef.name}{" nsSelector="}{.namespaceSelector}{" podSelector="}{.podSelector}{"\n"}{end}'
T_CR_IMG='{range .spec.features.apm.instrumentation.targets[*]}{"name="}{.name}{" customImageFullName="}{.customImageFullName}{" customImageName="}{.customImageName}{" imagePullSecrets="}{.imagePullSecrets[*].name}{" envs="}{range .envs[*]}{.name}{"="}{.value}{";"}{end}{"\n"}{end}'
T_CRL_SELX='{range .items[*]}{range .spec.features.apm.instrumentation.targets[*]}{range .podSelector.matchExpressions[*]}{range .values[*]}{.}{"\n"}{end}{end}{end}{end}'
T_CRL_SELL='{range .items[*]}{range .spec.features.apm.instrumentation.targets[*]}{.podSelector.matchLabels}{"\n"}{end}{end}'
T_CRL_JNAMES='{range .items[*]}{.metadata.name}{" apiVersion="}{.apiVersion}{" created="}{.metadata.creationTimestamp}{"\n"}{end}'
T_CRL_JALL='{.items[*].metadata.name}'
T_CRL_JTGT='{range .items[*]}{.metadata.name}{"="}{range .spec.features.apm.instrumentation.targets[*]}{.name}{","}{end}{"\n"}{end}'
T_CRL_JSEL='{range .items[*]}{"cr="}{.metadata.name}{"\n"}{range .spec.features.apm.instrumentation.targets[*]}{"  target="}{.name}{" enabled="}{.enabled}{" lang="}{.language}{"\n"}{"    namespaceSelector.matchNames="}{.namespaceSelector.matchNames}{"\n"}{"    namespaceSelector.matchLabels="}{.namespaceSelector.matchLabels}{"\n"}{"    namespaceSelector.matchExpressions="}{.namespaceSelector.matchExpressions}{"\n"}{"    podSelector.matchLabels="}{.podSelector.matchLabels}{"\n"}{"    podSelector.matchExpressions="}{.podSelector.matchExpressions}{"\n"}{end}{end}'
T_WH_HOOKS='{range .webhooks[*]}{.name}{" "}{end}'
T_WH_LINE='{range .webhooks[*]}{.name}{" path="}{.clientConfig.service.path}{" url="}{.clientConfig.url}{" ops="}{.rules[*].operations}{" resources="}{.rules[*].resources}{" failurePolicy="}{.failurePolicy}{" matchPolicy="}{.matchPolicy}{" reinvocationPolicy="}{.reinvocationPolicy}{" nsSelector="}{.namespaceSelector}{" objectSelector="}{.objectSelector}{"\n"}{end}'
T_WH_CAB='{range .webhooks[*]}{.name}{"="}{.clientConfig.caBundle}{"\n"}{end}'
T_WH_SVC='{range .webhooks[*]}{.clientConfig.service.namespace}{"/"}{.clientConfig.service.name}{"\n"}{end}'
T_WH_CABT='{range .webhooks[*]}{.name}{"\t"}{.clientConfig.caBundle}{"\n"}{end}'
T_WH_MF='{range .metadata.managedFields[*]}{.manager}{" op="}{.operation}{" time="}{.time}{"\n"}{end}'
T_DS_CONT='{range .spec.template.spec.containers[*]}{.name}{" "}{end}'
T_DS_SA='{.spec.template.spec.serviceAccountName}'
T_DS_MOUNTS='{range .spec.template.spec.containers[*]}{.name}{"="}{range .volumeMounts[*]}{.mountPath}{","}{end}{"\n"}{end}'
T_DS_PORTS='{range .spec.template.spec.containers[*]}{.name}{"="}{.ports[0].containerPort}{"\n"}{end}'
T_DS_HOSTPID='{.spec.template.spec.hostPID}'

# _cr_merged_get -> the cluster-scoped CR list with every template read of it,
# whole-list ones keyed by name and per-instance ones keyed <cr>/<name>
_cr_merged_get() {
    local k t pi=""
    KM_T=()
    for k in list selx sell jnames jall jtgt jsel; do
        case "$k" in
            list)   t='{range .items[*]}{" "}{.metadata.name}{"\n"}{end}' ;;
            selx)   t="$T_CRL_SELX" ;;   sell) t="$T_CRL_SELL" ;;
            jnames) t="$T_CRL_JNAMES" ;; jall) t="$T_CRL_JALL" ;;
            jtgt)   t="$T_CRL_JTGT" ;;   jsel) t="$T_CRL_JSEL" ;;
        esac
        KM_T[${#KM_T[@]}]="$(_km_mark "$k")"; KM_T[${#KM_T[@]}]="$t"
    done
    for k in ENV1 ENV2 ENV3 MF ID TG IMG; do
        eval "t=\$T_CR_$k"
        pi="$pi{\"\\n$_KM_M \"}{.metadata.name}{\"/$k\\n\"}$t"
    done
    KM_T[${#KM_T[@]}]="{range .items[*]}$pi{end}"
    KM_IKEYS="ENV1 ENV2 ENV3 MF ID TG IMG"
    km_get CRG get "$WA_CRD"
}

CR_STATE=""          # listed | nocrd | failed
SCOPE_WHY=""         # why the crd scope read failed
CR_WHY=""            # what was read, or why the list failed
discover_workloads() {
    [ -n "$KCTL_BIN" ] || { CR_STATE=failed; CR_WHY="command not found: kubectl/oc"; return; }
    [ "$API_OK" = 0 ] && { CR_STATE=failed; CR_WHY="skipped: $API_WHY"; return; }
    local out line
    # CRDs. The CR goal rests on this list and on the CR list below: an absence
    # is stated only when both calls answered, cluster-wide.
    if run_k get crd; then
        CRD_TABLE="$(printf '%s\n' "$K_OUT" | grep -Ei 'whatap' | grep -Eiv '^NAME')"
    else
        CR_STATE=failed; CR_WHY="crd list: $(_k_reason)"
        CRD_TABLE=""
    fi
    WA_CRD="$(printf '%s\n' "$CRD_TABLE" | awk '$1 ~ /^whatapagents\./ {print $1; exit}')"
    if [ -z "$CR_STATE" ] && [ -z "$WA_CRD" ]; then
        CR_STATE=nocrd; CR_WHY="the cluster-wide crd list answered and carries no whatapagents.* crd"
    fi
    if [ -n "$WA_CRD" ]; then
        local where="" scopewhy=""
        # scope unknown (the read failed): list across all namespaces, which
        # also answers for a cluster-scoped kind
        # scope and served versions of the crd in one call (group CRDG)
        KM_T=("$(_km_mark scope)" '{.spec.scope}' "$(_km_mark versions)" "$T_CRD_VERSIONS")
        km_get CRDG get crd "$WA_CRD"
        if kg_run CRDG scope get crd "$WA_CRD" -o 'jsonpath={.spec.scope}'; then WA_SCOPE="$K_OUT"
        else WA_SCOPE=""; scopewhy="$(_k_reason)"; SCOPE_WHY="$scopewhy"; fi
        if [ "$WA_SCOPE" = "Namespaced" ] || [ -z "$WA_SCOPE" ]; then
            where=" across all namespaces"
            run_k get "$WA_CRD" -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}'
        else
            # cluster-scoped: every read of the CR list in this run, and the
            # per-instance reads of section C, in one call (group CRG). A
            # namespaced kind keeps its own calls: sections C and J read it
            # per namespace and in the context's namespace.
            _cr_merged_get
            kg_run CRG list get "$WA_CRD" -o 'jsonpath={range .items[*]}{" "}{.metadata.name}{"\n"}{end}'
        fi
        if [ "$K_RC" -eq 0 ]; then
            out="$K_OUT"; CR_STATE=listed
            CR_WHY="the $WA_CRD list${where} answered with no items"
        else
            out=""; CR_STATE=failed
            CR_WHY="$WA_CRD list${where}: $(_k_reason)"
            [ -n "$scopewhy" ] && CR_WHY="$CR_WHY; crd scope not read: $scopewhy"
            [ -n "$OPT_NS" ] && CR_WHY="$CR_WHY (this run had --namespace $OPT_NS; the list is cluster-wide)"
        fi
        # parallel arrays; cap 3 instances
        local _n=0 _ns _nm
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            [ "$_n" -ge 3 ] && break
            _ns="$(printf '%s' "$line" | awk '{if (NF==2) print $1; else print ""}')"
            _nm="$(printf '%s' "$line" | awk '{print $NF}')"
            [ -n "$_nm" ] || continue
            CR_NAMES[${#CR_NAMES[@]}]="$_nm"
            CR_NSS[${#CR_NSS[@]}]="$_ns"
            _n=$((_n + 1))
        done <<EOF
$out
EOF
    fi
    # namespace-scoped workloads
    if [ -n "$NS" ]; then
        DS_NAME="$(kval get ds -n "$NS" -o name | grep -Ei 'whatap' | head -n1)"; DS_WHY="$(_kv_why)"
        DS_NAME="${DS_NAME##*/}"
        if [ -n "$DS_NAME" ]; then
            # every jsonpath read of the daemonset in this run, in one call (group DSG)
            KM_T=("$(_km_mark cont)" "$T_DS_CONT" "$(_km_mark sa)" "$T_DS_SA" "$(_km_mark mounts)" "$T_DS_MOUNTS" \
                  "$(_km_mark ports)" "$T_DS_PORTS" "$(_km_mark hostpid)" "$T_DS_HOSTPID")
            km_get DSG get ds "$DS_NAME" -n "$NS"
            DS_CONTAINERS="$(kg_kval DSG cont get ds "$DS_NAME" -n "$NS" -o "jsonpath=$T_DS_CONT")"; DSC_WHY="$(_kv_why)"
        fi
        OP_DEPLOY="$(kval get deploy -n "$NS" -o name | grep -Ei 'whatap-operator' | head -n1)"; OP_WHY="$(_kv_why)"
        OP_DEPLOY="${OP_DEPLOY##*/}"
        WHATAP_DEPLOYS="$(kval get deploy -n "$NS" 2>/dev/null | grep -Ei 'whatap|^NAME')"; DEP_WHY="$(_kv_why)"
        # the secret name list is read again in section D: one call (group SECG)
        run_k get secrets -n "$NS" -o name; kr_keep SECG names
        HELM_SECRETS="$(kg_kval SECG names get secrets -n "$NS" -o name | grep -E 'sh\.helm\.release\.v1\..*whatap' | sed 's#^secret/##')"; HS_WHY="$(_kv_why)"
    fi
    WEBHOOKS="$(kval get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -Ei 'whatap')"; WH_WHY="$(_kv_why)"
    # per-hook names: the API server keys its admission metrics by these, not by the
    # configuration object name, so they have to be resolved to read the counters
    # every jsonpath read of each whatap webhook configuration in this run, in
    # one call per configuration (groups WHG0, WHG1, ... in WEBHOOKS order)
    local wh j=0
    for wh in $WEBHOOKS; do
        KM_T=("$(_km_mark hooks)" "$T_WH_HOOKS" "$(_km_mark line)" "$T_WH_LINE" "$(_km_mark cab)" "$T_WH_CAB" \
              "$(_km_mark svc)" "$T_WH_SVC" "$(_km_mark cabt)" "$T_WH_CABT" "$(_km_mark mf)" "$T_WH_MF")
        km_get "WHG$j" get "$wh"
        WEBHOOK_HOOKS="$WEBHOOK_HOOKS $(kg_kval "WHG$j" hooks get "$wh" -o "jsonpath=$T_WH_HOOKS")"
        j=$((j + 1))
    done
    WHATAP_CROLES="$(kval get clusterroles -o name | grep -Ei 'whatap' | sed 's#^clusterrole\.rbac\.authorization\.k8s\.io/##' | head -n 5)"
    if run_k get mutatingwebhookconfigurations,validatingwebhookconfigurations \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .webhooks[*]}{.name}{","}{end}{"\n"}{end}'; then
        ALL_HOOKS="$(printf '%s\n' "$K_OUT" | grep -v '^$' | head -n 60)"
        [ -n "$ALL_HOOKS" ] || ALL_HOOKS_WHY="the list answered with no items"
    else
        ALL_HOOKS_WHY="$(_k_reason)"
    fi
}

# APM_SEL_VALS: every label VALUE named by an APM target's podSelector, one per
# line. Section J uses it to inspect the pods a target actually names before the
# rest of the namespace — without it a per-target cap can fill up with unrelated
# pods and leave the named workloads out of the report entirely.
# Only VALUES are collected, never keys: a key like "app" is carried by nearly
# every pod and would select everything.
APM_SEL_VALS=""
discover_apm_selector_values() {
    [ -n "$KCTL_BIN" ] && [ -n "$WA_CRD" ] || return
    local exprs labels
    exprs="$(kg_kval CRG selx get "$WA_CRD" -o "jsonpath=$T_CRL_SELX")"
    # matchLabels is a map; jsonpath cannot range over it, so the JSON object is
    # emitted and its values are taken from the "key":"value" pairs
    labels="$(kg_kval CRG sell get "$WA_CRD" -o "jsonpath=$T_CRL_SELL" \
        | tr ',' '\n' | sed -n 's/.*":"\([^"]*\)".*/\1/p')"
    APM_SEL_VALS="$(printf '%s\n%s\n' "$exprs" "$labels" | grep -v '^$' | sort -u)"
}

# sample node-agent pods: SP_POD/SP_PHASE/SP_RST parallel arrays sorted by
# total restart count (descending), built bash-3.2 style (no mapfile).
SP_POD=(); SP_PHASE=(); SP_RST=()
pick_sample_pods() {
    [ -n "$KCTL_BIN" ] && [ -n "$NS" ] || return
    local raw sorted line
    raw="$(kval get pods -n "$NS" -l name=whatap-node-agent -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}')"; SP_WHY="$(_kv_why)"
    if [ -z "$raw" ] && [ -n "$DS_NAME" ]; then
        # a failed label list stays failed even when the prefix fallback answers empty
        local sp1="$SP_WHY"
        raw="$(kval get pods -n "$NS" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}' | grep "^$DS_NAME-")"; SP_WHY="$(_kv_why)"
        [ -z "$raw" ] && [ -n "$sp1" ] && SP_WHY="label list: $sp1${SP_WHY:+; pod list: $SP_WHY}"
    fi
    [ -n "$raw" ] || return
    sorted="$(printf '%s\n' "$raw" | awk -F'|' 'NF>=2 { n=split($3,a,","); t=0; for(i=1;i<=n;i++) t+=a[i]; print t "|" $1 "|" $2 }' | sort -t'|' -k1,1nr)"
    for line in $sorted; do
        SP_POD[${#SP_POD[@]}]="$(printf '%s' "$line" | cut -d'|' -f2)"
        SP_PHASE[${#SP_PHASE[@]}]="$(printf '%s' "$line" | cut -d'|' -f3)"
        SP_RST[${#SP_RST[@]}]="$(printf '%s' "$line" | cut -d'|' -f1)"
    done
}

# =============================================================================
# Report body (Tier 0 — MECE domains A..I)
# =============================================================================
run_report() {
    emit_header

    goal api "Kubernetes API reachable"
    goal cr  "WhatapAgent CR"

    section "Collection environment"
    fact "collector: $COLLECTOR_NAME $VERSION"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root ))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "run host: $(hostname 2>/dev/null || echo unknown)"
    fact "tools:"
    local t
    for t in kubectl oc helm awk grep sed sort tar gzip timeout curl; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"; else printf '        %-12s absent\n' "$t"; fi
    done
    fact "cli in use: ${KCTL_BIN:-n/a (command not found: kubectl/oc)}"
    fact "cli global options: ${KOPTS[*]:-none}"
    fact "KUBECONFIG env: ${KUBECONFIG:-not set}"
    kprobe "current context" config current-context
    kprobe "client version" version --client
    if [ "$API_OK" = 1 ]; then fact "api reachability (get --raw /version, 5s): answered"
    else fact "api reachability (get --raw /version, 5s): n/a (${API_WHY#API check (get --raw /version, 5s) failed: })"; fi
    if [ -n "$NS" ]; then fact "namespace: $NS (via $NS_SRC)"; else fact "namespace: $NS_SRC"; fi
    if [ -n "$NS_ALL" ] && [ "$(printf '%s\n' "$NS_ALL" | wc -l | tr -d ' ')" -gt 1 ]; then
        fact "whatap workloads seen in multiple namespaces; this run covers '$NS':"
        printf '%s\n' "$NS_ALL" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    fi

    # Fail fast (engineering guideline 2): with no API every section below
    # would time out call by call. Each is still named, with the one reason.
    if [ "$API_OK" != 1 ]; then
        local st
        for st in "A. Cluster & API server" "B. Nodes" "C. WhaTap CRDs & WhatapAgent CR" \
                  "D. Operator, RBAC & admission webhooks" "E. Agent workloads" \
                  "F. Events, quotas & namespace constraints" "G. Logs (bounded tails)" \
                  "H. Helm & deployed image inventory" "I. In-pod node facts (kubectl exec into node-agent pods)" \
                  "J. APM auto-instrumentation"; do
            section "$st"
            fact "n/a (skipped: $API_WHY)"
        done
        missed api "$API_WHY"
        missed cr "not listed: $API_WHY"
        emit_status
        emit_footer
        return
    fi

    # -- A. Cluster & API server ----------------------------------------------
    section "A. Cluster & API server"
    kprobe "kubectl version (client+server)" version
    if run_k get --raw /readyz && [ -n "$K_OUT" ]; then fact "apiserver /readyz: $K_OUT"
    elif run_k get --raw /healthz && [ -n "$K_OUT" ]; then fact "apiserver /healthz: $K_OUT"
    else fact "apiserver readiness endpoints: n/a ($(_k_reason))"; fi
    # the same list feeds the status summary in section B (group NHG)
    run_k get nodes --no-headers; kr_keep NHG nh
    if [ "$K_RC" -eq 0 ]; then fact "node count: $(printf '%s\n' "$K_OUT" | grep -c .)"
    else fact "node count: n/a ($(_k_reason))"; fi
    if run_k get ns --no-headers; then fact "namespace count: $(printf '%s\n' "$K_OUT" | grep -c .)"
    else fact "namespace count: n/a ($(_k_reason))"; fi
    subsection "platform markers (verbatim; reader interprets)"
    # both first-node reads in one call (group NDG)
    KM_T=("$(_km_mark prov)" '{.items[0].spec.providerID}' "$(_km_mark labels)" '{.items[0].metadata.labels}')
    km_get NDG get nodes
    kg_probe NDG prov "first node providerID" get nodes -o 'jsonpath={.items[0].spec.providerID}'
    local nlabels
    if kg_run NDG labels get nodes -o 'jsonpath={.items[0].metadata.labels}'; then
        nlabels="$(printf '%s\n' "$K_OUT" | tr ' ,' '\n\n' | grep -Ei 'eks|gke|aks|azure|cce|openshift|cloud\.google|paas' | head -n 15)"
        if [ -n "$nlabels" ]; then _emit_labeled "first node platform-ish labels" "$nlabels"
        else fact "first node platform-ish labels: none matched (eks/gke/aks/azure/cce/openshift/paas)"; fi
    else
        fact "first node platform-ish labels: n/a ($(_k_reason))"
    fi
    local osgroups
    if run_k api-versions; then
        osgroups="$(printf '%s\n' "$K_OUT" | grep -ci openshift)"
        if [ "${osgroups:-0}" -gt 0 ] 2>/dev/null; then
            fact "openshift api groups: $osgroups"
            kprobe "clusterversion" get clusterversion
            kfilter "scc (whatap-filtered)" 'whatap|^NAME' get scc
        else
            fact "openshift api groups: 0 (clusterversion/scc not probed)"
        fi
    else
        fact "openshift api groups: n/a ($(_k_reason))"
    fi

    # -- B. Nodes ---------------------------------------------------------------
    section "B. Nodes"
    local ntable="" ncount
    run_k get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,ARCH:.status.nodeInfo.architecture && ntable="$K_OUT"
    if [ -n "$ntable" ]; then
        ncount="$(printf '%s\n' "$ntable" | grep -c . )"; ncount=$((ncount - 1))
        _emit_labeled "nodes (first 50)" "$(printf '%s\n' "$ntable" | head -n 51)"
        [ "$ncount" -gt 50 ] && fact "total nodes: $ncount (table above capped at 50)"
        _emit_labeled "distinct container runtimes" "$(printf '%s\n' "$ntable" | awk 'NR>1{print $(NF-1)}' | sort | uniq -c | sed 's/^ *//')"
    else
        fact "node table: n/a ($(_k_reason))"
    fi
    if kg_run NHG nh get nodes --no-headers; then
        _emit_labeled "node status summary" "$(printf '%s\n' "$K_OUT" | awk '{print $2}' | sort | uniq -c | sed 's/^ *//')"
    else
        fact "node status summary: n/a ($(_k_reason))"
    fi
    # Which nodes carry the control plane, and their addresses. An admission webhook is
    # called BY the API server, so when a webhook is not being applied, these are the
    # hosts whose path to the webhook backend is the one that matters. Both the current
    # and the pre-1.24 role label are printed, and roles are read from labels rather
    # than assumed from the node name.
    kprobe "control-plane nodes (role labels + addresses)" get nodes \
        -l node-role.kubernetes.io/control-plane \
        -o 'custom-columns=NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,CP:.metadata.labels.node-role\.kubernetes\.io/control-plane,MASTER:.metadata.labels.node-role\.kubernetes\.io/master'
    kfilter "nodes carrying any node-role label (fallback view, covers pre-1.24 'master')" 'node-role|^NAME' get nodes --show-labels

    # -- C. WhaTap CRDs & WhatapAgent CR ----------------------------------------
    section "C. WhaTap CRDs & WhatapAgent CR"
    if [ -n "$CRD_TABLE" ]; then _emit_labeled "whatap crds" "$CRD_TABLE"
    elif [ "$CR_STATE" = failed ] && [ -z "$WA_CRD" ]; then fact "whatap crds: n/a ($CR_WHY)"
    else fact "whatap crds: none (no crd name matching 'whatap' in the crd list)"; fi
    local m_crd m_hs
    if [ -n "$WA_CRD" ]; then m_crd="present ($WA_CRD)"
    elif [ "$CR_STATE" = failed ]; then m_crd="n/a ($CR_WHY)"
    else m_crd="absent"; fi
    if [ -n "$HELM_SECRETS" ]; then m_hs="$(printf '%s' "$HELM_SECRETS" | tr '\n' ',')"
    elif [ -z "$NS" ]; then m_hs="n/a (no whatap namespace discovered)"
    else m_hs="$(_none_or_na "$HS_WHY" "")"; m_hs="${m_hs% }"; fi
    local m_dsc
    if [ -n "$DS_CONTAINERS" ]; then m_dsc="$DS_CONTAINERS"
    elif [ -z "$NS" ]; then m_dsc="n/a (no whatap namespace discovered)"
    elif [ -z "$DS_NAME" ]; then m_dsc="n/a (no whatap daemonset: $(_none_or_na "$DS_WHY" "listed"))"
    else m_dsc="n/a (${DSC_WHY:-empty output})"; fi
    fact "install generation markers: crd=$m_crd ds-containers=$m_dsc helm-release-secrets=$m_hs"
    if [ -n "$WA_CRD" ]; then
        fact "crd scope: ${WA_SCOPE:-n/a (${SCOPE_WHY:-not read})}"
        kg_probe CRDG versions "crd stored/served versions" get crd "$WA_CRD" -o "jsonpath=$T_CRD_VERSIONS"
        if [ "${#CR_NAMES[@]}" -eq 0 ]; then
            if [ "$CR_STATE" = listed ]; then fact "whatapagent instances: none ($CR_WHY)"
            else fact "whatapagent instances: n/a ($CR_WHY)"; fi
        fi
        local i cr crns crref
        i=0
        while [ "$i" -lt "${#CR_NAMES[@]}" ]; do
            cr="${CR_NAMES[$i]}"; crns="${CR_NSS[$i]}"
            subsection "whatapagent instance: ${crns:+$crns/}$cr"
            if [ -n "$crns" ]; then crref="-n $crns"; else crref=""; fi
            # shellcheck disable=SC2086
            kprobe "cr yaml" get "$WA_CRD" "$cr" $crref -o yaml
            # env placement facts: the operator applies container-level envs and
            # pod-level envs through different code paths — surface both verbatim.
            # shellcheck disable=SC2086
            # (kg_probe: from the merged CR call when the kind is cluster-scoped)
            kg_probe CRG "$cr/ENV1" "nodeAgent.envs (pod-level) names" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_ENV1"
            # shellcheck disable=SC2086
            kg_probe CRG "$cr/ENV2" "nodeAgentContainer.envs names" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_ENV2"
            # shellcheck disable=SC2086
            kg_probe CRG "$cr/ENV3" "nodeHelperContainer.envs names" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_ENV3"
            # master switches above the per-target level: with apm.instrumentation.enabled
            # false, or no targets at all, the pod-mutating path returns before any target
            # is evaluated (whatapagent_webhook.go)
            # shellcheck disable=SC2086
            # when each writer last touched the CR — settles "was the apm block present
            # when that pod was created", which generation alone cannot answer
            # shellcheck disable=SC2086
            kg_probe CRG "$cr/MF" "cr write history (managedFields: manager / operation / time)" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_MF"
            # shellcheck disable=SC2086
            kg_probe CRG "$cr/ID" "cr identity + master switches" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_ID"
            # shellcheck disable=SC2086
            kg_probe CRG "$cr/TG" "apm instrumentation targets" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_TG"
            # the init image the operator will pull for each target: an explicit
            # customImageFullName overrides the default public.ecr.aws/whatap/apm-init-<lang>:<version>
            # shellcheck disable=SC2086
            kg_probe CRG "$cr/IMG" "apm target init image overrides + extra envs" get "$WA_CRD" "$cr" $crref -o "jsonpath=$T_CR_IMG"
            i=$((i + 1))
        done
    else
        fact "whatapagent cr probes: n/a ($CR_WHY)"
    fi
    subsection "configmaps in ${NS:-<no namespace>}"
    if [ -n "$NS" ]; then kprobe "configmaps (name/data/age)" get cm -n "$NS"
    else fact "configmaps: n/a (not applicable: no whatap namespace discovered)"; fi

    # -- D. Operator, RBAC & admission webhooks ----------------------------------
    section "D. Operator, RBAC & admission webhooks"
    if [ -n "$OP_DEPLOY" ]; then
        kprobe "operator pods" get pods -n "$NS" -l app.kubernetes.io/name=whatap-operator -o wide
        kprobe "operator deployment yaml" get deploy "$OP_DEPLOY" -n "$NS" -o yaml
        # the operator writes its per-pod admission decisions (target matched / pod
        # labels do not match / namespace does not match / target disabled) at V(1)-V(2),
        # so the log verbosity it was started with decides whether section G can show them
        kprobe "operator container command/args + log-level env" get deploy "$OP_DEPLOY" -n "$NS" \
            -o 'jsonpath={range .spec.template.spec.containers[*]}{.name}{" command="}{.command}{" args="}{.args}{" env="}{range .env[*]}{.name}{"="}{.value}{";"}{end}{"\n"}{end}'
        kfilter "operator replicasets (revision/image history)" "whatap-operator|^NAME" get rs -n "$NS" -o custom-columns=NAME:.metadata.name,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,IMAGE:.spec.template.spec.containers[0].image,CREATED:.metadata.creationTimestamp
    else
        if [ -z "$NS" ]; then fact "operator deployment: n/a (no whatap namespace discovered)"
        else fact "operator deployment: $(_none_or_na "$OP_WHY" "named whatap-operator in $NS")"; fi
    fi
    subsection "admission webhooks"
    if [ -n "$WEBHOOKS" ]; then
        local wh whsvc svcns svcname
        for wh in $WEBHOOKS; do
            _whg "$wh"
            # compact applicability line first (the full yaml below carries everything,
            # but these four fields decide whether a given pod is even sent to the webhook)
            kg_probe "$_WHG" line "webhook $wh (per-hook: name / path / rules / policies / selectors)" get "$wh" \
                -o "jsonpath=$T_WH_LINE"
            # an empty caBundle means the API server has nothing to trust the backend
            # with; the value itself is a long base64 blob, so its size is what is stated
            local cab
            cab="$(kg_kval "$_WHG" cab get "$wh" -o "jsonpath=$T_WH_CAB" | awk -F'=' '{printf "%s caBundle=%d bytes\n", $1, length($2)}')"
            if [ -n "$cab" ]; then _emit_labeled "webhook $wh caBundle size per hook" "$cab"
            else fact "webhook $wh caBundle size: n/a (empty output)"; fi
            kprobe "webhook $wh (yaml)" get "$wh" -o yaml
            # the webhook backend: a Service with no ready endpoint cannot mutate anything
            whsvc="$(kg_kval "$_WHG" svc get "$wh" -o "jsonpath=$T_WH_SVC" | sort -u | grep -v '^/*$')"
            if [ -n "$whsvc" ]; then
                for svcns in $whsvc; do
                    svcname="${svcns#*/}"; svcns="${svcns%%/*}"
                    [ -n "$svcname" ] && [ -n "$svcns" ] || continue
                    kprobe "webhook backend service $svcns/$svcname" get svc "$svcname" -n "$svcns" -o wide
                    kprobe "webhook backend endpoints $svcns/$svcname" get endpoints "$svcname" -n "$svcns"
                    # How many pods are serving this webhook right now. The operator mints
                    # its own CA per process, and the registered caBundle can match only
                    # one of them, so more than one ready address is itself the fact.
                    local eaddr ecount
                    if run_k get endpoints "$svcname" -n "$svcns" -o 'jsonpath={range .subsets[*]}{range .addresses[*]}{.ip}{":"}{end}{"\n"}{end}'; then
                        eaddr="$(printf '%s\n' "$K_OUT" | tr ':' '\n' | grep -v '^$')"
                        ecount="$(printf '%s\n' "$eaddr" | grep -c . )"
                        if [ -n "$eaddr" ]; then _emit_labeled "ready backend addresses: $ecount" "$eaddr"
                        else fact "ready backend addresses: 0"; fi
                    else
                        fact "ready backend addresses: n/a ($(_k_reason))"
                    fi
                done
            else
                fact "webhook $wh backend service: n/a (no clientConfig.service — url-based or empty)"
            fi
        done
    else
        fact "whatap mutating/validating webhooks: $(_none_or_na "$WH_WHY" "named whatap")"
    fi

    subsection "every admission webhook in the cluster (config -> hook names)"
    # Not whatap-filtered on purpose: a third-party mutating webhook that runs on the same
    # pods is part of the injection path (it can inject a conflicting env earlier in the
    # list), and a hook NAME reused by another configuration shares whatap's metric series.
    if [ -n "$ALL_HOOKS" ]; then _emit_labeled "webhook configurations (name -> hooks)" "$ALL_HOOKS"
    else fact "webhook configurations: n/a (${ALL_HOOKS_WHY:-not listed})"; fi

    subsection "webhook serving certificate vs registered caBundle"
    # The operator generates a fresh self-signed CA on every process start (cmd/main.go
    # generateSelfSignedCert) and writes it to /etc/webhook/certs, which the Deployment
    # mounts as an emptyDir — nothing persists across pod restarts. The caBundle in the
    # webhook configuration is written from whichever operator process reconciled last.
    # When the two disagree the API server rejects the call with
    #   x509: certificate signed by unknown authority ... "whatap-webhook-ca"
    # and, under failurePolicy: Ignore, the pod is admitted with no injection and no error.
    # So: the fingerprints below, and the times they were produced, are the fact.
    if [ -n "$WEBHOOKS" ] && have openssl; then
        local wh2 cab1 fpr
        for wh2 in $WEBHOOKS; do
            _whg "$wh2"
            cab1="$(kg_kval "$_WHG" cabt get "$wh2" -o "jsonpath=$T_WH_CABT")"
            [ -n "$cab1" ] || continue
            fpr="$(printf '%s\n' "$cab1" | while IFS="$(printf '\t')" read -r hn hb; do
                [ -n "$hb" ] || { printf '%s\tcaBundle empty\n' "$hn"; continue; }
                printf '%s\t%s\n' "$hn" "$(printf '%s' "$hb" | base64 -d 2>/dev/null \
                    | openssl x509 -noout -sha256 -fingerprint -subject -enddate 2>/dev/null \
                    | tr '\n' ' ' | sed 's/  */ /g')"
            done)"
            [ -n "$fpr" ] && _emit_labeled "$wh2 caBundle certificate (hook / fingerprint+subject+expiry)" "$fpr"
        done
    elif [ -n "$WEBHOOKS" ]; then
        fact "caBundle certificate fingerprints: n/a (command not found: openssl)"
    fi
    # The same CA as the operator stored it. Only the PUBLIC cert.pem field is read and
    # only its fingerprint is emitted — the key.pem / tls.key fields in this Secret are
    # never requested and never printed.
    if [ -n "$NS" ] && have openssl; then
        # the Secret name is discovered, not assumed — it has differed across versions
        local certsec secfp
        local cs_why
        certsec="$(kg_kval SECG names get secrets -n "$NS" -o name | sed 's#^secret/##' | grep -Ei 'webhook.*cert|cert.*webhook' | head -n1)"; cs_why="$(_kv_why)"
        if [ -n "$certsec" ]; then
            secfp="$(kval get secret "$certsec" -n "$NS" -o 'jsonpath={.data.cert\.pem}' \
                | base64 -d 2>/dev/null \
                | openssl x509 -noout -sha256 -fingerprint -subject 2>/dev/null | tr '\n' ' ')"
            if [ -n "$secfp" ]; then fact "secret $certsec cert.pem (public CA field only): $secfp"
            else fact "secret $certsec cert.pem: n/a (field absent or not parseable as a certificate)"; fi
        else
            fact "webhook certificate secret: $(_none_or_na "$cs_why" "in $NS matching webhook*cert")"
        fi
    fi
    # When each side was produced: an operator process that started AFTER the caBundle was
    # last written is serving a CA the configuration does not carry.
    if [ -n "$OP_DEPLOY" ]; then
        kprobe "operator pod process start / restarts" get pods -n "$NS" \
            -l app.kubernetes.io/name=whatap-operator \
            -o 'jsonpath={range .items[*]}{.metadata.name}{" podStart="}{.status.startTime}{" containerStarted="}{range .status.containerStatuses[*]}{.state.running.startedAt}{" restarts="}{.restartCount}{end}{"\n"}{end}'
    fi
    local wh3
    for wh3 in $WEBHOOKS; do
        _whg "$wh3"
        kg_probe "$_WHG" mf "$wh3 last written (managedFields times)" get "$wh3" \
            -o "jsonpath=$T_WH_MF"
    done
    # Best effort: the CA the running process actually has on disk. The operator image may
    # be distroless, in which case there is no shell and this reports why instead.
    if [ -n "$NS" ]; then
        local oppod
        oppod="$(kval get pods -n "$NS" -l app.kubernetes.io/name=whatap-operator -o 'jsonpath={.items[0].metadata.name}')"
        if [ -n "$oppod" ]; then
            pod_exec_probe_ns "$NS" "operator pod /etc/webhook/certs listing (mtimes show when this process wrote them)" "$oppod" operator \
                'ls -la /etc/webhook/certs 2>&1; :'
            # ca.crt is a public certificate, so it is read out and fingerprinted HERE with
            # the same openssl invocation used on the caBundle above — that is what makes the
            # three values directly comparable. The PEM itself is not emitted, and the
            # ca.key / tls.key files in that directory are never read.
            if have openssl && run_k exec -n "$NS" "$oppod" -c operator -- cat /etc/webhook/certs/ca.crt; then
                local podfp
                podfp="$(printf '%s\n' "$K_OUT" | openssl x509 -noout -sha256 -fingerprint -subject 2>/dev/null | tr '\n' ' ')"
                if [ -n "$podfp" ]; then fact "operator pod /etc/webhook/certs/ca.crt (fingerprinted locally, same command as the caBundle above): $podfp"
                else fact "operator pod ca.crt fingerprint: n/a (content not parseable as a certificate)"; fi
            elif ! have openssl; then
                fact "operator pod ca.crt fingerprint: n/a (command not found: openssl)"
            else
                fact "operator pod ca.crt fingerprint: n/a ($(_k_reason))"
            fi
        fi
    fi

    subsection "admission call counters (kube-apiserver /metrics)"
    # The API server counts every admission webhook call it makes, keyed by the
    # per-hook name. These counters come from the CALLER, so they are independent of
    # anything the operator logs: they state whether the API server reached the
    # webhook at all, what HTTP code came back, and how many calls were let through
    # without the webhook (fail-open, which is what failurePolicy: Ignore does).
    # Available on managed control planes too, where the API server log is not.
    if [ -n "$WEBHOOK_HOOKS" ]; then
        fact "whatap hook names (metric label 'name'): $(printf '%s' "$WEBHOOK_HOOKS" | tr -s ' ' | sed 's/^ //; s/ $//')"
        if run_k get --raw /metrics; then
            local mpat mrows mfo
            fact "/metrics payload: ${#K_OUT} bytes (single read, bounded by the per-call timeout)"
            mpat="$(printf '%s\n' $WEBHOOK_HOOKS | grep -v '^$' | sed 's/\./\\./g' | awk '{printf "%s%s", (NR>1 ? "|" : ""), $0}')"
            mrows="$(printf '%s\n' "$K_OUT" | grep -E '^apiserver_admission_webhook_(request_total|fail_open_count|admission_duration_seconds_count)' | grep -E "name=\"($mpat)\"")"
            if [ -n "$mrows" ]; then _emit_labeled "whatap hook counters" "$mrows"
            else fact "whatap hook counters: no metric series carries these hook names"; fi
            # every fail-open in the cluster, for context: another webhook failing the
            # same way points at the path rather than at whatap
            mfo="$(printf '%s\n' "$K_OUT" | grep -E '^apiserver_admission_webhook_fail_open_count')"
            if [ -n "$mfo" ]; then _emit_labeled "fail_open_count for every webhook in the cluster" "$mfo"
            else fact "fail_open_count series: none present"; fi
            # The counters above are keyed by hook NAME only — no configuration name — so a
            # hook name used by two configurations shares one series. kubebuilder scaffolds
            # generic names (mpod.kb.io / vpod.kb.io), so this is worth stating either way.
            if [ -n "$ALL_HOOKS" ]; then
                local hdup
                hdup="$(printf '%s\n' "$ALL_HOOKS" | awk -F'\t' '{n=split($2,a,","); for(i=1;i<=n;i++) if(a[i]!="") print a[i] "\t" $1}' \
                    | sort | awk -F'\t' '{c[$1]=c[$1] " " $2; n[$1]++} END {for (k in n) if (n[k]>1) printf "%s carried by:%s\n", k, c[k]}' | sort)"
                if [ -n "$hdup" ]; then
                    _emit_labeled "hook names carried by more than one webhook configuration (their counters are shared)" "$hdup"
                else
                    fact "hook names carried by more than one webhook configuration: none"
                fi
            fi
        else
            fact "kube-apiserver /metrics: n/a ($(_k_reason))"
        fi
    else
        fact "admission call counters: n/a (not applicable: no whatap webhook hook names resolved)"
    fi

    subsection "rbac & identity"
    if [ -n "$NS" ]; then
        kprobe "serviceaccounts (ns)" get sa -n "$NS"
        local dssa opsa
        [ -n "$DS_NAME" ] && dssa="$(kg_kval DSG sa get ds "$DS_NAME" -n "$NS" -o "jsonpath=$T_DS_SA")"
        [ -n "$OP_DEPLOY" ] && opsa="$(kval get deploy "$OP_DEPLOY" -n "$NS" -o 'jsonpath={.spec.template.spec.serviceAccountName}')"
        fact "serviceaccount referenced by daemonset: ${dssa:-n/a}"
        fact "serviceaccount referenced by operator deploy: ${opsa:-n/a}"
        if [ -n "$dssa" ]; then
            if run_k get sa "$dssa" -n "$NS"; then fact "daemonset serviceaccount object: present"
            else fact "daemonset serviceaccount object: n/a ($(_k_reason))"; fi
        fi
        kprobe "secrets in ns (names/types only — values never fetched)" get secrets -n "$NS"
    else
        fact "rbac probes: n/a (not applicable: no whatap namespace discovered)"
    fi
    kfilter "clusterroles (whatap-filtered)" 'whatap|^NAME' get clusterroles
    # rules, not just names: the pod-mutating path reads the Pod's Namespace object
    # while matching a target's namespaceSelector, so what the operator's role grants
    # on core resources is part of the injection path
    local crole
    for crole in $WHATAP_CROLES; do
        kprobe "clusterrole $crole rules (apiGroups | resources | verbs)" get clusterrole "$crole" \
            -o 'jsonpath={range .rules[*]}{.apiGroups}{" | "}{.resources}{" | "}{.verbs}{"\n"}{end}'
    done
    [ -z "$WHATAP_CROLES" ] && fact "clusterrole rules: n/a (no whatap-named clusterrole found)"
    kfilter "clusterrolebindings (whatap-filtered)" 'whatap|^NAME' get clusterrolebindings

    # -- E. Agent workloads (declared + pod state) -------------------------------
    section "E. Agent workloads"
    if [ -n "$DS_NAME" ]; then
        kprobe "daemonset status" get ds "$DS_NAME" -n "$NS"
        fact "daemonset container names (discovered): ${DS_CONTAINERS:-n/a}"
        kprobe "daemonset yaml" get ds "$DS_NAME" -n "$NS" -o yaml
    else
        if [ -z "$NS" ]; then fact "node-agent daemonset: n/a (no whatap namespace discovered)"
        else fact "node-agent daemonset: $(_none_or_na "$DS_WHY" "named whatap in $NS")"; fi
    fi
    subsection "node-agent pods"
    if [ "${#SP_POD[@]}" -gt 0 ]; then
        local i lim total
        total="${#SP_POD[@]}"
        lim="$total"; [ "$lim" -gt 30 ] && lim=30
        fact "pods (restarts|name|phase, highest restarts first, showing $lim of $total):"
        i=0
        while [ "$i" -lt "$lim" ]; do
            printf '        %s|%s|%s\n' "${SP_RST[$i]}" "${SP_POD[$i]}" "${SP_PHASE[$i]}"
            i=$((i + 1))
        done
        # describe the two pods with the highest restart counts
        i=0
        while [ "$i" -lt 2 ] && [ "$i" -lt "$total" ]; do
            kprobe "describe pod ${SP_POD[$i]}" describe pod "${SP_POD[$i]}" -n "$NS"
            i=$((i + 1))
        done
    else
        if [ -z "$NS" ]; then fact "node-agent pods: n/a (no whatap namespace discovered)"
        else fact "node-agent pods: $(_none_or_na "$SP_WHY" "(label name=whatap-node-agent${DS_NAME:+, then pods named $DS_NAME-*})")"; fi
    fi
    subsection "other whatap deployments in ${NS:-<no namespace>}"
    if [ -n "$WHATAP_DEPLOYS" ]; then _emit_labeled "deployments" "$WHATAP_DEPLOYS"
    elif [ -z "$NS" ]; then fact "deployments: n/a (no whatap namespace discovered)"
    else fact "deployments: $(_none_or_na "$DEP_WHY" "named whatap")"; fi

    # -- F. Events, quotas & namespace constraints --------------------------------
    section "F. Events, quotas & namespace constraints"
    if [ -n "$NS" ]; then
        if run_k get events -n "$NS" --sort-by=.lastTimestamp && [ -n "$K_OUT" ]; then
            _emit_labeled "events (last 60 by lastTimestamp)" "$(printf '%s\n' "$K_OUT" | tail -n 60)"
        else
            fact "events: n/a ($(_k_reason))"
        fi
        kprobe "resourcequota (ns)" describe resourcequota -n "$NS"
        kprobe "limitrange (ns)" describe limitrange -n "$NS"
        kprobe "namespace labels" get ns "$NS" --show-labels
    else
        fact "events/quota probes: n/a (not applicable: no whatap namespace discovered)"
    fi

    # -- G. Logs (bounded tails) ---------------------------------------------------
    section "G. Logs (bounded tails)"
    fact "bounds: --tail=$OPT_TAIL per container; previous instance --tail=100; up to 3 sample node-agent pods (--bundle carries fuller logs)"
    if [ -n "$NS" ]; then
        if [ -n "$OP_DEPLOY" ]; then
            if run_k logs -n "$NS" "deploy/$OP_DEPLOY" --tail="$OPT_TAIL" && [ -n "$K_OUT" ]; then
                _emit_labeled "logs deploy/$OP_DEPLOY" "$K_OUT"
            else
                fact "logs deploy/$OP_DEPLOY: n/a ($(_k_reason))"
            fi
        fi
        # The admission decision is written when a pod is CREATED, which is usually
        # far behind a 200-line tail on a long-lived operator. Pull a deeper tail and
        # keep only the lines the injector emits (agent injection, env assembly,
        # webhook admission), so the trail survives without shipping the whole log.
        if [ -n "$OP_DEPLOY" ]; then
            if run_k logs -n "$NS" "deploy/$OP_DEPLOY" --tail=4000 --limit-bytes=4000000; then
                local inj
                # includes the webhook's own skip wording (target disabled / pod labels do
                # not match / namespace does not match / no matching targets), which is the
                # trail for a pod that was seen by the webhook and left untouched
                inj="$(printf '%s\n' "$K_OUT" | grep -Ei 'inject|instrument|whatap-agent-init|NODE_OPTIONS|NODE_PATH|PYTHONPATH|JAVA_TOOL_OPTIONS|AGENT_PATH|mutat|admission|apm-init|target|selector|skipping' | tail -n 200)"
                if [ -n "$inj" ]; then
                    _emit_labeled "operator log lines matching injection markers (tail 4000 -> last 200 matches)" "$inj"
                else
                    fact "operator log lines matching injection markers: none in the last 4000 lines"
                fi
            else
                fact "operator log injection markers: n/a ($(_k_reason))"
            fi
        fi
        local mdep
        mdep="$(printf '%s\n' "$WHATAP_DEPLOYS" | awk '$1 ~ /master-agent/ {print $1; exit}')"
        if [ -n "$mdep" ]; then
            if run_k logs -n "$NS" "deploy/$mdep" --tail="$OPT_TAIL" && [ -n "$K_OUT" ]; then
                _emit_labeled "logs deploy/$mdep" "$K_OUT"
            else
                fact "logs deploy/$mdep: n/a ($(_k_reason))"
            fi
        else
            fact "master-agent deployment logs: n/a (no deployment name matching master-agent)"
        fi
        # sample node-agent pods: top-2 by restarts + first Running pod (max 3)
        local picked=" " count=0 i pod cont
        i=0
        while [ "$i" -lt "${#SP_POD[@]}" ] && [ "$count" -lt 3 ]; do
            pod="${SP_POD[$i]}"
            case "$i" in
                0|1) : ;;                                  # top restarts
                *) [ "${SP_PHASE[$i]}" = "Running" ] || { i=$((i + 1)); continue; } ;;
            esac
            case "$picked" in *" $pod "*) i=$((i + 1)); continue ;; esac
            picked="$picked$pod "
            count=$((count + 1))
            for cont in $DS_CONTAINERS; do
                emit_log_tail "$pod" "$cont" "$OPT_TAIL"
                [ "${SP_RST[$i]}" -gt 0 ] 2>/dev/null && emit_log_tail "$pod" "$cont" 100 previous
            done
            i=$((i + 1))
        done
        [ "${#SP_POD[@]}" -eq 0 ] && fact "node-agent pod logs: n/a (${SP_WHY:-no node-agent pods found})"
    else
        fact "log probes: n/a (not applicable: no whatap namespace discovered)"
    fi

    subsection "kube-apiserver logs (webhook call outcome)"
    # The API server writes a warning for every admission webhook call that fails,
    # INCLUDING when failurePolicy: Ignore then lets the request through — which is
    # otherwise a completely silent event. That line carries the reason (timeout /
    # x509 / connection refused), which the counters in section D do not.
    # A self-hosted control plane exposes it as a mirror pod in kube-system; a managed
    # control plane does not, and then the host's own log is the only source.
    local apods ap an=0 apfail=""
    if run_k get pods -n kube-system -l component=kube-apiserver -o name; then
        apods="$(printf '%s\n' "$K_OUT" | sed 's#^pod/##' | grep -v '^$')"
    else apfail="label component=kube-apiserver: $(_k_reason)"; fi
    if [ -z "$apods" ]; then
        if run_k get pods -n kube-system --no-headers; then
            apods="$(printf '%s\n' "$K_OUT" | awk '$1 ~ /^kube-apiserver-/ {print $1}')"
        else apfail="${apfail:+$apfail; }pod list: $(_k_reason)"; fi
    fi
    if [ -z "$apods" ] && [ -n "$apfail" ]; then
        fact "kube-apiserver pods: n/a ($apfail)"
    elif [ -n "$apods" ]; then
        fact "kube-apiserver pods found: $(printf '%s' "$apods" | tr '\n' ' ')"
        fact "bounds: --tail=2000 per pod, up to 3 pods, then filtered to webhook/whatap lines (cap 80)"
        for ap in $apods; do
            [ "$an" -ge 3 ] && break
            an=$((an + 1))
            if run_k logs -n kube-system "$ap" --tail=2000; then
                local alines
                alines="$(printf '%s\n' "$K_OUT" | grep -Ei 'failed calling webhook|admission webhook|webhook.*(timeout|x509|refused|no route|deadline)|whatap' | tail -n 80)"
                if [ -n "$alines" ]; then _emit_labeled "$ap webhook/whatap log lines" "$alines"
                else fact "$ap webhook/whatap log lines: none in the last 2000 lines"; fi
            else
                fact "logs $ap: n/a ($(_k_reason))"
            fi
        done
    else
        fact "kube-apiserver pods: none in kube-system (label component=kube-apiserver, name prefix kube-apiserver-)"
    fi

    # -- H. Helm & deployed image inventory ----------------------------------------
    section "H. Helm & deployed image inventory"
    probe "helm version" helm version --short
    if have helm; then
        local HOPTS=()
        [ -n "$OPT_KUBECONFIG" ] && HOPTS[${#HOPTS[@]}]="--kubeconfig=$OPT_KUBECONFIG"
        [ -n "$OPT_CONTEXT" ] && HOPTS[${#HOPTS[@]}]="--kube-context=$OPT_CONTEXT"
        local hl rel relns
        local hlrc
        hl="$(_bounded helm list -A "${HOPTS[@]}" 2>"$_errfile")"; hlrc=$?
        hl="$(printf '%s\n' "$hl" | grep -Ei 'whatap|^NAME')"
        if [ "$hlrc" -ne 0 ]; then
            if [ "$hlrc" -eq 124 ] && _past_deadline; then fact "helm releases: n/a (run deadline reached: ${RUN_DEADLINE}s)"
            elif [ "$hlrc" -eq 124 ]; then fact "helm releases: n/a (timed out: ${CMD_TIMEOUT}s)"
            else fact "helm releases: n/a ($(_classify_err))"; fi
        elif [ -n "$hl" ]; then
            _emit_labeled "helm releases (whatap-filtered)" "$hl"
            printf '%s\n' "$hl" | awk 'NR>1 || $1!="NAME" {print $1, $2}' | grep -vi '^NAME' | head -n 3 | while read -r rel relns; do
                [ -n "$rel" ] || continue
                probe "helm history $rel" helm history "$rel" -n "$relns" "${HOPTS[@]}"
                probe "helm values $rel (user-supplied)" helm get values "$rel" -n "$relns" "${HOPTS[@]}"
            done
        else
            fact "helm releases: none (whatap-filtered helm list -A)"
        fi
    else
        fact "helm releases: n/a (command not found: helm)"
    fi
    if [ -n "$HELM_SECRETS" ]; then _emit_labeled "helm release secrets in ${NS:-?} (name = sh.helm.release.v1.<release>.v<revision>)" "$HELM_SECRETS"
    elif [ -z "$NS" ]; then fact "helm release secrets: n/a (no whatap namespace discovered)"
    else fact "helm release secrets: $(_none_or_na "$HS_WHY" "in $NS")"; fi
    subsection "images declared by whatap workloads in ${NS:-<no namespace>}"
    if [ -n "$NS" ]; then
        local imgs
        imgs="$(kval get deploy,ds,sts -n "$NS" -o 'jsonpath={range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' | grep -v '^$' | sort -u)"
        if [ -n "$imgs" ]; then _emit_labeled "images (containers + initContainers)" "$imgs"
        else fact "images: n/a (empty output)"; fi
    else
        fact "image inventory: n/a (not applicable: no whatap namespace discovered)"
    fi

    # -- I. In-pod node facts (kubectl exec, best-effort) ---------------------------
    section "I. In-pod node facts (kubectl exec into node-agent pods)"
    if [ -n "$NS" ] && [ -n "$DS_NAME" ] && [ "${#SP_POD[@]}" -gt 0 ]; then
        # derive exec plan from the DS spec (declared mounts / ports / hostPID)
        local mounts logcont portcont hport hostpid
        mounts="$(kg_kval DSG mounts get ds "$DS_NAME" -n "$NS" -o "jsonpath=$T_DS_MOUNTS")"
        logcont="$(printf '%s\n' "$mounts" | awk -F'=' '$2 ~ /\/var\/log|\/rootfs/ {print $1; exit}')"
        [ -z "$logcont" ] && logcont="$(printf '%s' "$DS_CONTAINERS" | awk '{print $1}')"
        # candidate path roots derive from the chosen container's DECLARED mounts
        # (e.g. a whole-host mount at /rootfs shifts every host path under it)
        local mpaths m logdirs rootdirs sockdirs
        mpaths="$(printf '%s\n' "$mounts" | awk -F'=' -v c="$logcont" '$1 == c {print $2}' | tr ',' '\n' | grep -v '^$' | head -n 4)"
        logdirs="/var/log/containers"; rootdirs=""; sockdirs=""
        for m in $mpaths; do
            case "$m" in
                *.sock|/dev*|/sys*|/proc*|/etc*) continue ;;
                */var/log) logdirs="$logdirs $m/containers" ;;
                /) : ;;
                *) logdirs="$logdirs $m/var/log/containers" ;;
            esac
        done
        for m in "" $mpaths; do
            [ "$m" = "/" ] && m=""
            case "$m" in *.sock|/dev*|/sys*|/proc*|/etc*|*/var/log) continue ;; esac
            rootdirs="$rootdirs $m/var/log/pods $m/var/log/containers $m/mnt/paas/runtime/container_logs"
            sockdirs="$sockdirs $m/run/containerd/containerd.sock $m/var/run/docker.sock $m/run/crio/crio.sock"
        done
        local ports
        ports="$(kg_kval DSG ports get ds "$DS_NAME" -n "$NS" -o "jsonpath=$T_DS_PORTS")"
        portcont="$(printf '%s\n' "$ports" | awk -F'=' '$2 != "" {print $1; exit}')"
        hport="$(printf '%s\n' "$ports" | awk -F'=' '$2 != "" {print $2; exit}')"
        hostpid="$(kg_kval DSG hostpid get ds "$DS_NAME" -n "$NS" -o "jsonpath=$T_DS_HOSTPID")"
        fact "exec container for log-path probes: ${logcont:-n/a} (first container declaring a /var/log mount, else first container)"
        fact "declared container ports: $(printf '%s' "$ports" | tr '\n' ' ')"
        fact "daemonset hostPID: ${hostpid:-not set}"
        # choose exec pods: Running only — 1 with restarts, 1 without (or all with --exec-per-node)
        local EXEC_PODS="" i pod n=0
        if [ "$OPT_EXEC_ALL" = 1 ]; then
            i=0
            while [ "$i" -lt "${#SP_POD[@]}" ] && [ "$n" -lt 30 ]; do
                [ "${SP_PHASE[$i]}" = "Running" ] && { EXEC_PODS="$EXEC_PODS ${SP_POD[$i]}"; n=$((n + 1)); }
                i=$((i + 1))
            done
            warn "[Tier2] --exec-per-node: running read-only commands inside $n node-agent pods"
            fact "exec fan-out: $n running pods (--exec-per-node, cap 30)"
        else
            local with="" without=""
            i=0
            while [ "$i" -lt "${#SP_POD[@]}" ]; do
                if [ "${SP_PHASE[$i]}" = "Running" ]; then
                    if [ "${SP_RST[$i]}" -gt 0 ] 2>/dev/null; then [ -z "$with" ] && with="${SP_POD[$i]}"
                    else [ -z "$without" ] && without="${SP_POD[$i]}"; fi
                fi
                i=$((i + 1))
            done
            EXEC_PODS="$with $without"
            fact "exec samples: with-restarts=${with:-none} without-restarts=${without:-none}"
        fi
        local any=0
        # the in-pod probes of one pod run in ONE exec (_pod_probes_run), each
        # still through its own sh -c with its own exit status
        local pc1 pc2 pc3 pc4 pc5 pc6 pn pcs
        pc1="for d in $logdirs; do for f in \"\$d\"/*.log; do [ -L \"\$f\" ] || [ -e \"\$f\" ] || continue; readlink \"\$f\"; break 2; done; done; :"
        pc2="ls -d $rootdirs 2>/dev/null; :"
        pc3="ls -l $sockdirs 2>/dev/null; :"
        pc4='stat -fc %T /sys/fs/cgroup 2>/dev/null; ls /sys/fs/cgroup/cgroup.controllers 2>/dev/null; :'
        pc5="wget -qO- -T 5 http://127.0.0.1:$hport/health 2>/dev/null || curl -sf -m 5 http://127.0.0.1:$hport/health"
        pc6='for d in /proc/[0-9]*; do case "$(cat "$d/comm" 2>/dev/null)" in kubelet) tr "\0" " " < "$d/cmdline"; echo; break;; esac; done'
        for pod in $EXEC_PODS; do
            any=1
            subsection "in-pod probes: $pod"
            pcs=("$pc1" "$pc2" "$pc3" "$pc4")
            [ -n "$hport" ] && [ -n "$portcont" ] && pcs[${#pcs[@]}]="$pc5"
            [ "$hostpid" = "true" ] && pcs[${#pcs[@]}]="$pc6"
            _pod_probes_run "$pod" "$logcont" "${pcs[@]}"
            _pod_probe_emit 1 "container log symlink target (first entry found under: $logdirs)" "$pc1"
            _pod_probe_emit 2 "container-log roots present (candidates from declared mounts)" "$pc2"
            _pod_probe_emit 3 "container runtime sockets visible (candidates from declared mounts)" "$pc3"
            _pod_probe_emit 4 "cgroup filesystem type + v2 controllers file" "$pc4"
            pn=4
            if [ -n "$hport" ] && [ -n "$portcont" ]; then
                pn=5; _pod_probe_emit 5 "helper endpoint http://127.0.0.1:$hport/health" "$pc5"
            else
                fact "helper endpoint probe: n/a (not applicable: no containerPort declared in daemonset)"
            fi
            if [ "$hostpid" = "true" ]; then
                _pod_probe_emit $((pn + 1)) "kubelet cmdline (via hostPID /proc)" "$pc6"
            else
                fact "kubelet cmdline: n/a (not applicable: daemonset hostPID not set)"
            fi
        done
        [ "$any" = 0 ] && fact "in-pod probes: n/a (not applicable: no Running node-agent pod)"
    else
        fact "in-pod probes: n/a (not applicable: no namespace/daemonset/pods discovered)"
    fi

    # -- J. APM auto-instrumentation (application pods) ------------------------------
    # The operator's mutating webhook acts on pods at CREATE, so three states exist
    # and each is collected separately here:
    #   declared  — the workload template the application owner applied
    #   admitted  — the pod spec that survived admission (what the operator produced)
    #   running   — what the process actually received (--apm-exec, /proc/1/environ)
    # Section C carries the CR targets and their selectors; the namespace/pod labels
    # below are the other half of that comparison.
    section "J. APM auto-instrumentation"

    # ---- name mapping: the identifiers that have to line up before anything is injected --
    # Every one of these is a name or label the operator matches by string. They are
    # collected together, verbatim, so each side of every match can be read off one page.
    subsection "name mapping inputs (CR name, selectors, labels)"
    if [ -n "$WA_CRD" ]; then
        kg_probe CRG jnames "whatapagent CR names present (cluster)" get "$WA_CRD" -o "jsonpath=$T_CRL_JNAMES"
        if kg_run CRG jall get "$WA_CRD" -o "jsonpath=$T_CRL_JALL"; then
            case " $K_OUT " in
                *" whatap "*) fact "a whatapagent named 'whatap' is present: yes" ;;
                *) fact "a whatapagent named 'whatap' is present: no (names found: ${K_OUT:-none})" ;;
            esac
        else
            fact "a whatapagent named 'whatap' is present: n/a ($(_k_reason))"
        fi
        # how many targets exist at all, stated separately so "no targets declared" is
        # never confused with "the selector probe returned nothing"
        local tgtnames=""
        kg_run CRG jtgt get "$WA_CRD" -o "jsonpath=$T_CRL_JTGT" && tgtnames="$K_OUT"
        if [ -n "$tgtnames" ]; then _emit_labeled "apm instrumentation targets declared per cr (cr=target,target,...)" "$tgtnames"
        else fact "apm instrumentation targets declared per cr: n/a ($(_k_reason))"; fi
        # per-target selectors, one line per target, in the shape they are matched in:
        # namespaceSelector by name OR by namespace label; podSelector by pod label
        kg_probe CRG jsel "target selectors (matched against namespace names/labels and pod labels)" get "$WA_CRD" -o "jsonpath=$T_CRL_JSEL"
    else
        fact "whatapagent CR name mapping: n/a ($CR_WHY)"
    fi
    # the namespace side of namespaceSelector, for every namespace in the cluster
    kprobe "namespace names + labels (the namespaceSelector match input)" get ns --show-labels

    subsection "cluster-wide inventory: pods the APM webhook has instrumented"
    # Two independent markers, because either one alone can miss a pod:
    #   * the injected init container   — present even if the annotations were stripped
    #   * the whatap-apm-injected annotation the webhook stamps on the pod it mutated
    #     (whatapagent_webhook.go) — present even when a target overrides the init image
    #     with customImageFullName, whose name need not contain "whatap" at all
    if run_k get pods -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.phase}{"|"}{range .spec.initContainers[*]}{.name}{"="}{.image}{","}{end}{"|injected="}{.metadata.annotations.whatap-apm-injected}{" lang="}{.metadata.annotations.whatap-apm-language}{" ver="}{.metadata.annotations.whatap-apm-version}{"\n"}{end}'; then
        local inv invn invtot
        invtot="$(printf '%s\n' "$K_OUT" | grep -c .)"
        inv="$(printf '%s\n' "$K_OUT" | awk -F'|' 'NF>=5 && (tolower($4) ~ /whatap|apm-init/ || $5 ~ /injected=true/)')"
        if [ -n "$inv" ]; then
            invn="$(printf '%s\n' "$inv" | grep -c .)"
            _emit_labeled "instrumented pods — namespace|pod|phase|initContainers|webhook annotations ($invn of $invtot pods cluster-wide; first 100 listed)" "$(printf '%s\n' "$inv" | head -n 100)"
            _emit_labeled "count per namespace" "$(printf '%s\n' "$inv" | cut -d'|' -f1 | sort | uniq -c)"
            _emit_labeled "count per annotated language" "$(printf '%s\n' "$inv" | cut -d'|' -f5 | sed -n 's/.* lang=\([^ ]*\).*/\1/p' | sed 's/^$/<none>/' | sort | uniq -c)"
            # tally the whatap init images only; sibling init containers stay visible
            # per pod above, where their ORDER relative to the agent init matters
            _emit_labeled "whatap init-container images in use (count image)" "$(printf '%s\n' "$inv" | cut -d'|' -f4 | tr ',' '\n' | grep -Ei 'whatap|apm-init' | sed 's/^[^=]*=//' | grep -v '^$' | sort | uniq -c)"
            # a pod carrying one marker but not the other is a fact on its own
            local invmm
            invmm="$(printf '%s\n' "$inv" | awk -F'|' '
                { ic = (tolower($4) ~ /whatap|apm-init/); an = ($5 ~ /injected=true/) }
                ic && !an { printf "%s/%s init container only (no whatap-apm-injected annotation)\n", $1, $2 }
                !ic && an { printf "%s/%s annotation only (no whatap init container)\n", $1, $2 }' | head -n 40)"
            if [ -n "$invmm" ]; then _emit_labeled "pods carrying only one of the two markers" "$invmm"
            else fact "pods carrying only one of the two markers: none (every instrumented pod has both)"; fi
        else
            fact "instrumented pods: none among $invtot pods cluster-wide (no whatap init container and no whatap-apm-injected annotation)"
        fi
    else
        fact "cluster-wide instrumented-pod inventory: n/a ($(_k_reason))"
    fi

    if [ "${#APM_TGTS[@]}" -eq 0 ]; then
        fact "per-target inspection: n/a (not requested: no --apm-target given)"
        [ "$OPT_APM_EXEC" = 1 ] && fact "in-container probes: n/a (--apm-exec given with no --apm-target)"
    else
        local ti tgt tns twl
        ti=0
        while [ "$ti" -lt "${#APM_TGTS[@]}" ] && [ "$ti" -lt 5 ]; do
            tgt="${APM_TGTS[$ti]}"
            tns="${tgt%%/*}"
            twl=""; case "$tgt" in */*) twl="${tgt#*/}" ;; esac
            subsection "target: namespace=$tns${twl:+ workload=$twl}"
            kprobe "namespace labels" get ns "$tns" --show-labels
            kprobe "namespace annotations" get ns "$tns" -o 'jsonpath={.metadata.annotations}'

            # ---- declared state: workload templates (never touched by the webhook) ----
            local wls wl wlkind wlname
            wls="$(kval get deploy,sts,ds -n "$tns" -o name)"
            [ -n "$twl" ] && wls="$(printf '%s\n' "$wls" | awk -F'/' -v p="$twl" 'index($2, p) == 1')"
            wls="$(printf '%s\n' "$wls" | grep -v '^$' | head -n 5)"
            if [ -z "$wls" ]; then
                fact "workloads (deploy/sts/ds): none found${twl:+ matching $twl} in $tns"
            fi
            for wl in $wls; do
                wlkind="${wl%%/*}"; wlname="${wl##*/}"
                kprobe "workload $wl template labels" get "$wlkind" "$wlname" -n "$tns" -o 'jsonpath={.spec.template.metadata.labels}'
                kprobe "workload $wl template annotations" get "$wlkind" "$wlname" -n "$tns" -o 'jsonpath={.spec.template.metadata.annotations}'
                kprobe "workload $wl rollout (generation/observed/updated/ready)" get "$wlkind" "$wlname" -n "$tns" \
                    -o 'jsonpath={"generation="}{.metadata.generation}{" observed="}{.status.observedGeneration}{" updated="}{.status.updatedReplicas}{" ready="}{.status.readyReplicas}{" replicas="}{.status.replicas}'
                _emit_env_table "workload $wl env AS DECLARED" "$(kval get "$wlkind" "$wlname" -n "$tns" -o "$(_envpath .spec.template.spec)")"
            done

            # ---- admitted state: pods ------------------------------------------------
            # order: (1) pods whose labels carry a value named by an APM target's
            # podSelector — the pods the CR actually asks for, which a plain
            # alphabetical cap can miss entirely; then (2) most not-ready containers
            # first (init containers counted too); then (3) by name.
            local praw psorted tpods tp ttotal
            praw="$(kval get pods -n "$tns" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{range .status.initContainerStatuses[*]}{.ready}{","}{end}{"|"}{range .status.containerStatuses[*]}{.ready}{","}{end}{"|"}{.metadata.labels}{"\n"}{end}')"
            [ -n "$twl" ] && praw="$(printf '%s\n' "$praw" | grep -E "^$twl")"
            psorted="$(printf '%s\n' "$praw" | grep -v '^$' | awk -F'|' -v sel="$APM_SEL_VALS" '
                BEGIN { nsel = split(sel, sv, "\n") }
                { n = split($2 $3, a, ","); nr = 0; for (i = 1; i <= n; i++) if (a[i] == "false") nr++
                  hit = 0
                  for (i = 1; i <= nsel; i++) if (sv[i] != "" && index($4, "\"" sv[i] "\"") > 0) { hit = 1; break }
                  print hit "|" nr "|" $1 }' \
                | sort -t'|' -k1,1nr -k2,2nr -k3,3)"
            ttotal="$(printf '%s\n' "$psorted" | grep -c .)"
            tpods="$(printf '%s\n' "$psorted" | head -n 5 | cut -d'|' -f3)"
            if [ -n "$APM_SEL_VALS" ]; then
                _emit_labeled "label values named by an apm target podSelector (pods carrying one are inspected first)" "$APM_SEL_VALS"
                fact "pods carrying one of those values: $(printf '%s\n' "$psorted" | awk -F'|' '$1==1' | grep -c .) of $ttotal"
            else
                fact "apm target podSelector values: none declared (pod order falls back to not-ready count, then name)"
            fi
            if [ -z "$tpods" ]; then
                fact "pods: none found${twl:+ with name prefix $twl} in namespace $tns"
            else
                fact "pods inspected: $(printf '%s\n' "$tpods" | grep -c .) of $ttotal (cap 5, ordered by podSelector match, then not-ready count, then name)"
            fi
            # every pod in the namespace with its labels (the podSelector match input) and
            # its injection markers side by side — uncapped at 60, so the pods the webhook
            # left untouched are visible next to the ones it changed
            kprobe "all pods in $tns: labels + injection markers (podSelector match input)" get pods -n "$tns" \
                -o 'jsonpath={range .items[*]}{.metadata.name}{" labels="}{.metadata.labels}{" injected="}{.metadata.annotations.whatap-apm-injected}{" lang="}{.metadata.annotations.whatap-apm-language}{" ver="}{.metadata.annotations.whatap-apm-version}{"\n"}{end}'
            for tp in $tpods; do
                fact "--- pod $tp ---"
                kprobe "pod $tp identity" get pod "$tp" -n "$tns" \
                    -o 'jsonpath={"phase="}{.status.phase}{" node="}{.spec.nodeName}{" created="}{.metadata.creationTimestamp}{" owner="}{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{" "}{end}{" sa="}{.spec.serviceAccountName}'
                kprobe "pod $tp labels" get pod "$tp" -n "$tns" -o 'jsonpath={.metadata.labels}'
                kprobe "pod $tp annotations" get pod "$tp" -n "$tns" -o 'jsonpath={.metadata.annotations}'
                kprobe "pod $tp initContainers (declared)" get pod "$tp" -n "$tns" -o 'jsonpath={range .spec.initContainers[*]}{.name}{" image="}{.image}{" imagePullPolicy="}{.imagePullPolicy}{"\n"}{end}'
                kprobe "pod $tp initContainer status (state carries waiting reason/message)" get pod "$tp" -n "$tns" \
                    -o 'jsonpath={range .status.initContainerStatuses[*]}{.name}{" ready="}{.ready}{" restarts="}{.restartCount}{" state="}{.state}{" lastState="}{.lastState}{"\n"}{end}'
                kprobe "pod $tp container status" get pod "$tp" -n "$tns" \
                    -o 'jsonpath={range .status.containerStatuses[*]}{.name}{" ready="}{.ready}{" restarts="}{.restartCount}{" image="}{.image}{" state="}{.state}{"\n"}{end}'
                # the agent home is an emptyDir shared init->app; a mount present on the
                # init container but absent on the app container is a fact worth having
                kprobe "pod $tp volumes (name=source keys)" get pod "$tp" -n "$tns" -o 'jsonpath={range .spec.volumes[*]}{.name}{"\n"}{end}'
                kprobe "pod $tp volumeMounts per container" get pod "$tp" -n "$tns" \
                    -o 'jsonpath={range .spec.initContainers[*]}{"init:"}{.name}{" "}{range .volumeMounts[*]}{.name}{":"}{.mountPath}{" "}{end}{"\n"}{end}{range .spec.containers[*]}{.name}{" "}{range .volumeMounts[*]}{.name}{":"}{.mountPath}{" "}{end}{"\n"}{end}'
                kprobe "pod $tp securityContext (pod + per container)" get pod "$tp" -n "$tns" \
                    -o 'jsonpath={"pod="}{.spec.securityContext}{"\n"}{range .spec.containers[*]}{.name}{"="}{.securityContext}{"\n"}{end}'
                _emit_env_table "pod $tp env AS ADMITTED" "$(kval get pod "$tp" -n "$tns" -o "$(_envpath .spec)")"

                # ---- logs: init container output, then the head of each app container --
                local icl icname acl acname acn
                icl="$(kval get pod "$tp" -n "$tns" -o 'jsonpath={range .spec.initContainers[*]}{.name}{"\n"}{end}' | grep -Ei 'whatap|apm-init')"
                if [ -n "$icl" ]; then
                    for icname in $icl; do
                        if run_k logs -n "$tns" "$tp" -c "$icname" --limit-bytes=8000; then
                            if [ -n "$K_OUT" ]; then _emit_labeled "init log $tp/$icname (first 8000B)" "$K_OUT"
                            else fact "init log $tp/$icname: n/a (empty output)"; fi
                        else
                            fact "init log $tp/$icname: n/a ($(_k_reason))"
                        fi
                    done
                else
                    fact "whatap init container in pod $tp: none (no initContainer named whatap/apm-init)"
                fi
                acl="$(kval get pod "$tp" -n "$tns" -o 'jsonpath={range .spec.containers[*]}{.name}{"\n"}{end}' | grep -v '^$')"
                acn=0
                for acname in $acl; do
                    [ "$acn" -ge 2 ] && break
                    acn=$((acn + 1))
                    emit_log_head_ns "$tns" "$tp" "$acname" 4000
                done
            done

            # ---- observed events in the application namespace ------------------------
            if run_k get events -n "$tns" --sort-by=.lastTimestamp && [ -n "$K_OUT" ]; then
                _emit_labeled "events in $tns (last 60 by lastTimestamp)" "$(printf '%s\n' "$K_OUT" | tail -n 60)"
            else
                fact "events in $tns: n/a ($(_k_reason))"
            fi

            # ---- Tier 2: running state inside the application container --------------
            if [ "$OPT_APM_EXEC" = 1 ]; then
                local xp xc xn=0
                warn "[Tier2] --apm-exec: running read-only commands inside application containers in $tns"
                for xp in $tpods; do
                    [ "$xn" -ge 3 ] && break
                    xc="$(kval get pod "$xp" -n "$tns" -o 'jsonpath={.spec.containers[0].name}')"
                    [ -n "$xc" ] || continue
                    xn=$((xn + 1))
                    subsection "in-container probes: $tns/$xp/$xc"
                    # /proc/1/environ is the env the process actually received — the pod
                    # spec is what was requested, this is what took effect.
                    pod_exec_probe_ns "$tns" "pid 1 cmdline" "$xp" "$xc" \
                        'tr "\0" " " < /proc/1/cmdline 2>/dev/null; echo'
                    pod_exec_probe_ns "$tns" "pid 1 environ (whatap / agent-loader keys)" "$xp" "$xc" \
                        'tr "\0" "\n" < /proc/1/environ 2>/dev/null | grep -Ei "whatap|okind|NODE_OPTIONS|NODE_PATH|PYTHONPATH|JAVA_TOOL_OPTIONS|license|^APP_"'
                    pod_exec_probe_ns "$tns" "agent home listing" "$xp" "$xc" \
                        'H=${WHATAP_HOME:-/whatap-agent}; echo "home=$H"; ls -la "$H" 2>&1 | head -n 30'
                    pod_exec_probe_ns "$tns" "agent home node_modules/whatap (nodejs seeding)" "$xp" "$xc" \
                        'H=${WHATAP_HOME:-/whatap-agent}; ls -la "$H/node_modules/whatap" 2>&1 | head -n 20; ls -la "$H/agent" 2>&1 | head -n 10'
                    pod_exec_probe_ns "$tns" "whatap.conf as present in the container" "$xp" "$xc" \
                        'H=${WHATAP_HOME:-/whatap-agent}; for f in "$H/whatap.conf" ./whatap.conf /whatap.conf; do [ -f "$f" ] && { echo "== $f"; cat "$f"; }; done; :'
                    pod_exec_probe_ns "$tns" "agent log directory + newest lines" "$xp" "$xc" \
                        'H=${WHATAP_HOME:-/whatap-agent}; ls -la "$H/logs" 2>&1 | head -n 20; for f in "$H"/logs/*.log; do [ -f "$f" ] && { echo "== $f"; tail -n 40 "$f"; }; done; :'
                    pod_exec_probe_ns "$tns" "agent port registry (/tmp/whatap-*.lock)" "$xp" "$xc" \
                        'ls -la /tmp/whatap-*.lock 2>/dev/null && cat /tmp/whatap-*.lock 2>/dev/null; :'
                    pod_exec_probe_ns "$tns" "language runtime version" "$xp" "$xc" \
                        'node -v 2>&1; python3 -V 2>&1; java -version 2>&1 | head -n 3; :'
                    pod_exec_probe_ns "$tns" "application module tree (whatap present in app node_modules?)" "$xp" "$xc" \
                        'ls -d ./node_modules/whatap /app/node_modules/whatap /usr/src/app/node_modules/whatap 2>/dev/null; :'
                done
                [ "$xn" = 0 ] && fact "in-container probes: n/a (no pod/container resolved in $tns)"
            else
                fact "in-container probes: n/a (not requested: no --apm-exec given)"
            fi
            ti=$((ti + 1))
        done
        [ "${#APM_TGTS[@]}" -gt 5 ] && fact "targets capped: first 5 of ${#APM_TGTS[@]} processed"
    fi

    got api
    if [ "${#CR_NAMES[@]}" -gt 0 ]; then got cr
    elif [ "$CR_STATE" = listed ] || [ "$CR_STATE" = nocrd ]; then na cr "$CR_WHY"
    else missed cr "${CR_WHY:-the whatapagents list was not reached}"; fi

    emit_status
    emit_footer
}

# =============================================================================
# Bundle (Tier 1)
# =============================================================================
_bundle_write() {
    # _bundle_write FILE ARGS... -> run_k output into FILE; skipped on failure
    local file="$1"; shift
    if run_k "$@" && [ -n "$K_OUT" ]; then
        printf '%s\n' "$K_OUT" > "$file" 2>/dev/null
    fi
}

collect_bundle_cr() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$WA_CRD" ] || { warn "cr: skipped (no whatapagents crd)"; return; }
    _bundle_write "$dest/crd-$WA_CRD.yaml" get crd "$WA_CRD" -o yaml
    local i cr crns
    i=0
    while [ "$i" -lt "${#CR_NAMES[@]}" ]; do
        cr="${CR_NAMES[$i]}"; crns="${CR_NSS[$i]}"
        if [ -n "$crns" ]; then _bundle_write "$dest/cr-$crns-$cr.yaml" get "$WA_CRD" "$cr" -n "$crns" -o yaml
        else _bundle_write "$dest/cr-$cr.yaml" get "$WA_CRD" "$cr" -o yaml; fi
        i=$((i + 1))
    done
    progress "cr: yaml written"
}

collect_bundle_operator() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$NS" ] || return
    [ -n "$OP_DEPLOY" ] && _bundle_write "$dest/operator-deploy.yaml" get deploy "$OP_DEPLOY" -n "$NS" -o yaml
    _bundle_write "$dest/replicasets.txt" get rs -n "$NS" -o wide
    local wh
    for wh in $WEBHOOKS; do
        _bundle_write "$dest/webhook-$(printf '%s' "$wh" | tr '/.' '--').yaml" get "$wh" -o yaml
    done
    _bundle_write "$dest/serviceaccounts.txt" get sa -n "$NS"
    _bundle_write "$dest/secrets-names-only.txt" get secrets -n "$NS"
    progress "operator: yaml/tables written"
}

collect_bundle_agents() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$NS" ] || return
    [ -n "$DS_NAME" ] && _bundle_write "$dest/daemonset.yaml" get ds "$DS_NAME" -n "$NS" -o yaml
    _bundle_write "$dest/pods-wide.txt" get pods -n "$NS" -o wide
    local i
    i=0
    while [ "$i" -lt 2 ] && [ "$i" -lt "${#SP_POD[@]}" ]; do
        _bundle_write "$dest/describe-${SP_POD[$i]}.txt" describe pod "${SP_POD[$i]}" -n "$NS"
        i=$((i + 1))
    done
    progress "agents: yaml/tables written"
}

# Caps for the per-container log files. A namespace with many pods would
# otherwise pull every container twice at 5 MB each.
BUNDLE_LOG_PODS=20          # pods whose containers are fetched
BUNDLE_LOG_BYTES=2000000    # per container file (--limit-bytes)
BUNDLE_LOG_TOTAL=60000000   # all log files together
collect_bundle_logs() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$NS" ] || return
    local podconts line pod conts cont cname crst npod=0 skipped_pods=""
    # containerStatuses carry the restart count, so --previous is asked only
    # where a previous instance exists; a pod with no status yet has no log
    run_k get pods -n "$NS" -o 'jsonpath={range .items[*]}{.metadata.name}{"="}{range .status.containerStatuses[*]}{.name}{":"}{.restartCount}{","}{end}{"\n"}{end}'
    podconts="$K_OUT"
    for line in $podconts; do
        pod="${line%%=*}"; conts="$(printf '%s' "${line#*=}" | tr ',' ' ')"
        [ -n "$conts" ] || continue
        if [ "$npod" -ge "$BUNDLE_LOG_PODS" ]; then skipped_pods="$skipped_pods $pod"; continue; fi
        npod=$((npod + 1))
        for cont in $conts; do
            cname="${cont%%:*}"; crst="${cont#*:}"
            [ -n "$cname" ] || continue
            # checked before the fetch with the per-file cap, so the total stays under the cap
            if [ $((BL_SUM + BUNDLE_LOG_BYTES + 1)) -gt "$BUNDLE_LOG_TOTAL" ]; then BL_LEFT="$BL_LEFT $pod/$cname"; continue; fi
            if run_k logs -n "$NS" "$pod" -c "$cname" --tail=2000 --limit-bytes="$BUNDLE_LOG_BYTES" && [ -n "$K_OUT" ]; then
                printf '%s\n' "$K_OUT" > "$dest/${pod}_${cname}.log" 2>/dev/null
                BL_SUM=$((BL_SUM + ${#K_OUT} + 1)); BL_FILES=$((BL_FILES + 1))
            fi
            [ "${crst:-0}" -gt 0 ] 2>/dev/null || continue
            [ $((BL_SUM + BUNDLE_LOG_BYTES + 1)) -gt "$BUNDLE_LOG_TOTAL" ] && { BL_LEFT="$BL_LEFT $pod/$cname(previous)"; continue; }
            if run_k logs -n "$NS" "$pod" -c "$cname" --tail=2000 --limit-bytes="$BUNDLE_LOG_BYTES" --previous && [ -n "$K_OUT" ]; then
                printf '%s\n' "$K_OUT" > "$dest/${pod}_${cname}.previous.log" 2>/dev/null
                BL_SUM=$((BL_SUM + ${#K_OUT} + 1)); BL_FILES=$((BL_FILES + 1))
            fi
        done
    done
    BL_PODS_LEFT="$skipped_pods"
    progress "logs: $BL_FILES files, $BL_SUM bytes so far"
}

# the log caps cover logs/ and apm-targets/ together; CAPS.txt is written
# after both, into logs/
BL_SUM=0 BL_FILES=0 BL_LEFT="" BL_PODS_LEFT=""
write_bundle_caps() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    {
        printf 'namespace: %s\n' "${NS:-n/a}"
        printf 'caps: %s pods, tail 2000 lines and %s bytes per container file, %s bytes in total (logs/ and apm-targets/ together)\n' \
            "$BUNDLE_LOG_PODS" "$BUNDLE_LOG_BYTES" "$BUNDLE_LOG_TOTAL"
        printf 'previous-instance logs: fetched only for containers with restartCount > 0\n'
        printf 'files written: %s, bytes: %s\n' "$BL_FILES" "$BL_SUM"
        printf 'pods left out by the pod cap:%s\n' "${BL_PODS_LEFT:- none}"
        printf 'containers left out by the total cap:%s\n' "${BL_LEFT:- none}"
    } > "$dest/CAPS.txt" 2>/dev/null
    [ -n "$BL_PODS_LEFT$BL_LEFT" ] && warn "bundle logs: caps reached; left out:${BL_PODS_LEFT}${BL_LEFT} (listed in logs/CAPS.txt)"
    progress "logs: $BL_FILES files, $BL_SUM bytes (caps in logs/CAPS.txt)"
}

collect_bundle_cluster() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$NS" ] && _bundle_write "$dest/events.txt" get events -n "$NS" --sort-by=.lastTimestamp
    _bundle_write "$dest/nodes-wide.txt" get nodes -o wide
    local nc
    nc="$(kval get nodes --no-headers | grep -c .)"
    if [ "${nc:-0}" -le 30 ] 2>/dev/null && [ "${nc:-0}" -gt 0 ] 2>/dev/null; then
        _bundle_write "$dest/nodes.yaml" get nodes -o yaml
    else
        printf 'node yaml skipped: %s nodes (cap 30)\n' "${nc:-unknown}" > "$dest/nodes-yaml-skipped.txt" 2>/dev/null
    fi
    if [ -n "$NS" ]; then
        local imgs
        imgs="$(kval get deploy,ds,sts -n "$NS" -o 'jsonpath={range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' | grep -v '^$' | sort -u)"
        [ -n "$imgs" ] && printf '%s\n' "$imgs" > "$dest/images.txt" 2>/dev/null
    fi
    progress "cluster: events/nodes/images written"
}

collect_bundle_apm() {
    # Raw artifacts for the --apm-target namespaces: the workload yaml (env as
    # declared), the pod yaml (env as admitted), init/app logs and events. The
    # report carries the extracted facts; this carries the originals to re-read.
    local dest="$1"
    [ "${#APM_TGTS[@]}" -gt 0 ] || return
    mkdir -p "$dest" 2>/dev/null
    local ti tgt tns twl wls wl wlkind wlname pods tp conts cont
    ti=0
    while [ "$ti" -lt "${#APM_TGTS[@]}" ] && [ "$ti" -lt 5 ]; do
        tgt="${APM_TGTS[$ti]}"; tns="${tgt%%/*}"
        twl=""; case "$tgt" in */*) twl="${tgt#*/}" ;; esac
        mkdir -p "$dest/$tns" 2>/dev/null
        _bundle_write "$dest/$tns/pods-wide.txt" get pods -n "$tns" -o wide
        _bundle_write "$dest/$tns/events.txt" get events -n "$tns" --sort-by=.lastTimestamp
        _bundle_write "$dest/$tns/namespace.yaml" get ns "$tns" -o yaml
        wls="$(kval get deploy,sts,ds -n "$tns" -o name)"
        [ -n "$twl" ] && wls="$(printf '%s\n' "$wls" | awk -F'/' -v p="$twl" 'index($2, p) == 1')"
        for wl in $(printf '%s\n' "$wls" | grep -v '^$' | head -n 5); do
            wlkind="${wl%%/*}"; wlname="${wl##*/}"
            _bundle_write "$dest/$tns/workload-$wlkind-$wlname.yaml" get "$wlkind" "$wlname" -n "$tns" -o yaml
        done
        pods="$(kval get pods -n "$tns" --no-headers | awk '{print $1}')"
        [ -n "$twl" ] && pods="$(printf '%s\n' "$pods" | grep -E "^$twl")"
        for tp in $(printf '%s\n' "$pods" | grep -v '^$' | head -n 5); do
            _bundle_write "$dest/$tns/pod-$tp.yaml" get pod "$tp" -n "$tns" -o yaml
            _bundle_write "$dest/$tns/describe-$tp.txt" describe pod "$tp" -n "$tns"
            conts="$(kval get pod "$tp" -n "$tns" -o 'jsonpath={range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}')"
            for cont in $conts; do
                [ -n "$cont" ] || continue
                if [ $((BL_SUM + BUNDLE_LOG_BYTES + 1)) -gt "$BUNDLE_LOG_TOTAL" ]; then BL_LEFT="$BL_LEFT $tns/$tp/$cont"; continue; fi
                if run_k logs -n "$tns" "$tp" -c "$cont" --limit-bytes="$BUNDLE_LOG_BYTES" && [ -n "$K_OUT" ]; then
                    printf '%s\n' "$K_OUT" > "$dest/$tns/${tp}_${cont}.log" 2>/dev/null
                    BL_SUM=$((BL_SUM + ${#K_OUT} + 1)); BL_FILES=$((BL_FILES + 1))
                fi
            done
        done
        ti=$((ti + 1))
    done
    progress "apm targets: workload/pod yaml, logs, events written"
}

collect_bundle_helm() {
    local dest="$1"
    have helm || { warn "helm: skipped (command not found: helm)"; return; }
    mkdir -p "$dest" 2>/dev/null
    local HOPTS=()
    [ -n "$OPT_KUBECONFIG" ] && HOPTS[${#HOPTS[@]}]="--kubeconfig=$OPT_KUBECONFIG"
    [ -n "$OPT_CONTEXT" ] && HOPTS[${#HOPTS[@]}]="--kube-context=$OPT_CONTEXT"
    local hrc
    _bounded helm list -A "${HOPTS[@]}" > "$(_tmp helm.list)" 2>"$(_tmp helm.err)"; hrc=$?
    if [ "$hrc" -ne 0 ]; then
        local hwhy
        if [ "$hrc" -eq 124 ] && _past_deadline; then hwhy="run deadline reached: ${RUN_DEADLINE}s"
        elif [ "$hrc" -eq 124 ]; then hwhy="timed out: ${CMD_TIMEOUT}s"
        else hwhy="exit $hrc$(head -n1 "$(_tmp helm.err)" 2>/dev/null | _cutw 160 | sed 's/^/: /')"; fi
        warn "helm: list failed ($hwhy); no releases written"
        printf 'helm list -A failed: %s\n' "$hwhy" > "$dest/releases-failed.txt" 2>/dev/null
        return
    fi
    grep -Ei 'whatap|^NAME' "$(_tmp helm.list)" > "$dest/releases.txt" 2>/dev/null
    local rel relns
    awk 'NR>1 {print $1, $2}' "$dest/releases.txt" 2>/dev/null | head -n 3 > "$(_tmp helm.rels)" 2>/dev/null
    while read -r rel relns; do
        [ -n "$rel" ] || continue
        _bounded helm history "$rel" -n "$relns" "${HOPTS[@]}" > "$dest/history-$rel.txt" 2>/dev/null
        _bounded helm get values "$rel" -n "$relns" "${HOPTS[@]}" > "$dest/values-$rel.yaml" 2>/dev/null
    done < "$(_tmp helm.rels)"
    progress "helm: releases/history/values written"
}

do_bundle() {
    local work tarball
    # the work tree lives in the run's private directory, removed on exit
    if [ -n "$_tmp_dir" ]; then work="$(_tmp bundle)"
    else work="$OPT_OUT/$BASENAME.work"; fi
    mkdir -m 700 "$work" 2>/dev/null || { warn "bundle: cannot create a work directory ($work)"; return 1; }
    run_report > "$work/report.txt" 2>/dev/null
    progress "report: written to bundle"
    if [ "$API_OK" = 1 ]; then
        collect_bundle_cr       "$work/cr"
        collect_bundle_operator "$work/operator"
        collect_bundle_agents   "$work/agents"
        collect_bundle_logs     "$work/logs"
        collect_bundle_cluster  "$work/cluster"
        collect_bundle_apm      "$work/apm-targets"
        write_bundle_caps       "$work/logs"
        collect_bundle_helm     "$work/helm"
    else
        warn "bundle: API artifacts skipped ($API_WHY); the bundle carries the report only"
    fi

    tarball="$OPT_OUT/$BASENAME.tar.gz"
    if have tar; then
        # -C keeps $tarball relative to the caller's CWD (see collserver notes);
        # only remove $work if tar actually wrote the archive.
        if tar -C "$work" -czf "$tarball" . 2>/dev/null && [ -f "$tarball" ]; then
            progress "bundle: $tarball"
            rm -rf "$work" 2>/dev/null
            return 0
        fi
        warn "tar failed — artifacts copied to $OPT_OUT/$BASENAME instead"
    else
        warn "tar: command not found — artifacts copied to $OPT_OUT/$BASENAME instead"
    fi
    # the private directory is removed on exit, so the artifacts are kept by copying
    if cp -R "$work" "$OPT_OUT/$BASENAME" 2>/dev/null; then return 0; fi
    warn "bundle: artifacts could not be copied to $OPT_OUT/$BASENAME"
    return 1
}

# =============================================================================
# main
# =============================================================================
# fd 3 = the terminal, saved before any stdout/stderr redirection so progress()
# still reaches the operator even in --file mode (which redirects both).
exec 3>&2

# No arguments -> print help and stop; a collection needs an explicit action flag.
[ "$ARGC" -eq 0 ] && { usage; exit 0; }

# An action flag is required. Modifiers alone (--namespace/--tail/--quiet/...)
# are not enough — say so and show help rather than silently doing nothing.
if [ "$OPT_BUNDLE" = 0 ] && [ "$OPT_STDOUT" = 0 ] && [ "$OPT_FILE" = 0 ]; then
    warn "no action flag given — need one of --file / --stdout / --bundle"
    usage >&2
    exit 2
fi

_run_init
_init_errfile
have timeout && _timeout_bin="$(command -v timeout)"
mkdir -p "$OPT_OUT" 2>/dev/null

progress "resolving CLI / namespace / whatap workloads ..."
k8s_cli_discover
k8s_api_check
[ "$API_OK" = 1 ] || warn "Kubernetes API not usable — API sections skipped: $API_WHY"
k8s_ns_discover
discover_workloads
discover_apm_selector_values
pick_sample_pods

CTX_NAME="$OPT_CONTEXT"
[ -z "$CTX_NAME" ] && [ -n "$KCTL_BIN" ] && CTX_NAME="$(kval config current-context)"
# An identity only: the context when there is one, else the machine the run came
# from. What could not be resolved is the status section's business.
if [ -n "$CTX_NAME" ]; then TARGET="k8s-cluster/$(printf '%s' "$CTX_NAME" | tr ' ' '_')${NS:+@ns:$NS}"
else TARGET="host/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)${NS:+@ns:$NS}"; fi
if [ -n "$NS" ]; then _nsline="namespace: $NS (via $NS_SRC)"; else _nsline="namespace: $NS_SRC"; fi
progress "cli: ${KCTL_BIN:-none}; context: ${CTX_NAME:-unknown}; $_nsline; node-agent pods: ${#SP_POD[@]}"

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-k8s-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (Tier 0 report + Tier 1 artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle || exit 1
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (Tier 0 report, read-only API GETs)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (Tier 0 report, read-only API GETs) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi

exit 0
