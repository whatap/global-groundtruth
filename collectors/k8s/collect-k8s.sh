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
#   * MECE sections     — every fact lives in exactly one domain (A..I below):
#                         declared state in C/D/E, observed events in F, all
#                         log streams in G, image index in H, in-pod facts in I.
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
# REDACTION: license/access-key/password values and certificate bundles are
# masked (<REDACTED:len=N> / <omitted:len=N>) in the report AND in bundle
# artifacts. Secret VALUES are never fetched (`get secret -o yaml|json` is not
# used anywhere); secrets appear only as name/type/key tables.
#
# NOTE: no `set -e` / no `set -u`. A collector must run to completion and emit
# its footer even when individual steps fail; each step guards itself.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-k8s"
VERSION="0.1.0"
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
  collect-k8s.sh --apm-target NS[/NAME]   also inspect an application namespace for
                                          whatap auto-instrumentation facts (repeatable,
                                          max 5; reads that namespace's pod specs)

  Tier 2 (opt-in, wider fan-out — announced on stderr before running):
  collect-k8s.sh --exec-per-node          run the in-pod probes on EVERY running
                                          node-agent pod (max 30) instead of 2 samples

License / access-key values and certificate bundles are masked in all output;
secret values are never fetched.
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

# probe_red: like probe but the output passes through redact first.
probe_red() {
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
    if [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ]; then fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; fi
    if [ "$rc" -ne 0 ]; then fact "$label: n/a ($(_classify_err))"; return; fi
    if [ -z "$out" ]; then fact "$label: n/a (empty output)"; return; fi
    _emit_labeled "$label" "$(printf '%s\n' "$out" | redact)"
}

warn() { printf '%s\n' "$*" >&2; }

# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any stdout/stderr redirection). It NEVER lands in the report — stdout stays
# byte-for-byte the report even in --file mode. Silenced by --quiet. Keep the text a
# fact about collection state (no judgment words) so validate.sh keeps passing.
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- redaction ---------------------------------------------------------------
# One portable-awk pass over any text that may carry credentials: CR yaml, DS /
# deployment / webhook yaml, describe output, helm values, log tails, exec
# output, and every bundle artifact. Values are replaced by <REDACTED:len=N>
# (length preserved: "a 38-char license is set" stays a fact). Certificate
# bundles become <omitted:len=N>. secretKeyRef NAMES survive on purpose — the
# reference structure is a fact the reader needs; only literal values die here.
redact() {
    awk '
    function masked(s) { return "<REDACTED:len=" length(s) ">" }
    BEGIN {
        sens = "(licen[cs]e[_.-]?(key)?|access[_-]?key|api[_-]?(key|token)|passwd|password)"
        sep  = "[\"\047]?[[:space:]]*[:=][[:space:]]*"
        pending = 0
    }
    {
        line = $0
        low  = tolower(line)

        # certificate / key-material bulk fields: mask the rest of the line
        if (match(low, /(cabundle|certificate-authority-data|client-certificate-data|client-key-data)[\"\047]?[[:space:]]*:[[:space:]]*/)) {
            p = RSTART + RLENGTH
            v = substr(line, p)
            gsub(/[[:space:]]+$/, "", v)
            if (length(v) > 0) { print substr(line, 1, p - 1) "<omitted:len=" length(v) ">"; next }
        }

        # two-line yaml env form: a sensitive "name:" line arms masking of the
        # "value:" line that follows; "valueFrom:" (secretKeyRef) disarms it so
        # the secret NAME stays visible.
        if (pending > 0) {
            pending--
            if (low ~ /valuefrom[\"\047]?[[:space:]]*:/) pending = 0
            else if (low ~ /(^|[[:space:]])[\"\047]?value[\"\047]?[[:space:]]*:/) {
                i = index(line, ":")
                v = substr(line, i + 1)
                gsub(/^[[:space:]]+/, "", v); gsub(/[\"\047]/, "", v)
                print substr(line, 1, i) " " masked(v)
                pending = 0
                next
            }
        }
        if (low ~ ("name[\"\047]?[[:space:]]*:[[:space:]]*[\"\047]?[a-z0-9_.-]*" sens)) {
            pending = 3
            # same-line JSON env form: {"name":"WHATAP_LICENSE","value":"..."}
            if (match(low, /"value"[[:space:]]*:[[:space:]]*"/)) {
                p = RSTART + RLENGTH
                rest = substr(line, p)
                q = index(rest, "\"")
                if (q > 0) {
                    line = substr(line, 1, p - 1) masked(substr(rest, 1, q - 1)) substr(rest, q)
                    low = tolower(line)
                    pending = 0
                }
            }
        }

        # inline key[:=]value forms (yaml scalars, java properties, shell env,
        # helm values, json fields). Loop-guarded for multiple hits per line.
        out = ""; guard = 0
        while (match(tolower(line), sens sep) && guard < 8) {
            guard++
            p = RSTART + RLENGTH
            head = substr(line, 1, p - 1)
            rest = substr(line, p)
            c = substr(rest, 1, 1)
            if (c == "\"" || c == "\047") {
                q = index(substr(rest, 2), c)
                if (q > 0) { inner = substr(rest, 2, q - 1); tail = substr(rest, q + 2) }
                else       { inner = substr(rest, 2);        tail = "" }
                out = out head c masked(inner) c
            } else {
                t = match(rest, /[[:space:],}]/)
                if (t == 0) { inner = rest; tail = "" }
                else        { inner = substr(rest, 1, t - 1); tail = substr(rest, t) }
                # kubectl describe renders secret references as "<set to the key
                # ... in secret ...>" — structural text, not a value; keep it.
                if (substr(inner, 1, 1) == "<") out = out head inner
                else out = out head masked(inner)
            }
            line = tail
        }
        line = out line
        print line
    }'
}

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

# kprobe_red "label" ARGS... -> same, but output passes through redact
kprobe_red() {
    local label="$1"; shift
    if run_k "$@" && [ -n "$K_OUT" ]; then _emit_labeled "$label" "$(printf '%s\n' "$K_OUT" | redact)"
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

# emit_log_tail POD CONTAINER LINES [previous] -> redacted, bounded log tail
emit_log_tail() {
    local pod="$1" cont="$2" lines="$3" prev="${4:-}"
    local label="logs $pod/$cont"
    [ -n "$prev" ] && label="$label (previous instance)"
    local rc
    if [ -n "$prev" ]; then run_k logs -n "$NS" "$pod" -c "$cont" --tail="$lines" --previous; rc=$?
    else run_k logs -n "$NS" "$pod" -c "$cont" --tail="$lines"; rc=$?; fi
    if [ "$rc" -eq 0 ] && [ -n "$K_OUT" ]; then
        _emit_labeled "$label" "$(printf '%s\n' "$K_OUT" | redact)"
    else
        fact "$label: n/a ($(_k_reason))"
    fi
}

# pod_exec_probe "label" POD CONTAINER CMDSTRING -> redacted output of a
# read-only command run inside an agent pod, or a classified reason.
pod_exec_probe() {
    local label="$1" pod="$2" cont="$3" cmd="$4"
    if run_k exec -n "$NS" "$pod" -c "$cont" -- sh -c "$cmd" && [ -n "$K_OUT" ]; then
        _emit_labeled "$label" "$(printf '%s\n' "$K_OUT" | redact)"
    else
        fact "$label: n/a ($(_k_reason))"
    fi
}

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

    section "Collection environment"
    fact "collector: $COLLECTOR_NAME $VERSION"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root ))"
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
            kprobe_red "cr yaml (redacted)" get "$WA_CRD" "$cr" $crref -o yaml
            # env placement facts: the operator applies container-level envs and
            # pod-level envs through different code paths — surface both verbatim.
            # shellcheck disable=SC2086
            kprobe "nodeAgent.envs (pod-level) names" get "$WA_CRD" "$cr" $crref -o 'jsonpath={.spec.features.k8sAgent.nodeAgent.envs[*].name}'
            # shellcheck disable=SC2086
            kprobe "nodeAgentContainer.envs names" get "$WA_CRD" "$cr" $crref -o 'jsonpath={.spec.features.k8sAgent.nodeAgent.nodeAgentContainer.envs[*].name}'
            # shellcheck disable=SC2086
            kprobe "nodeHelperContainer.envs names" get "$WA_CRD" "$cr" $crref -o 'jsonpath={.spec.features.k8sAgent.nodeAgent.nodeHelperContainer.envs[*].name}'
            # shellcheck disable=SC2086
            kprobe "apm instrumentation targets" get "$WA_CRD" "$cr" $crref -o 'jsonpath={range .spec.features.apm.instrumentation.targets[*]}{"name="}{.name}{" lang="}{.language}{" enabled="}{.enabled}{" versions="}{.whatapApmVersions}{" mode="}{.config.mode}{" configMapRef="}{.config.configMapRef.name}{" nsSelector="}{.namespaceSelector}{" podSelector="}{.podSelector}{"\n"}{end}'
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
        kprobe_red "operator deployment yaml (redacted)" get deploy "$OP_DEPLOY" -n "$NS" -o yaml
        kfilter "operator replicasets (revision/image history)" "whatap-operator|^NAME" get rs -n "$NS" -o custom-columns=NAME:.metadata.name,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,IMAGE:.spec.template.spec.containers[0].image,CREATED:.metadata.creationTimestamp
    else
        fact "operator deployment: none found in ${NS:-<no namespace>}"
    fi
    subsection "admission webhooks"
    if [ -n "$WEBHOOKS" ]; then
        local wh
        for wh in $WEBHOOKS; do
            kprobe_red "webhook $wh (yaml, redacted)" get "$wh" -o yaml
        done
    else
        fact "whatap mutating/validating webhooks: none found"
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
    kfilter "clusterrolebindings (whatap-filtered)" 'whatap|^NAME' get clusterrolebindings

    # -- E. Agent workloads (declared + pod state) -------------------------------
    section "E. Agent workloads"
    if [ -n "$DS_NAME" ]; then
        kprobe "daemonset status" get ds "$DS_NAME" -n "$NS"
        fact "daemonset container names (discovered): ${DS_CONTAINERS:-n/a}"
        kprobe_red "daemonset yaml (redacted)" get ds "$DS_NAME" -n "$NS" -o yaml
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
            kprobe_red "describe pod ${SP_POD[$i]} (redacted)" describe pod "${SP_POD[$i]}" -n "$NS"
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
                _emit_labeled "logs deploy/$OP_DEPLOY" "$(printf '%s\n' "$K_OUT" | redact)"
            else
                fact "logs deploy/$OP_DEPLOY: n/a ($(_k_reason))"
            fi
        fi
        local mdep
        mdep="$(printf '%s\n' "$WHATAP_DEPLOYS" | awk '$1 ~ /master-agent/ {print $1; exit}')"
        if [ -n "$mdep" ]; then
            if run_k logs -n "$NS" "deploy/$mdep" --tail="$OPT_TAIL" && [ -n "$K_OUT" ]; then
                _emit_labeled "logs deploy/$mdep" "$(printf '%s\n' "$K_OUT" | redact)"
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
                probe_red "helm values $rel (user-supplied, redacted)" helm get values "$rel" -n "$relns" "${HOPTS[@]}"
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

    # -- J. APM auto-instrumentation targets (opt-in) --------------------------------
    if [ "${#APM_TGTS[@]}" -gt 0 ]; then
        section "J. APM auto-instrumentation targets (--apm-target)"
        local ti tgt tns twl tpods tp shown
        ti=0
        while [ "$ti" -lt "${#APM_TGTS[@]}" ] && [ "$ti" -lt 5 ]; do
            tgt="${APM_TGTS[$ti]}"
            tns="${tgt%%/*}"
            twl=""; case "$tgt" in */*) twl="${tgt#*/}" ;; esac
            subsection "target: namespace=$tns${twl:+ workload=$twl}"
            kprobe "namespace labels" get ns "$tns" --show-labels
            tpods="$(kval get pods -n "$tns" --no-headers | awk '{print $1}')"
            [ -n "$twl" ] && tpods="$(printf '%s\n' "$tpods" | grep "^$twl" )"
            tpods="$(printf '%s\n' "$tpods" | head -n 3)"
            if [ -z "$tpods" ]; then
                fact "pods: n/a (none found matching${twl:+ prefix $twl in} namespace $tns)"
            fi
            shown=0
            for tp in $tpods; do
                shown=$((shown + 1))
                kprobe "pod $tp initContainers" get pod "$tp" -n "$tns" -o 'jsonpath={range .spec.initContainers[*]}{.name}{" image="}{.image}{"\n"}{end}'
                if run_k get pod "$tp" -n "$tns" -o yaml; then
                    local marks
                    marks="$(printf '%s\n' "$K_OUT" | grep -Ein 'whatap|okind' | head -n 40 | redact)"
                    if [ -n "$marks" ]; then _emit_labeled "pod $tp whatap-marker lines (grep whatap|okind, first 40)" "$marks"
                    else fact "pod $tp whatap-marker lines: none (no line matching whatap/okind in pod yaml)"; fi
                else
                    fact "pod $tp yaml: n/a ($(_k_reason))"
                fi
            done
            [ "$shown" -gt 0 ] && fact "pods inspected: $shown (cap 3 per target)"
            ti=$((ti + 1))
        done
        [ "${#APM_TGTS[@]}" -gt 5 ] && fact "targets capped: first 5 of ${#APM_TGTS[@]} processed"
    fi

    emit_footer
}

# =============================================================================
# Bundle (Tier 1)
# =============================================================================
_bundle_write() {
    # _bundle_write FILE ARGS... -> run_k output (redacted) into FILE; skipped on failure
    local file="$1"; shift
    if run_k "$@" && [ -n "$K_OUT" ]; then
        printf '%s\n' "$K_OUT" | redact > "$file" 2>/dev/null
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
                printf '%s\n' "$K_OUT" | redact > "$dest/${pod}_${cont}.log" 2>/dev/null
            fi
            if run_k logs -n "$NS" "$pod" -c "$cont" --tail=2000 --limit-bytes=5000000 --previous && [ -n "$K_OUT" ]; then
                printf '%s\n' "$K_OUT" | redact > "$dest/${pod}_${cont}.previous.log" 2>/dev/null
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
        helm get values "$rel" -n "$relns" "${HOPTS[@]}" 2>/dev/null | redact > "$dest/values-$rel.yaml" 2>/dev/null
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
