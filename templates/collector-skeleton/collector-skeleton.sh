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

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
# Guideline 5 (../../docs/collector-engineering.md): no-args prints usage — a run
# needs an explicit action flag (--file / --stdout) so nothing starts by accident;
# and progress is narrated on stderr (fd 3, see main) so the operator sees it
# working while the report on stdout stays byte-for-byte clean. --quiet silences it.
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet .. silence progress on stderr (add to --file / --stdout)
EOF
}

ARGC=$#           # 0 args -> usage (handled in main, below)
while [ $# -gt 0 ]; do
    case "$1" in
        --file)    OPT_FILE=1 ;;
        --stdout)  OPT_STDOUT=1 ;;
        --quiet)   OPT_QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

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

# section "TITLE"  -> starts the next numbered section (and narrates it to fd 3)
section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
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

# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any redirection). It NEVER lands in the report — stdout stays the report
# even in --file mode. Silenced by --quiet. Keep the text a fact about collection
# state (no judgment words) so validate.sh keeps passing.
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- reasoned-absence helpers — recommended, keep or trim as needed ---------
# These implement guideline 4 (../../docs/collector-engineering.md): a value you
# cannot obtain is reported WITH a classified reason, so the reader can tell
# "not installed" from "no permission" from "timed out". Reason strings stay
# free of judgment words so validate.sh keeps passing.
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
# Per-probe cap. Budget the whole run too: dozens of hanging probes x 20s is
# minutes on a sick host — lower this (or give network-dependent probes their
# own shorter cap) if your collector has many of them. Guideline 2.
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

# ---- report body — EDIT HERE ------------------------------------------------
# Add your fact sections inside run_report(); leave the CLI harness, the helpers,
# and the header/footer shape alone. Each `section` also narrates itself to the
# terminal (guideline 5), so you get progress for free.
run_report() {
    emit_header

    # Declare what this run is for, before collecting anything. Keep the list
    # short: a goal is something whose absence makes the bundle not worth
    # sending, not every value the collector happens to print.
    goal identity "host identity"
    goal example  "the thing this collector exists to obtain"

    # Guideline 4: a capability preamble makes every downstream "command not found"
    # self-explanatory. List the tools your collector relies on.
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown)"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    fact "tools:"
    for t in ss findmnt systemctl; do   # <- replace with the tools you use
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"
        else printf '        %-12s absent\n' "$t"; fi
    done

    # Placeholder: a discovered value, reported as a fact (with a reason if absent).
    section "Host identity"
    probe "hostname" hostname
    probe "kernel" uname -sr
    if hostname >/dev/null 2>&1; then got identity; else missed identity "hostname unavailable"; fi

    # Placeholder: resolve rather than assume (Contract rule 2). Replace the target
    # with whatever your domain actually needs to resolve.
    section "Example resolved value"
    fact "replace this section with your domain's facts"
    fact "when a value is absent, print it as a fact with its reason — n/a (...)"
    missed example "replace this with got/missed at the point the value is resolved"

    # Always last, immediately before the footer.
    emit_status
    emit_footer
}

# ---- main — DO NOT EDIT -----------------------------------------------------
# fd 3 = the terminal, saved before any redirection so progress() reaches the
# operator even in --file mode (which redirects both stdout and stderr).
exec 3>&2

# No arguments -> print help and stop; a collection needs an explicit action flag.
[ "$ARGC" -eq 0 ] && { usage; exit 0; }

# Modifiers alone (e.g. --quiet) are not an action — say so and show help.
if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_init_probe
if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="$(hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="./$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    run_report > "$OUTFILE" 2>/dev/null
    progress "report written: $OUTFILE"
fi
_end_probe
