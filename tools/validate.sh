#!/usr/bin/env bash
#
# validate.sh — lint a WhaTap Global Groundtruth collector against the CONTRACT.
# -----------------------------------------------------------------------------
# Usage:  tools/validate.sh <collector.sh | collector.ps1 | directory> [more...]
#
# Both shell (.sh) and PowerShell (.ps1) collectors are linted: PowerShell
# line comments use the same `#` prefix, so the comment-exclusion rules below
# apply unchanged. (PowerShell block comments <# ... #> are NOT excluded —
# keep collector commentary in line comments.)
#
# A collector FAILS validation if any of the following is true:
#   (1) it is missing one of the required header fields
#       (Collector: / Version: / Timestamp / Domain: / Target:) on a
#       non-comment line — a label that lives only in a comment is never
#       actually emitted
#   (2) it is missing the exact footer sentinel line (same non-comment rule)
#   (3) an EMITTED line contains a judgment word (case-insensitive):
#         diagnos  recommend  likely  should  root cause  fix
#       .NET assembly/namespace identifiers (System.Diagnostics.*,
#       Microsoft.Diagnostics.*, DiagnosticSource) are stripped from each
#       line before this scan: they are proper names a .NET collector must
#       emit as facts, not judgment prose. The prose words "diagnose /
#       diagnosis / diagnostic(s)" outside such identifiers still fail.
#   (4) its filename is not collect-<token>.sh (or .ps1) — the required
#       entrypoint name,
#       so collectors never collide when copied side by side or into a shared
#       bin/. The skeleton template and validate.sh itself are exempt.
#
# Rule (3) enforces CONTRACT rule 1 ("facts only — no emitted line states a
# conclusion"). Two kinds of lines are therefore NOT judged, on purpose:
#   - comment lines (^\s*#): the contract reminders a collector carries live in
#     comments and never reach the reader, so they may name these words freely;
#   - the footer sentinel line itself, which literally contains "no diagnosis".
# Line numbers reported below are the true line numbers in the file.
#
# This validator is a tool, not a collector, so it is never validated against
# itself (its judgment-word pattern below obviously contains the words).
# -----------------------------------------------------------------------------

set -u

FOOTER='==== END OF COLLECTION (no diagnosis by design) ===='
JUDGMENT='diagnos|recommend|\blikely\b|\bshould\b|\broot cause\b|\bfix\b'
HEADER_LABELS=('Collector:' 'Version:' 'Timestamp' 'Domain:' 'Target:')

usage() { echo "usage: $0 <collector.sh | directory> [more...]" >&2; exit 2; }
[ $# -ge 1 ] || usage

# Resolve arguments into a list of collector scripts.
targets=()
for arg in "$@"; do
    if [ -d "$arg" ]; then
        while IFS= read -r f; do targets+=("$f"); done \
            < <(find "$arg" -type f \( -name '*.sh' -o -name '*.ps1' \) | sort)
    elif [ -f "$arg" ]; then
        targets+=("$arg")
    else
        echo "not found: $arg" >&2
        exit 2
    fi
done
[ ${#targets[@]} -gt 0 ] || { echo "no .sh/.ps1 collectors found" >&2; exit 2; }

rc=0
for f in "${targets[@]}"; do
    bn="$(basename "$f")"
    # The validator is not a collector; never lint it.
    [ "$bn" = "validate.sh" ] && continue

    problems=()

    # (0) entrypoint naming: collect-<token>.sh, never a bare collect.sh, so
    #     collectors never collide when copied side by side or into a shared bin/.
    #     The skeleton template is format-checked but exempt from the name rule
    #     (it is copied and renamed, never run in the field).
    case "$bn" in
        collect-*.sh|collect-*.ps1|collector-skeleton.sh) ;;
        *) problems+=("entrypoint must be named collect-<token>.sh or collect-<token>.ps1 (got: $bn)") ;;
    esac

    # (1) required header fields — on non-comment lines only, so a label that
    #     exists solely in a comment (never emitted) does not pass
    for label in "${HEADER_LABELS[@]}"; do
        grep -v '^[[:space:]]*#' "$f" | grep -qF "$label" \
            || problems+=("missing header field on a non-comment line: $label")
    done

    # (2) exact footer sentinel — same non-comment rule
    grep -v '^[[:space:]]*#' "$f" | grep -qF "$FOOTER" \
        || problems+=("missing exact footer line on a non-comment line: $FOOTER")

    # (3) judgment words in emitted lines (exclude comments + footer sentinel,
    #     keeping the file's true line numbers). .NET identifiers containing
    #     "Diagnostics" are stripped first (line structure is preserved, so
    #     grep -n line numbers stay true).
    offenders=$(sed -E 's/(System|Microsoft)\.Diagnostics[A-Za-z0-9.]*//g; s/DiagnosticSource//g' "$f" \
                | grep -inE "$JUDGMENT" \
                | grep -vE '^[0-9]+:[[:space:]]*#' \
                | grep -vF "$FOOTER" || true)
    if [ -n "$offenders" ]; then
        while IFS= read -r line; do
            problems+=("judgment word in emitted line -> $line")
        done <<< "$offenders"
    fi

    if [ ${#problems[@]} -eq 0 ]; then
        echo "PASS  $f"
    else
        echo "FAIL  $f"
        for p in "${problems[@]}"; do echo "      - $p"; done
        rc=1
    fi
done

exit $rc
