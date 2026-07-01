#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collector skeleton
# -----------------------------------------------------------------------------
# Copy this file to collectors/<domain>/<name>.sh and fill it in. It already
# emits the shared report shape (see ../../docs/output-format.md), so you only
# add fact sections. Then run ../../tools/validate.sh against your copy.
#
# THE CONTRACT (../../CONTRACT.md) — read before editing:
#   1. Facts only. No diagnosis, no likely-cause, no recommendation, no fix.
#      No emitted line may state a conclusion. Report what IS, never what it
#      means — interpretation is the reader's job.
#   2. Discover, never assume. Resolve symlinks / mounts / process args / config
#      instead of hardcoding paths, so a new environment needs no code change.
#      When a value cannot be found, print it as a fact ("n/a"), never a guess.
#   3. One field command -> paste. The engineer runs this once and copies all of
#      the output. Nothing here should ask them to interpret or choose.
#   4. Domain-team owned. This collector belongs to its domain's developers.
#
# DESIGN GUIDELINES (../../docs/collector-engineering.md) — how to make it robust:
#   * MECE sections     — every fact lives in exactly one domain; name them.
#   * Load-safe by tier — the default report runs only read-only, instant
#                         commands (no JVM attach, no recursive du, no whole-log
#                         grep); expensive probes are opt-in and announced.
#   * Portable          — read /proc & /sys first, fall back through command
#                         chains, target bash 3.2+, assume nothing about the OS.
#   * Reasoned absence  — a value you cannot get is a fact WITH a reason: use the
#                         probe/read_proc/dump_file helpers below.
#
# NOTE: this script deliberately does NOT use `set -e`. A collector must always
# run to completion and emit its footer, even when individual discovery steps
# fail. Handle failure locally (the helpers do this) instead of aborting.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata — EDIT THESE ----------------------------------------
COLLECTOR_NAME="example-skeleton"      # e.g. whatap-k8s-env
VERSION="0.0.0"                        # x.y.z
DOMAIN="example"                       # k8s | server | apm | db | ...
TARGET="host/$(hostname 2>/dev/null || echo unknown)"   # identity of what is inspected

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

# section "TITLE"  -> starts the next numbered section
section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
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

# ---- reasoned-absence helpers — recommended, keep or trim as needed ---------
# These implement guideline 4 (../../docs/collector-engineering.md): a value you
# cannot obtain is reported WITH a classified reason, so the reader can tell
# "not installed" from "no permission" from "timed out". Reason strings stay
# free of judgment words so validate.sh keeps passing.
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=20
_init_probe() {
    _errfile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.err")"
    have timeout && _timeout_bin="$(command -v timeout)"
}
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null; }

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
probe() {
    local label="$1"; shift
    command -v "$1" >/dev/null 2>&1 || { fact "$label: n/a (command not found: $1)"; return; }
    local out rc
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$@" 2>"$_errfile")"; rc=$?
    else out="$("$@" 2>"$_errfile")"; rc=$?; fi
    [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ "$rc" -ne 0 ] && { fact "$label: n/a ($(_classify_err))"; return; }
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

# ---- report body — REPLACE THE PLACEHOLDER SECTIONS BELOW -------------------
_init_probe
emit_header

# Guideline 4: a capability preamble makes every downstream "command not found"
# self-explanatory. List the tools your collector relies on.
section "Collection environment"
fact "bash: ${BASH_VERSION:-unknown}"
fact "uid: $(id -u 2>/dev/null || echo unknown)"
fact "tools:"
for t in ss findmnt systemctl; do   # <- replace with the tools you use
    if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"
    else printf '        %-12s absent\n' "$t"; fi
done

# Placeholder: a discovered value, reported as a fact (with a reason if absent).
section "Host identity"
probe "hostname" hostname
probe "kernel" uname -sr

# Placeholder: resolve rather than assume (Contract rule 2). Replace the target
# with whatever your domain actually needs to resolve.
section "Example resolved value"
fact "replace this section with your domain's facts"
fact "when a value is absent, print it as a fact with its reason — n/a (...)"

emit_footer
_end_probe
