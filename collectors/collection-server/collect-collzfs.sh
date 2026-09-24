#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collection-server ZFS collector
# -----------------------------------------------------------------------------
# Scope: a WhaTap collection-server host whose data path (yardbase / logs / db)
# sits on ZFS. It gathers the ZFS facts a remote reviewer needs in order to
# verify or refute a judgment about block sizing, allocation classes, the write
# path and free-space fragmentation — WITHOUT the collector itself making that
# judgment (CONTRACT rule 1).
#
# Companion collector: collect-collserver.sh collects the WhaTap backend facts
# (WHATAP_HOME layout, JVMs, ports, conf/*.conf, service logs). This collector
# deliberately does NOT repeat those; it stops at "which dataset does each
# WhaTap path live on, and what are that dataset's properties" (section M).
# The two reports are each self-contained; the MECE rule applies within a
# report, not across collectors.
#
# What a reader typically wants to check, and where the facts for it live:
#   * allocation-class routing      -> B (zfs_special_class_metadata_reserve_pct),
#                                      C (per-vdev class usage), E (recordsize vs
#                                      special_small_blocks, side by side)
#   * block sizing                  -> E (property matrix incl. property source),
#                                      J (request-size histograms), N (zdb -Lbbbs)
#   * append / txg behaviour        -> B (zfs_txg_timeout, dirty-data throttle),
#                                      H (txgs ring buffer, ZIL kstats), I (per-
#                                      dataset objset write counters)
#   * free-space fragmentation      -> C/D (FRAG, CAP per vdev and per pool),
#                                      B (metaslab_* parameters), N (zdb -mm)
#   * rewrite / send-receive path   -> A (whether the rewrite subcommand exists),
#                                      F (snapshot and clone space accounting)
#
# THE CONTRACT (../../CONTRACT.md) — facts only, no diagnosis / no judgment.
# Thresholds, defaults-in-the-docs and "good/bad" belong to the reader, not to
# this script: it prints the measured value and the tunable that governs it.
#
# DESIGN GUIDELINES (../../docs/collector-engineering.md):
#   * MECE sections     — every fact lives in exactly one domain (A..N below).
#   * Load-safe by tier — Tier 0 (default report) reads kstats, properties and
#                         cumulative-since-boot iostat only: no pool traversal,
#                         no tree walk, no device wake-up. Anything that costs
#                         wall-clock (--sample) or pool I/O (--zdb,
#                         --filesizes) is opt-in and announced first.
#   * Portable          — /proc and /sys first; parse `zpool list -v` by column
#                         NAME instead of position; discover kstat files instead
#                         of hardcoding them; target bash 3.2+.
#   * Reasoned absence  — a value we cannot obtain is a fact too, carrying WHY
#                         (command not found / permission denied / path not
#                         found / timed out / not applicable / empty output).
#                         A tunable that does not exist in this ZFS build is
#                         reported as such — that is a version fact.
#
# NOTE: no `set -e` / no `set -u`. A collector must run to completion and emit
# its footer even when individual steps fail; each step guards itself.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-collection-server-zfs"
VERSION="0.4.1"
DOMAIN="collection-server"
TARGET="collection-server-zfs/$(hostname 2>/dev/null || echo unknown)"   # refined after pool discovery

# ---- options ----------------------------------------------------------------
OPT_FILE=0           # write the report to a .txt file
OPT_STDOUT=0
OPT_BUNDLE=0
OPT_QUIET=0          # suppress progress narration on stderr
OPT_OUT="."
OPT_HOME=""
OPT_HOURS=24         # journal window
OPT_SAMPLE=0         # Tier 1: interval iostat/arcstat samples
SAMPLE_SECS=10
# Block-layer sampling bucket, in seconds. `iostat -x` with no interval prints
# the average since boot, which on a long-lived host averages a busy hour into a
# year and reads as idle. A reader cannot tell the two apart from the output, so
# --sample takes buckets too and keeps every one of them: a peak that a single
# window would average away stays visible as one tall bucket.
IOSTAT_BUCKET=5
OPT_ZDB=0            # Tier 2: zdb -C / -Lbbbs / -mm
# File-size histogram. On by default since 0.2.0: it is the only thing in this
# collector that says what size the workload actually writes, and recordsize
# cannot be judged without it. It reads metadata only (find -printf '%s'), never
# file contents. It was opt-in until 0.1.0 and therefore absent from the runs
# that mattered — the XLSMART web01 bundles of 2026-09-23 came back with
# filesizes=off because the runbook did not pass the flag.
OPT_FILESIZES=1
FILESIZES_PATH=""
FILESIZES_SECS=300   # bound on the tree walk; a partial result is labelled as such
# zpool events window, in days. The ring buffer holds everything back to pool
# creation when zfs_zevent_len_max is large, and `zpool events -v` of that is
# hundreds of MB (192MB on XLSMART web01-bsd, 2026-09-23). The per-event detail
# is only useful for recent events, but the TALLY is useful over the whole buffer
# because what matters is when a class STARTED and when it STOPPED. So: tally
# everything, keep the detail for this window. 0 keeps the detail for everything.
OPT_EVENT_DAYS=30

usage() {
    cat <<'EOF'
Run on the collection-server host. Produces one ZFS facts .txt or a tar.gz.
Run with no arguments (or --help) to print this help — a collection needs an
explicit action flag (--file / --stdout / --bundle) so nothing starts by accident.

  collect-collzfs.sh                        print this help (no collection)
  collect-collzfs.sh --file                 Tier 0 ZFS facts report -> one .txt file
  collect-collzfs.sh --stdout               print the report to stdout instead of a file
  collect-collzfs.sh --bundle               Tier 0 report + Tier 1 raw artifacts -> tar.gz
  collect-collzfs.sh --quiet ...            silence progress on stderr (for automation)
  collect-collzfs.sh --home DIR             force WHATAP_HOME (else auto-resolved)
  collect-collzfs.sh --out DIR              output directory (default: .)
  collect-collzfs.sh --hours N              journal window in hours (default: 24)

  Tier 0 always includes the cumulative-since-boot zpool iostat histograms
  (-r request size, -w latency), which are instant kstat reads, and the
  file-size histogram under yardbase (see --no-filesizes to turn it off).

  zpool events. The tally (count, first date, last date per class) always covers
  the WHOLE ring buffer, because what the buffer answers is when a class started
  and when it stopped. The per-event detail is kept only for a recent window,
  because the full -v dump of a deep buffer is hundreds of MB.
  collect-collzfs.sh --event-days N         detail window in days (default: 30)
                                            0 keeps the detail for everything

  Tier 1 sampling (read-only; costs wall-clock, not disk load):
  collect-collzfs.sh --file --sample[=SEC]  add interval samples of zpool iostat
                                            -lqv / -r / -w, arcstat, and iostat -x
                                            in 5s buckets over 3 x SEC seconds
                                            (default SEC=10; adds about 9 x SEC seconds)
                                            Without this, every block-layer number
                                            (%util, await, aqu-sz) is the average
                                            since boot and cannot answer "is the
                                            device busy now".

  File-size histogram (on by default since 0.2.0). recordsize cannot be judged
  without knowing what size the workload actually writes, so this is no longer
  opt-in. It reads metadata only (find -printf '%s'), never file contents, and a
  walk that hits its bound is labelled PARTIAL rather than passed off as whole.
  collect-collzfs.sh --filesizes=PATH       walk PATH instead of yardbase
  collect-collzfs.sh --filesizes-secs N     bound on the walk (default: 300)
  collect-collzfs.sh --no-filesizes         skip it

  Tier 2 (opt-in, adds pool or disk load — announced on stderr before running):
  collect-collzfs.sh --file --zdb           zdb -C, -Lbbbs, -mm per pool: block/psize
                                            histograms, measured compression, metaslab
                                            free-space histograms. Traverses pool
                                            metadata — minutes on a large pool.
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
        --home) OPT_HOME="$2"; shift ;;
        --home=*) OPT_HOME="${1#*=}" ;;
        --hours) OPT_HOURS="$2"; shift ;;
        --hours=*) OPT_HOURS="${1#*=}" ;;
        --sample) OPT_SAMPLE=1 ;;
        --sample=*) OPT_SAMPLE=1; SAMPLE_SECS="${1#*=}" ;;
        --zdb) OPT_ZDB=1 ;;
        --filesizes) OPT_FILESIZES=1 ;;
        --filesizes=*) OPT_FILESIZES=1; FILESIZES_PATH="${1#*=}" ;;
        --no-filesizes) OPT_FILESIZES=0 ;;
        --filesizes-secs) FILESIZES_SECS="$2"; shift ;;
        --filesizes-secs=*) FILESIZES_SECS="${1#*=}" ;;
        --event-days) OPT_EVENT_DAYS="$2"; shift ;;
        --event-days=*) OPT_EVENT_DAYS="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

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
blk() { printf '        %s\n' "$1"; }

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
        *[Pp]"ermission denied"*|*"peration not permitted"*|*"peration not supported"*)
            echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*|*"o such device"*|*"no such pool"*|*"o such pool"*)
            echo "path not found"; return ;;
        *"nvalid option"*|*"llegal option"*|*"nrecognized"*|*"usage:"*|*"Usage:"*)
            echo "option not supported by this zfs version"; return ;;
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
        printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do blk "$_l"; done
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

# probe_merged: like probe but folds stderr into stdout (tools that print to stderr).
probe_merged() {
    local label="$1"; shift
    local bin="$1"
    if ! command -v "$bin" >/dev/null 2>&1; then
        fact "$label: n/a (command not found: $bin)"; return
    fi
    local out rc
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$@" 2>&1)"; rc=$?
    else out="$("$@" 2>&1)"; rc=$?; fi
    if [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ]; then fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; fi
    if [ -z "$out" ]; then fact "$label: n/a (empty output)"; return; fi
    _emit_labeled "$label" "$out"
}

# probe_t SECS "label" CMD... -> probe with a one-shot timeout override
probe_t() {
    local t="$1"; shift
    local sv="$CMD_TIMEOUT"
    CMD_TIMEOUT="$t"
    probe "$@"
    CMD_TIMEOUT="$sv"
}

# probe_pipe "label" REQBIN 'shell pipeline' -> probe a pipeline, but classify a
# missing primary binary as "command not found: REQBIN" rather than as sh output.
probe_pipe() {
    local label="$1" req="$2" pipeline="$3"
    if ! command -v "$req" >/dev/null 2>&1; then
        fact "$label: n/a (command not found: $req)"; return
    fi
    probe "$label" sh -c "$pipeline"
}

probe_pipe_t() {
    local t="$1"; shift
    local sv="$CMD_TIMEOUT"
    CMD_TIMEOUT="$t"
    probe_pipe "$@"
    CMD_TIMEOUT="$sv"
}

# read_proc "label" PATH -> emits a /proc or /sys file's content with a reason.
read_proc() {
    local label="$1" path="$2" cap="${3:-0}"
    if [ ! -e "$path" ]; then fact "$label: n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "$label: n/a (permission denied: $path)"; return; fi
    local out
    if [ "$cap" -gt 0 ] 2>/dev/null; then out="$(tail -n "$cap" "$path" 2>"$_errfile")"
    else out="$(cat "$path" 2>"$_errfile")"; fi
    if [ -z "$out" ]; then fact "$label: n/a (empty output)"; return; fi
    _emit_labeled "$label" "$out"
}

# read_kstat_tail "label" PATH LINES -> like read_proc with a cap, but keeps the
# kstat column header (line 1) and says how many records were omitted. The txgs
# ring buffer is header + zfs_txg_history rows, so a plain tail would cut the
# only line that names the columns.
read_kstat_tail() {
    local label="$1" path="$2" n="$3" total out
    if [ ! -e "$path" ]; then fact "$label: n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "$label: n/a (permission denied: $path)"; return; fi
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    if [ -z "$total" ] || [ "$total" -eq 0 ] 2>/dev/null; then fact "$label: n/a (empty output)"; return; fi
    if [ "$total" -le "$n" ] 2>/dev/null; then
        out="$(cat "$path" 2>/dev/null)"
    else
        out="$( { head -n 1 "$path"; printf '... (%s earlier records omitted of %s lines) ...\n' "$((total - n))" "$total"; tail -n "$n" "$path"; } 2>/dev/null)"
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# _epoch_iso EPOCH -> ISO-8601 UTC, or the raw epoch when date cannot convert it
_epoch_iso() {
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'epoch=%s' "$1"
}

# dump_file PATH [LINES] -> emits a file's content (bounded), or a reason.
dump_file() {
    local path="$1" cap="${2:-2000}"
    if [ ! -e "$path" ]; then fact "n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "n/a (permission denied: $path)"; return; fi
    if [ ! -s "$path" ]; then fact "(empty file)"; return; fi
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do blk "$_l"; done
}

warn() { printf '%s\n' "$*" >&2; }

# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any stdout/stderr redirection). It NEVER lands in the report. Silenced by
# --quiet. Keep the text a fact about collection state (no judgment words).
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# run_bounded SECS CMD... -> stdout only, bounded when `timeout` exists
run_bounded() {
    local s="$1"; shift
    if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$s" "$@" 2>/dev/null
    else "$@" 2>/dev/null; fi
}

# ---- portable helpers -------------------------------------------------------
fstype_of() {
    local p="$1"
    if have findmnt; then findmnt -no FSTYPE -T "$p" 2>/dev/null && return; fi
    if have stat; then stat -f -c '%T' "$p" 2>/dev/null && return; fi
    echo ""
}

source_of() {
    local p="$1"
    if have findmnt; then findmnt -no SOURCE -T "$p" 2>/dev/null && return; fi
    echo ""
}

cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

sd_show() { have systemctl && systemctl show -p "$1" "$2" 2>/dev/null | cut -d= -f2-; }
unit_loaded() { [ "$(sd_show LoadState "$1")" = "loaded" ]; }

# param NAME -> "NAME = value" from /sys/module/zfs/parameters, with a reason.
# A tunable that is absent is a fact about this build, not a collection failure.
param() {
    local n="$1" p="/sys/module/zfs/parameters/$1"
    if [ ! -e "$p" ]; then fact "$n = n/a (path not found: not present in this zfs build)"; return; fi
    if [ ! -r "$p" ]; then fact "$n = n/a (permission denied)"; return; fi
    fact "$n = $(head -n1 "$p" 2>/dev/null)"
}

# dump_param_dir DIR -> "name = value" for every readable parameter file
dump_param_dir() {
    local d="$1" f v n=0
    if [ ! -d "$d" ]; then fact "n/a (path not found: $d)"; return; fi
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        if [ -r "$f" ]; then v="$(head -n1 "$f" 2>/dev/null)"; else v="n/a (permission denied)"; fi
        printf '        %-56s = %s\n' "$(basename "$f")" "$v"
        n=$((n + 1))
    done
    [ "$n" -eq 0 ] && fact "n/a (empty output)"
}

# =============================================================================
# Discovery (run once, before the report)
# =============================================================================
ZPOOLS=""            # space-separated pool names
ZPOOL_COUNT=0
_ZGETALL=""          # temp file: name<TAB>property<TAB>value<TAB>source (fs+vol)
_ZSNAP=""            # temp file: name<TAB>used<TAB>creation(epoch)<TAB>userrefs
DS_COUNT=0
SNAP_COUNT=0
KSTAT_DIR="/proc/spl/kstat/zfs"
ZFS_ON_HOST=0        # 1 when zfs/zpool commands OR the kstat tree exist

discover_zfs() {
    if have zfs || have zpool || [ -d "$KSTAT_DIR" ]; then ZFS_ON_HOST=1; fi
    if have zpool; then
        ZPOOLS="$(run_bounded 20 zpool list -H -o name | tr '\n' ' ')"
        ZPOOL_COUNT="$(printf '%s' "$ZPOOLS" | wc -w | tr -d ' ')"
    fi
    if have zfs; then
        # One pass over every filesystem/volume property, WITH its source
        # (local / inherited / default). Asking for `all` instead of a property
        # list means a version that lacks a property simply does not report it —
        # no command-wide failure, and the absence itself becomes a fact.
        _ZGETALL="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.zget.$$")"
        run_bounded 90 zfs get -H -o name,property,value,source -t filesystem,volume all > "$_ZGETALL" 2>/dev/null
        DS_COUNT="$(awk -F'\t' '{print $1}' "$_ZGETALL" 2>/dev/null | sort -u | grep -c . 2>/dev/null)"
        # One pass over snapshots. `clones` is a SNAPSHOT property (it never
        # appears in the filesystem/volume dump above), so it is collected here:
        # a snapshot with a clone attached cannot be destroyed to reclaim space.
        # Bounded: a yard with an aggressive snapshot policy holds tens of thousands.
        _ZSNAP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.zsnap.$$")"
        run_bounded 120 zfs list -H -p -t snapshot -o name,used,creation,userrefs,clones > "$_ZSNAP" 2>/dev/null
        SNAP_COUNT="$(grep -c . "$_ZSNAP" 2>/dev/null)"
    fi
    [ -z "$DS_COUNT" ] && DS_COUNT=0
    [ -z "$SNAP_COUNT" ] && SNAP_COUNT=0
}

# zprop DATASET PROPERTY -> value, or empty when absent
zprop() {
    [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ] || return
    awk -F'\t' -v d="$1" -v p="$2" '$1==d && $2==p {print $3; exit}' "$_ZGETALL" 2>/dev/null
}

# has_property PROPERTY -> 0 when this zfs build reported the property at all
has_property() {
    [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ] || return 1
    awk -F'\t' -v p="$1" '$2==p {found=1; exit} END{exit !found}' "$_ZGETALL" 2>/dev/null
}

# ---- WhaTap layout discovery (only enough to map paths to datasets) ---------
WHATAP_UNITS="yard proxy gateway keeper account notihub eureka front router billing crane flexreport"
WHOME=""
WHOME_SRC=""
YARDBASE=""

resolve_home() {
    local d cl v unit wd sd
    if [ -n "$OPT_HOME" ]; then WHOME="$OPT_HOME"; WHOME_SRC="option --home"; return; fi
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cl="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$cl" in
            *whatap.server.*|*whatap.opslake.*|*.yard.boot*) ;;
            *) continue ;;
        esac
        v="$(printf '%s\n' "$cl" | grep -oE '[-]Dwhatap\.server\.home=[^ ]+' | head -n1 | cut -d= -f2-)"
        if [ -n "$v" ]; then WHOME="$v"; WHOME_SRC="process ${d#/proc/} (-Dwhatap.server.home)"; return; fi
    done
    if have systemctl; then
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit.service" || continue
            wd="$(sd_show WorkingDirectory "$unit.service")"
            if [ -n "$wd" ] && [ "$wd" != "/" ]; then WHOME="$wd"; WHOME_SRC="systemd $unit.service WorkingDirectory"; return; fi
        done
    fi
    sd="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -n "$sd" ] && [ -d "$sd/../conf" ] && [ -d "$sd/../logs" ]; then
        WHOME="$(cd "$sd/.." && pwd)"; WHOME_SRC="script parent dir"; return
    fi
    WHOME=""; WHOME_SRC="n/a (not resolved)"
}

resolve_yardbase() {
    local v
    if [ -n "$WHOME" ] && [ -f "$WHOME/conf/yard.conf" ]; then
        v="$(grep -E '^[[:space:]]*yardbase[[:space:]]*=' "$WHOME/conf/yard.conf" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d ' \r')"
        [ -n "$v" ] && YARDBASE="$v"
    fi
    if [ -z "$YARDBASE" ] && [ -n "$WHOME" ] && [ -d "$WHOME/yardbase" ]; then YARDBASE="$WHOME/yardbase"; fi
    case "$YARDBASE" in
        ""|/*) : ;;
        *) [ -n "$WHOME" ] && YARDBASE="$WHOME/$YARDBASE" ;;
    esac
}

# =============================================================================
# Derived views (re-projections of command output — no interpretation added)
# =============================================================================

# Per-top-level-vdev usage grouped by allocation class, derived from
# `zpool list -v`. The raw output is emitted next to this, so nothing is lost if
# a future layout defeats the parser. Columns are located by HEADER NAME, not by
# position, because zpool grew CKPOINT/EXPANDSZ/DEDUP columns over time.
zpool_class_view() {
    run_bounded 20 zpool list -v 2>/dev/null | awk '
        NR==1 { for (i=1; i<=NF; i++) col[$i]=i; next }
        {
            ind = 0
            if (match($0, /^ +/)) ind = RLENGTH
            name = $1
            if (ind == 0) {
                if (pool != "" && (name=="special" || name=="logs" || name=="log" || \
                                   name=="cache" || name=="spare" || name=="spares" || name=="dedup")) {
                    cls = name; next
                }
                pool = name; cls = "data"
                printf "pool  %-24s size=%-8s alloc=%-8s free=%-8s frag=%-6s cap=%-6s health=%s\n", \
                       name, g("SIZE"), g("ALLOC"), g("FREE"), g("FRAG"), g("CAP"), g("HEALTH")
                next
            }
            if (ind == 2) {
                printf "  vdev  class=%-8s %-22s size=%-8s alloc=%-8s free=%-8s frag=%-6s cap=%-6s health=%s\n", \
                       cls, name, g("SIZE"), g("ALLOC"), g("FREE"), g("FRAG"), g("CAP"), g("HEALTH")
            }
        }
        function g(c) { return (c in col && col[c] <= NF) ? $(col[c]) : "-" }
    '
}

# Redundancy shape per allocation class, derived from the same output. A vdev
# named mirror-N / raidzP-N / draid* carries its own shape in the name; a bare
# device name means a single-device top-level vdev.
zpool_class_shape() {
    run_bounded 20 zpool list -v 2>/dev/null | awk '
        NR==1 { next }
        {
            ind = 0
            if (match($0, /^ +/)) ind = RLENGTH
            name = $1
            if (ind == 0) {
                if (pool != "" && (name=="special" || name=="logs" || name=="log" || \
                                   name=="cache" || name=="spare" || name=="spares" || name=="dedup")) {
                    cls = name; next
                }
                if (pool != "") flush()
                pool = name; cls = "data"; delete shape; delete cnt; n = 0
                next
            }
            if (ind == 2) {
                s = "single-device"
                if (name ~ /^mirror/)        s = "mirror"
                else if (name ~ /^raidz/)    s = "raidz"
                else if (name ~ /^draid/)    s = "draid"
                else if (name ~ /^indirect/) s = "indirect (mapping left by a zpool remove)"
                else if (name ~ /^spare-/)   s = "spare-in-use"
                else if (name ~ /^replacing/) s = "replacing"
                k = cls "/" s
                if (!(k in cnt)) { order[++n] = k }
                cnt[k]++
            }
        }
        END { if (pool != "") flush() }
        function flush() {
            for (i = 1; i <= n; i++) {
                k = order[i]
                printf "%s: %s -> %d top-level vdev(s)\n", pool, k, cnt[k]
            }
        }
    '
}

# The block-sizing matrix: recordsize and special_small_blocks side by side, with
# each value''s property source, for every filesystem and volume.
dataset_blocksize_matrix() {
    [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ] || return
    awk -F'\t' '
        !($1 in seen) { seen[$1] = 1; order[++n] = $1 }
        { v[$1 SUBSEP $2] = $3; s[$1 SUBSEP $2] = $4 }
        END {
            fmt = "%-38s %-10s %-13s %-13s %-14s %-8s %-11s %-12s %-14s %-8s %-12s\n"
            printf fmt, "DATASET","TYPE","RECORDSIZE","SPECIAL_SB","COMPRESSION","RATIO","LOGBIAS","SYNC","PRIMARYCACHE","ATIME","VOLBLOCK"
            for (i = 1; i <= n; i++) {
                d = order[i]
                printf fmt, d, g(d,"type"), gs(d,"recordsize"), gs(d,"special_small_blocks"), \
                       gs(d,"compression"), g(d,"compressratio"), gs(d,"logbias"), gs(d,"sync"), \
                       gs(d,"primarycache"), gs(d,"atime"), gs(d,"volblocksize")
            }
        }
        function g(d,p)  { k = d SUBSEP p; return (k in v) ? v[k] : "-" }
        function gs(d,p) { k = d SUBSEP p; if (!(k in v)) return "-"; return v[k] "(" sm(s[k]) ")" }
        function sm(x) {
            if (x == "local")     return "l"
            if (x == "default")   return "d"
            if (x == "temporary") return "t"
            if (x == "received")  return "r"
            if (substr(x,1,9) == "inherited") return "i"
            if (x == "-" || x == "") return "-"
            return substr(x,1,1)
        }
    ' "$_ZGETALL" 2>/dev/null
}

# Space accounting per dataset: where the used space actually sits (dataset vs
# snapshots vs children vs refreservation) plus quota/reservation and origin.
dataset_space_matrix() {
    [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ] || return
    awk -F'\t' '
        !($1 in seen) { seen[$1] = 1; order[++n] = $1 }
        { v[$1 SUBSEP $2] = $3 }
        END {
            fmt = "%-38s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %-9s %s\n"
            printf fmt, "DATASET","USED","REFER","USEDSNAP","USEDDS","USEDCHILD","USEDRESRV","WRITTEN","LOGUSED","QUOTA","REFQUOTA","ORIGIN"
            for (i = 1; i <= n; i++) {
                d = order[i]
                printf fmt, d, g(d,"used"), g(d,"referenced"), g(d,"usedbysnapshots"), \
                       g(d,"usedbydataset"), g(d,"usedbychildren"), g(d,"usedbyrefreservation"), \
                       g(d,"written"), g(d,"logicalused"), g(d,"quota"), g(d,"refquota"), g(d,"origin")
            }
        }
        function g(d,p) { k = d SUBSEP p; return (k in v) ? v[k] : "-" }
    ' "$_ZGETALL" 2>/dev/null
}

# Per-dataset write/read counters from the objset-<objsetid> kstats. This is the
# only place a per-DATASET (not per-pool) byte counter is available without
# instrumenting the application.
objset_kstat_view() {
    local f any=0
    for f in "$KSTAT_DIR"/*/objset-*; do
        [ -f "$f" ] || continue
        [ -r "$f" ] || continue
        any=1
        awk -v src="$f" '
            $1 == "dataset_name" { d = $3 }
            $1 == "writes"       { w = $3 }
            $1 == "nwritten"     { nw = $3 }
            $1 == "reads"        { r = $3 }
            $1 == "nread"        { nr = $3 }
            $1 == "nunlinks"     { nu = $3 }
            $1 == "nunlinked"    { nud = $3 }
            END {
                n = split(src, a, "/"); k = a[n]
                printf "%-38s %-16s writes=%-12s nwritten=%-16s reads=%-12s nread=%-16s nunlinks=%s/%s\n", \
                       (d == "" ? "-" : d), k, w, nw, r, nr, nu, nud
            }
        ' "$f" 2>/dev/null
    done
    [ "$any" = 0 ] && return 1
    return 0
}

# File-size histogram (Tier 2 --filesizes). Buckets chosen at the power-of-two
# steps a recordsize decision moves through.
# filesize_histogram PATH -> bucketed file-size histogram, or a partial one.
#
# The walk is bounded. When the bound is hit the reader must not read the result
# as the whole tree, so the sizes are staged in a file, the walk's exit status is
# read, and a truncated walk says so in its own line. Piping find straight into
# awk would hide this: awk still prints a complete-looking END block from
# whatever it received before find was killed.
filesize_histogram() {
    local p="$1" tmp rc
    tmp="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.fsz.$$")"
    run_bounded "$FILESIZES_SECS" find "$p" -xdev -type f -printf '%s\n' 2>/dev/null > "$tmp"
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        printf '(PARTIAL: the walk hit the %ss bound and was stopped. The buckets below\n' "$FILESIZES_SECS"
        printf ' cover only the files reached by then, in directory order, not the whole tree.\n'
        printf ' Raise it with --filesizes-secs N.)\n'
    fi
    awk '
        {
            n++; t += $1; s = $1
            if      (s == 0)         b = "0"
            else if (s <= 512)       b = "<=512"
            else if (s <= 4096)      b = "<=4K"
            else if (s <= 8192)      b = "<=8K"
            else if (s <= 16384)     b = "<=16K"
            else if (s <= 32768)     b = "<=32K"
            else if (s <= 65536)     b = "<=64K"
            else if (s <= 131072)    b = "<=128K"
            else if (s <= 262144)    b = "<=256K"
            else if (s <= 524288)    b = "<=512K"
            else if (s <= 1048576)   b = "<=1M"
            else if (s <= 4194304)   b = "<=4M"
            else if (s <= 16777216)  b = "<=16M"
            else                     b = ">16M"
            c[b]++; z[b] += s
        }
        END {
            m = split("0 <=512 <=4K <=8K <=16K <=32K <=64K <=128K <=256K <=512K <=1M <=4M <=16M >16M", ord, " ")
            printf "%-8s %14s %20s\n", "BUCKET", "FILES", "APPARENT_BYTES"
            for (i = 1; i <= m; i++) { k = ord[i]; if (k in c) printf "%-8s %14d %20d\n", k, c[k], z[k] }
            printf "%-8s %14d %20d\n", "TOTAL", n, t
        }
    ' "$tmp"
    rm -f "$tmp" 2>/dev/null
}

# =============================================================================
# Report body (MECE domains A..N)
# =============================================================================
run_report() {
    emit_header

    goal zfs   "ZFS present on this host"
    goal pools "pool topology and properties"

    # -- [0] Collection environment -------------------------------------------
    section "Collection environment"
    fact "collector: $COLLECTOR_NAME $VERSION"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root ))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    # [J] zpool iostat, the kstat trees and metaslab_stats are all since-boot.
    _note_boot
    fact "tools:"
    local t
    for t in zfs zpool zdb arcstat arc_summary findmnt df stat lsblk iostat modinfo dkms \
             systemctl journalctl dmesg timeout tar awk find sort head tail nproc free; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"; else printf '        %-12s absent\n' "$t"; fi
    done
    fact "kstat tree ($KSTAT_DIR): $( [ -d "$KSTAT_DIR" ] && echo present || echo 'absent (path not found)' )"
    fact "module parameter dir (/sys/module/zfs/parameters): $( [ -d /sys/module/zfs/parameters ] && echo present || echo 'absent (path not found)' )"
    fact "ZFS present on this host: $( [ "$ZFS_ON_HOST" = 1 ] && echo yes || echo 'no (zfs/zpool commands and kstat tree all absent)' )"
    fact "pools discovered: ${ZPOOL_COUNT:-0} (${ZPOOLS:-none})"
    fact "filesystems+volumes discovered: ${DS_COUNT:-0}"
    fact "snapshots discovered: ${SNAP_COUNT:-0}"
    fact "tiers in this run: Tier0=always sample=$( [ "$OPT_SAMPLE" = 1 ] && echo "on(${SAMPLE_SECS}s)" || echo off ) zdb=$( [ "$OPT_ZDB" = 1 ] && echo on || echo off ) filesizes=$( [ "$OPT_FILESIZES" = 1 ] && echo on || echo off )"
    fact "note: every 'n/a (...)' below names why a value was not obtained"
    fact "note: a tunable printed as 'not present in this zfs build' is a version fact, not a collection failure"

    if [ "$ZFS_ON_HOST" != 1 ]; then
        section "A. ZFS software & kernel module"
        fact "n/a (not applicable: no zfs/zpool command and no $KSTAT_DIR on this host)"
        fact "sections B..L of this collector cover ZFS only and are omitted for the same reason"
        section "M. WhaTap collection-server paths"
        report_whatap_paths
        # This early return is exactly the case the status is for: a host with no
        # ZFS produces a short, tidy-looking report that answers none of the
        # questions this collector exists for. Say so before leaving.
        na zfs "this host does not use ZFS (no zfs/zpool command and no $KSTAT_DIR)"
        na pools "sections B..L cover ZFS only and were omitted"
        emit_status
        emit_footer
        return
    fi

    # -- A. ZFS software & kernel module --------------------------------------
    section "A. ZFS software & kernel module"
    probe "zfs version" zfs version
    read_proc "kmod version (/sys/module/zfs/version)" /sys/module/zfs/version
    read_proc "spl version (/sys/module/spl/version)" /sys/module/spl/version
    probe_pipe "modinfo zfs (selected)" modinfo \
        "modinfo zfs 2>/dev/null | grep -E '^(filename|version|srcversion|license|depends|retpoline):' || true"
    probe "kernel" uname -sr
    read_proc "kernel tainted (/proc/sys/kernel/tainted)" /proc/sys/kernel/tainted
    subsection "packaging"
    if have dpkg-query; then
        # 'spl*' as a PREFIX glob, not '*spl*': the substring form also matches
        # hfsplus / libnss-nisplus / printer-driver-splix. Only rows that are
        # actually installed are kept.
        probe_pipe "dpkg zfs packages" dpkg-query \
            "dpkg-query -W -f='\${Package} \${Version} \${Status}\n' '*zfs*' 'spl*' 'libnvpair*' 'libuutil*' 'libzpool*' 2>/dev/null | grep 'install ok installed' || true"
    elif have rpm; then
        probe_pipe "rpm zfs packages" rpm "rpm -qa 2>/dev/null | grep -iE 'zfs|spl' || true"
    else
        fact "package inventory: n/a (command not found: dpkg-query/rpm)"
    fi
    probe_pipe "dkms status (zfs)" dkms "dkms status 2>/dev/null | grep -i zfs || true"
    subsection "subcommand availability (asked of the installed binary, not inferred from a version string)"
    if have zfs; then
        fact "zfs rewrite subcommand: $(zfs 2>&1 | grep -qE '(^|[[:space:]])rewrite([[:space:]]|$)' && echo present || echo absent)"
        fact "zfs jail/unjail subcommand: $(zfs 2>&1 | grep -qE '(^|[[:space:]])jail([[:space:]]|$)' && echo present || echo absent)"
    else
        fact "zfs subcommands: n/a (command not found: zfs)"
    fi
    if have zpool; then
        # stdout AND stderr to /dev/null, in that order: only the exit code is wanted.
        fact "zpool iostat -r (request-size histogram): $(zpool iostat -r >/dev/null 2>&1 && echo supported || echo 'not supported by this zpool')"
        fact "zpool iostat -w (latency histogram): $(zpool iostat -w >/dev/null 2>&1 && echo supported || echo 'not supported by this zpool')"
        fact "zpool status -t (trim state): $(zpool status -t >/dev/null 2>&1 && echo supported || echo 'not supported by this zpool')"
    fi
    subsection "ZFS systemd units & pool cache"
    if have systemctl; then
        local u any=0
        for u in zfs.target zfs-import-cache zfs-import-scan zfs-mount zfs-share zfs-zed zfs-volume-wait zfs-load-key; do
            unit_loaded "$u.service" || [ "$u" = "zfs.target" ] || continue
            any=1
            fact "$u: active=$(systemctl is-active "$u" 2>/dev/null) enabled=$(systemctl is-enabled "$u" 2>/dev/null)"
        done
        [ "$any" = 0 ] && fact "no zfs-* units loaded"
    else
        fact "zfs units: n/a (command not found: systemctl)"
    fi
    fact "/etc/zfs/zpool.cache: $( [ -e /etc/zfs/zpool.cache ] && echo "present ($(wc -c < /etc/zfs/zpool.cache 2>/dev/null | tr -d ' ') bytes, mtime $(date -u -r /etc/zfs/zpool.cache +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a))" || echo 'absent (path not found)' )"

    # -- B. ZFS module parameters ---------------------------------------------
    # The runtime value of a tunable and the value persisted in modprobe.d can
    # differ (a live `echo > /sys/module/...` is lost on reboot; a modprobe.d
    # entry added after boot is not yet active). Both are reported.
    section "B. ZFS module parameters (runtime + persisted)"
    subsection "allocation class routing"
    param zfs_special_class_metadata_reserve_pct
    param zfs_ddt_data_is_special
    param zfs_user_indirect_is_special
    param zfs_dmu_offset_next_sync
    subsection "block size limits"
    param zfs_max_recordsize
    param zfs_default_bs
    param zfs_default_ibs
    param zvol_volmode
    subsection "transaction group & dirty-data write throttle"
    param zfs_txg_timeout
    param zfs_txg_history
    param zfs_dirty_data_max
    param zfs_dirty_data_max_max
    param zfs_dirty_data_max_percent
    param zfs_dirty_data_sync_percent
    param zfs_delay_min_dirty_percent
    param zfs_delay_scale
    param zfs_vdev_async_write_active_min_dirty_percent
    param zfs_vdev_async_write_active_max_dirty_percent
    subsection "metaslab & allocator"
    param metaslab_df_free_pct
    param metaslab_df_alloc_threshold
    param metaslab_force_ganging
    param metaslab_force_ganging_pct
    param metaslab_aliquot
    param metaslab_debug_load
    param metaslab_debug_unload
    param metaslab_unload_delay
    param metaslab_preload_enabled
    param zfs_metaslab_switch_threshold
    param zfs_metaslab_fragmentation_threshold
    param zfs_mg_fragmentation_threshold
    param zfs_mg_noalloc_threshold
    param zfs_metaslab_sm_blksz_no_log
    param zfs_metaslab_sm_blksz_with_log
    subsection "ZIL / sync write path"
    param zil_slog_bulk
    param zil_nocacheflush
    param zfs_immediate_write_sz
    param zfs_commit_timeout_pct
    subsection "ARC / L2ARC"
    param zfs_arc_max
    param zfs_arc_min
    param zfs_arc_meta_limit
    param zfs_arc_meta_limit_percent
    param zfs_arc_meta_balance
    param zfs_arc_dnode_limit_percent
    param zfs_compressed_arc_enabled
    param zfs_abd_scatter_enabled
    param l2arc_write_max
    param l2arc_write_boost
    param l2arc_noprefetch
    param l2arc_rebuild_enabled
    param l2arc_exclude_special
    subsection "prefetch & vdev aggregation"
    param zfs_prefetch_disable
    param zfetch_max_distance
    param zfetch_max_streams
    param zfs_vdev_aggregation_limit
    param zfs_vdev_aggregation_limit_non_rotating
    param zfs_vdev_read_gap_limit
    param zfs_vdev_write_gap_limit
    subsection "scrub / resilver / trim"
    param zfs_scan_vdev_limit
    param zfs_resilver_min_time_ms
    param zfs_scrub_min_time_ms
    param zfs_trim_extent_bytes_min
    param zfs_trim_txg_batch
    param zfs_rebuild_scrub_enabled
    subsection "all /sys/module/zfs/parameters (name = value)"
    dump_param_dir /sys/module/zfs/parameters
    subsection "all /sys/module/spl/parameters (name = value)"
    dump_param_dir /sys/module/spl/parameters
    subsection "persisted module options (/etc/modprobe.d/*zfs*, verbatim)"
    local mp any_mp=0
    for mp in /etc/modprobe.d/*zfs* /etc/modprobe.d/*spl*; do
        [ -f "$mp" ] || continue
        any_mp=1
        fact "$mp:"
        dump_file "$mp" 200
    done
    [ "$any_mp" = 0 ] && fact "no /etc/modprobe.d/*zfs* or *spl* file (path not found)"
    probe_pipe "kernel cmdline zfs options" cat "tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -iE 'zfs|spl' || true"

    # -- C. Pool topology & allocation classes --------------------------------
    section "C. Pool topology & allocation classes"
    probe "zpool list -v (raw)" zpool list -v
    subsection "per-top-level-vdev usage by allocation class (derived from zpool list -v)"
    local cv; cv="$(zpool_class_view)"
    if [ -n "$cv" ]; then printf '%s\n' "$cv" | while IFS= read -r _l; do blk "$_l"; done
    else fact "n/a (empty output or layout not parsed — see the raw zpool list -v above)"; fi
    subsection "redundancy shape per allocation class (derived from zpool list -v)"
    local cs; cs="$(zpool_class_shape)"
    if [ -n "$cs" ]; then printf '%s\n' "$cs" | while IFS= read -r _l; do blk "$_l"; done
    else fact "n/a (empty output or layout not parsed)"; fi
    subsection "zpool status"
    # -v and -t combined in one call: -t only annotates the same vdev tree with
    # trim state, so two separate calls would print the tree twice.
    if zpool status -vt >/dev/null 2>&1; then
        probe "zpool status -vt (verbose + trim state per vdev)" zpool status -vt
    else
        probe "zpool status -v" zpool status -v
        probe "zpool status -t (trim state per vdev)" zpool status -t
    fi
    probe "zpool status -x (health summary)" zpool status -x
    subsection "metaslab / allocator counters (global kstat)"
    read_proc "metaslab_stats" "$KSTAT_DIR/metaslab_stats"
    subsection "vdev device paths"
    local p
    for p in $ZPOOLS; do
        probe_pipe "$p: leaf device paths (zpool status -P)" zpool \
            "zpool status -PL '$p' 2>/dev/null | awk 'NF>=2 && \$1 ~ /^\\// {print \$1\"  \"\$2}' || true"
    done
    [ -z "$ZPOOLS" ] && fact "leaf device paths: n/a (no pool discovered)"

    # -- D. Pool properties, features & capacity ------------------------------
    section "D. Pool properties, features & capacity"
    probe "zpool list" zpool list
    for p in $ZPOOLS; do
        subsection "$p"
        probe "zpool get all $p" zpool get all "$p"
    done
    [ -z "$ZPOOLS" ] && fact "zpool get all: n/a (no pool discovered)"
    subsection "dataset space overview (zfs list -o space)"
    probe_t 60 "zfs list -o space" zfs list -o space

    # -- E. Dataset block size & compression ----------------------------------
    # recordsize and special_small_blocks are printed adjacently and each value
    # carries its property source, because an inherited or default value and a
    # deliberately set one are different facts.
    section "E. Dataset block size & compression"
    fact "datasets (filesystem+volume): ${DS_COUNT:-0}"
    if has_property special_small_blocks; then
        fact "special_small_blocks property: reported by this zfs build"
    else
        fact "special_small_blocks property: not reported by this zfs build (or no dataset enumerated)"
    fi
    fact "property source marker: l=local d=default i=inherited t=temporary r=received -=absent"
    subsection "block-size / compression matrix"
    local bm; bm="$(dataset_blocksize_matrix)"
    if [ -n "$bm" ]; then printf '%s\n' "$bm" | while IFS= read -r _l; do blk "$_l"; done
    else fact "n/a (no dataset property dump — zfs get returned nothing)"; fi
    subsection "volumes (volblocksize is set at creation time)"
    probe_t 60 "zfs list -t volume" zfs list -t volume -o name,volsize,volblocksize,used,referenced,compression,compressratio,sync,logbias
    subsection "non-default (locally set) properties, per dataset"
    if [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ]; then
        probe_pipe "locally set properties" awk \
            "awk -F'\t' '\$4==\"local\" {printf \"%-38s %-28s %s\n\", \$1, \$2, \$3}' '$_ZGETALL' || true"
    else
        fact "locally set properties: n/a (no dataset property dump)"
    fi
    subsection "compression runtime counters (global kstats)"
    read_proc "zstd" "$KSTAT_DIR/zstd"

    # -- F. Snapshots, clones & space accounting ------------------------------
    section "F. Snapshots, clones & space accounting"
    subsection "space accounting matrix (where used space sits)"
    local sm_; sm_="$(dataset_space_matrix)"
    if [ -n "$sm_" ]; then printf '%s\n' "$sm_" | while IFS= read -r _l; do blk "$_l"; done
    else fact "n/a (no dataset property dump)"; fi
    subsection "snapshot inventory"
    fact "snapshot count (all pools): ${SNAP_COUNT:-0}"
    if [ -n "$_ZSNAP" ] && [ -s "$_ZSNAP" ]; then
        # counts are emitted as a bare numeric column so `sort -k2,2nr` orders
        # them numerically (a formatted "snapshots=N" field would sort as text)
        probe_pipe "snapshot count per dataset (top 30 by count)" awk \
            "printf '%-52s %10s %20s\n' DATASET SNAPSHOTS USED_BYTES; awk -F'\t' '{split(\$1,a,\"@\"); c[a[1]]++; u[a[1]]+=\$2} END{for(d in c) printf \"%-52s %10d %20d\n\", d, c[d], u[d]}' '$_ZSNAP' | sort -k2,2nr | head -n 30 || true"
        local _old _new
        _old="$(awk -F'\t' 'NR==1{m=$3;s=$1} $3+0<m+0{m=$3;s=$1} END{if(NR)printf "%s\t%s", s, m}' "$_ZSNAP" 2>/dev/null)"
        _new="$(awk -F'\t' 'NR==1{m=$3;s=$1} $3+0>m+0{m=$3;s=$1} END{if(NR)printf "%s\t%s", s, m}' "$_ZSNAP" 2>/dev/null)"
        if [ -n "$_old" ]; then
            fact "oldest snapshot: $(printf '%s' "$_old" | cut -f1) (creation $(_epoch_iso "$(printf '%s' "$_old" | cut -f2)"))"
            fact "newest snapshot: $(printf '%s' "$_new" | cut -f1) (creation $(_epoch_iso "$(printf '%s' "$_new" | cut -f2)"))"
        else
            fact "oldest / newest snapshot: n/a (empty output)"
        fi
        probe_pipe "snapshots holding a user hold (userrefs > 0)" awk \
            "awk -F'\t' '\$4+0>0 {n++; if(n<=20) printf \"%s userrefs=%s\n\", \$1, \$4} END{printf \"total_with_holds=%d\n\", n+0}' '$_ZSNAP' || true"
        probe_pipe "snapshots with a clone attached (first 30)" awk \
            "awk -F'\t' '\$5!=\"-\" && \$5!=\"\" {n++; if(n<=30) printf \"%s  clones=%s\n\", \$1, \$5} END{printf \"total_snapshots_with_clones=%d\n\", n+0}' '$_ZSNAP' || true"
    else
        fact "snapshot detail: n/a (zfs list -t snapshot returned nothing or timed out)"
    fi
    subsection "clones (the filesystem/volume side: which dataset has an origin)"
    if [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ]; then
        probe_pipe "clone origins" awk \
            "awk -F'\t' '\$2==\"origin\" && \$3!=\"-\" {printf \"%-38s origin=%s\n\", \$1, \$3}' '$_ZGETALL' || true"
        fact "note: the reverse mapping (which snapshot is pinned by a clone) is in the snapshot inventory above, because 'clones' is a snapshot property"
    else
        fact "clones: n/a (no dataset property dump)"
    fi
    subsection "block cloning / block reference table (global kstat)"
    read_proc "brtstats" "$KSTAT_DIR/brtstats"
    subsection "pool checkpoint & bookmarks"
    for p in $ZPOOLS; do
        probe_pipe "$p: checkpoint" zpool "zpool get -H -o value checkpoint '$p' 2>/dev/null || true"
    done
    probe_t 60 "bookmarks" zfs list -t bookmark

    # -- G. ARC / L2ARC / memory ----------------------------------------------
    section "G. ARC / L2ARC / memory"
    read_proc "arcstats (verbatim)" "$KSTAT_DIR/arcstats"
    probe_t 30 "arc_summary" arc_summary
    probe_pipe_t 30 "arcstat (single 1s sample)" arcstat "arcstat 1 1 2>/dev/null || true"
    read_proc "dbufstats" "$KSTAT_DIR/dbufstats"
    read_proc "abdstats" "$KSTAT_DIR/abdstats"
    read_proc "zfetchstats" "$KSTAT_DIR/zfetchstats"
    read_proc "dnodestats" "$KSTAT_DIR/dnodestats"
    read_proc "vdev_cache_stats" "$KSTAT_DIR/vdev_cache_stats"
    subsection "host memory context for the ARC values above"
    read_proc "meminfo" /proc/meminfo
    fact "/proc/spl/kmem/slab: $( [ -e /proc/spl/kmem/slab ] && echo 'present (not inlined here — included in --bundle)' || echo 'absent (path not found)' )"

    # -- H. Write path: transaction groups & ZIL ------------------------------
    # The txgs kstat is a ring buffer of the last zfs_txg_history transaction
    # groups with, per txg, the bytes dirtied and the time spent in each state.
    # When zfs_txg_history is 0 the file exists but stays empty (see section B).
    section "H. Write path: transaction groups & ZIL"
    local kd pn
    for kd in "$KSTAT_DIR"/*/; do
        [ -d "$kd" ] || continue
        pn="$(basename "$kd")"
        subsection "pool $pn"
        read_kstat_tail "txgs (column header + last 150 records)" "$kd/txgs" 150
        read_proc "dmu_tx_assign (transaction assign histogram)" "$kd/dmu_tx_assign"
        read_proc "zil" "$kd/zil"
        read_proc "state" "$kd/state"
        read_proc "iostats" "$kd/iostats"
        read_proc "reads" "$kd/reads"
        read_proc "multihost" "$kd/multihost"
    done
    if [ ! -d "$KSTAT_DIR" ]; then fact "per-pool kstats: n/a (path not found: $KSTAT_DIR)"; fi
    subsection "global write-path kstats"
    read_proc "dmu_tx" "$KSTAT_DIR/dmu_tx"
    read_proc "zil (global)" "$KSTAT_DIR/zil"
    fact "note: the tunables that govern the values above (zfs_txg_timeout, zfs_txg_history, zfs_dirty_data_*, zil_slog_bulk) are in section B"
    subsection "separate log (SLOG) vdev presence"
    local shp; shp="$(zpool_class_shape 2>/dev/null | grep -E '/(logs|log)/' || true)"
    if [ -n "$shp" ]; then printf '%s\n' "$shp" | while IFS= read -r _l; do blk "$_l"; done
    else fact "no vdev in the logs allocation class was parsed from zpool list -v"; fi

    # -- I. Per-dataset I/O counters (objset kstats) --------------------------
    section "I. Per-dataset I/O counters (objset kstats)"
    fact "source: $KSTAT_DIR/<pool>/objset-<objsetid>; counters are cumulative since pool import"
    local ov; ov="$(objset_kstat_view)"
    if [ -n "$ov" ]; then printf '%s\n' "$ov" | while IFS= read -r _l; do blk "$_l"; done
    else fact "n/a (no objset-* kstat file found or readable under $KSTAT_DIR)"; fi
    subsection "other kstat entries present but not inlined above"
    if [ -d "$KSTAT_DIR" ]; then
        # dbufs is deliberately never read: it enumerates every dbuf in the ARC
        # and can be very large and lock-heavy on a busy host.
        probe_pipe "kstat inventory" find \
            "find '$KSTAT_DIR' -maxdepth 2 \\( -type f -o -type d \\) 2>/dev/null | sed \"s#^$KSTAT_DIR/*##\" | grep -vE '^(arcstats|dbufstats|abdstats|zfetchstats|dnodestats|vdev_cache_stats|dmu_tx|zil|dbufs|dbgmsg|metaslab_stats|zstd|brtstats|fm|)\$' | grep -vE '/(txgs|zil|state|iostats|reads|multihost|dmu_tx_assign)\$' | grep -vE '/objset-' | sort || true"
        fact "note: $KSTAT_DIR/dbufs is present on most builds and is deliberately not read (it enumerates every ARC dbuf)"
    else
        fact "kstat inventory: n/a (path not found: $KSTAT_DIR)"
    fi

    # -- J. I/O request size & latency distribution ---------------------------
    # zpool iostat with no interval prints cumulative-since-boot values from
    # kstats — instant and load-free. -r is the request-SIZE histogram (the
    # distribution an on-disk block size question turns on); -w is the latency
    # histogram. An interval sample (--sample) shows current behaviour instead
    # of the whole-uptime average.
    section "J. I/O request size & latency distribution"
    subsection "cumulative since boot (instant kstat read)"
    probe "zpool iostat -v" zpool iostat -v
    probe "zpool iostat -lv (latency)" zpool iostat -lv
    probe "zpool iostat -qv (queue depth, instantaneous)" zpool iostat -qv
    probe_pipe "zpool iostat -r (request size histogram, first 400 lines)" zpool \
        "zpool iostat -r 2>/dev/null | head -n 400 || true"
    probe_pipe "zpool iostat -w (latency histogram, first 400 lines)" zpool \
        "zpool iostat -w 2>/dev/null | head -n 400 || true"
    subsection "interval sample (--sample)"
    if [ "$OPT_SAMPLE" = 1 ]; then
        local st=$((SAMPLE_SECS * 3 + 30))
        progress "sampling zpool iostat -lqv over ${SAMPLE_SECS}s ..."
        probe_pipe_t "$st" "zpool iostat -lqv ${SAMPLE_SECS} 2 (second block is the interval)" zpool \
            "zpool iostat -lqv ${SAMPLE_SECS} 2 2>/dev/null || true"
        progress "sampling zpool iostat -r over ${SAMPLE_SECS}s ..."
        probe_pipe_t "$st" "zpool iostat -r ${SAMPLE_SECS} 2 (first 500 lines)" zpool \
            "zpool iostat -r ${SAMPLE_SECS} 2 2>/dev/null | head -n 500 || true"
        progress "sampling zpool iostat -w over ${SAMPLE_SECS}s ..."
        probe_pipe_t "$st" "zpool iostat -w ${SAMPLE_SECS} 2 (first 500 lines)" zpool \
            "zpool iostat -w ${SAMPLE_SECS} 2 2>/dev/null | head -n 500 || true"
        progress "sampling arcstat over ${SAMPLE_SECS}s ..."
        probe_pipe_t "$st" "arcstat 1 ${SAMPLE_SECS}" arcstat "arcstat 1 ${SAMPLE_SECS} 2>/dev/null || true"
        # Block layer, bucketed. J's `iostat -x` is the since-boot average and
        # says nothing about now; these buckets do. Both are kept because the
        # since-boot one still serves device-to-device comparison over the same
        # span. The first block printed here is the since-boot one again — the
        # interval blocks are the ones after it.
        local ic=$(( SAMPLE_SECS * 3 / IOSTAT_BUCKET + 1 ))
        [ "$ic" -lt 2 ] && ic=2
        progress "sampling iostat -x in ${IOSTAT_BUCKET}s buckets over $(( (ic - 1) * IOSTAT_BUCKET ))s ..."
        probe_pipe_t $(( ic * IOSTAT_BUCKET + 30 )) \
            "iostat -x ${IOSTAT_BUCKET} ${ic} (first block is since boot; the rest are ${IOSTAT_BUCKET}s intervals)" \
            iostat "iostat -x ${IOSTAT_BUCKET} ${ic} 2>/dev/null || true"
        progress "sampling txgs delta over ${SAMPLE_SECS}s ..."
        for kd in "$KSTAT_DIR"/*/; do
            [ -d "$kd" ] || continue
            pn="$(basename "$kd")"
            [ -r "$kd/txgs" ] || continue
            local before after
            before="$(wc -l < "$kd/txgs" 2>/dev/null | tr -d ' ')"
            if have sleep; then sleep "$SAMPLE_SECS"; fi
            after="$(tail -n 20 "$kd/txgs" 2>/dev/null)"
            fact "pool $pn: txgs records before sample=$before; last 20 records after a ${SAMPLE_SECS}s wait:"
            printf '%s\n' "$after" | while IFS= read -r _l; do blk "$_l"; done
            break   # one pool's wait is enough; the ring buffer is per pool but the wait is shared
        done
    else
        fact "n/a (not applicable: --sample not given)"
    fi

    # -- K. Underlying block devices ------------------------------------------
    section "K. Underlying block devices"
    probe "lsblk" lsblk -o NAME,KNAME,TYPE,SIZE,ROTA,PHY-SEC,LOG-SEC,SCHED,MOUNTPOINT,MODEL
    subsection "queue settings per block device (/sys/block/*/queue)"
    local bdev bn qf line
    for bdev in /sys/block/*; do
        [ -d "$bdev/queue" ] || continue
        bn="$(basename "$bdev")"
        case "$bn" in loop*|ram*|zram*|dm-*) continue ;; esac
        line="$bn:"
        for qf in rotational scheduler nr_requests read_ahead_kb max_sectors_kb \
                  physical_block_size logical_block_size optimal_io_size \
                  discard_granularity write_cache nomerges; do
            if [ -r "$bdev/queue/$qf" ]; then
                line="$line $qf=$(head -n1 "$bdev/queue/$qf" 2>/dev/null | tr -d '\n')"
            fi
        done
        blk "$line"
    done
    probe_pipe "device id links (/dev/disk/by-id)" ls "ls -l /dev/disk/by-id 2>/dev/null | awk 'NF>=9 {print \$9\" -> \"\$NF}' || true"
    probe_pipe "iostat -x (cumulative since boot)" iostat "iostat -x 2>/dev/null | head -n 60 || true"
    fact "multipath: $( have multipath && echo 'multipath command present (multipath -ll is included in --bundle)' || echo 'n/a (command not found: multipath)' )"

    # -- L. Pool events, errors & maintenance ---------------------------------
    section "L. Pool events, errors & maintenance"
    # stderr is folded into the output (2>&1) on purpose: for an unprivileged uid
    # these two write "permission denied" to stderr and still print their header
    # line to stdout, so discarding stderr would leave a header that reads like
    # "no events" / "no history". Folding it in keeps the reason visible.
    # The tally comes before the last-100 list on purpose. The list answers "what
    # is happening now", the tally answers "when did this class start and when did
    # it stop" — and the second question is the one a recent-only view cannot
    # answer. A host with no deadman event this month reads identically whether it
    # never had one or whether they ended in July. This uses the short form of
    # `zpool events` (one line per event), not -v, so it stays cheap here; the
    # per-event detail is bundled by zevents_split.
    probe_pipe_t 180 "zpool events: tally over the whole ring buffer (count, first, last)" zpool \
        "zpool events 2>/dev/null | awk '
            BEGIN { split(\"Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec\", mn, \" \")
                    for (i = 1; i <= 12; i++) M[mn[i]] = i }
            NF >= 5 && \$3 ~ /^[0-9][0-9][0-9][0-9]\$/ && (\$1 in M) {
                d = sprintf(\"%04d-%02d-%02d\", \$3, M[\$1], \$2); t++
                n[\$5]++
                if (!(\$5 in f) || d < f[\$5]) f[\$5] = d
                if (!(\$5 in l) || d > l[\$5]) l[\$5] = d
            }
            END {
                if (t == 0) { print \"(no event parsed)\"; exit }
                printf \"%10s  %-10s %-10s  %s\n\", \"COUNT\", \"FIRST\", \"LAST\", \"CLASS\"
                for (c in n) printf \"%10d  %-10s %-10s  %s\n\", n[c], f[c], l[c], c
                printf \"%10d  %-10s %-10s  %s\n\", t, \"\", \"\", \"(total)\"
            }' | sort -rn || true"
    fact "note: the tally above covers the whole ring buffer, whose depth is set by zfs_zevent_len_max (section B)"
    probe_pipe_t 60 "zpool events (last 100, stderr folded in)" zpool "zpool events 2>&1 | tail -n 100 || true"
    for p in $ZPOOLS; do
        probe_pipe_t 60 "$p: zpool history (last 200, stderr folded in)" zpool "zpool history '$p' 2>&1 | tail -n 200 || true"
    done
    [ -z "$ZPOOLS" ] && fact "zpool history: n/a (no pool discovered)"
    fact "note: 'zpool events' and 'zpool history' read /dev/zfs; the uid of this run is in section [0]"
    subsection "fault management kstat"
    read_proc "fm" "$KSTAT_DIR/fm"
    subsection "kernel messages"
    probe_pipe "dmesg (zfs/spl/zio/txg lines, last 100)" dmesg \
        "dmesg 2>/dev/null | grep -iE 'zfs|spl:|zio|txg|ZIL|arc_' | tail -n 100 || true"
    read_proc "spl debug ring (dbgmsg, last 200 lines)" "$KSTAT_DIR/dbgmsg" 200
    subsection "journal for zfs units (last ${OPT_HOURS}h, bounded)"
    if have journalctl; then
        local u2
        for u2 in zfs-zed zfs-import-cache zfs-import-scan zfs-mount zfs-share; do
            unit_loaded "$u2.service" || continue
            local jo
            jo="$(journalctl -u "$u2.service" -p warning --since "${OPT_HOURS} hours ago" -n 30 --no-pager 2>/dev/null)"
            if [ -n "$jo" ]; then fact "$u2.service (last 30 at warning+):"; printf '%s\n' "$jo" | while IFS= read -r _l; do blk "$_l"; done
            else fact "$u2.service: no warning+ entry in the last ${OPT_HOURS}h"; fi
        done
    else
        fact "journal: n/a (command not found: journalctl)"
    fi
    subsection "scheduled maintenance & snapshot automation"
    probe_pipe "systemd timers matching zfs/sanoid/zrepl" systemctl \
        "systemctl list-timers --all --no-pager 2>/dev/null | grep -iE 'zfs|sanoid|syncoid|zrepl|scrub|trim' || true"
    probe_pipe "cron entries matching zfs/sanoid/zrepl" ls \
        "ls -1 /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.monthly 2>/dev/null | grep -iE 'zfs|sanoid|syncoid|zrepl' || true"
    local cfgf
    for cfgf in /etc/sanoid/sanoid.conf /etc/zfs/zed.d/zed.rc /etc/zrepl/zrepl.yml; do
        fact "$cfgf: $( [ -e "$cfgf" ] && echo present || echo 'absent (path not found)' )"
    done
    probe_pipe "zed / replication processes" ps \
        "ps -eo comm,args 2>/dev/null | grep -iE 'zed|sanoid|syncoid|zrepl|zfs (send|recv|receive)' | grep -v grep || true"

    # -- M. WhaTap collection-server paths -> dataset mapping -----------------
    section "M. WhaTap collection-server paths -> dataset mapping"
    report_whatap_paths

    # -- N. Deep block & metaslab statistics (opt-in) -------------------------
    section "N. Deep block & metaslab statistics (opt-in)"
    if [ "$OPT_ZDB" = 1 ]; then
        if ! have zdb; then
            fact "zdb: n/a (command not found: zdb)"
        else
            # zdb opens the pool's devices directly. For an unprivileged uid it
            # exits with "can't open '<pool>': Permission denied"; stderr is
            # folded into the output below so that message is visible verbatim
            # instead of appearing as an empty result.
            fact "uid for this run: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root )) — zdb opens the pool devices directly"
            for p in $ZPOOLS; do
                subsection "$p (zdb)"
                warn "[Tier2] zdb -C $p — reads the pool configuration"
                progress "zdb -C $p ..."
                probe_pipe_t 120 "zdb -C $p (config; per-vdev ashift and allocation class)" zdb \
                    "zdb -C '$p' 2>&1 | head -n 400 || true"
                warn "[Tier2] zdb -Lbbbs $p — traverses pool metadata; takes minutes on a large pool and reads the data disks"
                progress "zdb -Lbbbs $p (block statistics; this is the long one) ..."
                # zdb writes a carriage-return progress line to stderr while it
                # traverses ("... estimated time remaining ..."). stderr is kept
                # (it carries the permission error for a non-root uid), but the
                # progress is split on \r and dropped so it does not flood the
                # report as one very long line.
                probe_pipe_t 1800 "zdb -Lbbbs $p (block/psize/lsize histogram, measured compression; first 500 lines)" zdb \
                    "zdb -Lbbbs '$p' 2>&1 | tr '\r' '\n' | grep -v 'estimated time remaining' | head -n 500 || true"
                warn "[Tier2] zdb -mm $p — loads metaslab space maps"
                progress "zdb -mm $p (metaslab free-space histograms) ..."
                probe_pipe_t 1800 "zdb -mm $p (metaslab free-space histograms; first 500 lines)" zdb \
                    "zdb -mm '$p' 2>&1 | head -n 500 || true"
            done
            [ -z "$ZPOOLS" ] && fact "zdb: n/a (no pool discovered)"
        fi
    else
        fact "zdb block/metaslab statistics: n/a (not applicable: --zdb not given)"
    fi
    subsection "file-size histogram (--filesizes)"
    if [ "$OPT_FILESIZES" = 1 ]; then
        local fp="$FILESIZES_PATH"
        [ -z "$fp" ] && fp="$YARDBASE"
        if [ -z "$fp" ]; then
            fact "n/a (no path given and yardbase not resolved — pass --filesizes=PATH)"
        elif [ ! -d "$fp" ]; then
            fact "n/a (path not found: $fp)"
        elif ! find /dev/null -maxdepth 0 -printf '' 2>/dev/null; then
            fact "n/a (find -printf not supported by this build; GNU find is needed)"
        else
            warn "file-size histogram: walking $fp — metadata-only tree read, bounded to ${FILESIZES_SECS}s (--no-filesizes to skip)"
            progress "walking $fp for the file-size histogram ..."
            fact "path: $fp (single filesystem, -xdev)"
            local fh; fh="$(filesize_histogram "$fp")"
            if [ -n "$fh" ]; then printf '%s\n' "$fh" | while IFS= read -r _l; do blk "$_l"; done
            else fact "n/a (empty output or timed out: 600s)"; fi
        fi
    else
        fact "n/a (skipped: --no-filesizes was given. This histogram is on by default)"
    fi

    if [ "$ZFS_ON_HOST" = 1 ]; then got zfs
    else na zfs "this host does not use ZFS"; fi
    if [ "$ZPOOL_COUNT" -gt 0 ] 2>/dev/null; then got pools
    elif [ "$ZFS_ON_HOST" = 1 ]; then na pools "zpool list returned no pools (none imported on this host)"
    else na pools "sections B..L cover ZFS only"; fi

    emit_status
    emit_footer
}

# Section M body — also used in the "no ZFS on this host" short path.
report_whatap_paths() {
    fact "WHATAP_HOME: ${WHOME:-n/a (not resolved)}"
    fact "WHATAP_HOME resolved by: $WHOME_SRC"
    fact "yardbase: ${YARDBASE:-n/a (not resolved from yard.conf or WHATAP_HOME/yardbase)}"
    fact "note: WhaTap conf/*.conf, JVM flags, ports and service logs are collected by collect-collserver.sh, not here"
    subsection "path -> filesystem -> dataset"
    local paths p ex ft sr pool
    paths="$WHOME $YARDBASE"
    [ -n "$WHOME" ] && paths="$paths $WHOME/logs $WHOME/conf $WHOME/db $WHOME/keeperbase $WHOME/logsink"
    if [ -z "$WHOME" ] && [ -z "$YARDBASE" ]; then
        fact "n/a (WHATAP_HOME and yardbase both unresolved: no running whatap JVM, no whatap systemd unit, and this script is not in \$WHATAP_HOME/bin — pass --home DIR to map paths anyway)"
        fact "note: the ZFS sections of this report do not depend on WHATAP_HOME — only this path-to-dataset mapping does"
        return
    fi
    local seen=""
    for p in $paths; do
        [ -n "$p" ] || continue
        case " $seen " in *" $p "*) continue ;; esac
        seen="$seen $p"
        if [ -e "$p" ]; then ex="present"; else ex="path not found"; fi
        ft="$(fstype_of "$p")"; [ -z "$ft" ] && ft="n/a"
        sr="$(source_of "$p")"; [ -z "$sr" ] && sr="n/a"
        # The pool is the part of the dataset name before the first '/', but only
        # when the mount source IS a dataset. Deriving it unconditionally turns a
        # device path (/dev/vda2) into an empty pool and "n/a" into "n".
        if [ "$ft" = "zfs" ]; then pool="${sr%%/*}"; else pool="n/a (not zfs)"; fi
        blk "$(printf '%-42s %-14s fstype=%-8s dataset=%-30s pool=%s' "$p" "$ex" "$ft" "$sr" "$pool")"
    done
    subsection "dataset properties for the paths above"
    local done_ds=""
    for p in $paths; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || continue
        ft="$(fstype_of "$p")"
        [ "$ft" = "zfs" ] || continue
        sr="$(source_of "$p")"
        [ -n "$sr" ] || continue
        case " $done_ds " in *" $sr "*) continue ;; esac
        done_ds="$done_ds $sr"
        fact "$sr (mounted at or containing $p):"
        local pr v
        for pr in type mounted mountpoint recordsize special_small_blocks compression compressratio \
                  logbias sync primarycache secondarycache atime relatime dedup checksum copies \
                  quota refquota reservation refreservation used available referenced \
                  usedbysnapshots usedbydataset usedbychildren logicalused written snapdir canmount; do
            v="$(zprop "$sr" "$pr")"
            [ -z "$v" ] && v="n/a (property not reported for this dataset)"
            blk "$(printf '%-24s %s' "$pr" "$v")"
        done
    done
    [ -z "$done_ds" ] && fact "no WhaTap path resolved to a ZFS dataset"
    subsection "capacity as the filesystem reports it"
    for p in $paths; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || continue
        probe "df -h $p" df -h "$p"
    done
    subsection "data directory markers"
    if [ -n "$YARDBASE" ] && [ -d "$YARDBASE" ]; then
        fact "YARDB_LOCK: $( [ -e "$YARDBASE/YARDB_LOCK" ] && echo "present (mtime $(date -u -r "$YARDBASE/YARDB_LOCK" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown))" || echo 'absent' )"
        probe "yardbase entries (depth 1)" ls -1 "$YARDBASE"
    else
        fact "YARDB_LOCK / yardbase entries: n/a (yardbase not present)"
    fi
}

# zevents_split DESTDIR -> split `zpool events -v` into a tally and a window.
#
# The zevent ring buffer holds every event back to pool creation when
# zfs_zevent_len_max is large (it is INT_MAX on the XLSMART hosts), so the -v
# dump is hundreds of MB and cannot travel or live in a repo. But truncating it
# to a recent window loses the one thing the buffer is good for: **when a class
# started and when it stopped**. A host with zero deadman events in the last
# month reads the same whether it never had any or whether they ended in July.
#
# So the stream is read ONCE and split three ways:
#   zpool-events-tally.tsv     class x date x vdev, counted over the whole buffer
#   zpool-events-overview.tsv  class, count, first date, last date
#   zpool-events-v.txt         full detail, but only for the last OPT_EVENT_DAYS
#
# Reading it once matters: a second pass costs the same minutes again and sees a
# buffer that has moved.
zevents_split() {
    local d="$1" cut=""
    if [ "$OPT_EVENT_DAYS" -gt 0 ] 2>/dev/null; then
        # No GNU date -> cut stays empty -> the detail window is "everything".
        # That is the old behaviour, which is safe, and the tally still works.
        cut="$(date -u -d "$OPT_EVENT_DAYS days ago" +%Y-%m-%d 2>/dev/null || true)"
    fi
    progress "zfs: reading the zevent ring buffer (tally over all of it, detail for ${OPT_EVENT_DAYS}d) ..."
    run_bounded 600 zpool events -v 2>/dev/null | awk -v CUT="$cut" \
        -v TALLY="$d/zpool-events-tally.tsv" \
        -v OVER="$d/zpool-events-overview.tsv" \
        -v DETAIL="$d/zpool-events-v.txt" '
        BEGIN {
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
            for (i = 1; i <= 12; i++) M[mn[i]] = i
            kept = 0; seen = 0
        }
        # An event header looks like:
        #   Aug 13 2024 00:44:15.230790956 ereport.fs.zfs.deadman
        # Everything indented under it belongs to that event.
        function flush(  key) {
            if (!inev) return
            key = cls "\t" date "\t" vdev
            cnt[key]++
            n[cls]++
            if (!(cls in first) || date < first[cls]) first[cls] = date
            if (!(cls in last)  || date > last[cls])  last[cls]  = date
            if (keep) { printf "%s", buf > DETAIL; kept++ }
            inev = 0
        }
        /^[A-Z][a-z][a-z] +[0-9]+ [0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\./ {
            flush()
            date = sprintf("%04d-%02d-%02d", $3, M[$1], $2)
            cls = $5; vdev = "-"; seen++
            keep = (CUT == "" || date >= CUT)
            buf = $0 "\n"; inev = 1
            next
        }
        inev {
            buf = buf $0 "\n"
            if ($1 == "vdev_path") { vdev = $3; gsub(/"/, "", vdev) }
        }
        END {
            flush()
            printf "class\tdate\tvdev\tcount\n" > TALLY
            for (k in cnt) printf "%s\t%d\n", k, cnt[k] > TALLY
            printf "class\tcount\tfirst\tlast\n" > OVER
            for (c in n) printf "%s\t%d\t%s\t%s\n", c, n[c], first[c], last[c] > OVER
            printf "# events in the ring buffer: %d\n", seen > OVER
            printf "# detail kept in zpool-events-v.txt: %d", kept > OVER
            if (CUT != "") printf " (since %s)\n", CUT > OVER; else printf " (all)\n" > OVER
        }
    '
    # A pool with no events at all leaves no files; say so rather than leaving a
    # reader to wonder whether the collector skipped the step.
    [ -f "$d/zpool-events-overview.tsv" ] || printf 'class\tcount\tfirst\tlast\n# no events returned (empty buffer, or permission denied for this uid)\n' > "$d/zpool-events-overview.tsv"
    [ -f "$d/zpool-events-v.txt" ] || : > "$d/zpool-events-v.txt"
}

# =============================================================================
# Bundle (Tier 1 raw artifacts; Tier 2 only when its flag was given)
# =============================================================================
bundle_zfs() {
    local d="$1" p; mkdir -p "$d" 2>/dev/null
    if have zpool; then
        run_bounded 30 zpool list -v          > "$d/zpool-list-v.txt"
        run_bounded 30 zpool status -v        > "$d/zpool-status-v.txt"
        run_bounded 30 zpool status -t        > "$d/zpool-status-t.txt"
        run_bounded 60 zpool status -D        > "$d/zpool-status-D.txt"
        run_bounded 30 zpool iostat -v        > "$d/zpool-iostat-v.txt"
        run_bounded 30 zpool iostat -lv       > "$d/zpool-iostat-lv.txt"
        run_bounded 30 zpool iostat -qv       > "$d/zpool-iostat-qv.txt"
        run_bounded 30 zpool iostat -r        > "$d/zpool-iostat-r.txt"
        run_bounded 30 zpool iostat -w        > "$d/zpool-iostat-w.txt"
        zevents_split "$d"
        for p in $ZPOOLS; do
            run_bounded 30 zpool get all "$p" > "$d/zpool-get-all-$p.txt"
            run_bounded 60 zpool history "$p" > "$d/zpool-history-$p.txt"
            run_bounded 30 zpool status -PL "$p" > "$d/zpool-status-P-$p.txt"
        done
    fi
    if have zfs; then
        run_bounded 90  zfs get -H -o name,property,value,source -t filesystem,volume all > "$d/zfs-get-all.tsv"
        run_bounded 90  zfs get -Hp -o name,property,value,source -t filesystem,volume all > "$d/zfs-get-all-parsable.tsv"
        run_bounded 60  zfs list -o space          > "$d/zfs-list-space.txt"
        run_bounded 60  zfs list -t filesystem,volume > "$d/zfs-list.txt"
        run_bounded 120 zfs list -H -p -t snapshot -o name,used,referenced,creation,userrefs,written > "$d/zfs-list-snapshots.tsv"
        run_bounded 60  zfs list -t bookmark       > "$d/zfs-list-bookmarks.txt"
        run_bounded 30  zfs version                > "$d/zfs-version.txt"
    fi
    progress "zfs: pool/dataset snapshot written"
}

bundle_kstat() {
    local d="$1" f rel
    [ -d "$KSTAT_DIR" ] || { warn "kstat: skipped (path not found: $KSTAT_DIR)"; return; }
    mkdir -p "$d" 2>/dev/null
    # dbufs is skipped on purpose (very large, lock-heavy). Everything else under
    # the kstat tree is a small text file.
    find "$KSTAT_DIR" -maxdepth 2 -type f 2>/dev/null | while IFS= read -r f; do
        case "$(basename "$f")" in dbufs) continue ;; esac
        rel="${f#"$KSTAT_DIR"/}"
        mkdir -p "$d/$(dirname "$rel")" 2>/dev/null
        cat "$f" > "$d/$rel" 2>/dev/null
    done
    [ -e /proc/spl/kmem/slab ] && head -c 4194304 /proc/spl/kmem/slab > "$d/kmem-slab.txt" 2>/dev/null
    progress "kstat: tree copied (dbufs excluded)"
}

bundle_params() {
    local d="$1" f; mkdir -p "$d" 2>/dev/null
    for f in /sys/module/zfs/parameters /sys/module/spl/parameters; do
        [ -d "$f" ] || continue
        ( cd "$f" 2>/dev/null && for k in *; do
              [ -f "$k" ] || continue
              printf '%s = %s\n' "$k" "$(head -n1 "$k" 2>/dev/null)"
          done ) > "$d/$(printf '%s' "$f" | tr '/' '_').txt" 2>/dev/null
    done
    have modinfo && modinfo zfs > "$d/modinfo-zfs.txt" 2>/dev/null
    cat /etc/modprobe.d/*zfs* /etc/modprobe.d/*spl* > "$d/modprobe.d-zfs.txt" 2>/dev/null
    cat /proc/cmdline > "$d/kernel-cmdline.txt" 2>/dev/null
    progress "params: module parameters written"
}

bundle_host() {
    local d="$1"; mkdir -p "$d" 2>/dev/null
    cat /proc/meminfo > "$d/meminfo.txt" 2>/dev/null
    cat /proc/loadavg > "$d/loadavg.txt" 2>/dev/null
    have lsblk && lsblk -O > "$d/lsblk-O.txt" 2>/dev/null
    have lsblk && lsblk -o NAME,KNAME,TYPE,SIZE,ROTA,PHY-SEC,LOG-SEC,SCHED,MOUNTPOINT,MODEL > "$d/lsblk.txt" 2>/dev/null
    have findmnt && findmnt > "$d/findmnt.txt" 2>/dev/null
    have df && df -T > "$d/df-T.txt" 2>/dev/null
    cat /proc/self/mountinfo > "$d/mountinfo.txt" 2>/dev/null
    have iostat && iostat -x > "$d/iostat-x.txt" 2>/dev/null
    have multipath && multipath -ll > "$d/multipath.txt" 2>&1
    dmesg 2>/dev/null | tail -n 500 > "$d/dmesg-tail.txt" 2>/dev/null
    ( for b in /sys/block/*; do
          [ -d "$b/queue" ] || continue
          printf '== %s ==\n' "$(basename "$b")"
          for q in "$b"/queue/*; do
              [ -f "$q" ] && [ -r "$q" ] && printf '%s = %s\n' "$(basename "$q")" "$(head -n1 "$q" 2>/dev/null)"
          done
      done ) > "$d/block-queue.txt" 2>/dev/null
    if have journalctl; then
        local u
        for u in zfs-zed zfs-import-cache zfs-import-scan zfs-mount zfs-share; do
            unit_loaded "$u.service" || continue
            journalctl -u "$u.service" --since "${OPT_HOURS} hours ago" --no-pager > "$d/$u.journal.txt" 2>/dev/null
        done
    fi
    progress "host: block device and kernel snapshot written"
}

bundle_whatap() {
    local d="$1"; mkdir -p "$d" 2>/dev/null
    {
        printf 'WHATAP_HOME=%s\n' "${WHOME:-n/a}"
        printf 'WHATAP_HOME_resolved_by=%s\n' "$WHOME_SRC"
        printf 'YARDBASE=%s\n' "${YARDBASE:-n/a}"
    } > "$d/paths.txt" 2>/dev/null
    local p
    for p in "$WHOME" "$YARDBASE" "$WHOME/logs" "$WHOME/db" "$WHOME/keeperbase" "$WHOME/logsink"; do
        [ -n "$p" ] && [ -e "$p" ] || continue
        printf '%s\tfstype=%s\tdataset=%s\n' "$p" "$(fstype_of "$p")" "$(source_of "$p")" >> "$d/path-dataset-map.txt" 2>/dev/null
    done
    have df && df -h > "$d/df-h.txt" 2>/dev/null
    progress "whatap: path-to-dataset map written"
}

bundle_sample() {
    local d="$1"; mkdir -p "$d" 2>/dev/null
    have zpool || return
    progress "sample: zpool iostat interval samples (${SAMPLE_SECS}s each) ..."
    run_bounded $((SAMPLE_SECS * 3 + 30)) zpool iostat -lqv "$SAMPLE_SECS" 2 > "$d/iostat-lqv.txt"
    run_bounded $((SAMPLE_SECS * 3 + 30)) zpool iostat -r "$SAMPLE_SECS" 2   > "$d/iostat-r.txt"
    run_bounded $((SAMPLE_SECS * 3 + 30)) zpool iostat -w "$SAMPLE_SECS" 2   > "$d/iostat-w.txt"
    have arcstat && run_bounded $((SAMPLE_SECS * 3 + 30)) arcstat 1 "$SAMPLE_SECS" > "$d/arcstat.txt"
    if have iostat; then
        local ic=$(( SAMPLE_SECS * 3 / IOSTAT_BUCKET + 1 ))
        [ "$ic" -lt 2 ] && ic=2
        progress "sample: iostat -x in ${IOSTAT_BUCKET}s buckets over $(( (ic - 1) * IOSTAT_BUCKET ))s ..."
        run_bounded $(( ic * IOSTAT_BUCKET + 30 )) iostat -x "$IOSTAT_BUCKET" "$ic" \
            > "$d/iostat-x-interval.txt"
    fi
    progress "sample: written"
}

bundle_zdb() {
    local d="$1" p; mkdir -p "$d" 2>/dev/null
    have zdb || { warn "[Tier2] zdb: command not found"; return; }
    for p in $ZPOOLS; do
        warn "[Tier2] zdb -C $p (bundle)"
        run_bounded 300  zdb -C "$p"      > "$d/zdb-C-$p.txt" 2>&1
        warn "[Tier2] zdb -Lbbbs $p (bundle) — traverses pool metadata"
        run_bounded 3600 zdb -Lbbbs "$p"  > "$d/zdb-Lbbbs-$p.txt" 2>&1
        warn "[Tier2] zdb -mm $p (bundle) — loads metaslab space maps"
        run_bounded 3600 zdb -mm "$p"     > "$d/zdb-mm-$p.txt" 2>&1
    done
    progress "zdb: written"
}

do_bundle() {
    local work tarball
    work="$(mktemp -d 2>/dev/null || echo "$OPT_OUT/$BASENAME.tmp.$$")"
    mkdir -p "$work" 2>/dev/null
    run_report > "$work/report.txt" 2>/dev/null
    progress "report: written to bundle"
    bundle_zfs    "$work/zfs"
    bundle_kstat  "$work/kstat"
    bundle_params "$work/params"
    bundle_host   "$work/host"
    bundle_whatap "$work/whatap"
    [ "$OPT_SAMPLE" = 1 ] && bundle_sample "$work/sample"
    [ "$OPT_ZDB" = 1 ] && bundle_zdb "$work/zdb"

    tarball="$OPT_OUT/$BASENAME.tar.gz"
    if have tar; then
        # -C instead of `cd "$work"`: with a relative --out (default "."), a cd
        # into $work would put $tarball inside $work and then delete it with the
        # work dir. Only remove $work if tar actually wrote the tarball.
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

if [ "$OPT_BUNDLE" = 0 ] && [ "$OPT_STDOUT" = 0 ] && [ "$OPT_FILE" = 0 ]; then
    warn "no action flag given — need one of --file / --stdout / --bundle"
    usage >&2
    exit 2
fi

case "$SAMPLE_SECS" in
    ''|*[!0-9]*) warn "--sample takes seconds as an integer; got '$SAMPLE_SECS' — using 10"; SAMPLE_SECS=10 ;;
esac
[ "$SAMPLE_SECS" -lt 1 ] 2>/dev/null && SAMPLE_SECS=1

_init_errfile
have timeout && _timeout_bin="$(command -v timeout)"
mkdir -p "$OPT_OUT" 2>/dev/null

progress "discovering pools, datasets and snapshots ..."
discover_zfs
progress "resolving WHATAP_HOME / yardbase ..."
resolve_home
resolve_yardbase
TARGET="collection-server-zfs/$(hostname 2>/dev/null || echo unknown)@pools=${ZPOOLS:-none}"
progress "pools: ${ZPOOLS:-none}; datasets: ${DS_COUNT:-0}; snapshots: ${SNAP_COUNT:-0}; WHATAP_HOME: ${WHOME:-n/a}"

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-collzfs-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (report + raw ZFS artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (report)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (report) -> writing $OUTFILE"
    run_report > "$OUTFILE" 2>/dev/null
    progress "report written: $OUTFILE"
fi

[ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null
[ -n "$_ZGETALL" ] && rm -f "$_ZGETALL" 2>/dev/null
[ -n "$_ZSNAP" ] && rm -f "$_ZSNAP" 2>/dev/null
exit 0
