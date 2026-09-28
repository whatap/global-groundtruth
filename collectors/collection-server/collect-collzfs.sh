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
# ZFS only: it does not look for WhaTap. Companion collector:
# collect-collserver.sh collects the WhaTap backend facts (WHATAP_HOME layout,
# JVMs, ports, conf/*.conf, service logs) and, in its section C, which
# filesystem and dataset the yardbase is on; runbooks run both. This report has
# every dataset's properties, so the two join on the dataset name.
#
# Question -> report section map: see README.md, "Design notes" under this
# collector.
#
# Tier 0 (the default report) reads kstats, properties and since-boot iostat
# only: no pool traversal, no tree walk, no device wake-up. What costs wall-clock
# beyond the default 15s window (--window) or pool I/O (--zdb, --filesizes) is
# opt-in and announced first.
#
# Rules: ../../CONTRACT.md and ../../docs/collector-engineering.md. No `set -e`:
# the report always reaches its footer.
# -----------------------------------------------------------------------------

# bash only (arrays, local, PIPESTATUS). Checked first, so sh or dash stops with
# a sentence instead of a syntax error.
[ -n "${BASH_VERSION:-}" ] || { echo "collect-collzfs.sh needs bash" >&2; exit 2; }

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
# History: CHANGELOG.md, section collect-collzfs.sh (next to this file).
COLLECTOR_NAME="whatap-collzfs"
VERSION="0.12.5"
DOMAIN="collection-server"
TARGET="collection-server-zfs/$(hostname 2>/dev/null || echo unknown)"   # refined after pool discovery

# ---- emit helpers — DO NOT EDIT ---------------------------------------------
# The report shape (../../docs/output-format.md): header, numbered sections,
# facts, footer. progress narrates on fd 3 (the terminal saved in main), never
# into the report, and --quiet silences it; keep its text a fact about the run.
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

# section "A. TITLE" -> the next numbered section, [n] A. TITLE, narrated too
section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}
subsection() { printf '\n    -- %s --\n' "$1"; }
fact()       { printf '    %s\n' "$1"; }
emit_footer() { printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'; }
progress()   { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null || :; }
have()       { command -v "$1" >/dev/null 2>&1; }

# _indent PREFIX -> stdin with PREFIX before every line; a last line without a
# newline is kept (and ended)
_indent() { awk -v p="$1" '{ print p $0 }'; }

# _emit_labeled LABEL BODY -> "LABEL: BODY" for a one-line BODY; else "LABEL:"
# and BODY's lines under it, indented
_emit_labeled() {
    local label="$1" body="$2" n
    n="$(printf '%s\n' "$body" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -le 1 ]; then
        fact "$label: $body"
    else
        fact "$label:"
        printf '%s\n' "$body" | _indent '        '
    fi
}

# _tool_rows [--path] TOOL... -> one row per TOOL for the environment section's
# tool table: "present" or "absent", with --path "present (PATH)". The path is
# read back from a file in the run's directory, not a $(...) (a fork per tool);
# without the directory it is looked up again.
_tool_rows() {
    local wp=0 t p
    [ "${1:-}" = --path ] && { wp=1; shift; }
    for t in "$@"; do
        if ! command -v "$t" >/dev/null 2>&1; then printf '        %-12s absent\n' "$t"; continue; fi
        [ "$wp" = 1 ] || { printf '        %-12s present\n' "$t"; continue; }
        p=""
        [ -n "$_tmp_dir" ] && { command -v "$t" > "$_tmp_dir/cmdv"; } 2>/dev/null && IFS= read -r p < "$_tmp_dir/cmdv"
        [ -n "$p" ] || p="$(command -v "$t" 2>/dev/null)"
        printf '        %-12s present (%s)\n' "$t" "$p"
    done
}

# _optval NAME VALUE -> exit 2 when VALUE is empty or starts with '-' (then the
# next option was taken for the value: `--out --stdout`). This block comes
# before the option loop, which calls it.
_optval() {
    case "$2" in ''|-*) printf -- 'missing value for %s\n' "$1" >&2; exit 2 ;; esac
}
# ---- end emit helpers

# ---- options ----------------------------------------------------------------
OPT_FILE=0           # write the report to a .txt file
OPT_STDOUT=0
OPT_BUNDLE=0
OPT_QUIET=0          # suppress progress narration on stderr
OPT_OUT="."
# journal window in hours: JOURNAL_HOURS in the environment (checked in main)
OPT_HOURS="${JOURNAL_HOURS:-24}"
OPT_ZDB=0            # Tier 2: zdb -C / -Lbbbs / -mm
# File-size histogram: Tier 2. A metadata walk of a yard with ~10^8 files loads
# the special vdev and the ARC and does not finish in the bound; df -i gives the
# file count and --zdb the block sizes. --filesizes=PATH walks a narrow sample;
# there is no whole-yardbase walk.
OPT_FILESIZES=0
FILESIZES_PATH=""
# bound on the tree walk, from the environment like RUN_DEADLINE and
# CMD_TIMEOUT (checked in main); a partial result is labelled as such
FILESIZES_SECS="${FILESIZES_SECS:-300}"
# zpool events detail window, in days (0 = everything). With a large
# zfs_zevent_len_max, `zpool events -v` of the whole ring buffer is hundreds of
# MB; the tally (when a class started and stopped) always covers all of it.
# EVENT_DAYS in the environment (checked in main)
OPT_EVENT_DAYS="${EVENT_DAYS:-30}"
# The time window (section O) runs in every run: kstat file reads and interval
# samples, no pool load, only wall-clock. WIN_DEFAULT seconds unless
# --window=DUR sets it. WIN_SPEC is DUR.
WIN_DEFAULT=15
WIN_SPEC=""
WIN_GIVEN=0          # 1 when --window was on the command line, even empty
WIN_SECS=0
# RUN_DEADLINE as the caller gave it (empty when not given), read before the run
# helpers default it: the file-size walk, --window, --zdb and the bundle's
# event dump each need more than the default, and a caller's value wins.
_RUN_DEADLINE_ENV="${RUN_DEADLINE:-}"

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
  collect-collzfs.sh --out DIR              output directory (default: .)

  Tier 0 always includes the cumulative-since-boot zpool iostat histograms
  (-r request size, -w latency), which are instant kstat reads, and df -i
  (inodes, i.e. the file count) of every mounted ZFS dataset.

  zpool events. The tally (count, first date, last date per class) always covers
  the WHOLE ring buffer, because what the buffer answers is when a class started
  and when it stopped. The per-event detail is kept only for a recent window,
  because the full -v dump of a deep buffer is hundreds of MB.
  The detail window is EVENT_DAYS in the environment (below).

  File-size histogram (Tier 2, opt-in). It walks the whole tree reading metadata
  (find -printf '%s'), which on a yard of 10^8 files is load on the device that
  holds the metadata (a special vdev) and on the ARC, and does not finish in the
  bound. The file count comes from df -i in every run; the block-size
  distribution from --zdb. A walk that hits its bound is labelled PARTIAL.
  collect-collzfs.sh --filesizes=PATH       walk PATH (a narrow sample, such as
                                            one day's directory); a PATH is required
                                            bound: FILESIZES_SECS in the
                                            environment (default 300 seconds)

  Time window (section O). Every run includes one, 15 seconds long by default:
  kstat file reads and interval samples, no pool load, only wall-clock. It
  answers "is the device busy now"; every other interval number (%util,
  await, aqu-sz, vdev latency) is an average since boot or import. Over the
  window it collects:
    every txg from /proc/spl/kstat/zfs/<pool>/txgs (the ring of the last
    zfs_txg_history txgs, re-read before it wraps, merged by txg number; a
    txg that left the ring unseen is counted as a gap); start, end and delta
    of dmu_tx, arcstats and each dataset's objset-* counters; zpool iostat
    -vlq and iostat -x started together at the same interval, with
    timestamps; zpool iostat -r / -w for the window; arcstat when present.
  No tunable is changed. The window runs first; the rest of the report is
  collected after it. Ctrl-C ends the window early; the report keeps what
  was collected.
  collect-collzfs.sh --file --window=DUR    a window of DUR instead of 15s:
                                            N (seconds), Ns, Nm or Nh, 10s .. 24h.
                                            To cover a later time, start the run
                                            then (at, cron); keep the session open.

  Tier 2 (opt-in, adds pool or disk load — announced on stderr before running):
  collect-collzfs.sh --file --zdb           zdb -C, -Lbbbs, -mm per pool: block/psize
                                            histograms, measured compression, metaslab
                                            free-space histograms. Traverses pool
                                            metadata — minutes on a large pool.

  Environment (whole numbers; another value is ignored with a warning):
    CMD_TIMEOUT=N      cap on each external command, seconds (default 20)
    RUN_DEADLINE=N     cap on the whole run, seconds (default 300, raised for
                       the window, --zdb, --filesizes and --bundle unless set)
    FILESIZES_SECS=N   cap on the --filesizes walk, seconds (default 300)
    EVENT_DAYS=N       zpool events detail window, days (default 30; 0 = all)
    JOURNAL_HOURS=N    zfs unit journal window, hours (default 24)
EOF
}

ARGC=$#              # 0 args -> usage (handled in main, below)
# ---- collection-server: options — DO NOT EDIT -------------------------------
# members: collmysql collserver collzfs
# _removed MESSAGE -> an option that no longer exists: exit 2, naming what
# replaced it (fd 3 is not open yet, so stderr)
_removed() { printf '!! %s\n' "$1" >&2; exit 2; }
# ---- end collection-server: options
# _ignored MESSAGE -> an option that no longer exists but need not exit: named,
# then ignored (right where it is named, so it prints before a later error)
_ignored() { printf '!! %s\n' "$1" >&2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --file) OPT_FILE=1 ;;
        --stdout) OPT_STDOUT=1 ;;
        --bundle) OPT_BUNDLE=1 ;;
        --quiet) OPT_QUIET=1 ;;
        --out) _optval --out "${2:-}"; OPT_OUT="$2"; shift ;;
        --out=*) _optval --out "${1#*=}"; OPT_OUT="${1#*=}" ;;
        # removed, and nothing the run collects depends on it: named, then ignored
        --home) _optval --home "${2:-}"
            _ignored "--home is no longer used: collzfs reports ZFS only; the WhaTap paths and their dataset are in collect-collserver.sh section C"
            shift ;;
        --home=*) _optval --home "${1#*=}"
            _ignored "--home is no longer used: collzfs reports ZFS only; the WhaTap paths and their dataset are in collect-collserver.sh section C" ;;
        --hours|--hours=*)
            _removed "--hours was removed: set JOURNAL_HOURS=N in the environment (default 24)" ;;
        --sample|--sample=*)
            _removed "--sample was merged into --window: use --window=30s (or --window=DUR for a longer span)" ;;
        --zdb) OPT_ZDB=1 ;;
        --filesizes)
            _removed "--filesizes needs a path since 0.11.0: use --filesizes=PATH (a narrow sample such as one day's directory); the whole yardbase is not walked" ;;
        --filesizes=*) _optval --filesizes= "${1#*=}"; OPT_FILESIZES=1; FILESIZES_PATH="${1#*=}" ;;
        --no-filesizes)
            _removed "--no-filesizes was removed: the file-size walk runs only when --filesizes is given" ;;
        --filesizes-secs|--filesizes-secs=*)
            _removed "--filesizes-secs was removed: set FILESIZES_SECS=N in the environment (default 300)" ;;
        --event-days|--event-days=*)
            _removed "--event-days was removed: set EVENT_DAYS=N in the environment (default 30; 0 keeps everything)" ;;
        --window) _optval --window "${2:-}"; WIN_GIVEN=1; WIN_SPEC="$2"; shift ;;
        --window=*) _optval --window "${1#*=}"; WIN_GIVEN=1; WIN_SPEC="${1#*=}" ;;
        --window-start|--window-start=*)
            _removed "--window-start was removed: start the run at that time (at, cron) with --window=DUR" ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

blk() { printf '        %s\n' "$1"; }

# ---- reasoned-absence helpers (see docs/collector-engineering.md) -----------
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
# What a run can read depends on the privilege it was given: a fact about this
# run (CONTRACT rule 1), stated in the environment section ([1]). Each goal that
# privilege blocked repeats it via _priv_hint, because the status roll-up is what
# reaches the operator while still logged in, and "what was missing" and "what
# would have obtained it" are one thought. Without it, bundles came back with no
# conf/ and nothing said the uid could not reach it.
PRIV_WHY="unknown"
PRIV_GAP=""   # what a further privilege would obtain; empty when the run is root

# _priv_hint -> " (not elevated: REASON)", or nothing when the run is root.
# Append it to the reason of any goal that a privilege blocked.
_priv_hint() { [ -n "$PRIV_GAP" ] && printf ' (not elevated: %s)' "$PRIV_GAP"; return 0; }

# _note_privilege -> set PRIV_WHY/PRIV_GAP for this process. Call it once,
# before the environment section prints PRIV_WHY.
_note_privilege() {
    # No uid is not uid 0. A run that cannot tell says so, and claims no root.
    # _run_init has usually read it already.
    [ -n "${_priv_uid:-}" ] || _priv_uid="$(id -u 2>/dev/null)"
    [ -n "$_priv_uid" ] || _priv_uid="$(awk '/^Uid:/{print $2; exit}' /proc/self/status 2>/dev/null)"
    if [ -z "$_priv_uid" ]; then
        PRIV_WHY="n/a (id -u failed and /proc/self/status is not readable)"
        PRIV_GAP=""
    elif [ "$_priv_uid" = 0 ]; then
        PRIV_WHY="root${SUDO_UID:+ (elevated by sudo from uid $SUDO_UID)}"
        PRIV_GAP=""
        # uid 0 in a container is often without CAP_SYS_PTRACE (bit 19 of
        # CapEff; docker's and k8s's defaults), and then another uid's
        # /proc/<pid>/{environ,root,cwd} are denied although the line says root.
        # The low 8 hex digits: all shells agree on 32 bits.
        _priv_cap="$(awk '/^CapEff:/{print substr($2, length($2) - 7); exit}' /proc/self/status 2>/dev/null)"
        case "$_priv_cap" in
            ''|*[!0-9a-fA-F]*) ;;
            *) [ "$(( (0x$_priv_cap >> 19) & 1 ))" = 0 ] \
                && PRIV_WHY="$PRIV_WHY without CAP_SYS_PTRACE (other uids' /proc/<pid>/environ, root, cwd are not readable: run as the target's uid, e.g. docker exec -u <uid> or kubectl exec)" ;;
        esac
    else
        PRIV_WHY="not root (uid $_priv_uid)"
        PRIV_GAP="run again with sudo"
    fi
}
# ---- end privilege

# ---- boot time — DO NOT EDIT ------------------------------------------------
# Most counters a collector reports are cumulative since boot (/proc/diskstats,
# ZFS kstats, MySQL GLOBAL STATUS); without the boot time they cannot be read as
# a rate. It reads /proc, not `uptime`: that works without procps and on a run
# whose main collection failed early, the run whose counters most need it.
# _note_boot -> the two facts; call it in the environment section after privilege.
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
# ---- end boot time

# ---- run helpers — DO NOT EDIT ----------------------------------------------
# warn            must-see operator text on fd 3 (the terminal saved in main);
#                 not silenced by --quiet and not lost in --file mode.
# _bounded CMD... every external command under CMD_TIMEOUT and RUN_DEADLINE.
# _tmp NAME       a path in this run's private directory, removed on exit.
# _out_dir_check  the output directory exists and is writable, before a run.
# _report_to_file --file mode's write; fails when the file is not written whole.
# probe, probe_merged, read_proc  a command's output (probe_merged: with its
#                 stderr) or a file's content as facts, or n/a with the reason
#                 (guideline 4).
# _why_124        the reason for a bounded call's 124: run deadline or its cap.
# Constraints:
# - POSIX sh only (apm collectors run under `sh -s`, often dash or busybox):
#   no SECONDS, no `type -t`, no ${v//x/y} outside a BASH_VERSION guard.
# - A cap returns 124 whatever timeout(1) returns for a kill (busybox: 143).
#   timeout(1) gets -k where it takes it, so a command deaf to TERM still ends;
#   without timeout(1) (busybox's counts as without), or for a shell function,
#   a watchdog that ends in KILL. A call that finishes leaves no process to
#   PID 1 (a killed tree's grandchildren still can).
# - Past RUN_DEADLINE nothing runs (124), so the report still reaches its footer.
# - Each call is logged with its time; only the command name and a subcommand
#   word, never arguments (they can hold a path or a credential).
RUN_DEADLINE="${RUN_DEADLINE:-300}"
_tmp_dir=""
_timeout_bin=""   # timeout(1), found in _run_init; empty = watchdog only
_run_t0=""
_errfile=""       # a probe's stderr (_run_init)
_timeout_k=""     # 5 when timeout(1) takes -k (_run_init)
_load0=""         # _host_load at _run_init
SLOW_SEC=3        # a bounded call at least this long is named in the status
_stdin_script=0   # 1 when the shell reads this script from stdin (sh -s)
_nl='
'
_tab="$(printf '\t')"

# Falls back to stderr when fd 3 is not open yet (an error before main).
warn() { { printf '!! %s\n' "$*" >&3; } 2>/dev/null || printf '!! %s\n' "$*" >&2 || :; }

# _elapsed -> seconds since _run_init; 0 without a clock, which disables the
# deadline rather than tripping it at once
# shellcheck disable=SC3028  # SECONDS only under BASH_VERSION
_elapsed() {
    if [ -n "${BASH_VERSION:-}" ]; then printf '%s' "${SECONDS:-0}"
    elif [ -n "$_run_t0" ]; then printf '%s' "$(( $(date +%s 2>/dev/null || echo "$_run_t0") - _run_t0 ))"
    else printf '0'; fi
}
_past_deadline() { [ "$(_elapsed)" -ge "$RUN_DEADLINE" ]; }

# _cmd_kind CMD -> "file", "shell" (function or builtin) or "" (not found)
_cmd_kind() {
    case "$(command -v "$1" 2>/dev/null)" in
        /*) printf 'file' ;;
        '') ;;
        *)  printf 'shell' ;;
    esac
}

# Only the process that ran _run_init removes the directory: jobs forked by
# _bounded_in inherit the traps and would remove it mid-run. The owner is told
# by its pid, not by a flag set around the fork, which left a Ctrl-C window.
_owner_pid=""
_run_cleanup() {
    local me
    if [ -n "${BASHPID:-}" ]; then me="$BASHPID"; else me="$(exec sh -c 'echo "$PPID"')"; fi
    [ "$me" = "$_owner_pid" ] || return 0
    case "$_tmp_dir" in */ggt.*) rm -rf "$_tmp_dir" 2>/dev/null ;; esac
    _tmp_dir=""
}

# _cap_or NAME VALUE DEFAULT -> VALUE when it is 1..999999, else DEFAULT, and a
# warn naming what was ignored. A leading zero is refused too: $((030)) is 24.
_cap_or() {
    case "$2" in
        ''|*[!0-9]*|0*) ;;
        *) [ "${#2}" -le 6 ] && { printf '%s' "$2"; return 0; } ;;
    esac
    warn "$1=$2 ignored (not a whole number 1..999999 without leading zeros), using $3"
    printf '%s' "$3"
}

# _run_init -> the private temp directory, the traps, timeout(1), and _errfile
# (the file a probe's stderr goes to, which _classify_err reads). Call it once
# in main, before anything creates a temp file.
_run_init() {
    _run_t0="$(date +%s 2>/dev/null)"
    _owner_pid="$$"
    _load0="$(_host_load)"
    # 16+ digits: a date without %N prints bare seconds
    [ -z "${EPOCHREALTIME:-}" ] && case "$(date +%s%N 2>/dev/null)" in *[!0-9]*|'') ;; ????????????????*) _ms_date=1 ;; esac
    case "$_run_t0" in ''|*[!0-9]*) _run_t0="" ;; esac
    # The traps come before the directory: set after it, a signal in between
    # left ggt.* behind (1 in ~300 runs of a stress test, 2026-09-28). A signal
    # during mktemp runs the trap once the assignment is done, and
    # _run_cleanup does nothing while _tmp_dir is still empty.
    trap '_run_cleanup' EXIT
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
    # no predictable fallback name: without mktemp, _tmp answers /dev/null
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ggt.XXXXXX" 2>/dev/null)"
    # Script read from stdin (`sh -s`)? Then fd 0 is the script: a bounded
    # command must not read it, and bash 5.2 kills a $(...) that duplicates it.
    # A shell started by its path (`/bin/bash -s`) has its own binary as $0:
    # that is stdin too. Taken for a file, bash 3.2 frees its fd-0 input buffer
    # twice after `4<&0`, and under musl it faults in a loop at full CPU.
    case "$0" in
        */*|*.sh) [ -f "$0" ] || _stdin_script=1
                  [ -e "/proc/$$/exe" ] && [ "$0" -ef "/proc/$$/exe" ] && _stdin_script=1 ;;
        *)        _stdin_script=1 ;;
    esac
    [ -n "$_tmp_dir" ] || warn "no private temp directory could be made under ${TMPDIR:-/tmp}; values that need one are reported as n/a"
    _errfile="$(_tmp probe.err)"
    # the uid, read once: reasons name it (${_priv_uid:-?}), _note_privilege judges it
    _priv_uid="$(id -u 2>/dev/null)"
    # caps from the environment: whole numbers or unused (0 = no limit to timeout(1))
    RUN_DEADLINE="$(_cap_or RUN_DEADLINE "$RUN_DEADLINE" 300)"
    CMD_TIMEOUT="$(_cap_or CMD_TIMEOUT "${CMD_TIMEOUT:-20}" 20)"
    [ -n "${_timeout_bin:-}" ] || _timeout_bin="$(command -v timeout 2>/dev/null)"
    # busybox timeout(1) runs CMD in its own pid and leaves its timer to PID 1,
    # a zombie per call under a PID 1 that does not reap: the watchdog instead
    case "$_timeout_bin" in /*) LC_ALL=C grep -q 'BusyBox v' "$_timeout_bin" 2>/dev/null && _timeout_bin="" ;; esac
    if [ -n "${_timeout_bin:-}" ] && "$_timeout_bin" -k 1 5 true </dev/null >/dev/null 2>&1; then
        _timeout_k=5
    fi
}

# _tmp NAME -> a path inside this run's directory. /dev/null when no directory
# could be made, so a write is lost rather than landing somewhere shared.
_tmp() { if [ -n "$_tmp_dir" ]; then printf '%s/%s' "$_tmp_dir" "$1"; else printf '/dev/null'; fi; }

# _kill_tree SIG PID -> signal PID and every descendant, found by PPid in
# /proc/<pid>/status. dash keeps a job in the caller's group even under set -m.
_kill_tree() {
    local sig="$1" all="$2" list="$2" next c
    while [ -n "$list" ]; do
        next=""
        for c in $list; do
            next="$next $(grep -l "^PPid:[[:space:]]*$c\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3)"
        done
        # shellcheck disable=SC2086,SC2116  # word-splitting squeezes the list
        list="$(echo $next)"
        all="$all $list"
    done
    # shellcheck disable=SC2086
    kill -"$sig" $all 2>/dev/null
}

# _now_ms -> _ms, ms since the epoch, in a variable so a call does not fork.
# EPOCHREALTIME (bash), else date +%s%N when it has %N (_ms_date=1), else
# whole seconds.
_ms_date=0
_ms=0
# shellcheck disable=SC3028  # EPOCHREALTIME is empty outside bash
_now_ms() {
    local t="${EPOCHREALTIME:-}" f
    if [ -n "$t" ]; then
        # the locale's radix: EPOCHREALTIME can read 1790000000,123456
        f="${t#*[.,]}000"; f="${f%"${f#???}"}"
        _ms="${t%[.,]*}$f"
    elif [ "$_ms_date" = 1 ]; then
        t="$(date +%s%N 2>/dev/null)"; _ms="${t%??????}"
    else
        _ms="$(date +%s 2>/dev/null || echo 0)000"
    fi
}

# _time_log MS KIND CMD ARGS... -> one line for emit_status: the command name
# and, for a subcommand tool (kubectl get, zfs list), that word after any
# --opt=value. No other argument is kept; a name with odd bytes is "?".
_time_log() {
    [ -n "$_tmp_dir" ] || return 0
    local ms="$1" kind="$2" c="${3##*/}" w=""
    shift 3
    case "$c" in
        kubectl|oc|helm|zfs|zpool|systemctl|journalctl|timedatectl|chronyc|npm|pip|pip3|openssl|docker|crictl|ctr|ip)
            while [ $# -gt 0 ]; do case "$1" in -*=*) shift ;; *) break ;; esac; done
            case "${1:-}" in [a-z]*) case "$1" in *[!a-z0-9-]*) ;; *) w=" $1" ;; esac ;; esac ;;
    esac
    case "$c" in ''|*[!A-Za-z0-9._+-]*) c='?' ;; esac
    # braces: a redirect is opened before 2>/dev/null applies to it
    { printf '%s\t%s\t%s\n' "$ms" "$kind" "$c$w" >> "$_tmp_dir/time.log"; } 2>/dev/null
}

# _host_load -> one line: load average, PSI avg10 (cpu/io/memory), available
# memory, procs running/blocked. Read at start and end, so a slow call can be
# set against the load it ran under. /proc only.
_host_load() {
    LC_ALL=C awk '
        FILENAME == "/proc/loadavg" { la = "load " $1 " " $2 " " $3 }
        FILENAME ~ /^\/proc\/pressure\// {
            k = substr(FILENAME, 16)
            for (i = 2; i <= NF; i++) if ($i ~ /^avg10=/) p[k] = p[k] (p[k] == "" ? "" : "/") substr($i, 7)
        }
        /^MemTotal:/ { mt = $2 } /^MemAvailable:/ { ma = $2 }
        /^procs_running/ { pr = $2 } /^procs_blocked/ { pb = $2 }
        END {
            psi = ""; n = split("cpu io memory", K, " ")
            for (i = 1; i <= n; i++) if (K[i] in p) psi = psi " " K[i] " " p[K[i]]
            printf "%s; ", (la != "" ? la : "load n/a")
            if (psi != "") printf "psi avg10 (some/full)%s; ", psi
            if (mt) printf "mem available %d of %d MiB; ", ma / 1024, mt / 1024; else printf "mem n/a; "
            printf "procs running %s, blocked %s", (pr != "" ? pr : "n/a"), (pb != "" ? pb : "n/a")
        }' /proc/loadavg /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory /proc/meminfo /proc/stat 2>/dev/null
}

# _bounded CMD... -> CMD under the caps, with the caller's stdin (/dev/null when
# the script itself is on stdin). _bounded_in FILE CMD... -> FILE as its stdin;
# use it, not `< FILE` on the call.
_bounded() { _bounded_in "" "$@"; }

_bounded_in() {
    local in="$1" t="${CMD_TIMEOUT:-20}" left rc p w d m0
    shift
    left=$((RUN_DEADLINE - $(_elapsed)))
    [ "$left" -le 0 ] && { _time_log 0 "not run" "$@"; return 124; }
    _now_ms; m0="$_ms"
    [ "$left" -lt "$t" ] && t="$left"
    [ -z "$in" ] && [ "$_stdin_script" = 1 ] && in=/dev/null
    if [ -n "${_timeout_bin:-}" ] && [ "$(_cmd_kind "$1")" = file ]; then
        if [ -n "$in" ]; then "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@" < "$in"
        else                  "$_timeout_bin" ${_timeout_k:+-k "$_timeout_k"} "$t" "$@"; fi
        rc=$?
    else
        # The kill must reach all CMD started (an orphaned grandchild holds a
        # $(...) pipe open): set -m gives bash a job group, _kill_tree covers
        # dash. Inherited stdin goes through fd 4: an async list gets /dev/null
        # as stdin before its own redirections, so 0<&0 would hand dash /dev/null.
        set -m 2>/dev/null
        if [ -n "$in" ]; then "$@" < "$in" &
        else                  { "$@" 0<&4 4<&- & } 4<&0; fi
        p=$!
        set +m 2>/dev/null
        # The watchdog is ended by USR1, on which it KILLs and reaps its sleep:
        # a sleep left behind goes to PID 1, and a container's PID 1 that does
        # not reap keeps it as a zombie (one per call). No trap of this shell
        # is on USR1, so one that lands before the watchdog's trap is set ends
        # it at once, before it has a child. A TERM could land before dash
        # reset the inherited traps and be lost, and a KILL orphans the sleep.
        # The trap's own kill is KILL: a TERM to a sleep not yet exec'd is lost.
        ( trap '[ "$!" = "$p" ] || kill -KILL "$!" 2>/dev/null; wait; exit 0' USR1
          i=0
          # background sleep + wait, so the USR1 ends the watchdog at once
          while [ "$i" -lt "$t" ]; do sleep 1 & wait $!; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2 & wait $!
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        wait "$p"; rc=$?
        kill -USR1 "$w" 2>/dev/null; wait "$w" 2>/dev/null
    fi
    _now_ms; d=$((_ms - m0))
    case "$rc" in 124|137|143) [ "$((d / 1000))" -ge "$t" ] && rc=124 ;; esac
    if [ "$rc" = 124 ]; then
        if [ "$t" -lt "${CMD_TIMEOUT:-20}" ]; then w="cut at the deadline"; else w="capped at ${t}s"; fi
    else w="ran"; fi
    _time_log "$d" "$w" "$@"
    return "$rc"
}

# _out_dir_check -> the output directory OPT_OUT (empty: the working directory)
# exists, made when missing, and this uid can write into it; else false, saying
# so on the operator stream.
# Called before anything is collected, so an unwritable one fails at once
# rather than after a full run.
_out_dir_check() {
    local d="${OPT_OUT:-.}"
    [ -d "$d" ] || _bounded mkdir -p -- "$d" 2>/dev/null
    if [ ! -d "$d" ] || [ ! -w "$d" ] || [ ! -x "$d" ]; then
        warn "the report was not written: output directory $d is not writable by uid ${_priv_uid:-?}"
        return 1
    fi
}

_report_to_file() {
    # `true`, not `:`. A failed redirect on a special builtin exits dash.
    if ! { true > "$1"; } 2>/dev/null; then
        warn "the report was not written: $1 cannot be created by uid ${_priv_uid:-?}"
        return 1
    fi
    run_report > "$1" 2>/dev/null
    if ! tail -n 1 -- "$1" 2>/dev/null | grep -q '^==== END OF COLLECTION'; then
        warn "the report was not written whole: $1 does not end with the footer"
        return 1
    fi
}

# _why_124 -> why a bounded call returned 124: the run deadline, or its own cap
_why_124() {
    if _past_deadline; then printf 'run deadline reached: %ss' "$RUN_DEADLINE"
    else printf 'timed out: %ss' "$CMD_TIMEOUT"; fi
}

# probe "label" CMD [ARGS...] -> output as facts, or "label: n/a (<why>)".
# CMD may be a file, a shell function or a builtin; _bounded caps all three. A
# non-zero exit that still printed something is reported with its output, since
# for many commands the exit code is the answer (systemctl is-active prints
# "inactive" and exits 3). The reason of a failure is the collector's
# _classify_err, reading _errfile. PROBE_OUT / PROBE_RC: the last probe's stdout
# and exit status (127 when nothing ran), so a caller that also parses the
# output runs the command once.
# probe_merged "label" CMD [ARGS...] -> the same with stderr folded into stdout,
# for tools that answer on stderr (java -version). With no stderr to classify,
# a failed run with no output says its exit status.
PROBE_OUT=""; PROBE_RC=127
probe()        { _probe_run 2 "$@"; }
probe_merged() { _probe_run 1 "$@"; }
# shellcheck disable=SC2034  # PROBE_OUT / PROBE_RC are read by the caller
_probe_run() {
    local _pr_m="$1" label="$2" out rc; shift 2
    PROBE_OUT=""; PROBE_RC=127
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    if [ "$_pr_m" = 1 ]; then out="$(_bounded "$@" 2>&1)"; rc=$?
    else out="$(_bounded "$@" 2>"$_errfile")"; rc=$?; fi
    PROBE_OUT="$out"; PROBE_RC="$rc"
    if [ "$rc" -eq 124 ]; then
        fact "$label: n/a ($(_why_124))"
        return
    fi
    if [ "$rc" -ne 0 ]; then
        [ -n "$out" ] && { _emit_labeled "$label (exit $rc)" "$out"; return; }
        if [ "$_pr_m" = 1 ]; then fact "$label: n/a (empty output, exit $rc)"
        else fact "$label: n/a ($(_classify_err))"; fi
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# read_proc "label" PATH [LINES] -> a /proc or /sys file's content (its last
# LINES lines when LINES is given), or "label: n/a (<why>)".
read_proc() {
    local label="$1" path="$2" cap="${3:-0}" out
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    if [ "$cap" -gt 0 ] 2>/dev/null; then out="$(tail -n "$cap" "$path" 2>/dev/null)"
    else out="$(cat "$path" 2>/dev/null)"; fi
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}
# ---- end run helpers

# ---- collection completeness — DO NOT EDIT ----------------------------------
# Whether this run obtained what it came for is a fact about the run (CONTRACT.md,
# "Saying whether the collection worked"). A report full of n/a otherwise reads as
# finished and the gap surfaces days later; the status says, while the operator
# is still logged in: send this, or change something and run again.
#
#     goal   conf "module configs"                     # what this run is for
#     got    conf                                      # obtained
#     na     conf "this host runs no yard"             # legitimately absent
#     missed conf "uid 3103 cannot reach /data/whatap"  # this run was blocked
#
# `na` only when every input behind the absence was read and it IS the answer;
# one unreadable path, refused call or timeout makes it `missed`. Only `missed`
# makes a run INCOMPLETE. Resolve each goal once, after the last fallback:
# unresolved counts as "not reached", resolved twice differently counts as
# blocked, an undeclared resolution is listed. Records are KEY<TAB>VALUE lines;
# tabs and newlines in a reason are flattened.
_goals='' _res=''

_flat() { printf '%s' "$1" | tr '\n\t' '  '; }

goal() {
    case "$_nl$_goals" in *"$_nl$1$_tab"*) return 0 ;; esac
    _goals="$_goals$1$_tab$(_flat "$2")$_nl"
}
got()    { _res="$_res$1${_tab}got$_tab$_nl"; }
na()     { _res="$_res$1${_tab}na$_tab$(_flat "$2")$_nl"; }
missed() { _res="$_res$1${_tab}missed$_tab$(_flat "$2")$_nl"; }

# notice: like progress, but NOT silenced by --quiet; reserved for the status
# roll-up, the one line an automated caller wants most.
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null || :; }

# _emit_time -> the run time; when a call was slow (SLOW_SEC), capped or not
# run, also the host load at start and end, the counts, and each such call as
# time.log has it (ms, outcome, command), in the order they happened. No sums
# or sorting: the reader or an analysis tool does that (CONTRACT.md, rule 1).
_emit_time() {
    local f="${_tmp_dir:+$_tmp_dir/time.log}" counts
    fact "run time: $(_elapsed)s of ${RUN_DEADLINE}s allowed"
    [ -n "$f" ] && [ -s "$f" ] || return 0
    # calls, stopped at a cap or the deadline, not run, slow
    counts="$(awk -F'\t' -v s="$SLOW_SEC" '
        { n++ } $2 ~ /^(capped|cut)/ { c++ } $2 == "not run" { r++ } $2 != "not run" && $1 >= s * 1000 { w++ }
        END { printf "%d %d %d %d", n, c, r, w }' "$f")"
    set -- $counts
    [ "$2" -gt 0 ] || [ "$3" -gt 0 ] || [ "$4" -gt 0 ] || return 0
    fact "host load at start: ${_load0:-n/a}"
    fact "host load at end:   $(_host_load)"
    fact "bounded calls: $1; stopped at their cap or the deadline: $2; not run past the deadline: $3"
    fact "bounded calls that were slow (${SLOW_SEC}s+), stopped or not run, in order (ms, outcome, command):"
    awk -F'\t' -v s="$SLOW_SEC" '
        $2 != "ran" || $1 >= s * 1000 { if (++k <= 40) printf "%s ms  %s  %s\n", $1, $2, $3 }
        END { if (k > 40) printf "(%d more in this run)\n", k - 40 }' "$f" \
        | while IFS= read -r l; do fact "    $l"; done
}

# emit_status -> the roll-up section. Call it immediately before emit_footer.
# Also repeats each gap on fd 3 so the operator sees it while still logged in.
emit_status() {
    [ -n "$_goals" ] || return 0
    local k lab outs u why total=0 obtained=0 nacount=0 blocked=0 gaps='' nas='' oks='' stray deadline=''
    while IFS="$_tab" read -r k lab; do
        [ -n "$k" ] || continue
        total=$((total + 1))
        # every outcome recorded for this key, in order, and the distinct set
        outs="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { printf "%s%s", (n++ ? ", " : ""), $2 }')"
        u="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k && !s[$2]++ { printf "%s%s", (n++ ? " " : ""), $2 }')"
        case "$u" in
            got) obtained=$((obtained + 1)); oks="$oks $lab,"; continue ;;
            na)  nacount=$((nacount + 1))
                 nas="$nas$lab — $(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { print $3; exit }')$_nl"
                 continue ;;
        esac
        blocked=$((blocked + 1))
        why="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k && $2 == "missed" { printf "%s%s", (n++ ? "; " : ""), $3 }')"
        case "$u" in
            '')     why='not reached' ;;
            missed) ;;
            *)      why="resolved $(printf '%s' "$outs" | awk -F', ' '{print NF}') times: $outs${why:+ — $why}" ;;
        esac
        gaps="$gaps$lab — $why$_nl"
    done <<EOF
$_goals
EOF
    stray="$(printf '%s' "$_res" | _G="$_goals" awk -F'\t' '
        BEGIN { n = split(ENVIRON["_G"], L, "\n"); for (i = 1; i <= n; i++) { split(L[i], f, "\t"); if (f[1] != "") d[f[1]] = 1 } }
        $1 != "" && !($1 in d) && !($1 in seen) { seen[$1] = 1; printf "%s%s", (c++ ? ", " : ""), $1 }')"
    _past_deadline && deadline="reached at ${RUN_DEADLINE}s; commands after it were not run"
    section "Collection status"
    fact "goals: $total declared, $obtained obtained, $nacount not applicable here, $blocked blocked"
    [ -n "$oks" ] && fact "obtained:${oks%,}"
    if [ -n "$nas" ]; then
        fact "not applicable to this host (this is an answer, not a gap):"
        printf '%s' "$nas" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
    fi
    [ -n "$stray" ] && fact "resolved but never declared: $stray"
    [ -n "$deadline" ] && fact "run deadline: $deadline"
    _emit_time
    if [ "$blocked" -eq 0 ] && [ -z "$deadline" ]; then
        fact "status: COMPLETE"
        notice "status: COMPLETE — nothing was blocked${nas:+ ($nacount not applicable to this host)}"
    else
        if [ -n "$gaps" ]; then
            fact "blocked (running this differently would obtain these):"
            printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && fact "    $l"; done
        fi
        fact "status: INCOMPLETE"
        notice "status: INCOMPLETE — $blocked of $total goals blocked${deadline:+, run deadline reached}"
        printf '%s' "$gaps" | while IFS= read -r l; do [ -n "$l" ] && notice "  $l"; done
    fi
}
# ---- end collection completeness

# ---- collection-server: file helpers — DO NOT EDIT --------------------------
# members: collserver collzfs
# dump_file PATH [LINES] -> a file's first LINES lines (default 4000), indented,
# or a reason.
dump_file() {
    local path="$1" cap="${2:-4000}"
    if [ ! -e "$path" ]; then fact "n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "n/a (permission denied: $path)"; return; fi
    if [ ! -s "$path" ]; then fact "(empty file)"; return; fi
    head -n "$cap" "$path" 2>/dev/null | _indent '        '
}
# ---- end collection-server: file helpers

# probe (run helpers) goes through _bounded: a pool that hangs costs at most
# CMD_TIMEOUT per call and the run still reaches its footer.
# Fail fast: a zpool or zfs whose discovery call hit the cap is not asked again.
# One hung pool would otherwise cost CMD_TIMEOUT for each of forty calls.
HUNG=""              # " zpool zfs" as discovery found them
HUNG_ZPOOL_WHY=""    # which discovery call hung, and its cap
HUNG_ZFS_WHY=""
_hung() { case " $HUNG " in *" $1 "*) return 0 ;; esac; return 1; }
# _skip_why CMD -> the reason a call to CMD was not made
_skip_why() {
    case "$1" in
        zpool) printf 'skipped: zpool hung earlier (%s)' "$HUNG_ZPOOL_WHY" ;;
        zfs)   printf 'skipped: zfs hung earlier (%s)' "$HUNG_ZFS_WHY" ;;
    esac
}

# zprobe "label" CMD... -> probe (run helpers), except that a zpool or zfs that
# hung earlier is not run again
zprobe() {
    if _hung "$2"; then PROBE_OUT=""; PROBE_RC=127; fact "$1: n/a ($(_skip_why "$2"))"
    else probe "$@"; fi
}

# probe_t SECS "label" CMD... -> probe capped at SECS (bash restores the
# prefix assignment when the function returns)
probe_t() { local t="$1"; shift; CMD_TIMEOUT="$t" zprobe "$@"; }

# probe_pipe "label" REQBIN 'shell pipeline' -> probe a pipeline, but classify a
# missing primary binary as "command not found: REQBIN" rather than as sh output.
probe_pipe() {
    local label="$1" req="$2" pipeline="$3"
    if ! command -v "$req" >/dev/null 2>&1; then
        fact "$label: n/a (command not found: $req)"; return
    fi
    _hung "$req" && { fact "$label: n/a ($(_skip_why "$req"))"; return; }
    probe "$label" sh -c "$pipeline"
}

probe_pipe_t() { local t="$1"; shift; CMD_TIMEOUT="$t" probe_pipe "$@"; }

# read_kstat_tail "label" PATH LINES -> like read_proc with a cap, but keeps the
# kstat column header (line 1) and says how many records were omitted. The txgs
# ring buffer is header + zfs_txg_history rows, so a plain tail would cut the
# only line that names the columns.
read_kstat_tail() {
    local label="$1" path="$2" n="$3" total out
    if [ ! -e "$path" ]; then fact "$label: n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "$label: n/a (permission denied: $path)"; return; fi
    total="$( { wc -l < "$path"; } 2>/dev/null | tr -d ' ')"
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

# run_bounded SECS CMD... -> stdout only, capped at SECS by _bounded (which also
# honours the run deadline and works without timeout(1)). Returns 124 on a cap.
run_bounded() {
    local s="$1"; shift
    _hung "$1" && return 124
    CMD_TIMEOUT="$s" _bounded "$@" 2>/dev/null
}

# ---- collection-server: systemd — DO NOT EDIT -------------------------------
# members: collserver collzfs
# _sd ARGS... -> systemctl ARGS, bounded, stderr dropped. No `--value` (systemd
# <230, Ubuntu 16.04, lacks it). Bounded: systemctl waits on D-Bus, and a wedged
# systemd would hang every call. Fail fast: once one call hits the cap, the rest
# are skipped rather than each costing CMD_TIMEOUT again. The mark is a file in
# the run's private directory because most calls run inside $(...), where a
# variable would not survive.
_sd() {
    local mark="" rc
    [ -n "$_tmp_dir" ] && mark="$_tmp_dir/systemctl.hung"
    [ -n "$mark" ] && [ -e "$mark" ] && return 124
    _bounded systemctl "$@" 2>/dev/null; rc=$?
    if [ "$rc" -eq 124 ] && [ -n "$mark" ]; then
        true > "$mark" 2>/dev/null
        warn "systemctl did not answer within ${CMD_TIMEOUT}s; further systemctl calls are skipped"
    fi
    return "$rc"
}

# What _sd_prefetch read with one `systemctl show` for every unit the run asks
# about: sd_show answers from here and asks systemctl only for a unit that was
# not prefetched.
_SD_CACHE=""   # lines: <unit><TAB><Prop>=<value>
_SD_KNOWN=" "  # units the prefetch answered for
# _sd_cached PROP UNIT -> the prefetched value; false when UNIT was not prefetched
_sd_cached() {
    case "$_SD_KNOWN" in *" $2 "*) ;; *) return 1 ;; esac
    local l
    while IFS= read -r l; do
        case "$l" in "$2$_tab$1="*) printf '%s\n' "${l#*=}"; return 0 ;; esac
    done <<EOF
$_SD_CACHE
EOF
    return 0
}

# _sd_prefetch UNIT... -> one `systemctl show` for every unit this run asks
# about, not one per question, into _SD_CACHE. It prints one block per unit
# (blank-line separated, properties in systemd's order); each block is filed
# under its Id.
_sd_prefetch() {
    have systemctl || return 0
    local out line id="" blk=""
    out="$(_sd show -p Id -p LoadState -p WorkingDirectory -p NRestarts "$@")"
    [ -n "$out" ] || return 0
    # A trailing blank line closes the last block.
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            case "$line" in Id=*) id="${line#Id=}" ;; esac
            blk="$blk$line$_nl"
            continue
        fi
        if [ -n "$id" ]; then
            _SD_KNOWN="$_SD_KNOWN$id "
            while IFS= read -r line; do
                [ -n "$line" ] && _SD_CACHE="$_SD_CACHE$id$_tab$line$_nl"
            done <<EOB
$blk
EOB
        fi
        id=""; blk=""
    done <<EOF
$out

EOF
}

# sd_show PROP UNIT -> the unit's property value; sd_state is-active|is-enabled
# UNIT -> systemctl's answer; unit_loaded UNIT -> UNIT is loaded. UNIT is the
# full name (whatap-server.service, zfs.target).
sd_show() {
    have systemctl || return 0
    _sd_cached "$1" "$2" && return 0
    _sd show -p "$1" "$2" | cut -d= -f2-
}
sd_state() { _sd "$1" "$2"; }
unit_loaded() { [ "$(sd_show LoadState "$1")" = "loaded" ]; }
# ---- end collection-server: systemd

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
_ZGETALL=""          # temp file: name<TAB>property<TAB>value<TAB>source (fs+vol, -p exact values)
_ZSNAP=""            # temp file: name used referenced creation(epoch) userrefs written clones, TAB-separated
DS_COUNT=0
SNAP_COUNT=0
# COLLZFS_KSTAT_DIR is a test hook (tools/test-collzfs.sh): a machine without
# ZFS cannot otherwise show the "kstat tree but no zpool" case.
KSTAT_DIR="${COLLZFS_KSTAT_DIR:-/proc/spl/kstat/zfs}"
ZFS_ON_HOST=0        # 1 when zfs/zpool commands OR the kstat tree exist
ZPOOL_RC=""          # exit status of the discovery `zpool list`; empty when not run
ZPOOL_ERR=""         # its stderr, first line
ZGET_RC=""           # the same for `zfs get all` and the snapshot list
ZGET_ERR=""
ZSNAP_RC=""
ZSNAP_CAP=120
ZSNAP_ERR=""
# the zfs-* systemd units: section A's per-unit rows and the prefetch (main)
# read this list; the journal ones (section D and the bundle) read the next.
ZFS_UNITS="zfs.target zfs-import-cache zfs-import-scan zfs-mount zfs-share zfs-zed zfs-volume-wait zfs-load-key"
ZFS_JOURNAL_UNITS="zfs-zed zfs-import-cache zfs-import-scan zfs-mount zfs-share"

discover_zfs() {
    if have zfs || have zpool || [ -d "$KSTAT_DIR" ]; then ZFS_ON_HOST=1; fi
    if have zpool; then
        # A failed list is not an empty one: its exit status and message are
        # kept so the pools goal can tell "none imported" from "not allowed".
        local _zl _ze; _ze="$(_tmp zpool-list.err)"
        _zl="$(_bounded zpool list -H -o name 2>"$_ze")"; ZPOOL_RC=$?
        ZPOOL_ERR="$(head -n1 "$_ze" 2>/dev/null | cut -c1-160)"
        if [ "$ZPOOL_RC" -eq 124 ]; then
            HUNG="$HUNG zpool"; HUNG_ZPOOL_WHY="zpool list did not answer within ${CMD_TIMEOUT}s"
            warn "$HUNG_ZPOOL_WHY; the other zpool calls are skipped"
        fi
        if [ "$ZPOOL_RC" -eq 0 ]; then
            # No trailing blank: an empty list has to stay empty for [ -z ].
            ZPOOLS="$(printf '%s' "$_zl" | tr '\n' ' ' | sed 's/ *$//')"
            ZPOOL_COUNT="$(printf '%s' "$ZPOOLS" | wc -w | tr -d ' ')"
        fi
    fi
    if have zfs; then
        # One pass over every filesystem/volume property, WITH its source
        # (local / inherited / default). Asking for `all` instead of a property
        # list means a version that lacks a property simply does not report it —
        # no command-wide failure, and the absence itself becomes a fact. -p:
        # exact values; the bundle's zfs-get-all-parsable.tsv is this file.
        _ZGETALL="$(_tmp zget.tsv)"
        local _ge; _ge="$(_tmp zget.err)"
        # Caps scale with CMD_TIMEOUT: 90s and 120s at the default 20s.
        local _gcap=$(( CMD_TIMEOUT * 9 / 2 )) _scap=$(( CMD_TIMEOUT * 6 ))
        CMD_TIMEOUT="$_gcap" _bounded zfs get -Hp -o name,property,value,source -t filesystem,volume all > "$_ZGETALL" 2>"$_ge"
        ZGET_RC=$?; ZGET_ERR="$(head -n1 "$_ge" 2>/dev/null | cut -c1-160)"
        if [ "$ZGET_RC" -eq 124 ]; then
            HUNG="$HUNG zfs"; HUNG_ZFS_WHY="zfs get did not answer within ${_gcap}s"
            warn "$HUNG_ZFS_WHY; the other zfs calls are skipped"
        fi
        DS_COUNT="$(awk -F'\t' '{print $1}' "$_ZGETALL" 2>/dev/null | sort -u | grep -c . 2>/dev/null)"
        # One pass over snapshots. `clones` is a SNAPSHOT property (it never
        # appears in the filesystem/volume dump above), so it is collected here:
        # a snapshot with a clone attached cannot be destroyed to reclaim space.
        # Bounded: a yard with an aggressive snapshot policy holds tens of thousands.
        # The bundle's zfs-list-snapshots.tsv is this file.
        _ZSNAP="$(_tmp zsnap.tsv)"
        local _se; _se="$(_tmp zsnap.err)"
        if _hung zfs; then ZSNAP_RC=124
        else
            CMD_TIMEOUT="$_scap" _bounded zfs list -H -p -t snapshot -o name,used,referenced,creation,userrefs,written,clones > "$_ZSNAP" 2>"$_se"
            ZSNAP_RC=$?
        fi
        ZSNAP_CAP="$_scap"; ZSNAP_ERR="$(head -n1 "$_se" 2>/dev/null | cut -c1-160)"
        SNAP_COUNT="$(grep -c . "$_ZSNAP" 2>/dev/null)"
    fi
    [ -z "$DS_COUNT" ] && DS_COUNT=0
    [ -z "$SNAP_COUNT" ] && SNAP_COUNT=0
}

# has_property PROPERTY -> 0 when this zfs build reported the property at all
has_property() {
    [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ] || return 1
    awk -F'\t' -v p="$1" '$2==p {found=1; exit} END{exit !found}' "$_ZGETALL" 2>/dev/null
}

# =============================================================================
# Raw rows of what discovery and section C already fetched
# =============================================================================

# zget_rows PROPS [DATASET...] -> the rows of discovery's `zfs get all` whose
# property is one of PROPS (space-separated), for every dataset or for the
# DATASETs named, in zfs's own order: NAME PROPERTY VALUE SOURCE. Empty when
# no row matched.
zget_rows() {
    local props="$1" ds=""; shift
    [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ] || return 1
    [ "$#" -gt 0 ] && ds="$_tab$(printf '%s\t' "$@")"
    awk -F'\t' -v P=" $props " -v D="$ds" '
        index(P, " " $2 " ") && (D == "" || index(D, "\t" $1 "\t")) {
            if (!h++) printf "%-38s %-26s %-22s %s\n", "NAME", "PROPERTY", "VALUE", "SOURCE"
            printf "%-38s %-26s %-22s %s\n", $1, $2, $3, $4
        }' "$_ZGETALL" 2>/dev/null
}

# _keep NAME -> the last probe's output, kept for the bundle when it answered
_keep() { [ "$PROBE_RC" = 0 ] && [ -n "$PROBE_OUT" ] && printf '%s\n' "$PROBE_OUT" > "$(_tmp "keep-$1")" 2>/dev/null; }
# _reuse NAME FILE SECS CMD... -> FILE from what the report kept under NAME, or
# from CMD when the report's call did not answer
_reuse() {
    local k; k="$(_tmp "keep-$1")"; shift
    if [ -s "$k" ]; then cp "$k" "$1" 2>/dev/null
    else local f="$1"; shift; run_bounded "$@" > "$f"; fi
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
    local p="$1" tmp err rc nerr
    tmp="$(_tmp fsz.list)"; err="$(_tmp fsz.err)"
    CMD_TIMEOUT="$FILESIZES_SECS" _bounded find "$p" -xdev -type f -printf '%s\n' 2>"$err" > "$tmp"
    rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        printf '(PARTIAL: the walk hit the %ss bound and was stopped. The buckets below\n' "$FILESIZES_SECS"
        printf ' cover only the files reached by then, in directory order, not the whole tree.)\n'
        warn "file-size histogram is partial: the walk hit the ${FILESIZES_SECS}s bound; FILESIZES_SECS=N in the environment raises it"
    elif [ "$rc" -ne 0 ]; then
        # find exits 1 when it could not descend into part of the tree. The
        # buckets then leave those subtrees out, and must say so.
        nerr="$(grep -c . "$err" 2>/dev/null)"
        printf '(PARTIAL: find exited %s; %s directories or files could not be read by uid %s,\n' "$rc" "${nerr:-0}" "${_priv_uid:-?}"
        printf ' so the buckets below leave those subtrees out. First message: %s)\n' "$(head -n1 "$err" 2>/dev/null | cut -c1-160)"
        warn "file-size histogram is partial: ${nerr:-0} paths under $p were not readable$(_priv_hint)"
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
# Report body: one _rep_<x> per section (MECE domains A..N)
# =============================================================================
# -- [1] Collection environment -------------------------------------------
_rep_env() {
    section "Collection environment"
    fact "collector: $COLLECTOR_NAME $VERSION"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root ))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    # [J] zpool iostat, the kstat trees and metaslab_stats are all since-boot.
    _note_boot
    # The whole run is bounded by this, raised for what this run was asked to do.
    fact "run deadline(s): $RUN_DEADLINE"
    fact "tools:"
    _tool_rows zfs zpool zdb arcstat arc_summary findmnt df lsblk iostat modinfo dkms \
        systemctl journalctl dmesg timeout tar awk find sort head tail
    fact "kstat tree ($KSTAT_DIR): $( [ -d "$KSTAT_DIR" ] && echo present || echo 'absent (path not found)' )"
    fact "module parameter dir (/sys/module/zfs/parameters): $( [ -d /sys/module/zfs/parameters ] && echo present || echo 'absent (path not found)' )"
    fact "ZFS present on this host: $( [ "$ZFS_ON_HOST" = 1 ] && echo yes || echo 'no (zfs/zpool commands and kstat tree all absent)' )"
    if [ -z "$ZPOOL_RC" ]; then fact "pools discovered: n/a (command not found: zpool)"
    elif [ "$ZPOOL_RC" -eq 124 ]; then fact "pools discovered: n/a ($HUNG_ZPOOL_WHY)"
    elif [ "$ZPOOL_RC" -ne 0 ]; then fact "pools discovered: n/a (zpool list exit $ZPOOL_RC${ZPOOL_ERR:+: $ZPOOL_ERR})"
    elif [ "${ZPOOL_COUNT:-0}" -eq 0 ]; then fact "pools discovered: 0 (zpool list ran and listed none)"
    else fact "pools discovered: $ZPOOL_COUNT ($ZPOOLS)"; fi
    if [ -z "$ZGET_RC" ]; then fact "filesystems+volumes discovered: n/a (command not found: zfs)"
    elif [ "$ZGET_RC" -eq 124 ]; then fact "filesystems+volumes discovered: n/a ($HUNG_ZFS_WHY)"
    elif [ "$ZGET_RC" -ne 0 ]; then fact "filesystems+volumes discovered: n/a (zfs get exit $ZGET_RC${ZGET_ERR:+: $ZGET_ERR})"
    else fact "filesystems+volumes discovered: ${DS_COUNT:-0}"; fi
    if [ -z "$ZSNAP_RC" ]; then fact "snapshots discovered: n/a (command not found: zfs)"
    elif [ "$ZSNAP_RC" -eq 124 ]; then fact "snapshots discovered: n/a ($( _hung zfs && _skip_why zfs || echo "zfs list -t snapshot did not answer within ${ZSNAP_CAP}s"))"
    elif [ "$ZSNAP_RC" -ne 0 ]; then fact "snapshots discovered: n/a (zfs list -t snapshot exit $ZSNAP_RC${ZSNAP_ERR:+: $ZSNAP_ERR})"
    else fact "snapshots discovered: ${SNAP_COUNT:-0}"; fi
    fact "tiers in this run: Tier0=always zdb=$( [ "$OPT_ZDB" = 1 ] && echo on || echo off ) filesizes=$( [ "$OPT_FILESIZES" = 1 ] && echo on || echo off ) window=$(_win_tier)"
}

# _win_tier -> the window's part of the tiers line: its length, or
# why it did not run (it runs only where ZFS is present, before the report)
_win_tier() {
    if [ "$ZFS_ON_HOST" != 1 ]; then printf 'n/a (no ZFS on this host)'
    elif [ "$WIN_RAN" != 1 ] && [ -n "$WIN_SKIP" ]; then printf 'not run (see section O)'
    else printf '%ss%s' "$WIN_SECS" "$( [ "$WIN_GIVEN" = 1 ] || echo ' (default)' )"; fi
}

# -- A. ZFS software & kernel module --------------------------------------
_rep_a() {
    section "A. ZFS software & kernel module"
    zprobe "zfs version" zfs version
    read_proc "kmod version (/sys/module/zfs/version)" /sys/module/zfs/version
    read_proc "spl version (/sys/module/spl/version)" /sys/module/spl/version
    probe_pipe "modinfo zfs (selected)" modinfo \
        "modinfo zfs 2>/dev/null | grep -E '^(filename|version|srcversion|license|depends|retpoline):' || true"
    # /proc, no fork; uname only where it is unreadable
    _ko=""; _kr=""
    { IFS= read -r _ko < /proc/sys/kernel/ostype; IFS= read -r _kr < /proc/sys/kernel/osrelease; } 2>/dev/null
    if [ -n "$_ko" ] && [ -n "$_kr" ]; then fact "kernel: $_ko $_kr"; else probe "kernel" uname -sr; fi
    read_proc "os-release" /etc/os-release
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
        if _hung zfs; then
            fact "zfs subcommands: n/a ($(_skip_why zfs))"
        else
            local _zu; _zu="$(_bounded zfs 2>&1)"
            fact "zfs rewrite subcommand: $(printf '%s\n' "$_zu" | grep -qE '(^|[[:space:]])rewrite([[:space:]]|$)' && echo present || echo absent)"
            fact "zfs jail/unjail subcommand: $(printf '%s\n' "$_zu" | grep -qE '(^|[[:space:]])jail([[:space:]]|$)' && echo present || echo absent)"
        fi
    else
        fact "zfs subcommands: n/a (command not found: zfs)"
    fi
    if have zpool; then
        # stdout AND stderr to /dev/null, in that order: only the exit code is
        # wanted. A cap (124) is its own answer, not "not supported".
        local _o _rc
        for _o in "iostat -r|request-size histogram" "iostat -w|latency histogram" "status -t|trim state"; do
            if _hung zpool; then fact "zpool ${_o%%|*} (${_o#*|}): n/a ($(_skip_why zpool))"; continue; fi
            # shellcheck disable=SC2086
            run_bounded "$CMD_TIMEOUT" zpool ${_o%%|*} >/dev/null 2>&1; _rc=$?
            case "$_rc" in
                0)   fact "zpool ${_o%%|*} (${_o#*|}): supported" ;;
                124) fact "zpool ${_o%%|*} (${_o#*|}): n/a ($(_why_124))" ;;
                *)   fact "zpool ${_o%%|*} (${_o#*|}): not supported by this zpool (exit $_rc)" ;;
            esac
        done
    fi
    subsection "ZFS systemd units & pool cache"
    if have systemctl; then
        local u any=0
        for u in $ZFS_UNITS; do
            unit_loaded "$u.service" || [ "$u" = "zfs.target" ] || continue
            any=1
            fact "$u: active=$(sd_state is-active "$u") enabled=$(sd_state is-enabled "$u")"
        done
        [ "$any" = 0 ] && fact "no zfs-* units loaded"
    else
        fact "zfs units: n/a (command not found: systemctl)"
    fi
    fact "/etc/zfs/zpool.cache: $( [ -e /etc/zfs/zpool.cache ] && echo "present ($( { wc -c < /etc/zfs/zpool.cache; } 2>/dev/null | tr -d ' ') bytes, mtime $(date -u -r /etc/zfs/zpool.cache +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a))" || echo 'absent (path not found)' )"
}

# -- B. ZFS module parameters ---------------------------------------------
_rep_b() {
    # The runtime value of a tunable and the value persisted in modprobe.d can
    # differ (a live `echo > /sys/module/...` is lost on reboot; a modprobe.d
    # entry added after boot is not yet active). Both are reported.
    section "B. ZFS module parameters (runtime + persisted)"
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
    probe_pipe "kernel cmdline zfs options" cat "{ tr ' ' '\n' < /proc/cmdline; } 2>/dev/null | grep -iE 'zfs|spl' || true"
}

# -- C. Pool topology & allocation classes --------------------------------
_rep_c() {
    section "C. Pool topology & allocation classes"
    # One call: the raw lines here are also the bundle's zpool-list-v.txt.
    # The class of a top-level vdev (special / logs / cache / dedup) and its
    # shape (mirror-N / raidzP-N / draid) are in these lines.
    zprobe "zpool list -v (raw)" zpool list -v; _keep zpool-list-v
    subsection "zpool status"
    # -v and -t combined in one call: -t only annotates the same vdev tree with
    # trim state, so two separate calls would print the tree twice. The answer
    # to the support test is the one printed.
    local zst
    if zst="$(run_bounded "$CMD_TIMEOUT" zpool status -vt)"; then
        # succeeded but printed nothing (no pool imported): one line, as probe says it
        if [ -n "$zst" ]; then _emit_labeled "zpool status -vt (verbose + trim state per vdev)" "$zst"
        else fact "zpool status -vt (verbose + trim state per vdev): n/a (empty output)"; fi
    else
        zprobe "zpool status -v" zpool status -v
        zprobe "zpool status -t (trim state per vdev)" zpool status -t
    fi
    zprobe "zpool status -x (health summary)" zpool status -x
    subsection "metaslab / allocator counters (global kstat)"
    read_proc "metaslab_stats" "$KSTAT_DIR/metaslab_stats"
    subsection "vdev device paths"
    local p
    for p in $ZPOOLS; do
        probe_pipe "$p: leaf device paths (zpool status -P)" zpool \
            "zpool status -PL '$p' 2>/dev/null | awk 'NF>=2 && \$1 ~ /^\\// {print \$1\"  \"\$2}' || true"
    done
    [ -z "$ZPOOLS" ] && fact "leaf device paths: n/a ($(_nopool_why))"
}

# -- D. Pool properties, features & capacity ------------------------------
_rep_d() {
    local p
    section "D. Pool properties, features & capacity"
    zprobe "zpool list" zpool list
    for p in $ZPOOLS; do
        subsection "$p"
        zprobe "zpool get all $p" zpool get all "$p"
    done
    [ -z "$ZPOOLS" ] && fact "zpool get all: n/a ($(_nopool_why))"
    subsection "dataset space overview (zfs list -o space)"
    probe_t 60 "zfs list -o space" zfs list -o space
    # The file count of each mounted dataset: ZFS has no inode table, and IUsed
    # is the number of objects (README.md, section D). statfs only, no walk.
    subsection "file count per mounted dataset (df -i -t zfs)"
    probe_t 60 "df -i -t zfs" df -i -t zfs
}

# -- E. Dataset block size & compression ----------------------------------
_rep_e() {
    # Each row carries its property source: an inherited or default value and a
    # deliberately set one are different facts.
    section "E. Dataset block size & compression"
    fact "datasets (filesystem+volume): ${DS_COUNT:-0}"
    if has_property special_small_blocks; then
        fact "special_small_blocks property: reported by this zfs build"
    else
        fact "special_small_blocks property: not reported by this zfs build (or no dataset enumerated)"
    fi
    subsection "block size, compression, cache and mount properties, every filesystem and volume (zfs get rows)"
    local r; r="$(zget_rows "type recordsize special_small_blocks volblocksize compression compressratio logbias sync primarycache atime mounted canmount secondarycache relatime dedup checksum copies reservation refreservation snapdir")"
    if [ -n "$r" ]; then printf '%s\n' "$r" | _indent '        '
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
}

# -- F. Snapshots, clones & space accounting ------------------------------
_rep_f() {
    local p
    section "F. Snapshots, clones & space accounting"
    # used / avail / usedby* are D's zfs list -o space; these are the rest
    subsection "space properties not in zfs list -o space (zfs get rows)"
    local r; r="$(zget_rows "referenced logicalused logicalreferenced written quota refquota")"
    if [ -n "$r" ]; then printf '%s\n' "$r" | _indent '        '
    else fact "n/a (no dataset property dump)"; fi
    subsection "snapshot inventory"
    if [ -n "$ZSNAP_RC" ] && [ "$ZSNAP_RC" -eq 0 ]; then fact "snapshot count (all pools): ${SNAP_COUNT:-0}"
    elif [ -z "$ZSNAP_RC" ]; then fact "snapshot count (all pools): n/a (command not found: zfs)"
    elif [ "$ZSNAP_RC" -eq 124 ]; then fact "snapshot count (all pools): n/a ($( _hung zfs && _skip_why zfs || echo "zfs list -t snapshot did not answer within ${ZSNAP_CAP}s"))"
    else fact "snapshot count (all pools): n/a (zfs list -t snapshot exit $ZSNAP_RC${ZSNAP_ERR:+: $ZSNAP_ERR})"; fi
    if [ -n "$_ZSNAP" ] && [ -s "$_ZSNAP" ]; then
        # counts are emitted as a bare numeric column so `sort -k2,2nr` orders
        # them numerically (a formatted "snapshots=N" field would sort as text)
        probe_pipe "snapshot count per dataset (top 30 by count)" awk \
            "printf '%-52s %10s %20s\n' DATASET SNAPSHOTS USED_BYTES; awk -F'\t' '{split(\$1,a,\"@\"); c[a[1]]++; u[a[1]]+=\$2} END{for(d in c) printf \"%-52s %10d %20d\n\", d, c[d], u[d]}' '$_ZSNAP' | sort -k2,2nr | head -n 30 || true"
        local _old _new
        _old="$(awk -F'\t' 'NR==1{m=$4;s=$1} $4+0<m+0{m=$4;s=$1} END{if(NR)printf "%s\t%s", s, m}' "$_ZSNAP" 2>/dev/null)"
        _new="$(awk -F'\t' 'NR==1{m=$4;s=$1} $4+0>m+0{m=$4;s=$1} END{if(NR)printf "%s\t%s", s, m}' "$_ZSNAP" 2>/dev/null)"
        if [ -n "$_old" ]; then
            fact "oldest snapshot: $(printf '%s' "$_old" | cut -f1) (creation $(_epoch_iso "$(printf '%s' "$_old" | cut -f2)"))"
            fact "newest snapshot: $(printf '%s' "$_new" | cut -f1) (creation $(_epoch_iso "$(printf '%s' "$_new" | cut -f2)"))"
        else
            fact "oldest / newest snapshot: n/a (empty output)"
        fi
        probe_pipe "snapshots holding a user hold (userrefs > 0)" awk \
            "awk -F'\t' '\$5+0>0 {n++; if(n<=20) printf \"%s userrefs=%s\n\", \$1, \$5} END{printf \"total_with_holds=%d\n\", n+0}' '$_ZSNAP' || true"
        probe_pipe "snapshots with a clone attached (first 30)" awk \
            "awk -F'\t' '\$7!=\"-\" && \$7!=\"\" {n++; if(n<=30) printf \"%s  clones=%s\n\", \$1, \$7} END{printf \"total_snapshots_with_clones=%d\n\", n+0}' '$_ZSNAP' || true"
    else
        if [ -z "$ZSNAP_RC" ]; then fact "snapshot detail: n/a (command not found: zfs)"
        elif [ "$ZSNAP_RC" -eq 124 ] && _hung zfs; then fact "snapshot detail: n/a ($(_skip_why zfs))"
        elif [ "$ZSNAP_RC" -eq 124 ]; then fact "snapshot detail: n/a (zfs list -t snapshot did not answer within ${ZSNAP_CAP}s)"
        elif [ "$ZSNAP_RC" -ne 0 ]; then fact "snapshot detail: n/a (zfs list -t snapshot exit $ZSNAP_RC${ZSNAP_ERR:+: $ZSNAP_ERR})"
        else fact "snapshot detail: none (zfs list -t snapshot ran and listed no snapshot)"; fi
    fi
    subsection "clones (the filesystem/volume side: which dataset has an origin)"
    if [ -n "$_ZGETALL" ] && [ -s "$_ZGETALL" ]; then
        probe_pipe "clone origins" awk \
            "awk -F'\t' '\$2==\"origin\" && \$3!=\"-\" {printf \"%-38s origin=%s\n\", \$1, \$3}' '$_ZGETALL' || true"
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
}

# -- G. ARC / L2ARC / memory ----------------------------------------------
_rep_g() {
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
    fact "/proc/spl/kmem/slab: $( [ -e /proc/spl/kmem/slab ] && echo 'present (not inlined in this report)' || echo 'absent (path not found)' )"
}

# -- H. Write path: transaction groups & ZIL ------------------------------
_rep_h() {
    # The txgs kstat is a ring buffer of the last zfs_txg_history transaction
    # groups with, per txg, the bytes dirtied and the time spent in each state.
    # When zfs_txg_history is 0 the file exists but stays empty (see section B).
    section "H. Write path: transaction groups & ZIL"
    local kd pn
    for kd in "$KSTAT_DIR"/*/; do
        kd="${kd%/}"   # the glob's trailing slash would print as <pool>//zil
        [ -d "$kd" ] || continue
        pn="${kd##*/}"
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
}

# -- I. Per-dataset I/O counters (objset kstats) --------------------------
_rep_i() {
    section "I. Per-dataset I/O counters (objset kstats)"
    fact "source: $KSTAT_DIR/<pool>/objset-<objsetid>; counters are cumulative since pool import"
    local f any=0
    for f in "$KSTAT_DIR"/*/objset-*; do
        [ -f "$f" ] || continue
        any=1; read_proc "${f#"$KSTAT_DIR"/}" "$f"
    done
    [ "$any" = 0 ] && fact "n/a (no objset-* kstat file found under $KSTAT_DIR)"
    subsection "other kstat entries present but not inlined above"
    if [ -d "$KSTAT_DIR" ]; then
        # dbufs is deliberately never read: it enumerates every dbuf in the ARC
        # and can be very large and lock-heavy on a busy host.
        probe_pipe "kstat inventory" find \
            "find '$KSTAT_DIR' -maxdepth 2 \\( -type f -o -type d \\) 2>/dev/null | sed \"s#^$KSTAT_DIR/*##\" | grep -vE '^(arcstats|dbufstats|abdstats|zfetchstats|dnodestats|vdev_cache_stats|dmu_tx|zil|dbufs|dbgmsg|metaslab_stats|zstd|brtstats|fm|)\$' | grep -vE '/(txgs|zil|state|iostats|reads|multihost|dmu_tx_assign)\$' | grep -vE '/objset-' | sort || true"
    else
        fact "kstat inventory: n/a (path not found: $KSTAT_DIR)"
    fi
}

# -- J. I/O request size & latency distribution ---------------------------
_rep_j() {
    # zpool iostat without an interval is the since-boot kstat values (instant,
    # load-free): -r the request-size histogram, -w the latency histogram.
    # Interval values over a span of time are --window's (section O).
    section "J. I/O request size & latency distribution"
    subsection "cumulative since boot (instant kstat read)"
    # Each answer is kept for the bundle's zfs/zpool-iostat-*.txt (_reuse).
    # -r / -w: the whole output is kept (tee), the first 400 lines printed.
    zprobe "zpool iostat -v" zpool iostat -v; _keep zpool-iostat-v
    zprobe "zpool iostat -lv (latency)" zpool iostat -lv; _keep zpool-iostat-lv
    zprobe "zpool iostat -qv (queue depth, instantaneous)" zpool iostat -qv; _keep zpool-iostat-qv
    probe_pipe "zpool iostat -r (request size histogram, first 400 lines)" zpool \
        "zpool iostat -r 2>/dev/null | tee '$(_tmp keep-zpool-iostat-r)' | awk 'NR <= 400' || true"
    probe_pipe "zpool iostat -w (latency histogram, first 400 lines)" zpool \
        "zpool iostat -w 2>/dev/null | tee '$(_tmp keep-zpool-iostat-w)' | awk 'NR <= 400' || true"
}

# -- K. Underlying block devices ------------------------------------------
_rep_k() {
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
    probe_pipe "iostat -x (cumulative since boot)" iostat "iostat -x 2>/dev/null | tee '$(_tmp keep-iostat-x)' | awk 'NR <= 60' || true"
    fact "multipath: $( have multipath && echo 'command present (multipath -ll not run in this report)' || echo 'n/a (command not found: multipath)' )"
}

# -- L. Pool events, errors & maintenance ---------------------------------
_rep_l() {
    local p
    section "L. Pool events, errors & maintenance"
    # One read of the ring (zevents_split; why the whole of it: README.md,
    # section L). A bundle run keeps its files in zfs/.
    if ! have zpool; then fact "zpool events: n/a (command not found: zpool)"
    elif _hung zpool; then fact "zpool events: n/a ($(_skip_why zpool))"
    else
        [ -n "$ZEV_DIR" ] || ZEV_DIR="$(_tmp zevents)"
        if ! mkdir -p "$ZEV_DIR" 2>/dev/null; then fact "zpool events: n/a (no private temp directory for its output)"
        else
            zevents_split "$ZEV_DIR"
            case "$ZEV_RC" in
                0) ;;
                124) if _past_deadline; then fact "zpool events: stopped (run deadline reached: ${RUN_DEADLINE}s); the lines below cover the part read"
                     else fact "zpool events: stopped at the ${ZEV_CAP}s cap; the lines below cover the part read"; fi ;;
                *) fact "zpool events: exit $ZEV_RC${ZEV_ERR:+: $ZEV_ERR}$(_priv_hint)" ;;
            esac
            _emit_labeled "zpool events$( [ "$ZEV_V" = 1 ] && echo ' -v'): per class over the whole ring buffer" \
                "$(awk -F'\t' '/^#/ { print; next } { printf "%-44s %10s  %-10s  %s\n", $1, $2, $3, $4 }' "$ZEV_DIR/zpool-events-overview.tsv" 2>/dev/null)"
            if [ -s "$(_tmp zevents-last.txt)" ]; then _emit_labeled "zpool events: the last 100 events" "$(cat "$(_tmp zevents-last.txt)")"
            else fact "zpool events: the last 100 events: none"; fi
        fi
    fi
    for p in $ZPOOLS; do
        probe_pipe_t 60 "$p: zpool history (last 200, stderr folded in)" zpool "zpool history '$p' 2>&1 | tail -n 200 || true"
    done
    [ -z "$ZPOOLS" ] && fact "zpool history: n/a ($(_nopool_why))"
    subsection "fault management kstat"
    read_proc "fm" "$KSTAT_DIR/fm"
    subsection "kernel messages"
    probe_pipe "dmesg (zfs/spl/zio/txg lines, last 100)" dmesg \
        "dmesg 2>/dev/null | grep -iE 'zfs|spl:|zio|txg|ZIL|arc_' | tail -n 100 || true"
    read_proc "spl debug ring (dbgmsg, last 200 lines)" "$KSTAT_DIR/dbgmsg" 200
    subsection "journal for zfs units (last ${OPT_HOURS}h, bounded)"
    if have journalctl; then
        local u2
        for u2 in $ZFS_JOURNAL_UNITS; do
            unit_loaded "$u2.service" || continue
            local jo
            jo="$(_bounded journalctl -u "$u2.service" -p warning --since "${OPT_HOURS} hours ago" -n 30 --no-pager 2>/dev/null)"
            if [ $? -eq 124 ]; then fact "$u2.service: n/a ($(_why_124))"
            elif [ -n "$jo" ]; then fact "$u2.service (last 30 at warning+):"; printf '%s\n' "$jo" | while IFS= read -r _l; do blk "$_l"; done
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
}

# -- N. Deep block & metaslab statistics (opt-in) -------------------------
_rep_n() {
    local p
    section "N. Deep block & metaslab statistics (opt-in)"
    if [ "$OPT_ZDB" = 1 ]; then
        if ! have zdb; then
            fact "zdb: n/a (command not found: zdb)"
        else
            # zdb opens the pool devices directly; stderr is folded in so a
            # non-root "can't open '<pool>': Permission denied" stays visible.
            fact "uid for this run: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root )) — zdb opens the pool devices directly"
            # A bundle run writes zdb's whole output to zdb/ instead (_zdb_bundle):
            # one run of each zdb call, never both.
            if [ -n "$BUNDLE_WORK" ]; then _zdb_bundle "$BUNDLE_WORK/zdb"
            else
                for p in $ZPOOLS; do
                    subsection "$p (zdb)"
                    warn "[Tier2] zdb -C $p — reads the pool configuration"
                    progress "zdb -C $p ..."
                    probe_pipe_t 120 "zdb -C $p (config; per-vdev ashift and allocation class)" zdb \
                        "zdb -C '$p' 2>&1 | head -n 400 || true"
                    warn "[Tier2] zdb -Lbbbs $p — traverses pool metadata; takes minutes on a large pool and reads the data disks"
                    progress "zdb -Lbbbs $p (block statistics; this is the long one) ..."
                    # Its \r-separated "estimated time remaining" progress on stderr
                    # is split and dropped; the rest of stderr is kept.
                    probe_pipe_t 1800 "zdb -Lbbbs $p (block/psize/lsize histogram, measured compression; first 500 lines)" zdb \
                        "zdb -Lbbbs '$p' 2>&1 | tr '\r' '\n' | grep -v 'estimated time remaining' | head -n 500 || true"
                    warn "[Tier2] zdb -mm $p — loads metaslab space maps"
                    progress "zdb -mm $p (metaslab free-space histograms) ..."
                    probe_pipe_t 1800 "zdb -mm $p (metaslab free-space histograms; first 500 lines)" zdb \
                        "zdb -mm '$p' 2>&1 | head -n 500 || true"
                done
                [ -z "$ZPOOLS" ] && fact "zdb: n/a ($(_nopool_why))"
            fi
        fi
    else
        fact "zdb block/metaslab statistics: n/a (not applicable: --zdb not given)"
    fi
    subsection "file-size histogram (--filesizes)"
    if [ "$OPT_FILESIZES" = 1 ]; then
        local fp="$FILESIZES_PATH"
        if [ ! -d "$fp" ]; then
            fact "n/a (path not found: $fp)"
        elif ! find /dev/null -maxdepth 0 -printf '' 2>/dev/null; then
            fact "n/a (find -printf not supported by this build; GNU find is needed)"
        else
            warn "[Tier2] file-size histogram: walking $fp — a metadata read of the whole tree (special vdev and ARC load), bounded to ${FILESIZES_SECS}s"
            progress "walking $fp for the file-size histogram ..."
            fact "path: $fp (single filesystem, -xdev)"
            local fh; fh="$(filesize_histogram "$fp")"
            if [ -n "$fh" ]; then printf '%s\n' "$fh" | while IFS= read -r _l; do blk "$_l"; done
            else fact "n/a (empty output or timed out: ${FILESIZES_SECS}s)"; fi
        fi
    else
        fact "not requested (--filesizes not given)"
    fi
}

run_report() {
    emit_header

    goal zfs   "ZFS present on this host"
    goal pools "pool topology and properties"
    [ "$ZFS_ON_HOST" = 1 ] && goal datasets "dataset properties and snapshots"

    _rep_env
    if [ "$ZFS_ON_HOST" != 1 ]; then
        section "A. ZFS software & kernel module"
        fact "n/a (not applicable: no zfs/zpool command and no $KSTAT_DIR on this host)"
        fact "sections B..L: not collected (no zfs/zpool command and no $KSTAT_DIR)"
        # A short report that answers none of this collector's questions: the
        # status says so.
        na zfs "no zfs or zpool command and no $KSTAT_DIR on this host"
        na pools "no zfs or zpool command and no $KSTAT_DIR on this host"
        goal window "$WIN_GOAL"
        na window "no zfs or zpool command and no $KSTAT_DIR on this host"
        emit_status
        emit_footer
        return
    fi

    _rep_a
    _rep_b
    _rep_c
    _rep_d
    _rep_e
    _rep_f
    _rep_g
    _rep_h
    _rep_i
    _rep_j
    _rep_k
    _rep_l
    # M (WhaTap paths -> dataset) was removed in 0.12.0: collect-collserver.sh
    # section C has it. N and O keep their letters.
    _rep_n
    _rep_o
    got zfs
    _resolve_pools
    _resolve_datasets

    emit_status
    emit_footer
}

# _nopool_why -> why there is no pool to ask about: the list was not answered,
# or it answered with none
_nopool_why() {
    if [ -z "$ZPOOL_RC" ]; then printf 'not queried: command not found: zpool'
    elif [ "$ZPOOL_RC" -eq 124 ]; then printf 'not queried: %s' "$HUNG_ZPOOL_WHY"
    elif [ "$ZPOOL_RC" -ne 0 ]; then printf 'not queried: zpool list exit %s%s' "$ZPOOL_RC" "${ZPOOL_ERR:+: $ZPOOL_ERR}"
    else printf 'zpool list ran and listed no pool'; fi
}

# _module_absent_msg TEXT -> true when TEXT is zpool/zfs saying the kernel module
# is not loaded (never a permission refusal)
_module_absent_msg() {
    printf '%s' "$1" | grep -qiE 'modules are not loaded|/dev/zfs.*no such file' \
        && ! printf '%s' "$1" | grep -qiE 'permission|not permitted'
}

# _resolve_pools -> the pools goal, on a host where some ZFS was found. "No pool"
# is an answer only when `zpool list` ran and listed none. A zpool that failed,
# was refused or timed out has not shown that there is no pool, and a missing
# zpool binary next to a loaded kernel module has not asked.
_resolve_pools() {
    local uid; uid="${_priv_uid:-?}"
    if [ -z "$ZPOOL_RC" ]; then
        missed pools "command not found: zpool (while $( [ -d "$KSTAT_DIR" ] && echo "$KSTAT_DIR exists" || echo "zfs is installed" ))"
    elif [ "$ZPOOL_RC" -eq 0 ] && [ "$ZPOOL_COUNT" -gt 0 ] 2>/dev/null; then
        got pools
    elif [ "$ZPOOL_RC" -eq 0 ]; then
        na pools "zpool list ran and listed no imported pool"
    elif [ "$ZPOOL_RC" -eq 124 ]; then
        missed pools "zpool list did not answer within ${CMD_TIMEOUT}s"
    elif [ ! -d "$KSTAT_DIR" ] && _module_absent_msg "$ZPOOL_ERR"; then
        # The kernel side is absent: /proc/spl was read and there is no ZFS in
        # this kernel for a pool to be imported into.
        na pools "zfs kernel module not loaded ($KSTAT_DIR absent; zpool: $ZPOOL_ERR)"
    else
        case "$ZPOOL_ERR" in
            *[Pp]ermission*|*"not permitted"*) missed pools "zpool list failed for uid $uid (exit $ZPOOL_RC): $ZPOOL_ERR$(_priv_hint)" ;;
            *) missed pools "zpool list failed (exit $ZPOOL_RC)${ZPOOL_ERR:+: $ZPOOL_ERR}" ;;
        esac
    fi
}

# _resolve_datasets -> the datasets goal: `zfs get all` and the snapshot list
# ran and answered. A hang, a failure or a missing zfs binary is blocked; an
# empty answer is n/a only when zpool also listed no pool.
_resolve_datasets() {
    if [ -z "$ZGET_RC" ]; then missed datasets "command not found: zfs"
    elif [ "$ZGET_RC" -eq 124 ]; then missed datasets "$HUNG_ZFS_WHY"
    elif [ "$ZGET_RC" -ne 0 ] && [ ! -d "$KSTAT_DIR" ] && _module_absent_msg "$ZGET_ERR"; then
        na datasets "zfs kernel module not loaded ($KSTAT_DIR absent; zfs: $ZGET_ERR)"
    elif [ "$ZGET_RC" -ne 0 ]; then
        case "$ZGET_ERR" in
            *[Pp]ermission*|*"not permitted"*) missed datasets "zfs get failed (exit $ZGET_RC): $ZGET_ERR$(_priv_hint)" ;;
            *) missed datasets "zfs get failed (exit $ZGET_RC)${ZGET_ERR:+: $ZGET_ERR}" ;;
        esac
    elif [ "$ZSNAP_RC" -eq 124 ]; then missed datasets "zfs list -t snapshot did not answer within ${ZSNAP_CAP}s"
    elif [ "$ZSNAP_RC" -ne 0 ]; then missed datasets "zfs list -t snapshot failed (exit $ZSNAP_RC)${ZSNAP_ERR:+: $ZSNAP_ERR}"
    elif [ "$DS_COUNT" -gt 0 ] 2>/dev/null; then got datasets
    elif [ "${ZPOOL_COUNT:-0}" -gt 0 ] 2>/dev/null; then missed datasets "zfs get listed no dataset while zpool listed $ZPOOL_COUNT pools"
    else na datasets "zfs get ran and listed no filesystem or volume"; fi
}

# zevents_split DESTDIR -> split one read of `zpool events` into a tally and a
# window. Why the tally covers the whole buffer: README.md, section L. Read ONCE
# (a second pass costs the same minutes and sees a moved buffer) into:
#   zpool-events-tally.tsv     class x date x vdev, counted over the whole buffer
#   zpool-events-overview.tsv  class, count, first date, last date (section L)
#   zpool-events-v.txt         full detail, but only for the last OPT_EVENT_DAYS
# A bundle run reads `zpool events -v` for the detail; a report run reads the
# short form (the event lines only: no vdev, no detail file). ZEV_RC / ZEV_ERR:
# the read's exit status and first stderr line.
ZEV_DIR="" ZEV_V=0 ZEV_RC="" ZEV_ERR="" ZEV_CAP=180
BUNDLE_WORK=""       # the bundle's work dir while do_bundle runs the report
zevents_split() {
    local d="$1" cut="" err detail=/dev/null
    err="$(_tmp zevents.err)"
    if [ "$ZEV_V" = 1 ]; then
        ZEV_CAP=600; detail="$d/zpool-events-v.txt"
        if [ "$OPT_EVENT_DAYS" -gt 0 ] 2>/dev/null; then
            # No GNU date -> cut stays empty -> the detail window is "everything".
            # That is the old behaviour, which is safe, and the tally still works.
            cut="$(date -u -d "$OPT_EVENT_DAYS days ago" +%Y-%m-%d 2>/dev/null || true)"
        fi
        progress "zfs: reading the zevent ring buffer (tally over all of it, detail for ${OPT_EVENT_DAYS}d) ..."
    else
        progress "zfs: reading the zevent ring buffer (tally over all of it) ..."
    fi
    # shellcheck disable=SC2046  # -v or nothing
    CMD_TIMEOUT="$ZEV_CAP" _bounded zpool events $( [ "$ZEV_V" = 1 ] && echo -v ) 2>"$err" | awk -v CUT="$cut" \
        -v TALLY="$d/zpool-events-tally.tsv" \
        -v OVER="$d/zpool-events-overview.tsv" \
        -v DETAIL="$detail" -v V="$ZEV_V" \
        -v LAST="$(_tmp zevents-last.txt)" '
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
            ring[seen % 100] = $0
            keep = V && (CUT == "" || date >= CUT)
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
            if (V) {
                printf "# detail kept in zpool-events-v.txt: %d", kept > OVER
                if (CUT != "") printf " (since %s)\n", CUT > OVER; else printf " (all)\n" > OVER
            }
            for (i = (seen > 100 ? seen - 99 : 1); i <= seen; i++) print ring[i % 100] > LAST
        }
    '
    ZEV_RC="${PIPESTATUS[0]}"
    ZEV_ERR="$(head -n1 "$err" 2>/dev/null | cut -c1-160)"
    # the classes by count, largest first
    local o="$d/zpool-events-overview.tsv"
    [ -f "$o" ] && { head -n 1 "$o"; sed '1d; /^#/d' "$o" | sort -t "$_tab" -k2,2nr; grep '^#' "$o"; } > "$o.s" 2>/dev/null && mv -f "$o.s" "$o"
    # A pool with no events at all leaves no files; say so rather than leaving a
    # reader to wonder whether the collector skipped the step.
    [ -f "$d/zpool-events-overview.tsv" ] || printf 'class\tcount\tfirst\tlast\n# no events returned (empty buffer, or permission denied for this uid)\n' > "$d/zpool-events-overview.tsv"
    [ "$ZEV_V" = 1 ] && { [ -f "$d/zpool-events-v.txt" ] || : > "$d/zpool-events-v.txt"; }
    return 0
}

# =============================================================================
# Write-path window (--window; Tier 1: wall-clock, kstat file reads only)
# =============================================================================
# How the ring is read, merged, gapped and retried: README.md, "How the txgs
# ring is read" (section O). WIN_IV_MIN/MAX below are that read interval's
# clamp.
WIN_IV_MIN=2
WIN_IV_MAX=300
WIN_ROW_CAP=20000       # merged rows kept per pool
WIN_RESERVE=120         # seconds of the run deadline left for the report
WIN_IOSTAT_LINES=6000   # zpool iostat -v lines printed in the report
WIN_DIR=""
WIN_RAN=0               # 1 once the window started
WIN_SIG=""              # INT / TERM / HUP that ended the window
WIN_T0="" WIN_T1=""     # epoch at start and end of the window
WIN_CUT=""              # set when the run deadline ended the window early
WIN_SKIP=""             # why no window ran
WIN_IO_IV=0 WIN_IO_N=0
WIN_IO_GRACE=5          # seconds the interval jobs get after the window ends
WIN_PLAN=0              # the window's planned length, after a deadline cut
WIN_IV_LO="" WIN_IV_HI=""   # the read intervals actually slept
_win_sp=""

# ---- interval jobs of the window (zpool iostat, iostat -x, histograms, arcstat)
# Why they start together at the same interval/count, and per-job output
# files: README.md, section O.
IOSTAT_FL=""         # the iostat -x flags this sysstat takes (_iostat_flags)
IOSTAT_FL_NOTE=""    # what was dropped, and so what the output lacks

# _iostat_flags -> IOSTAT_FL: "-x -N -t" when this iostat takes -N (device-mapper
# names) and -t (timestamps), else fewer; asked once, of the since-boot report
_iostat_flags() {
    [ -n "$IOSTAT_FL" ] && return 0
    if _bounded iostat -x -N -t >/dev/null 2>&1; then IOSTAT_FL="-x -N -t"
    elif _bounded iostat -x -t >/dev/null 2>&1; then
        IOSTAT_FL="-x -t"; IOSTAT_FL_NOTE="this iostat refused -N; device-mapper devices keep their dm-N names"
    else
        IOSTAT_FL="-x"; IOSTAT_FL_NOTE="this iostat refused -N and -t; its blocks carry no timestamp (align them from the start time)"
    fi
}

# _bg_start DIR NAME CAP CMD... -> CMD in the background under _bounded, capped
# at CAP: DIR/NAME.txt (stdout), .err, .rc (exit status, once it ended),
# .t0 (ms since the epoch, just before the fork), .pid
_bg_start() {
    local d="$1" n="$2" c="$3"
    shift 3
    rm -f "$d/$n.rc" "$d/$n.stop" 2>/dev/null
    _now_ms; printf '%s\n' "$_ms" > "$d/$n.t0"
    ( [ "$1" = iostat ] && export S_TIME_FORMAT=ISO
      CMD_TIMEOUT="$c" _bounded "$@" > "$d/$n.txt" 2> "$d/$n.err"
      echo $? > "$d/$n.rc" ) &
    echo "$!" > "$d/$n.pid"
}

# _bg_end DIR NAME GRACE WHY -> wait up to GRACE seconds for the job; one still
# running then is stopped, and WHY (why it was stopped) goes to DIR/NAME.stop
_bg_end() {
    local d="$1" n="$2" g="$3" p k=0
    p="$(cat "$d/$n.pid" 2>/dev/null)"
    [ -n "$p" ] || return 0
    while kill -0 "$p" 2>/dev/null && [ "$k" -lt "$g" ]; do _win_sleep 1; k=$((k + 1)); done
    if kill -0 "$p" 2>/dev/null; then
        _kill_tree TERM "$p"
        printf 'stopped at %s: %s\n' "$(_win_local "$(date +%s)")" "$4" > "$d/$n.stop"
    fi
    wait "$p" 2>/dev/null
    rm -f "$d/$n.pid"
}

# _ms_local MS -> "YYYY-MM-DD HH:MM:SS.mmm TZ"
_ms_local() {
    local s=$(( $1 / 1000 )) m=$(( $1 % 1000 ))
    printf '%s.%03d %s' "$(date -d "@$s" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'epoch %s' "$s")" "$m" "$(date -d "@$s" +%Z 2>/dev/null)"
}

# _bg_emit DIR NAME LABEL LINES -> the job's start, how it ended and its output
# (first LINES lines) as facts. BG_WHY: why it did not deliver, or empty.
BG_WHY=""
_bg_emit() {
    local d="$1" n="$2" lab="$3" cap="$4" rc t0 st c short
    BG_WHY=""
    short="${lab%% (*}"
    t0="$(cat "$d/$n.t0" 2>/dev/null)"; rc="$(cat "$d/$n.rc" 2>/dev/null)"
    if [ -f "$d/$n.stop" ]; then st="$(cat "$d/$n.stop") (output up to then below)"; BG_WHY="$short: $(cat "$d/$n.stop")"
    elif [ "$rc" = 124 ]; then st="capped by its bound (output up to the cap below)"; BG_WHY="$short: capped by its bound"
    elif [ "$rc" = 0 ]; then st="exit 0"
    elif [ -z "$rc" ]; then st="no exit status recorded (output up to then below)"; BG_WHY="$short: no exit status"
    else st="exit $rc$( [ -s "$d/$n.err" ] && printf ': %s' "$(head -n1 "$d/$n.err" | cut -c1-120)")"; BG_WHY="$short: $st"; fi
    fact "$lab"
    fact "  started $( [ -n "$t0" ] && _ms_local "$t0" || echo n/a ); $st"
    if [ -s "$d/$n.txt" ]; then
        c="$(wc -l < "$d/$n.txt" | tr -d ' ')"
        [ "$c" -gt "$cap" ] && fact "  (first $cap of $c lines; all of them in the bundle)"
        head -n "$cap" "$d/$n.txt" | while IFS= read -r l; do blk "$l"; done
    else
        fact "  n/a (no output)"
        [ -n "$BG_WHY" ] || BG_WHY="$short: no output"
    fi
}

# _pair_start DIR IV N CAP -> zpool iostat -T d -vlq IV N and iostat -x IV N,
# started back to back (zpool first); PAIR_WHY names a zpool iostat that was
# not run. iostat -x only adds the block-device view: what it did not deliver
# (absent, failed, stopped) goes to PAIR_IO_NOTE, a fact line, never the goal.
PAIR_WHY=""
PAIR_IO_NOTE=""
_pair_start() {
    local d="$1" iv="$2" n="$3" cap="$4"
    PAIR_WHY=""; PAIR_IO_NOTE=""
    mkdir -p "$d" 2>/dev/null
    have iostat && _iostat_flags
    if ! have zpool; then PAIR_WHY="zpool iostat: command not found"
    elif _hung zpool; then PAIR_WHY="zpool iostat: $(_skip_why zpool)"
    else _bg_start "$d" zpool "$cap" zpool iostat -T d -vlq "$iv" "$n"; fi
    if have iostat; then
        # shellcheck disable=SC2086  # IOSTAT_FL is a list of flags
        _bg_start "$d" iostat "$cap" iostat $IOSTAT_FL "$iv" "$n"
    else PAIR_IO_NOTE="iostat -x: command not found (sysstat)"; fi
}

# _pair_kill DIR -> stop every job still running under DIR
_pair_kill() {
    local f p
    for f in "$1"/*.pid; do
        [ -f "$f" ] || continue
        p="$(cat "$f" 2>/dev/null)"
        [ -n "$p" ] && _kill_tree TERM "$p"
    done
}

# _pair_emit DIR IV N LINES -> both jobs' facts and the start offset between
# them; PAIR_WHY collects what did not deliver
_pair_emit() {
    local d="$1" iv="$2" n="$3" cap="$4" a b
    fact "interval ${iv}s, $n blocks each; the first block of each is cumulative (zpool: since pool import; iostat: since boot)"
    a="$(cat "$d/zpool.t0" 2>/dev/null)"; b="$(cat "$d/iostat.t0" 2>/dev/null)"
    [ -n "$a" ] && [ -n "$b" ] && fact "start offset: iostat -x started $((b - a)) ms after zpool iostat"
    if [ -f "$d/zpool.t0" ]; then
        _bg_emit "$d" zpool "zpool iostat -T d -vlq $iv $n (per vdev: operations, bandwidth, total_wait, disk_wait, syncq/asyncq_wait, queue depths):" "$cap"
        [ -n "$BG_WHY" ] && PAIR_WHY="${PAIR_WHY:+$PAIR_WHY; }$BG_WHY"
    fi
    if [ -f "$d/iostat.t0" ]; then
        [ -n "$IOSTAT_FL_NOTE" ] && fact "iostat flags: $IOSTAT_FL ($IOSTAT_FL_NOTE)"
        _bg_emit "$d" iostat "iostat $IOSTAT_FL $iv $n (per device: r/s w/s rkB/s wkB/s r_await w_await aqu-sz %util):" "$cap"
        [ -n "$BG_WHY" ] && PAIR_IO_NOTE="$BG_WHY"
    fi
    [ -n "$PAIR_WHY" ] && fact "not delivered: $PAIR_WHY"
    [ -n "$PAIR_IO_NOTE" ] && fact "not delivered: $PAIR_IO_NOTE"
}

# ---- collection-server: window — DO NOT EDIT --------------------------------
# members: collmysql collzfs
# _win_secs DUR -> seconds for N, Ns, Nm or Nh (10 .. 86400); 1 when not one
_win_secs() {
    local v="$1" n u
    case "$v" in
        *s) u=1;    n="${v%s}" ;;
        *m) u=60;   n="${v%m}" ;;
        *h) u=3600; n="${v%h}" ;;
        *)  u=1;    n="$v" ;;
    esac
    case "$n" in ''|*[!0-9]*|0*) return 1 ;; esac
    [ "${#n}" -le 6 ] || return 1
    n=$((n * u))
    [ "$n" -ge 10 ] && [ "$n" -le 86400 ] || return 1
    printf '%s' "$n"
}
# ---- end collection-server: window

# _win_local EPOCH -> "YYYY-MM-DD HH:MM:SS TZ (UTC ...Z)"
_win_local() {
    printf '%s (%s)' "$(date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'epoch %s' "$1")" "$(_epoch_iso "$1")"
}

# _win_hms SECS -> 1h02m03s
_win_hms() {
    local s="$1"
    if [ "$s" -ge 3600 ]; then printf '%dh%02dm%02ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
    elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
    else printf '%ds' "$s"; fi
}

# _win_cat SRC DST -> one bounded read of SRC into DST; its exit status
_win_cat() { CMD_TIMEOUT=10 _bounded cat "$1" > "$2" 2>/dev/null; }

# _win_param NAME -> the zfs module parameter's value, or n/a with the reason
_win_param() {
    local f="/sys/module/zfs/parameters/$1" v=""
    if [ ! -e "$f" ]; then printf 'n/a (path not found: %s)' "$f"
    elif { IFS= read -r v < "$f"; } 2>/dev/null; then printf '%s' "$v"
    else printf 'n/a (not readable: %s)' "$f"; fi
}

# _win_on_sig SIG -> the first INT / TERM / HUP ends the window;
# the loop sees WIN_SIG and the report is still written
_win_on_sig() {
    if [ -n "$WIN_SIG" ]; then
        # a second one aborts, as outside the window
        [ -n "$WIN_DIR" ] && _pair_kill "$WIN_DIR/io"
        [ -n "$_win_sp" ] && kill "$_win_sp" 2>/dev/null
        _run_cleanup
        case "$1" in HUP) exit 129 ;; INT) exit 130 ;; *) exit 143 ;; esac
    fi
    WIN_SIG="$1"
    [ -n "$_win_sp" ] && kill "$_win_sp" 2>/dev/null
}
# the run helpers' traps, as _run_init set them
_win_restore_traps() {
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
}

# _win_sleep SECS -> a sleep a trapped signal ends at once
_win_sleep() {
    [ "$1" -gt 0 ] 2>/dev/null || return 0
    sleep "$1" & _win_sp=$!
    wait "$_win_sp" 2>/dev/null
    kill "$_win_sp" 2>/dev/null; _win_sp=""
}

# _win_snap PHASE -> $WIN_DIR/PHASE: epoch, the two txg parameters, dmu_tx,
# arcstats and every pool's objset-* kstats
_win_snap() {
    local d="$WIN_DIR/$1" kd pn f
    mkdir -p "$d/pools" 2>/dev/null
    date +%s > "$d/epoch" 2>/dev/null
    printf 'zfs_txg_history\t%s\nzfs_txg_timeout\t%s\n' \
        "$(_win_param zfs_txg_history)" "$(_win_param zfs_txg_timeout)" > "$d/params" 2>/dev/null
    [ -e "$KSTAT_DIR/dmu_tx" ] && { _win_cat "$KSTAT_DIR/dmu_tx" "$d/dmu_tx" || rm -f "$d/dmu_tx"; }
    [ -e "$KSTAT_DIR/arcstats" ] && { _win_cat "$KSTAT_DIR/arcstats" "$d/arcstats" || rm -f "$d/arcstats"; }
    for kd in "$KSTAT_DIR"/*/; do
        kd="${kd%/}"
        [ -e "$kd/txgs" ] || continue
        pn="${kd##*/}"
        mkdir -p "$d/pools/$pn" 2>/dev/null
        for f in "$kd"/objset-*; do
            [ -f "$f" ] || continue
            _win_cat "$f" "$d/pools/$pn/${f##*/}" || rm -f "$d/pools/$pn/${f##*/}"
        done
    done
}

# One read of a pool's txgs merged into $p/rows. prev: the previous read;
# the state line carries the running values between reads:
#   first last kept over gap part reads fails span_s rmin rmax openend empty
# first = the txg open at the first read (the window's first txg), last = the
# highest txg merged so far.
# shellcheck disable=SC2016  # an awk program, expanded by awk
_WIN_MERGE_AWK='
function keep(line) { if (kept < cap) { print line >> rowsf; kept++ } else over++ }
FILENAME == prevf { if ($1 ~ /^[0-9]+$/) { pr[$1 + 0] = $0; if (pmax == "" || $1 + 0 > pmax) pmax = $1 + 0 }; next }
$1 ~ /^[0-9]+$/ {
    t = $1 + 0; r[t] = $0; s[t] = $3; n++
    if (rmin == "" || t < rmin) { rmin = t; bmin = $2 }
    if (rmax == "" || t > rmax) { rmax = t; bmax = $2 }
}
END {
    empty = 0; span = 0
    if (n == 0) empty = 1
    else {
        if (first == "") { first = rmax; last = rmax - 1 }
        if (rmin > last + 1) {
            g0 = ""; ng = 0
            for (t = last + 1; t < rmin; t++) {
                if (t in pr) { keep(pr[t]); part++; continue }
                if (g0 == "") g0 = t
                g1 = t; ng++
            }
            if (ng) { printf "%s\t%s\t%d\t%s\n", g0, g1, ng, now >> gapf; gap += ng }
            last = rmin - 1
        }
        for (t = last + 1; t <= rmax; t++) {
            if (!(t in r) || s[t] != "C") break
            keep(r[t]); last = t
        }
        if (final) for (t = last + 1; t <= rmax; t++) if (t in r) { keep(r[t]); openend++; last = t }
        span = (bmax - bmin) / 1e9
    }
    printf "%s %s %d %d %d %d %d %d %.3f %s %s %d %d\n", (first == "" ? "-" : first), (last == "" ? "-" : last), \
        kept, over, gap, part, reads + 1, fails, span, (rmin == "" ? "-" : rmin), (rmax == "" ? "-" : rmax), openend, empty
}'

# _win_state FILE -> the state line into w_first .. w_empty (fields as above)
_win_state() {
    w_first=- w_last=- w_kept=0 w_over=0 w_gap=0 w_part=0 w_reads=0 w_fails=0 w_span=0 w_rmin=- w_rmax=- w_open=0 w_empty=1
    { read -r w_first w_last w_kept w_over w_gap w_part w_reads w_fails w_span w_rmin w_rmax w_open w_empty < "$1"; } 2>/dev/null
}

# _win_read POOL FINAL -> one read of POOL's txgs, merged; the reads log gets
# a line (epoch, rows, oldest, newest, span, gaps so far) or the failure
_win_merge() {
    local p="$1" prevf="$2" curf="$3" fin="$4" now="$5" st
    _win_state "$p/state"
    [ -s "$p/rows" ] || head -n 1 "$curf" > "$p/rows" 2>/dev/null
    st="$(awk -v prevf="$prevf" -v rowsf="$p/rows" -v gapf="$p/gaps.tsv" -v cap="$WIN_ROW_CAP" \
        -v first="${w_first#-}" -v last="${w_last#-}" \
        -v kept="$w_kept" -v over="$w_over" -v gap="$w_gap" -v part="$w_part" -v reads="$w_reads" -v fails="$w_fails" \
        -v openend=0 -v final="$fin" -v now="$now" "$_WIN_MERGE_AWK" "$prevf" "$curf" 2>/dev/null)"
    [ -n "$st" ] || return 1
    printf '%s\n' "$st" > "$p/state"
    _win_state "$p/state"
}

# _win_read POOL FINAL -> one read of POOL's txgs, merged; the reads log gets
# a line (epoch, rows, oldest, newest, span, gaps so far) or the failure. A
# txgs that is gone (pool exported) ends the pool: the last good read is
# merged as the final one, and $p/gone holds the failed read's time and the
# last good read's time.
_win_read() {
    local pn="$1" fin="$2" p="$WIN_DIR/txg/$1" rc now lg
    [ -f "$p/gone" ] && return 0
    _win_cat "$KSTAT_DIR/$pn/txgs" "$p/cur"; rc=$?
    [ "$rc" -ne 0 ] && { _win_cat "$KSTAT_DIR/$pn/txgs" "$p/cur"; rc=$?; }
    now="$(date +%s 2>/dev/null)"
    if [ "$rc" -ne 0 ]; then
        if [ ! -e "$KSTAT_DIR/$pn/txgs" ]; then
            lg="$(awk -F'\t' '$2 ~ /^[0-9]+$/ { e = $1 } END { print e }' "$p/reads.tsv" 2>/dev/null)"
            printf '%s\tpath not found: %s\n' "$now" "$KSTAT_DIR/$pn/txgs" >> "$p/reads.tsv"
            printf '%s\t%s\n' "$now" "$lg" > "$p/gone"
            # the last good read's still-open rows, kept as last seen
            [ -s "$p/prev" ] && _win_merge "$p" /dev/null "$p/prev" 1 "$now"
        else
            printf '%s\tread failed (exit %s, asked twice)\n' "$now" "$rc" >> "$p/reads.tsv"
        fi
        _win_state "$p/state"
        printf '%s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$w_first" "$w_last" "$w_kept" "$w_over" "$w_gap" "$w_part" \
            "$( [ -f "$p/gone" ] && [ -s "$p/prev" ] && echo "$w_reads" || echo $((w_reads + 1)) )" "$((w_fails + 1))" \
            "$w_span" "$w_rmin" "$w_rmax" "$w_open" "$w_empty" > "$p/state"
        return 0
    fi
    _win_merge "$p" "$p/prev" "$p/cur" "$fin" "$now" || return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$(( $(wc -l < "$p/cur") - 1 ))" "$w_rmin" "$w_rmax" "$w_span" "$w_gap" >> "$p/reads.tsv"
    cat "$p/cur" > "$p/prev" 2>/dev/null
}

# _win_iv -> seconds to the next read: half the shortest span any pool's ring
# covered at its last read, clamped to [WIN_IV_MIN, WIN_IV_MAX]
_win_iv() {
    local f iv="" h
    for f in "$WIN_DIR"/txg/*/state; do
        [ -f "$f" ] || continue
        [ -f "${f%/state}/gone" ] && continue
        _win_state "$f"
        [ "$w_empty" = 0 ] || continue
        h="${w_span%.*}"; h=$(( ${h:-0} / 2 ))
        { [ -z "$iv" ] || [ "$h" -lt "$iv" ]; } && iv="$h"
    done
    [ -z "$iv" ] && iv="$WIN_IV_MAX"
    [ "$iv" -lt "$WIN_IV_MIN" ] && iv="$WIN_IV_MIN"
    [ "$iv" -gt "$WIN_IV_MAX" ] && iv="$WIN_IV_MAX"
    printf '%s' "$iv"
}

# window_run -> the window, before the report: reads counters, every pool's
# txgs until the end, and counters again. Its
# files are in WIN_DIR; section O prints them and the bundle copies them.
# _win_plan -> sets WIN_DIR, traps INT/TERM/HUP, WIN_RAN, WIN_T0 and the
# caller's (window_run's) e0/end/WIN_PLAN, with the run-deadline cut (WIN_CUT)
# and its warn already printed; or sets WIN_SKIP and returns 1 when the
# window will not run (no private temp dir, no kstat tree, no pool, or the
# run deadline leaves it no time)
_win_plan() {
    local left k n
    WIN_DIR="$(_tmp win)"
    case "$WIN_DIR" in /dev/null) WIN_SKIP="no private temp directory could be made under ${TMPDIR:-/tmp}"; return 1 ;; esac
    [ -d "$KSTAT_DIR" ] || { WIN_SKIP="path not found: $KSTAT_DIR"; return 1; }
    k=""; for n in "$KSTAT_DIR"/*/txgs; do [ -e "$n" ] && { k=1; break; }; done
    [ -n "$k" ] || { WIN_SKIP=nopool; return 1; }
    # a caller's RUN_DEADLINE that leaves the (default) window no time
    left=$((RUN_DEADLINE - WIN_RESERVE - $(_elapsed)))
    if [ "$left" -lt 1 ]; then
        WIN_SKIP="RUN_DEADLINE=$RUN_DEADLINE leaves no time for the ${WIN_SECS}s window (${WIN_RESERVE}s are kept for the report)"
        warn "window: not run: $WIN_SKIP"
        return 1
    fi
    mkdir -p "$WIN_DIR/txg" 2>/dev/null || { WIN_SKIP="cannot create $WIN_DIR"; return 1; }
    trap '_win_on_sig INT' INT
    trap '_win_on_sig TERM' TERM
    trap '_win_on_sig HUP' HUP
    WIN_RAN=1
    WIN_T0="$(date +%s)"
    e0="$(_elapsed)"; end=$((e0 + WIN_SECS))
    if [ "$end" -gt $((RUN_DEADLINE - WIN_RESERVE)) ]; then
        end=$((RUN_DEADLINE - WIN_RESERVE)); WIN_CUT=1
        [ "$end" -lt "$e0" ] && end="$e0"
        warn "window: the run deadline (${RUN_DEADLINE}s) cuts the window to $((end - e0))s of ${WIN_SECS}s"
    fi
    WIN_PLAN=$((end - e0))
    progress "window: $(_win_hms $((end - e0))) from $(_win_local "$WIN_T0")"
    return 0
}

window_run() {
    local e0 end left iv pn io_cap k n
    _win_plan || return
    # The interval jobs (README.md, section O): about 120 blocks over the
    # window, so (N - 1) x I <= its length and they end with it whatever I is.
    WIN_IO_IV=$(( (end - e0) / 120 ))
    [ "$WIN_IO_IV" -lt 1 ] && WIN_IO_IV=1
    [ "$WIN_IO_IV" -gt 60 ] && WIN_IO_IV=60
    WIN_IO_N=$(( (end - e0) / WIN_IO_IV + 1 ))
    io_cap=$(( end - e0 + WIN_IO_IV + 30 ))
    _pair_start "$WIN_DIR/io" "$WIN_IO_IV" "$WIN_IO_N" "$io_cap"
    if have zpool && ! _hung zpool && [ "$WIN_PLAN" -gt 0 ]; then
        _bg_start "$WIN_DIR/io" hist-r "$io_cap" zpool iostat -T d -r "$WIN_PLAN" 2
        _bg_start "$WIN_DIR/io" hist-w "$io_cap" zpool iostat -T d -w "$WIN_PLAN" 2
    fi
    have arcstat && _bg_start "$WIN_DIR/io" arcstat "$io_cap" arcstat "$WIN_IO_IV" "$WIN_IO_N"
    _win_snap start
    for k in "$KSTAT_DIR"/*/; do
        k="${k%/}"; [ -e "$k/txgs" ] || continue
        pn="${k##*/}"
        mkdir -p "$WIN_DIR/txg/$pn" 2>/dev/null
        : > "$WIN_DIR/txg/$pn/prev"
        echo "- - 0 0 0 0 0 0 0 - - 0 1" > "$WIN_DIR/txg/$pn/state"
        _win_read "$pn" 0
    done
    lastp="$(_elapsed)"
    while [ -z "$WIN_SIG" ]; do
        left=$((end - $(_elapsed)))
        [ "$left" -le 0 ] && break
        iv="$(_win_iv)"; [ "$iv" -gt "$left" ] && iv="$left"
        { [ -z "$WIN_IV_LO" ] || [ "$iv" -lt "$WIN_IV_LO" ]; } && WIN_IV_LO="$iv"
        { [ -z "$WIN_IV_HI" ] || [ "$iv" -gt "$WIN_IV_HI" ]; } && WIN_IV_HI="$iv"
        _win_sleep "$iv"
        [ -n "$WIN_SIG" ] && break
        [ "$(_elapsed)" -ge "$end" ] && break
        for k in "$WIN_DIR"/txg/*/; do k="${k%/}"; [ -d "$k" ] && _win_read "${k##*/}" 0; done
        if [ $(( $(_elapsed) - lastp )) -ge 300 ]; then
            progress "window: $(_win_hms $(( $(_elapsed) - e0 ))) of $(_win_hms $((end - e0))); next read in $(_win_iv)s"
            lastp="$(_elapsed)"
        fi
    done
    for k in "$WIN_DIR"/txg/*/; do k="${k%/}"; [ -d "$k" ] && _win_read "${k##*/}" 1; done
    _win_snap end
    WIN_T1="$(date +%s)"
    # they end by their count with the window; WIN_IO_GRACE seconds more for
    # the last block, whatever the interval. An early end (signal, deadline)
    # stops them at once.
    k="$WIN_IO_GRACE"; { [ -n "$WIN_SIG" ] || [ -n "$WIN_CUT" ]; } && k=0
    for n in zpool iostat hist-r hist-w arcstat; do
        _bg_end "$WIN_DIR/io" "$n" "$k" "the window ended${WIN_SIG:+ early (SIG$WIN_SIG)}"
    done
    [ -n "$WIN_SIG" ] && warn "window: SIG$WIN_SIG after $(_win_hms $((WIN_T1 - WIN_T0))) of $(_win_hms "$WIN_SECS"); writing the report with what was collected (a second one aborts)"
    _win_restore_traps
}

# _win_delta START END -> one line per numeric counter that changed (start,
# end, delta) and one line naming the unchanged ones; a kstat recreated in
# between (its crtime changed) and a counter that went down are said as such
_win_delta() {
    awk '
        FNR == 1 { f++; cr[f] = $6; next }
        FNR == 2 { next }
        f == 1 { if ($2 == 7) nm1 = $3; else { v1[$1] = $3; o[++n] = $1 } ; next }
        f == 2 { if ($2 == 7) nm2 = $3; else v2[$1] = $3 }
        END {
            if (nm1 != nm2) printf "        dataset_name: %s at start, %s at end\n", nm1, nm2
            if (cr[1] != cr[2]) { printf "        kstat recreated during the window (crtime %s at start, %s at end): deltas not computed\n", cr[1], cr[2]; exit }
            for (i = 1; i <= n; i++) {
                k = o[i]
                if (v1[k] == v2[k]) { z = z (z == "" ? "" : ", ") k "=" v1[k]; continue }
                if (!hd++) printf "        %-34s %20s %20s %20s\n", "counter", "start", "end", "delta"
                if (!(k in v2)) { printf "        %-34s %20s %20s %20s\n", k, v1[k], "-", "absent at end"; continue }
                if (v2[k] + 0 < v1[k] + 0) d = "went down (end < start)"; else d = sprintf("%.0f", v2[k] - v1[k])
                printf "        %-34s %20s %20s %20s\n", k, v1[k], v2[k], d
            }
            # the unchanged ones, wrapped at about 150 columns
            m = split(z, U, ", "); l = "unchanged:"
            for (i = 1; i <= m; i++) {
                if (length(l) + length(U[i]) > 150) { printf "        %s\n", l; l = "          " }
                l = l " " U[i] (i < m ? "," : "")
            }
            if (m) printf "        %s\n", l
        }' "$1" "$2" 2>/dev/null
}

# _win_saved PHASE NAME -> a parameter as the window's PHASE snapshot read it
_win_saved() { awk -F'\t' -v k="$2" '$1 == k { print $2 }' "$WIN_DIR/$1/params" 2>/dev/null; }

# -- O. Write-path window (--window) ---------------------------------------
WIN_GOAL="time window (every txg, counters, zpool iostat -vlq, -r/-w)"
# _O_WHY / _O_NOPOOL: what section O's subsections found missing, for its goal line
_O_WHY="" _O_NOPOOL=0
_o_why() { _O_WHY="${_O_WHY:+$_O_WHY; }$1"; }
_rep_o() {
    section "O. Time window (every run; --window sets its length)"
    goal window "$WIN_GOAL"
    fact "length: $(_win_hms "$WIN_SECS")$( [ "$WIN_GIVEN" = 1 ] && echo ' (--window)' || echo " (default; --window=DUR sets it)")"
    if [ "$WIN_RAN" != 1 ]; then
        if [ ! -d "$KSTAT_DIR" ]; then
            fact "window: not run (path not found: $KSTAT_DIR)"
            if [ "${ZPOOL_COUNT:-0}" -gt 0 ] 2>/dev/null; then missed window "zpool list listed $ZPOOLS but $KSTAT_DIR is not there"
            else na window "no kstat tree ($KSTAT_DIR not found) and no pool listed by zpool"; fi
        elif [ "$WIN_SKIP" = nopool ]; then
            fact "window: not run (no <pool>/txgs under $KSTAT_DIR)"
            if [ "${ZPOOL_COUNT:-0}" -gt 0 ] 2>/dev/null; then missed window "zpool list listed $ZPOOLS but $KSTAT_DIR has no <pool>/txgs"
            else na window "no <pool>/txgs under $KSTAT_DIR and no pool listed by zpool (no pool imported)"; fi
        else
            fact "window: not run (${WIN_SKIP:-not reached})"
            missed window "not run: ${WIN_SKIP:-not reached}"
        fi
        return
    fi
    local p
    _O_WHY="" _O_NOPOOL=0
    fact "window: $(_win_local "$WIN_T0") -> $(_win_local "$WIN_T1"), $(_win_hms $((WIN_T1 - WIN_T0)))"
    if [ -n "$WIN_SIG" ]; then
        fact "ended early: SIG$WIN_SIG after $(_win_hms $((WIN_T1 - WIN_T0))) of $(_win_hms "$WIN_SECS"); what follows covers the part collected"
        _O_WHY="ended early by SIG$WIN_SIG after $(_win_hms $((WIN_T1 - WIN_T0))) of $(_win_hms "$WIN_SECS")"
    elif [ -n "$WIN_CUT" ]; then
        fact "ended early: the run deadline (${RUN_DEADLINE}s, ${WIN_RESERVE}s kept for the report) cut it to $(_win_hms "$WIN_PLAN") of $(_win_hms "$WIN_SECS"); it ran $(_win_hms $((WIN_T1 - WIN_T0))) with the last reads"
        _O_WHY="cut by the run deadline (${RUN_DEADLINE}s) to $(_win_hms "$WIN_PLAN") of $(_win_hms "$WIN_SECS")"
    fi
    subsection "module parameters at start and end (read, never written)"
    for p in zfs_txg_history zfs_txg_timeout; do
        fact "$p: start $(_win_saved start "$p"), end $(_win_saved end "$p")"
    done
    _rep_o_txgs
    _rep_o_counters
    _rep_o_io

    subsection "txgs rows kept (column header, then one row per txg, ascending)"
    for p in "$WIN_DIR"/txg/*/; do
        p="${p%/}"; [ -s "$p/rows" ] || continue
        fact "pool ${p##*/}:"
        dump_file "$p/rows" $((WIN_ROW_CAP + 1))
    done
    if [ -n "$_O_WHY" ]; then missed window "$_O_WHY"
    elif [ "$_O_NOPOOL" = 1 ]; then na window "no <pool>/txgs under $KSTAT_DIR and no pool listed by zpool (no pool imported)"
    else got window; fi
}

# _rep_o_txgs -> every txg of the window, per pool (adds to _O_WHY / _O_NOPOOL)
_rep_o_txgs() {
    local p pn n np g0 g1 gn ge
    subsection "txgs per pool (reads merged by txg number)"
    if [ -n "$WIN_IV_LO" ]; then
        fact "read interval used: ${WIN_IV_LO}..${WIN_IV_HI}s (half the shortest ring span of all pools, clamped to ${WIN_IV_MIN}..${WIN_IV_MAX}s, cut to the time left)"
    else
        fact "read interval used: none (read at the start and at the end only)"
    fi
    np=0
    for p in "$WIN_DIR"/txg/*/; do
        p="${p%/}"; [ -f "$p/state" ] || continue
        pn="${p##*/}"; np=$((np + 1))
        _win_state "$p/state"
        fact "pool $pn: $w_reads reads ($w_fails failed); read interval its ring's span implied: $(awk -F'\t' -v lo="$WIN_IV_MIN" -v hi="$WIN_IV_MAX" '
            BEGIN { mn = -1 }
            $5 ~ /^[0-9.]+$/ { i = int($5 / 2); if (i < lo) i = lo; if (i > hi) i = hi; if (mn < 0 || i < mn) mn = i; if (i > mx) mx = i }
            END { if (mn < 0) print "-"; else printf "%d..%ds", mn, mx }' "$p/reads.tsv" 2>/dev/null)"
        if [ "$w_first" = - ]; then
            fact "  txgs: none read (the ring was empty or not readable at every read)"
            _o_why "pool $pn: no txgs row read (zfs_txg_history=$(_win_saved end zfs_txg_history) at the end)"
            continue
        fi
        n=$((w_last - w_first + 1))
        fact "  txgs in the window: $w_first .. $w_last ($n number$( [ "$n" = 1 ] || echo s)); rows kept: $w_kept"
        fact "  rows seen completed (state C): $(awk '$1 ~ /^[0-9]+$/ && $3 == "C"' "$p/rows" 2>/dev/null | wc -l | tr -d ' '); not completed at the last read: $w_open; left the ring before seen completed (last-seen state kept): $w_part"
        fact "  txgs never seen (left the ring between two reads): $w_gap"
        if [ "$w_gap" -gt 0 ]; then
            head -n 50 "$p/gaps.tsv" 2>/dev/null | while IFS="$_tab" read -r g0 g1 gn ge; do
                blk "txg $g0 .. $g1 ($gn), missing from the read at $(_win_local "$ge")"
            done
            [ "$(wc -l < "$p/gaps.tsv")" -gt 50 ] && blk "(first 50 ranges; all of them in the bundle's window/gaps-$pn.tsv)"
            _o_why "pool $pn: $w_gap txgs left the ring unseen (zfs_txg_history=$(_win_saved end zfs_txg_history) at the end; a larger ring covers a longer span)"
        fi
        if [ "$w_over" -gt 0 ]; then
            fact "  row cap: $WIN_ROW_CAP rows kept, $w_over later ones not kept"
            _o_why "pool $pn: $w_over rows past the ${WIN_ROW_CAP}-row cap (a shorter --window keeps them all)"
        fi
        if [ -f "$p/gone" ]; then
            IFS="$_tab" read -r g0 g1 < "$p/gone"
            fact "  $KSTAT_DIR/$pn/txgs: not found at the read of $(_win_local "$g0"); the last read with rows was at $( [ -n "$g1" ] && _win_local "$g1" || echo n/a ), newest txg $w_last; txgs after it are not in this report"
            _o_why "pool $pn: $KSTAT_DIR/$pn/txgs not found from $(_win_local "$g0") on"
        fi
    done
    if [ "$np" = 0 ]; then
        fact "no <pool>/txgs under $KSTAT_DIR at the start"
        if [ "${ZPOOL_COUNT:-0}" -gt 0 ] 2>/dev/null; then _o_why "zpool list listed $ZPOOLS but $KSTAT_DIR has no <pool>/txgs"
        else _O_NOPOOL=1; fi
    fi
}

# _rep_o_counters -> dmu_tx, arcstats and objset-* at start and end (adds to _O_WHY)
_rep_o_counters() {
    local p pn f fn st=""
    subsection "counters at start and end (dmu_tx, arcstats, objset-* per dataset)"
    if [ -f "$WIN_DIR/start/dmu_tx" ] && [ -f "$WIN_DIR/end/dmu_tx" ]; then
        fact "dmu_tx ($KSTAT_DIR/dmu_tx):"
        _win_delta "$WIN_DIR/start/dmu_tx" "$WIN_DIR/end/dmu_tx"
    else
        fact "dmu_tx: n/a (not read at $( [ -f "$WIN_DIR/start/dmu_tx" ] && echo end || echo start ): $KSTAT_DIR/dmu_tx)"
        _o_why "dmu_tx not read"
    fi
    if [ -f "$WIN_DIR/start/arcstats" ] && [ -f "$WIN_DIR/end/arcstats" ]; then
        fact "arcstats ($KSTAT_DIR/arcstats; the ARC counters behind arcstat, sizes as gauges):"
        _win_delta "$WIN_DIR/start/arcstats" "$WIN_DIR/end/arcstats"
    else
        fact "arcstats: n/a (not read at $( [ -f "$WIN_DIR/start/arcstats" ] && echo end || echo start ): $KSTAT_DIR/arcstats)"
        _o_why "arcstats not read"
    fi
    for p in "$WIN_DIR"/start/pools/*/ "$WIN_DIR"/end/pools/*/; do
        p="${p%/}"; [ -d "$p" ] || continue
        pn="${p##*/}"
        case " $st " in *" $pn "*) continue ;; esac
        st="$st $pn"
        for f in "$WIN_DIR/start/pools/$pn"/objset-* "$WIN_DIR/end/pools/$pn"/objset-*; do
            [ -f "$f" ] || continue
            fn="${f##*/}"
            case " $st " in *" $pn/$fn "*) continue ;; esac
            st="$st $pn/$fn"
            if [ ! -f "$WIN_DIR/start/pools/$pn/$fn" ]; then
                fact "$pn/$fn ($(awk '$1 == "dataset_name" { print $3 }' "$f" 2>/dev/null)): absent at start, present at end"
            elif [ ! -f "$WIN_DIR/end/pools/$pn/$fn" ]; then
                fact "$pn/$fn ($(awk '$1 == "dataset_name" { print $3 }' "$f" 2>/dev/null)): present at start, absent at end"
            else
                fact "$pn/$fn ($(awk '$1 == "dataset_name" { print $3 }' "$f" 2>/dev/null)):"
                _win_delta "$WIN_DIR/start/pools/$pn/$fn" "$WIN_DIR/end/pools/$pn/$fn"
            fi
        done
    done
}

# _rep_o_io -> zpool iostat / iostat -x / histograms / arcstat of the window (adds to _O_WHY)
_rep_o_io() {
    local n
    subsection "zpool iostat -vlq and iostat -x over the window (started together, same interval)"
    _pair_emit "$WIN_DIR/io" "$WIN_IO_IV" "$WIN_IO_N" "$WIN_IOSTAT_LINES"
    [ -n "$PAIR_WHY" ] && _o_why "$PAIR_WHY"

    subsection "zpool iostat -r / -w for the window (first block: since pool import; second: the window)"
    for n in hist-r hist-w; do
        if [ -f "$WIN_DIR/io/$n.t0" ]; then
            _bg_emit "$WIN_DIR/io" "$n" "zpool iostat -T d -${n#hist-} $WIN_PLAN 2 ($( [ "$n" = hist-r ] && echo 'request-size histogram' || echo 'latency histogram' )):" 1000
            [ -n "$BG_WHY" ] && _o_why "$BG_WHY"
        fi
    done
    [ -f "$WIN_DIR/io/hist-r.t0" ] || fact "n/a (not run with zpool iostat above)"

    subsection "arcstat over the window"
    if [ -f "$WIN_DIR/io/arcstat.t0" ]; then
        _bg_emit "$WIN_DIR/io" arcstat "arcstat $WIN_IO_IV $WIN_IO_N:" "$WIN_IOSTAT_LINES"
        [ -n "$BG_WHY" ] && _o_why "$BG_WHY"
    else
        fact "n/a (command not found: arcstat; the arcstats counters it reads are in the start/end table above)"
    fi

}

bundle_window() {
    local d="$1" p pn n
    [ -n "$WIN_DIR" ] && [ -d "$WIN_DIR" ] || return 0
    mkdir -p "$d" 2>/dev/null
    for p in "$WIN_DIR"/txg/*/; do
        p="${p%/}"; pn="${p##*/}"
        [ -f "$p/rows" ] && cp "$p/rows" "$d/txgs-$pn.txt" 2>/dev/null
        [ -f "$p/reads.tsv" ] && { printf 'epoch\trows\toldest\tnewest\tspan_s\tgaps_so_far\n'; cat "$p/reads.tsv"; } > "$d/reads-$pn.tsv" 2>/dev/null
        [ -f "$p/gaps.tsv" ] && { printf 'from\tto\tcount\tfound_at_epoch\n'; cat "$p/gaps.tsv"; } > "$d/gaps-$pn.tsv" 2>/dev/null
    done
    for p in zpool iostat hist-r hist-w arcstat; do
        case "$p" in zpool) n=zpool-iostat-vlq ;; iostat) n=iostat-x ;; hist-r) n=zpool-iostat-r ;; hist-w) n=zpool-iostat-w ;; *) n=arcstat ;; esac
        [ -f "$WIN_DIR/io/$p.txt" ] && cp "$WIN_DIR/io/$p.txt" "$d/$n.txt" 2>/dev/null
        [ -f "$WIN_DIR/io/$p.t0" ] && printf '%s\t%s\n' "$p" "$(cat "$WIN_DIR/io/$p.t0")" >> "$d/io-start-ms.tsv" 2>/dev/null
    done
    for p in start end; do [ -d "$WIN_DIR/$p" ] && cp -R "$WIN_DIR/$p" "$d/$p" 2>/dev/null; done
    progress "window: merged txgs, reads log, counters and the interval jobs' output written"
}

# =============================================================================
# Bundle (Tier 1 raw artifacts; Tier 2 only when its flag was given)
# =============================================================================
bundle_zfs() {
    local d="$1" p; mkdir -p "$d" 2>/dev/null
    if have zpool; then
        # the report's own calls, when they answered; asked again only when not.
        # The zpool-events-* files are already here: section L wrote them.
        _reuse zpool-list-v "$d/zpool-list-v.txt" 30 zpool list -v
        run_bounded 30 zpool status -v        > "$d/zpool-status-v.txt"
        run_bounded 30 zpool status -t        > "$d/zpool-status-t.txt"
        run_bounded 60 zpool status -D        > "$d/zpool-status-D.txt"
        for p in v lv qv r w; do _reuse "zpool-iostat-$p" "$d/zpool-iostat-$p.txt" 30 zpool iostat "-$p"; done
        for p in $ZPOOLS; do
            run_bounded 30 zpool get all "$p" > "$d/zpool-get-all-$p.txt"
            run_bounded 60 zpool history "$p" > "$d/zpool-history-$p.txt"
            run_bounded 30 zpool status -PL "$p" > "$d/zpool-status-P-$p.txt"
        done
    fi
    if have zfs; then
        # discovery's zfs get all (-Hp) and snapshot list, as they were read
        if [ "$ZGET_RC" = 0 ]; then cp "$_ZGETALL" "$d/zfs-get-all-parsable.tsv" 2>/dev/null
        else run_bounded 90 zfs get -Hp -o name,property,value,source -t filesystem,volume all > "$d/zfs-get-all-parsable.tsv"; fi
        run_bounded 60  zfs list -o space          > "$d/zfs-list-space.txt"
        run_bounded 60  zfs list -t filesystem,volume > "$d/zfs-list.txt"
        if [ "$ZSNAP_RC" = 0 ]; then cp "$_ZSNAP" "$d/zfs-list-snapshots.tsv" 2>/dev/null
        else run_bounded 120 zfs list -H -p -t snapshot -o name,used,referenced,creation,userrefs,written,clones > "$d/zfs-list-snapshots.tsv"; fi
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
    _bounded find "$KSTAT_DIR" -maxdepth 2 -type f 2>/dev/null | while IFS= read -r f; do
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
    have modinfo && _bounded modinfo zfs > "$d/modinfo-zfs.txt" 2>/dev/null
    cat /etc/modprobe.d/*zfs* /etc/modprobe.d/*spl* > "$d/modprobe.d-zfs.txt" 2>/dev/null
    cat /proc/cmdline > "$d/kernel-cmdline.txt" 2>/dev/null
    progress "params: module parameters written"
}

bundle_host() {
    local d="$1"; mkdir -p "$d" 2>/dev/null
    cat /proc/meminfo > "$d/meminfo.txt" 2>/dev/null
    cat /proc/loadavg > "$d/loadavg.txt" 2>/dev/null
    have lsblk && _bounded lsblk -O > "$d/lsblk-O.txt" 2>/dev/null
    have lsblk && _bounded lsblk -o NAME,KNAME,TYPE,SIZE,ROTA,PHY-SEC,LOG-SEC,SCHED,MOUNTPOINT,MODEL > "$d/lsblk.txt" 2>/dev/null
    have findmnt && _bounded findmnt > "$d/findmnt.txt" 2>/dev/null
    have df && _bounded df -T > "$d/df-T.txt" 2>/dev/null
    cat /proc/self/mountinfo > "$d/mountinfo.txt" 2>/dev/null
    have iostat && _reuse iostat-x "$d/iostat-x.txt" "$CMD_TIMEOUT" iostat -x
    have multipath && _bounded multipath -ll > "$d/multipath.txt" 2>&1
    _bounded dmesg 2>&1 | tail -n 500 > "$d/dmesg-tail.txt" 2>/dev/null
    ( for b in /sys/block/*; do
          [ -d "$b/queue" ] || continue
          printf '== %s ==\n' "$(basename "$b")"
          for q in "$b"/queue/*; do
              [ -f "$q" ] && [ -r "$q" ] && printf '%s = %s\n' "$(basename "$q")" "$(head -n1 "$q" 2>/dev/null)"
          done
      done ) > "$d/block-queue.txt" 2>/dev/null
    if have journalctl; then
        # Capped by time and by size: zed on a pool that logs a deadman per
        # second writes millions of lines. The newest JOURNAL_LINES are kept.
        local u JOURNAL_LINES=20000
        for u in $ZFS_JOURNAL_UNITS; do
            unit_loaded "$u.service" || continue
            _bounded journalctl -u "$u.service" --since "${OPT_HOURS} hours ago" -n "$JOURNAL_LINES" --no-pager > "$d/$u.journal.txt" 2>&1
            [ $? -eq 124 ] && printf '\n(journalctl stopped at the %ss cap)\n' "$CMD_TIMEOUT" >> "$d/$u.journal.txt"
        done
    fi
    have df && _bounded df -h > "$d/df-h.txt" 2>/dev/null
    have df && _bounded df -i > "$d/df-i.txt" 2>/dev/null
    progress "host: block device and kernel snapshot written"
}

# _zdb_bundle DIR -> section N in a bundle run: zdb -C / -Lbbbs / -mm per pool,
# each written whole (stderr folded in) to DIR, and one fact line per file
_zdb_bundle() {
    local d="$1" p c t rc f
    mkdir -p "$d" 2>/dev/null
    for p in $ZPOOLS; do
        subsection "$p (zdb, written whole to the bundle's zdb/)"
        for c in "C 300 reads the pool configuration" "Lbbbs 3600 traverses pool metadata; takes minutes on a large pool and reads the data disks" "mm 3600 loads metaslab space maps"; do
            # shellcheck disable=SC2086  # "flag cap impact" into $1 $2 $3...
            set -- $c; t="$2"; f="$d/zdb-$1-$p.txt"
            warn "[Tier2] zdb -$1 $p — ${c#* * }"
            progress "zdb -$1 $p ..."
            CMD_TIMEOUT="$t" _bounded zdb "-$1" "$p" > "$f" 2>&1; rc=$?
            case "$rc" in
                0)   rc="exit 0" ;;
                124) if _past_deadline; then rc="stopped: run deadline reached (${RUN_DEADLINE}s)"; else rc="stopped at the ${t}s cap"; fi ;;
                *)   rc="exit $rc" ;;
            esac
            fact "zdb -$1 $p: zdb/${f##*/}, $( { wc -c < "$f"; } 2>/dev/null | tr -d ' ') bytes, $rc"
        done
    done
    [ -z "$ZPOOLS" ] && fact "zdb: n/a ($(_nopool_why))"
    progress "zdb: written"
}

do_bundle() {
    local work tarball
    # The work dir lives in the run's private directory, so an interrupted run
    # leaves nothing behind in /tmp or in --out.
    work="$(_tmp bundle)"
    case "$work" in /dev/null) warn "the bundle was not written: no private temp directory could be created under ${TMPDIR:-/tmp}"; return 1 ;; esac
    mkdir -p "$work" 2>/dev/null || { warn "the bundle was not written: cannot create $work"; return 1; }
    # Section L's one read of the zevent ring and section N's zdb write their
    # files straight into the bundle.
    BUNDLE_WORK="$work"; ZEV_DIR="$work/zfs"; ZEV_V=1
    mkdir -p "$ZEV_DIR" 2>/dev/null
    run_report > "$work/report.txt" 2>/dev/null
    progress "report: written to bundle"
    bundle_zfs    "$work/zfs"
    bundle_kstat  "$work/kstat"
    bundle_params "$work/params"
    bundle_host   "$work/host"
    bundle_window "$work/window"

    tarball="$OPT_OUT/$BASENAME.tar.gz"
    have tar || { warn "the bundle was not written: tar: command not found"; return 1; }
    # -C instead of `cd "$work"`: $tarball stays relative to the caller's cwd.
    # Not capped: a local write of what the run already collected.
    if tar -C "$work" -czf "$tarball" . 2>/dev/null && [ -s "$tarball" ]; then
        _give_back "$tarball"
        progress "bundle: $tarball"
    else
        rm -f "$tarball" 2>/dev/null
        warn "the bundle was not written: tar could not write $tarball"
        return 1
    fi
}

# ---- collection-server: give back — DO NOT EDIT -----------------------------
# members: collserver collzfs
# _give_back FILE -> under sudo, hand FILE to the account that ran sudo, so the
# operator can move and delete the file they came for
_give_back() {
    if [ "$(id -u 2>/dev/null)" = 0 ] && [ -n "${SUDO_UID:-}" ]; then
        chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$1" 2>/dev/null
    fi
}
# ---- end collection-server: give back

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

# Numeric options are checked before anything runs (exit 2), not half way.
# The environment caps, checked like RUN_DEADLINE and CMD_TIMEOUT: a value
# that is not a whole number is ignored, with a warn, and the default used.
FILESIZES_SECS="$(_cap_or FILESIZES_SECS "$FILESIZES_SECS" 300)"
OPT_HOURS="$(_cap_or JOURNAL_HOURS "$OPT_HOURS" 24)"
[ "$OPT_EVENT_DAYS" = 0 ] || OPT_EVENT_DAYS="$(_cap_or EVENT_DAYS "$OPT_EVENT_DAYS" 30)"
if [ "$WIN_GIVEN" = 1 ]; then
    # the start time form is gone: collecting DUR from now would cover
    # another span than the one asked for, so it stops
    case "$WIN_SPEC" in *@*) _removed "--window=DUR@START was removed in 0.11.0: start the run at START (at, cron) with --window=DUR" ;; esac
    WIN_SECS="$(_win_secs "$WIN_SPEC")" || { warn "--window takes DUR from 10s to 24h: N (seconds), Ns, Nm or Nh; got '$WIN_SPEC'"; exit 2; }
else
    WIN_SECS="$WIN_DEFAULT"
fi

# The run deadline is raised to fit what was asked for, unless the caller set
# one: the file-size walk (FILESIZES_SECS), --window (below), the bundle's
# zpool events -v read (600s) and, after discovery, --zdb.
if [ -z "$_RUN_DEADLINE_ENV" ]; then
    [ "$OPT_FILESIZES" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + FILESIZES_SECS))
    [ "$OPT_BUNDLE" = 1 ] && RUN_DEADLINE=$((RUN_DEADLINE + 900))
    # the window and its last reads
    RUN_DEADLINE=$((RUN_DEADLINE + WIN_SECS + 60))
fi

_run_init
# A caller's RUN_DEADLINE is not raised: say at once when it cuts a requested
# window, and refuse one that would leave it under 10s. The default window is
# cut, or not run, and says so in section O.
if [ "$WIN_GIVEN" = 1 ] && [ -n "$_RUN_DEADLINE_ENV" ]; then
    _wl=$((RUN_DEADLINE - WIN_RESERVE))
    if [ "$_wl" -lt 10 ]; then
        warn "RUN_DEADLINE=$RUN_DEADLINE leaves the window ${_wl}s (${WIN_RESERVE}s are kept for the report); a window needs at least 10s"
        exit 2
    elif [ "$_wl" -lt "$WIN_SECS" ]; then
        warn "RUN_DEADLINE=$RUN_DEADLINE cuts the window to about ${_wl}s of ${WIN_SECS}s"
    fi
fi

# The output directory is checked before collecting, so an unwritable one
# fails at once rather than after a full run.
if [ "$OPT_STDOUT" != 1 ] || [ "$OPT_BUNDLE" = 1 ]; then
    _out_dir_check || exit 1
fi

progress "discovering pools, datasets and snapshots ..."
discover_zfs
# --zdb runs once per pool, in section N: 120s + 1800s + 1800s in a report,
# or 300s + 3600s + 3600s written whole into a bundle. 280s on top, and at
# least one pool's share, so pool 2 onward is not cut off by the deadline.
if [ -z "$_RUN_DEADLINE_ENV" ] && [ "$OPT_ZDB" = 1 ]; then
    _zn="${ZPOOL_COUNT:-0}"; [ "$_zn" -ge 1 ] 2>/dev/null || _zn=1
    if [ "$OPT_BUNDLE" = 1 ]; then _zc=7500; else _zc=3720; fi
    RUN_DEADLINE=$((RUN_DEADLINE + 280 + _zn * _zc))
fi
# every unit sd_show will be asked about, in one call (the zfs units are asked
# as <name>.service, zfs.target included, as section A always has)
_pf=""; for _u in $ZFS_UNITS; do _pf="$_pf $_u.service"; done
# shellcheck disable=SC2086
_sd_prefetch $_pf
_zp="$(printf '%s' "$ZPOOLS" | tr -s ' ' ',' | sed 's/^,//; s/,$//')"
TARGET="collection-server-zfs/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)${_zp:+@pools=$_zp}"
progress "pools: ${ZPOOLS:-none}; datasets: ${DS_COUNT:-0}; snapshots: ${SNAP_COUNT:-0}"

# The window runs before the report, so the report's snapshot is taken at
# the window's end.
[ "$ZFS_ON_HOST" = 1 ] && window_run

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-collzfs-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (report + raw ZFS artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle || exit 1
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (report)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (report) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    _give_back "$OUTFILE"
    progress "report written: $OUTFILE"
fi
exit 0
