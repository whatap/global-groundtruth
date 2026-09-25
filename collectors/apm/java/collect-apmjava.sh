#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM Java agent collector
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap Java-agent developer repeatedly asks
# a field engineer for, from the host or container where the target JVM runs.
# Derived from the agent source (io.whatap.java/whatap.agent.tracer, v2.2.76),
# the whatap-operator Java injector (internal/webhook/v2alpha1/injector_java.go),
# and WhaTap Global support cases 2026-06-16 (JBoss 5.1 eorder_uat), 2026-06-24
# (KBANESCFServer socket gateway), 2026-06-30 (keypro GlassFish logging loop).
#
# Recurring field questions this report answers with facts:
#   * Is a WhaTap -javaagent actually attached, and how many agents are on the
#     JVM? The option may come from the command line OR from JAVA_TOOL_OPTIONS /
#     _JAVA_OPTIONS / JDK_JAVA_OPTIONS (the operator injects it that way, so it
#     never appears in /proc/<pid>/cmdline) — all four sources are read.
#   * Which agent jar, which version? Version is read from whatap/v.properties
#     INSIDE the jar (VERSION/BUILD), with the jar's size/mtime/sha256 and the
#     agent log banner as independent cross-checks.
#   * Where does the agent look for its config? The resolution the agent
#     performs is: env WHATAP_CONFIG_FILE, else -Dwhatap.config.file, else
#     -Dwhatap.home (DEFAULT ".", i.e. the process working directory) plus
#     -Dwhatap.config (default "whatap.conf"). Resolved per process, and the
#     file dumped verbatim.
#   * Which settings are in force? whatap.conf is dumped verbatim, and every
#     whatap-related environment variable and -D system property is listed per
#     process: the agent overlays env and system properties onto the config
#     (whatap/lang/conf/ConfigValueUtil.replaceSysProp), and env names may carry
#     dots (license, whatap.server.host, whatap.server.port).
#   * What kind of Java process is this? Server markers (catalina.base,
#     jboss.home.dir, jeus.home, weblogic, websphere, Spring Boot loader) are
#     read the same way the agent's own ProcessTypeDetector reads them.
#   * The most frequent Java case — "the agent is installed, the process is
#     healthy, but the hitmap stays empty because the application's framework
#     is not instrumented" — needs four facts side by side, and the report
#     carries all four: what the application carries (section F), what THIS
#     agent build can instrument (section G: the weaving modules bundled in
#     the installed jar plus its built-in ASM classes — read from the jar, so
#     the list matches the deployed version), which modules the configuration
#     selects (the weaving / hook_service_* / instrumentation_* keys), and
#     which modules the running process actually loaded (the agent log's
#     "Weaving" lines, including the compiled-class-version warnings that stop
#     a module from applying).
#   * Which libraries does the deployed application actually carry? Enumerated
#     from the target's own -cp/-classpath, -jar (BOOT-INF/lib), CLASSPATH and
#     the server deploy directories derived from its -D properties. The
#     -javaagent jar itself is EXCLUDED from these lists and the exclusion is
#     stated: the agent jar bundles weaving-module markers, so a scan that
#     includes it reports the agent's own catalog instead of the application's
#     libraries (case 2026-06-16).
#   * Where does the JVM's stdout go? /proc/<pid>/fd/1 is resolved — the agent
#     boot banner and a SIGQUIT thread dump land there, not in the agent log.
#   * Which logging framework is in play, and where are its config files and
#     output files? (case 2026-06-30: a console/JUL loop produced 19.8M events
#     while the on-disk server log stayed small.)
#   * Is the process a JVM at all when nothing about it says java? A native
#     launcher that creates the VM in-process through JNI_CreateJavaVM (Axway
#     API Gateway's `vshell` is one) has its own comm and exe and passes the
#     JVM options in memory, so no /proc file names them. Such a process is
#     identified by the VM shared library mapped into it (libjvm.so /
#     libj9vm*.so), and --jcmd then reads its options back from the VM itself
#     (case 2026-09-11 BAF: section D reported no JVM while section J showed
#     two `vshell` processes connected to the collection server).
#   * Tier 2, opt-in: thread dumps (--threads) and jcmd VM data (--jcmd) of the
#     target JVM — the artifact that decided both transaction-entry cases.
#   * Which of the application's own classes implement, extend or call a
#     given type? The console answers it with an Interfaces column; from the
#     artifact it is answered by the constant pool, which carries the type as
#     a UTF8 entry in every class that names it. --class-refs does that scan
#     (case 2026-09-17 FIF: which of 72 batchprocess classes are Quartz jobs).
#   * A thread dump the field already holds (WhaTap console dump, jstack file,
#     kill -3 output) enters the same counts through --dump-file, without
#     touching any JVM (case 2026-09-17 FIF: the dump arrived over Slack and
#     was counted by hand). The counts also cover what the FRAMES of an idle
#     JVM do not show: thread names (a cache or scheduler thread carries the
#     application's package in its name), thread states, and the frame and
#     thread footprint of other APM agents attached to the same JVM.
#
# THE CONTRACT (../../../CONTRACT.md):
#   1. Facts only. No conclusion is stated on any emitted line.
#   2. Discover, never assume. Resolve symlinks, process args, env, config.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned. Seed v0 by the Global team; ownership transfers to
#      the APM/Java agent developers.
#
# DESIGN GUIDELINES (../../../docs/collector-engineering.md): MECE sections,
# Tier-0 load-safe defaults (bounded reads, directory listings only, no
# recursive walks, no whole-log grep), bash 3.2+ and POSIX-sh compatible,
# reasoned absence for every missing value. Tier 0 NEVER attaches to, signals,
# or pauses the target JVM: `java -version` is only ever run on a discovered
# java binary (a separate short-lived JVM), never against a running process.
# jstack / jcmd / SIGQUIT are Tier 2 and print their impact before running.
#
# NOTE: no `set -e` — a collector must reach its footer even when every probe
# fails. Failures are handled locally by the helpers.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmjava"
VERSION="0.11.0"
DOMAIN="apm/java"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr
OPT_THREADS=0     # Tier 2: thread dumps of the target JVMs (0 = off)
OPT_JCMD=0        # Tier 2: jcmd VM.command_line / VM.system_properties / VM.flags
OPT_LIBS=""       # --library PATTERN (repeatable): library detail pack
OPT_LIBALL=0      # --library-all: detail every enumerated jar (capped)
OPT_CLASSES=""    # --class FQCN (repeatable): member signatures via javap
OPT_APPCLASSES=0  # --appclasses: application class index (section N)
OPT_DUMPS=""      # --dump-file: thread dump files taken elsewhere (section L)
OPT_REFS=""       # --class-refs: types to look for in the class constant pools

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Collects Java APM agent facts from the host or container where the target JVM
runs (run it inside the container for containerized apps, e.g. kubectl exec /
docker exec, as the same OS user as the JVM where possible).

Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")             print this help (no collection)
  $(basename "$0") --file      write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout    print the facts report to stdout
  $(basename "$0") --quiet ..  silence progress on stderr (add to --file / --stdout)

Library detail pack (off by default; read-only, no contact with the JVM) —
for the case where a new weaving module has to be written for a library:
  --library PAT  detail every enumerated jar whose name or path contains PAT
                 (case-insensitive, repeatable): Maven coordinates, manifest
                 versions, class-file version, package map. With --appclasses
                 the classes of those jars also enter the section N index, for
                 an application that ships its own code as jars
  --library-all  detail every enumerated jar (cap 40)
  --class FQCN   member signatures of that class via javap -p -s (the JVM
                 descriptor of every member included), from each detailed jar
                 that contains it (repeatable)

Application class index (off by default; read-only, no contact with the JVM) —
for the case where the transaction entry point of an application no weaving
module covers has to be located without access to the customer's source:
  --appclasses   enumerate the application's OWN classes from every class root
                 section F finds — WEB-INF/classes, BOOT-INF/classes, directory
                 classpath entries, the JVM's own working directory, and the
                 webapp directories each server product configures: package
                 histogram, a name-pattern index, and the class list

  --class-refs T  with --appclasses: list the indexed classes whose bytecode
                 names type T (e.g. org.quartz.Job, javax.servlet.Filter;
                 repeatable). The constant pool carries the type whether the
                 class implements, extends, calls or merely references it, so
                 the list is "names it", not "implements it"

Thread dumps taken elsewhere (off by default; read-only, no contact with the JVM):
  --dump-file PATH  a thread dump file produced outside this collector (WhaTap
                 console thread dump, jstack output, kill -3 output; repeatable).
                 It enters the same per-frame and per-thread counts as a
                 --threads dump, so a dump the field already holds is counted
                 without pausing any JVM

Tier 2 (off by default; each announces its impact on stderr before running):
  --threads[=N]  N thread dumps per WhaTap-attached JVM (default N=1) via
                 jstack -l; pauses the target JVM at a safepoint for the dump
  --jcmd         jcmd VM.command_line / VM.system_properties / VM.flags per
                 WhaTap-attached JVM; uses the JVM attach mechanism. Also
                 recovers the options of a JVM a native launcher created
                 through JNI, whose options are in no /proc file, so sections
                 E/F/G read them
EOF
}

ARGC=$#
while [ $# -gt 0 ]; do
    case "$1" in
        --file)      OPT_FILE=1 ;;
        --stdout)    OPT_STDOUT=1 ;;
        --quiet)     OPT_QUIET=1 ;;
        --threads)   OPT_THREADS=1 ;;
        --threads=*) OPT_THREADS="${1#*=}" ;;
        --jcmd)      OPT_JCMD=1 ;;
        --library)      shift; OPT_LIBS="$OPT_LIBS $1" ;;
        --library=*)    OPT_LIBS="$OPT_LIBS ${1#*=}" ;;
        --library-all)  OPT_LIBALL=1 ;;
        --class)        shift; OPT_CLASSES="$OPT_CLASSES $1" ;;
        --class=*)      OPT_CLASSES="$OPT_CLASSES ${1#*=}" ;;
        --appclasses)   OPT_APPCLASSES=1 ;;
        --class-refs)   shift; OPT_REFS="$OPT_REFS $1" ;;
        --class-refs=*) OPT_REFS="$OPT_REFS ${1#*=}" ;;
        --dump-file)    shift; OPT_DUMPS="$OPT_DUMPS
$1" ;;
        --dump-file=*)  OPT_DUMPS="$OPT_DUMPS
${1#*=}" ;;
        -h|--help)   usage; exit 0 ;;
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

section() {
    _section_n=$((_section_n + 1))
    printf '\n[%d] %s\n' "$_section_n" "$1"
    progress "[$_section_n] $1"
}

fact() {
    printf '    %s\n' "$1"
}

emit_footer() {
    printf '\n==== END OF COLLECTION (no diagnosis by design) ====\n'
}

# ---- privilege — DO NOT EDIT ------------------------------------------------
# What a collection can read is decided by the privilege it was given. That is a
# fact about this run, not a claim about the environment, so it stays inside
# CONTRACT rule 1 and belongs in the environment section ([1]) with the rest of the run's own facts.
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

# _note_privilege -> describe this process. Call it once, before the environment section reads
# PRIV_WHY. It yields to a value already set, so a self-elevating collector can
# say something more exact.
_note_privilege() {
    [ "$PRIV_WHY" = unknown ] || return 0
    # No uid is not uid 0. A run that cannot tell says so, and claims no root.
    _priv_uid="$(id -u 2>/dev/null)"
    [ -n "$_priv_uid" ] || _priv_uid="$(awk '/^Uid:/{print $2; exit}' /proc/self/status 2>/dev/null)"
    if [ -z "$_priv_uid" ]; then
        PRIV_WHY="n/a (id -u failed and /proc/self/status is not readable)"
        PRIV_GAP=""
    elif [ "$_priv_uid" = 0 ]; then
        PRIV_WHY="root${SUDO_UID:+ (elevated by sudo from uid $SUDO_UID)}"
        PRIV_GAP=""
    else
        PRIV_WHY="not root (uid $_priv_uid)"
        PRIV_GAP="run again with sudo"
    fi
}
# ---- end privilege

# ---- boot time — DO NOT EDIT ------------------------------------------------
# Most of what a collector reports is cumulative since boot: /proc/diskstats,
# ZFS kstat trees, zpool iostat histograms, MySQL GLOBAL STATUS. Without the boot
# time those are sums with no denominator and cannot be read as a rate, so the
# reader either asks the site for it afterwards or reconstructs it. Both are work
# the collector could have done, and it belongs in the environment section ([1]) with the rest of the
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
# _note_boot -> emit the two facts. Call it from the environment section, after the privilege
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
# ---- end boot time

# ---- run helpers — DO NOT EDIT ----------------------------------------------
# Four things every collector needs and none may get wrong on its own.
#
# warn. What the operator must see whatever --quiet says: a Tier 2 impact before
# it runs, a hard error, a skipped step. It goes to fd 3, the terminal saved in
# main, because --file mode discards the report body's stderr. Every collector
# once wrote warn to plain stderr, and in --file mode the "[Tier2] ... pauses
# the target JVM" line never reached the terminal while jstack still ran
# (apmjava 0.10.1, found 2026-09-25).
#
# _bounded CMD... Every external command runs under a cap. timeout(1) when the
# host has it and CMD is a file; otherwise a shell watchdog, which also covers
# shell functions and hosts without coreutils. Returns 124 on a cap, whatever
# the local timeout(1) returns for a kill (busybox gives 143).
#
# RUN_DEADLINE. The whole run is bounded too. Past it, _bounded runs nothing and
# returns 124, so a host where every command hangs still yields a report that
# reaches its footer, and emit_status says the deadline was reached.
#
# _tmp NAME. One private directory per run, removed on exit and on INT, TERM
# and HUP. A Ctrl-C used to leave config copies and thread dumps in /tmp, and a
# $$-named path in a shared /tmp is one a root run follows through a planted
# symlink.
#
# _report_to_file FILE. --file mode's write, which says so and fails when the
# file cannot be written instead of printing "report written".
#
# POSIX sh only in the synced blocks, because the apm collectors are piped into
# `sh -s` inside containers, where sh is often dash or busybox: no SECONDS, no
# `type -t`, no ${v//x/y}. The first draft of this block used all three.
RUN_DEADLINE="${RUN_DEADLINE:-300}"
_tmp_dir=""
_run_t0=""
_nl='
'
_tab="$(printf '\t')"

# Falls back to stderr when fd 3 is not open yet (an error before main).
warn() { { printf '!! %s\n' "$*" >&3; } 2>/dev/null || printf '!! %s\n' "$*" >&2; }

# _elapsed -> seconds since _run_init; 0 when no clock is available, which
# disables the deadline rather than tripping it at once
_elapsed() {
    if [ -n "${BASH_VERSION:-}" ]; then printf '%s' "${SECONDS:-0}"
    elif [ -n "$_run_t0" ]; then printf '%s' "$(( $(date +%s 2>/dev/null || echo "$_run_t0") - _run_t0 ))"
    else printf '0'; fi
}
_past_deadline() { [ "$(_elapsed)" -ge "$RUN_DEADLINE" ]; }

# _cmd_kind CMD -> "file", "shell" (function or builtin) or "" (not found)
_cmd_kind() {
    case "$(command -v "$1" 2>/dev/null)" in
        '') printf '' ;;
        /*) printf 'file' ;;
        *)  printf 'shell' ;;
    esac
}

_run_cleanup() {
    case "$_tmp_dir" in */ggt.*) rm -rf "$_tmp_dir" 2>/dev/null ;; esac
    _tmp_dir=""
}

# _run_init -> the private temp directory, the traps, and timeout(1). Call it
# once in main, before anything creates a temp file.
_run_init() {
    _run_t0="$(date +%s 2>/dev/null)"
    case "$_run_t0" in ''|*[!0-9]*) _run_t0="" ;; esac
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ggt.XXXXXX" 2>/dev/null)"
    [ -n "$_tmp_dir" ] || { _tmp_dir="${TMPDIR:-/tmp}/ggt.$$.${_run_t0:-0}"; mkdir -m 700 "$_tmp_dir" 2>/dev/null || _tmp_dir=""; }
    trap '_run_cleanup' EXIT
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
    [ -n "${_timeout_bin:-}" ] || _timeout_bin="$(command -v timeout 2>/dev/null)"
}

# _tmp NAME -> a path inside this run's directory. /dev/null when no directory
# could be made, so a write is lost rather than landing somewhere shared.
_tmp() { if [ -n "$_tmp_dir" ]; then printf '%s/%s' "$_tmp_dir" "$1"; else printf '/dev/null'; fi; }

# _kill_tree SIG PID -> signal PID and every descendant. dash starts a background
# job in the caller's process group even under set -m, so a group kill misses
# the grandchildren; /proc/<pid>/status names each process's parent.
_kill_tree() {
    local sig="$1" all="$2" list="$2" next c
    while [ -n "$list" ]; do
        next=""
        for c in $list; do
            next="$next $(grep -l "^PPid:[[:space:]]*$c\$" /proc/[0-9]*/status 2>/dev/null | cut -d/ -f3)"
        done
        list="$(echo $next)"
        all="$all $list"
    done
    # shellcheck disable=SC2086
    kill -"$sig" $all 2>/dev/null
}

_bounded() {
    local t="${CMD_TIMEOUT:-20}" left start rc p w
    start="$(_elapsed)"
    left=$((RUN_DEADLINE - start))
    [ "$left" -le 0 ] && return 124
    [ "$left" -lt "$t" ] && t="$left"
    if [ -n "${_timeout_bin:-}" ] && [ "$(_cmd_kind "$1")" = file ]; then
        "$_timeout_bin" "$t" "$@"; rc=$?
    else
        # The kill has to reach whatever CMD started: an orphaned grandchild
        # holds a $(...) pipe open and the caller waits for it anyway. bash
        # under set -m gives the job its own group; _kill_tree covers dash.
        set -m 2>/dev/null
        "$@" 0<&0 &
        p=$!
        set +m 2>/dev/null
        ( i=0
          while [ "$i" -lt "$t" ]; do sleep 1; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        wait "$p"; rc=$?
        kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
    fi
    case "$rc" in 124|137|143) [ $(( $(_elapsed) - start )) -ge "$t" ] && rc=124 ;; esac
    return "$rc"
}

_report_to_file() {
    if ! { : > "$1"; } 2>/dev/null; then
        warn "the report was not written: $1 cannot be created by uid $(id -u 2>/dev/null || echo '?')"
        return 1
    fi
    run_report > "$1" 2>/dev/null
    if ! tail -n 1 "$1" 2>/dev/null | grep -q '^==== END OF COLLECTION'; then
        warn "the report was not written whole: $1 does not end with the footer"
        return 1
    fi
}
# ---- end run helpers

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
# `na` needs every input behind the absence to have been read. One unreadable
# path, one refused call, one timeout, and it is `missed` (output-format.md,
# "Three outcomes"). A non-root run that sees no agent process because it cannot
# read other users' /proc/<pid>/environ has not seen that there is no agent.
#
# Declare a goal once, then resolve it exactly once, after the last fallback. A
# goal left unresolved counts as missed with reason "not reached": the run ended
# before that step. A goal resolved twice with different outcomes counts as
# blocked and says so, because the second call usually hides the first (missed
# then na turned a refused read into COMPLETE). A resolution for a goal never
# declared is listed. A requested opt-in is a goal; an unrequested one is not.
#
# Storage is one line per record, KEY<TAB>VALUE, so a reason cannot shift the
# others: tabs and newlines inside a reason are flattened on the way in.
_goals='' _res=''

_flat() { printf '%s' "$1" | tr '\n\t' '  '; }

goal() {
    case "$_nl$_goals" in *"$_nl$1$_tab"*) return 0 ;; esac
    _goals="$_goals$1$_tab$(_flat "$2")$_nl"
}
got()    { _res="$_res$1${_tab}got$_tab$_nl"; }
na()     { _res="$_res$1${_tab}na$_tab$(_flat "$2")$_nl"; }
missed() { _res="$_res$1${_tab}missed$_tab$(_flat "$2")$_nl"; }

# notice: like progress, but NOT silenced by --quiet. Reserved for the
# completeness roll-up. --quiet exists to keep run narration out of automation
# logs; the one line that decides whether a run is worth sending is not
# narration, and an automated caller wants it most of all.
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null; }

# emit_status -> the roll-up section. Call it immediately before emit_footer.
# Also repeats each gap on fd 3 so the operator sees it while still logged in.
emit_status() {
    [ -n "$_goals" ] || return 0
    local k lab outs total=0 obtained=0 nacount=0 blocked=0 gaps='' nas='' oks='' stray deadline=''
    while IFS="$_tab" read -r k lab; do
        [ -n "$k" ] || continue
        total=$((total + 1))
        # every outcome recorded for this key, in order, and the distinct set
        outs="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { printf "%s%s", (n++ ? ", " : ""), $2 }')"
        case "$outs" in
            got|got,\ got*)
                case "$outs" in *na*|*missed*) ;; *)
                    obtained=$((obtained + 1)); oks="$oks $lab,"; continue ;; esac ;;
        esac
        case "$outs" in
            na|na,\ na*)
                case "$outs" in *got*|*missed*) ;; *)
                    nacount=$((nacount + 1))
                    nas="$nas$lab — $(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k { print $3; exit }')$_nl"
                    continue ;; esac ;;
        esac
        blocked=$((blocked + 1))
        local why
        why="$(printf '%s' "$_res" | awk -F'\t' -v k="$k" '$1 == k && $2 == "missed" { printf "%s%s", (n++ ? "; " : ""), $3 }')"
        case "$outs" in
            '')           why='not reached' ;;
            missed|missed,\ missed*)
                case "$outs" in *got*|*na*) why="resolved $(printf '%s' "$outs" | awk -F', ' '{print NF}') times: $outs${why:+ — $why}" ;; esac ;;
            *)            why="resolved $(printf '%s' "$outs" | awk -F', ' '{print NF}') times: $outs${why:+ — $why}" ;;
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

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- reasoned-absence helpers -------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_timeout_bin=""
CMD_TIMEOUT=15
_init_probe() {
    _errfile="$(_tmp probe.err)"
    have timeout && _timeout_bin="$(command -v timeout)"
}
_end_probe() { [ -n "$_errfile" ] && rm -rf "$_errfile" "$_errfile".* 2>/dev/null; }

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

# dump_file "label" PATH [CAP] -> the file's content verbatim (line-capped),
# or a classified reason. Framework policy: configuration is dumped verbatim,
# never masked (see collectors/apm/java/README.md security note).
dump_file() {
    local label="$1" path="$2" cap="${3:-400}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (first $cap of ${total:-?} lines):"
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# tail_file "label" PATH [CAP] -> the file's LAST lines (bounded read).
tail_file() {
    local label="$1" path="$2" cap="${3:-200}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (last $cap of ${total:-?} lines):"
    tail -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# head_file "label" PATH [CAP] -> the file's FIRST lines (bounded read).
head_file() {
    local label="$1" path="$2" cap="${3:-120}" total
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label (first $cap of ${total:-?} lines):"
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# conf_bytes "label" PATH -> byte-level facts a plain `cat` hides: total bytes
# and CR (\r, 0x0D) byte count. Windows-edited conf files reach Linux hosts
# through support cases; the reader compares these against the dumped text.
conf_bytes() {
    local label="$1" path="$2" sz cr
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
    cr="$(tr -dc '\r' < "$path" 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}

# _sha256 PATH -> the artifact's sha256, or a classified reason.
_sha256() {
    if have sha256sum; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif have shasum; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else printf 'n/a (command not found: sha256sum, shasum)'; fi
}

# file_facts "indent" PATH -> identity of a binary artifact: size, mtime,
# sha256. The Java agent jar carries no version in its filename in many
# deployments, so these are the cross-check for the in-jar version.
file_facts() {
    local ind="$1" p="$2" sz mt sum
    [ -e "$p" ] || { printf '%sn/a (path not found: %s)\n' "$ind" "$p"; return; }
    sz="$(wc -c < "$p" 2>/dev/null | tr -d ' ')"
    mt="$(stat -c '%y' "$p" 2>/dev/null || ls -l "$p" 2>/dev/null | cut -c1-60)"
    printf '%ssize: %s bytes   mtime: %s\n' "$ind" "${sz:-?}" "${mt:-n/a (stat and ls both unavailable)}"
    printf '%ssha256: %s\n' "$ind" "$(_sha256 "$p")"
}

# jar_version "indent" JAR -> VERSION/BUILD from whatap/v.properties inside the
# jar (the file the agent's own whatap.Version class reads), read with unzip.
jar_version() {
    local ind="$1" jar="$2" out
    if ! have unzip; then
        printf '%sin-jar whatap/v.properties: n/a (command not found: unzip)\n' "$ind"
        return
    fi
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" unzip -p "$jar" whatap/v.properties 2>"$_errfile")"
    else out="$(unzip -p "$jar" whatap/v.properties 2>"$_errfile")"; fi
    if [ -z "$out" ]; then
        printf '%sin-jar whatap/v.properties: n/a (%s)\n' "$ind" "$(_classify_err)"
        return
    fi
    printf '%sin-jar whatap/v.properties:\n' "$ind"
    printf '%s\n' "$out" | head -n 10 | while IFS= read -r _l || [ -n "$_l" ]; do printf '%s  %s\n' "$ind" "$_l"; done
}

# jar_entries "indent" JAR PATTERN CAP -> file entry names inside a jar
# (central directory read only; the jar is never executed or loaded).
# Directory entries are dropped so the list holds libraries, not folders.
jar_entries() {
    local ind="$1" jar="$2" pat="$3" cap="${4:-100}" out n
    have unzip || { printf '%sn/a (command not found: unzip)\n' "$ind"; return; }
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" unzip -Z1 "$jar" "$pat" 2>/dev/null | grep -v '/$')"
    else out="$(unzip -Z1 "$jar" "$pat" 2>/dev/null | grep -v '/$')"; fi
    [ -z "$out" ] && { printf '%snone matching %s\n' "$ind" "$pat"; return; }
    n="$(printf '%s\n' "$out" | grep -c .)"
    printf '%s%s entries matching %s (first %s):\n' "$ind" "${n:-0}" "$pat" "$cap"
    printf '%s\n' "$out" | head -n "$cap" | while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        printf '%s  %s\n' "$ind" "$(basename "$_l")"
        _lib_record "$(basename "$_l")"
        case "$_l" in *.jar) _path_record "nested|$jar|$_l" ;; esac
    done
}

# jvprobe "label" JAVA_EXE [ARGS...] -> run a DISCOVERED java binary (a new,
# short-lived JVM). Never applied to a running process.
jvprobe() {
    local label="$1" jv="$2"; shift 2
    [ -x "$jv" ] || { fact "$label: n/a (not executable: $jv)"; return; }
    local out rc
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$jv" "$@" 2>&1)"; rc=$?
    else out="$("$jv" "$@" 2>&1)"; rc=$?; fi
    [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ] && { fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; }
    [ -z "$out" ] && { fact "$label: n/a (empty output)"; return; }
    _emit_labeled "$label" "$out"
}

# _lib_record NAME -> append a library name to the per-process inventory that
# section H filters. No-op when _LIBSINK is unset (outside section F).
_LIBSINK=""
_lib_record() {
    [ -n "$_LIBSINK" ] || return
    [ -n "$1" ] || return
    printf '%s\n' "$1" >> "$_LIBSINK" 2>/dev/null
}

# _path_record RECORD -> append a locatable jar to the inventory section M
# details. RECORD is "file|<path>" for a jar on the filesystem, or
# "nested|<container jar>|<entry>" for one packed inside an executable jar.
_PATHSINK=""
_path_record() {
    [ -n "$_PATHSINK" ] || return
    [ -n "$1" ] || return
    printf '%s\n' "$1" >> "$_PATHSINK" 2>/dev/null
}

# _appclass_record RECORD -> append an application class ROOT to the inventory
# section N enumerates. RECORD is "dir|<path>" for an exploded class directory
# or a directory classpath entry, or "archive|<path>" for a war/ear/executable
# jar whose WEB-INF/classes or BOOT-INF/classes is read in place. Jars are
# libraries and go to _path_record; the classes the application itself ships
# live in these roots and are enumerated nowhere else in this report.
_APPSINK=""
_appclass_record() {
    [ -n "$_APPSINK" ] || return
    [ -n "$1" ] || return
    printf '%s\n' "$1" >> "$_APPSINK" 2>/dev/null
}

# list_jars "indent" DIR CAP -> *.jar names in ONE directory level (no walk),
# with the agent jar filtered out and the count reported.
list_jars() {
    local ind="$1" d="$2" cap="${3:-120}" n out
    [ -d "$d" ] || { printf '%s%s: n/a (path not found)\n' "$ind" "$d"; return; }
    [ -r "$d" ] || { printf '%s%s: n/a (permission denied)\n' "$ind" "$d"; return; }
    out="$(ls "$d" 2>/dev/null | grep -i '\.jar$')"
    if [ -z "$out" ]; then printf '%s%s: 0 jar files\n' "$ind" "$d"; return; fi
    out="$(printf '%s\n' "$out" | grep -v -i 'whatap\.agent')"
    n="$(printf '%s\n' "$out" | grep -c . )"
    printf '%s%s: %s jar files (%s printed; every one of the %s is recorded, so --library matches beyond the printed part)\n' "$ind" "$d" "${n:-0}" "$cap" "${n:-0}"
    # record every jar, print only the first CAP: a deployment unit can carry
    # several hundred jars, and the application's own ones sort anywhere in
    # that list (case 2026-09-17 FIF: 282 jars, the customer's own at "f")
    _lj=0
    printf '%s\n' "$out" | while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        _lj=$((_lj + 1))
        [ "$_lj" -le "$cap" ] && printf '%s  %s\n' "$ind" "$_l"
        _lib_record "$_l"
        _path_record "file|$d/$_l"
    done
}

# list_deploy "indent" DIR -> deployment units in a server deploy directory,
# one level plus the standard lib dirs inside exploded ear/war units.
list_deploy() {
    local ind="$1" d="$2" u seen=""
    [ -d "$d" ] || { printf '%s%s: n/a (path not found)\n' "$ind" "$d"; return; }
    printf '%sdeploy dir %s (units, first 60):\n' "$ind" "$d"
    ls "$d" 2>/dev/null | head -n 60 | while IFS= read -r _l; do printf '%s  %s\n' "$ind" "$_l"; done
    # the last two globs overlap on *.war units; list each directory once
    for u in "$d"/*.ear/lib "$d"/*.war/WEB-INF/lib "$d"/*/WEB-INF/lib; do
        [ -d "$u" ] || continue
        case "$seen" in *"|$u|"*) continue ;; esac
        seen="$seen|$u|"
        list_jars "$ind  " "$u" 120
    done
    # the application's own classes, for section N — exploded units first,
    # then unexploded archives read in place
    for u in "$d"/*.ear/*.war/WEB-INF/classes "$d"/*.war/WEB-INF/classes "$d"/*/WEB-INF/classes; do
        [ -d "$u" ] || continue
        case "$seen" in *"|$u|"*) continue ;; esac
        seen="$seen|$u|"
        _appclass_record "dir|$u"
    done
    for u in "$d"/*.war "$d"/*.ear; do
        [ -f "$u" ] || continue
        _appclass_record "archive|$u"
    done
}

# _build_libroots -> the jars section N will index: every --library match,
# capped. Built once, before section M, because M asks it whether a jar it is
# about to detail will appear in that index: the package histogram of a jar
# whose class names section N prints is the same information twice, and a
# report a field engineer pastes into a chat is not the place to send it twice
# (case 2026-09-17 FIF: 40 jars, 988 of the report's 2738 lines).
_LIBROOTS=""
_build_libroots() {
    _LIBROOTS="${_errfile}.libroots"
    : > "$_LIBROOTS" 2>/dev/null
    [ "$OPT_APPCLASSES" = 1 ] || return 0
    [ -n "$OPT_LIBS" ] || [ "$OPT_LIBALL" = 1 ] || return 0
    [ -s "$_PATHSINK" ] || return 0
    sort -u "$_PATHSINK" 2>/dev/null | while IFS= read -r _lrec; do
        case "$_lrec" in
            file\|*) _lp="${_lrec#file|}"; _lib_match "$_lp" || continue
                     printf 'libjar|%s\n' "$_lp" ;;
        esac
    done | head -n 60 > "$_LIBROOTS" 2>/dev/null
}

# _in_libroots PATH -> success when section N will index this jar
_in_libroots() {
    [ -s "$_LIBROOTS" ] || return 1
    grep -qxF "libjar|$1" "$_LIBROOTS" 2>/dev/null
}

# _lib_match NAME -> success when NAME matches a --library pattern (or when
# --library-all was given). Case-insensitive substring match.
_lib_match() {
    [ "$OPT_LIBALL" = 1 ] && return 0
    [ -n "$OPT_LIBS" ] || return 1
    local n p
    n="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    for p in $OPT_LIBS; do
        p="$(printf '%s' "$p" | tr 'A-Z' 'a-z')"
        case "$n" in *"$p"*) return 0 ;; esac
    done
    return 1
}

# class_file_version "indent" JAR -> the class-file major version carried by
# the jar, read from the first class entry (bytes 6-7 of the class file, big
# endian). A weaving module has to be compiled for a version the target class
# accepts, so this is the number its author needs. major - 44 is the Java
# feature release (52 = Java 8).
class_file_version() {
    local ind="$1" jar="$2" ent hi lo maj
    have unzip || { printf '%sclass-file version: n/a (command not found: unzip)\n' "$ind"; return; }
    have od    || { printf '%sclass-file version: n/a (command not found: od)\n' "$ind"; return; }
    ent="$(unzip -Z1 "$jar" '*.class' 2>/dev/null | grep -v '^META-INF/versions/' | head -n1)"
    [ -n "$ent" ] || { printf '%sclass-file version: n/a (no class entry in this jar)\n' "$ind"; return; }
    set -- $(unzip -p "$jar" "$ent" 2>/dev/null | od -An -tu1 -j6 -N2 2>/dev/null)
    hi="$1"; lo="$2"
    [ -n "$lo" ] || { printf '%sclass-file version: n/a (class entry not readable: %s)\n' "$ind" "$ent"; return; }
    maj=$(( hi * 256 + lo ))
    printf '%sclass-file major version: %s (Java %s), read from %s\n' "$ind" "$maj" "$((maj - 44))" "$ent"
}

# detail_jar "label" JAR -> the facts a weaving-module author needs about one
# library: identity, Maven coordinates, manifest versions, class-file version,
# package map (a relocated/shaded jar shows it here), class count, service
# entries, multi-release markers.
detail_jar() {
    local label="$1" jar="$2" origin="$3" pp cnt
    fact "-- $label"
    if [ -n "$origin" ]; then
        # a library packed inside an executable jar has no path of its own on
        # this host; size and sha256 identify the entry's content, and the
        # timestamps of the extraction it was read through carry no meaning
        fact "       origin: $origin"
        fact "       size: $(wc -c < "$jar" 2>/dev/null | tr -d ' ') bytes (content of that entry)"
        fact "       sha256: $(_sha256 "$jar")"
    else
        fact "       path: $jar"
        file_facts "           " "$jar"
    fi
    if ! have unzip; then
        fact "       jar contents: n/a (command not found: unzip)"
        return
    fi
    # definitive coordinates: the build stamps them into the jar
    pp="$(unzip -Z1 "$jar" 'META-INF/maven/*/pom.properties' 2>/dev/null | head -n 3)"
    if [ -n "$pp" ]; then
        printf '%s\n' "$pp" | while IFS= read -r _e; do
            printf '           maven entry: %s\n' "$_e"
            unzip -p "$jar" "$_e" 2>/dev/null | grep -vE '^#' | while IFS= read -r _l; do
                [ -n "$_l" ] && printf '             %s\n' "$_l"
            done
        done
    else
        fact "       maven coordinates: none (no META-INF/maven/*/pom.properties in this jar)"
    fi
    # manifest version attributes, for jars without maven metadata
    _mf="$(unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' \
           | grep -iE '^(Implementation-|Specification-|Bundle-SymbolicName|Bundle-Version|Bundle-Name|Automatic-Module-Name|Build-Jdk|Created-By|Multi-Release|Export-Package)' | head -n 20)"
    if [ -n "$_mf" ]; then
        fact "       manifest attributes:"
        printf '%s\n' "$_mf" | while IFS= read -r _l; do printf '             %s\n' "$(printf '%s' "$_l" | cut -c1-200)"; done
    else
        fact "       manifest attributes: none of the version attributes are present"
    fi
    class_file_version "           " "$jar"
    # package map: reveals the real namespace, including relocation/shading
    cnt="$(unzip -Z1 "$jar" '*.class' 2>/dev/null | grep -c .)"
    fact "       class entries: ${cnt:-0}"
    if [ "${_DJ_IN_INDEX:-0}" = 1 ]; then
        fact "       packages by class count: not repeated here — the class names of this jar are in the section N index (--library with --appclasses)"
    else
        fact "       packages by class count (top 25):"
        unzip -Z1 "$jar" '*.class' 2>/dev/null | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -n 25 \
            | while IFS= read -r _l; do printf '             %s\n' "$(printf '%s' "$_l" | sed 's|/|.|g')"; done
    fi
    _mr="$(unzip -Z1 "$jar" 'META-INF/versions/*' 2>/dev/null | sed 's|^META-INF/versions/\([0-9]*\)/.*|\1|' | sort -u | tr '\n' ' ')"
    [ -n "$_mr" ] && fact "       multi-release jar, versioned class trees for: $_mr"
    unzip -Z1 "$jar" 'module-info.class' >/dev/null 2>&1 && fact "       module-info.class: present"
    _svc="$(unzip -Z1 "$jar" 'META-INF/services/*' 2>/dev/null | head -n 10)"
    if [ -n "$_svc" ]; then
        fact "       service provider entries:"
        printf '%s\n' "$_svc" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
    fi
    # member signatures of the classes named with --class
    for _fq in $OPT_CLASSES; do
        _ce="$(printf '%s' "$_fq" | tr '.' '/').class"
        unzip -Z1 "$jar" "$_ce" >/dev/null 2>&1 || continue
        if ! have javap; then
            fact "       $_fq: present in this jar; member signatures n/a (command not found: javap)"
            continue
        fi
        fact "       $_fq member signatures (javap -p -s, first 400 lines):"
        if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$CMD_TIMEOUT" javap -p -s -classpath "$jar" "$_fq" 2>&1 | head -n 400 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
        else javap -p -s -classpath "$jar" "$_fq" 2>&1 | head -n 400 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done; fi
    done
}

# bootjar_facts "indent" JAR -> the facts an executable (fat) jar carries that
# a loose classpath does not: the launcher manifest (Start-Class names the real
# application entry class, Spring-Boot-Version decides which weaving module
# applies), the layer index, and the package map of the application's own
# classes under BOOT-INF/classes.
bootjar_facts() {
    local ind="$1" jar="$2" mf cnt
    have unzip || { printf '%sexecutable jar layout: n/a (command not found: unzip)\n' "$ind"; return; }
    unzip -Z1 "$jar" 'BOOT-INF/*' 2>/dev/null | head -n1 | grep -q . || return
    printf '%sexecutable jar layout: BOOT-INF present (libraries are packed inside this jar, not on the filesystem)\n' "$ind"
    mf="$(unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' \
          | grep -iE '^(Main-Class|Start-Class|Spring-Boot-Version|Spring-Boot-Classes|Spring-Boot-Lib|Implementation-Title|Implementation-Version|Build-Jdk|Created-By)' | head -n 12)"
    if [ -n "$mf" ]; then
        printf '%slauncher manifest:\n' "$ind"
        printf '%s\n' "$mf" | while IFS= read -r _l; do printf '%s  %s\n' "$ind" "$(printf '%s' "$_l" | cut -c1-200)"; done
    else
        printf '%slauncher manifest: none of the launcher attributes are present\n' "$ind"
    fi
    unzip -Z1 "$jar" 'BOOT-INF/layers.idx' >/dev/null 2>&1 && printf '%sBOOT-INF/layers.idx: present (layered jar)\n' "$ind"
    cnt="$(unzip -Z1 "$jar" 'BOOT-INF/classes/*.class' 2>/dev/null | grep -c .)"
    printf '%sapplication classes in BOOT-INF/classes: %s\n' "$ind" "${cnt:-0}"
    if [ "${cnt:-0}" -gt 0 ]; then
        printf '%sapplication packages by class count (top 20):\n' "$ind"
        unzip -Z1 "$jar" 'BOOT-INF/classes/*.class' 2>/dev/null \
            | sed 's|^BOOT-INF/classes/||; s|/[^/]*$||' | sort | uniq -c | sort -rn | head -n 20 \
            | while IFS= read -r _l; do printf '%s  %s\n' "$ind" "$(printf '%s' "$_l" | sed 's|/|.|g')"; done
    fi
}

# nested_extract CONTAINER ENTRY -> extract one packed jar to a temp path and
# print that path, so the same detail_jar reader works on a library that only
# exists inside an executable jar. Bounded: entries above 80 MB are skipped.
nested_extract() {
    local jar="$1" ent="$2" out sz
    have unzip || return 1
    sz="$(unzip -Zt "$jar" "$ent" 2>/dev/null | awk '{print $3}')"
    if [ -n "$sz" ] && [ "$sz" -gt 83886080 ] 2>/dev/null; then return 1; fi
    out="${_errfile}.nested.jar"
    unzip -p "$jar" "$ent" > "$out" 2>/dev/null || return 1
    [ -s "$out" ] || return 1
    printf '%s\n' "$out"
}

# weaving_lines "label" PATH -> the agent-log lines carrying the "Weaving" log
# id, from a BOUNDED window (module load lines are written at startup, so the
# head of the file is searched as well as the tail; never a whole-file grep).
weaving_lines() {
    local label="$1" path="$2" hw=3000 tw=1000 out n
    [ -e "$path" ] || { fact "-- $label: n/a (path not found)"; return; }
    [ -r "$path" ] || { fact "-- $label: n/a (permission denied)"; return; }
    out="$( { head -n "$hw" "$path" 2>/dev/null; tail -n "$tw" "$path" 2>/dev/null; } \
            | grep -a 'Weaving' | sort -u | head -n 80)"
    if [ -z "$out" ]; then
        fact "-- $label: no line carrying the Weaving log id in the first $hw or last $tw lines"
        return
    fi
    n="$(printf '%s\n' "$out" | grep -c .)"
    fact "-- $label: $n distinct Weaving lines in the first $hw and last $tw lines (first 80):"
    printf '%s\n' "$out" | while IFS= read -r _l; do printf '             %s\n' "$(printf '%s' "$_l" | cut -c1-300)"; done
}

# ---- process / JVM helpers ---------------------------------------------------
# _proc_env PID NAME -> value of NAME= in the process environ (empty if none).
# Java agent env names may contain dots (license, whatap.server.host), which is
# why the environ file is read directly instead of using the shell environment.
_proc_env() {
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | grep "^$2=" | head -n1 | cut -d= -f2-
}

# _all_jvm_args PID -> one JVM argument per line, in the order the JVM applies
# them: JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS, the command line, then
# _JAVA_OPTIONS (which HotSpot processes last). The operator injects
# -javaagent through JAVA_TOOL_OPTIONS, so the command line alone is not enough.
# A fifth source is appended when it exists: arguments recovered from the
# running VM itself with `jcmd` (see _jcmd_recover). It is written only for a
# process whose options are absent from /proc and only when --jcmd was passed,
# is empty otherwise, and is last because it reports the EFFECTIVE set the VM
# holds — which is what "last wins" means for _jvm_sysprop.
_all_jvm_args() {
    local pid="$1"
    _proc_env "$pid" JAVA_TOOL_OPTIONS | tr ' ' '\n'
    _proc_env "$pid" JDK_JAVA_OPTIONS | tr ' ' '\n'
    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null
    _proc_env "$pid" _JAVA_OPTIONS | tr ' ' '\n'
    [ -n "$_errfile" ] && [ -f "${_errfile}.jcmdargs.$pid" ] \
        && cat "${_errfile}.jcmdargs.$pid" 2>/dev/null
    return 0
}

# ---- Tier 2 argument recovery (opt-in: --jcmd) --------------------------------
# A JVM the collector found only by its libjvm.so mapping carries its options
# nowhere in /proc: the native launcher passed them to JNI_CreateJavaVM as an
# array it built, so /proc/<pid>/cmdline holds the launcher's own arguments and
# nothing else. Sections E, F and G read those options, so for such a process
# they have nothing to read and report absence.
#
# The running VM still holds them, and `jcmd <pid> VM.command_line` and
# `VM.system_properties` report them. Reaching the VM that way is the JVM
# attach mechanism on a live process — Tier 2 — so this runs ONLY when the
# field engineer passed --jcmd, and only for the processes whose options are
# not in /proc. Its output is written to a per-pid file that _all_jvm_args
# appends, so every section downstream reads it through the path it already
# uses; nothing else changes.
#
# Splitting jvm_args on spaces is the same treatment _all_jvm_args already
# gives JAVA_TOOL_OPTIONS: an argument containing a space is split, and both
# halves are reported. VM.system_properties is Properties.store format, in
# which "=", ":", "#" and "!" arrive backslash-escaped in keys and values
# alike (java.class.path reaches here as /a\:/b), so those escapes are undone
# before each property is written as the -Dkey=value the other sections read.
_JCMD_RECOVERED=""
_jcmd_recover() {
    local pid="$1" out cl dst
    have jcmd || return 1
    dst="${_errfile}.jcmdargs.$pid"
    : > "$dst" 2>/dev/null
    warn "[Tier2] jcmd argument recovery: pid $pid — uses the JVM attach mechanism on the target process"
    if [ -n "$_timeout_bin" ]; then cl="$("$_timeout_bin" "$CMD_TIMEOUT" jcmd "$pid" VM.command_line 2>/dev/null)"
    else cl="$(jcmd "$pid" VM.command_line 2>/dev/null)"; fi
    printf '%s\n' "$cl" | sed -n 's/^jvm_args: //p' | tr ' ' '\n' | grep . >> "$dst" 2>/dev/null
    # the program the VM recorded, when it recorded one; a VM created straight
    # through JNI_CreateJavaVM often carries "<unknown>" here, and that is the
    # fact section D prints in place of a main class read off the launcher's
    # own argv, which is not a java command line at all
    printf '%s\n' "$cl" | sed -n 's/^java_command: //p' | head -n1 > "${_errfile}.jcmdmain.$pid" 2>/dev/null
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" jcmd "$pid" VM.system_properties 2>/dev/null)"
    else out="$(jcmd "$pid" VM.system_properties 2>/dev/null)"; fi
    # a -D the launcher passed is already in the file, from jvm_args; only the
    # properties it does not carry are appended, so no option is listed twice
    printf '%s\n' "$out" | grep '=' | grep -v '^#' \
        | sed 's/\\:/:/g; s/\\=/=/g; s/\\!/!/g; s/\\#/#/g; s/^/-D/' \
        | awk 'NR==FNR { if (substr($0,1,2) == "-D") { split($0, kv, "="); seen[kv[1]] = 1 } next }
               { split($0, kv, "="); if (!(kv[1] in seen)) print }' "$dst" - > "${dst}.sp" 2>/dev/null
    cat "${dst}.sp" >> "$dst" 2>/dev/null
    rm -f "${dst}.sp" 2>/dev/null
    [ -s "$dst" ] || { rm -f "$dst" 2>/dev/null; return 1; }
    _JCMD_RECOVERED="$_JCMD_RECOVERED $pid"
    return 0
}

# _jvm_sysprop PID KEY -> the last -DKEY=value seen across all argument
# sources (see _all_jvm_args for the order). Empty when the property is unset.
_jvm_sysprop() {
    _all_jvm_args "$1" 2>/dev/null | grep "^-D$2=" | tail -n1 | sed "s/^-D$2=//"
}

# _jvm_maps_lib PID -> the VM shared library mapped into the process, or empty.
# Every JVM maps one, whoever started it: the `java` launcher, jsvc, or a
# native program that called JNI_CreateJavaVM itself. HotSpot and its
# derivatives map libjvm.so; OpenJ9 / IBM J9 map libj9vm<ver>.so beside their
# own libjvm.so. The mapping is matched, not a name list of launchers.
_jvm_maps_lib() {
    [ -r "/proc/$1/maps" ] || return 1
    grep -m1 -oE '/[^[:space:]]*/(libjvm\.so|libj9vm[^/[:space:]]*\.so)' "/proc/$1/maps" 2>/dev/null \
        | head -n1
}

_IS_JVM_WHY=""
# _is_jvm PID -> success if the process is a JVM (resolved binary, comm, a
# JVM-only argument, or a mapped VM shared library). On success _IS_JVM_WHY
# holds the test that settled it, which section D reports per process.
# Launchers rename the process, so comm alone is not enough.
# A launcher may rename the process (JBoss run.jar, jsvc, custom start
# scripts), so comm alone is not enough; a JVM-only option is accepted as
# evidence, but only as a WHOLE argument. A shell wrapper whose command line
# merely contains a java invocation as text keeps the whole command in one
# argument, and interpreters are excluded outright, so start.sh is not
# reported as a JVM.
#
# The fourth and last test reads /proc/<pid>/maps. A NATIVE LAUNCHER that
# creates the VM in its own process through the JNI Invocation API
# (JNI_CreateJavaVM) leaves nothing for the first three: comm and exe are the
# launcher's own name, and the JVM options it hands to JNI_CreateJavaVM are an
# array it built in memory, so they never reach /proc/<pid>/cmdline. What such
# a process does have, like every other JVM, is the VM shared library mapped
# into it. Axway API Gateway (`vshell`) is one launcher of this shape;
# the test names none of them and matches the mapping instead, so a launcher
# this collector has never seen is reported the same way (CONTRACT rule 2).
# It runs LAST, only for the processes the three cheaper tests did not settle,
# because it opens one more file per remaining process.
_is_jvm() {
    local pid="$1" comm exe lib
    _IS_JVM_WHY=""
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
    case "$comm" in java|java.*|jsvc*|jexec*) _IS_JVM_WHY="comm is $comm"; return 0 ;; esac
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
    case "${exe##*/}" in
        java|jsvc|jsvc.exec) _IS_JVM_WHY="resolved exe is $exe"; return 0 ;;
        sh|bash|dash|ksh|zsh|busybox|python*|perl|ruby|node|nodejs|awk|sed|grep|tr) return 1 ;;
    esac
    if tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null \
        | grep -qE '^-(javaagent:|Xmx|Xms|XX:|Dcatalina\.|Djava\.|Dwhatap\.)'; then
        _IS_JVM_WHY="a JVM-only whole argument on the command line"
        return 0
    fi
    lib="$(_jvm_maps_lib "$pid")"
    if [ -n "$lib" ]; then
        _IS_JVM_WHY="$lib mapped in /proc/$pid/maps (comm ${comm:-n/a}, exe ${exe:-n/a}, no JVM argument on the command line)"
        return 0
    fi
    return 1
}

# _whatap_attached PID -> success if a whatap -javaagent reaches this JVM from
# any argument source, or a whatap system property / env variable is present.
_whatap_attached() {
    local pid="$1"
    _all_jvm_args "$pid" 2>/dev/null | grep -qiE '^-javaagent:.*whatap|^-Dwhatap\.' && return 0
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
        | grep -qiE '^(WHATAP_|whatap\.|license=)' && return 0
    return 1
}

# ---- discovery (internal; emits nothing) --------------------------------------
# Populates:
#   D_JVM_PIDS    pids of JVM processes, WhaTap-attached ones first
#   D_MARKED      pids among them that carry a WhaTap attach marker
#   D_JAVA_EXES   distinct java binaries (running processes + PATH + JAVA_HOME)
#   D_AGENT_JARS  newline-joined "path|source" records for whatap agent jars
#   D_HOMES       newline-joined "path|source" records for agent home candidates
#   D_JVM_WHY     newline-joined "pid|test that settled it" records
#   D_JVM_NOARGS  pids found only by a mapped VM library: no options in /proc
#   D_PROC_SCANNED / D_PROC_SKIPPED  what the /proc walk covered, so section D
#                 states the basis of an empty result instead of only the result
D_JVM_PIDS=""
D_JVM_WHY=""
D_JVM_NOARGS=""
D_PROC_SCANNED=0
D_PROC_SKIPPED=0
D_MARKED=""
D_JAVA_EXES=""
D_JAVA_KEYS=""
D_AGENT_JARS=""
D_HOMES=""

# resolve_fs PATH -> a readable filesystem view of PATH: the path itself if it
# exists here, otherwise the same path seen through the root of a discovered
# JVM (/proc/<pid>/root<PATH>). Empty if neither is visible. This lets the
# collector run from a different mount namespace (node shell, kubectl debug).
resolve_fs() {
    local p="$1" pid
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    for pid in $D_JVM_PIDS; do
        [ -e "/proc/$pid/root$p" ] && { printf '%s\n' "/proc/$pid/root$p"; return; }
    done
    return 1
}

# resolve_rel PID PATH -> a readable filesystem view of PATH as the JVM at PID
# resolves it. An absolute path goes through resolve_fs. A RELATIVE path is
# resolved by a process against its OWN working directory, never the
# collector's, so it is joined to /proc/<pid>/cwd — the same directory
# section D reports. The collector is often started somewhere else than the
# JVM (a script copied to /tmp, a debug shell), and an entrypoint of
# "java -jar app.jar" under a WORKDIR is a documented container layout, so a
# relative argument is an ordinary case and not an exotic one.
resolve_rel() {
    local pid="$1" p="$2" c
    case "$p" in /*) resolve_fs "$p"; return ;; esac
    c="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
    [ -n "$c" ] && [ -e "$c/$p" ] && { printf '%s\n' "$c/$p"; return; }
    [ -e "/proc/$pid/cwd/$p" ] && { printf '%s\n' "/proc/$pid/cwd/$p"; return; }
    return 1
}

# cwd_view PID -> a readable path to the working directory of PID: the link
# target when it exists in this mount namespace, otherwise the link itself,
# which the kernel resolves inside the target's namespace.
cwd_view() {
    local pid="$1" t
    t="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
    [ -n "$t" ] && [ -d "$t" ] && { printf '%s\n' "$t"; return; }
    [ -d "/proc/$pid/cwd" ] && { printf '%s\n' "/proc/$pid/cwd"; return; }
    return 1
}

# tomcat_app_bases FSDIR -> every appBase this instance configures, one per
# line. Read from server.xml instead of assuming <instance>/webapps, because
# an instance is free to place its appBase anywhere; a relative value is
# joined to the instance directory, which is how Tomcat resolves it.
tomcat_app_bases() {
    local fsd="$1" b
    [ -r "$fsd/conf/server.xml" ] || return 0
    grep -o 'appBase="[^"]*"' "$fsd/conf/server.xml" 2>/dev/null \
        | sed 's/^appBase="//; s/"$//' | while IFS= read -r b; do
        [ -n "$b" ] || continue
        case "$b" in /*) printf '%s\n' "$b" ;; *) printf '%s\n' "$fsd/$b" ;; esac
    done
}

# tomcat_doc_bases FSDIR APPBASEFILE -> every docBase this instance configures,
# from server.xml and from the per-host context files under conf/<engine>/
# <host>/. An absolute value is printed as is. A relative value is resolved
# against each appBase listed in APPBASEFILE and against the instance
# directory; only the candidates that exist are printed, so no single layout
# is assumed.
tomcat_doc_bases() {
    local fsd="$1" basefile="$2" f b a
    for f in "$fsd"/conf/server.xml "$fsd"/conf/*/*/*.xml; do
        [ -r "$f" ] || continue
        grep -o 'docBase="[^"]*"' "$f" 2>/dev/null \
            | sed 's/^docBase="//; s/"$//' | while IFS= read -r b; do
            [ -n "$b" ] || continue
            case "$b" in
                /*) printf '%s\n' "$b" ;;
                *)  [ -e "$fsd/$b" ] && printf '%s\n' "$fsd/$b"
                    [ -r "$basefile" ] || continue
                    while IFS= read -r a; do
                        [ -n "$a" ] || continue
                        [ -e "$a/$b" ] && printf '%s\n' "$a/$b"
                    done < "$basefile" ;;
            esac
        done
    done
}

# webapp_roots "indent" FSDIR CAP -> record the application class roots under
# one webapp container directory (an appBase, a Jetty base) and list the
# libraries next to them.
webapp_roots() {
    local ind="$1" ab="$2" cap="${3:-120}" lbl="${4:-appBase}" w
    [ -d "$ab" ] || { printf '%s%s %s: n/a (path not found)\n' "$ind" "$lbl" "$ab"; return; }
    printf '%s%s %s\n' "$ind" "$lbl" "$ab"
    for w in "$ab"/*/WEB-INF/lib; do
        [ -d "$w" ] && list_jars "$ind  " "$w" "$cap"
    done
    for w in "$ab"/*/WEB-INF/classes; do
        [ -d "$w" ] && _appclass_record "dir|$w"
    done
    for w in "$ab"/*.war; do
        [ -f "$w" ] && _appclass_record "archive|$w"
    done
}

_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$D_HOMES" in *"$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES
$p|$s"; else D_HOMES="$p|$s"; fi
}

_add_jar() {  # _add_jar PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$D_AGENT_JARS" in *"$p|"*) return ;; esac
    if [ -n "$D_AGENT_JARS" ]; then D_AGENT_JARS="$D_AGENT_JARS
$p|$s"; else D_AGENT_JARS="$p|$s"; fi
}

# Dedup key for java binaries: the resolved target. Unlike Python virtualenvs,
# a java launcher symlink and its target load the same runtime, so collapsing
# to the resolved path loses nothing.
_add_java() {
    local p="$1" k
    [ -n "$p" ] || return
    [ -x "$p" ] || return
    k="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_JAVA_KEYS" in *"|$k|"*) return ;; esac
    D_JAVA_KEYS="$D_JAVA_KEYS|$k|"
    D_JAVA_EXES="$D_JAVA_EXES $p"
}

discover() {
    progress "discovery: JVM processes, agent jars, agent homes, java binaries"
    local pid exe v a rest marked _jr

    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        D_PROC_SCANNED=$((D_PROC_SCANNED + 1))
        [ "$pid" = "$$" ] && continue
        [ -r "/proc/$pid/cmdline" ] || { D_PROC_SKIPPED=$((D_PROC_SKIPPED + 1)); continue; }
        _is_jvm "$pid" || continue
        D_JVM_PIDS="$D_JVM_PIDS $pid"
        D_JVM_WHY="$D_JVM_WHY
$pid|$_IS_JVM_WHY"
        case "$_IS_JVM_WHY" in *' mapped in /proc/'*) D_JVM_NOARGS="$D_JVM_NOARGS $pid" ;; esac
        exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null)"
        [ -n "$exe" ] && _add_java "$exe"
    done

    # A JVM found by its mapped VM library has no options in /proc. When --jcmd
    # was passed, recover them from the VM before anything reads them — the
    # WhaTap attach marker below is one of the things read.
    if [ "$OPT_JCMD" != 0 ] && [ -n "$D_JVM_NOARGS" ]; then
        progress "discovery: jcmd argument recovery for JVMs whose options are not in /proc"
        _jr=0
        for pid in $D_JVM_NOARGS; do
            _jr=$((_jr + 1))
            [ "$_jr" -gt 4 ] && break
            _jcmd_recover "$pid"
        done
    fi

    # WhaTap-attached JVMs take the per-process detail slots before unrelated
    # JVMs (build daemons, IDE helpers) when the cap applies
    marked=""; rest=""
    for pid in $D_JVM_PIDS; do
        if _whatap_attached "$pid"; then marked="$marked $pid"; else rest="$rest $pid"; fi
    done
    D_MARKED="$marked"
    D_JVM_PIDS="$marked $rest"

    # agent jars and homes from every attached JVM's own arguments
    for pid in $D_JVM_PIDS; do
        for a in $(_all_jvm_args "$pid" 2>/dev/null | grep -i '^-javaagent:.*whatap' | sed 's/^-javaagent://; s/=.*$//'); do
            _add_jar "$a" "-javaagent of pid $pid"
            _add_home "$(dirname "$a" 2>/dev/null)" "directory of the -javaagent jar of pid $pid"
        done
        v="$(_jvm_sysprop "$pid" whatap.home)"
        [ -n "$v" ] && _add_home "$v" "-Dwhatap.home of pid $pid"
        v="$(_jvm_sysprop "$pid" whatap.config.file)"
        [ -n "$v" ] && _add_home "$(dirname "$v" 2>/dev/null)" "-Dwhatap.config.file of pid $pid"
        v="$(_proc_env "$pid" WHATAP_CONFIG_FILE)"
        [ -n "$v" ] && _add_home "$(dirname "$v" 2>/dev/null)" "env WHATAP_CONFIG_FILE of pid $pid"
        v="$(_proc_env "$pid" WHATAP_HOME)"
        [ -n "$v" ] && _add_home "$v" "env WHATAP_HOME of pid $pid"
        v="$(_proc_env "$pid" WHATAP_JAVA_AGENT_PATH)"
        if [ -n "$v" ]; then
            _add_jar "$v" "env WHATAP_JAVA_AGENT_PATH of pid $pid"
            _add_home "$(dirname "$v" 2>/dev/null)" "directory of WHATAP_JAVA_AGENT_PATH of pid $pid"
        fi
    done

    # collector shell environment
    [ -n "${WHATAP_HOME:-}" ] && _add_home "$WHATAP_HOME" "env WHATAP_HOME (collector shell)"
    [ -n "${WHATAP_CONFIG_FILE:-}" ] && _add_home "$(dirname "$WHATAP_CONFIG_FILE" 2>/dev/null)" "env WHATAP_CONFIG_FILE (collector shell)"

    # operator auto-injection volume (whatap-operator mounts the agent here)
    [ -e /whatap-agent/whatap.agent.java.jar ] && _add_jar /whatap-agent/whatap.agent.java.jar "operator injection volume /whatap-agent"
    [ -d /whatap-agent ] && _add_home /whatap-agent "operator injection volume /whatap-agent"

    # java binaries on PATH, JAVA_HOME, and common install roots (shallow globs)
    for v in java jsvc; do
        exe="$(command -v "$v" 2>/dev/null)"
        [ -n "$exe" ] && _add_java "$exe"
    done
    [ -n "${JAVA_HOME:-}" ] && _add_java "$JAVA_HOME/bin/java"
    for exe in /usr/lib/jvm/*/bin/java /usr/java/*/bin/java /opt/java*/bin/java /opt/jdk*/bin/java; do
        [ -x "$exe" ] && _add_java "$exe"
    done
}

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    # Without an agent on disk and a config to read, nothing downstream can be
    # settled remotely. Both are resolved just before emit_status, where the
    # discovery variables are final.
    goal agent "whatap agent artifacts on disk"
    goal conf  "agent configuration"

    # [1] capability preamble: every downstream "command not found" is
    # pre-explained here.
    section "Collection environment"
    if [ -n "${BASH_VERSION:-}" ]; then fact "shell: bash $BASH_VERSION"
    else fact "shell: POSIX sh (non-bash)"; fi
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in java jstack jcmd jps unzip sha256sum ss netstat lsof readlink timeout stat awk tr; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present (%s)\n' "$t" "$(command -v "$t")"
        else printf '        %-12s absent\n' "$t"; fi
    done
    fact "Tier 2 flags: --threads=$OPT_THREADS  --jcmd=$OPT_JCMD (0 = not requested)"
    fact "library detail flags: --library=${OPT_LIBS:-none}  --library-all=$OPT_LIBALL  --class=${OPT_CLASSES:-none}"

    _PATHSINK="${_errfile}.paths"
    : > "$_PATHSINK" 2>/dev/null
    _APPSINK="${_errfile}.approots"
    : > "$_APPSINK" 2>/dev/null

    discover

    # [2] A. host / platform
    section "A. Host / platform"
    probe "kernel" uname -srm
    read_proc "os-release" /etc/os-release
    probe "cpu count (nproc)" nproc
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable|SwapTotal)' /proc/meminfo 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    read_proc "loadavg" /proc/loadavg
    # the JVM sizes its heap and CPU-derived pools from these limits
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        fact "cgroup: v2 (unified)"
        read_proc "cgroup memory.max" /sys/fs/cgroup/memory.max
        read_proc "cgroup cpu.max" /sys/fs/cgroup/cpu.max
    elif [ -d /sys/fs/cgroup/memory ]; then
        fact "cgroup: v1"
        read_proc "cgroup memory.limit_in_bytes" /sys/fs/cgroup/memory/memory.limit_in_bytes
        read_proc "cgroup cpu cfs_quota_us" /sys/fs/cgroup/cpu/cpu.cfs_quota_us
        read_proc "cgroup cpu cfs_period_us" /sys/fs/cgroup/cpu/cpu.cfs_period_us
    else
        fact "cgroup: n/a (path not found: /sys/fs/cgroup)"
    fi
    fact "container markers:"
    for m in /.dockerenv /run/.containerenv; do
        if [ -e "$m" ]; then printf '        %-22s present\n' "$m"; else printf '        %-22s absent\n' "$m"; fi
    done
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        printf '        %-22s %s\n' "KUBERNETES_SERVICE_HOST" "$KUBERNETES_SERVICE_HOST"
    else
        printf '        %-22s not set\n' "KUBERNETES_SERVICE_HOST"
    fi
    probe "self cgroup (first 5 lines)" sh -c "head -n 5 /proc/self/cgroup"
    probe "pid 1 command" sh -c "tr '\0' ' ' < /proc/1/cmdline | cut -c1-160"
    # clock: transaction timestamps and server-side correlation depend on it
    probe "local time" date
    probe "UTC time" date -u
    probe "timedatectl" timedatectl

    # [3] B. Java runtimes present on this host
    section "B. Java runtimes discovered"
    if [ -z "$D_JAVA_EXES" ]; then
        fact "java binaries: none found among running processes, PATH, JAVA_HOME, /usr/lib/jvm"
    fi
    fact "env JAVA_HOME (collector shell): ${JAVA_HOME:-not set}"
    _jc=0
    for jv in $D_JAVA_EXES; do
        _jc=$((_jc + 1))
        if [ "$_jc" -gt 6 ]; then
            fact "-- more java binaries found but not detailed (cap: 6)"
            break
        fi
        fact "-- java binary: $jv"
        fact "   resolves to: $(readlink -f "$jv" 2>/dev/null || echo "$jv")"
        # the release file is free; -version starts a separate short-lived JVM
        _rel="$(dirname "$(dirname "$(readlink -f "$jv" 2>/dev/null || echo "$jv")")")/release"
        if [ -r "$_rel" ]; then
            fact "   $_rel:"
            grep -E '^(JAVA_VERSION|IMPLEMENTOR|JAVA_VERSION_DATE|OS_ARCH)=' "$_rel" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "   release file: n/a (path not found: $_rel)"
        fi
        jvprobe "   version (separate short-lived JVM)" "$jv" -version
    done

    # [4] C. WhaTap Java agent artifacts on disk
    section "C. WhaTap agent artifacts on disk"
    if [ -z "$D_AGENT_JARS" ]; then
        fact "whatap agent jars: none discovered (no -javaagent, no WHATAP_JAVA_AGENT_PATH, no /whatap-agent)"
    else
        fact "whatap agent jars discovered (read as files; never loaded or executed):"
        printf '%s\n' "$D_AGENT_JARS" | while IFS='|' read -r p src; do
            [ -n "$p" ] || continue
            printf '        -- %s   <- %s\n' "$p" "$src"
            fsp="$(resolve_fs "$p")"
            if [ -z "$fsp" ]; then printf '           n/a (path not visible from this mount namespace)\n'; continue; fi
            [ "$fsp" != "$p" ] && printf '           filesystem view: %s (read through a process root)\n' "$fsp"
            printf '           resolves to: %s\n' "$(readlink -f "$fsp" 2>/dev/null || echo "$fsp")"
            file_facts "           " "$fsp"
            jar_version "           " "$fsp"
        done
    fi
    # the helper CLI (whatap.javahelper) ships beside the agent and its output
    # is quoted in weaving cases, so its presence and build are facts too
    if [ -z "$D_AGENT_JARS" ]; then
        fact "companion files next to an agent jar: n/a (no agent jar discovered)"
    else
        _comp="$(printf '%s\n' "$D_AGENT_JARS" | cut -d'|' -f1 | sort -u | while IFS= read -r p; do
            [ -n "$p" ] || continue
            d="$(dirname "$p" 2>/dev/null)"
            fsd="$(resolve_fs "$d")"
            [ -n "$fsd" ] || continue
            ls "$fsd" 2>/dev/null | grep -i -E 'helper|whatap' | grep -v -F "$(basename "$p")" \
                | head -n 20 | while IFS= read -r _l; do printf '%s/%s\n' "$fsd" "$_l"; done
        done)"
        if [ -n "$_comp" ]; then
            fact "companion files next to an agent jar (javahelper and other whatap files):"
            printf '%s\n' "$_comp" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "companion files next to an agent jar (javahelper and other whatap files): none present"
        fi
    fi

    # [5] D. JVM processes and how the agent is attached
    section "D. JVM processes and agent attachment"
    _n="$(echo $D_JVM_PIDS | wc -w | tr -d ' ')"
    _nm="$(echo $D_MARKED | wc -w | tr -d ' ')"
    # what an empty result rests on: the walk that produced it and the tests
    # applied to each entry, so the reader can tell "no JVM is running here"
    # from "the walk could not see one"
    fact "/proc walk: $D_PROC_SCANNED numeric pid entries scanned, $D_PROC_SKIPPED skipped (cmdline unreadable)"
    fact "tests applied to each, in order: /proc/<pid>/comm; resolved /proc/<pid>/exe; a JVM-only whole argument in /proc/<pid>/cmdline; a libjvm.so or libj9vm*.so mapping in /proc/<pid>/maps"
    if [ "${_n:-0}" -eq 0 ]; then
        fact "JVM processes: none found in /proc (this pid namespace)"
    else
        fact "JVM processes found: $_n ($_nm carrying a WhaTap attach marker; those are listed first, detailing first 20)"
        _shown=0
        for pid in $D_JVM_PIDS; do
            _shown=$((_shown + 1))
            [ "$_shown" -gt 20 ] && { fact "-- remaining $((_n - 20)) JVM processes not detailed (cap: 20)"; break; }
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           detected as a JVM by: %s\n' "$(printf '%s\n' "$D_JVM_WHY" | awk -F'|' -v p="$pid" '$1==p{sub(/^[^|]*\|/,""); print; exit}')"
            printf '           comm: %s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           exe: %s\n' "$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            printf '           uid/state/threads: %s\n' "$(awk '/^Uid:/{u=$2} /^State:/{s=$2} /^Threads:/{t=$2} END{print u" / "s" / "t}' "/proc/$pid/status" 2>/dev/null)"
            printf '           VmRSS: %s\n' "$(awk '/^VmRSS:/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"
            printf '           start time (ps): %s\n' "$(ps -o lstart= -p "$pid" 2>/dev/null | head -n1)"
            printf '           cwd: %s\n' "$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            # where the boot banner and any SIGQUIT dump land
            printf '           stdout (fd 1) -> %s\n' "$(readlink "/proc/$pid/fd/1" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            printf '           stderr (fd 2) -> %s\n' "$(readlink "/proc/$pid/fd/2" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            printf '           cmdline (verbatim):\n'
            tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            # a JVM the mapping test found holds no options in /proc; state
            # whether they were read back from the VM, and with which command
            case " $D_JVM_NOARGS " in
                *" $pid "*)
                    case " $_JCMD_RECOVERED " in
                        *" $pid "*)
                            printf '           JVM options are absent from /proc/%s/cmdline; the sections below read them from the VM via jcmd VM.command_line and jcmd VM.system_properties (--jcmd): %s lines recovered\n' \
                                "$pid" "$(grep -c . "${_errfile}.jcmdargs.$pid" 2>/dev/null)" ;;
                        *)
                            if [ "$OPT_JCMD" = 0 ]; then
                                printf '           JVM options are absent from /proc/%s/cmdline; --jcmd was not passed, so the VM was not asked for them and the sections below read only what /proc holds\n' "$pid"
                            else
                                printf '           JVM options are absent from /proc/%s/cmdline; --jcmd was passed and the recovery returned nothing (jcmd absent, attach refused, or the cap of 4 such processes reached)\n' "$pid"
                            fi ;;
                    esac ;;
            esac
            # every -javaagent reaching this JVM, from all four argument sources
            _ja="$(_all_jvm_args "$pid" 2>/dev/null | grep -c '^-javaagent:')"
            printf '           -javaagent options reaching this JVM: %s\n' "${_ja:-0}"
            _all_jvm_args "$pid" 2>/dev/null | grep '^-javaagent:' | while IFS= read -r _l; do
                _jp="$(printf '%s' "$_l" | sed 's/^-javaagent://; s/=.*$//')"
                if [ -e "$_jp" ]; then _ex="file present"; else _ex="file not found at this path"; fi
                printf '             %s   (%s)\n' "$_l" "$_ex"
            done
            for _ev in JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS JAVA_OPTS CATALINA_OPTS JAVA_OPTIONS; do
                _v="$(_proc_env "$pid" "$_ev")"
                if [ -n "$_v" ]; then printf '           env %s=%s\n' "$_ev" "$(printf '%s' "$_v" | cut -c1-400)"; fi
            done
            # server type markers — the same properties the agent's own
            # ProcessTypeDetector reads to name the process type
            _smk=0
            printf '           server markers:\n'
            for _sp in catalina.base catalina.home catalina.useNaming jboss.home.dir jboss.server.name jboss.server.base.dir jetty.base jetty.home jeus.home weblogic.Name domain.home com.sun.aas.instanceRoot com.sun.aas.installRoot com.sun.aas.instanceName com.sun.aas.domainName was.install.root server.root java.protocol.handler.pkgs spring.profiles.active; do
                _v="$(_jvm_sysprop "$pid" "$_sp")"
                if [ -n "$_v" ]; then _smk=$((_smk + 1)); printf '             -D%s=%s\n' "$_sp" "$(printf '%s' "$_v" | cut -c1-200)"; fi
            done
            if _all_jvm_args "$pid" 2>/dev/null | grep -qi 'org.springframework.boot.loader'; then
                _smk=$((_smk + 1)); printf '             spring boot loader on the arguments: yes\n'
            fi
            [ "$_smk" = 0 ] && printf '             none of the known server properties are set on this JVM\n'
            # program identity: the option values (-cp, -jar, --module-path …)
            # are skipped so a classpath is never reported as a main class
            _jarv="$(_all_jvm_args "$pid" 2>/dev/null | awk 'p=="-jar"{print; exit} {p=$0}')"
            # a launcher's own argv is not a java command line, so nothing on
            # it is read as a program; what the VM itself recorded is printed
            case " $D_JVM_NOARGS " in
                *" $pid "*)
                    _jc="$(cat "${_errfile}.jcmdmain.$pid" 2>/dev/null)"
                    if [ -n "$_jc" ]; then
                        printf '           program: java_command recorded by the VM: %s\n' "$(printf '%s' "$_jc" | cut -c1-200)"
                    else
                        printf '           program: n/a (the command line above belongs to the launcher, not to a JVM; the VM was not asked for its java_command)\n'
                    fi
                    continue ;;
            esac
            if [ -n "$_jarv" ]; then
                printf '           program: executable jar %s\n' "$_jarv"
            else
                _mc="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk '
                    NR==1 {p=$0; next}
                    (p=="-cp"||p=="-classpath"||p=="--class-path"||p=="-p"||p=="--module-path"||p=="-jar"||p=="-m"||p=="--module"||p=="--add-opens"||p=="--add-exports") {p=$0; next}
                    substr($0,1,1)=="-" {p=$0; next}
                    {print; exit}')"
                printf '           program: main class %s\n' "$(printf '%s' "${_mc:-n/a (no main class on the command line)}" | cut -c1-200)"
            fi
        done
    fi

    # [6] E. Agent home resolution and configuration
    section "E. Agent home resolution and configuration"
    fact "resolution the agent performs (whatap.agent.Configure.getPropertyFile):"
    fact "  env WHATAP_CONFIG_FILE  >  -Dwhatap.config.file  >  -Dwhatap.home + -Dwhatap.config (default \"whatap.conf\")"
    fact "  when -Dwhatap.home is absent the agent sets it itself to the directory of its own jar before reading the file (whatap.agent.boot.AgentBoot, JarUtil.getJarLocation); Configure's literal default \".\" is reached only when no -javaagent jar location is known"
    fact "  values in the file are then overlaid with environment variables and system properties (whatap.lang.conf.ConfigValueUtil.replaceSysProp); env names may contain dots"
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "per-process resolution: n/a (no JVM carrying a WhaTap attach marker)"
    fi
    for pid in $D_MARKED; do
        fact "-- pid $pid"
        _cf="$(_proc_env "$pid" WHATAP_CONFIG_FILE)"; _src="env WHATAP_CONFIG_FILE"
        if [ -z "$_cf" ]; then _cf="$(_jvm_sysprop "$pid" whatap.config.file)"; _src="-Dwhatap.config.file"; fi
        if [ -z "$_cf" ]; then
            _hm="$(_jvm_sysprop "$pid" whatap.home)"; _src="-Dwhatap.home"
            if [ -z "$_hm" ]; then
                _aj="$(_all_jvm_args "$pid" 2>/dev/null | grep -i '^-javaagent:.*whatap' | head -n1 | sed 's/^-javaagent://; s/=.*$//')"
                if [ -n "$_aj" ]; then _hm="$(dirname "$_aj" 2>/dev/null)"; _src="directory of the -javaagent jar (whatap.home unset; the agent sets it from its jar location, AgentBoot)"
                else _hm="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"; _src="process working directory (whatap.home unset and no -javaagent jar path known, default \".\")"; fi
            fi
            _cn="$(_jvm_sysprop "$pid" whatap.config)"
            [ -z "$_cn" ] && _cn="whatap.conf"
            _cf="$_hm/$_cn"
        else
            _hm="$(dirname "$_cf" 2>/dev/null)"
        fi
        fact "   config path resolved by this collector: $_cf   <- $_src"
        fact "   home used for the artifacts below: $_hm"
        _fsh="$(resolve_fs "$_hm")"
        _fsc="$(resolve_fs "$_cf")"
        if [ -n "$_fsc" ]; then
            [ "$_fsc" != "$_cf" ] && fact "   filesystem view: $_fsc (read through a process root)"
            dump_file "   whatap.conf (verbatim)" "$_fsc" 400
            conf_bytes "   whatap.conf byte facts" "$_fsc"
        else
            fact "   whatap.conf: n/a (path not found: $_cf)"
        fi
        # whatap-related environment of THIS process, verbatim
        if [ -r "/proc/$pid/environ" ]; then
            _wenv="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                | grep -iE '^(WHATAP|whatap\.|license=|accesskey=|OKIND=|PODNAME=|POD_NAME=|NODE_NAME=|NODE_IP=)' \
                | cut -c1-400)"
            if [ -n "$_wenv" ]; then
                fact "   whatap-related environment variables of this process:"
                printf '%s\n' "$_wenv" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            else
                fact "   whatap-related environment variables of this process: none set"
            fi
            # whatap.env is a properties blob applied on top of everything else
            _we="$(_proc_env "$pid" whatap.env)"
            if [ -n "$_we" ]; then fact "   env whatap.env (properties text applied over the config): $(printf '%s' "$_we" | cut -c1-400)"; fi
        else
            fact "   environ: n/a (permission denied: /proc/$pid/environ)"
        fi
        _wsp="$(_all_jvm_args "$pid" 2>/dev/null | grep -i '^-Dwhatap' | cut -c1-300)"
        if [ -n "$_wsp" ]; then
            fact "   whatap system properties on the arguments of this process:"
            printf '%s\n' "$_wsp" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
        else
            fact "   whatap system properties on the arguments of this process: none set"
        fi
        # other files the agent reads or writes in its home
        if [ -n "$_fsh" ]; then
            probe "   home listing" sh -c "ls -la '$_fsh' 2>/dev/null | head -n 60"
            for _sf in security.conf paramkey.txt; do
                if [ -f "$_fsh/$_sf" ]; then
                    fact "   $_sf: present, $(wc -c < "$_fsh/$_sf" 2>/dev/null | tr -d ' ') bytes (content not collected — SQL-parameter encryption key)"
                else
                    fact "   $_sf: absent"
                fi
            done
            _ccp="$(_proc_env "$pid" WHATAP_CONTAINER_CONF_PATH)"
            [ -n "$_ccp" ] && fact "   env WHATAP_CONTAINER_CONF_PATH: $_ccp"
            dump_file "   container.conf (container id written by the k8s node agent)" "${_ccp:-$_fsh}/container.conf" 40
        else
            fact "   home listing: n/a (path not visible from this mount namespace: $_hm)"
        fi
    done
    if [ -n "$D_HOMES" ]; then
        fact "all agent home candidates discovered (union of every source):"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _s; do printf '        %s   <- %s\n' "$_p" "$_s"; done
    fi

    # [7] F. Application libraries visible to the target JVMs
    section "F. Application libraries visible to the target JVMs"
    fact "the -javaagent jar is excluded from every list below: it bundles the agent's weaving-module markers, which a scan that includes it reports instead of the application's own libraries"
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "n/a (no JVM carrying a WhaTap attach marker)"
    fi
    _pc=0
    for pid in $D_MARKED; do
        _pc=$((_pc + 1))
        [ "$_pc" -gt 4 ] && { fact "-- remaining attached JVMs not detailed in this section (cap: 4)"; break; }
        fact "-- pid $pid"
        _LIBSINK="${_errfile}.libs.$pid"
        : > "$_LIBSINK" 2>/dev/null
        # 1) explicit classpath given to this JVM
        _cp="$(_all_jvm_args "$pid" 2>/dev/null | awk 'p=="-cp"||p=="-classpath"{print; exit} {p=$0}')"
        [ -z "$_cp" ] && _cp="$(_jvm_sysprop "$pid" java.class.path)"
        if [ -n "$_cp" ]; then
            _cpn="$(printf '%s' "$_cp" | tr ':' '\n' | grep -c .)"
            fact "   -cp / -classpath entries: $_cpn (first 120, agent jar excluded)"
            printf '%s' "$_cp" | tr ':' '\n' | grep -v -i 'whatap.agent' | head -n 120 | while IFS= read -r _l; do
                [ -n "$_l" ] || continue
                printf '             %s\n' "$_l"
                _lib_record "${_l##*/}"
                _fsl="$(resolve_rel "$pid" "$_l")"
                case "$_l" in /*) ;; *)
                    if [ -n "$_fsl" ]; then printf '               relative entry, resolved through the working directory of pid %s: %s\n' "$pid" "$_fsl"
                    else printf '               relative entry, not readable through the working directory of pid %s\n' "$pid"; fi ;;
                esac
                case "$_l" in
                    *.jar) _path_record "file|${_fsl:-$_l}" ;;
                    *)     [ -n "$_fsl" ] && [ -d "$_fsl" ] && _appclass_record "dir|$_fsl" ;;
                esac
            done
        else
            fact "   -cp / -classpath: not set on this JVM"
        fi
        _cpe="$(_proc_env "$pid" CLASSPATH)"
        [ -n "$_cpe" ] && fact "   env CLASSPATH: $(printf '%s' "$_cpe" | cut -c1-400)"
        # 2) executable jar (Spring Boot fat jar carries its libraries inside)
        _jar="$(_all_jvm_args "$pid" 2>/dev/null | awk 'p=="-jar"{print; exit} {p=$0}')"
        if [ -n "$_jar" ]; then
            fact "   executable jar: $_jar"
            _fsj="$(resolve_rel "$pid" "$_jar")"
            if [ -n "$_fsj" ]; then
                case "$_jar" in /*) ;; *) fact "     relative path, resolved through the working directory of pid $pid: $_fsj" ;; esac
                bootjar_facts "             " "$_fsj"
                _appclass_record "archive|$_fsj"
                fact "   libraries packed inside that jar:"
                jar_entries "             " "$_fsj" 'BOOT-INF/lib/*' 200
                jar_entries "             " "$_fsj" 'WEB-INF/lib/*' 200
            else
                fact "     n/a (path not readable here: an absolute path is tried in this mount namespace and through /proc/$pid/root, a relative one through /proc/$pid/cwd)"
            fi
        else
            fact "   executable jar (-jar): not set on this JVM"
        fi
        # 3) the working directory of this JVM. A process started with neither
        #    -cp nor -jar loads from its own working directory (the default
        #    class path is "."), which is how an extracted application layout
        #    runs, so the working directory is a class root candidate on its
        #    own. Section D reports the same directory.
        _cwd="$(cwd_view "$pid")"
        if [ -n "$_cwd" ]; then
            fact "   working directory of this JVM: $_cwd"
            _cwdn=0
            for _sub in BOOT-INF/classes WEB-INF/classes classes; do
                if [ -d "$_cwd/$_sub" ]; then
                    fact "     $_sub is present under it"
                    _appclass_record "dir|$_cwd/$_sub"
                    _cwdn=$((_cwdn + 1))
                fi
            done
            if [ -n "$(find "$_cwd" -maxdepth 1 -name '*.class' -type f 2>/dev/null | head -n 1)" ]; then
                fact "     class files are present directly under it"
                _appclass_record "dir|$_cwd"
                _cwdn=$((_cwdn + 1))
            fi
            [ "$_cwdn" = 0 ] && fact "     no BOOT-INF/classes, WEB-INF/classes, classes directory or top-level class file under it"
        else
            fact "   working directory of this JVM: n/a (permission denied or gone)"
        fi
        # 4) server deploy and lib directories derived from this JVM's own -D
        _cb="$(_jvm_sysprop "$pid" catalina.base)"; _ch="$(_jvm_sysprop "$pid" catalina.home)"
        _jb="$(_jvm_sysprop "$pid" jboss.home.dir)"; _jsb="$(_jvm_sysprop "$pid" jboss.server.base.dir)"
        _je="$(_jvm_sysprop "$pid" jeus.home)"; _dh="$(_jvm_sysprop "$pid" domain.home)"
        # GlassFish / Payara name the instance directory with com.sun.aas.instanceRoot;
        # its deployments are expanded under <instanceRoot>/applications/<app>/
        _gr="$(_jvm_sysprop "$pid" com.sun.aas.instanceRoot)"
        # WebLogic names the server with -Dweblogic.Name and starts it in the
        # domain directory; -Ddomain.home is not set by the stock start
        # scripts. The domain is therefore read from the process working
        # directory and from the DOMAIN_HOME variable of the process, and the
        # deployment staging area is servers/<weblogic.Name>/tmp/_WL_user/.
        _wn="$(_jvm_sysprop "$pid" weblogic.Name)"
        if [ -n "$_wn" ]; then
            _wdh=""
            for _cand in "$(_proc_env "$pid" DOMAIN_HOME)" "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"; do
                [ -n "$_cand" ] || continue
                _fsc="$(resolve_fs "$_cand")"
                [ -n "$_fsc" ] && [ -d "$_fsc/servers/$_wn" ] && { _wdh="$_cand"; break; }
            done
            if [ -n "$_wdh" ]; then
                _fsd="$(resolve_fs "$_wdh")"
                fact "   weblogic domain directory (weblogic.Name=$_wn; from DOMAIN_HOME or the process working directory): $_wdh"
                [ -d "$_fsd/lib" ] && list_jars "             " "$_fsd/lib" 60
                _wst="$_fsd/servers/$_wn/tmp/_WL_user"
                if [ -d "$_wst" ]; then
                    probe "     staging directory servers/$_wn/tmp/_WL_user (deployment units)" sh -c "ls '$_wst' 2>/dev/null | head -n 60"
                    if [ -n "$_timeout_bin" ]; then
                        "$_timeout_bin" "$CMD_TIMEOUT" find "$_wst" -maxdepth 7 -type d -path '*/WEB-INF/classes' 2>/dev/null | head -n 12 > "${_errfile}.wl" 2>/dev/null
                    else
                        find "$_wst" -maxdepth 7 -type d -path '*/WEB-INF/classes' 2>/dev/null | head -n 12 > "${_errfile}.wl" 2>/dev/null
                    fi
                    if [ -s "${_errfile}.wl" ]; then
                        fact "     WEB-INF/classes directories under the staging area (depth 7, first 12):"
                        while IFS= read -r _w; do
                            [ -n "$_w" ] || continue
                            printf '             %s\n' "$_w"
                            _appclass_record "dir|$_w"
                            [ -d "${_w%/classes}/lib" ] && list_jars "               " "${_w%/classes}/lib" 120
                        done < "${_errfile}.wl"
                    else
                        fact "     WEB-INF/classes directories under the staging area (depth 7): none found"
                    fi
                else
                    fact "     staging directory servers/$_wn/tmp/_WL_user: absent"
                fi
                # the deployment sources config.xml names (archives or exploded dirs)
                if [ -r "$_fsd/config/config.xml" ]; then
                    _wsp="$(grep -o '<source-path>[^<]*</source-path>' "$_fsd/config/config.xml" 2>/dev/null | sed 's/<source-path>//; s/<\/source-path>//' | sort -u | head -n 40)"
                    if [ -n "$_wsp" ]; then
                        fact "     deployment source paths in config/config.xml (<source-path>, first 40):"
                        printf '%s\n' "$_wsp" | while IFS= read -r _sp1; do
                            [ -n "$_sp1" ] || continue
                            case "$_sp1" in /*) _spa="$_sp1" ;; *) _spa="$_fsd/$_sp1" ;; esac
                            if [ -d "$_spa/WEB-INF/classes" ]; then
                                printf '             %s   (exploded, WEB-INF/classes present)\n' "$_sp1"; _appclass_record "dir|$_spa/WEB-INF/classes"
                            elif [ -f "$_spa" ]; then
                                printf '             %s   (archive, read in place)\n' "$_sp1"; _appclass_record "archive|$_spa"
                            elif [ -d "$_spa" ]; then
                                printf '             %s   (directory)\n' "$_sp1"
                            else
                                printf '             %s   (path not found from here)\n' "$_sp1"
                            fi
                        done
                    else
                        fact "     deployment source paths in config/config.xml: none"
                    fi
                else
                    fact "     config/config.xml: n/a (not readable at $_wdh/config/config.xml)"
                fi
            else
                fact "   weblogic domain directory (weblogic.Name=$_wn): n/a (neither DOMAIN_HOME nor the process working directory holds servers/$_wn)"
            fi
        fi
        # catalina.base and catalina.home are one directory in a single-instance
        # install and two in a split install; list each distinct path once
        _seen_d=""
        for _d in "$_cb" "$_ch"; do
            [ -n "$_d" ] || continue
            case "$_seen_d" in *"|$_d|"*) continue ;; esac
            _seen_d="$_seen_d|$_d|"
            _fsd="$(resolve_fs "$_d")"
            [ -n "$_fsd" ] || { fact "   server directory (catalina): $_d — n/a (path not visible from this mount namespace)"; continue; }
            fact "   server directory (catalina): $_d"
            list_jars "             " "$_fsd/lib" 120
            # the appBase of an instance is whatever server.xml says it is;
            # <instance>/webapps is only the shipped default, so both are read
            _abs="$(printf '%s\n' "$_fsd/webapps"; tomcat_app_bases "$_fsd")"
            _abs="$(printf '%s\n' "$_abs" | grep . | sort -u)"
            printf '%s\n' "$_abs" | while IFS= read -r _ab; do
                [ -n "$_ab" ] && webapp_roots "             " "$_ab" 120
            done
            # a context can point its docBase outside every appBase
            printf '%s\n' "$_abs" > "${_errfile}.abs" 2>/dev/null
            _dbs="$(tomcat_doc_bases "$_fsd" "${_errfile}.abs" | sort -u)"
            if [ -n "$_dbs" ]; then
                printf '%s\n' "$_dbs" | while IFS= read -r _db; do
                    [ -n "$_db" ] || continue
                    if [ -d "$_db/WEB-INF/classes" ]; then
                        fact "         docBase $_db (WEB-INF/classes present)"
                        _appclass_record "dir|$_db/WEB-INF/classes"
                    elif [ -f "$_db" ]; then
                        fact "         docBase $_db (archive, read in place)"
                        _appclass_record "archive|$_db"
                    else
                        fact "         docBase $_db: no WEB-INF/classes under it"
                    fi
                    [ -d "$_db/WEB-INF/lib" ] && list_jars "               " "$_db/WEB-INF/lib" 120
                done
            else
                fact "         docBase entries in server.xml or conf/<engine>/<host>/*.xml: none"
            fi
        done
        _seen_t=""
        for _d in "$(_jvm_sysprop "$pid" jetty.base)" "$(_jvm_sysprop "$pid" jetty.home)"; do
            [ -n "$_d" ] || continue
            case "$_seen_t" in *"|$_d|"*) continue ;; esac
            _seen_t="$_seen_t|$_d|"
            _fsd="$(resolve_fs "$_d")"
            [ -n "$_fsd" ] || { fact "   server directory (jetty): $_d — n/a (path not readable here)"; continue; }
            fact "   server directory (jetty): $_d"
            list_jars "             " "$_fsd/lib" 120
            webapp_roots "             " "$_fsd/webapps" 120 "webapps directory"
        done
        if [ -n "$_jb" ]; then
            fact "   server directory (jboss.home.dir): $_jb"
            _fsd="$(resolve_fs "$_jb")"
            if [ -n "$_fsd" ]; then
                list_jars "             " "$_fsd/lib" 60
                for _dd in "$_fsd"/server/*/deploy "$_fsd"/server/*/lib "$_fsd"/standalone/deployments; do
                    [ -d "$_dd" ] && list_deploy "             " "$_dd"
                done
            else
                fact "     n/a (path not visible from this mount namespace)"
            fi
        fi
        if [ -n "$_jsb" ]; then
            _fsd="$(resolve_fs "$_jsb")"
            [ -n "$_fsd" ] && { fact "   server base directory (jboss.server.base.dir): $_jsb"; list_deploy "             " "$_fsd/deployments"; }
        fi
        for _d in "$_je" "$_dh" "$_gr"; do
            [ -n "$_d" ] || continue
            _fsd="$(resolve_fs "$_d")"
            [ -n "$_fsd" ] || continue
            fact "   server directory: $_d"
            probe "     listing" sh -c "ls '$_fsd' 2>/dev/null | head -n 40"
            [ -d "$_fsd/lib" ] && list_jars "             " "$_fsd/lib" 60
            [ -d "$_fsd/applications" ] && probe "     applications directory listing" sh -c "ls '$_fsd/applications' 2>/dev/null | head -n 40"
            # these products compose the staging path of a deployment at
            # runtime, so the class roots are found by searching for them
            # rather than by naming a layout
            if [ -n "$_timeout_bin" ]; then
                "$_timeout_bin" "$CMD_TIMEOUT" find "$_fsd" -maxdepth 10 -type d -path '*/WEB-INF/classes' 2>/dev/null | head -n 12 > "${_errfile}.wi" 2>/dev/null
            else
                find "$_fsd" -maxdepth 10 -type d -path '*/WEB-INF/classes' 2>/dev/null | head -n 12 > "${_errfile}.wi" 2>/dev/null
            fi
            if [ -s "${_errfile}.wi" ]; then
                fact "     WEB-INF/classes directories under it (depth 10, first 12):"
                while IFS= read -r _w; do
                    [ -n "$_w" ] || continue
                    printf '             %s\n' "$_w"
                    _appclass_record "dir|$_w"
                done < "${_errfile}.wi"
            else
                fact "     WEB-INF/classes directories under it (depth 10): none found"
            fi
        done
        # 4) open jar files held by the process — covers layouts none of the
        #    above describe (custom launchers, exploded frameworks)
        if [ -r "/proc/$pid/fd" ]; then
            _oj="$(ls -l "/proc/$pid/fd" 2>/dev/null | grep -i '\.jar$' | awk '{print $NF}' | grep -v -i 'whatap.agent')"
            _ojn="$(printf '%s\n' "$_oj" | grep -c .)"
            fact "   jar files currently open by this process: ${_ojn:-0} (first 120, agent jar excluded)"
            printf '%s\n' "$_oj" | head -n 120 | while IFS= read -r _l; do
                [ -n "$_l" ] || continue
                printf '             %s\n' "$_l"
                _lib_record "${_l##*/}"
                _path_record "file|$_l"
            done
        else
            fact "   open jar files: n/a (permission denied: /proc/$pid/fd)"
        fi
        _LIBSINK=""
    done

    # [8] G. Agent instrumentation surface and weaving activation
    # The most frequent Java case is "the agent is installed but the hitmap
    # stays empty". Reading it needs four facts side by side: what the
    # application carries (section F), what THIS agent build can instrument
    # (the bundled catalog below — read from the installed jar, so it matches
    # the deployed version exactly), which modules the configuration selects,
    # and which modules the process actually loaded (the agent log lines).
    section "G. Agent instrumentation surface and weaving activation"
    fact "the lists below come from the installed agent jar itself, so they describe the deployed version; read them against the application libraries in section F"
    if [ -z "$D_AGENT_JARS" ]; then
        fact "bundled instrumentation: n/a (no agent jar discovered)"
    else
        printf '%s\n' "$D_AGENT_JARS" | cut -d'|' -f1 | sort -u | while IFS= read -r p; do
            [ -n "$p" ] || continue
            fsp="$(resolve_fs "$p")"
            [ -n "$fsp" ] || { fact "-- agent jar $p: n/a (path not visible from this mount namespace)"; continue; }
            fact "-- agent jar: $p"
            # weaving modules the jar carries; WeaveMain loads them from the
            # jar resource /weaving/<name>.jar for each name in the weaving list
            fact "   weaving modules bundled in this jar (loaded on demand from the weaving list):"
            jar_entries "             " "$fsp" 'weaving/*' 200
            # built-in bytecode instrumentation classes present in this build
            fact "   built-in instrumentation classes in this jar (whatap/agent/asm):"
            jar_entries "             " "$fsp" 'whatap/agent/asm/*ASM.class' 150
        done
    fi
    # a jar dropped into <home>/weaving is loaded whole-directory, independent
    # of the weaving list (WeaveMain.load -> listup)
    if [ -z "$D_HOMES" ]; then
        fact "on-disk weaving plugin directories: n/a (no agent home discovered)"
    else
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            fshome="$(resolve_fs "$home")"
            [ -n "$fshome" ] || continue
            if [ -d "$fshome/weaving" ]; then
                fact "-- on-disk plugin directory $home/weaving (every jar here is loaded while weaving_plugin_enabled is true, independent of the weaving list):"
                list_jars "             " "$fshome/weaving" 120
            fi
            # script plugins (<name>.x, compiled by the agent's PluginLoadThread,
            # re-read when the file's mtime changes) live in <home>/plugin
            if [ -d "$fshome/plugin" ]; then
                _pxl="$(ls -l "$fshome/plugin" 2>/dev/null | grep '\.x$')"
                _pxn="$(printf '%s\n' "$_pxl" | grep -c .)"
                fact "-- script plugin directory $home/plugin: ${_pxn:-0} .x file(s) (size, mtime, name as ls -l prints them):"
                if [ "${_pxn:-0}" -gt 0 ]; then
                    printf '%s\n' "$_pxl" | head -n 40 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                else
                    printf '             (directory present, no .x file)\n'
                fi
            else
                fact "-- script plugin directory $home/plugin: absent"
            fi
        done
    fi
    # which modules the configuration selects — the lines are selected from the
    # config file dumped verbatim in section E, kept here next to the catalog
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "instrumentation settings in force: n/a (no JVM carrying a WhaTap attach marker)"
    fi
    for pid in $D_MARKED; do
        _cf2="$(_proc_env "$pid" WHATAP_CONFIG_FILE)"
        [ -z "$_cf2" ] && _cf2="$(_jvm_sysprop "$pid" whatap.config.file)"
        if [ -z "$_cf2" ]; then
            _hm2="$(_jvm_sysprop "$pid" whatap.home)"
            if [ -z "$_hm2" ]; then
                _aj2="$(_all_jvm_args "$pid" 2>/dev/null | grep -i '^-javaagent:.*whatap' | head -n1 | sed 's/^-javaagent://; s/=.*$//')"
                if [ -n "$_aj2" ]; then _hm2="$(dirname "$_aj2" 2>/dev/null)"; else _hm2="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"; fi
            fi
            _cn2="$(_jvm_sysprop "$pid" whatap.config)"
            [ -z "$_cn2" ] && _cn2="whatap.conf"
            _cf2="$_hm2/$_cn2"
        fi
        _fsc2="$(resolve_fs "$_cf2")"
        if [ -z "$_fsc2" ] || [ ! -r "$_fsc2" ]; then
            fact "-- pid $pid instrumentation settings: n/a (config file not readable: $_cf2)"
        else
            _wk="$(grep -nE '^[[:space:]]*(weaving|weaving_reserved|weaving_[A-Za-z0-9_]*|hook_service_[A-Za-z_]*|hook_method_[A-Za-z_]*|hook_component|instrumentation_[A-Za-z0-9_]*|_enable_asm_[a-z]*|_enable_emb_[a-z]*|trace_component_enabled|bci_ignore_packages)[[:space:]]*=' "$_fsc2" 2>/dev/null | head -n 60)"
            if [ -n "$_wk" ]; then
                fact "-- pid $pid instrumentation settings (selected from the config file shown in section E, with line numbers):"
                printf '%s\n' "$_wk" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            else
                fact "-- pid $pid instrumentation settings: no weaving / hook / instrumentation key set in $_cf2"
            fi
        fi
        _wenvp="$(_all_jvm_args "$pid" 2>/dev/null | grep -iE '^-D(weaving|hook_|instrumentation_)' | cut -c1-300)"
        [ -n "$_wenvp" ] && printf '%s\n' "$_wenvp" | while IFS= read -r _l; do printf '             (argument) %s\n' "$_l"; done
        # each name in the weaving list is loaded from the jar resource
        # weaving/<name>.jar — state per name whether that entry exists in the
        # jar attached to THIS process (the same check the report already makes
        # for a -javaagent path)
        _wlist=""
        [ -n "$_fsc2" ] && [ -r "$_fsc2" ] && _wlist="$(grep -aE '^[[:space:]]*(weaving|weaving_reserved)[[:space:]]*=' "$_fsc2" 2>/dev/null | head -n 2 | sed 's/^[^=]*=//' | tr ',' '\n' | tr -d ' \r')"
        if [ -n "$_wlist" ]; then
            _pjar="$(_all_jvm_args "$pid" 2>/dev/null | grep -i '^-javaagent:.*whatap' | head -n1 | sed 's/^-javaagent://; s/=.*$//')"
            _fspj="$(resolve_fs "$_pjar")"
            if [ -z "$_fspj" ] || ! have unzip; then
                fact "   weaving list entries vs the jar of this process: n/a (agent jar not readable here, or command not found: unzip)"
            else
                _cat="${_errfile}.weav.$pid"
                if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$CMD_TIMEOUT" unzip -Z1 "$_fspj" 'weaving/*' > "$_cat" 2>/dev/null
                else unzip -Z1 "$_fspj" 'weaving/*' > "$_cat" 2>/dev/null; fi
                fact "   weaving list entries vs the modules bundled in $_pjar:"
                printf '%s\n' "$_wlist" | while IFS= read -r _m; do
                    [ -n "$_m" ] || continue
                    if grep -qxF "weaving/$_m.jar" "$_cat" 2>/dev/null; then
                        printf '             %-40s bundled in this jar\n' "$_m"
                    else
                        printf '             %-40s no weaving/%s.jar entry in this jar\n' "$_m" "$_m"
                    fi
                done
                rm -f "$_cat" 2>/dev/null
            fi
        fi
    done
    # what actually loaded in the running process: the agent writes one
    # "Weaving" line per module it loads, and a Warning/Error line when a
    # module's compiled class version is above the target class version
    if [ -z "$D_HOMES" ]; then
        fact "weaving activity in the agent log: n/a (no agent home discovered)"
    else
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            fshome="$(resolve_fs "$home")"
            [ -n "$fshome" ] || continue
            weaving_lines "$home/logs/whatap.log" "$fshome/logs/whatap.log"
            # after a rotation the module load lines sit in the previous file
            _rot2="$(ls -t "$fshome"/logs/whatap-*.log 2>/dev/null | head -n 1)"
            [ -n "$_rot2" ] && weaving_lines "$(basename "$_rot2") (most recent rotated log)" "$_rot2"
        done
    fi

    # [9] H. Application logging stack
    section "H. Application logging stack"
    _lgp=0
    fact "logging framework configuration properties on the attached JVMs:"
    for pid in $D_MARKED; do
        for _lp in logback.configurationFile logback.statusListenerClass log4j.configuration log4j.configurationFile log4j2.configurationFile java.util.logging.config.file java.util.logging.manager org.jboss.logging.provider; do
            _v="$(_jvm_sysprop "$pid" "$_lp")"
            if [ -n "$_v" ]; then _lgp=$((_lgp + 1)); printf '        pid %s  -D%s=%s\n' "$pid" "$_lp" "$_v"; fi
        done
    done
    [ "$_lgp" = 0 ] && fact "    none of the known logging properties are set on the attached JVMs"
    # filtered from the library inventory of section F (classpath entries, jar
    # contents, server lib directories and open jar files), so a library that
    # is present but not yet opened is still reported
    fact "logging framework libraries in the section F inventory:"
    for pid in $D_MARKED; do
        _lf="${_errfile}.libs.$pid"
        if [ ! -s "$_lf" ]; then printf '        pid %s: n/a (no libraries enumerated in section F)\n' "$pid"; continue; fi
        _lgj="$(grep -i -E 'logback|log4j|slf4j|commons-logging|jboss-logging|logstash|tinylog|jcl-over|jul-to' "$_lf" 2>/dev/null | sort -u | head -n 40)"
        if [ -n "$_lgj" ]; then
            printf '%s\n' "$_lgj" | while IFS= read -r _l; do printf '        pid %s  %s\n' "$pid" "$_l"; done
        else
            printf '        pid %s: no logging framework library among %s enumerated entries\n' "$pid" "$(grep -c . "$_lf" 2>/dev/null)"
        fi
    done
    _lgc=0
    fact "logging configuration files in the working directory of each attached JVM (one level):"
    for pid in $D_MARKED; do
        _cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        [ -n "$_cwd" ] || continue
        _lgf="$(ls "$_cwd" 2>/dev/null | grep -i -E '^(logback|log4j|log4j2|logging)[^/]*\.(xml|properties|yaml|yml|json)$' | head -n 10)"
        if [ -n "$_lgf" ]; then
            _lgc=$((_lgc + 1))
            printf '%s\n' "$_lgf" | while IFS= read -r _l; do printf '        pid %s  %s/%s\n' "$pid" "$_cwd" "$_l"; done
        fi
    done
    [ "$_lgc" = 0 ] && fact "    none present in any attached JVM working directory"
    # console destination and on-disk server logs: the collected volume and the
    # on-disk volume can differ, and both are facts a reader compares
    fact "console destination and server log files of each attached JVM:"
    for pid in $D_MARKED; do
        printf '        pid %s stdout -> %s\n' "$pid" "$(readlink "/proc/$pid/fd/1" 2>/dev/null || echo 'n/a (permission denied or gone)')"
        _cb="$(_jvm_sysprop "$pid" catalina.base)"
        _jsb="$(_jvm_sysprop "$pid" jboss.server.base.dir)"
        _cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null)"
        for _ld in "$_cb/logs" "$_jsb/log" "$_cwd/logs" "$_cwd/log"; do
            case "$_ld" in /logs|/log) continue ;; esac
            _fsl="$(resolve_fs "$_ld")"
            [ -n "$_fsl" ] || continue
            [ -d "$_fsl" ] || continue
            printf '        pid %s log dir %s (newest 15 by name):\n' "$pid" "$_ld"
            ls -la "$_fsl" 2>/dev/null | tail -n 15 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
        done
    done

    # [10] I. WhaTap agent logs
    section "I. WhaTap agent logs"
    # default log_root is <whatap.home>/logs, log_name "whatap"; the live file
    # is <log_name>.log and rotation renames it to <log_name>-YYYYMMDD.log
    if [ -z "$D_HOMES" ]; then
        fact "no agent home discovered; no log locations to read"
    else
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            fshome="$(resolve_fs "$home")"
            [ -n "$fshome" ] || continue
            [ -d "$fshome/logs" ] || continue
            fact "-- log dir: $home/logs"
            probe "   listing" sh -c "ls -la '$fshome/logs' 2>/dev/null | head -n 60"
            # the live log opens with the agent banner: "WhaTap Java v<version>"
            head_file "   whatap.log (first lines: banner and version)" "$fshome/logs/whatap.log" 40
            tail_file "   whatap.log (recent lines)" "$fshome/logs/whatap.log" 200
            _rot="$(ls -t "$fshome"/logs/whatap-*.log 2>/dev/null | head -n 1)"
            if [ -n "$_rot" ]; then
                tail_file "   $(basename "$_rot") (most recent rotated log, recent lines)" "$_rot" 120
            else
                fact "   rotated logs (whatap-YYYYMMDD.log): none present"
            fi
            if [ -r "$fshome/logs/whatap.log" ]; then
                fact "   [WA*] codes in the last 500 lines of whatap.log:"
                tail -n 500 "$fshome/logs/whatap.log" 2>/dev/null | grep -oE '\[WA[0-9A-Za-z-]*\]' | sort | uniq -c | sort -rn | head -n 20 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            fi
        done
    fi

    # [11] J. Network endpoints
    section "J. Network endpoints"
    # the agent opens an outbound TCP session to whatap.server.host:port
    # (default port 6600); the configured value is in section E
    fact "whatap.server.host / whatap.server.port reaching each attached JVM through env or -D:"
    for pid in $D_MARKED; do
        for _k in whatap.server.host whatap.server.port WHATAP_SERVER_HOST WHATAP_SERVER_PORT; do
            _v="$(_proc_env "$pid" "$_k")"
            [ -n "$_v" ] && printf '        pid %s  env %s=%s\n' "$pid" "$_k" "$_v"
            _v="$(_jvm_sysprop "$pid" "$_k")"
            [ -n "$_v" ] && printf '        pid %s  -D%s=%s\n' "$pid" "$_k" "$_v"
        done
    done
    if have ss; then
        probe "tcp sessions of the attached JVMs and port 6600" sh -c "ss -tnp 2>/dev/null | awk 'NR==1 || /java/ || /:6600/' | head -n 60"
    elif have netstat; then
        probe "tcp sessions of the attached JVMs and port 6600" sh -c "netstat -tnp 2>/dev/null | awk 'NR<=2 || /java/ || /:6600/' | head -n 60"
    else
        fact "socket listing: n/a (command not found: ss, netstat); raw table follows"
        probe "raw /proc/net/tcp (first 30 lines, ports in hex; 0x19C8=6600)" sh -c "head -n 30 /proc/net/tcp"
    fi
    read_proc "/etc/resolv.conf" /etc/resolv.conf
    fact "proxy variables in the collector shell: ${http_proxy:+http_proxy=$http_proxy }${https_proxy:+https_proxy=$https_proxy }${no_proxy:+no_proxy=$no_proxy}"

    # [12] K. Kubernetes / operator injection context
    section "K. Kubernetes / operator injection context"
    # the operator injects -javaagent:/whatap-agent/whatap.agent.java.jar through
    # JAVA_TOOL_OPTIONS and sets WHATAP_JAVA_AGENT_PATH plus the connection env
    if [ -d /whatap-agent ]; then
        probe "/whatap-agent listing (operator injection volume)" sh -c "ls -la /whatap-agent 2>/dev/null | head -n 40"
    else
        fact "/whatap-agent: n/a (path not found — operator injection volume absent)"
    fi
    fact "env WHATAP_JAVA_AGENT_PATH (collector shell): ${WHATAP_JAVA_AGENT_PATH:-not set}"
    fact "env JAVA_TOOL_OPTIONS (collector shell): ${JAVA_TOOL_OPTIONS:-not set}"
    for v in POD_NAME PODNAME NODE_NAME NODE_IP OKIND WHATAP_MICRO_ENABLED; do
        eval "_val=\${$v:-}"
        if [ -n "$_val" ]; then fact "env $v: $_val"; else fact "env $v: not set"; fi
    done
    [ -d /var/run/secrets/kubernetes.io ] && fact "/var/run/secrets/kubernetes.io: present" || fact "/var/run/secrets/kubernetes.io: absent"
    read_proc "container hostname (/etc/hostname)" /etc/hostname

    # [13] L. Tier 2 — only when explicitly requested
    section "L. Tier 2 artifacts (opt-in)"
    if [ "$OPT_THREADS" = 0 ] && [ "$OPT_JCMD" = 0 ] && [ -z "$OPT_DUMPS" ]; then
        fact "not requested (--threads / --jcmd / --dump-file absent); no attach, signal, or pause was applied to any JVM"
    fi
    _TDUMPS=0
    : > "${_errfile}.tframes" 2>/dev/null
    if [ "$OPT_THREADS" != 0 ] 2>/dev/null; then
        _tn="$OPT_THREADS"
        [ "$_tn" -ge 1 ] 2>/dev/null || _tn=1
        _tp=0
        for pid in $D_MARKED; do
            _tp=$((_tp + 1))
            [ "$_tp" -gt 3 ] && { fact "-- remaining attached JVMs not dumped (cap: 3)"; break; }
            warn "[Tier2] thread dump: pid $pid x$_tn — pauses the target JVM at a safepoint for each dump"
            _k=1
            while [ "$_k" -le "$_tn" ]; do
                _td="${_errfile}.tdump"
                if have jstack; then
                    if [ -n "$_timeout_bin" ]; then "$_timeout_bin" 60 jstack -l "$pid" > "$_td" 2>&1
                    else jstack -l "$pid" > "$_td" 2>&1; fi
                    fact "-- thread dump pid $pid ($_k/$_tn) via jstack -l (first 5000 lines):"
                    head -n 5000 "$_td" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                    cat "$_td" >> "${_errfile}.tframes" 2>/dev/null
                    _TDUMPS=$((_TDUMPS + 1))
                elif have jcmd; then
                    if [ -n "$_timeout_bin" ]; then "$_timeout_bin" 60 jcmd "$pid" Thread.print -l > "$_td" 2>&1
                    else jcmd "$pid" Thread.print -l > "$_td" 2>&1; fi
                    fact "-- thread dump pid $pid ($_k/$_tn) via jcmd Thread.print -l (first 5000 lines):"
                    head -n 5000 "$_td" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                    cat "$_td" >> "${_errfile}.tframes" 2>/dev/null
                    _TDUMPS=$((_TDUMPS + 1))
                else
                    warn "[Tier2] jstack and jcmd absent: sending SIGQUIT to pid $pid — the dump goes to that process's stdout"
                    kill -3 "$pid" 2>/dev/null
                    fact "-- thread dump pid $pid ($_k/$_tn): jstack and jcmd absent; SIGQUIT sent, output goes to the process stdout shown in section D"
                fi
                [ "$_k" -lt "$_tn" ] && sleep 2
                _k=$((_k + 1))
            done
        done
        [ "$_tp" = 0 ] && fact "thread dumps: n/a (no JVM carrying a WhaTap attach marker)"
    fi
    # Dump files taken elsewhere enter the same counts. No JVM is contacted;
    # the file is read as it is, and which JVM produced it is whatever the
    # reader knows about the file.
    # one path per line: a dump file name may carry spaces (console downloads do)
    while IFS= read -r _df; do
        [ -n "$_df" ] || continue
        if [ ! -e "$_df" ]; then fact "-- supplied dump file $_df: n/a (path not found)"; continue; fi
        if [ ! -r "$_df" ]; then fact "-- supplied dump file $_df: n/a (permission denied)"; continue; fi
        _dfl="$(grep -c . "$_df" 2>/dev/null)"; _dfh="$(grep -c '^"' "$_df" 2>/dev/null)"
        fact "-- supplied dump file $_df: ${_dfl:-0} non-empty lines, ${_dfh:-0} thread header lines; first line: $(head -n 1 "$_df" 2>/dev/null | cut -c1-120)"
        fact "   read as supplied (--dump-file); not taken by this collector"
        cat "$_df" >> "${_errfile}.tframes" 2>/dev/null
        _TDUMPS=$((_TDUMPS + 1))
    done <<EOF_DUMPS
$OPT_DUMPS
EOF_DUMPS
    if [ "${_TDUMPS:-0}" -gt 0 ]; then
        # Frame frequency over the dumps above. A transaction entry point
        # that no weaving module covers is read off the frames that recur in
        # every dump, and counting them by hand across N dumps is the step the
        # field repeats on every such case. The three buckets are defined by
        # the package prefixes printed with them; no frame is filtered away.
        if [ -s "${_errfile}.tframes" ]; then
            grep -E '^[[:space:]]*at ' "${_errfile}.tframes" 2>/dev/null \
                | sed 's/^[[:space:]]*at //; s/(.*$//' \
                | sort | uniq -c | sort -rn > "${_errfile}.tfreq" 2>/dev/null
            _fq_n="$(grep -c . "${_errfile}.tfreq" 2>/dev/null)"
            fact "-- stack frame frequency over the $_TDUMPS dump(s) above: ${_fq_n:-0} distinct frames"
            fact "   counted from the 'at <class>.<method>' lines of every thread, at any stack depth"
            fact "   bucket 1 of 3 — JDK and JVM-vendor frames (package starts with java. javax. jakarta. sun. jdk. com.sun. oracle. org.graalvm.), top 20:"
            grep -E '[0-9]+ (java|javax|jakarta|sun|jdk|com\.sun|oracle|org\.graalvm)\.' "${_errfile}.tfreq" 2>/dev/null | head -n 20 > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (no frame in this bucket)\n'; fi
            fact "   bucket 2 of 3 — WhaTap agent frames (package starts with whatap.), top 20:"
            grep -E '[0-9]+ whatap\.' "${_errfile}.tfreq" 2>/dev/null | head -n 20 > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (no frame in this bucket)\n'; fi
            fact "   bucket 3 of 3 — every remaining frame, top 80:"
            grep -vE '[0-9]+ (java|javax|jakarta|sun|jdk|com\.sun|oracle|org\.graalvm|whatap)\.' "${_errfile}.tfreq" 2>/dev/null | head -n 80 > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (no frame in this bucket)\n'; fi
            # Thread-level counts. On an idle JVM the frames carry no application
            # class at all, while the thread NAMES still do (cache regions named
            # after entity classes, a scheduler instance id, a pool prefix), so
            # the names are counted separately from the frames.
            grep '^"' "${_errfile}.tframes" 2>/dev/null | sed 's/^"\([^"]*\)".*$/\1/' > "${_errfile}.tnames" 2>/dev/null
            _thn="$(grep -c . "${_errfile}.tnames" 2>/dev/null)"
            fact "-- thread header lines over the $_TDUMPS dump(s): ${_thn:-0}"
            fact "   thread states (java.lang.Thread.State lines, counted):"
            grep -oE 'java\.lang\.Thread\.State: [A-Z_]+' "${_errfile}.tframes" 2>/dev/null | sed 's/^java.lang.Thread.State: //' | sort | uniq -c | sort -rn > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (no state line in the dump text)\n'; fi
            fact "   thread name shapes, every digit run replaced by N so pool members collapse into one line (names that are themselves a dotted class-like name are counted in the next block instead), top 40:"
            sed 's/[0-9][0-9]*/N/g' "${_errfile}.tnames" 2>/dev/null | grep -vE '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_$][A-Za-z0-9_$]*){2,}$' | sort | uniq -c | sort -rn | head -n 40 > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (no thread header line in the dump text)\n'; fi
            grep -oE '[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_$][A-Za-z0-9_$]*){2,}' "${_errfile}.tnames" 2>/dev/null | sort | uniq -c | sort -rn > "${_errfile}.tdot" 2>/dev/null
            fact "   package roots of dotted names carried inside thread names (first three dot-separated parts, thread count):"
            awk '{ n=split($2, p, "."); if (n >= 3) print $1, p[1] "." p[2] "." p[3] }' "${_errfile}.tdot" 2>/dev/null | awk '{ c[$2]+=$1 } END { for (k in c) print c[k], k }' | sort -rn | head -n 20 > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (none)\n'; fi
            fact "   the dotted names themselves (three or more parts, as written), distinct, top 80:"
            head -n 80 "${_errfile}.tdot" > "${_errfile}.tb" 2>/dev/null
            if [ -s "${_errfile}.tb" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "${_errfile}.tb"; else printf '        (none)\n'; fi
            # Other APM agents on the same JVM show up as frames and threads of
            # their own packages. The prefix list is fixed and printed verbatim.
            # <frame package prefix>:<word looked for in thread names, case-insensitive>
            _OTHERAPM="oracle.apmaas.:apmaas com.dynatrace.:dynatrace com.appdynamics.:appdynamics com.newrelic.:newrelic io.opentelemetry.javaagent.:opentelemetry com.instana.:instana datadog.trace.:datadog scouter.:scouter com.jennifersoft.:jennifer com.ibm.tivoli.:tivoli co.elastic.apm.:elastic"
            fact "   frames and thread names of other APM agents on the same JVM (fixed list of frame-package prefix and thread-name word, printed here verbatim; an entry with no match is not listed):"
            fact "   $_OTHERAPM"
            _oam=0
            for _op in $_OTHERAPM; do
                _opp="${_op%%:*}"; _opw="${_op#*:}"
                _ope="$(printf '%s' "$_opp" | sed 's/\./\\./g')"
                _ofc="$(grep -E "^ *[0-9]+ ${_ope}" "${_errfile}.tfreq" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
                _otc="$(grep -c -i "$_opw" "${_errfile}.tnames" 2>/dev/null)"
                if [ "${_ofc:-0}" -gt 0 ] || [ "${_otc:-0}" -gt 0 ]; then
                    _oam=$((_oam + 1))
                    printf '        %s  frames=%s  thread names containing "%s" (case-insensitive)=%s\n' "$_opp" "${_ofc:-0}" "$_opw" "${_otc:-0}"
                fi
            done
            [ "$_oam" = 0 ] && printf '        (no frame or thread name under any listed prefix)\n'
        fi
    fi
    if [ "$OPT_JCMD" != 0 ]; then
        if ! have jcmd; then
            fact "jcmd data: n/a (command not found: jcmd)"
        else
            # A JVM whose options are not in /proc is queried here too, whether
            # or not it carries an attach marker: /proc showed nothing about
            # it, so this output is the only verbatim record of what it runs.
            _jp=0; _jseen=""
            for pid in $D_MARKED $D_JVM_NOARGS; do
                case "$_jseen" in *"|$pid|"*) continue ;; esac
                _jseen="$_jseen|$pid|"
                _jp=$((_jp + 1))
                [ "$_jp" -gt 3 ] && { fact "-- remaining JVMs not queried (cap: 3)"; break; }
                warn "[Tier2] jcmd: pid $pid — uses the JVM attach mechanism on the target process"
                probe "-- jcmd $pid VM.command_line" jcmd "$pid" VM.command_line
                probe "-- jcmd $pid VM.system_properties" jcmd "$pid" VM.system_properties
                probe "-- jcmd $pid VM.flags" jcmd "$pid" VM.flags
                probe "-- jcmd $pid VM.version" jcmd "$pid" VM.version
            done
            [ "$_jp" = 0 ] && fact "jcmd data: n/a (no JVM carrying a WhaTap attach marker, and none whose options are absent from /proc)"
        fi
    fi

    # [14] M. Library detail pack — only when explicitly requested
    # Writing a new weaving module needs more than a file name: the module is
    # compiled against the customer's own artifact, redeclares the target
    # class's fields and method signatures, and must not be compiled for a
    # class-file version above the target's. This section carries exactly
    # those inputs for the libraries named on the command line.
    section "M. Library detail pack (opt-in)"
    if [ "$OPT_LIBALL" = 0 ] && [ -z "$OPT_LIBS" ]; then
        fact "not requested (--library / --library-all absent)"
    elif [ ! -s "$_PATHSINK" ]; then
        fact "no locatable jar was enumerated in section F; nothing to detail"
    else
        [ -n "$OPT_LIBS" ] && fact "patterns requested:$OPT_LIBS"
        [ "$OPT_LIBALL" = 1 ] && fact "patterns requested: --library-all (every enumerated jar)"
        [ -n "$OPT_CLASSES" ] && fact "member signatures requested for:$OPT_CLASSES"
        _dn=0
        : > "${_errfile}.jarsha" 2>/dev/null
        _build_libroots
        if [ -s "$_LIBROOTS" ]; then
            fact "the class names of the jars section N indexes are not repeated in this section; their package histogram is left out and named as such"
        fi
        sort -u "$_PATHSINK" 2>/dev/null > "${_errfile}.paths.u" 2>/dev/null
        while IFS= read -r _rec; do
            [ -n "$_rec" ] || continue
            _kind="${_rec%%|*}"
            case "$_kind" in
                file)
                    _p="${_rec#file|}"
                    _lib_match "$_p" || continue
                    _fsp="$(resolve_fs "$_p")"
                    if [ -z "$_fsp" ]; then fact "-- $_p: n/a (path not visible from this mount namespace)"; continue; fi
                    # Several deployment units of one application carry the same
                    # jar. Detailing each copy spends the cap on identical
                    # content and hides the other units entirely (case
                    # 2026-09-17 FIF: all 40 came from one unit of two), so a
                    # byte-identical copy is named rather than detailed again.
                    _sh=""
                    if have sha256sum; then _sh="$(sha256sum "$_fsp" 2>/dev/null | cut -d' ' -f1)"
                    elif have shasum; then _sh="$(shasum -a 256 "$_fsp" 2>/dev/null | cut -d' ' -f1)"; fi
                    if [ -n "$_sh" ] && grep -q "^$_sh " "${_errfile}.jarsha" 2>/dev/null; then
                        fact "-- $(basename "$_p"): byte-identical copy of a jar already detailed above (sha256 $_sh); path: $_p"
                        continue
                    fi
                    [ -n "$_sh" ] && printf '%s %s\n' "$_sh" "$_p" >> "${_errfile}.jarsha" 2>/dev/null
                    _dn=$((_dn + 1))
                    [ "$_dn" -gt 40 ] && { fact "-- cap reached: 40 distinct jars detailed, later matches skipped"; break; }
                    if _in_libroots "$_p"; then _DJ_IN_INDEX=1; else _DJ_IN_INDEX=0; fi
                    detail_jar "$(basename "$_p")" "$_fsp"
                    _DJ_IN_INDEX=0
                    ;;
                nested)
                    _cj="${_rec#nested|}"; _ent="${_cj#*|}"; _cj="${_cj%%|*}"
                    _lib_match "$_ent" || continue
                    _dn=$((_dn + 1))
                    [ "$_dn" -gt 40 ] && { fact "-- cap reached: 40 jars detailed, later matches skipped"; break; }
                    _fsc="$(resolve_fs "$_cj")"
                    if [ -z "$_fsc" ]; then fact "-- $_ent: n/a (container jar not visible from this mount namespace: $_cj)"; continue; fi
                    _tmpj="$(nested_extract "$_fsc" "$_ent")"
                    if [ -z "$_tmpj" ]; then
                        fact "-- $_ent: n/a (packed inside $_cj; entry could not be read, or is above the 80 MB extraction bound)"
                        continue
                    fi
                    detail_jar "$(basename "$_ent")" "$_tmpj" "entry $_ent inside $_cj"
                    rm -f "$_tmpj" 2>/dev/null
                    ;;
            esac
        done < "${_errfile}.paths.u"
        [ "$_dn" = 0 ] && fact "no enumerated jar matched the requested patterns"
        # a class named with --class may be an application class of an
        # executable jar rather than a library class
        for _fq in $OPT_CLASSES; do
            _rel="$(printf '%s' "$_fq" | tr '.' '/').class"
            for pid in $D_MARKED; do
                _jarp="$(_all_jvm_args "$pid" 2>/dev/null | awk 'p=="-jar"{print; exit} {p=$0}')"
                [ -n "$_jarp" ] || continue
                _fsj2="$(resolve_fs "$_jarp")"
                [ -n "$_fsj2" ] || continue
                have unzip || continue
                unzip -Z1 "$_fsj2" "BOOT-INF/classes/$_rel" >/dev/null 2>&1 || continue
                fact "-- $_fq is an application class of $_jarp (BOOT-INF/classes)"
                if ! have javap; then
                    fact "   member signatures: n/a (command not found: javap)"
                    continue
                fi
                _cd="${_errfile}.cls"
                rm -rf "$_cd" 2>/dev/null; mkdir -p "$_cd" 2>/dev/null
                if unzip -o -q -d "$_cd" "$_fsj2" "BOOT-INF/classes/$_rel" 2>/dev/null; then
                    fact "   member signatures (javap -p -s, first 400 lines):"
                    if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$CMD_TIMEOUT" javap -p -s -classpath "$_cd/BOOT-INF/classes" "$_fq" 2>&1 | head -n 400 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                    else javap -p -s -classpath "$_cd/BOOT-INF/classes" "$_fq" 2>&1 | head -n 400 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done; fi
                else
                    fact "   member signatures: n/a (class entry could not be extracted)"
                fi
                rm -rf "$_cd" 2>/dev/null
            done
        done
    fi

    # [15] N. Application class index — only when explicitly requested
    # Attaching a transaction to an application that no weaving module covers
    # starts from one question: which classes are the application's own? The
    # customer's source is frequently out of reach for procurement or security
    # reasons, and the deployed artifact answers the same question. Section F
    # inventories the LIBRARIES; this section inventories the classes the
    # application itself ships, from the same roots the JVM loads them from.
    section "N. Application class index (opt-in)"
    # The jars named with --library are read into this index too. An
    # application can ship its own code as jars inside WEB-INF/lib rather than
    # as class files under WEB-INF/classes; which of several hundred jars are
    # the application's own is the reader's call, and --library is where the
    # reader states it. Nothing is inferred from a jar name here.
    _APPPAT="Controller Action Servlet Handler Endpoint Resource Service Facade Manager Delegate Listener Consumer Processor Job Task Batch Adapter Gateway"
    if [ "$OPT_APPCLASSES" = 0 ]; then
        fact "not requested (--appclasses absent)"
    else
        # jars named with --library join the roots below
        [ -n "$_LIBROOTS" ] || _build_libroots
        if [ -n "$OPT_LIBS" ] || [ "$OPT_LIBALL" = 1 ]; then
            _lrn="$(grep -c . "$_LIBROOTS" 2>/dev/null)"
            fact "-- jars named with --library that join this index: ${_lrn:-0} (cap 60). Naming them is the reader's statement that they carry the application's own code; this collector does not judge a jar by its name"
        fi
        if [ ! -s "$_APPSINK" ] && [ ! -s "$_LIBROOTS" ]; then
            fact "requested, but section F enumerated no application class root (no directory classpath entry, no WEB-INF/classes, no BOOT-INF/classes) and no jar was named with --library. Section F states, per JVM, what its -cp, its -jar, its working directory and its server directories yielded"
        else
        fact "-- names are reported as the JVM loads them: a BOOT-INF/classes or WEB-INF/classes segment at the head of a path inside a root is a layout artifact, not part of the class name, and is not printed"
        { sort -u "$_APPSINK" 2>/dev/null; head -n 60 "$_LIBROOTS" 2>/dev/null; } > "${_errfile}.approots.u" 2>/dev/null
        _NAMES="${_errfile}.appnames"
        : > "$_NAMES" 2>/dev/null
        _rn=0
        while IFS= read -r _rec; do
            [ -n "$_rec" ] || continue
            _rn=$((_rn + 1))
            _rcap=12; [ -s "$_LIBROOTS" ] && _rcap=72
            [ "$_rn" -gt "$_rcap" ] && { fact "-- cap reached: $_rcap class roots read, later roots skipped"; break; }
            case "$_rec" in
                dir\|*)
                    _rt="${_rec#dir|}"
                    if [ ! -d "$_rt" ]; then fact "-- directory root $_rt: n/a (path not found)"; continue; fi
                    if [ ! -r "$_rt" ]; then fact "-- directory root $_rt: n/a (permission denied)"; continue; fi
                    _cnt="$(find "$_rt" -name '*.class' -type f 2>/dev/null | head -n 20000 | grep -c .)"
                    fact "-- directory root $_rt: ${_cnt:-0} class files (read bound: 20000)"
                    # A deployment unit can ship the application's own code as
                    # jars next to this directory rather than as class files in
                    # it. When the directory holds nothing, the count of the
                    # sibling lib directory is the fact that says where else to
                    # look; --library <name> then details those jars (section M).
                    if [ "${_cnt:-0}" -eq 0 ]; then
                        _sib="${_rt%/classes}/lib"
                        if [ -d "$_sib" ]; then
                            _sibn="$(ls "$_sib" 2>/dev/null | grep -i -c '\.jar$')"
                            fact "   sibling ${_sib}: ${_sibn:-0} jar files (this root contributed no class name; section F lists them and --library <name> details the ones you name)"
                        else
                            fact "   sibling ${_sib}: absent"
                        fi
                    fi
                    find "$_rt" -name '*.class' -type f 2>/dev/null | head -n 20000 | while IFS= read -r _cf; do
                        _fq="${_cf#"$_rt"/}"; _fq="${_fq%.class}"
                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_NAMES" 2>/dev/null
                    done
                    ;;
                libjar\|*)
                    _rt="${_rec#libjar|}"
                    _fsl="$(resolve_fs "$_rt")"
                    if [ -z "$_fsl" ]; then fact "-- named jar $_rt: n/a (path not visible from this mount namespace)"; continue; fi
                    if ! have unzip; then fact "-- named jar $_rt: n/a (command not found: unzip)"; continue; fi
                    if [ -n "$_timeout_bin" ]; then _lst="$("$_timeout_bin" "$CMD_TIMEOUT" unzip -Z1 "$_fsl" '*.class' 2>/dev/null)"
                    else _lst="$(unzip -Z1 "$_fsl" '*.class' 2>/dev/null)"; fi
                    _lst="$(printf '%s\n' "$_lst" | grep -v '^META-INF/versions/')"
                    _cnt="$(printf '%s\n' "$_lst" | grep -c .)"
                    fact "-- named jar $(basename "$_rt"): ${_cnt:-0} class entries (named with --library)"
                    printf '%s\n' "$_lst" | head -n 20000 | while IFS= read -r _ce; do
                        [ -n "$_ce" ] || continue
                        _fq="${_ce%.class}"
                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_NAMES" 2>/dev/null
                    done
                    ;;
                archive\|*)
                    _rt="${_rec#archive|}"
                    if [ ! -f "$_rt" ]; then fact "-- archive root $_rt: n/a (path not found)"; continue; fi
                    if ! have unzip; then fact "-- archive root $_rt: n/a (command not found: unzip)"; continue; fi
                    if [ -n "$_timeout_bin" ]; then _lst="$("$_timeout_bin" "$CMD_TIMEOUT" unzip -Z1 "$_rt" 'WEB-INF/classes/*.class' 'BOOT-INF/classes/*.class' 2>/dev/null)"
                    else _lst="$(unzip -Z1 "$_rt" 'WEB-INF/classes/*.class' 'BOOT-INF/classes/*.class' 2>/dev/null)"; fi
                    _cnt="$(printf '%s\n' "$_lst" | grep -c .)"
                    fact "-- archive root $_rt: ${_cnt:-0} class entries under WEB-INF/classes or BOOT-INF/classes (read bound: 20000)"
                    printf '%s\n' "$_lst" | head -n 20000 | while IFS= read -r _ce; do
                        [ -n "$_ce" ] || continue
                        _fq="${_ce#WEB-INF/classes/}"; _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq%.class}"
                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_NAMES" 2>/dev/null
                    done
                    ;;
            esac
        done < "${_errfile}.approots.u"
        if [ ! -s "$_NAMES" ]; then
            fact "no class file was read from the enumerated roots"
        else
            sort -u "$_NAMES" 2>/dev/null > "${_NAMES}.u" 2>/dev/null
            _tot="$(grep -c . "${_NAMES}.u" 2>/dev/null)"
            fact "-- distinct application classes: ${_tot:-0}"
            fact "-- package histogram, class count per package (top 40):"
            sed 's/\.[^.]*$//' "${_NAMES}.u" 2>/dev/null | sort | uniq -c | sort -rn | head -n 40 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            fact "-- name-pattern index. The patterns are a fixed list carried by this collector, printed here verbatim so the reader knows exactly what was matched and what was not:"
            fact "   $_APPPAT"
            for _p in $_APPPAT; do
                _mn="$(grep -E "(^|\.)[^.]*${_p}[^.]*$" "${_NAMES}.u" 2>/dev/null | grep -c .)"
                [ "${_mn:-0}" -eq 0 ] && continue
                fact "   *${_p}*: ${_mn} (first 60)"
                grep -E "(^|\.)[^.]*${_p}[^.]*$" "${_NAMES}.u" 2>/dev/null | head -n 60 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            done
            fact "-- classes matching none of those patterns: $(grep -vE "(^|\.)[^.]*($(printf '%s' "$_APPPAT" | tr ' ' '|'))[^.]*$" "${_NAMES}.u" 2>/dev/null | grep -c .)"
            fact "-- full class list (first 2000, alphabetical):"
            head -n 2000 "${_NAMES}.u" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            # --class-refs: which of these classes name a given type. A class
            # file carries every type it implements, extends, calls or
            # references as a UTF8 constant-pool entry in internal form, so the
            # scan is a byte search of the class files of the same roots. It
            # reports "names it", never "implements it".
            if [ -n "$OPT_REFS" ]; then
                _refdir="${_errfile}.refx"
                for _tk in $OPT_REFS; do
                    _tki="$(printf '%s' "$_tk" | tr '.' '/')"
                    _hits="${_errfile}.refhits"; : > "$_hits" 2>/dev/null
                    _rr=0
                    while IFS= read -r _rrec; do
                        [ -n "$_rrec" ] || continue
                        _rr=$((_rr + 1)); [ "$_rr" -gt 72 ] && break
                        case "$_rrec" in
                            dir\|*)
                                _rt="${_rrec#dir|}"
                                [ -d "$_rt" ] || continue
                                grep -rl -a --include='*.class' -- "$_tki" "$_rt" 2>/dev/null | head -n 400 \
                                  | while IFS= read -r _hf; do
                                        _fq="${_hf#"$_rt"/}"; _fq="${_fq%.class}"
                                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_hits" 2>/dev/null
                                    done
                                ;;
                            libjar\|*|archive\|*)
                                case "$_rrec" in libjar\|*) _rt="${_rrec#libjar|}" ;; *) _rt="${_rrec#archive|}" ;; esac
                                _fsr="$(resolve_fs "$_rt")"
                                [ -n "$_fsr" ] || continue
                                have unzip || continue
                                _sz="$(wc -c < "$_fsr" 2>/dev/null)"
                                if [ -n "$_sz" ] && [ "$_sz" -gt 83886080 ] 2>/dev/null; then
                                    fact "   $_rt: skipped for this scan (above the 80 MB unpack bound)"
                                    continue
                                fi
                                rm -rf "$_refdir" 2>/dev/null; mkdir -p "$_refdir" 2>/dev/null || continue
                                if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$CMD_TIMEOUT" unzip -qq -o -d "$_refdir" "$_fsr" '*.class' >/dev/null 2>&1
                                else unzip -qq -o -d "$_refdir" "$_fsr" '*.class' >/dev/null 2>&1; fi
                                grep -rl -a --include='*.class' -- "$_tki" "$_refdir" 2>/dev/null | head -n 400 \
                                  | while IFS= read -r _hf; do
                                        _fq="${_hf#"$_refdir"/}"; _fq="${_fq%.class}"
                                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_hits" 2>/dev/null
                                    done
                                rm -rf "$_refdir" 2>/dev/null
                                ;;
                        esac
                    done < "${_errfile}.approots.u"
                    sort -u "$_hits" 2>/dev/null > "${_hits}.u" 2>/dev/null
                    _hn="$(grep -c . "${_hits}.u" 2>/dev/null)"
                    fact "-- classes naming $_tk in their bytecode: ${_hn:-0} (searched for the internal form $_tki in the class files of the roots above; a class is listed whether it implements, extends, calls or only references the type)"
                    if [ "${_hn:-0}" -gt 0 ]; then
                        head -n 200 "${_hits}.u" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                    else
                        printf '        (no class of these roots carries the token)\n'
                    fi
                done
            fi
            # Join with section L: which classes of THIS index appear as frames in
            # the dumps counted there. A zero is a fact worth a line — it says the
            # dumps were taken while no application code was on any stack.
            if [ -s "${_errfile}.tfreq" ]; then
                awk 'NR==FNR { a[$0]=1; next } { c=$2; sub(/\.[^.]*$/, "", c); if (c in a) print }' "${_NAMES}.u" "${_errfile}.tfreq" > "${_errfile}.tjoin" 2>/dev/null
                _tjn="$(grep -c . "${_errfile}.tjoin" 2>/dev/null)"
                _tjs="$(awk '{s+=$1} END{print s+0}' "${_errfile}.tjoin" 2>/dev/null)"
                fact "-- frames in the section L dump(s) whose class is in this index: ${_tjn:-0} distinct frames, ${_tjs:-0} occurrences (top 60):"
                if [ "${_tjn:-0}" -gt 0 ]; then
                    head -n 60 "${_errfile}.tjoin" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                else
                    printf '        (no frame of any counted dump belongs to a class in this index)\n'
                fi
            else
                fact "-- frames in the section L dump(s) whose class is in this index: n/a (no thread dump was counted in this run: --threads and --dump-file absent, or no dump text)"
            fi
        fi
        fi
    fi

    # Resolved here, not at the point of use: the config dumps above run inside
    # `| while` pipelines, and an assignment made in a subshell does not survive.
    if [ -n "$D_HOMES" ] || [ -n "$D_AGENT_JARS" ]; then got agent
    else na agent "no whatap java agent is installed on this host (no jar or home on disk or in any JVM command line)"; fi
    _cseen=0
    for _h in $(printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u); do
        [ -n "$_h" ] || continue
        _fh="$(resolve_fs "$_h")"; [ -n "$_fh" ] || continue
        [ -r "$_fh/whatap.conf" ] && _cseen=1
    done
    if [ "$_cseen" = 1 ]; then got conf
    elif [ -z "$D_HOMES" ]; then na conf "no agent home exists to hold a whatap.conf"
    else missed conf "agent home discovered but no whatap.conf under it is readable by uid $(id -u 2>/dev/null || echo '?')$(_priv_hint)"; fi

    emit_status
    emit_footer
}

# ---- main — DO NOT EDIT --------------------------------------------------------
exec 3>&2

[ "$ARGC" -eq 0 ] && { usage; exit 0; }

if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_run_init
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
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
_end_probe
