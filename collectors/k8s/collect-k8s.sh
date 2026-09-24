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
# other side. Kubernetes Secret VALUES are still never fetched (`get secret
# -o yaml|json` is not used anywhere); secrets appear only as name/type/key
# tables — that is a data-scope choice, not masking.
#
# NOTE: no `set -e` / no `set -u`. A collector must run to completion and emit
# its footer even when individual steps fail; each step guards itself.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-k8s"
VERSION="0.5.1"
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

Output is verbatim (framework policy: no masking). Kubernetes Secret values
are never fetched; secrets appear only as name/type/key tables.
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
_init_errfile() { _errfile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.err")"; }
_timeout_bin=""
CMD_TIMEOUT=20

_classify_err() {
    # reads a stderr file, prints a short classified reason
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *[Ff]orbidden*|*[Uu]nauthorized*)
            echo "permission denied"; return ;;
        *"doesn't have a resource type"*|*"the server could not find the requested resource"*|*"o matches for kind"*)
            echo "not applicable: resource type not present"; return ;;
        *NotFound*|*"ot found"*)
            echo "not applicable: object not found"; return ;;
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
# CONTRACT rule 1 and belongs in section 0 with the rest of the run's own facts.
#
# Two places, one sentence. Section 0 says which privilege this run had. Every
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

# _note_privilege -> describe this process. Call it once, before section 0 reads
# PRIV_WHY. It yields to a value already set, so a self-elevating collector can
# say something more exact.
_note_privilege() {
    [ "$PRIV_WHY" = unknown ] || return 0
    _priv_uid="$(id -u 2>/dev/null || echo 0)"
    if [ "$_priv_uid" = 0 ]; then
        PRIV_WHY="root${SUDO_UID:+ (elevated by sudo from uid $SUDO_UID)}"
        PRIV_GAP=""
    else
        PRIV_WHY="not root (uid $_priv_uid)"
        PRIV_GAP="run again with sudo"
    fi
}

# ---- boot time — DO NOT EDIT ------------------------------------------------
# Most of what a collector reports is cumulative since boot: /proc/diskstats,
# ZFS kstat trees, zpool iostat histograms, MySQL GLOBAL STATUS. Without the boot
# time those are sums with no denominator and cannot be read as a rate, so the
# reader either asks the site for it afterwards or reconstructs it. Both are work
# the collector could have done, and it belongs in section 0 with the rest of the
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
# _note_boot -> emit the two facts. Call it from section 0, after the privilege
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
# Declare a goal once, then resolve it exactly once. A goal left unresolved
# counts as missed with reason "not reached", which is itself worth seeing: it
# means the run ended before that step.
_goal_keys='' _goal_labels='' _ok_keys='' _na_keys='' _na_reasons='' _gap_keys='' _gap_reasons=''

goal()   { _goal_keys="$_goal_keys$1
"; _goal_labels="$_goal_labels$2
"; }
got()    { _ok_keys="$_ok_keys$1
"; }
na()     { _na_keys="$_na_keys$1
"; _na_reasons="$_na_reasons$2
"; }
missed() { _gap_keys="$_gap_keys$1
"; _gap_reasons="$_gap_reasons$2
"; }

# _label_of KEY -> the label declared for KEY (falls back to the key itself)
_label_of() {
    local i=1 k
    while IFS= read -r k; do
        [ "$k" = "$1" ] && { printf '%s' "$(printf '%s' "$_goal_labels" | sed -n "${i}p")"; return; }
        i=$((i + 1))
    done <<EOF
$_goal_keys
EOF
    printf '%s' "$1"
}

# _reason_in LIST REASONS KEY -> the reason recorded for KEY in that pair, or empty
_reason_in() {
    local i=1 k
    while IFS= read -r k; do
        [ "$k" = "$3" ] && { printf '%s' "$(printf '%s' "$2" | sed -n "${i}p")"; return; }
        i=$((i + 1))
    done <<EOF
$1
EOF
}

# notice: like progress, but NOT silenced by --quiet. Reserved for the
# completeness roll-up. --quiet exists to keep run narration out of automation
# logs; the one line that decides whether a run is worth sending is not
# narration, and an automated caller wants it most of all.
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null; }

# emit_status -> the roll-up section. Call it immediately before emit_footer.
# Also repeats each gap on fd 3 so the operator sees it while still logged in.
emit_status() {
    [ -n "$_goal_keys" ] || return 0
    local k total=0 obtained=0 nacount=0 gaps='' nas='' oks=''
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        total=$((total + 1))
        if printf '%s' "$_ok_keys" | grep -qxF "$k"; then
            obtained=$((obtained + 1)); oks="$oks $(_label_of "$k"),"
        elif printf '%s' "$_na_keys" | grep -qxF "$k"; then
            nacount=$((nacount + 1))
            nas="$nas$(_label_of "$k") — $(_reason_in "$_na_keys" "$_na_reasons" "$k")
"
        else
            local r; r="$(_reason_in "$_gap_keys" "$_gap_reasons" "$k")"; [ -n "$r" ] || r='not reached'
            gaps="$gaps$(_label_of "$k") — $r
"
        fi
    done <<EOF
$_goal_keys
EOF
    local blocked=$((total - obtained - nacount))
    # Most collectors' `section` takes (TITLE) and numbers it automatically. A
    # few take (LETTER, TITLE) because their sections are lettered by hand; those
    # set STATUS_LABEL to the letter they want this roll-up to carry.
    if [ -n "${STATUS_LABEL:-}" ]; then section "$STATUS_LABEL" "Collection status"
    else section "Collection status"; fi
    fact "goals: $total declared, $obtained obtained, $nacount not applicable here, $blocked blocked"
    [ -n "$oks" ] && fact "obtained:${oks%,}"
    if [ -n "$nas" ]; then
        fact "not applicable to this host (this is an answer, not a gap):"
        printf '%s' "$nas" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
    fi
    if [ "$blocked" -eq 0 ]; then
        fact "status: COMPLETE"
        notice "status: COMPLETE — nothing was blocked${nas:+ ($nacount not applicable to this host)}"
    else
        fact "blocked (running this differently would obtain these):"
        printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
        fact "status: INCOMPLETE"
        notice "status: INCOMPLETE — $blocked of $total goals blocked"
        printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && notice "  $l"; done
    fi
}

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
        _emit_labeled "$label / repeated env names (Kubernetes applies the first occurrence)" "$dups"
    else
        fact "$label / repeated env names: none"
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

warn() { printf '%s\n' "$*" >&2; }

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

# run_k ARGS... -> low-level CLI call with the double timeout (client-side
# --request-timeout + external `timeout`, because `timeout` cannot wrap a shell
# function). Sets K_OUT / K_RC; stderr lands in $_errfile for _classify_err.
K_OUT=""; K_RC=1
run_k() {
    K_OUT=""; K_RC=1
    [ -n "$KCTL_BIN" ] || { : > "$_errfile" 2>/dev/null; return 1; }
    if [ -n "$_timeout_bin" ]; then
        K_OUT="$("$_timeout_bin" "$CMD_TIMEOUT" "$KCTL_BIN" "${KOPTS[@]}" "$@" 2>"$_errfile")"; K_RC=$?
    else
        K_OUT="$("$KCTL_BIN" "${KOPTS[@]}" "$@" 2>"$_errfile")"; K_RC=$?
    fi
    return "$K_RC"
}

_k_reason() {
    # prints the n/a reason for the last run_k (assumes K_RC != 0 or empty K_OUT)
    if [ -z "$KCTL_BIN" ]; then echo "command not found: kubectl/oc"; return; fi
    if [ "$K_RC" -eq 124 ] && [ -n "$_timeout_bin" ]; then echo "timed out: ${CMD_TIMEOUT}s"; return; fi
    if [ "$K_RC" -ne 0 ]; then _classify_err; return; fi
    echo "empty output"
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
kval() { run_k "$@" || return 1; printf '%s\n' "$K_OUT"; }

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

# ---- discovery (run once, before the report) ---------------------------------
NS=""; NS_SRC=""; NS_ALL=""
k8s_ns_discover() {
    if [ -n "$OPT_NS" ]; then NS="$OPT_NS"; NS_SRC="option --namespace"; return; fi
    [ -n "$KCTL_BIN" ] || { NS_SRC="n/a (command not found: kubectl/oc)"; return; }
    local out
    # 1) server-side label select on the two known whatap labels
    out="$(kval get pods -A -l name=whatap-node-agent -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u | grep -v '^$')"
    if [ -n "$out" ]; then
        NS="$(printf '%s\n' "$out" | head -n1)"; NS_ALL="$out"; NS_SRC="pods labeled name=whatap-node-agent"; return
    fi
    out="$(kval get pods -A -l app.kubernetes.io/name=whatap-operator -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u | grep -v '^$')"
    if [ -n "$out" ]; then
        NS="$(printf '%s\n' "$out" | head -n1)"; NS_ALL="$out"; NS_SRC="pods labeled app.kubernetes.io/name=whatap-operator"; return
    fi
    # 2) last resort: one cluster-wide pod scan by name prefix
    out="$(kval get pods -A --no-headers | awk '$2 ~ /^whatap-/ {print $1}' | sort -u)"
    if [ -n "$out" ]; then
        NS="$(printf '%s\n' "$out" | head -n1)"; NS_ALL="$out"; NS_SRC="pod name scan (whatap-*)"; return
    fi
    NS_SRC="n/a (no whatap workloads discovered)"
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
HELM_SECRETS=""      # sh.helm.release.v1.* secret names mentioning whatap

discover_workloads() {
    [ -n "$KCTL_BIN" ] || return
    local out line
    # CRDs
    out="$(kval get crd 2>/dev/null | grep -Ei 'whatap|^NAME')"
    CRD_TABLE="$(printf '%s\n' "$out" | grep -Eiv '^NAME')"
    WA_CRD="$(printf '%s\n' "$CRD_TABLE" | awk '$1 ~ /^whatapagents\./ {print $1; exit}')"
    if [ -n "$WA_CRD" ]; then
        WA_SCOPE="$(kval get crd "$WA_CRD" -o 'jsonpath={.spec.scope}')"
        if [ "$WA_SCOPE" = "Namespaced" ]; then
            out="$(kval get "$WA_CRD" -A -o 'jsonpath={range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')"
        else
            out="$(kval get "$WA_CRD" -o 'jsonpath={range .items[*]}{" "}{.metadata.name}{"\n"}{end}')"
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
        DS_NAME="$(kval get ds -n "$NS" -o name | grep -Ei 'whatap' | head -n1)"
        DS_NAME="${DS_NAME##*/}"
        if [ -n "$DS_NAME" ]; then
            DS_CONTAINERS="$(kval get ds "$DS_NAME" -n "$NS" -o 'jsonpath={range .spec.template.spec.containers[*]}{.name}{" "}{end}')"
        fi
        OP_DEPLOY="$(kval get deploy -n "$NS" -o name | grep -Ei 'whatap-operator' | head -n1)"
        OP_DEPLOY="${OP_DEPLOY##*/}"
        WHATAP_DEPLOYS="$(kval get deploy -n "$NS" 2>/dev/null | grep -Ei 'whatap|^NAME')"
        HELM_SECRETS="$(kval get secrets -n "$NS" -o name | grep -E 'sh\.helm\.release\.v1\..*whatap' | sed 's#^secret/##')"
    fi
    WEBHOOKS="$(kval get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name | grep -Ei 'whatap')"
    # per-hook names: the API server keys its admission metrics by these, not by the
    # configuration object name, so they have to be resolved to read the counters
    local wh
    for wh in $WEBHOOKS; do
        WEBHOOK_HOOKS="$WEBHOOK_HOOKS $(kval get "$wh" -o 'jsonpath={range .webhooks[*]}{.name}{" "}{end}')"
    done
    WHATAP_CROLES="$(kval get clusterroles -o name | grep -Ei 'whatap' | sed 's#^clusterrole\.rbac\.authorization\.k8s\.io/##' | head -n 5)"
    ALL_HOOKS="$(kval get mutatingwebhookconfigurations,validatingwebhookconfigurations \
        -o 'jsonpath={range .items[*]}{.metadata.name}{"\t"}{range .webhooks[*]}{.name}{","}{end}{"\n"}{end}' | grep -v '^$' | head -n 60)"
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
    exprs="$(kval get "$WA_CRD" -o 'jsonpath={range .items[*]}{range .spec.features.apm.instrumentation.targets[*]}{range .podSelector.matchExpressions[*]}{range .values[*]}{.}{"\n"}{end}{end}{end}{end}')"
    # matchLabels is a map; jsonpath cannot range over it, so the JSON object is
    # emitted and its values are taken from the "key":"value" pairs
    labels="$(kval get "$WA_CRD" -o 'jsonpath={range .items[*]}{range .spec.features.apm.instrumentation.targets[*]}{.podSelector.matchLabels}{"\n"}{end}{end}' \
        | tr ',' '\n' | sed -n 's/.*":"\([^"]*\)".*/\1/p')"
    APM_SEL_VALS="$(printf '%s\n%s\n' "$exprs" "$labels" | grep -v '^$' | sort -u)"
}

# sample node-agent pods: SP_POD/SP_PHASE/SP_RST parallel arrays sorted by
# total restart count (descending), built bash-3.2 style (no mapfile).
SP_POD=(); SP_PHASE=(); SP_RST=()
pick_sample_pods() {
    [ -n "$KCTL_BIN" ] && [ -n "$NS" ] || return
    local raw sorted line
    raw="$(kval get pods -n "$NS" -l name=whatap-node-agent -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}')"
    if [ -z "$raw" ] && [ -n "$DS_NAME" ]; then
        raw="$(kval get pods -n "$NS" -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{range .status.containerStatuses[*]}{.restartCount}{","}{end}{"\n"}{end}' | grep "^$DS_NAME-")"
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
    fact "run host: $(hostname 2>/dev/null || echo unknown) (bastion/workstation — not a cluster node)"
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
    fact "namespace: ${NS:-n/a} (via $NS_SRC)"
    if [ -n "$NS_ALL" ] && [ "$(printf '%s\n' "$NS_ALL" | wc -l | tr -d ' ')" -gt 1 ]; then
        fact "note: whatap workloads seen in multiple namespaces; this run covers '$NS':"
        printf '%s\n' "$NS_ALL" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    fi
    fact "note: every 'n/a (...)' below names why a value was not obtained"

    # -- A. Cluster & API server ----------------------------------------------
    section "A. Cluster & API server"
    kprobe "kubectl version (client+server)" version
    local ready
    if run_k get --raw /readyz && [ -n "$K_OUT" ]; then fact "apiserver /readyz: $K_OUT"
    elif run_k get --raw /healthz && [ -n "$K_OUT" ]; then fact "apiserver /healthz: $K_OUT"
    else fact "apiserver readiness endpoints: n/a ($(_k_reason))"; fi
    if run_k get nodes --no-headers; then fact "node count: $(printf '%s\n' "$K_OUT" | grep -c .)"
    else fact "node count: n/a ($(_k_reason))"; fi
    if run_k get ns --no-headers; then fact "namespace count: $(printf '%s\n' "$K_OUT" | grep -c .)"
    else fact "namespace count: n/a ($(_k_reason))"; fi
    subsection "platform markers (verbatim; reader interprets)"
    kprobe "first node providerID" get nodes -o 'jsonpath={.items[0].spec.providerID}'
    local nlabels
    nlabels="$(kval get nodes -o 'jsonpath={.items[0].metadata.labels}' | tr ' ,' '\n\n' | grep -Ei 'eks|gke|aks|azure|cce|openshift|cloud\.google|paas' | head -n 15)"
    if [ -n "$nlabels" ]; then _emit_labeled "first node platform-ish labels" "$nlabels"
    else fact "first node platform-ish labels: none matched (eks/gke/aks/azure/cce/openshift/paas)"; fi
    local osgroups
    osgroups="$(kval api-versions | grep -ci openshift)"
    if [ "${osgroups:-0}" -gt 0 ] 2>/dev/null; then
        fact "openshift api groups: $osgroups"
        kprobe "clusterversion" get clusterversion
        kfilter "scc (whatap-filtered)" 'whatap|^NAME' get scc
    else
        fact "openshift api groups: 0 (clusterversion/scc probes not applicable)"
    fi

    # -- B. Nodes ---------------------------------------------------------------
    section "B. Nodes"
    local ntable ncount
    ntable="$(kval get nodes -o custom-columns=NAME:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,ARCH:.status.nodeInfo.architecture)"
    if [ -n "$ntable" ]; then
        ncount="$(printf '%s\n' "$ntable" | grep -c . )"; ncount=$((ncount - 1))
        _emit_labeled "nodes (first 50)" "$(printf '%s\n' "$ntable" | head -n 51)"
        [ "$ncount" -gt 50 ] && fact "total nodes: $ncount (table above capped at 50)"
        _emit_labeled "distinct container runtimes" "$(printf '%s\n' "$ntable" | awk 'NR>1{print $(NF-1)}' | sort | uniq -c | sed 's/^ *//')"
    else
        fact "node table: n/a ($(_k_reason))"
    fi
    if run_k get nodes --no-headers; then
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
    else fact "whatap crds: none found (no crd names matching 'whatap', or crd list not permitted)"; fi
    fact "install generation markers: crd=$( [ -n "$WA_CRD" ] && echo "present ($WA_CRD)" || echo absent ) ds-containers=${DS_CONTAINERS:-n/a} helm-release-secrets=$( [ -n "$HELM_SECRETS" ] && printf '%s' "$HELM_SECRETS" | tr '\n' ',' || echo none-seen )"
    if [ -n "$WA_CRD" ]; then
        fact "crd scope: ${WA_SCOPE:-n/a}"
        kprobe "crd stored/served versions" get crd "$WA_CRD" -o 'jsonpath={range .spec.versions[*]}{.name}{" served="}{.served}{" storage="}{.storage}{"\n"}{end}'
        if [ "${#CR_NAMES[@]}" -eq 0 ]; then
            fact "whatapagent instances: none found"
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
            kprobe "nodeAgent.envs (pod-level) names" get "$WA_CRD" "$cr" $crref -o 'jsonpath={.spec.features.k8sAgent.nodeAgent.envs[*].name}'
            # shellcheck disable=SC2086
            kprobe "nodeAgentContainer.envs names" get "$WA_CRD" "$cr" $crref -o 'jsonpath={.spec.features.k8sAgent.nodeAgent.nodeAgentContainer.envs[*].name}'
            # shellcheck disable=SC2086
            kprobe "nodeHelperContainer.envs names" get "$WA_CRD" "$cr" $crref -o 'jsonpath={.spec.features.k8sAgent.nodeAgent.nodeHelperContainer.envs[*].name}'
            # master switches above the per-target level: with apm.instrumentation.enabled
            # false, or no targets at all, the pod-mutating path returns before any target
            # is evaluated (whatapagent_webhook.go)
            # shellcheck disable=SC2086
            # when each writer last touched the CR — settles "was the apm block present
            # when that pod was created", which generation alone cannot answer
            # shellcheck disable=SC2086
            kprobe "cr write history (managedFields: manager / operation / time)" get "$WA_CRD" "$cr" $crref -o 'jsonpath={range .metadata.managedFields[*]}{.manager}{" op="}{.operation}{" subresource="}{.subresource}{" time="}{.time}{"\n"}{end}'
            # shellcheck disable=SC2086
            kprobe "cr identity + master switches" get "$WA_CRD" "$cr" $crref -o 'jsonpath={"apiVersion="}{.apiVersion}{" name="}{.metadata.name}{" k8sAgent.namespace="}{.spec.features.k8sAgent.namespace}{" k8sAgent.enabled="}{.spec.features.k8sAgent.enabled}{" apm.instrumentation.enabled="}{.spec.features.apm.instrumentation.enabled}{" targets="}{.spec.features.apm.instrumentation.targets[*].name}'
            # shellcheck disable=SC2086
            kprobe "apm instrumentation targets" get "$WA_CRD" "$cr" $crref -o 'jsonpath={range .spec.features.apm.instrumentation.targets[*]}{"name="}{.name}{" lang="}{.language}{" enabled="}{.enabled}{" versions="}{.whatapApmVersions}{" mode="}{.config.mode}{" configMapRef="}{.config.configMapRef.name}{" nsSelector="}{.namespaceSelector}{" podSelector="}{.podSelector}{"\n"}{end}'
            # the init image the operator will pull for each target: an explicit
            # customImageFullName overrides the default public.ecr.aws/whatap/apm-init-<lang>:<version>
            # shellcheck disable=SC2086
            kprobe "apm target init image overrides + extra envs" get "$WA_CRD" "$cr" $crref -o 'jsonpath={range .spec.features.apm.instrumentation.targets[*]}{"name="}{.name}{" customImageFullName="}{.customImageFullName}{" customImageName="}{.customImageName}{" imagePullSecrets="}{.imagePullSecrets[*].name}{" envs="}{range .envs[*]}{.name}{"="}{.value}{";"}{end}{"\n"}{end}'
            i=$((i + 1))
        done
    else
        fact "whatapagent cr probes: n/a (not applicable: whatapagents crd not present)"
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
        fact "operator deployment: none found in ${NS:-<no namespace>}"
    fi
    subsection "admission webhooks"
    if [ -n "$WEBHOOKS" ]; then
        local wh whsvc svcns svcname
        for wh in $WEBHOOKS; do
            # compact applicability line first (the full yaml below carries everything,
            # but these four fields decide whether a given pod is even sent to the webhook)
            kprobe "webhook $wh (per-hook: name / path / rules / policies / selectors)" get "$wh" \
                -o 'jsonpath={range .webhooks[*]}{.name}{" path="}{.clientConfig.service.path}{" url="}{.clientConfig.url}{" ops="}{.rules[*].operations}{" resources="}{.rules[*].resources}{" failurePolicy="}{.failurePolicy}{" matchPolicy="}{.matchPolicy}{" reinvocationPolicy="}{.reinvocationPolicy}{" nsSelector="}{.namespaceSelector}{" objectSelector="}{.objectSelector}{"\n"}{end}'
            # an empty caBundle means the API server has nothing to trust the backend
            # with; the value itself is a long base64 blob, so its size is what is stated
            local cab
            cab="$(kval get "$wh" -o 'jsonpath={range .webhooks[*]}{.name}{"="}{.clientConfig.caBundle}{"\n"}{end}' | awk -F'=' '{printf "%s caBundle=%d bytes\n", $1, length($2)}')"
            if [ -n "$cab" ]; then _emit_labeled "webhook $wh caBundle size per hook" "$cab"
            else fact "webhook $wh caBundle size: n/a (empty output)"; fi
            kprobe "webhook $wh (yaml)" get "$wh" -o yaml
            # the webhook backend: a Service with no ready endpoint cannot mutate anything
            whsvc="$(kval get "$wh" -o 'jsonpath={range .webhooks[*]}{.clientConfig.service.namespace}{"/"}{.clientConfig.service.name}{"\n"}{end}' | sort -u | grep -v '^/*$')"
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
                    eaddr="$(kval get endpoints "$svcname" -n "$svcns" -o 'jsonpath={range .subsets[*]}{range .addresses[*]}{.ip}{":"}{end}{"\n"}{end}' | tr ':' '\n' | grep -v '^$')"
                    ecount="$(printf '%s\n' "$eaddr" | grep -c . )"
                    if [ -n "$eaddr" ]; then _emit_labeled "ready backend addresses: $ecount" "$eaddr"
                    else fact "ready backend addresses: 0 (no ready endpoint — every call to this webhook fails)"; fi
                done
            else
                fact "webhook $wh backend service: n/a (no clientConfig.service — url-based or empty)"
            fi
        done
    else
        fact "whatap mutating/validating webhooks: none found"
    fi

    subsection "every admission webhook in the cluster (config -> hook names)"
    # Not whatap-filtered on purpose: a third-party mutating webhook that runs on the same
    # pods is part of the injection path (it can inject a conflicting env earlier in the
    # list), and a hook NAME reused by another configuration shares whatap's metric series.
    if [ -n "$ALL_HOOKS" ]; then _emit_labeled "webhook configurations (name -> hooks)" "$ALL_HOOKS"
    else fact "webhook configurations: n/a ($(_k_reason))"; fi

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
            cab1="$(kval get "$wh2" -o 'jsonpath={range .webhooks[*]}{.name}{"\t"}{.clientConfig.caBundle}{"\n"}{end}')"
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
        certsec="$(kval get secrets -n "$NS" -o name | sed 's#^secret/##' | grep -Ei 'webhook.*cert|cert.*webhook' | head -n1)"
        if [ -n "$certsec" ]; then
            secfp="$(kval get secret "$certsec" -n "$NS" -o 'jsonpath={.data.cert\.pem}' \
                | base64 -d 2>/dev/null \
                | openssl x509 -noout -sha256 -fingerprint -subject 2>/dev/null | tr '\n' ' ')"
            if [ -n "$secfp" ]; then fact "secret $certsec cert.pem (public CA field only): $secfp"
            else fact "secret $certsec cert.pem: n/a (field absent or not parseable as a certificate)"; fi
        else
            fact "webhook certificate secret: none found in $NS matching webhook*cert (the operator may be keeping the CA only in its emptyDir)"
        fi
    fi
    # When each side was produced: an operator process that started AFTER the caBundle was
    # last written is serving a CA the configuration does not carry.
    if [ -n "$OP_DEPLOY" ]; then
        kprobe "operator pod process start / restarts (a restart regenerates the CA)" get pods -n "$NS" \
            -l app.kubernetes.io/name=whatap-operator \
            -o 'jsonpath={range .items[*]}{.metadata.name}{" podStart="}{.status.startTime}{" containerStarted="}{range .status.containerStatuses[*]}{.state.running.startedAt}{" restarts="}{.restartCount}{end}{"\n"}{end}'
    fi
    local wh3
    for wh3 in $WEBHOOKS; do
        kprobe "$wh3 last written (managedFields times — when the caBundle was last set)" get "$wh3" \
            -o 'jsonpath={range .metadata.managedFields[*]}{.manager}{" op="}{.operation}{" time="}{.time}{"\n"}{end}'
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
    fact "counter meanings: request_total = calls made (per HTTP code) / fail_open_count = calls admitted WITHOUT the webhook after a failed call / admission_duration_seconds_count = calls attempted"
    if [ -n "$WEBHOOK_HOOKS" ]; then
        fact "whatap hook names (metric label 'name'): $(printf '%s' "$WEBHOOK_HOOKS" | tr -s ' ' | sed 's/^ //; s/ $//')"
        if run_k get --raw /metrics; then
            local mpat mrows mfo
            fact "/metrics payload: ${#K_OUT} bytes (single read, bounded by the per-call timeout)"
            mpat="$(printf '%s\n' $WEBHOOK_HOOKS | grep -v '^$' | sed 's/\./\\./g' | awk '{printf "%s%s", (NR>1 ? "|" : ""), $0}')"
            mrows="$(printf '%s\n' "$K_OUT" | grep -E '^apiserver_admission_webhook_(request_total|fail_open_count|admission_duration_seconds_count)' | grep -E "name=\"($mpat)\"")"
            if [ -n "$mrows" ]; then _emit_labeled "whatap hook counters" "$mrows"
            else fact "whatap hook counters: no metric series carries these hook names (the API server has not recorded a call for them)"; fi
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
                    fact "hook names carried by more than one webhook configuration: none — each counter series above belongs to one configuration"
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
        [ -n "$DS_NAME" ] && dssa="$(kval get ds "$DS_NAME" -n "$NS" -o 'jsonpath={.spec.template.spec.serviceAccountName}')"
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
        fact "node-agent daemonset: none found in ${NS:-<no namespace>}"
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
        fact "node-agent pods: none found (daemonset absent, selector mismatch, or list not permitted)"
    fi
    subsection "other whatap deployments in ${NS:-<no namespace>}"
    if [ -n "$WHATAP_DEPLOYS" ]; then _emit_labeled "deployments" "$WHATAP_DEPLOYS"
    else fact "deployments: n/a (none found or list not permitted)"; fi

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
        [ "${#SP_POD[@]}" -eq 0 ] && fact "node-agent pod logs: n/a (no node-agent pods found)"
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
    local apods ap an=0
    apods="$(kval get pods -n kube-system -l component=kube-apiserver -o name | sed 's#^pod/##')"
    if [ -z "$apods" ]; then
        apods="$(kval get pods -n kube-system --no-headers | awk '$1 ~ /^kube-apiserver-/ {print $1}')"
    fi
    if [ -n "$apods" ]; then
        fact "kube-apiserver pods found: $(printf '%s' "$apods" | tr '\n' ' ')"
        fact "bounds: --tail=2000 per pod, up to 3 pods, then filtered to webhook/whatap lines (cap 80). A failure older than that tail is still counted in the section D counters."
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
        fact "kube-apiserver pods: none found in kube-system (managed control plane, or the API server does not run as a pod) — the control-plane host's own log is then the only source for webhook call failures; the section D counters still apply"
    fi

    # -- H. Helm & deployed image inventory ----------------------------------------
    section "H. Helm & deployed image inventory"
    probe "helm version" helm version --short
    if have helm; then
        local HOPTS=()
        [ -n "$OPT_KUBECONFIG" ] && HOPTS[${#HOPTS[@]}]="--kubeconfig=$OPT_KUBECONFIG"
        [ -n "$OPT_CONTEXT" ] && HOPTS[${#HOPTS[@]}]="--kube-context=$OPT_CONTEXT"
        local hl rel relns
        hl="$("$_timeout_bin" "$CMD_TIMEOUT" helm list -A "${HOPTS[@]}" 2>"$_errfile" | grep -Ei 'whatap|^NAME')"
        if [ -n "$hl" ]; then
            _emit_labeled "helm releases (whatap-filtered)" "$hl"
            printf '%s\n' "$hl" | awk 'NR>1 || $1!="NAME" {print $1, $2}' | grep -vi '^NAME' | head -n 3 | while read -r rel relns; do
                [ -n "$rel" ] || continue
                probe "helm history $rel" helm history "$rel" -n "$relns" "${HOPTS[@]}"
                probe "helm values $rel (user-supplied)" helm get values "$rel" -n "$relns" "${HOPTS[@]}"
            done
        else
            fact "helm releases: n/a (empty output)"
        fi
    else
        fact "helm release facts: degraded to release-secret names (command not found: helm)"
    fi
    if [ -n "$HELM_SECRETS" ]; then _emit_labeled "helm release secrets in ${NS:-?} (name = sh.helm.release.v1.<release>.v<revision>)" "$HELM_SECRETS"
    else fact "helm release secrets: none seen in ${NS:-<no namespace>}"; fi
    subsection "images declared by whatap workloads in ${NS:-<no namespace>}"
    if [ -n "$NS" ]; then
        local imgs
        imgs="$(kval get deploy,ds,sts -n "$NS" -o 'jsonpath={range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' | grep -v '^$' | sort -u)"
        if [ -n "$imgs" ]; then _emit_labeled "images (containers + initContainers)" "$imgs"
        else fact "images: n/a (empty output)"; fi
    else
        fact "image inventory: n/a (not applicable: no whatap namespace discovered)"
    fi
    fact "note: external registry tag listings are out of scope for this collector (clusters are often airgapped); the analyst checks registries separately"

    # -- I. In-pod node facts (kubectl exec, best-effort) ---------------------------
    section "I. In-pod node facts (kubectl exec into node-agent pods)"
    if [ -n "$NS" ] && [ -n "$DS_NAME" ] && [ "${#SP_POD[@]}" -gt 0 ]; then
        # derive exec plan from the DS spec (declared mounts / ports / hostPID)
        local mounts logcont portcont hport hostpid
        mounts="$(kval get ds "$DS_NAME" -n "$NS" -o 'jsonpath={range .spec.template.spec.containers[*]}{.name}{"="}{range .volumeMounts[*]}{.mountPath}{","}{end}{"\n"}{end}')"
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
        ports="$(kval get ds "$DS_NAME" -n "$NS" -o 'jsonpath={range .spec.template.spec.containers[*]}{.name}{"="}{.ports[0].containerPort}{"\n"}{end}')"
        portcont="$(printf '%s\n' "$ports" | awk -F'=' '$2 != "" {print $1; exit}')"
        hport="$(printf '%s\n' "$ports" | awk -F'=' '$2 != "" {print $2; exit}')"
        hostpid="$(kval get ds "$DS_NAME" -n "$NS" -o 'jsonpath={.spec.template.spec.hostPID}')"
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
            progress "[Tier2] --exec-per-node: running read-only commands inside $n node-agent pods"
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
        for pod in $EXEC_PODS; do
            any=1
            subsection "in-pod probes: $pod"
            pod_exec_probe "container log symlink target (first entry found under: $logdirs)" "$pod" "$logcont" \
                "for d in $logdirs; do for f in \"\$d\"/*.log; do [ -L \"\$f\" ] || [ -e \"\$f\" ] || continue; readlink \"\$f\"; break 2; done; done; :"
            pod_exec_probe "container-log roots present (candidates from declared mounts)" "$pod" "$logcont" \
                "ls -d $rootdirs 2>/dev/null; :"
            pod_exec_probe "container runtime sockets visible (candidates from declared mounts)" "$pod" "$logcont" \
                "ls -l $sockdirs 2>/dev/null; :"
            pod_exec_probe "cgroup filesystem type + v2 controllers file" "$pod" "$logcont" \
                'stat -fc %T /sys/fs/cgroup 2>/dev/null; ls /sys/fs/cgroup/cgroup.controllers 2>/dev/null; :'
            if [ -n "$hport" ] && [ -n "$portcont" ]; then
                pod_exec_probe "helper endpoint http://127.0.0.1:$hport/health" "$pod" "$logcont" \
                    "wget -qO- -T 5 http://127.0.0.1:$hport/health 2>/dev/null || curl -sf -m 5 http://127.0.0.1:$hport/health"
            else
                fact "helper endpoint probe: n/a (not applicable: no containerPort declared in daemonset)"
            fi
            if [ "$hostpid" = "true" ]; then
                pod_exec_probe "kubelet cmdline (via hostPID /proc)" "$pod" "$logcont" \
                    'for d in /proc/[0-9]*; do case "$(cat "$d/comm" 2>/dev/null)" in kubelet) tr "\0" " " < "$d/cmdline"; echo; break;; esac; done'
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
    fact "webhook scope: whatap admission acts on pods at CREATE (see the webhook rules in section D) — a pod created before the operator/CR existed carries no injection until it is recreated"
    fact "states reported: declared (workload template) / admitted (pod spec) / running (--apm-exec only)"

    # ---- name mapping: the identifiers that have to line up before anything is injected --
    # Every one of these is a name or label the operator matches by string. They are
    # collected together, verbatim, so each side of every match can be read off one page.
    subsection "name mapping inputs (CR name, selectors, labels)"
    fact "operator reference (whatap-operator internal/webhook/v2alpha1/whatapagent_webhook.go): the pod-mutating path resolves ONE cluster-scoped WhatapAgent by the fixed name 'whatap'; a CR under any other name is not read by that path. The CR names present in this cluster are listed below."
    if [ -n "$WA_CRD" ]; then
        kprobe "whatapagent CR names present (cluster)" get "$WA_CRD" -o 'jsonpath={range .items[*]}{.metadata.name}{" apiVersion="}{.apiVersion}{" created="}{.metadata.creationTimestamp}{"\n"}{end}'
        if run_k get "$WA_CRD" -o 'jsonpath={.items[*].metadata.name}'; then
            case " $K_OUT " in
                *" whatap "*) fact "a whatapagent named 'whatap' is present: yes" ;;
                *) fact "a whatapagent named 'whatap' is present: no (names found: ${K_OUT:-none})" ;;
            esac
        else
            fact "a whatapagent named 'whatap' is present: n/a ($(_k_reason))"
        fi
        # how many targets exist at all, stated separately so "no targets declared" is
        # never confused with "the selector probe returned nothing"
        local tgtnames
        tgtnames="$(kval get "$WA_CRD" -o 'jsonpath={range .items[*]}{.metadata.name}{"="}{range .spec.features.apm.instrumentation.targets[*]}{.name}{","}{end}{"\n"}{end}')"
        if [ -n "$tgtnames" ]; then _emit_labeled "apm instrumentation targets declared per cr (cr=target,target,...; empty after '=' means none declared)" "$tgtnames"
        else fact "apm instrumentation targets declared per cr: n/a ($(_k_reason))"; fi
        # per-target selectors, one line per target, in the shape they are matched in:
        # namespaceSelector by name OR by namespace label; podSelector by pod label
        kprobe "target selectors (matched against namespace names/labels and pod labels)" get "$WA_CRD" -o 'jsonpath={range .items[*]}{"cr="}{.metadata.name}{"\n"}{range .spec.features.apm.instrumentation.targets[*]}{"  target="}{.name}{" enabled="}{.enabled}{" lang="}{.language}{"\n"}{"    namespaceSelector.matchNames="}{.namespaceSelector.matchNames}{"\n"}{"    namespaceSelector.matchLabels="}{.namespaceSelector.matchLabels}{"\n"}{"    namespaceSelector.matchExpressions="}{.namespaceSelector.matchExpressions}{"\n"}{"    podSelector.matchLabels="}{.podSelector.matchLabels}{"\n"}{"    podSelector.matchExpressions="}{.podSelector.matchExpressions}{"\n"}{end}{end}'
    else
        fact "whatapagent CR name mapping: n/a (not applicable: whatapagents crd not present)"
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
        fact "per-target inspection: n/a (not requested — pass --apm-target NS[/NAME] for workload/pod/env/log facts)"
        [ "$OPT_APM_EXEC" = 1 ] && fact "in-container probes: n/a (--apm-exec given with no --apm-target: nothing to exec into)"
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
                progress "[Tier2] --apm-exec: running read-only commands inside application containers in $tns"
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
                fact "in-container probes: n/a (not requested — pass --apm-exec for running-state facts)"
            fi
            ti=$((ti + 1))
        done
        [ "${#APM_TGTS[@]}" -gt 5 ] && fact "targets capped: first 5 of ${#APM_TGTS[@]} processed"
    fi

    if [ -n "$KCTL_BIN" ] && run_k version --request-timeout=5s >/dev/null 2>&1; then got api
    elif [ -z "$KCTL_BIN" ]; then missed api "command not found: kubectl (and no oc)"
    else missed api "kubectl found but the API did not answer (see section A for the reason)"; fi
    if [ "${#CR_NAMES[@]}" -gt 0 ]; then got cr
    else na cr "no WhatapAgent CR exists in any namespace"; fi

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

collect_bundle_logs() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$NS" ] || return
    local podconts line pod conts cont
    podconts="$(kval get pods -n "$NS" -o 'jsonpath={range .items[*]}{.metadata.name}{"="}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}')"
    for line in $podconts; do
        pod="${line%%=*}"; conts="$(printf '%s' "${line#*=}" | tr ',' ' ')"
        for cont in $conts; do
            [ -n "$cont" ] || continue
            if run_k logs -n "$NS" "$pod" -c "$cont" --tail=2000 --limit-bytes=5000000 && [ -n "$K_OUT" ]; then
                printf '%s\n' "$K_OUT" > "$dest/${pod}_${cont}.log" 2>/dev/null
            fi
            if run_k logs -n "$NS" "$pod" -c "$cont" --tail=2000 --limit-bytes=5000000 --previous && [ -n "$K_OUT" ]; then
                printf '%s\n' "$K_OUT" > "$dest/${pod}_${cont}.previous.log" 2>/dev/null
            fi
        done
    done
    progress "logs: per-container files written (tail 2000 / 5MB caps)"
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
                if run_k logs -n "$tns" "$tp" -c "$cont" --limit-bytes=2000000 && [ -n "$K_OUT" ]; then
                    printf '%s\n' "$K_OUT" > "$dest/$tns/${tp}_${cont}.log" 2>/dev/null
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
    helm list -A "${HOPTS[@]}" 2>/dev/null | grep -Ei 'whatap|^NAME' > "$dest/releases.txt" 2>/dev/null
    awk 'NR>1 {print $1, $2}' "$dest/releases.txt" 2>/dev/null | head -n 3 | while read -r rel relns; do
        [ -n "$rel" ] || continue
        helm history "$rel" -n "$relns" "${HOPTS[@]}" > "$dest/history-$rel.txt" 2>/dev/null
        helm get values "$rel" -n "$relns" "${HOPTS[@]}" 2>/dev/null > "$dest/values-$rel.yaml" 2>/dev/null
    done
    progress "helm: releases/history/values written"
}

do_bundle() {
    local work tarball
    work="$(mktemp -d 2>/dev/null || echo "$OPT_OUT/$BASENAME.tmp.$$")"
    mkdir -p "$work" 2>/dev/null
    run_report > "$work/report.txt" 2>/dev/null
    progress "report: written to bundle"
    collect_bundle_cr       "$work/cr"
    collect_bundle_operator "$work/operator"
    collect_bundle_agents   "$work/agents"
    collect_bundle_logs     "$work/logs"
    collect_bundle_cluster  "$work/cluster"
    collect_bundle_apm      "$work/apm-targets"
    collect_bundle_helm     "$work/helm"

    tarball="$OPT_OUT/$BASENAME.tar.gz"
    if have tar; then
        # -C keeps $tarball relative to the caller's CWD (see collserver notes);
        # only remove $work if tar actually wrote the archive.
        if tar -C "$work" -czf "$tarball" . 2>/dev/null && [ -f "$tarball" ]; then
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

# An action flag is required. Modifiers alone (--namespace/--tail/--quiet/...)
# are not enough — say so and show help rather than silently doing nothing.
if [ "$OPT_BUNDLE" = 0 ] && [ "$OPT_STDOUT" = 0 ] && [ "$OPT_FILE" = 0 ]; then
    warn "no action flag given — need one of --file / --stdout / --bundle"
    usage >&2
    exit 2
fi

_init_errfile
have timeout && _timeout_bin="$(command -v timeout)"
mkdir -p "$OPT_OUT" 2>/dev/null

progress "resolving CLI / namespace / whatap workloads ..."
k8s_cli_discover
k8s_ns_discover
discover_workloads
discover_apm_selector_values
pick_sample_pods

CTX_NAME="$OPT_CONTEXT"
[ -z "$CTX_NAME" ] && [ -n "$KCTL_BIN" ] && CTX_NAME="$(kval config current-context)"
TARGET="k8s-cluster/${CTX_NAME:-unknown}@ns:${NS:-unresolved}"
progress "cli: ${KCTL_BIN:-none}; context: ${CTX_NAME:-unknown}; namespace: ${NS:-unresolved} (via $NS_SRC); node-agent pods: ${#SP_POD[@]}"

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-k8s-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (Tier 0 report + Tier 1 artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (Tier 0 report, read-only API GETs)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (Tier 0 report, read-only API GETs) -> writing $OUTFILE"
    run_report > "$OUTFILE" 2>/dev/null
    progress "report written: $OUTFILE"
fi

[ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null
exit 0
