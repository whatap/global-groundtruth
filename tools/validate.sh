#!/usr/bin/env bash
#
# validate.sh — lint a WhaTap Global Groundtruth collector against the CONTRACT.
# -----------------------------------------------------------------------------
# Usage:  tools/validate.sh <collector.sh | collector.ps1 | directory> [more...]
#         tools/validate.sh --report <report.txt> [more...]
#
# Two modes. The default reads a collector's SOURCE. --report reads a REPORT a
# collector produced, and checks what only a real run shows: the header values
# and their order, the numbering, the environment section, the status
# arithmetic, the footer. docs/output-format.md is the spec for both.
#
# Both shell (.sh) and PowerShell (.ps1) collectors are linted: PowerShell
# line comments use the same `#` prefix, so the comment-exclusion rules below
# apply unchanged. (PowerShell block comments <# ... #> are NOT excluded —
# keep collector commentary in line comments.)
#
# A collector SOURCE fails validation if any of the following is true:
#   (0) its filename is not collect-<token>.sh (or .ps1) — the required
#       entrypoint name, so collectors never collide when copied side by side
#       or into a shared bin/ — or its COLLECTOR_NAME is not whatap-<token>
#       for that same token, or its DOMAIN is not one of the listed domains.
#       The skeleton template and validate.sh itself are exempt from the name.
#   (1) it is missing one of the required header fields
#       (Collector: / Version: / Timestamp / Domain: / Target:) on a
#       non-comment line — a label that lives only in a comment is never
#       actually emitted
#   (2) it is missing the exact footer sentinel line (same non-comment rule)
#   (2b) a PowerShell collector does not parse (see below)
#   (3) it declares no goal, never calls emit_status, states no privilege,
#       never calls _note_boot, or (shell) never calls _run_init
#   (4) an EMITTED line contains a judgment word (case-insensitive):
#         diagnos  recommend  likely  should  root cause  fix
#       .NET assembly/namespace identifiers (System.Diagnostics.*,
#       Microsoft.Diagnostics.*, DiagnosticSource) are stripped from each
#       line before this scan: they are proper names a .NET collector must
#       emit as facts, not judgment prose. The prose words "diagnose /
#       diagnosis / diagnostic(s)" outside such identifiers still fail.
#   (2b) a PowerShell collector does not parse. `bash -n` has no counterpart for
#        .ps1, so this runs the PowerShell parser when `pwsh` is present. When it
#        is not, the line "~ not checked" is printed instead: a check that could
#        not run is not a check that passed. On Linux, pwsh installs without root:
#          curl -sSL <PowerShell release>/powershell-<ver>-linux-x64.tar.gz | \
#            tar -xz -C ~/.local/share/powershell-dist
#          ln -s ~/.local/share/powershell-dist/pwsh ~/.local/bin/pwsh
#
# Rule (4) is a keyword list. It catches the common slip, not every judgment:
# "probably" or "the problem is" pass it. Review catches the rest (CONTRACT.md).
#
# Rule (4) enforces CONTRACT rule 1 ("facts only — no emitted line states a
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
# directory is skipped either way. So is templates/groups/: its files own the
# group blocks, fragments with no header or main of their own, and each block
# is validated where it runs, inside every member collector.
# -----------------------------------------------------------------------------

set -u

FOOTER='==== END OF COLLECTION (no diagnosis by design) ===='
JUDGMENT='diagnos|recommend|\blikely\b|\bshould\b|\broot cause\b|\bfix\b'
HEADER_LABELS=('Collector:' 'Version:' 'Timestamp' 'Domain:' 'Target:')
# The top-level domains (output-format.md, "Header block"). A new domain is
# added here and there in the same change.
DOMAINS='k8s|server|apm|db|nms|collection-server'

usage() {
    echo "usage: $0 <collector.sh | collector.ps1 | directory> [more...]" >&2
    echo "       $0 --report <report.txt> [more...]" >&2
    exit 2
}
[ $# -ge 1 ] || usage

# ---- --report: check a produced report ---------------------------------------
# One awk pass. Each problem is printed as one line; no output means the report
# conforms. The rules, in the order output-format.md states them:
#   header   title line, then Collector/Version/Timestamp(UTC)/Domain/Target in
#            that order with conforming values, then the rule line
#   sections [n] numbered from 1 with no gap; [1] is "Collection environment"
#            and holds privilege / host boot(UTC) / host uptime(s); the last is
#            "Collection status"
#   status   "goals: N declared, a obtained, b not applicable here, c blocked"
#            with N = a + b + c, and "status: COMPLETE" exactly when c is 0 and
#            no run deadline was reached
#   footer   the last line, exactly, after a blank line
#   bytes    no UTF-8 BOM and no CR: a CRLF or BOM report is named as such and
#            not checked further (every other rule would fail on it)
# A section is a line at column 0 that starts with "[n] ". Fact lines are
# indented by the shared helpers, so quoted content cannot open a section.
check_report() {
    LC_ALL=C awk -v footer="$FOOTER" -v domains="^($DOMAINS)\$" '
    function bad(m) { print m; nbad++ }
    { line[NR] = $0; if (/\r$/) ncr++ }
    END {
        if (NR == 0) { bad("empty file"); exit }
        if (substr(line[1], 1, 3) == "\357\273\277") bad("starts with a UTF-8 BOM (a report is UTF-8 without BOM)")
        if (ncr) bad(ncr " of " NR " lines end in CR (CRLF): a report uses LF line endings")
        if (nbad) exit
        if (line[1] != "==== WhaTap Global Groundtruth Collection ====") bad("line 1 is not the title line")
        split("Collector:|Version:|Timestamp(UTC):|Domain:|Target:", lab, "|")
        for (i = 1; i <= 5; i++) {
            l = line[i + 1]
            if (index(l, lab[i]) != 1) { bad("line " (i + 1) " is not the " lab[i] " field"); continue }
            v = substr(l, length(lab[i]) + 1); sub(/^ +/, "", v); val[i] = v
        }
        if (val[1] !~ /^whatap-[a-z0-9-]+$/)                        bad("Collector: not whatap-<token>: " val[1])
        if (val[2] !~ /^[0-9]+\.[0-9]+\.[0-9]+$/)                    bad("Version: not x.y.z: " val[2])
        if (val[3] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/)
                                                                     bad("Timestamp(UTC): not ISO-8601 UTC: " val[3])
        if (val[4] !~ domains)                                       bad("Domain: not a top-level domain: " val[4])
        if (val[5] !~ /^[a-z][a-z0-9-]*\/[^ \t]+$/)                bad("Target: not <kind>/<name>[@<qualifier>] without spaces: " val[5])
        if (val[5] ~ /@(unresolved|unknown|n\/a)/ || val[5] ~ /\/(unresolved|unknown)$/)
                                                                     bad("Target: carries an outcome, not an identity: " val[5])
        if (line[7] !~ /^=+$/)                                       bad("line 7 is not the header rule")

        # sections
        n = 0
        for (i = 8; i <= NR; i++) {
            if (match(line[i], /^\[[0-9]+\] /)) {
                num = substr(line[i], 2, RLENGTH - 3) + 0
                n++
                if (num != n) bad("line " i ": section [" num "] where [" n "] was due")
                start[n] = i; title[n] = substr(line[i], RLENGTH + 1)
            }
        }
        if (n == 0) { bad("no numbered section"); }
        else {
            start[n + 1] = NR + 1
            if (title[1] != "Collection environment") bad("[1] is \"" title[1] "\", not \"Collection environment\"")
            split("privilege: |host boot(UTC): |host uptime(s): ", need, "|")
            for (j = 1; j <= 3; j++) {
                found = 0
                for (i = start[1]; i < start[2]; i++) if (index(line[i], "    " need[j]) == 1) found = 1
                if (!found) bad("[1] has no \"" need[j] "\" line")
            }
            if (title[n] != "Collection status") bad("the last section is \"" title[n] "\", not \"Collection status\"")
            else {
                g = ""; st = ""; dl = 0
                for (i = start[n]; i < start[n + 1]; i++) {
                    if (line[i] ~ /^    goals: /)        g = line[i]
                    if (line[i] ~ /^    status: /)       st = line[i]
                    if (line[i] ~ /^    run deadline: /) dl = 1
                }
                if (g == "") bad("the status section has no goals: line")
                else if (match(g, /goals: [0-9]+ declared, [0-9]+ obtained, [0-9]+ not applicable here, [0-9]+ blocked$/)) {
                    split(substr(g, RSTART + 7), w, /[^0-9]+/)
                    if (w[1] != w[2] + w[3] + w[4]) bad("goals do not add up: " w[1] " declared, " w[2] " + " w[3] " + " w[4])
                    blocked = w[4]
                } else bad("goals: line malformed: " g)
                if (st == "") bad("the status section has no status: line")
                else if (st == "    status: COMPLETE") { if (blocked > 0 || dl) bad("status COMPLETE with " blocked " blocked" (dl ? " and the run deadline reached" : "")) }
                else if (st == "    status: INCOMPLETE") { if (blocked == 0 && !dl) bad("status INCOMPLETE with nothing blocked") }
                else bad("status line malformed: " st)
            }
        }
        if (line[NR] != footer)  bad("the last line is not the footer")
        if (line[NR - 1] != "")  bad("no blank line before the footer")
        for (i = 8; i < NR; i++) if (line[i] == footer) bad("line " i ": the footer appears before the end")
    }' "$1"
}

if [ "$1" = --report ]; then
    shift
    [ $# -ge 1 ] || usage
    rc=0
    for r in "$@"; do
        [ -f "$r" ] || { echo "not found: $r" >&2; exit 2; }
        out="$(check_report "$r")"
        # the file name, when it is a delivered report, shares the Collector token
        bn="$(basename "$r")"
        coll="$(sed -n '2s/^Collector: *//p' "$r" | tr -d '\r')"
        case "$bn" in
            whatap-*.txt) case "$bn" in "$coll"-*) ;; *) out="${out:+$out
}file name $bn does not start with $coll-" ;; esac ;;
        esac
        if [ -z "$out" ]; then echo "PASS  $r"
        else
            echo "FAIL  $r"
            printf '%s\n' "$out" | sed 's/^/      - /'
            rc=1
        fi
    done
    exit $rc
fi

# Resolve arguments into a list of collector scripts.
targets=()
for arg in "$@"; do
    if [ -d "$arg" ]; then
        # Skip anything under a dotted directory (.git, .claude, a leftover
        # worktree). Those hold copies of the very files being linted, and a
        # stale copy failing is noise about a checkout, not about a collector.
        # Only dotted components BELOW the argument count: a checkout that itself
        # sits under ~/.cache is still a checkout.
        while IFS= read -r f; do
            case "${f#"$arg"}" in */.*) continue ;; esac
            targets+=("$f")
        done < <(find "$arg" -type f \( -name '*.sh' -o -name '*.ps1' \) | sort)
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
# The owners of the group blocks (sync-shared-block.sh): fragments, not collectors.
GROUPS_DIR="$(cd "$SELF_DIR/../templates/groups" 2>/dev/null && pwd)"

rc=0
for f in "${targets[@]}"; do
    bn="$(basename "$f")"
    fdir="$(cd "$(dirname "$f")" && pwd)"
    [ "$fdir" = "$SELF_DIR" ] && continue
    [ -n "$GROUPS_DIR" ] && [ "$fdir" = "$GROUPS_DIR" ] && continue

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
    # ... and COLLECTOR_NAME carries the same token, so the entrypoint, the
    # Collector: line and the output file share one identifier. DOMAIN is a
    # top-level domain.
    case "$bn" in
        collect-*.sh|collect-*.ps1)
            tok="${bn#collect-}"; tok="${tok%.*}"
            cn="$(grep -m1 -E '^[$]?COLLECTOR_NAME *= *"' "$f" | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
            [ "$cn" = "whatap-$tok" ] || problems+=("COLLECTOR_NAME must be whatap-$tok for $bn (got: ${cn:-none})")
            dm="$(grep -m1 -E '^[$]?DOMAIN *= *"' "$f" | sed -E 's/^[^"]*"([^"]*)".*/\1/')"
            printf '%s\n' "$dm" | grep -qxE "$DOMAINS" || problems+=("DOMAIN must be one of ${DOMAINS//|/, } (got: ${dm:-none})") ;;
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
                || problems+=("the environment section does not state the privilege: no 'privilege:' fact")
            # The PowerShell port of the shared blocks owes the same lines and
            # streams (output-format.md, "Scope"): the boot time, and no
            # Write-Host, which reaches stdout under pwsh -File.
            grep -v '^[[:space:]]*#' "$f" | grep -qF 'host boot(UTC): ' \
                || problems+=("the environment section does not state the host boot time: no 'host boot(UTC):' fact")
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[^A-Za-z-])Write-Host([^A-Za-z-]|$)' \
                && problems+=("Write-Host is used: operator messages go to [Console]::Error (it reaches stdout under pwsh -File)") ;;
        *)
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:]])emit_status([[:space:]]|$)' \
                || problems+=("no completeness roll-up: nothing calls emit_status")
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:]])goal[[:space:]]' \
                || problems+=("no goals declared: nothing calls goal")
            grep -v '^[[:space:]]*#' "$f" | grep -qF 'fact "privilege: ' \
                || problems+=("the environment section does not state the privilege: no 'privilege:' fact")
            grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:]])_note_boot([[:space:]]|$)' \
                || problems+=("the environment section does not state the host boot time: nothing calls _note_boot")
            # A pipe into _bounded reads /dev/null when the script itself is on
            # stdin (sh -s), and the command sees nothing: collserver found no
            # JVM under bash -s and said "none" (2026-09-25). Use _bounded_in.
            _pb="$(grep -nE '(^|[^|])\|&?[[:space:]]*_bounded([[:space:]]|$)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | head -n 3 | cut -d: -f1 | tr '\n' ' ')"
            [ -n "$_pb" ] && problems+=("a pipe into _bounded (line ${_pb% }): its stdin is /dev/null under sh -s; write the input to _tmp and use _bounded_in")
            # A fixed top-level CMD_TIMEOUT=N overwrites the value _run_init checked
            # from the environment, so the operator's cap is silently ignored.
            _ct="$(grep -nE '^CMD_TIMEOUT=[0-9]' "$f" | head -n 1 | cut -d: -f1)"
            [ -n "$_ct" ] && problems+=("CMD_TIMEOUT is set to a fixed number at line $_ct: use CMD_TIMEOUT=\"\${CMD_TIMEOUT:-N}\" so the environment's value is kept")
            case "$bn" in collector-skeleton.sh) ;; *)
                grep -qE '^_run_init$' "$f" \
                    || problems+=("main never calls _run_init: no deadline, no private temp directory, no cleanup") ;;
            esac ;;
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
