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
#   (3b) a PowerShell collector does not parse. `bash -n` has no counterpart for
#        .ps1, so this runs the PowerShell parser when `pwsh` is present. When it
#        is not, the line "~ not checked" is printed instead: a check that could
#        not run is not a check that passed. On Linux, pwsh installs without root:
#          curl -sSL <PowerShell release>/powershell-<ver>-linux-x64.tar.gz | \
#            tar -xz -C ~/.local/share/powershell-dist
#          ln -s ~/.local/share/powershell-dist/pwsh ~/.local/bin/pwsh
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
# Nothing in this directory is a collector, so nothing in it is validated:
# not this validator (its judgment-word pattern below obviously contains the
# words), and not the test harness or the sync helper beside it. Pass a
# collector, or a directory of collectors, or the repo root — the tools/
# directory is skipped either way.
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
        # Skip anything under a dotted directory (.git, .claude, a leftover
        # worktree). Those hold copies of the very files being linted, and a
        # stale copy failing is noise about a checkout, not about a collector.
        while IFS= read -r f; do targets+=("$f"); done \
            < <(find "$arg" -type f \( -name '*.sh' -o -name '*.ps1' \) -not -path '*/.*/*' | sort)
    elif [ -f "$arg" ]; then
        targets+=("$arg")
    else
        echo "not found: $arg" >&2
        exit 2
    fi
done
[ ${#targets[@]} -gt 0 ] || { echo "no .sh/.ps1 collectors found" >&2; exit 2; }

# This script's own directory. Everything in it is a tool, never a collector.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

rc=0
for f in "${targets[@]}"; do
    bn="$(basename "$f")"
    [ "$(cd "$(dirname "$f")" && pwd)" = "$SELF_DIR" ] && continue

    problems=()
    skipped=()

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

    # (2b) PowerShell collectors: parse them. `bash -n` has no counterpart here,
    #      so before pwsh was available on a reviewer's machine a .ps1 could ship
    #      with a syntax error that no check would catch. Skipped, with a line
    #      saying so, when pwsh is absent — a missing tool must not silently
    #      turn into a pass.
    case "$bn" in
        *.ps1)
            if command -v pwsh >/dev/null 2>&1; then
                perr="$(pwsh -NoProfile -Command "
                    \$e = \$null
                    \$null = [System.Management.Automation.Language.Parser]::ParseFile('$(cd "$(dirname "$f")" && pwd)/$bn', [ref]\$null, [ref]\$e)
                    if (\$e) { \$e | ForEach-Object { 'line ' + \$_.Extent.StartLineNumber + ': ' + \$_.Message } }
                " 2>&1)"
                [ -n "$perr" ] && while IFS= read -r l; do problems+=("powershell parse error -> $l"); done <<< "$perr"
            else
                skipped+=("powershell parse (pwsh not installed)")
            fi ;;
    esac

    # (3) the completeness roll-up: a collector must declare what it came for and
    #     say whether it got it (CONTRACT, "Saying whether the collection worked").
    #     Shell only — the PowerShell collectors carry their own port of the block
    #     and are checked by the Emit-Status name instead.
    #     Section 0 states the privilege the run had. What a collection can read
    #     is decided by it, and a report that omits it leaves the reader unable
    #     to tell an absent value from an unreadable one. Shell collectors carry
    #     the shared block; the PowerShell pair ports the same line by hand.
    #     Section 0 also states the host boot time, because nearly everything a
    #     collector reports is cumulative since boot and without it those are sums
    #     with no denominator. This looks for the _note_boot CALL, not the label:
    #     the label is printed from inside the shared block, so sync-shared-block
    #     sees a collector that carries the block and never calls it as "ok".
    #     Shell only. The PowerShell pair has no port of that block yet.
    case "$bn" in
        *.ps1)
            grep -v '^[[:space:]]*#' "$f" | grep -qF 'Emit-Status' \
                || problems+=("no completeness roll-up: nothing calls Emit-Status")
            grep -v '^[[:space:]]*#' "$f" | grep -qE '^\s*Add-Goal' \
                || problems+=("no goals declared: nothing calls Add-Goal")
            grep -v '^[[:space:]]*#' "$f" | grep -qF 'Fact "privilege: ' \
                || problems+=("section 0 does not state the privilege: no 'privilege:' fact") ;;
        *)
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:]])emit_status([[:space:]]|$)' \
                || problems+=("no completeness roll-up: nothing calls emit_status")
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:]])goal[[:space:]]' \
                || problems+=("no goals declared: nothing calls goal")
            grep -v '^[[:space:]]*#' "$f" | grep -qF 'fact "privilege: ' \
                || problems+=("section 0 does not state the privilege: no 'privilege:' fact")
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:]])_note_boot([[:space:]]|$)' \
                || problems+=("section 0 does not state the host boot time: nothing calls _note_boot") ;;
    esac

    # (4) judgment words in emitted lines (exclude comments + footer sentinel,
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
    # A check that could not run is not a check that passed. Say which.
    for sk in ${skipped[@]+"${skipped[@]}"}; do echo "      ~ not checked: $sk"; done
done

exit $rc
