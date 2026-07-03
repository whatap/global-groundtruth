#!/usr/bin/env bash
#
# validate.sh — lint a WhaTap Global Groundtruth collector against the CONTRACT.
# -----------------------------------------------------------------------------
# Usage:  tools/validate.sh <collector.sh | directory> [more...]
#
# A collector FAILS validation if any of the following is true:
#   (1) it is missing one of the required header fields
#       (Collector: / Version: / Timestamp / Domain: / Target:)
#   (2) it is missing the exact footer sentinel line
#   (3) an EMITTED line contains a judgment word (case-insensitive):
#         diagnos  recommend  likely  should  root cause  fix
#   (4) its filename is not collect-<token>.sh — the required entrypoint name,
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
            < <(find "$arg" -type f -name '*.sh' | sort)
    elif [ -f "$arg" ]; then
        targets+=("$arg")
    else
        echo "not found: $arg" >&2
        exit 2
    fi
done
[ ${#targets[@]} -gt 0 ] || { echo "no .sh collectors found" >&2; exit 2; }

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
        collect-*.sh|collector-skeleton.sh) ;;
        *) problems+=("entrypoint must be named collect-<token>.sh (got: $bn)") ;;
    esac

    # (1) required header fields
    for label in "${HEADER_LABELS[@]}"; do
        grep -qF "$label" "$f" || problems+=("missing header field: $label")
    done

    # (2) exact footer sentinel
    grep -qF "$FOOTER" "$f" || problems+=("missing exact footer line: $FOOTER")

    # (3) judgment words in emitted lines (exclude comments + footer sentinel,
    #     keeping the file's true line numbers)
    offenders=$(grep -inE "$JUDGMENT" "$f" \
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
