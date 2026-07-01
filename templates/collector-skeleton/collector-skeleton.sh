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
# NOTE: this script deliberately does NOT use `set -e`. A collector must always
# run to completion and emit its footer, even when individual discovery steps
# fail. Handle failure locally (the `try` helper does this) instead of aborting.
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
# if the command fails or produces nothing. This is how a collector reports a
# value that may be absent WITHOUT assuming a default (Contract rule 2).
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

# ---- report body — REPLACE THE PLACEHOLDER SECTIONS BELOW -------------------
emit_header

# Placeholder: a discovered value, reported as a fact.
section "Host identity"
try hostname
try uname -sr

# Placeholder: resolve rather than assume (Contract rule 2). Replace the target
# with whatever your domain actually needs to resolve.
section "Example resolved value"
fact "replace this section with your domain's facts"
fact "when a value is absent, print it as a fact — n/a"

emit_footer
