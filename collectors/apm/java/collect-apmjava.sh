#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM Java agent collector
# -----------------------------------------------------------------------------
# Gathers the facts a remote WhaTap Java-agent developer repeatedly asks a
# field engineer for, from the host or container where the target JVM runs.
# Derived from the agent source (io.whatap.java/whatap.agent.tracer, v2.2.76)
# and the whatap-operator Java injector (internal/webhook/v2alpha1/
# injector_java.go). The support cases behind each part: README, "Cases".
#
# What the report answers with facts:
#   * Is a WhaTap -javaagent attached, and how many agents are on the JVM? The
#     option may come from the command line OR from JAVA_TOOL_OPTIONS /
#     _JAVA_OPTIONS / JDK_JAVA_OPTIONS (the operator injects it that way, so it
#     never appears in /proc/<pid>/cmdline); all four sources are read.
#   * Which agent jar and version: whatap/v.properties INSIDE the jar
#     (VERSION/BUILD), with its size/mtime/sha256 and the agent log banner as
#     independent cross-checks.
#   * Where the agent looks for its config: env WHATAP_CONFIG_FILE, else
#     -Dwhatap.config.file, else -Dwhatap.home (default ".", the process working
#     directory) plus -Dwhatap.config (default "whatap.conf"). Resolved per
#     process, and the file dumped verbatim.
#   * Which settings are in force: the agent overlays env and system properties
#     onto the config (whatap/lang/conf/ConfigValueUtil.replaceSysProp), so every
#     whatap-related env variable (names may carry dots: license,
#     whatap.server.host) and -D property is listed per process.
#   * What kind of Java process: the server markers the agent's own
#     ProcessTypeDetector reads (catalina.base, jboss.home.dir, jeus.home,
#     weblogic, websphere, the Spring Boot loader).
#   * "Installed and healthy, but the hitmap stays empty": four facts side by
#     side — what the application carries (F), what THIS agent build can
#     instrument (G: the weaving modules and ASM classes read from the installed
#     jar), which modules the configuration selects, and which the running
#     process loaded (the agent log's Weaving lines, class-version warnings
#     included).
#   * The application's own libraries: from its -cp/-classpath, -jar
#     (BOOT-INF/lib), CLASSPATH and the server deploy directories its -D
#     properties name. The -javaagent jar is EXCLUDED and the exclusion stated:
#     it bundles weaving-module markers, so a scan that includes it reports the
#     agent's catalog instead of the application's libraries.
#   * Where the JVM's stdout goes (/proc/<pid>/fd/1): the agent boot banner and
#     a SIGQUIT thread dump land there, not in the agent log.
#   * The logging framework in play, its config files and its output files.
#   * A JVM nothing names as java: a native launcher that creates the VM
#     in-process through JNI_CreateJavaVM (Axway API Gateway's vshell) has its
#     own comm and exe and passes the JVM options in memory. It is identified by
#     the VM library mapped into it (libjvm.so / libj9vm*.so), and --jcmd reads
#     its options back from the VM itself.
#   * Opt-in, read-only: --library (detail pack for writing a weaving module),
#     --appclasses (the application's own classes), --class-refs (which of them
#     name a type, from the constant pool: "names it", not "implements it"),
#     --dump-file (a thread dump taken elsewhere enters the same frame, thread
#     name, state and other-APM-agent counts, without touching any JVM).
#   * Tier 2, opt-in: thread dumps (--threads) and jcmd VM data (--jcmd).
#
# Sections: [1] environment, A host, B Java runtimes, C agent artifacts, D JVM
# processes and attachment, E home and config, F application libraries,
# G instrumentation, H logging, I agent logs, J network, K Kubernetes,
# L Tier 2, M library detail pack, N application class index; then status.
#
# Contract ../../../CONTRACT.md, guidelines ../../../docs/collector-engineering.md;
# no `set -e`, so the report reaches its footer when every probe fails.
# Tier 0 never attaches to, signals or pauses the target JVM: `-version` runs
# only on a discovered binary named java (a separate short-lived JVM), never on
# a running process or an embedding launcher. jstack / jcmd / SIGQUIT are
# Tier 2 and announce their impact before running. Tier-0 reads are bounded
# (directory listings, a depth-limited search for WEB-INF/classes, no
# whole-log grep); every external command runs under _bounded; bash 3.2+ and
# POSIX sh.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmjava"
# 0.12.6  Shared helpers moved into the apm group block; report unchanged.
#         The apm: blocks are copies of templates/groups/apm.sh.
VERSION="0.12.6"
DOMAIN="apm"
TARGET="host/$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"

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
progress()   { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }
have()       { command -v "$1" >/dev/null 2>&1; }
# ---- end emit helpers

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
# _report_to_file --file mode's write; fails when the file is not written whole.
# Constraints:
# - POSIX sh only (apm collectors run under `sh -s`, often dash or busybox):
#   no SECONDS, no `type -t`, no ${v//x/y} outside a BASH_VERSION guard.
# - A cap returns 124 whatever timeout(1) returns for a kill (busybox: 143).
#   timeout(1) gets -k where it takes it, so a command deaf to TERM still ends;
#   without timeout(1), or for a shell function, a watchdog that ends in KILL.
# - Past RUN_DEADLINE nothing runs (124), so the report still reaches its footer.
# - Each call is logged with its time; only the command name and a subcommand
#   word, never arguments (they can hold a path or a credential).
RUN_DEADLINE="${RUN_DEADLINE:-300}"
_tmp_dir=""
_timeout_bin=""   # timeout(1), found in _run_init; empty = watchdog only
_run_t0=""
_timeout_k=""     # 5 when timeout(1) takes -k (_run_init)
_load0=""         # _host_load at _run_init
SLOW_SEC=3        # a bounded call at least this long is named in the status
_stdin_script=0   # 1 when the shell reads this script from stdin (sh -s)
_nl='
'
_tab="$(printf '\t')"

# Falls back to stderr when fd 3 is not open yet (an error before main).
warn() { { printf '!! %s\n' "$*" >&3; } 2>/dev/null || printf '!! %s\n' "$*" >&2; }

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

# _run_init -> the private temp directory, the traps, and timeout(1). Call it
# once in main, before anything creates a temp file.
_run_init() {
    _run_t0="$(date +%s 2>/dev/null)"
    _owner_pid="$$"
    _load0="$(_host_load)"
    # 16+ digits: a date without %N prints bare seconds
    [ -z "${EPOCHREALTIME:-}" ] && case "$(date +%s%N 2>/dev/null)" in *[!0-9]*|'') ;; ????????????????*) _ms_date=1 ;; esac
    _now_ms; _run_ms0="$_ms"
    case "$_run_t0" in ''|*[!0-9]*) _run_t0="" ;; esac
    # no predictable fallback name: without mktemp, _tmp answers /dev/null
    _tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ggt.XXXXXX" 2>/dev/null)"
    # Script read from stdin (`sh -s`)? Then fd 0 is the script: a bounded
    # command must not read it, and bash 5.2 kills a $(...) that duplicates it.
    case "$0" in
        */*|*.sh) [ -f "$0" ] || _stdin_script=1 ;;
        *)        _stdin_script=1 ;;
    esac
    [ -n "$_tmp_dir" ] || warn "no private temp directory could be made under ${TMPDIR:-/tmp}; values that need one are reported as n/a"
    # caps from the environment: whole numbers or unused (0 = no limit to timeout(1))
    RUN_DEADLINE="$(_cap_or RUN_DEADLINE "$RUN_DEADLINE" 300)"
    CMD_TIMEOUT="$(_cap_or CMD_TIMEOUT "${CMD_TIMEOUT:-20}" 20)"
    trap '_run_cleanup' EXIT
    trap '_run_cleanup; exit 129' HUP
    trap '_run_cleanup; exit 130' INT
    trap '_run_cleanup; exit 143' TERM
    [ -n "${_timeout_bin:-}" ] || _timeout_bin="$(command -v timeout 2>/dev/null)"
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
# whole seconds. Milliseconds let many short calls add up to their real time.
_ms_date=0
_run_ms0=0
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
        ( i=0
          # background sleep + wait, so a TERM ends the watchdog at once
          while [ "$i" -lt "$t" ]; do sleep 1 & wait $!; kill -0 "$p" 2>/dev/null || exit 0; i=$((i + 1)); done
          kill -TERM -- "-$p" 2>/dev/null; _kill_tree TERM "$p"
          sleep 2
          kill -KILL -- "-$p" 2>/dev/null; _kill_tree KILL "$p" ) >/dev/null 2>&1 &
        w=$!
        wait "$p"; rc=$?
        # KILL: a TERM can arrive before dash resets the inherited traps and be lost
        kill -KILL "$w" 2>/dev/null; wait "$w" 2>/dev/null
    fi
    _now_ms; d=$((_ms - m0))
    case "$rc" in 124|137|143) [ "$((d / 1000))" -ge "$t" ] && rc=124 ;; esac
    if [ "$rc" = 124 ]; then
        if [ "$t" -lt "${CMD_TIMEOUT:-20}" ]; then w="cut at the deadline"; else w="capped at ${t}s"; fi
    else w="ran"; fi
    _time_log "$d" "$w" "$@"
    return "$rc"
}

_report_to_file() {
    # `true`, not `:`. A failed redirect on a special builtin exits dash.
    if ! { true > "$1"; } 2>/dev/null; then
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
notice() { printf '>> %s\n' "$*" >&3 2>/dev/null; }

# _emit_time -> the run time; when a call was slow (SLOW_SEC), capped or not
# run, also the host load at start and end and where the time went (bounded
# calls summed per command, largest first, and the time outside them).
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
    fact "where the time went (every bounded call, summed per command, largest first):"
    _now_ms
    LC_ALL=C awk -F'\t' -v run="$((_ms - _run_ms0))" '
        $2 == "not run" { nr[$3]++; next }
        { ms[$3] += $1; n[$3]++; tot += $1; if ($2 != "ran") { o[$3, $2]++; if (!(($3, $2) in seen)) { seen[$3, $2] = 1; ol[$3] = ol[$3] SUBSEP $2 } } }
        END {
            for (k in ms) {
                x = ""; m = split(substr(ol[k], 2), L, SUBSEP)
                for (i = 1; i <= m; i++) x = x ", " o[k, L[i]] " " L[i]
                printf "%d\t%6.1fs  %s%s%s\n", ms[k], ms[k] / 1000, k, (n[k] > 1 ? " x" n[k] : ""), x
            }
            out = run - tot
            if (out > 0) printf "%d\t%6.1fs  (outside bounded calls: shell work and file reads)\n", out, out / 1000
        }' "$f" | sort -t "$_tab" -k1,1nr | head -n 10 | cut -f2- \
        | while IFS= read -r l; do fact "    $l"; done
    # every command lost to the deadline, whatever the table above kept
    awk -F'\t' '$2 == "not run" { c[$3]++ } END { for (k in c) printf "%s x%d\n", k, c[k] }' "$f" | sort \
        | while IFS= read -r l; do fact "         -   $l not run (deadline)"; done
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

# ---- reasoned-absence helpers -------------------------------------------------
_errfile=""
CMD_TIMEOUT="${CMD_TIMEOUT:-15}"
# Call after _run_init: the error file lives in the run's private directory.
_init_probe() { _errfile="$(_tmp probe.err)"; }

# _rmtmp PATH... -> remove paths this run made under its own directory. A no-op
# when no directory could be made: _tmp then returns /dev/null, which a root
# run must never remove.
_rmtmp() { [ -n "$_tmp_dir" ] || return 0; rm -rf "$@" 2>/dev/null; return 0; }

# _flag KEY TEXT -> record one event of this run for the goals resolved at the
# end of the report. Kept in a file because most sections run inside `| while`
# pipelines, where a variable assignment does not survive.
_flag() { printf '%s\t%s\n' "$1" "$(_flat "$2")" >> "$(_tmp flags)" 2>/dev/null; }
_flagged() { grep -q "^$1$_tab" "$(_tmp flags)" 2>/dev/null; }
_flag_text() {
    awk -F'\t' -v k="$1" '$1 == k && !s[$2]++ { printf "%s%s", (n++ ? "; " : ""), $2 }' "$(_tmp flags)" 2>/dev/null
}

# ---- apm: probe helpers — DO NOT EDIT ---------------------------------------
# members: apmjava apmnodejs apmphp apmpython
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
# CMD may be a file, a shell function or a builtin; _bounded caps all three. A
# non-zero exit that still printed something is reported with its output.
probe() {
    local label="$1"; shift
    [ -n "$(_cmd_kind "$1")" ] || { fact "$label: n/a (command not found: $1)"; return; }
    local out rc
    out="$(_bounded "$@" 2>"$_errfile")"; rc=$?
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    if [ "$rc" -ne 0 ]; then
        [ -n "$out" ] && { _emit_labeled "$label (exit $rc)" "$out"; return; }
        fact "$label: n/a ($(_classify_err))"; return
    fi
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

# _names DIR -> the names in DIR, as `ls DIR` lists them (no dot files, sorted).
# Only an unmatched glob is skipped: in a DIR this uid can read but not enter,
# -e fails on every entry although ls lists them all.
_names() {
    local n
    for n in "$1"/*; do
        [ "$n" = "$1/*" ] && [ ! -e "$n" ] && [ ! -L "$n" ] && continue
        printf '%s\n' "${n##*/}"
    done
    return 0
}
# ---- end apm: probe helpers

# _fsize PATH -> size in bytes from the inode (ls -Ln), without reading the
# file: an agent or server log can be gigabytes, and counting its lines is a
# whole-file read.
_fsize() { ls -Lln "$(_vfix "$1")" 2>/dev/null | awk '{print $5; exit}'; }

# _file_lines first|last "label" PATH CAP -> the first or last CAP lines of a
# file verbatim (a bounded read), or a classified reason. Framework policy:
# configuration is dumped verbatim, never masked (README, "What the report can
# contain").
_file_lines() {
    local end="$1" label="$2" path="$3" cap="$4"
    case "$path" in /proc/[0-9]*/root*) path="$(_vfix "$path")" ;; esac
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    fact "$label ($end $cap lines; file size $(_fsize "$path") bytes):"
    if [ "$end" = last ]; then tail -n "$cap" "$path" 2>/dev/null; else head -n "$cap" "$path" 2>/dev/null; fi \
        | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

# conf_bytes "label" PATH -> byte-level facts a plain `cat` hides: total bytes
# and CR (\r, 0x0D) byte count.
conf_bytes() {
    local label="$1" path="$2" sz cr
    case "$path" in /proc/[0-9]*/root*) path="$(_vfix "$path")" ;; esac
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$(_fsize "$path")"
    cr="$(tr -dc '\r' < "$path" 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}

# _sha256 PATH -> the artifact's sha256, or a classified reason.
_sha256() {
    local out rc
    set -- "$(_vfix "$1")"
    if have sha256sum; then out="$(_bounded sha256sum "$1" 2>/dev/null)"; rc=$?
    elif have shasum; then out="$(_bounded shasum -a 256 "$1" 2>/dev/null)"; rc=$?
    else printf 'n/a (command not found: sha256sum, shasum)'; return; fi
    [ "$rc" -eq 124 ] && { printf 'n/a (timed out: %ss)' "$CMD_TIMEOUT"; return; }
    [ -n "$out" ] || { printf 'n/a (exit %s)' "$rc"; return; }
    printf '%s' "${out%% *}"
}

# file_facts "indent" PATH -> identity of a binary artifact: size, mtime,
# sha256; the cross-check for the in-jar version.
file_facts() {
    local ind="$1" p="$2" sz mt
    case "$p" in /proc/[0-9]*/root*) p="$(_vfix "$p")" ;; esac
    [ -e "$p" ] || { printf '%sn/a (path not found: %s)\n' "$ind" "$p"; return; }
    [ -r "$p" ] || { printf '%sn/a (permission denied: %s)\n' "$ind" "$p"; return; }
    sz="$(_fsize "$p")"
    mt="$(stat -c '%y' "$p" 2>/dev/null || ls -l "$p" 2>/dev/null | cut -c1-60)"
    printf '%ssize: %s bytes   mtime: %s\n' "$ind" "${sz:-?}" "${mt:-n/a (stat and ls both unavailable)}"
    printf '%ssha256: %s\n' "$ind" "$(_sha256 "$p")"
}

# _zlist JAR PATTERN... -> the entry names of a jar matching the patterns
# (central directory only; the jar is never executed or loaded). Returns 0 with
# the names, 11 when unzip read the jar and no entry matched (unzip's own exit
# code for that), and anything else when the jar could not be listed, with the
# reason in $(_tmp zlist.why). An unreadable jar, a timeout, or an unzip
# without -Z (busybox) is a failure to read, never "no entry".
_zlist() {
    local jar="$1" rc
    shift
    case "$jar" in /proc/[0-9]*/root*) jar="$(_vfix "$jar")" ;; esac
    true > "$(_tmp zlist.why)" 2>/dev/null
    if ! have unzip; then printf 'command not found: unzip' > "$(_tmp zlist.why)"; return 127; fi
    if [ ! -r "$jar" ]; then printf '%s' "$(_path_why "$jar")" > "$(_tmp zlist.why)"; return 126; fi
    _bounded unzip -Z1 "$jar" "$@" 2>"$(_tmp zlist.err)"; rc=$?
    case "$rc" in
        0|11) return "$rc" ;;
        124)  printf 'timed out: %ss' "$CMD_TIMEOUT" > "$(_tmp zlist.why)" ;;
        *)    printf 'unzip -Z1 exit %s: %s' "$rc" "$(_unzip_why "$(_tmp zlist.err)")" > "$(_tmp zlist.why)" ;;
    esac
    return "$rc"
}
_zwhy() { cat "$(_tmp zlist.why)" 2>/dev/null; }

# _unzip_why ERRFILE -> unzip's own message, without the "[<archive path>]"
# line it starts with, so a cut keeps the reason rather than the path
_unzip_why() {
    grep -v '^\[.*\]$' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-160
}

# jar_version "indent" JAR -> VERSION/BUILD from whatap/v.properties inside the
# jar, read with unzip.
jar_version() {
    local ind="$1" jar="$2" out rc
    case "$jar" in /proc/[0-9]*/root*) jar="$(_vfix "$jar")" ;; esac
    if ! have unzip; then
        printf '%sin-jar whatap/v.properties: n/a (command not found: unzip)\n' "$ind"
        return
    fi
    out="$(_bounded unzip -p "$jar" whatap/v.properties 2>"$_errfile")"; rc=$?
    case "$rc" in
        0)   ;;
        11)  printf '%sin-jar whatap/v.properties: no such entry in this jar\n' "$ind"; return ;;
        124) printf '%sin-jar whatap/v.properties: n/a (timed out: %ss)\n' "$ind" "$CMD_TIMEOUT"; return ;;
        *)   printf '%sin-jar whatap/v.properties: n/a (unzip exit %s: %s)\n' "$ind" "$rc" "$(_unzip_why "$_errfile")"; return ;;
    esac
    if [ -z "$out" ]; then
        printf '%sin-jar whatap/v.properties: (empty entry)\n' "$ind"
        return
    fi
    printf '%sin-jar whatap/v.properties:\n' "$ind"
    printf '%s\n' "$out" | head -n 10 | while IFS= read -r _l || [ -n "$_l" ]; do printf '%s  %s\n' "$ind" "$_l"; done
}

# jar_entries "indent" JAR PATTERN CAP -> file entry names inside a jar.
# Directory entries are dropped so the list holds libraries, not folders.
jar_entries() {
    local ind="$1" jar="$2" pat="$3" cap="${4:-100}" out n rc
    out="$(_zlist "$jar" "$pat")"; rc=$?
    case "$rc" in
        0|11) ;;
        *) printf '%sentries matching %s: n/a (%s)\n' "$ind" "$pat" "$(_zwhy)"; return ;;
    esac
    out="$(printf '%s\n' "$out" | grep -v '/$' | grep .)"
    [ -z "$out" ] && { printf '%snone matching %s\n' "$ind" "$pat"; return; }
    n="$(printf '%s\n' "$out" | grep -c .)"
    [ "$n" -lt "$cap" ] && cap="$n"
    printf '%s%s entries matching %s (%s printed):\n' "$ind" "${n:-0}" "$pat" "$cap"
    printf '%s\n' "$out" | head -n "$cap" | while IFS= read -r _l; do
        [ -n "$_l" ] || continue
        printf '%s  %s\n' "$ind" "${_l##*/}"
        _lib_record "${_l##*/}"
        case "$_l" in *.jar) _path_record "nested|$jar|$_l" ;; esac
    done
}

# jvprobe "label" JAVA_EXE [ARGS...] -> run a DISCOVERED java launcher (a new,
# short-lived JVM). Never applied to a running process, and never to a binary
# whose name is not java: an embedding launcher (vshell, jsvc) is a program of
# its own, and what it does with -version is not known.
jvprobe() {
    local label="$1" jv="$2" out rc
    shift 2
    [ -x "$jv" ] || { fact "$label: n/a (not executable: $jv)"; return; }
    out="$(_bounded "$jv" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq 124 ]; then
        if _past_deadline; then fact "$label: n/a (run deadline reached: ${RUN_DEADLINE}s)"
        else fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; fi
        return
    fi
    [ -z "$out" ] && { fact "$label: n/a (empty output, exit $rc)"; return; }
    [ "$rc" -ne 0 ] && label="$label (exit $rc)"
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
    local ind="$1" d="$2" cap="${3:-120}" n out shown
    case "$d" in /proc/[0-9]*/root*) d="$(_vfix "$d")" ;; esac
    [ -d "$d" ] || { printf '%s%s: n/a (%s)\n' "$ind" "$d" "$(_path_why "$d")"; return; }
    [ -r "$d" ] || { printf '%s%s: n/a (permission denied)\n' "$ind" "$d"; return; }
    out="$(_names "$d" | grep -i '\.jar$')"
    if [ -z "$out" ]; then printf '%s%s: 0 jar files\n' "$ind" "$d"; return; fi
    out="$(printf '%s\n' "$out" | grep -v -i 'whatap\.agent')"
    n="$(printf '%s\n' "$out" | grep -c . )"
    shown="$cap"; [ "${n:-0}" -lt "$cap" ] && shown="${n:-0}"
    if [ "$shown" = "${n:-0}" ]; then
        printf '%s%s: %s jar files (all printed)\n' "$ind" "$d" "${n:-0}"
    else
        printf '%s%s: %s jar files (first %s printed; all %s recorded for --library)\n' "$ind" "$d" "${n:-0}" "$shown" "${n:-0}"
    fi
    # record every jar, print only the first CAP: a deployment unit can carry
    # several hundred jars, and the application's own ones sort anywhere in
    # that list
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
    case "$d" in /proc/[0-9]*/root*) d="$(_vfix "$d")" ;; esac
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
# report a field engineer pastes into a chat is not the place to send it twice.
_LIBROOTS=""
_build_libroots() {
    _LIBROOTS="$(_tmp libroots)"
    true > "$_LIBROOTS" 2>/dev/null
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
# endian). major - 44 is the Java feature release (52 = Java 8).
class_file_version() {
    local ind="$1" jar="$2" ent hi lo maj rc
    case "$jar" in /proc/[0-9]*/root*) jar="$(_vfix "$jar")" ;; esac
    have od || { printf '%sclass-file version: n/a (command not found: od)\n' "$ind"; return; }
    ent="$(_zlist "$jar" '*.class')"; rc=$?
    case "$rc" in
        0|11) ;;
        *) printf '%sclass-file version: n/a (%s)\n' "$ind" "$(_zwhy)"; return ;;
    esac
    ent="$(printf '%s\n' "$ent" | grep -v '^META-INF/versions/' | head -n1)"
    [ -n "$ent" ] || { printf '%sclass-file version: n/a (no class entry in this jar)\n' "$ind"; return; }
    # shellcheck disable=SC2046
    set -- $(_bounded unzip -p "$jar" "$ent" 2>/dev/null | od -An -tu1 -j6 -N2 2>/dev/null)
    hi="$1"; lo="$2"
    [ -n "$lo" ] || { printf '%sclass-file version: n/a (class entry not readable: %s)\n' "$ind" "$ent"; return; }
    maj=$(( hi * 256 + lo ))
    printf '%sclass-file major version: %s (Java %s), read from %s\n' "$ind" "$maj" "$((maj - 44))" "$ent"
}

# detail_jar "label" JAR [ORIGIN] -> identity, Maven coordinates, manifest
# versions, class-file version, package map, class count, service entries and
# multi-release markers of one library.
detail_jar() {
    local label="$1" jar="$2" origin="$3" pp cnt lst rc
    case "$jar" in /proc/[0-9]*/root*) jar="$(_vfix "$jar")" ;; esac
    fact "-- $label"
    if [ -n "$origin" ]; then
        # a library packed inside an executable jar has no path of its own on
        # this host; size and sha256 identify the entry's content
        fact "       origin: $origin"
        fact "       size: $(_fsize "$jar") bytes (content of that entry)"
        fact "       sha256: $(_sha256 "$jar")"
    else
        fact "       path: $jar"
        file_facts "           " "$jar"
    fi
    lst="$(_tmp dj.list)"
    _zlist "$jar" > "$lst"; rc=$?
    if [ "$rc" -ne 0 ]; then
        fact "       jar contents: n/a ($(_zwhy))"
        return
    fi
    pp="$(grep -E '^META-INF/maven/[^/]*/[^/]*/pom\.properties$' "$lst" | head -n 3)"
    if [ -n "$pp" ]; then
        printf '%s\n' "$pp" | while IFS= read -r _e; do
            printf '           maven entry: %s\n' "$_e"
            _bounded unzip -p "$jar" "$_e" 2>/dev/null | grep -vE '^#' | while IFS= read -r _l; do
                [ -n "$_l" ] && printf '             %s\n' "$_l"
            done
        done
    else
        fact "       maven coordinates: none (no META-INF/maven/*/pom.properties in this jar)"
    fi
    _mf="$(_bounded unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' \
           | grep -iE '^(Implementation-|Specification-|Bundle-SymbolicName|Bundle-Version|Bundle-Name|Automatic-Module-Name|Build-Jdk|Created-By|Multi-Release|Export-Package)' | head -n 20)"
    if [ -n "$_mf" ]; then
        fact "       manifest attributes:"
        printf '%s\n' "$_mf" | while IFS= read -r _l; do printf '             %s\n' "$(printf '%s' "$_l" | cut -c1-200)"; done
    else
        fact "       manifest attributes: none of the version attributes are present"
    fi
    class_file_version "           " "$jar"
    cnt="$(grep -c '\.class$' "$lst")"
    fact "       class entries: ${cnt:-0}"
    if [ "${_DJ_IN_INDEX:-0}" = 1 ]; then
        fact "       packages by class count: not repeated here (the class names of this jar are in the section N index)"
    else
        fact "       packages by class count (top 25):"
        grep '\.class$' "$lst" | sed 's|/[^/]*$||; t; s|.*|(default package)|' | sort | uniq -c | sort -rn | head -n 25 \
            | while IFS= read -r _l; do printf '             %s\n' "$(printf '%s' "$_l" | sed 's|/|.|g')"; done
    fi
    _mr="$(grep '^META-INF/versions/' "$lst" | sed 's|^META-INF/versions/\([0-9]*\)/.*|\1|' | sort -u | tr '\n' ' ')"
    [ -n "$_mr" ] && fact "       multi-release jar, versioned class trees for: $_mr"
    grep -qx 'module-info.class' "$lst" && fact "       module-info.class: present"
    _svc="$(grep '^META-INF/services/.' "$lst" | head -n 10)"
    if [ -n "$_svc" ]; then
        fact "       service provider entries:"
        printf '%s\n' "$_svc" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
    fi
    # member signatures of the classes named with --class
    for _fq in $OPT_CLASSES; do
        _ce="$(printf '%s' "$_fq" | tr '.' '/').class"
        grep -qxF "$_ce" "$lst" || continue
        if ! have javap; then
            fact "       $_fq: present in this jar; member signatures n/a (command not found: javap)"
            continue
        fi
        fact "       $_fq member signatures (javap -p -s, first 400 lines):"
        _bounded javap -p -s -classpath "$jar" "$_fq" 2>&1 | head -n 400 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
    done
}

# bootjar_facts "indent" JAR -> the launcher manifest, the layer index, and the
# package map of the application's own classes under BOOT-INF/classes of an
# executable (fat) jar.
bootjar_facts() {
    local ind="$1" jar="$2" mf cnt lst rc
    case "$jar" in /proc/[0-9]*/root*) jar="$(_vfix "$jar")" ;; esac
    lst="$(_tmp bj.list)"
    _zlist "$jar" 'BOOT-INF/*' > "$lst"; rc=$?
    case "$rc" in
        0)  ;;
        11) return ;;
        *)  printf '%sexecutable jar layout: n/a (%s)\n' "$ind" "$(_zwhy)"; return ;;
    esac
    printf '%sexecutable jar layout: BOOT-INF present (libraries are packed inside this jar, not on the filesystem)\n' "$ind"
    mf="$(_bounded unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' \
          | grep -iE '^(Main-Class|Start-Class|Spring-Boot-Version|Spring-Boot-Classes|Spring-Boot-Lib|Implementation-Title|Implementation-Version|Build-Jdk|Created-By)' | head -n 12)"
    if [ -n "$mf" ]; then
        printf '%slauncher manifest:\n' "$ind"
        printf '%s\n' "$mf" | while IFS= read -r _l; do printf '%s  %s\n' "$ind" "$(printf '%s' "$_l" | cut -c1-200)"; done
    else
        printf '%slauncher manifest: none of the launcher attributes are present\n' "$ind"
    fi
    grep -qx 'BOOT-INF/layers.idx' "$lst" && printf '%sBOOT-INF/layers.idx: present\n' "$ind"
    cnt="$(grep -c '^BOOT-INF/classes/.*\.class$' "$lst")"
    printf '%sapplication classes in BOOT-INF/classes: %s\n' "$ind" "${cnt:-0}"
    if [ "${cnt:-0}" -gt 0 ]; then
        printf '%sapplication packages by class count (top 20):\n' "$ind"
        grep '^BOOT-INF/classes/.*\.class$' "$lst" \
            | sed 's|^BOOT-INF/classes/||' | sed 's|/[^/]*$||; t; s|.*|(default package)|' | sort | uniq -c | sort -rn | head -n 20 \
            | while IFS= read -r _l; do printf '%s  %s\n' "$ind" "$(printf '%s' "$_l" | sed 's|/|.|g')"; done
    fi
}

# nested_extract CONTAINER ENTRY -> extract one packed jar to a path under this
# run's directory and print that path, so the same detail_jar reader works on a
# library that only exists inside an executable jar. Bounded: entries above
# 80 MB are skipped.
nested_extract() {
    local jar="$1" ent="$2" out sz
    case "$jar" in /proc/[0-9]*/root*) jar="$(_vfix "$jar")" ;; esac
    have unzip || return 1
    sz="$(_bounded unzip -Zl "$jar" "$ent" 2>/dev/null | awk 'NR==1 {print $4}')"
    case "$sz" in ''|*[!0-9]*) sz="" ;; esac
    if [ -n "$sz" ] && [ "$sz" -gt 83886080 ]; then return 1; fi
    out="$(_tmp nested.jar)"
    _bounded unzip -p "$jar" "$ent" > "$out" 2>/dev/null || return 1
    [ -s "$out" ] || return 1
    printf '%s\n' "$out"
}

# weaving_lines "label" PATH -> the agent-log lines carrying the "Weaving" log
# id, from a BOUNDED window (the head of the file as well as the tail; never a
# whole-file grep).
weaving_lines() {
    local label="$1" path="$2" hw=3000 tw=1000 out n
    case "$path" in /proc/[0-9]*/root*) path="$(_vfix "$path")" ;; esac
    [ -e "$path" ] || { fact "-- $label: n/a ($(_path_why "$path"))"; return; }
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
# NAME is compared literally (whatap.env is not whatapXenv); the first entry
# wins. One awk pass per pid writes every "NAME<tab>value" under the run's
# directory, read back with the shell's own read; without that directory the
# same awk answers the one name.
_proc_env() {
    local t l
    if [ -z "$_tmp_dir" ]; then
        tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" | _K="$2" awk 'BEGIN { k = ENVIRON["_K"] "=" }
            index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
        return 0
    fi
    t="$_tmp_dir/env.$1"
    # a name holding a tab could not be told apart from its value: skipped
    [ -f "$t" ] || tr '\0' '\n' 2>/dev/null < "/proc/$1/environ" | awk '
        { i = index($0, "="); if (i < 2) next; n = substr($0, 1, i - 1)
          if (index(n, "\t") || (n in v)) next; v[n] = 1
          printf "%s\t%s\n", n, substr($0, i + 1) }' > "$t" 2>/dev/null
    while IFS= read -r l; do
        case "$l" in "$2$_tab"*) printf '%s\n' "${l#"$2$_tab"}"; return 0 ;; esac
    done < "$t"
    return 0
}

# _env_readable PID -> success when this run can read /proc/PID/environ. As
# non-root, another user's environ is closed, and JAVA_TOOL_OPTIONS (the way
# the operator injects -javaagent) is then invisible.
_env_readable() { head -c 1 "/proc/$1/environ" >/dev/null 2>&1; }

# _all_jvm_args PID -> one JVM argument per line, in the order the JVM applies
# them: JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS, the command line, then
# _JAVA_OPTIONS. A fifth source is appended when it exists: arguments
# recovered from the running VM with `jcmd` (_jcmd_recover), written only for a
# process whose options are absent from /proc and only when --jcmd was passed.
# It is last because it reports the EFFECTIVE set the VM holds, which is what
# "last wins" means for _jvm_sysprop. Built once per pid and cached under the
# run's directory; every section reads the same set.
_jvm_args_read() {
    local pid="$1"
    _proc_env "$pid" JAVA_TOOL_OPTIONS | tr ' ' '\n'
    _proc_env "$pid" JDK_JAVA_OPTIONS | tr ' ' '\n'
    tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline"
    _proc_env "$pid" _JAVA_OPTIONS | tr ' ' '\n'
    [ -n "$_tmp_dir" ] && [ -f "$(_tmp "jcmdargs.$pid")" ] && cat "$(_tmp "jcmdargs.$pid")" 2>/dev/null
    return 0
}
_all_jvm_args() {
    local c
    [ -n "$_tmp_dir" ] || { _jvm_args_read "$1"; return 0; }
    c="$(_tmp "args.$1")"
    [ -f "$c" ] || _jvm_args_read "$1" > "$c" 2>/dev/null
    cat "$c" 2>/dev/null
    return 0
}

# ---- Tier 2 argument recovery (opt-in: --jcmd) --------------------------------
# A JVM the collector found only by its libjvm.so mapping carries its options
# nowhere in /proc: the native launcher passed them to JNI_CreateJavaVM as an
# array it built, so /proc/<pid>/cmdline holds the launcher's own arguments.
# `jcmd <pid> VM.command_line` and `VM.system_properties` report them. That is
# the JVM attach mechanism on a live process, Tier 2, so this runs ONLY with
# --jcmd and only for the processes whose options are not in /proc. The output
# goes to a per-pid file _all_jvm_args appends.
#
# jvm_args is split on spaces, as _all_jvm_args splits JAVA_TOOL_OPTIONS.
# VM.system_properties is Properties.store format, in which "=", ":", "#" and
# "!" arrive backslash-escaped (java.class.path reaches here as /a\:/b), so
# those escapes are undone before each property is written as -Dkey=value.
_JCMD_RECOVERED=""
_jcmd_recover() {
    local pid="$1" out cl dst rc
    if ! have jcmd; then _flag jcmd_fail "argument recovery of pid $pid: command not found: jcmd"; return 1; fi
    dst="$(_tmp "jcmdargs.$pid")"
    true > "$dst" 2>/dev/null
    warn "[Tier2] jcmd argument recovery: pid $pid — uses the JVM attach mechanism on the target process"
    cl="$(_bounded jcmd "$pid" VM.command_line 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _flag jcmd_fail "jcmd $pid VM.command_line: $( [ "$rc" = 124 ] && echo "timed out: ${CMD_TIMEOUT}s" || echo "exit $rc: $(printf '%s\n' "$cl" | head -n 1 | cut -c1-120)")"
    fi
    printf '%s\n' "$cl" | sed -n 's/^jvm_args: //p' | tr ' ' '\n' | grep . >> "$dst" 2>/dev/null
    # the program the VM recorded; a VM created straight through
    # JNI_CreateJavaVM often carries "<unknown>" here
    printf '%s\n' "$cl" | sed -n 's/^java_command: //p' | head -n1 > "$(_tmp "jcmdmain.$pid")" 2>/dev/null
    out="$(_bounded jcmd "$pid" VM.system_properties 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        _flag jcmd_fail "jcmd $pid VM.system_properties: $( [ "$rc" = 124 ] && echo "timed out: ${CMD_TIMEOUT}s" || echo "exit $rc: $(printf '%s\n' "$out" | head -n 1 | cut -c1-120)")"
    fi
    # a -D the launcher passed is already in the file, from jvm_args; only the
    # properties it does not carry are appended, so no option is listed twice.
    # The file is read in BEGIN: with NR==FNR an empty first file would make
    # every property look like part of it and drop them all.
    printf '%s\n' "$out" | grep '=' | grep -v '^#' \
        | sed 's/\\:/:/g; s/\\=/=/g; s/\\!/!/g; s/\\#/#/g; s/^/-D/' \
        | awk -v f="$dst" 'BEGIN { while ((getline l < f) > 0) if (substr(l, 1, 2) == "-D") { split(l, kv, "="); seen[kv[1]] = 1 } }
               { split($0, kv, "="); if (!(kv[1] in seen)) print }' > "$(_tmp "jcmdsp.$pid")" 2>/dev/null
    cat "$(_tmp "jcmdsp.$pid")" >> "$dst" 2>/dev/null
    _rmtmp "$(_tmp "jcmdsp.$pid")" "$(_tmp "args.$pid")" "$(_tmp "sp.$pid")" "$(_tmp "conf.$pid")"
    [ -s "$dst" ] || { _rmtmp "$dst"; return 1; }
    _JCMD_RECOVERED="$_JCMD_RECOVERED $pid"
    return 0
}

# _jvm_sysprop PID KEY -> the last -DKEY=value seen across all argument
# sources (see _all_jvm_args for the order). Empty when the property is unset.
# KEY is compared literally (-DwhatapXconfig is not whatap.config). As in
# _proc_env, one awk pass per pid writes every key's last value under the run's
# directory (_jcmd_recover drops it with the argument cache).
_jvm_sysprop() {
    local t l
    if [ -z "$_tmp_dir" ]; then
        _all_jvm_args "$1" | _K="$2" awk 'BEGIN { k = "-D" ENVIRON["_K"] "="; f = 0 }
            index($0, k) == 1 { v = substr($0, length(k) + 1); f = 1 } END { if (f) print v }'
        return 0
    fi
    t="$_tmp_dir/sp.$1"
    [ -f "$t" ] || _all_jvm_args "$1" | awk '
        substr($0, 1, 2) == "-D" { i = index($0, "="); if (i < 4) next; k = substr($0, 3, i - 3)
          if (index(k, "\t")) next; if (!(k in v)) o[++n] = k; v[k] = substr($0, i + 1) }
        END { for (j = 1; j <= n; j++) printf "%s\t%s\n", o[j], v[o[j]] }' > "$t" 2>/dev/null
    while IFS= read -r l; do
        case "$l" in "$2$_tab"*) printf '%s\n' "${l#"$2$_tab"}"; return 0 ;; esac
    done < "$t"
    return 0
}

# _jvm_maps_lib PID -> the VM shared library mapped into the process, or empty.
# HotSpot and its derivatives map libjvm.so; OpenJ9 / IBM J9 map
# libj9vm<ver>.so beside their own libjvm.so.
_jvm_maps_lib() {
    grep -m1 -oE '/[^[:space:]]*/(libjvm\.so|libj9vm[^/[:space:]]*\.so)' "/proc/$1/maps" 2>/dev/null | head -n1
}

# _is_java_launcher PATH -> success when the binary is a java launcher by name
# (bin/java of a JDK or JRE). Only those are run with -version.
_is_java_launcher() {
    case "${1##*/}" in java|java.exe) return 0 ;; esac
    return 1
}

# _jvm_confirmed PID -> success when PID is confirmed a JVM: a libjvm /
# libj9vm mapping was read in its maps. Only a confirmed JVM is ever attached
# to (jcmd, jstack) or signalled (SIGQUIT), and only its binary is listed as
# a Java runtime: a process found by comm, exe name, an argument or its thread
# names alone could be any program (a script or a C binary named java), and
# SIGQUIT ends most of them. The exe link and maps pass the same access check,
# so a JVM whose exe this run can read has readable maps as well.
_jvm_confirmed() {
    [ -n "$(_jvm_maps_lib "$1")" ]
}
_NOTCONF="not confirmed as a JVM: no libjvm or libj9vm mapping was read in /proc/<pid>/maps, so it is not attached to or signalled"

# _whatap_attached PID -> success if a whatap -javaagent reaches this JVM from
# any argument source, or a whatap system property / env variable is present.
_whatap_attached() {
    local pid="$1"
    _all_jvm_args "$pid" | grep -qiE '^-javaagent:.*whatap|^-Dwhatap\.' && return 0
    tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | grep -qiE '^(WHATAP_|whatap\.|license=)' && return 0
    return 1
}

# ---- path resolution, per owning process ----------------------------------------
# A path a JVM names is a path in THAT process's view: a relative one is
# relative to its working directory, an absolute one to its mount namespace.
# Resolving either against the collector's own cwd or namespace reads another
# file, or none, and reports its absence as a fact.
#
# D_NSMAP holds " <pid>=same|other|unknown" for every JVM: whether it shares
# this collector's mount namespace. "unknown" is a namespace link this run
# cannot read (another user's process, as non-root).
_SELF_MNT=""
D_NSMAP=""
_note_ns() {
    local n r
    [ -n "$_SELF_MNT" ] || _SELF_MNT="$(readlink /proc/self/ns/mnt 2>/dev/null)"
    r="$(readlink "/proc/$1/root" 2>/dev/null)"
    n="$(readlink "/proc/$1/ns/mnt" 2>/dev/null)"
    # a root other than the collector's (chroot) is "other" as much as a
    # mount namespace is: its absolute paths are not the collector's
    if [ -z "$r" ]; then D_NSMAP="$D_NSMAP $1=unknown"
    elif [ "$r" != / ]; then D_NSMAP="$D_NSMAP $1=other"
    elif [ -n "$n" ] && [ -n "$_SELF_MNT" ] && [ "$n" != "$_SELF_MNT" ]; then D_NSMAP="$D_NSMAP $1=other"
    else D_NSMAP="$D_NSMAP $1=same"; fi
}
_ns_of() {
    case "$D_NSMAP " in
        *" $1=same "*)  echo same ;;
        *" $1=other "*) echo other ;;
        *)              echo unknown ;;
    esac
}

# _path_why PATH -> "readable: P", "permission denied: <the directory that
# refused>" or "path not found: P". A missing path is told from a hidden one
# by the deepest ancestor that exists: one this run cannot search hides it.
_path_why() {
    local p="$1" d
    if [ -e "$p" ]; then
        if [ -r "$p" ]; then echo "readable: $p"; else echo "permission denied: $p"; fi
        return
    fi
    d="$p"
    while :; do
        case "$d" in */*) d="${d%/*}"; [ -n "$d" ] || d=/ ;; *) break ;; esac
        if [ -e "$d" ]; then
            if [ -d "$d" ] && [ ! -x "$d" ]; then echo "permission denied: $d"; else echo "path not found: $p"; fi
            return
        fi
        [ "$d" = / ] && break
    done
    echo "path not found: $p"
}

# _nsresolve PID PATH -> PATH, absolute as the process PID sees it, resolved
# one component at a time under /proc/PID/root. The kernel resolves
# /proc/PID/root/<path> through the JVM's root only for the first step: a
# symlink met further down with an absolute target is resolved against the
# COLLECTOR's root, so a container's whatap.conf -> /etc/shadow would read the
# host's file. Here an absolute target is re-rooted under /proc/PID/root and
# ".." stops at that root, so nothing outside the JVM's own view is read.
# Status 1 on a symlink chain longer than 40 or an unreadable link.
_nsresolve() {
    local root="/proc/$1/root" rest="$2" cur="" comp t n=0
    while [ -n "$rest" ]; do
        case "$rest" in /*) rest="${rest#/}"; continue ;; esac
        comp="${rest%%/*}"
        if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$comp" in
            ''|.) continue ;;
            ..)   cur="${cur%/*}"; continue ;;
        esac
        if [ -L "$root$cur/$comp" ]; then
            n=$((n + 1)); [ "$n" -gt 40 ] && return 1
            t="$(readlink "$root$cur/$comp" 2>/dev/null)" || return 1
            [ -n "$t" ] || return 1
            case "$t" in /*) cur="" ;; esac
            rest="$t${rest:+/$rest}"
            continue
        fi
        cur="$cur/$comp"
    done
    printf '%s\n' "$root${cur:-/}"
}

# _vfix PATH -> PATH itself, or, for a view under /proc/<pid>/root, the same
# path re-resolved by _nsresolve. The readers below call it, so a file or
# directory reached by joining a name onto a view (<home>/whatap.conf,
# <appBase>/<app>/WEB-INF/lib) cannot follow a symlink out of the JVM's root.
_vfix() {
    local pid rest
    case "$1" in
        /proc/[0-9]*/root|/proc/[0-9]*/root/*)
            rest="${1#/proc/}"; pid="${rest%%/*}"; rest="${rest#*/root}"
            _nsresolve "$pid" "${rest:-/}" || printf '%s\n' "/proc/$pid/root/.ggt-unresolved-symlink-chain"
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# _rpath PID PATH -> the path through which this collector reads PATH as the
# process PID resolves it; nothing and status 1 when it is not visible (_rwhy
# gives the reason). PID "" is a fixed absolute path, read as is; "self" is the
# collector's own environment, where a relative path is the collector's.
_rpath() {
    local v
    v="$(_rview "$1" "$2")" || return 1
    [ -e "$v" ] || return 1
    printf '%s\n' "$v"
}

# _rview PID PATH -> the view _rpath checks, whether or not it exists.
# Nothing, status 1, when the JVM's root cannot be read (another user's
# process, as non-root): the collector's own copy of the path is another file,
# and reading it in its place reported a host decoy as a JVM's config.
_rview() {
    local pid="$1" p="$2" c r ns
    [ -n "$p" ] || return 1
    case "$pid" in
        ''|self)
            case "$p" in /*) ;; *) [ "$pid" = self ] || return 1 ;; esac
            printf '%s\n' "$p"; return 0 ;;
    esac
    ns="$(_ns_of "$pid")"
    [ "$ns" = unknown ] && return 1
    case "$p" in
        /*) ;;
        *)  c="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
            [ -n "$c" ] || return 1
            if [ "$ns" = other ]; then
                # the link text is the working directory as the collector's
                # root names it; below a chroot it carries the root's path, which
                # is taken off so the path is the JVM's own
                r="$(readlink "/proc/$pid/root" 2>/dev/null)"
                case "$r" in
                    /|'') ;;
                    *) case "$c" in
                           "$r") c=/ ;;
                           "$r"/*) c="${c#"$r"}" ;;
                           *) c="" ;;
                       esac ;;
                esac
                # not under its root as a string: the kernel's own link is the
                # directory, joined without the component walk
                [ -n "$c" ] || { printf '/proc/%s/cwd/%s\n' "$pid" "$p"; return 0; }
            fi
            case "$p" in
                .)   p="$c" ;;
                ./*) p="$c/${p#./}" ;;
                *)   p="$c/$p" ;;
            esac ;;
    esac
    if [ "$ns" = other ]; then _nsresolve "$pid" "$p"
    else printf '%s\n' "$p"; fi
}

# _rwhy PID PATH -> why _rpath found nothing: "permission denied: ..." or
# "path not found: ...", with the path as that process resolves it.
_rwhy() {
    local pid="$1" p="$2" v
    [ -n "$p" ] || { echo "path not found: (empty path)"; return; }
    case "$pid" in
        ''|self)
            case "$p" in /*) ;; *) [ "$pid" = self ] || { echo "path not found: relative path $p with no process to resolve it against"; return; } ;; esac
            _path_why "$p"; return ;;
    esac
    case "$p" in
        /*) if [ "$(_ns_of "$pid")" = unknown ]; then
                if [ -e "/proc/$pid" ]; then echo "permission denied: /proc/$pid/root (the JVM's root is not readable by this run)"
                else echo "path not found: /proc/$pid (the process exited)"; fi
                return
            fi ;;
        *)  if ! readlink "/proc/$pid/cwd" >/dev/null 2>&1; then
                if [ -e "/proc/$pid" ]; then echo "permission denied: /proc/$pid/cwd (the working directory the relative path $p is joined to)"
                else echo "path not found: /proc/$pid (the process exited)"; fi
                return
            fi ;;
    esac
    if v="$(_rview "$pid" "$p")"; then _path_why "$v"
    else echo "path not found: $p (a symlink chain under the root of pid $pid longer than 40 links or unreadable)"; fi
}

# _rnote PID PATH VIEW -> how a resolved path was reached, when it is not the
# path as written: a relative path joined to the JVM's working directory, or an
# absolute one read through the JVM's own root.
_rnote() {
    [ "$2" = "$3" ] && return 0
    case "$2" in
        /*) printf 'read through the root of pid %s: %s' "$1" "$3" ;;
        *)  printf 'relative to the working directory of pid %s: %s' "$1" "$3" ;;
    esac
}

# cwd_view PID -> a readable path to the working directory of PID.
cwd_view() {
    local v
    v="$(_rview "$1" .)" || return 1
    [ -d "$v" ] || return 1
    printf '%s\n' "$v"
}

# tomcat_app_bases PID FSDIR -> every appBase this instance configures, one
# per line. Read from server.xml instead of assuming <instance>/webapps; a
# relative value is joined to the instance directory, which is how Tomcat
# resolves it, and an absolute one is resolved as the JVM PID sees it.
tomcat_app_bases() {
    local pid="$1" fsd b
    fsd="$(_vfix "$2")"
    [ -r "$fsd/conf/server.xml" ] || return 0
    grep -o 'appBase="[^"]*"' "$fsd/conf/server.xml" 2>/dev/null \
        | sed 's/^appBase="//; s/"$//' | while IFS= read -r b; do
        [ -n "$b" ] || continue
        case "$b" in /*) _rview "$pid" "$b" ;; *) _vfix "$fsd/$b" ;; esac
    done
}

# tomcat_doc_bases PID FSDIR APPBASEFILE -> every docBase this instance
# configures, from server.xml and from the per-host context files under
# conf/<engine>/<host>/. An absolute value is resolved as the JVM PID sees it.
# A relative value is resolved against each appBase listed in APPBASEFILE and
# against the instance directory; only the candidates that exist are printed,
# so no single layout is assumed.
tomcat_doc_bases() {
    local pid="$1" fsd basefile="$3" f b a v
    fsd="$(_vfix "$2")"
    for f in "$fsd"/conf/server.xml "$fsd"/conf/*/*/*.xml; do
        f="$(_vfix "$f")"
        [ -r "$f" ] || continue
        grep -o 'docBase="[^"]*"' "$f" 2>/dev/null \
            | sed 's/^docBase="//; s/"$//' | while IFS= read -r b; do
            [ -n "$b" ] || continue
            case "$b" in
                /*) _rview "$pid" "$b" ;;
                *)  v="$(_vfix "$fsd/$b")"; [ -e "$v" ] && printf '%s\n' "$v"
                    [ -r "$basefile" ] || continue
                    while IFS= read -r a; do
                        [ -n "$a" ] || continue
                        v="$(_vfix "$a/$b")"; [ -e "$v" ] && printf '%s\n' "$v"
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
    case "$ab" in /proc/[0-9]*/root*) ab="$(_vfix "$ab")" ;; esac
    [ -d "$ab" ] || { printf '%s%s %s: n/a (%s)\n' "$ind" "$lbl" "$ab" "$(_path_why "$ab")"; return; }
    printf '%s%s %s\n' "$ind" "$lbl" "$ab"
    for w in "$ab"/*/WEB-INF/lib; do
        case "$w" in /proc/[0-9]*/root*) w="$(_vfix "$w")" ;; esac
        [ -d "$w" ] && list_jars "$ind  " "$w" "$cap"
    done
    for w in "$ab"/*/WEB-INF/classes; do
        case "$w" in /proc/[0-9]*/root*) w="$(_vfix "$w")" ;; esac
        [ -d "$w" ] && _appclass_record "dir|$w"
    done
    for w in "$ab"/*.war; do
        [ -f "$w" ] && _appclass_record "archive|$w"
    done
}

# ---- discovery (internal; emits nothing) --------------------------------------
# Populates:
#   D_JVM_PIDS    pids of JVM processes, WhaTap-attached ones first
#   D_MARKED      pids among them that carry a WhaTap attach marker
#   D_JAVA_EXES   java launchers to run -version on, one per line
#   D_JAVA_OTHER  "path|why it is not run|VM library|pid" for every other JVM binary
#   D_AGENT_JARS  "path|pid|source" records for whatap agent jars
#   D_HOMES       "path|pid|source" records for agent home candidates; pid is
#                 the process the path belongs to ("" = a fixed absolute path,
#                 "self" = the collector's own environment)
#   D_JVM_WHY     "pid|test that settled it" records
#   D_JVM_NOARGS  pids found only by a mapped VM library: no options in /proc
#   D_ENV_UNREAD / D_CWD_UNREAD  JVM pids whose environ / cwd this run cannot
#                 read, so an agent injected there cannot be seen
#   D_PROC_SCANNED / D_PROC_SKIPPED / D_MAPS_UNREAD  what the /proc walk covered
D_JVM_PIDS=""
D_JVM_WHY=""
D_JVM_NOARGS=""
D_ENV_UNREAD=""
D_CWD_UNREAD=""
D_PROC_SCANNED=0
D_PROC_SKIPPED=0
D_MAPS_UNREAD=0
D_TASKJVM=""
D_MARKED=""
D_JAVA_EXES=""
D_JAVA_OTHER=""
D_JAVA_UNCONF=""
D_JAVA_KEYS=""
D_AGENT_JARS=""
D_HOMES=""

# _rec_pid PATH PID -> the pid stored with a path record. An absolute path of a
# JVM that shares this namespace is a fixed path; any other keeps its owner.
_rec_pid() {
    case "$1" in
        /*) case "$2" in
                ''|self) printf '' ;;
                *) if [ "$(_ns_of "$2")" = same ]; then printf ''; else printf '%s' "$2"; fi ;;
            esac ;;
        *)  printf '%s' "$2" ;;
    esac
}

_add_home() {  # _add_home PATH PID SOURCE
    local p="$1" pid s="$3"
    [ -n "$p" ] || return
    pid="$(_rec_pid "$p" "$2")"
    case "$_nl$D_HOMES" in *"$_nl$p|$pid|"*) return ;; esac
    D_HOMES="$D_HOMES$_nl$p|$pid|$s"
}

_add_jar() {  # _add_jar PATH PID SOURCE
    local p="$1" pid s="$3"
    [ -n "$p" ] || return
    pid="$(_rec_pid "$p" "$2")"
    case "$_nl$D_AGENT_JARS" in *"$_nl$p|$pid|"*) return ;; esac
    D_AGENT_JARS="$D_AGENT_JARS$_nl$p|$pid|$s"
}

# _add_java PATH SOURCE [LIB] [PID] -> a JVM binary. It is kept to be run
# with -version only when BOTH the name it was found under and the file it
# resolves to are named java: a symlink named vshell that points at java is a
# program invoked as vshell, and a binary named java that resolves to
# something else is not a JDK launcher. Any other binary (jsvc, a native
# launcher that embeds the VM) is recorded with its VM library and never
# executed. Dedup key: the resolved target.
_add_java() {
    local p="$1" src="$2" lib="$3" pid="$4" k
    [ -n "$p" ] || return
    [ -x "$p" ] || return
    k="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_JAVA_KEYS" in *"|$k|"*) return ;; esac
    D_JAVA_KEYS="$D_JAVA_KEYS|$k|"
    if _is_java_launcher "$k" && _is_java_launcher "$p"; then
        D_JAVA_EXES="$D_JAVA_EXES$_nl$p"
    else
        D_JAVA_OTHER="$D_JAVA_OTHER$_nl$p|$src|$lib|$pid"
    fi
}

# _find_jvms -> D_JVM_PIDS, D_JVM_WHY, D_JVM_NOARGS and the walk counts.
#
# Four tests, in order: comm; the resolved exe; a JVM-only WHOLE argument on
# the command line (a shell wrapper that carries a java invocation as text
# keeps it in one argument, and interpreters are excluded outright); and last
# a libjvm.so / libj9vm*.so mapping in /proc/<pid>/maps. The fourth exists for
# a native launcher that creates the VM in its own process through
# JNI_CreateJavaVM (Axway API Gateway's vshell is one): its comm and exe are
# its own and the JVM options never reach /proc/<pid>/cmdline, but the VM
# library is mapped into it like into every JVM. The mapping is matched, not a
# name list of launchers (CONTRACT rule 2).
#
# Scale with the host, not per process: the exe links come from one ls, the
# argument test from one grep -z over every cmdline, comm and the verdicts
# from one awk, and the maps test from one grep over the processes the first
# three did not settle; a fork per pid does not scale to a large host.
_find_jvms() {
    local f_out f_map
    f_out="$(_tmp d.out)"; f_map="$(_tmp d.map)"
    _jvm_walk "$f_out"
    _jvm_maps "$f_out" "$f_map"
    _jvm_tasks
    _jvm_verdicts "$f_out" "$f_map"
}

# _jvm_walk OUT -> tests 1 to 3 over every /proc entry into OUT: "J|pid|why"
# for a JVM, "U|pid|comm|exe" for a process they did not settle, "S|pid" for
# an unreadable cmdline, "N|count"; sets D_PROC_SCANNED and D_PROC_SKIPPED.
_jvm_walk() {
    local f_out="$1" f_pids f_exe f_arg zok=0 kind pid c exe n
    f_pids="$(_tmp d.pids)"; f_exe="$(_tmp d.exe)"; f_arg="$(_tmp d.arg)"
    printf '%s\n' /proc/[0-9]* | cut -d/ -f3 | grep -E '^[0-9]+$' > "$f_pids"
    # path lists are written by the printf builtin and fed through xargs, so
    # no single exec carries one argument per process (ARG_MAX on a large host)
    printf '%s\n' /proc/[0-9]*/exe > "$(_tmp d.exelist)" 2>/dev/null
    printf '%s\n' /proc/[0-9]*/cmdline > "$(_tmp d.cmdlist)" 2>/dev/null
    _bounded_in "$(_tmp d.exelist)" xargs ls -l 2>/dev/null \
        | sed -n 's|^.* /proc/\([0-9][0-9]*\)/exe -> \(.*\)$|\1 \2|p' > "$f_exe"
    if printf 'a\000-Xmx1\000' | grep -qz '^-Xmx' 2>/dev/null; then
        zok=1
        _bounded_in "$(_tmp d.cmdlist)" xargs grep -laz -E '^-(javaagent:|Xmx|Xms|XX:|Dcatalina\.|Djava\.|Dwhatap\.)' 2>/dev/null \
            | cut -d/ -f3 > "$f_arg"
    else
        true > "$f_arg"
    fi
    _bounded awk -v self="$$" -v fexe="$f_exe" -v farg="$f_arg" '
        BEGIN {
            while ((getline l < fexe) > 0) { i = index(l, " "); exe[substr(l, 1, i - 1)] = substr(l, i + 1) }
            while ((getline l < farg) > 0) arg[l] = 1
        }
        {
            pid = $1
            scanned++
            if (pid == self) next
            f = "/proc/" pid "/cmdline"
            if ((getline x < f) < 0) { print "S|" pid; next }
            close(f)
            c = ""; g = "/proc/" pid "/comm"
            if ((getline c < g) <= 0) c = ""
            close(g)
            e = (pid in exe) ? exe[pid] : ""
            b = e; sub(/ \(deleted\)$/, "", b); sub(/.*\//, "", b)
            if (c ~ /^(java|java\..*|jsvc.*|jexec.*)$/) { print "J|" pid "|comm is " c; next }
            if (b ~ /^(java|jsvc|jsvc\.exec)$/) { print "J|" pid "|resolved exe is " e; next }
            if (b ~ /^(sh|bash|dash|ksh|zsh|busybox|python.*|perl|ruby|node|nodejs|awk|sed|grep|tr)$/) next
            # a wrapper that runs java as a child keeps the JVM options on its
            # own argv (sudo java -Xmx...); its comm names the wrapper, and its
            # exe is often unreadable (setuid, another user)
            if (c ~ /^(sudo|su|runuser|doas|timeout|nohup|env|setsid|nice|ionice|taskset|chrt|stdbuf|numactl|strace|ltrace|time|unshare|nsenter|tini|dumb-init|xargs|watch|script|flock|sg|systemd-run|start-stop-daem|daemon|su-exec|gosu)$/) next
            if (pid in arg) { print "J|" pid "|a JVM-only whole argument on the command line"; next }
            print "U|" pid "|" c "|" e
        }
        END { print "N|" scanned + 0 }' "$f_pids" > "$f_out" 2>/dev/null
    n="$(grep '^N|' "$f_out")"
    D_PROC_SCANNED="${n#N|}"
    # an unreadable cmdline of a process that has since exited (this run's own
    # short-lived commands among them) is not a blind spot; one still listed is
    D_PROC_SKIPPED=0
    for pid in $(grep '^S|' "$f_out" | cut -d'|' -f2); do
        [ -d "/proc/$pid" ] && D_PROC_SKIPPED=$((D_PROC_SKIPPED + 1))
    done
    # grep -z absent (an old busybox): the argument test per remaining process
    if [ "$zok" = 0 ]; then
        grep '^U|' "$f_out" | while IFS='|' read -r kind pid c exe; do
            tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" \
                | grep -qE '^-(javaagent:|Xmx|Xms|XX:|Dcatalina\.|Djava\.|Dwhatap\.)' \
                && printf 'J|%s|a JVM-only whole argument on the command line\n' "$pid"
        done > "$(_tmp d.out2)"
        cat "$(_tmp d.out2)" >> "$f_out"
        grep -v '^U|' "$f_out" > "$(_tmp d.out3)"
        grep '^U|' "$f_out" | while IFS='|' read -r kind pid c exe; do
            grep -q "^J|$pid|" "$(_tmp d.out2)" || printf 'U|%s|%s|%s\n' "$pid" "$c" "$exe"
        done >> "$(_tmp d.out3)"
        cat "$(_tmp d.out3)" > "$f_out"
    fi
}

# _jvm_maps OUT MAP -> test 4: the pids among the unsettled ones in OUT whose
# maps name a VM library, into MAP; sets D_MAPS_UNREAD.
_jvm_maps() {
    local f_out="$1" f_map="$2"
    # the maps test, over the unsettled processes only
    grep '^U|' "$f_out" | cut -d'|' -f2 | sed 's|^\(.*\)$|/proc/\1/maps|' > "$(_tmp d.maplist)"
    if [ -s "$(_tmp d.maplist)" ]; then
        _bounded_in "$(_tmp d.maplist)" xargs grep -l -E '/(libjvm\.so|libj9vm[^/[:space:]]*\.so)' \
            2>"$(_tmp d.maperr)" | cut -d/ -f3 > "$f_map"
        D_MAPS_UNREAD="$(grep -c 'ermission denied' "$(_tmp d.maperr)" 2>/dev/null)"
    else
        true > "$f_map"
    fi
}

# _jvm_tasks -> the candidates by VM thread name among the processes whose
# maps were not readable, into $(_tmp d.tjvm); sets D_TASK_*.
_jvm_tasks() {
    # A process whose maps this run cannot read (another user's, as non-root)
    # still names its threads in /proc/<pid>/task/*/comm, which is readable by
    # everyone, and a JVM's own threads have fixed names. Verified on HotSpot
    # (OpenJDK 17): VM Thread, Signal Dispatch(er), Reference Handl(er),
    # VM Periodic Tas(k), C1/C2 CompilerThre(ad), GC Thread#<n>; comm is cut at
    # 15 characters. OpenJ9 names (JIT Compilation, Signal Reporter,
    # Finalizer maste(r)) are taken from its thread list and not verified on a
    # running OpenJ9. A process is a candidate when TWO distinct names match,
    # so one thread a program happens to call "VM Thread" is not enough. One
    # glob of every thread's comm file, one grep, one awk; the line cap is a
    # safety net, and hitting it (or the time cap) is reported and blocks the
    # goals that rest on the scan.
    true > "$(_tmp d.tjvm)"
    D_TASK_TOTAL=0; D_TASK_READ=0; D_TASK_CAPPED=""
    sed -n 's|^grep: /proc/\([0-9][0-9]*\)/maps: .*ermission denied.*$|\1|p' "$(_tmp d.maperr)" 2>/dev/null | sort -u > "$(_tmp d.denied)"
    if [ -s "$(_tmp d.denied)" ]; then
        D_TASK_TOTAL="$(grep -c . "$(_tmp d.denied)")"
        printf '%s\n' /proc/[0-9]*/task/*/comm 2>/dev/null > "$(_tmp d.tasks.all)"
        if [ "$(wc -l < "$(_tmp d.tasks.all)" | tr -d ' ')" -gt 500000 ]; then
            D_TASK_CAPPED="cap of 500000 thread entries reached"
        fi
        head -n 500000 "$(_tmp d.tasks.all)" | awk 'NR == FNR { d[$0] = 1; next } { split($0, a, "/"); if (a[3] in d) print }' \
            "$(_tmp d.denied)" - > "$(_tmp d.tasks)"
        D_TASK_READ="$(awk '{ split($0, a, "/"); if (!(a[3] in s)) { s[a[3]] = 1; n++ } } END { print n + 0 }' "$(_tmp d.tasks)")"
        if [ -s "$(_tmp d.tasks)" ]; then
            _bounded_in "$(_tmp d.tasks)" xargs grep -H -x -E 'VM Thread|Signal Dispatch|Reference Handl|VM Periodic Tas|C[12] CompilerThre|GC Thread#[0-9]*|JIT Compilation|Signal Reporter|Finalizer maste' \
                > "$(_tmp d.hits)" 2>/dev/null
            [ "$?" = 124 ] && D_TASK_CAPPED="${D_TASK_CAPPED:+$D_TASK_CAPPED; }the thread-name grep timed out at ${CMD_TIMEOUT}s"
            awk '{ i = index($0, "/comm:"); f = substr($0, 1, i - 1); nm = substr($0, i + 6); split(f, a, "/")
                   sub(/#[0-9]*$/, "#", nm); k = a[3] SUBSEP nm
                   if (!(k in s)) { s[k] = 1; n[a[3]]++ } }
                 END { for (p in n) if (n[p] >= 2) print p }' "$(_tmp d.hits)" > "$(_tmp d.tjvm)"
        fi
    fi
}

# _jvm_verdicts OUT MAP -> D_JVM_PIDS, D_JVM_WHY, D_JVM_NOARGS, D_TASKJVM from
# the walk (OUT), the maps test (MAP) and the thread-name candidates.
_jvm_verdicts() {
    local f_out="$1" f_map="$2" kind pid why exe lib c _mapset _tjset _inmap _intj
    D_TASKJVM=""
    # both verdict lists as words, so the loop below tests them without a fork
    _mapset=" $(tr '\n' ' ' < "$f_map" 2>/dev/null)"
    _tjset=" $(tr '\n' ' ' < "$(_tmp d.tjvm)" 2>/dev/null)"
    while IFS='|' read -r kind pid why exe; do
        case "$kind" in
            J) ;;
            U) c="$why"
               case "$_mapset" in *" $pid "*) _inmap=1 ;; *) _inmap=0 ;; esac
               case "$_tjset" in *" $pid "*) _intj=1 ;; *) _intj=0 ;; esac
               if [ "$_inmap" = 1 ]; then
                   lib="$(_jvm_maps_lib "$pid")"
                   [ -n "$lib" ] || continue
                   why="$lib mapped in /proc/$pid/maps (comm ${c:-n/a}, exe ${exe:-n/a (not readable)}, no JVM argument on the command line)"
               elif [ "$_intj" = 1 ]; then
                   why="JVM thread names in /proc/$pid/task/*/comm; /proc/$pid/maps not readable by this run (comm ${c:-n/a}, exe ${exe:-n/a (not readable)}, no JVM argument on the command line; a candidate, never attached or signalled)"
                   D_TASKJVM="$D_TASKJVM $pid"
               else
                   continue
               fi
               D_JVM_NOARGS="$D_JVM_NOARGS $pid" ;;
            *) continue ;;
        esac
        D_JVM_PIDS="$D_JVM_PIDS $pid"
        D_JVM_WHY="$D_JVM_WHY$_nl$pid|$why"
    done < "$f_out"
}

discover() {
    progress "discovery: JVM processes, agent jars, agent homes, java binaries"
    local pid exe v a rest marked _jr lib

    _find_jvms
    for pid in $D_JVM_PIDS; do
        _note_ns "$pid"
        _env_readable "$pid" || D_ENV_UNREAD="$D_ENV_UNREAD $pid"
        readlink "/proc/$pid/cwd" >/dev/null 2>&1 || D_CWD_UNREAD="$D_CWD_UNREAD $pid"
    done

    # A JVM found by its mapped VM library has no options in /proc. When --jcmd
    # was passed, recover them from the VM before anything reads them; the
    # WhaTap attach marker below is one of the things read.
    if [ "$OPT_JCMD" != 0 ] && [ -n "$D_JVM_NOARGS" ]; then
        progress "discovery: jcmd argument recovery for JVMs whose options are not in /proc"
        _jr=0
        for pid in $D_JVM_NOARGS; do
            if ! _jvm_confirmed "$pid"; then _flag jcmd_fail "argument recovery of pid $pid not attempted: ${_NOTCONF}"; continue; fi
            _jr=$((_jr + 1))
            if [ "$_jr" -gt 4 ]; then _flag jcmd_fail "argument recovery of pid $pid not attempted (cap: 4 processes)"; continue; fi
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

    # the binary of every JVM; only a java launcher is ever executed
    for pid in $D_JVM_PIDS; do
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
        [ -n "$exe" ] || continue
        exe="${exe% (deleted)}"
        # only a confirmed JVM's binary is a Java runtime
        if ! _jvm_confirmed "$pid"; then
            D_JAVA_UNCONF="$D_JAVA_UNCONF$_nl$exe|binary of pid $pid"
            continue
        fi
        if [ "$(_ns_of "$pid")" = other ]; then
            D_JAVA_OTHER="$D_JAVA_OTHER$_nl$exe|binary of pid $pid, under another root or mount namespace|$(_jvm_maps_lib "$pid")|$pid"
            continue
        fi
        lib=""
        _is_java_launcher "$exe" || lib="$(_jvm_maps_lib "$pid")"
        # the name it was invoked under is argv[0]: a symlink named vshell
        # that points at java is a vshell to this collector, and is not run
        a="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | head -n 1)"
        if [ -n "$a" ] && ! _is_java_launcher "$a" && _is_java_launcher "$exe"; then
            case "$D_JAVA_OTHER" in *"$_nl$exe|binary of pid $pid"*) ;; *)
                D_JAVA_OTHER="$D_JAVA_OTHER$_nl$exe|binary of pid $pid, invoked as $a|$(_jvm_maps_lib "$pid")|$pid" ;; esac
            continue
        fi
        _add_java "$exe" "binary of pid $pid" "$lib" "$pid"
    done

    # agent jars and homes from every JVM's own arguments and environment
    for pid in $D_JVM_PIDS; do
        while IFS= read -r a; do
            [ -n "$a" ] || continue
            _add_jar "$a" "$pid" "-javaagent of pid $pid"
            _add_home "$(dirname "$a" 2>/dev/null)" "$pid" "directory of the -javaagent jar of pid $pid"
        done <<EOF
$(_all_jvm_args "$pid" | grep -i '^-javaagent:.*whatap' | sed 's/^-javaagent://; s/=.*$//')
EOF
        v="$(_jvm_sysprop "$pid" whatap.home)"
        [ -n "$v" ] && _add_home "$v" "$pid" "-Dwhatap.home of pid $pid"
        v="$(_jvm_sysprop "$pid" whatap.config.file)"
        [ -n "$v" ] && _add_home "$(dirname "$v" 2>/dev/null)" "$pid" "directory of -Dwhatap.config.file of pid $pid"
        v="$(_proc_env "$pid" WHATAP_CONFIG_FILE)"
        [ -n "$v" ] && _add_home "$(dirname "$v" 2>/dev/null)" "$pid" "directory of env WHATAP_CONFIG_FILE of pid $pid"
        v="$(_proc_env "$pid" WHATAP_HOME)"
        [ -n "$v" ] && _add_home "$v" "$pid" "env WHATAP_HOME of pid $pid"
        v="$(_proc_env "$pid" WHATAP_JAVA_AGENT_PATH)"
        if [ -n "$v" ]; then
            _add_jar "$v" "$pid" "env WHATAP_JAVA_AGENT_PATH of pid $pid"
            _add_home "$(dirname "$v" 2>/dev/null)" "$pid" "directory of env WHATAP_JAVA_AGENT_PATH of pid $pid"
        fi
    done

    # collector shell environment
    [ -n "${WHATAP_HOME:-}" ] && _add_home "$WHATAP_HOME" self "env WHATAP_HOME (collector shell)"
    [ -n "${WHATAP_CONFIG_FILE:-}" ] && _add_home "$(dirname "$WHATAP_CONFIG_FILE" 2>/dev/null)" self "directory of env WHATAP_CONFIG_FILE (collector shell)"

    # operator auto-injection volume (whatap-operator mounts the agent here)
    [ -e /whatap-agent/whatap.agent.java.jar ] && _add_jar /whatap-agent/whatap.agent.java.jar "" "path /whatap-agent/whatap.agent.java.jar"
    [ -d /whatap-agent ] && _add_home /whatap-agent "" "path /whatap-agent"

    # java binaries on PATH, JAVA_HOME, and common install roots (shallow globs)
    for v in java jsvc; do
        exe="$(command -v "$v" 2>/dev/null)"
        [ -n "$exe" ] && _add_java "$exe" "$v on PATH"
    done
    [ -n "${JAVA_HOME:-}" ] && _add_java "$JAVA_HOME/bin/java" "JAVA_HOME (collector shell)"
    for exe in /usr/lib/jvm/*/bin/java /usr/java/*/bin/java /opt/java*/bin/java /opt/jdk*/bin/java; do
        [ -x "$exe" ] && _add_java "$exe" "install root glob"
    done
    D_AGENT_JARS="$(printf '%s\n' "$D_AGENT_JARS" | grep .)"
    D_HOMES="$(printf '%s\n' "$D_HOMES" | grep .)"
    D_JAVA_EXES="$(printf '%s\n' "$D_JAVA_EXES" | grep .)"
    D_JAVA_OTHER="$(printf '%s\n' "$D_JAVA_OTHER" | grep .)"
    D_JAVA_UNCONF="$(printf '%s\n' "$D_JAVA_UNCONF" | grep .)"
}

# ---- per-process agent resolution ---------------------------------------------
# _agent_jar_of PID -> the first whatap -javaagent jar reaching PID, as written
_agent_jar_of() {
    _all_jvm_args "$1" | grep -i '^-javaagent:.*whatap' | head -n1 | sed 's/^-javaagent://; s/=.*$//'
}

# _conf_of PID -> "config path|how it was chosen|home|how the home was chosen",
# every path as the process writes it (a relative one is relative to its
# working directory). The order is the one the README "Config" row describes.
# "whatap.conf" is the file name used when -Dwhatap.config is unset: an assumed
# default, and the "how" field says so. Sections E, G, J and _log_targets all
# ask; the record is resolved once per pid and cached under the run's
# directory (a single line: every part is a single-line lookup).
_conf_of() {
    local c l
    c="${_tmp_dir:+$_tmp_dir/conf.$1}"
    [ -n "$c" ] || { _conf_resolve "$1"; return 0; }
    [ -f "$c" ] || _conf_resolve "$1" > "$c" 2>/dev/null
    if IFS= read -r l < "$c"; then printf '%s\n' "$l"; else _conf_resolve "$1"; fi
    return 0
}
_conf_resolve() {
    local pid="$1" cf src hm hsrc cn
    cf="$(_proc_env "$pid" WHATAP_CONFIG_FILE)"; src="env WHATAP_CONFIG_FILE"
    if [ -z "$cf" ]; then cf="$(_jvm_sysprop "$pid" whatap.config.file)"; src="-Dwhatap.config.file"; fi
    hm="$(_jvm_sysprop "$pid" whatap.home)"; hsrc="-Dwhatap.home"
    if [ -z "$hm" ]; then
        hm="$(_agent_jar_of "$pid")"
        if [ -n "$hm" ]; then hm="$(dirname "$hm")"; hsrc="directory of the -javaagent jar (-Dwhatap.home unset)"
        else hm="."; hsrc="working directory of the JVM (-Dwhatap.home unset, no -javaagent jar path)"; fi
    fi
    if [ -z "$cf" ]; then
        cn="$(_jvm_sysprop "$pid" whatap.config)"
        if [ -n "$cn" ]; then src="<home>/<-Dwhatap.config>"
        else cn="whatap.conf"; src="<home>/whatap.conf, the assumed default file name (-Dwhatap.config unset)"; fi
        case "$cn" in /*) cf="$cn" ;; *) cf="$hm/$cn" ;; esac
    fi
    printf '%s|%s|%s|%s\n' "$cf" "$src" "$hm" "$hsrc"
}

# _conf_value FILE KEY -> the value of the last KEY= line of a config file.
# A line counts when it is optional whitespace, KEY compared literally
# (whatap.server.host is not whatapXserverXhost), optional whitespace, "=";
# a "#" line or "KEY:" is not one. The value is what follows the "=", without
# the whitespace around it and without any CR. Whitespace is the [[:space:]]
# of the C locale, spelled out for awks without character classes.
_conf_value() {
    _K="$2" awk 'BEGIN { k = ENVIRON["_K"]; n = length(k); f = 0 }
        { l = $0; sub(/^[ \t\v\f\r]*/, "", l)
          if (substr(l, 1, n) != k) next
          r = substr(l, n + 1); if (r !~ /^[ \t\v\f\r]*=/) next
          v = r; f = 1 }
        END { if (!f) exit
              sub(/^[ \t\v\f\r]*=[ \t\v\f\r]*/, "", v); sub(/[ \t\v\f\r]*$/, "", v); gsub(/\r/, "", v)
              print v }' "$(_vfix "$1")" 2>/dev/null
}

# _setting_of PID KEY CONFVIEW -> "value|where it was read" from the first of
# -DKEY, env KEY and the config file that carries the key; status 1 when none
# does. The order is this collector's; each source found is named.
_setting_of() {
    local v
    v="$(_jvm_sysprop "$1" "$2")"; [ -n "$v" ] && { printf '%s|-D%s\n' "$v" "$2"; return 0; }
    v="$(_proc_env "$1" "$2")"; [ -n "$v" ] && { printf '%s|env %s\n' "$v" "$2"; return 0; }
    if [ -n "$3" ] && [ -r "$3" ]; then
        v="$(_conf_value "$3" "$2")"; [ -n "$v" ] && { printf '%s|%s= in the config file\n' "$v" "$2"; return 0; }
    fi
    return 1
}

# _log_targets -> one "pid|log dir as written|dir view|log name|how chosen"
# record per agent log location: for each attached JVM from its log_root and
# log_name settings, then for each home candidate no attached JVM covers. A
# location nothing configures is <home>/logs with log name "whatap", the
# assumed defaults, and the record says so.
_log_targets() {
    local pid rec cf hm cv lr ln how d dv seen="|"
    for pid in $D_MARKED; do
        rec="$(_conf_of "$pid")"; cf="${rec%%|*}"; hm="$(printf '%s' "$rec" | cut -d'|' -f3)"
        cv="$(_rpath "$pid" "$cf")"
        lr="$(_setting_of "$pid" log_root "$cv")"
        if [ -n "$lr" ]; then d="${lr%%|*}"; how="log_root=$d (${lr#*|})"
        else d="$hm/logs"; how="<home>/logs, the assumed default (no log_root in -D, env or the config file)"; fi
        ln="$(_setting_of "$pid" log_name "$cv")"
        if [ -n "$ln" ]; then how="$how; log_name=${ln%%|*} (${ln#*|})"; ln="${ln%%|*}"
        else ln=whatap; how="$how; log name whatap, the assumed default (no log_name set)"; fi
        dv="$(_rpath "$pid" "$d")"
        # a relative log_root that is not under the working directory is
        # tried under the home as well; the record names the one that exists
        if [ -z "$dv" ] && [ -n "$lr" ]; then
            case "$d" in /*) ;; *)
                dv="$(_rpath "$pid" "$hm/$d")"
                [ -n "$dv" ] && { how="$how; not under the JVM working directory, found under the home"; d="$hm/$d"; } ;;
            esac
        fi
        printf '%s|%s|%s|%s|%s\n' "$pid" "$d" "$dv" "$ln" "$how"
        seen="$seen$dv|"
    done
    printf '%s\n' "$D_HOMES" | while IFS='|' read -r d pid rec; do
        [ -n "$d" ] || continue
        case " $D_MARKED " in *" $pid "*) continue ;; esac
        dv="$(_rpath "$pid" "$d/logs")"
        [ -n "$dv" ] && case "$seen" in *"|$dv|"*) continue ;; esac
        printf '%s|%s|%s|%s|%s\n' "$pid" "$d/logs" "$dv" whatap "<home>/logs and log name whatap, the assumed defaults (home from $rec; no attached JVM names its settings)"
    done
}


# _proc_start PID -> the process start time in UTC, from /proc/<pid>/stat
# (starttime, in clock ticks since boot) and btime. ps -o lstart prints nothing
# under busybox.
_HZ=""
_proc_start() {
    local st t b s
    st="$(cat "/proc/$1/stat" 2>/dev/null)"
    [ -n "$st" ] || { echo "n/a (/proc/$1/stat not readable)"; return; }
    st="${st##*") "}"
    t="$(printf '%s\n' "$st" | awk '{print $20}')"
    b="$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)"
    [ -n "$_HZ" ] || _HZ="$(getconf CLK_TCK 2>/dev/null)"
    case "$t" in ''|*[!0-9]*) echo "n/a (no starttime in /proc/$1/stat)"; return ;; esac
    case "$b" in ''|*[!0-9]*) echo "n/a (no btime in /proc/stat)"; return ;; esac
    case "$_HZ" in ''|*[!0-9]*|0) echo "n/a (getconf CLK_TCK unavailable; starttime $t ticks)"; return ;; esac
    s=$((b + t / _HZ))
    date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch $s (date -d unavailable)"
}

# _visibility -> empty when every JVM's arguments and environment were read;
# otherwise what was not, for the reason of a goal that rests on them.
_visibility() {
    local n w="" p na=""
    if [ -n "$D_ENV_UNREAD" ]; then
        n="$(echo $D_ENV_UNREAD | wc -w | tr -d ' ')"
        w="/proc/<pid>/environ of $n JVM process(es) not readable (pid$D_ENV_UNREAD), so an agent or config injected through JAVA_TOOL_OPTIONS or WHATAP_* there is not visible"
    fi
    if [ "${D_PROC_SKIPPED:-0}" -gt 0 ]; then
        w="${w:+$w; }/proc/<pid>/cmdline of $D_PROC_SKIPPED process(es) not readable"
    fi
    # a JVM found by its VM library or VM thread names passed its options in
    # memory; unless jcmd read them back, a -javaagent among them is unseen
    for p in $D_JVM_NOARGS; do
        case " $_JCMD_RECOVERED " in *" $p "*) ;; *) na="$na $p" ;; esac
    done
    if [ -n "$na" ]; then
        if [ "$OPT_JCMD" = 0 ]; then w="${w:+$w; }the VM options of pid$na are in no /proc file and were not read (rerun with --jcmd)"
        else
            local nc="" nt=""
            for p in $na; do if _jvm_confirmed "$p"; then nt="$nt $p"; else nc="$nc $p"; fi; done
            [ -n "$nt" ] && w="${w:+$w; }the VM options of pid$nt are in no /proc file and jcmd did not return them"
            [ -n "$nc" ] && w="${w:+$w; }the VM options of pid$nc are in no /proc file; jcmd not attempted: not confirmed as a JVM"
        fi
    fi
    [ -n "$D_TASK_CAPPED" ] && w="${w:+$w; }candidate scan of the processes whose maps are not readable incomplete: $D_TASK_CAPPED"
    printf '%s' "$w"
}

# _find_classes DIR OUT DEPTH -> the WEB-INF/classes directories under DIR
# (first 12) into OUT, and in $(_tmp find.note) the bounds of the search and
# whether one was hit. The search stops descending at each WEB-INF it meets,
# visits at most _FIND_CAP directories, and runs under the per-command cap; a
# bound that was hit makes the result partial, and the note says so.
_FIND_CAP=20000
_find_classes() {
    local d out="$2" depth="$3" st note part=""
    d="$(_vfix "$1")"
    { _bounded find -H "$d" -maxdepth "$depth" -type d \( -name WEB-INF -print -prune -o -print \) 2>/dev/null; echo "ggt-rc $?"; } \
        | awk -v cap="$_FIND_CAP" '/^ggt-rc / { print; exit } { n++; if (n > cap) { print "ggt-cap"; exit } if ($0 ~ /\/WEB-INF$/) print }' \
        > "$(_tmp find.out)" 2>/dev/null
    st="$(tail -n 1 "$(_tmp find.out)")"
    case "$st" in
        "ggt-rc 0") ;;
        "ggt-rc 124") part="find timed out at ${CMD_TIMEOUT}s" ;;
        "ggt-rc "*) part="find exit ${st#ggt-rc }: a directory below was not readable" ;;
        ggt-cap) part="the cap of $_FIND_CAP directories was reached" ;;
        *) part="the search did not complete" ;;
    esac
    grep -v '^ggt-' "$(_tmp find.out)" | while IFS= read -r w; do
        [ -d "$w/classes" ] && printf '%s\n' "$w/classes"
    done | head -n 12 > "$out" 2>/dev/null
    note="depth $depth, at most $_FIND_CAP directories, ${CMD_TIMEOUT}s"
    [ -n "$part" ] && note="$note; partial: $part"
    printf '%s' "$note" > "$(_tmp find.note)"
}

# Helper scripts for probe, written once per run under the run's directory
# and run as `sh FILE ARGS`: probe bounds a file with timeout(1), where a shell
# function needs the shared watchdog, and that watchdog crashes bash 5.2 when
# bash reads the script itself from stdin (`bash -s`, as in kubectl exec).
# Session lists for section J take a space-separated pid or port list; a
# list with no match says so.
_write_helpers() {
    cat > "$(_tmp ls_head.sh)" 2>/dev/null <<'EOF_LS'
ls -la "$1/" 2>/dev/null | head -n "$2"
EOF_LS
    cat > "$(_tmp ss_pids.sh)" 2>/dev/null <<'EOF_H'
ss -tnp 2>/dev/null | awk -v P="$1" '
    BEGIN { n = split(P, a, " "); for (i = 1; i <= n; i++) w["pid=" a[i] ","] = 1 }
    NR == 1 { print; next }
    { for (k in w) if (index($0, k)) { print; c++; break } }
    END { if (!c) print "(no session)" }' | head -n 60
EOF_H
    cat > "$(_tmp ss_ports.sh)" 2>/dev/null <<'EOF_H'
ss -tnp 2>/dev/null | awk -v P="$1" '
    BEGIN { n = split(P, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    NR == 1 { print; next }
    { p = $5; sub(/.*:/, "", p); if (p in w) { print; c++ } }
    END { if (!c) print "(no session)" }' | head -n 60
EOF_H
    cat > "$(_tmp ns_pids.sh)" 2>/dev/null <<'EOF_H'
netstat -tnp 2>/dev/null | awk -v P="$1" '
    BEGIN { n = split(P, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    NR <= 2 { print; next }
    { p = $7; sub(/\/.*/, "", p); if (p in w) { print; c++ } }
    END { if (!c) print "(no session)" }' | head -n 60
EOF_H
    cat > "$(_tmp ns_ports.sh)" 2>/dev/null <<'EOF_H'
netstat -tnp 2>/dev/null | awk -v P="$1" '
    BEGIN { n = split(P, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    NR <= 2 { print; next }
    { p = $5; sub(/.*:/, "", p); if (p in w) { print; c++ } }
    END { if (!c) print "(no session)" }' | head -n 60
EOF_H
    cat > "$(_tmp proc_tcp.sh)" 2>/dev/null <<'EOF_H'
h=""
for p in $1; do h="$h $(printf '%04X' "$p")"; done
awk -v H="$h" '
    BEGIN { n = split(H, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
    FNR == 1 { next }
    { r = $3; sub(/.*:/, "", r); if (r in w) { print FILENAME ": " $0; c++ } }
    END { if (!c) print "(no row)" }' /proc/net/tcp /proc/net/tcp6 2>/dev/null | head -n 40
EOF_H
}

# _probe_ls LABEL DIR N -> the first N lines of ls -la DIR, bounded; a
# symlinked directory is listed through to its target
_probe_ls() { probe "$1" sh "$(_tmp ls_head.sh)" "$(_vfix "$2")" "$3"; }

# ---- report body ---------------------------------------------------------------
# One _rep_* function per section, called in order by run_report. They declare
# no locals: the variables are run_report's, and a section reads only the ones
# it sets itself, the D_* discovery results and _nm.

# [1] capability preamble: every downstream "command not found" is
# pre-explained here.
_rep_env() {
    section "Collection environment"
    if [ -n "${BASH_VERSION:-}" ]; then fact "shell: bash $BASH_VERSION"
    else fact "shell: POSIX sh (non-bash)"; fi
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in java javap jstack jcmd jps unzip od sha256sum ss netstat lsof readlink timeout stat awk tr xargs getconf; do
        # the path is read back from a file rather than a second lookup in
        # a $(...); without the file (no run directory) it is looked up again
        if [ -n "$_tmp_dir" ] && command -v "$t" > "$_tmp_dir/cmdv" 2>/dev/null && IFS= read -r _p < "$_tmp_dir/cmdv"; then
            printf '        %-12s present (%s)\n' "$t" "$_p"
        elif command -v "$t" >/dev/null 2>&1; then printf '        %-12s present (%s)\n' "$t" "$(command -v "$t")"
        else printf '        %-12s absent\n' "$t"; fi
    done
    fact "per-command cap: ${CMD_TIMEOUT}s; run deadline: ${RUN_DEADLINE}s"
    fact "Tier 2 flags: --threads=$OPT_THREADS  --jcmd=$OPT_JCMD (0 = not requested)"
    fact "library detail flags: --library=${OPT_LIBS:-none}  --library-all=$OPT_LIBALL  --class=${OPT_CLASSES:-none}"
    fact "application class flags: --appclasses=$OPT_APPCLASSES  --class-refs=${OPT_REFS:-none}"
    fact "supplied dump files (--dump-file): $(printf '%s\n' "$OPT_DUMPS" | grep -c .)"
}

# [2] A. host / platform
_rep_host() {
    section "A. Host / platform"
    probe "kernel" uname -srm
    read_proc "os-release" /etc/os-release
    probe "cpu count (nproc)" nproc
    _mem="$(grep -E '^(MemTotal|MemAvailable|SwapTotal)' /proc/meminfo 2>/dev/null)"
    if [ -n "$_mem" ]; then
        fact "memory (/proc/meminfo):"
        printf '%s\n' "$_mem" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
    else
        fact "memory: n/a (/proc/meminfo not readable)"
    fi
    read_proc "loadavg" /proc/loadavg
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
    probe "self cgroup (first 5 lines)" head -n 5 /proc/self/cgroup
    probe "pid 1 command" sh -c "tr '\0' ' ' < /proc/1/cmdline | cut -c1-160"
    probe "local time" date
    probe "UTC time" date -u
    probe "timedatectl" timedatectl
}

# [3] B. Java runtimes present on this host
_rep_runtimes() {
    section "B. Java runtimes discovered"
    if [ -z "$D_JAVA_EXES" ] && [ -z "$D_JAVA_OTHER" ] && [ -z "$D_JAVA_UNCONF" ]; then
        fact "java binaries: none found among running processes, PATH, JAVA_HOME, /usr/lib/jvm, /usr/java, /opt/java*, /opt/jdk*"
    fi
    fact "env JAVA_HOME (collector shell): ${JAVA_HOME:-not set}"
    _jc=0
    while IFS= read -r jv; do
        [ -n "$jv" ] || continue
        _jc=$((_jc + 1))
        if [ "$_jc" -gt 6 ]; then
            fact "-- $(printf '%s\n' "$D_JAVA_EXES" | grep -c .) java launchers found; the ones after the first 6 are not detailed"
            break
        fi
        _jr="$(readlink -f "$jv" 2>/dev/null || echo "$jv")"
        fact "-- java binary: $jv"
        fact "   resolves to: $_jr"
        _rel="$(dirname "$(dirname "$_jr")")/release"
        if [ -r "$_rel" ]; then
            fact "   $_rel:"
            grep -E '^(JAVA_VERSION|IMPLEMENTOR|JAVA_VERSION_DATE|OS_ARCH)=' "$_rel" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "   release file: n/a ($(_path_why "$_rel"))"
        fi
        jvprobe "   version (separate short-lived JVM)" "$jv" -version
    done <<EOF
$D_JAVA_EXES
EOF
    if [ -n "$D_JAVA_OTHER" ]; then
        fact "JVM binaries not run with -version (the name found or the file it resolves to is not java; listed only):"
        printf '%s\n' "$D_JAVA_OTHER" | head -n 12 | while IFS='|' read -r _p _s _lib _opid; do
            [ -n "$_p" ] || continue
            printf '        -- %s   <- %s\n' "$_p" "$_s"
            if [ -n "$_lib" ]; then
                printf '           VM library mapped: %s\n' "$_lib"
                # the release file of the runtime that library belongs to,
                # looked for in the four directories above it, as the JVM
                # that maps it sees them
                _d="${_lib%/*}"; _rf=""
                for _i in 1 2 3 4; do
                    _d="${_d%/*}"; [ -n "$_d" ] || break
                    _rv="$(_rpath "$_opid" "$_d/release")" && [ -r "$_rv" ] && { _rf="$_rv"; break; }
                done
                if [ -n "$_rf" ]; then
                    printf '           %s:\n' "$_rf"
                    grep -E '^(JAVA_VERSION|IMPLEMENTOR|JAVA_VERSION_DATE|OS_ARCH)=' "$_rf" 2>/dev/null | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                else
                    printf '           release file: none readable in the four directories above the VM library\n'
                fi
            fi
        done
    fi

    if [ -n "$D_JAVA_UNCONF" ]; then
        fact "binaries of processes detected as JVMs but not confirmed (no libjvm or libj9vm mapping read; not listed as runtimes, not executed):"
        printf '%s\n' "$D_JAVA_UNCONF" | head -n 12 | while IFS='|' read -r _p _s; do
            [ -n "$_p" ] && printf '        -- %s   <- %s\n' "$_p" "$_s"
        done
    fi
}

# [4] C. WhaTap Java agent artifacts on disk
_rep_artifacts() {
    section "C. WhaTap agent artifacts on disk"
    if [ -z "$D_AGENT_JARS" ]; then
        fact "whatap agent jars: none named by -javaagent or env WHATAP_JAVA_AGENT_PATH of any JVM whose arguments were read, and no /whatap-agent/whatap.agent.java.jar"
    else
        fact "whatap agent jars discovered (read as files; never loaded or executed):"
        printf '%s\n' "$D_AGENT_JARS" | while IFS='|' read -r p pid src; do
            [ -n "$p" ] || continue
            printf '        -- %s   <- %s\n' "$p" "$src"
            fsp="$(_rpath "$pid" "$p")"
            if [ -z "$fsp" ]; then
                _w="$(_rwhy "$pid" "$p")"
                printf '           n/a (%s)\n' "$_w"
                case "$_w" in
                    "permission denied"*) _flag agent_unread "agent jar $p ($src): $_w" ;;
                    *) _flag agent_absent "agent jar $p ($src): $_w" ;;
                esac
                continue
            fi
            _n="$(_rnote "$pid" "$p" "$fsp")"; [ -n "$_n" ] && printf '           %s\n' "$_n"
            if [ ! -r "$fsp" ]; then
                printf '           n/a (permission denied: %s)\n' "$fsp"
                _flag agent_unread "agent jar $p ($src): permission denied: $fsp"
                continue
            fi
            printf '           resolves to: %s\n' "$(readlink -f "$fsp" 2>/dev/null || echo "$fsp")"
            file_facts "           " "$fsp"
            jar_version "           " "$fsp"
            # obtained only when the jar opens as an archive
            _zlist "$fsp" 'whatap/*' > /dev/null; _zrc=$?
            if [ "$_zrc" = 0 ] || [ "$_zrc" = 11 ]; then _flag agent_read "agent jar $p"
            else
                printf '           archive listing: n/a (%s)\n' "$(_zwhy)"
                _flag agent_unread "agent jar $p ($src): $(_zwhy)"
            fi
        done
    fi
    # the helper CLI (whatap.javahelper) ships beside the agent and its output
    # is quoted in weaving cases, so its presence and build are facts too
    if [ -n "$D_AGENT_JARS" ]; then
        _comp="$(printf '%s\n' "$D_AGENT_JARS" | while IFS='|' read -r p pid src; do
            [ -n "$p" ] || continue
            fsd="$(_rpath "$pid" "$(dirname "$p")")"
            [ -n "$fsd" ] || continue
            _names "$fsd" | grep -i -E 'helper|whatap' | grep -v -x -F "$(basename "$p")" \
                | head -n 20 | while IFS= read -r _l; do printf '%s/%s\n' "$fsd" "$_l"; done
        done | sort -u)"
        if [ -n "$_comp" ]; then
            fact "companion files next to an agent jar (names containing helper or whatap):"
            printf '%s\n' "$_comp" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "companion files next to an agent jar (names containing helper or whatap): none in the readable jar directories"
        fi
    fi
}

# [5] D. JVM processes and how the agent is attached
_rep_jvms() {
    section "D. JVM processes and agent attachment"
    _n="$(echo $D_JVM_PIDS | wc -w | tr -d ' ')"
    # what an empty result rests on: the walk that produced it and the tests
    # applied to each entry
    fact "/proc walk: $D_PROC_SCANNED numeric pid entries scanned, $D_PROC_SKIPPED skipped (cmdline unreadable)"
    fact "tests applied to each, in order: /proc/<pid>/comm; resolved /proc/<pid>/exe; a JVM-only whole argument in /proc/<pid>/cmdline; a libjvm.so or libj9vm*.so mapping in /proc/<pid>/maps"
    [ "${D_MAPS_UNREAD:-0}" -gt 0 ] && fact "/proc/<pid>/maps not readable for $D_MAPS_UNREAD of the processes the first three tests did not settle; thread names in /proc/<pid>/task/*/comm read for $D_TASK_READ of $D_TASK_TOTAL of them${D_TASK_CAPPED:+ (partial: $D_TASK_CAPPED)}; two or more JVM thread names in:${D_TASKJVM:- none of them}"
    [ -n "$D_ENV_UNREAD" ] && fact "JVM processes whose /proc/<pid>/environ is not readable by this run:$D_ENV_UNREAD"
    if [ "${_n:-0}" -eq 0 ]; then
        fact "JVM processes: none found in /proc (this pid namespace)"
    else
        fact "JVM processes found: $_n ($_nm carrying a WhaTap attach marker; those are listed first, detailing first 20)"
        _shown=0
        for pid in $D_JVM_PIDS; do
            _shown=$((_shown + 1))
            [ "$_shown" -gt 20 ] && { fact "-- remaining $((_n - 20)) JVM processes not detailed (cap: 20)"; break; }
            # one read of the status file: "ppid|uid / state / threads|rss"
            _pst="$(awk '/^PPid:/{p=$2} /^Uid:/{u=$2} /^State:/{s=$2} /^Threads:/{t=$2} /^VmRSS:/{r=$2" "$3}
                         END{print p "|" u " / " s " / " t "|" r}' "/proc/$pid/status" 2>/dev/null)"
            printf '        -- pid %s (ppid %s)\n' "$pid" "${_pst%%|*}"
            printf '           detected as a JVM by: %s\n' "$(printf '%s\n' "$D_JVM_WHY" | awk -F'|' -v p="$pid" '$1==p{sub(/^[^|]*\|/,""); print; exit}')"
            printf '           comm: %s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           exe: %s\n' "$(readlink "/proc/$pid/exe" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            printf '           root and mount namespace: %s\n' "$(case "$(_ns_of "$pid")" in (same) echo "the collector's own" ;; (other) echo "not the collector's (root $(readlink "/proc/$pid/root" 2>/dev/null); paths are read through /proc/$pid/root)" ;; (*) echo "n/a (/proc/$pid/root not readable)" ;; esac)"
            _pst="${_pst#*|}"
            printf '           uid/state/threads: %s\n' "${_pst%%|*}"
            printf '           VmRSS: %s\n' "${_pst#*|}"
            printf '           start time(UTC): %s\n' "$(_proc_start "$pid")"
            printf '           cwd: %s\n' "$(readlink "/proc/$pid/cwd" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            # where the boot banner and any SIGQUIT dump land
            printf '           stdout (fd 1) -> %s\n' "$(readlink "/proc/$pid/fd/1" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            printf '           stderr (fd 2) -> %s\n' "$(readlink "/proc/$pid/fd/2" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            printf '           cmdline (verbatim):\n'
            tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            if ! _env_readable "$pid"; then
                printf '           environ: n/a (permission denied: /proc/%s/environ); JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS and _JAVA_OPTIONS of this process were not read\n' "$pid"
            fi
            # a JVM the mapping test found holds no options in /proc; state
            # whether they were read back from the VM, and with which command
            case " $D_JVM_NOARGS " in
                *" $pid "*)
                    case " $_JCMD_RECOVERED " in
                        *" $pid "*)
                            printf '           VM options: no JVM-only argument in /proc/%s/cmdline (the arguments above are the launcher'"'"'s own); %s option lines read back from the VM with jcmd VM.command_line and VM.system_properties, which the sections below read\n' \
                                "$pid" "$(grep -c . "$(_tmp "jcmdargs.$pid")" 2>/dev/null)" ;;
                        *)
                            printf '           VM options: no JVM-only argument in /proc/%s/cmdline (the arguments above are the launcher'"'"'s own); the options the launcher passed to the VM were not read\n' "$pid" ;;
                    esac ;;
            esac
            # every -javaagent reaching this JVM, from all argument sources
            _ja="$(_all_jvm_args "$pid" | grep -c '^-javaagent:')"
            printf '           -javaagent options reaching this JVM: %s\n' "${_ja:-0}"
            _all_jvm_args "$pid" | grep '^-javaagent:' | while IFS= read -r _l; do
                _jp="$(printf '%s' "$_l" | sed 's/^-javaagent://; s/=.*$//')"
                _jv="$(_rpath "$pid" "$_jp")"
                if [ -n "$_jv" ]; then
                    _ex="file present"; _jn="$(_rnote "$pid" "$_jp" "$_jv")"; [ -n "$_jn" ] && _ex="$_ex, $_jn"
                else
                    _ex="n/a: $(_rwhy "$pid" "$_jp")"
                fi
                printf '             %s   (%s)\n' "$_l" "$_ex"
            done
            for _ev in JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS JAVA_OPTS CATALINA_OPTS JAVA_OPTIONS; do
                _v="$(_proc_env "$pid" "$_ev")"
                if [ -n "$_v" ]; then printf '           env %s=%s\n' "$_ev" "$(printf '%s' "$_v" | cut -c1-400)"; fi
            done
            # server type markers
            _smk=0
            printf '           server markers:\n'
            for _sp in catalina.base catalina.home catalina.useNaming jboss.home.dir jboss.server.name jboss.server.base.dir jetty.base jetty.home jeus.home weblogic.Name domain.home com.sun.aas.instanceRoot com.sun.aas.installRoot com.sun.aas.instanceName com.sun.aas.domainName was.install.root server.root java.protocol.handler.pkgs spring.profiles.active; do
                _v="$(_jvm_sysprop "$pid" "$_sp")"
                if [ -n "$_v" ]; then _smk=$((_smk + 1)); printf '             -D%s=%s\n' "$_sp" "$(printf '%s' "$_v" | cut -c1-200)"; fi
            done
            if _all_jvm_args "$pid" | grep -qi 'org.springframework.boot.loader'; then
                _smk=$((_smk + 1)); printf '             spring boot loader on the arguments: yes\n'
            fi
            [ "$_smk" = 0 ] && printf '             none of the listed server properties is set on this JVM\n'
            # program identity: the option values (-cp, -jar, --module-path ...)
            # are skipped so a classpath is never reported as a main class
            _jarv="$(_all_jvm_args "$pid" | awk 'p=="-jar"{print; exit} {p=$0}')"
            case " $D_JVM_NOARGS " in
                *" $pid "*)
                    _jc="$(cat "$(_tmp "jcmdmain.$pid")" 2>/dev/null)"
                    if [ -n "$_jc" ]; then
                        printf '           program: java_command recorded by the VM: %s\n' "$(printf '%s' "$_jc" | cut -c1-200)"
                    else
                        printf '           program: n/a (the VM'"'"'s java_command was not read)\n'
                    fi
                    continue ;;
            esac
            if [ -n "$_jarv" ]; then
                printf '           program: executable jar %s\n' "$_jarv"
            else
                _mc="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | awk '
                    NR==1 {p=$0; next}
                    (p=="-cp"||p=="-classpath"||p=="--class-path"||p=="-p"||p=="--module-path"||p=="-jar"||p=="-m"||p=="--module"||p=="--add-opens"||p=="--add-exports") {p=$0; next}
                    substr($0,1,1)=="-" {p=$0; next}
                    {print; exit}')"
                printf '           program: main class %s\n' "$(printf '%s' "${_mc:-n/a (no main class on the command line)}" | cut -c1-200)"
            fi
        done
    fi
}

# [6] E. Agent home resolution and configuration
_rep_conf() {
    section "E. Agent home resolution and configuration"
    fact "config path resolution applied by this collector: env WHATAP_CONFIG_FILE, else -Dwhatap.config.file, else <home>/<-Dwhatap.config, or whatap.conf when unset>; <home> is -Dwhatap.home, else the directory of the -javaagent jar, else the JVM working directory; a relative path is joined to the working directory of the JVM"
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "per-process resolution: n/a (no JVM carrying a WhaTap attach marker)"
    fi
    _ec=0
    for pid in $D_MARKED; do
        _ec=$((_ec + 1))
        if [ "$_ec" -gt 8 ]; then
            fact "-- remaining $((_nm - 8)) attached JVMs not detailed in this section (cap: 8)"
            # their config is still part of the conf goal
            for _p2 in $D_MARKED; do
                _r2="$(_conf_of "$_p2")"; _v2="$(_rpath "$_p2" "${_r2%%|*}")"
                [ -n "$_v2" ] && [ -r "$_v2" ] && _flag conf_read "${_r2%%|*}"
            done
            break
        fi
        fact "-- pid $pid"
        _rec="$(_conf_of "$pid")"
        _cf="${_rec%%|*}"; _rest="${_rec#*|}"; _src="${_rest%%|*}"; _rest="${_rest#*|}"
        _hm="${_rest%%|*}"; _hsrc="${_rest#*|}"
        _envok=1; _env_readable "$pid" || _envok=0
        fact "   config path: $_cf   <- $_src"
        [ "$_envok" = 0 ] && fact "   env WHATAP_CONFIG_FILE: n/a (permission denied: /proc/$pid/environ); the path above is chosen from what was readable"
        fact "   home: $_hm   <- $_hsrc"
        _fsc="$(_rpath "$pid" "$_cf")"
        if [ -n "$_fsc" ]; then
            _n="$(_rnote "$pid" "$_cf" "$_fsc")"; [ -n "$_n" ] && fact "   config file $_n"
            if [ -r "$_fsc" ]; then
                _file_lines first "   config file (verbatim)" "$_fsc" 400
                conf_bytes "   config file byte facts" "$_fsc"
                _flag conf_read "$_cf"
            else
                fact "   config file: n/a (permission denied: $_fsc)"
                _flag conf_unread "config $_cf of pid $pid: permission denied: $_fsc"
            fi
        else
            _w="$(_rwhy "$pid" "$_cf")"
            fact "   config file: n/a ($_w)"
            case "$_w" in
                "path not found"*)
                    if [ "$_envok" = 1 ]; then _flag conf_absent "$_cf (pid $pid)"
                    else _flag conf_unread "config of pid $pid: $_cf not found, and env WHATAP_CONFIG_FILE, which comes first, could not be read (permission denied: /proc/$pid/environ)"; fi ;;
                *)  _flag conf_unread "config $_cf of pid $pid: $_w" ;;
            esac
        fi
        # whatap-related environment of THIS process, verbatim
        if [ "$_envok" = 1 ]; then
            _wenv="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
                | grep -iE '^(WHATAP|whatap\.|license=|accesskey=|OKIND=|PODNAME=|POD_NAME=|NODE_NAME=|NODE_IP=)' \
                | cut -c1-400)"
            if [ -n "$_wenv" ]; then
                fact "   whatap-related environment variables of this process:"
                printf '%s\n' "$_wenv" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            else
                fact "   whatap-related environment variables of this process: none set"
            fi
            _we="$(_proc_env "$pid" whatap.env)"
            if [ -n "$_we" ]; then fact "   env whatap.env: $(printf '%s' "$_we" | cut -c1-400)"; fi
        else
            fact "   environ: n/a (permission denied: /proc/$pid/environ)"
        fi
        _wsp="$(_all_jvm_args "$pid" | grep -i '^-Dwhatap' | cut -c1-300)"
        if [ -n "$_wsp" ]; then
            fact "   whatap system properties on the arguments of this process:"
            printf '%s\n' "$_wsp" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
        else
            fact "   whatap system properties on the arguments of this process: none set"
        fi
        # other files the agent reads or writes in its home
        _fsh="$(_rpath "$pid" "$_hm")"
        if [ -n "$_fsh" ] && [ -d "$_fsh" ] && [ -r "$_fsh" ]; then
            _n="$(_rnote "$pid" "$_hm" "$_fsh")"; [ -n "$_n" ] && fact "   home $_n"
            _probe_ls "   home listing (first 60 lines)" "$_fsh" 60
            _flag agent_home_read "home $_hm"
            for _sf in security.conf paramkey.txt; do
                if [ -f "$(_vfix "$_fsh/$_sf")" ]; then
                    fact "   $_sf: present, $(_fsize "$_fsh/$_sf") bytes (content not collected)"
                else
                    fact "   $_sf: absent"
                fi
            done
            _ccp="$(_proc_env "$pid" WHATAP_CONTAINER_CONF_PATH)"
            if [ -n "$_ccp" ]; then
                fact "   env WHATAP_CONTAINER_CONF_PATH: $_ccp"
                _ccv="$(_rpath "$pid" "$_ccp/container.conf")"
                if [ -n "$_ccv" ]; then _file_lines first "   container.conf" "$_ccv" 40
                else fact "   container.conf: n/a ($(_rwhy "$pid" "$_ccp/container.conf"))"; fi
            else
                _file_lines first "   container.conf" "$_fsh/container.conf" 40
            fi
        elif [ -n "$_fsh" ]; then
            fact "   home listing: n/a (permission denied: $_fsh)"
            _flag agent_unread "home $_hm of pid $pid: permission denied: $_fsh"
        else
            _w="$(_rwhy "$pid" "$_hm")"
            fact "   home listing: n/a ($_w)"
            case "$_w" in "permission denied"*) _flag agent_unread "home $_hm of pid $pid: $_w" ;; esac
        fi
    done
    if [ -n "$D_HOMES" ]; then
        fact "all agent home candidates discovered (union of every source):"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _pid _s; do
            [ -n "$_p" ] || continue
            _v="$(_rpath "$_pid" "$_p")"
            if [ -n "$_v" ] && [ -d "$_v" ] && [ -r "$_v" ] && [ -x "$_v" ]; then
                _st="readable directory"; _n="$(_rnote "$_pid" "$_p" "$_v")"; [ -n "$_n" ] && _st="$_st, $_n"
                _flag agent_home_read "home $_p"
            elif [ -n "$_v" ] && [ ! -d "$_v" ]; then
                _st="n/a (not a directory: $_v)"
            elif [ -n "$_v" ]; then
                _st="n/a (permission denied: $_v)"
                _flag agent_unread "home $_p ($_s): permission denied: $_v"
            else
                _w="$(_rwhy "$_pid" "$_p")"; _st="n/a ($_w)"
                case "$_w" in
                    "permission denied"*) _flag agent_unread "home $_p ($_s): $_w" ;;
                    *) _flag agent_absent "home $_p ($_s): $_w" ;;
                esac
            fi
            printf '        %s   <- %s: %s\n' "$_p" "$_s" "$_st"
            # a home no attached JVM resolved: its whatap.conf, the assumed
            # default file name, since no process names another
            case " $D_MARKED " in *" $_pid "*) continue ;; esac
            case "$_s" in *" of pid "*) continue ;; esac
            [ -n "$_v" ] && [ -d "$_v" ] || continue
            if [ -e "$_v/whatap.conf" ]; then
                if [ -r "$_v/whatap.conf" ]; then
                    _file_lines first "        $_p/whatap.conf (assumed default file name; verbatim)" "$_v/whatap.conf" 400
                    _flag conf_read "$_p/whatap.conf"
                else
                    printf '        %s/whatap.conf: n/a (permission denied)\n' "$_p"
                    _flag conf_unread "$_p/whatap.conf: permission denied"
                fi
            else
                _w="$(_path_why "$_v/whatap.conf")"
                case "$_w" in "path not found"*) _flag conf_absent_home "$_p/whatap.conf" ;; *) _flag conf_unread "$_p/whatap.conf: $_w" ;; esac
            fi
        done
    fi
}

# [7] F. Application libraries visible to the target JVMs
_rep_libs() {
    section "F. Application libraries visible to the target JVMs"
    fact "excluded from every list below: any entry whose name contains whatap.agent (the -javaagent jar)"
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "n/a (no JVM carrying a WhaTap attach marker)"
    fi
    _pc=0
    for pid in $D_MARKED; do
        _pc=$((_pc + 1))
        [ "$_pc" -gt 4 ] && { fact "-- remaining attached JVMs not detailed in this section (cap: 4)"; break; }
        fact "-- pid $pid"
        _LIBSINK="$(_tmp libs.$pid)"
        true > "$_LIBSINK" 2>/dev/null
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
                _fsl="$(_rpath "$pid" "$_l")"
                if [ -n "$_fsl" ]; then
                    _n="$(_rnote "$pid" "$_l" "$_fsl")"; [ -n "$_n" ] && printf '               %s\n' "$_n"
                else
                    printf '               n/a (%s)\n' "$(_rwhy "$pid" "$_l")"
                fi
                case "$_l" in
                    *.jar) [ -n "$_fsl" ] && _path_record "file|$_fsl" ;;
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
            _fsj="$(_rpath "$pid" "$_jar")"
            if [ -n "$_fsj" ]; then
                _n="$(_rnote "$pid" "$_jar" "$_fsj")"; [ -n "$_n" ] && fact "     $_n"
                bootjar_facts "             " "$_fsj"
                _appclass_record "archive|$_fsj"
                fact "   libraries packed inside that jar:"
                jar_entries "             " "$_fsj" 'BOOT-INF/lib/*' 200
                jar_entries "             " "$_fsj" 'WEB-INF/lib/*' 200
            else
                fact "     n/a ($(_rwhy "$pid" "$_jar"))"
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
            if [ -n "$(_bounded find "$_cwd" -maxdepth 1 -name '*.class' -type f 2>/dev/null | head -n 1)" ]; then
                fact "     class files are present directly under it"
                _appclass_record "dir|$_cwd"
                _cwdn=$((_cwdn + 1))
            fi
            [ "$_cwdn" = 0 ] && fact "     no BOOT-INF/classes, WEB-INF/classes, classes directory or top-level class file under it"
        else
            fact "   working directory of this JVM: n/a ($(_rwhy "$pid" .))"
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
            for _cand in "$(_proc_env "$pid" DOMAIN_HOME)" .; do
                [ -n "$_cand" ] || continue
                _fsc="$(_rpath "$pid" "$_cand")"
                [ -n "$_fsc" ] && [ -d "$_fsc/servers/$_wn" ] && { _wdh="$_cand"; break; }
            done
            if [ -n "$_wdh" ]; then
                _fsd="$(_rpath "$pid" "$_wdh")"
                [ "$_wdh" = . ] && _wdh="$_fsd"
                fact "   weblogic domain directory (weblogic.Name=$_wn; from DOMAIN_HOME or the process working directory): $_wdh"
                [ -d "$_fsd/lib" ] && list_jars "             " "$_fsd/lib" 60
                _wst="$_fsd/servers/$_wn/tmp/_WL_user"
                if [ -d "$_wst" ]; then
                    _probe_ls "     staging directory servers/$_wn/tmp/_WL_user (deployment units, first 60)" "$_wst" 60
                    _find_classes "$_wst" "$(_tmp wl)" 7
                    if [ -s "$(_tmp wl)" ]; then
                        fact "     WEB-INF/classes directories under the staging area ($(cat "$(_tmp find.note)"); first 12):"
                        while IFS= read -r _w; do
                            [ -n "$_w" ] || continue
                            printf '             %s\n' "$_w"
                            _appclass_record "dir|$_w"
                            [ -d "${_w%/classes}/lib" ] && list_jars "               " "${_w%/classes}/lib" 120
                        done < "$(_tmp wl)"
                    else
                        fact "     WEB-INF/classes directories under the staging area: none found ($(cat "$(_tmp find.note)"))"
                    fi
                else
                    fact "     staging directory servers/$_wn/tmp/_WL_user: absent"
                fi
                # the deployment sources config.xml names (archives or exploded dirs)
                _wcx="$(_vfix "$_fsd/config/config.xml")"
                if [ -r "$_wcx" ]; then
                    _wsp="$(grep -o '<source-path>[^<]*</source-path>' "$_wcx" 2>/dev/null | sed 's/<source-path>//; s/<\/source-path>//' | sort -u | head -n 40)"
                    if [ -n "$_wsp" ]; then
                        fact "     deployment source paths in config/config.xml (<source-path>, first 40):"
                        printf '%s\n' "$_wsp" | while IFS= read -r _sp1; do
                            [ -n "$_sp1" ] || continue
                            case "$_sp1" in /*) _spa="$(_rview "$pid" "$_sp1")" ;; *) _spa="$(_vfix "$_fsd/$_sp1")" ;; esac
                            _spc="$(_vfix "$_spa/WEB-INF/classes")"
                            if [ -d "$_spc" ]; then
                                printf '             %s   (exploded, WEB-INF/classes present)\n' "$_sp1"; _appclass_record "dir|$_spc"
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
                    fact "     config/config.xml: n/a ($(_path_why "$_fsd/config/config.xml"))"
                fi
            else
                fact "   weblogic domain directory (weblogic.Name=$_wn): n/a (neither DOMAIN_HOME nor the process working directory holds servers/$_wn readable by this run)"
            fi
        fi
        # catalina.base and catalina.home are one directory in a single-instance
        # install and two in a split install; list each distinct path once
        _seen_d=""
        for _d in "$_cb" "$_ch"; do
            [ -n "$_d" ] || continue
            case "$_seen_d" in *"|$_d|"*) continue ;; esac
            _seen_d="$_seen_d|$_d|"
            _fsd="$(_rpath "$pid" "$_d")"
            [ -n "$_fsd" ] || { fact "   server directory (catalina): $_d — n/a ($(_rwhy "$pid" "$_d"))"; continue; }
            fact "   server directory (catalina): $_d"
            list_jars "             " "$_fsd/lib" 120
            # the appBase of an instance is whatever server.xml says it is;
            # <instance>/webapps is only the shipped default, so both are read
            _abs="$(printf '%s\n' "$_fsd/webapps"; tomcat_app_bases "$pid" "$_fsd")"
            _abs="$(printf '%s\n' "$_abs" | grep . | sort -u)"
            printf '%s\n' "$_abs" | while IFS= read -r _ab; do
                [ -n "$_ab" ] && webapp_roots "             " "$_ab" 120
            done
            # a context can point its docBase outside every appBase
            printf '%s\n' "$_abs" > "$(_tmp abs)" 2>/dev/null
            _dbs="$(tomcat_doc_bases "$pid" "$_fsd" "$(_tmp abs)" | sort -u)"
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
            _fsd="$(_rpath "$pid" "$_d")"
            [ -n "$_fsd" ] || { fact "   server directory (jetty): $_d — n/a ($(_rwhy "$pid" "$_d"))"; continue; }
            fact "   server directory (jetty): $_d"
            list_jars "             " "$_fsd/lib" 120
            webapp_roots "             " "$_fsd/webapps" 120 "webapps directory"
        done
        if [ -n "$_jb" ]; then
            fact "   server directory (jboss.home.dir): $_jb"
            _fsd="$(_rpath "$pid" "$_jb")"
            if [ -n "$_fsd" ]; then
                list_jars "             " "$_fsd/lib" 60
                for _dd in "$_fsd"/server/*/deploy "$_fsd"/server/*/lib "$_fsd"/standalone/deployments; do
                    [ -d "$_dd" ] && list_deploy "             " "$_dd"
                done
            else
                fact "     n/a ($(_rwhy "$pid" "$_jb"))"
            fi
        fi
        if [ -n "$_jsb" ]; then
            _fsd="$(_rpath "$pid" "$_jsb")"
            if [ -n "$_fsd" ]; then fact "   server base directory (jboss.server.base.dir): $_jsb"; list_deploy "             " "$_fsd/deployments"
            else fact "   server base directory (jboss.server.base.dir): $_jsb — n/a ($(_rwhy "$pid" "$_jsb"))"; fi
        fi
        for _d in "$_je" "$_dh" "$_gr"; do
            [ -n "$_d" ] || continue
            _fsd="$(_rpath "$pid" "$_d")"
            [ -n "$_fsd" ] || { fact "   server directory: $_d — n/a ($(_rwhy "$pid" "$_d"))"; continue; }
            fact "   server directory: $_d"
            _probe_ls "     listing (first 40 lines)" "$_fsd" 40
            [ -d "$_fsd/lib" ] && list_jars "             " "$_fsd/lib" 60
            [ -d "$_fsd/applications" ] && _probe_ls "     applications directory listing (first 40 lines)" "$_fsd/applications" 40
            # these products compose the staging path of a deployment at
            # runtime, so the class roots are found by searching for them
            # rather than by naming a layout
            _find_classes "$_fsd" "$(_tmp wi)" 10
            if [ -s "$(_tmp wi)" ]; then
                fact "     WEB-INF/classes directories under it ($(cat "$(_tmp find.note)"); first 12):"
                while IFS= read -r _w; do
                    [ -n "$_w" ] || continue
                    printf '             %s\n' "$_w"
                    _appclass_record "dir|$_w"
                done < "$(_tmp wi)"
            else
                fact "     WEB-INF/classes directories under it: none found ($(cat "$(_tmp find.note)"))"
            fi
        done
        # 4) open jar files held by the process — covers layouts none of the
        #    above describe (custom launchers, exploded frameworks)
        if ls "/proc/$pid/fd" >/dev/null 2>&1; then
            # the link target is everything after " -> ", so a path with
            # spaces stays whole and a "(deleted)" suffix stays visible
            _oj="$(ls -l "/proc/$pid/fd" 2>/dev/null | sed -n 's/^.* -> //p' | grep -i -E '\.jar( \(deleted\))?$' | grep -v -i 'whatap.agent' | sort -u)"
            _ojn="$(printf '%s\n' "$_oj" | grep -c .)"
            fact "   jar files currently open by this process: ${_ojn:-0} (first 120 printed)"
            printf '%s\n' "$_oj" | head -n 120 | while IFS= read -r _l; do
                [ -n "$_l" ] || continue
                printf '             %s\n' "$_l"
                case "$_l" in *" (deleted)") continue ;; esac
                _lib_record "${_l##*/}"
                _ojv="$(_rpath "$pid" "$_l")"
                [ -n "$_ojv" ] && _path_record "file|$_ojv"
            done
        else
            fact "   open jar files: n/a (permission denied: /proc/$pid/fd)"
        fi
        _LIBSINK=""
    done
}

# [8] G. Agent instrumentation surface and weaving activation
# Four facts side by side: what the application carries (section F), what
# THIS agent build can instrument (read from the installed jar), which
# modules the configuration selects, and which modules the process loaded
# (the agent log lines). README, "The common case".
_rep_weaving() {
    section "G. Agent instrumentation surface and weaving activation"
    # the jars listed here (bundled weaving/*.jar entries, <home>/weaving) are
    # the agent's own, never the application's, so they stay out of the
    # section M inventory
    _ps_saved="$_PATHSINK"; _PATHSINK=""
    if [ -z "$D_AGENT_JARS" ]; then
        fact "bundled instrumentation: n/a (no agent jar discovered)"
    else
        printf '%s\n' "$D_AGENT_JARS" | while IFS='|' read -r p pid src; do
            [ -n "$p" ] || continue
            fsp="$(_rpath "$pid" "$p")"
            [ -n "$fsp" ] || { fact "-- agent jar $p: n/a ($(_rwhy "$pid" "$p"))"; continue; }
            fact "-- agent jar: $p${pid:+ (pid $pid)}"
            fact "   weaving modules bundled in this jar:"
            jar_entries "             " "$fsp" 'weaving/*' 200
            fact "   built-in instrumentation classes in this jar (whatap/agent/asm/*ASM.class):"
            jar_entries "             " "$fsp" 'whatap/agent/asm/*ASM.class' 150
        done
    fi
    if [ -z "$D_HOMES" ]; then
        fact "on-disk weaving and script plugin directories: n/a (no agent home discovered)"
    else
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r home pid src; do
            [ -n "$home" ] || continue
            fshome="$(_rpath "$pid" "$home")"
            if [ -z "$fshome" ]; then
                fact "-- home $home: n/a ($(_rwhy "$pid" "$home"))"
                continue
            fi
            if [ -d "$fshome/weaving" ]; then
                fact "-- on-disk plugin directory $home/weaving:"
                list_jars "             " "$fshome/weaving" 120
            else
                fact "-- on-disk plugin directory $home/weaving: absent"
            fi
            if [ -d "$fshome/plugin" ]; then
                # shellcheck disable=SC2010  # the ls -l line is the fact printed
                _pxl="$(ls -l "$(_vfix "$fshome/plugin")" 2>/dev/null | grep '\.x$')"
                _pxn="$(printf '%s\n' "$_pxl" | grep -c .)"
                fact "-- script plugin directory $home/plugin: ${_pxn:-0} .x file(s) (ls -l lines, first 40):"
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
    _PATHSINK="$_ps_saved"
    # which modules the configuration selects, selected from the config file
    # dumped verbatim in section E
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "instrumentation settings in force: n/a (no JVM carrying a WhaTap attach marker)"
    fi
    for pid in $D_MARKED; do
        _rec2="$(_conf_of "$pid")"; _cf2="${_rec2%%|*}"
        _fsc2="$(_rpath "$pid" "$_cf2")"
        if [ -z "$_fsc2" ]; then
            fact "-- pid $pid instrumentation settings: n/a (config file $_cf2: $(_rwhy "$pid" "$_cf2"))"
        elif [ ! -r "$_fsc2" ]; then
            fact "-- pid $pid instrumentation settings: n/a (permission denied: $_fsc2)"
        else
            _wk="$(grep -nE '^[[:space:]]*(weaving|weaving_reserved|weaving_[A-Za-z0-9_]*|hook_service_[A-Za-z_]*|hook_method_[A-Za-z_]*|hook_component|instrumentation_[A-Za-z0-9_]*|_enable_asm_[a-z]*|_enable_emb_[a-z]*|trace_component_enabled|bci_ignore_packages)[[:space:]]*=' "$_fsc2" 2>/dev/null | head -n 60)"
            if [ -n "$_wk" ]; then
                fact "-- pid $pid instrumentation settings (selected from the config file shown in section E, with line numbers):"
                printf '%s\n' "$_wk" | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            else
                fact "-- pid $pid instrumentation settings: no weaving / hook / instrumentation key set in $_cf2"
            fi
        fi
        _wenvp="$(_all_jvm_args "$pid" | grep -iE '^-D(weaving|hook_|instrumentation_)' | cut -c1-300)"
        [ -n "$_wenvp" ] && printf '%s\n' "$_wenvp" | while IFS= read -r _l; do printf '             (argument) %s\n' "$_l"; done
        # each name in the weaving list, against the weaving/<name>.jar
        # entries of the jar attached to THIS process
        _wlist=""
        [ -n "$_fsc2" ] && [ -r "$_fsc2" ] && _wlist="$(grep -aE '^[[:space:]]*(weaving|weaving_reserved)[[:space:]]*=' "$_fsc2" 2>/dev/null | head -n 2 | sed 's/^[^=]*=//' | tr ',' '\n' | tr -d ' \r')"
        if [ -n "$_wlist" ]; then
            _pjar="$(_agent_jar_of "$pid")"
            _fspj="$(_rpath "$pid" "$_pjar")"
            _cat="$(_tmp "weav.$pid")"
            if [ -z "$_pjar" ]; then
                fact "   weaving list entries vs the jar of this process: n/a (no whatap -javaagent jar on the arguments of pid $pid)"
            elif [ -z "$_fspj" ]; then
                fact "   weaving list entries vs the jar of this process: n/a (agent jar $_pjar: $(_rwhy "$pid" "$_pjar"))"
            else
                _zlist "$_fspj" 'weaving/*' > "$_cat"; _zrc=$?
                if [ "$_zrc" != 0 ] && [ "$_zrc" != 11 ]; then
                    fact "   weaving list entries vs the jar of this process: n/a ($(_zwhy))"
                else
                    fact "   weaving list entries vs the modules bundled in $_pjar:"
                    printf '%s\n' "$_wlist" | while IFS= read -r _m; do
                        [ -n "$_m" ] || continue
                        if grep -qxF "weaving/$_m.jar" "$_cat" 2>/dev/null; then
                            printf '             %-40s bundled in this jar\n' "$_m"
                        else
                            printf '             %-40s no weaving/%s.jar entry in this jar\n' "$_m" "$_m"
                        fi
                    done
                fi
            fi
            _rmtmp "$_cat"
        fi
    done
    # what actually loaded in the running process: the "Weaving" lines of the
    # agent log, at the log locations section I reads
    _log_targets > "$(_tmp logt)" 2>/dev/null
    # the most recent rotated log of each location, kept for section I
    _rotf="$(_tmp logrot)"
    true > "$_rotf" 2>/dev/null
    if [ ! -s "$(_tmp logt)" ]; then
        fact "weaving activity in the agent log: n/a (no JVM carrying a WhaTap attach marker and no agent home discovered)"
    else
        while IFS='|' read -r _lp _ld _lv _ln _lh; do
            [ -n "$_ld" ] || continue
            if [ -z "$_lv" ]; then
                fact "-- $_ld/$_ln.log: n/a ($(_rwhy "$_lp" "$_ld"))"
                continue
            fi
            weaving_lines "$_ld/$_ln.log" "$_lv/$_ln.log"
            _rot2="$(ls -t "$_lv"/"$_ln"-*.log 2>/dev/null | head -n 1)"
            printf '%s\t%s\n' "$_lv/$_ln" "$_rot2" >> "$_rotf" 2>/dev/null
            [ -n "$_rot2" ] && weaving_lines "$(basename "$_rot2") (most recent rotated log by mtime)" "$_rot2"
        done < "$(_tmp logt)"
    fi
}

# [9] H. Application logging stack
_rep_logging() {
    section "H. Application logging stack"
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "logging stack: n/a (no JVM carrying a WhaTap attach marker)"
    else
        _lgp=0
        fact "logging framework configuration properties on the attached JVMs:"
        for pid in $D_MARKED; do
            for _lp in logback.configurationFile logback.statusListenerClass log4j.configuration log4j.configurationFile log4j2.configurationFile java.util.logging.config.file java.util.logging.manager org.jboss.logging.provider; do
                _v="$(_jvm_sysprop "$pid" "$_lp")"
                if [ -n "$_v" ]; then _lgp=$((_lgp + 1)); printf '        pid %s  -D%s=%s\n' "$pid" "$_lp" "$_v"; fi
            done
        done
        [ "$_lgp" = 0 ] && fact "    none of the listed logging properties is set on the attached JVMs"
        # filtered from the library inventory of section F
        fact "logging framework libraries in the section F inventory:"
        for pid in $D_MARKED; do
            _lf="$(_tmp "libs.$pid")"
            if [ ! -s "$_lf" ]; then printf '        pid %s: n/a (no libraries enumerated in section F)\n' "$pid"; continue; fi
            _lgj="$(grep -i -E 'logback|log4j|slf4j|commons-logging|jboss-logging|logstash|tinylog|jcl-over|jul-to' "$_lf" 2>/dev/null | sort -u | head -n 40)"
            if [ -n "$_lgj" ]; then
                printf '%s\n' "$_lgj" | while IFS= read -r _l; do printf '        pid %s  %s\n' "$pid" "$_l"; done
            else
                printf '        pid %s: no logging framework library among %s enumerated entries\n' "$pid" "$(grep -c . "$_lf" 2>/dev/null)"
            fi
        done
        fact "logging configuration files in the working directory of each attached JVM (one level):"
        for pid in $D_MARKED; do
            _cwd="$(cwd_view "$pid")"
            if [ -z "$_cwd" ]; then printf '        pid %s: n/a (%s)\n' "$pid" "$(_rwhy "$pid" .)"; continue; fi
            _lgf="$(_names "$_cwd" | grep -i -E '^(logback|log4j|log4j2|logging)[^/]*\.(xml|properties|yaml|yml|json)$' | head -n 10)"
            if [ -n "$_lgf" ]; then
                printf '%s\n' "$_lgf" | while IFS= read -r _l; do printf '        pid %s  %s/%s\n' "$pid" "$_cwd" "$_l"; done
            else
                printf '        pid %s: none in %s\n' "$pid" "$_cwd"
            fi
        done
        # console destination and on-disk server logs
        fact "console destination and server log directories of each attached JVM:"
        for pid in $D_MARKED; do
            printf '        pid %s stdout -> %s\n' "$pid" "$(readlink "/proc/$pid/fd/1" 2>/dev/null || echo 'n/a (permission denied or gone)')"
            _cb="$(_jvm_sysprop "$pid" catalina.base)"
            _jsb="$(_jvm_sysprop "$pid" jboss.server.base.dir)"
            _lds=0
            for _ld in "${_cb:+$_cb/logs}" "${_jsb:+$_jsb/log}" logs log; do
                [ -n "$_ld" ] || continue
                _fsl="$(_rpath "$pid" "$_ld")"
                [ -n "$_fsl" ] && [ -d "$_fsl" ] || continue
                _lds=$((_lds + 1))
                printf '        pid %s log dir %s (newest 15 by mtime, ls -lt):\n' "$pid" "$_fsl"
                # shellcheck disable=SC2010  # the ls -lt lines are the facts printed
                ls -lt "$_fsl" 2>/dev/null | grep -v '^total ' | head -n 15 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
            done
            [ "$_lds" = 0 ] && printf '        pid %s: no readable directory among%s%s logs, log (under the working directory)\n' "$pid" "${_cb:+ $_cb/logs,}" "${_jsb:+ $_jsb/log,}"
        done
    fi
}

# [10] I. WhaTap agent logs
_rep_agentlogs() {
    section "I. WhaTap agent logs"
    if [ ! -s "$(_tmp logt)" ]; then
        fact "agent log locations: n/a (no JVM carrying a WhaTap attach marker and no agent home discovered)"
    else
        while IFS='|' read -r _lp _ld _lv _ln _lh; do
            [ -n "$_ld" ] || continue
            case "$_lp" in ''|self) fact "-- log dir: $_ld" ;; *) fact "-- log dir: $_ld (pid $_lp)" ;; esac
            fact "   location from: $_lh"
            if [ -z "$_lv" ]; then
                fact "   n/a ($(_rwhy "$_lp" "$_ld"))"
                continue
            fi
            _n="$(_rnote "$_lp" "$_ld" "$_lv")"; [ -n "$_n" ] && fact "   $_n"
            if [ ! -d "$_lv" ] || [ ! -r "$_lv" ]; then
                fact "   n/a ($(_path_why "$_lv"))"
                continue
            fi
            _probe_ls "   listing (first 60 lines)" "$_lv" 60
            _file_lines first "   $_ln.log (first lines)" "$_lv/$_ln.log" 40
            _file_lines last "   $_ln.log (recent lines)" "$_lv/$_ln.log" 200
            # section G listed this location already; ls only when it did not
            _rot=""; _rk=""
            while IFS= read -r _l; do
                case "$_l" in "$_lv/$_ln$_tab"*) _rot="${_l#"$_lv/$_ln$_tab"}"; _rk=1; break ;; esac
            done < "$(_tmp logrot)"
            [ -n "$_rk" ] || _rot="$(ls -t "$_lv"/"$_ln"-*.log 2>/dev/null | head -n 1)"
            if [ -n "$_rot" ]; then
                _file_lines last "   $(basename "$_rot") (most recent rotated log by mtime, recent lines)" "$_rot" 120
            else
                fact "   rotated logs ($_ln-*.log): none present"
            fi
            if [ -r "$_lv/$_ln.log" ]; then
                _wa="$(tail -n 500 "$(_vfix "$_lv/$_ln.log")" 2>/dev/null | grep -oE '\[WA[0-9A-Za-z-]*\]' | sort | uniq -c | sort -rn | head -n 20)"
                if [ -n "$_wa" ]; then
                    fact "   [WA*] codes in the last 500 lines of $_ln.log:"
                    printf '%s\n' "$_wa" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                else
                    fact "   [WA*] codes in the last 500 lines of $_ln.log: none"
                fi
            fi
        done < "$(_tmp logt)"
    fi
}

# [11] J. Network endpoints
_rep_network() {
    section "J. Network endpoints"
    _ports=""; _psrc=""
    if [ "${_nm:-0}" -eq 0 ]; then
        fact "whatap.server.host / whatap.server.port of attached JVMs: n/a (no JVM carrying a WhaTap attach marker)"
    else
        fact "whatap.server.host / whatap.server.port reaching each attached JVM (-D, env, config file):"
        for pid in $D_MARKED; do
            _rec3="$(_conf_of "$pid")"; _cv3="$(_rpath "$pid" "${_rec3%%|*}")"
            for _k in whatap.server.host whatap.server.port; do
                _v="$(_setting_of "$pid" "$_k" "$_cv3")"
                if [ -n "$_v" ]; then
                    printf '        pid %s  %s=%s   <- %s\n' "$pid" "$_k" "${_v%%|*}" "${_v#*|}"
                    [ "$_k" = whatap.server.port ] && _ports="$_ports $(printf '%s' "${_v%%|*}" | tr ',' ' ')"
                else
                    printf '        pid %s  %s: not set in -D, env or a readable config file\n' "$pid" "$_k"
                fi
            done
            for _k in WHATAP_SERVER_HOST WHATAP_SERVER_PORT; do
                _v="$(_proc_env "$pid" "$_k")"
                [ -n "$_v" ] && printf '        pid %s  env %s=%s\n' "$pid" "$_k" "$_v"
                [ -n "$_v" ] && [ "$_k" = WHATAP_SERVER_PORT ] && _ports="$_ports $(printf '%s' "$_v" | tr ',' ' ')"
            done
        done
    fi
    _ports="$(for _p in $_ports; do case "$_p" in ''|*[!0-9]*) ;; *) echo "$_p" ;; esac; done | sort -un | tr '\n' ' ')"
    _ports="${_ports% }"
    if [ -n "$_ports" ]; then _psrc="configured, from the settings above"
    else _psrc="none configured was read"; fi
    # 6600 is listed as well: it is the default a JVM with no port setting
    # uses, and other WhaTap agents on the host use it
    _aports="$(for _p in $_ports 6600; do echo "$_p"; done | sort -un | tr '\n' ' ')"; _aports="${_aports% }"
    fact "server port(s) for the any-owner session list: $_aports (${_ports:+$_ports }$_psrc; 6600 added as the assumed default)"
    # as non-root, ss -p / netstat -p name no owner for another user's socket
    _jpids=""; _jhidden=""; _myuid="$(id -u 2>/dev/null)"
    for _p in $D_JVM_PIDS; do
        _pu="$(awk '/^Uid:/{print $2; exit}' "/proc/$_p/status" 2>/dev/null)"
        if [ "$_myuid" != 0 ] && [ -n "$_pu" ] && [ "$_pu" != "$_myuid" ]; then _jhidden="$_jhidden $_p"
        else _jpids="$_jpids $_p"; fi
    done
    _jpids="$(echo $_jpids)"
    [ -n "$_jhidden" ] && fact "tcp sessions of JVM pid(s)$_jhidden: n/a (owner not visible to uid $_myuid)"
    if have ss; then
        if [ -n "$_jpids" ]; then probe "tcp sessions owned by the JVM processes $_jpids (ss -tnp, matched on pid=)" sh "$(_tmp ss_pids.sh)" "$_jpids"
        elif [ -z "$_jhidden" ]; then fact "tcp sessions owned by the JVM processes: n/a (no JVM process found)"; fi
        probe "tcp sessions to port(s) $_aports, any owner (ss -tnp)" sh "$(_tmp ss_ports.sh)" "$_aports"
    elif have netstat; then
        if [ -n "$_jpids" ]; then probe "tcp sessions owned by the JVM processes $_jpids (netstat -tnp)" sh "$(_tmp ns_pids.sh)" "$_jpids"
        elif [ -z "$_jhidden" ]; then fact "tcp sessions owned by the JVM processes: n/a (no JVM process found)"; fi
        probe "tcp sessions to port(s) $_aports, any owner (netstat -tnp)" sh "$(_tmp ns_ports.sh)" "$_aports"
    else
        fact "socket listing: n/a (command not found: ss, netstat)"
        probe "/proc/net/tcp and tcp6 rows whose remote port is one of $_aports (ports in hex)" sh "$(_tmp proc_tcp.sh)" "$_aports"
    fi
    read_proc "/etc/resolv.conf" /etc/resolv.conf
    _px="${http_proxy:+http_proxy=$http_proxy }${https_proxy:+https_proxy=$https_proxy }${no_proxy:+no_proxy=$no_proxy}"
    fact "proxy variables in the collector shell: ${_px:-none set}"
}

# [12] K. Kubernetes / operator injection context
_rep_k8s() {
    section "K. Kubernetes / operator injection context"
    if [ -d /whatap-agent ]; then
        _probe_ls "/whatap-agent listing (first 40 lines)" /whatap-agent 40
    else
        fact "/whatap-agent: n/a ($(_path_why /whatap-agent))"
    fi
    fact "env WHATAP_JAVA_AGENT_PATH (collector shell): ${WHATAP_JAVA_AGENT_PATH:-not set}"
    fact "env JAVA_TOOL_OPTIONS (collector shell): ${JAVA_TOOL_OPTIONS:-not set}"
    for v in POD_NAME PODNAME NODE_NAME NODE_IP OKIND WHATAP_MICRO_ENABLED; do
        eval "_val=\${$v:-}"
        if [ -n "$_val" ]; then fact "env $v: $_val"; else fact "env $v: not set"; fi
    done
    if [ -d /var/run/secrets/kubernetes.io ]; then fact "/var/run/secrets/kubernetes.io: present"; else fact "/var/run/secrets/kubernetes.io: absent"; fi
    read_proc "container hostname (/etc/hostname)" /etc/hostname
}

# [13] L. Tier 2 — only when explicitly requested
_rep_tier2() {
    section "L. Tier 2 artifacts (opt-in)"
    if [ "$OPT_THREADS" = 0 ] && [ "$OPT_JCMD" = 0 ] && [ -z "$OPT_DUMPS" ]; then
        fact "not requested (--threads / --jcmd / --dump-file absent); no attach, signal, or pause was applied to any JVM"
    fi
    _TDUMPS=0
    true > "$(_tmp tframes)" 2>/dev/null
    if [ "$OPT_THREADS" != 0 ] 2>/dev/null; then
        _tn="$OPT_THREADS"
        [ "$_tn" -ge 1 ] 2>/dev/null || _tn=1
        _tp=0
        for pid in $D_MARKED; do
            if ! _jvm_confirmed "$pid"; then
                fact "-- thread dump pid $pid: n/a (${_NOTCONF})"
                _flag threads_fail "pid $pid: ${_NOTCONF}"
                continue
            fi
            _tp=$((_tp + 1))
            [ "$_tp" -gt 3 ] && { fact "-- remaining attached JVMs not dumped (cap: 3)"; break; }
            warn "[Tier2] thread dump: pid $pid x$_tn — pauses the target JVM at a safepoint for each dump"
            _k=1
            while [ "$_k" -le "$_tn" ]; do
                _td="$(_tmp tdump)"
                _tool=""
                if have jstack; then _tool="jstack -l"
                elif have jcmd; then _tool="jcmd Thread.print -l"; fi
                if [ -n "$_tool" ]; then
                    # a dump of a large JVM outlasts the per-command cap
                    _ct="$CMD_TIMEOUT"; CMD_TIMEOUT=60
                    if [ "$_tool" = "jstack -l" ]; then _bounded jstack -l "$pid" > "$_td" 2>&1
                    else _bounded jcmd "$pid" Thread.print -l > "$_td" 2>&1; fi
                    _trc=$?
                    CMD_TIMEOUT="$_ct"
                    if [ "$_trc" = 0 ] && grep -q '^"' "$_td" 2>/dev/null; then
                        fact "-- thread dump pid $pid ($_k/$_tn) via $_tool (first 5000 lines):"
                        head -n 5000 "$_td" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                        cat "$_td" >> "$(_tmp tframes)" 2>/dev/null
                        _TDUMPS=$((_TDUMPS + 1))
                        _flag threads_ok "pid $pid"
                    else
                        if [ "$_trc" = 124 ]; then _tw="timed out: 60s"
                        elif [ "$_trc" = 0 ]; then _tw="no thread header in the output: $(head -n 1 "$_td" 2>/dev/null | cut -c1-120)"
                        else _tw="exit $_trc: $(head -n 1 "$_td" 2>/dev/null | cut -c1-120)"; fi
                        fact "-- thread dump pid $pid ($_k/$_tn) via $_tool: n/a ($_tw)"
                        _flag threads_fail "$_tool $pid: $_tw"
                    fi
                else
                    warn "[Tier2] jstack and jcmd absent: sending SIGQUIT to pid $pid — the dump goes to that process's stdout"
                    if _kerr="$(kill -3 "$pid" 2>&1)"; then
                        fact "-- thread dump pid $pid ($_k/$_tn): jstack and jcmd absent; SIGQUIT sent, output goes to the process stdout shown in section D"
                        _flag threads_fail "pid $pid: jstack and jcmd absent; SIGQUIT sent, the dump is in the process stdout, not in this report"
                    else
                        fact "-- thread dump pid $pid ($_k/$_tn): jstack and jcmd absent; SIGQUIT not sent: ${_kerr:-kill -3 failed}"
                        _flag threads_fail "pid $pid: jstack and jcmd absent, and kill -3 failed: ${_kerr:-nonzero exit}"
                    fi
                fi
                [ "$_k" -lt "$_tn" ] && sleep 2
                _k=$((_k + 1))
            done
        done
        [ "$_tp" = 0 ] && [ -z "$(echo $D_MARKED)" ] && fact "thread dumps: n/a (no JVM carrying a WhaTap attach marker)"
    fi
    # Dump files taken elsewhere enter the same counts. No JVM is contacted;
    # the file is read as it is, and which JVM produced it is whatever the
    # reader knows about the file.
    # one path per line: a dump file name may carry spaces (console downloads do)
    while IFS= read -r _df; do
        [ -n "$_df" ] || continue
        if [ ! -e "$_df" ]; then fact "-- supplied dump file $_df: n/a (path not found)"; _flag dump_fail "$_df: path not found"; continue; fi
        if [ ! -r "$_df" ]; then fact "-- supplied dump file $_df: n/a (permission denied)"; _flag dump_fail "$_df: permission denied$(_priv_hint)"; continue; fi
        _flag dump_ok "$_df"
        _dfl="$(grep -c . "$_df" 2>/dev/null)"; _dfh="$(grep -c '^"' "$_df" 2>/dev/null)"
        fact "-- supplied dump file $_df: ${_dfl:-0} non-empty lines, ${_dfh:-0} thread header lines; first line: $(head -n 1 "$_df" 2>/dev/null | cut -c1-120)"
        fact "   read as supplied (--dump-file); not taken by this collector"
        cat "$_df" >> "$(_tmp tframes)" 2>/dev/null
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
        if [ -s "$(_tmp tframes)" ]; then
            grep -E '^[[:space:]]*at ' "$(_tmp tframes)" 2>/dev/null \
                | sed 's/^[[:space:]]*at //; s/(.*$//' \
                | sort | uniq -c | sort -rn > "$(_tmp tfreq)" 2>/dev/null
            _fq_n="$(grep -c . "$(_tmp tfreq)" 2>/dev/null)"
            fact "-- stack frame frequency over the $_TDUMPS dump(s) above: ${_fq_n:-0} distinct frames"
            fact "   counted from the 'at <class>.<method>' lines of every thread, at any stack depth"
            fact "   bucket 1 of 3 — JDK and JVM-vendor frames (package starts with java. javax. jakarta. sun. jdk. com.sun. oracle. org.graalvm.), top 20:"
            grep -E '[0-9]+ (java|javax|jakarta|sun|jdk|com\.sun|oracle|org\.graalvm)\.' "$(_tmp tfreq)" 2>/dev/null | head -n 20 > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (no frame in this bucket)\n'; fi
            fact "   bucket 2 of 3 — WhaTap agent frames (package starts with whatap.), top 20:"
            grep -E '[0-9]+ whatap\.' "$(_tmp tfreq)" 2>/dev/null | head -n 20 > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (no frame in this bucket)\n'; fi
            fact "   bucket 3 of 3 — every remaining frame, top 80:"
            grep -vE '[0-9]+ (java|javax|jakarta|sun|jdk|com\.sun|oracle|org\.graalvm|whatap)\.' "$(_tmp tfreq)" 2>/dev/null | head -n 80 > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (no frame in this bucket)\n'; fi
            # Thread-level counts. On an idle JVM the frames carry no application
            # class at all, while the thread NAMES still do (cache regions named
            # after entity classes, a scheduler instance id, a pool prefix), so
            # the names are counted separately from the frames.
            grep '^"' "$(_tmp tframes)" 2>/dev/null | sed 's/^"\([^"]*\)".*$/\1/' > "$(_tmp tnames)" 2>/dev/null
            _thn="$(grep -c . "$(_tmp tnames)" 2>/dev/null)"
            fact "-- thread header lines over the $_TDUMPS dump(s): ${_thn:-0}"
            fact "   thread states (java.lang.Thread.State lines, counted):"
            grep -oE 'java\.lang\.Thread\.State: [A-Z_]+' "$(_tmp tframes)" 2>/dev/null | sed 's/^java.lang.Thread.State: //' | sort | uniq -c | sort -rn > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (no state line in the dump text)\n'; fi
            fact "   thread name shapes, every digit run replaced by N so pool members collapse into one line (names that are themselves a dotted class-like name are counted in the next block instead), top 40:"
            sed 's/[0-9][0-9]*/N/g' "$(_tmp tnames)" 2>/dev/null | grep -vE '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_$][A-Za-z0-9_$]*){2,}$' | sort | uniq -c | sort -rn | head -n 40 > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (no thread header line in the dump text)\n'; fi
            grep -oE '[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_$][A-Za-z0-9_$]*){2,}' "$(_tmp tnames)" 2>/dev/null | sort | uniq -c | sort -rn > "$(_tmp tdot)" 2>/dev/null
            fact "   package roots of dotted names carried inside thread names (first three dot-separated parts, thread count):"
            awk '{ n=split($2, p, "."); if (n >= 3) print $1, p[1] "." p[2] "." p[3] }' "$(_tmp tdot)" 2>/dev/null | awk '{ c[$2]+=$1 } END { for (k in c) print c[k], k }' | sort -rn | head -n 20 > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (none)\n'; fi
            fact "   the dotted names themselves (three or more parts, as written), distinct, top 80:"
            head -n 80 "$(_tmp tdot)" > "$(_tmp tb)" 2>/dev/null
            if [ -s "$(_tmp tb)" ]; then while IFS= read -r _l; do printf '        %s\n' "$_l"; done < "$(_tmp tb)"; else printf '        (none)\n'; fi
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
                _ofc="$(grep -E "^ *[0-9]+ ${_ope}" "$(_tmp tfreq)" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
                _otc="$(grep -c -i "$_opw" "$(_tmp tnames)" 2>/dev/null)"
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
            _flag jcmd_fail "command not found: jcmd"
        else
            # A JVM whose options are not in /proc is queried here too, whether
            # or not it carries an attach marker: /proc showed nothing about
            # it, so this output is the only verbatim record of what it runs.
            _jp=0; _jseen=""
            for pid in $D_MARKED $D_JVM_NOARGS; do
                case "$_jseen" in *"|$pid|"*) continue ;; esac
                _jseen="$_jseen|$pid|"
                if ! _jvm_confirmed "$pid"; then
                    fact "-- jcmd $pid: n/a (${_NOTCONF})"
                    _flag jcmd_fail "pid $pid: ${_NOTCONF}"
                    continue
                fi
                _jp=$((_jp + 1))
                [ "$_jp" -gt 3 ] && { fact "-- remaining JVMs not queried (cap: 3)"; break; }
                warn "[Tier2] jcmd: pid $pid — uses the JVM attach mechanism on the target process"
                for _jq in VM.command_line VM.system_properties VM.flags VM.version; do
                    _jo="$(_bounded jcmd "$pid" "$_jq" 2>&1)"; _jrc=$?
                    if [ "$_jrc" = 0 ] && [ -n "$_jo" ]; then
                        _emit_labeled "-- jcmd $pid $_jq" "$_jo"
                        _flag jcmd_ok "$pid $_jq"
                    else
                        if [ "$_jrc" = 124 ]; then _jw="timed out: ${CMD_TIMEOUT}s"
                        else _jw="exit $_jrc: $(printf '%s\n' "$_jo" | head -n 1 | cut -c1-120)"; fi
                        fact "-- jcmd $pid $_jq: n/a ($_jw)"
                        _flag jcmd_fail "jcmd $pid $_jq: $_jw"
                    fi
                done
            done
            [ "$_jp" = 0 ] && [ -z "$_jseen" ] && fact "jcmd data: n/a (no JVM carrying a WhaTap attach marker, and none whose options are absent from /proc)"
        fi
    fi
}

# [14] M. Library detail pack — only when explicitly requested
# Writing a new weaving module needs more than a file name: the module is
# compiled against the customer's own artifact, redeclares the target
# class's fields and method signatures, and must not be compiled for a
# class-file version above the target's. This section carries exactly
# those inputs for the libraries named on the command line.
_rep_libpack() {
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
        true > "$(_tmp jarsha)" 2>/dev/null
        _build_libroots
        if [ -s "$_LIBROOTS" ]; then
            fact "for a jar whose class names section N prints, the package histogram is left out here and the jar says so"
        fi
        sort -u "$_PATHSINK" > "$(_tmp paths.u)" 2>/dev/null
        while IFS= read -r _rec; do
            [ -n "$_rec" ] || continue
            _kind="${_rec%%|*}"
            case "$_kind" in
                file)
                    _p="${_rec#file|}"
                    _lib_match "$_p" || continue
                    _fsp="$(_rpath "" "$_p")"
                    if [ -z "$_fsp" ]; then fact "-- $_p: n/a ($(_path_why "$_p"))"; continue; fi
                    # Several deployment units of one application carry the same
                    # jar. Detailing each copy spends the cap on identical
                    # content and hides the other units entirely, so a
                    # byte-identical copy is named rather than detailed again.
                    _sh="$(_sha256 "$_fsp")"
                    case "$_sh" in n/a*) _sh="" ;; esac
                    if [ -n "$_sh" ] && grep -q "^$_sh " "$(_tmp jarsha)" 2>/dev/null; then
                        fact "-- $(basename "$_p"): byte-identical copy of a jar already detailed above (sha256 $_sh); path: $_p"
                        continue
                    fi
                    [ -n "$_sh" ] && printf '%s %s\n' "$_sh" "$_p" >> "$(_tmp jarsha)" 2>/dev/null
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
                    _fsc="$(_rpath "" "$_cj")"
                    if [ -z "$_fsc" ]; then fact "-- $_ent: n/a (container jar $_cj: $(_path_why "$_cj"))"; continue; fi
                    _tmpj="$(nested_extract "$_fsc" "$_ent")"
                    if [ -z "$_tmpj" ]; then
                        fact "-- $_ent: n/a (packed inside $_cj; entry could not be read, or is above the 80 MB extraction bound)"
                        continue
                    fi
                    detail_jar "$(basename "$_ent")" "$_tmpj" "entry $_ent inside $_cj"
                    _rmtmp "$_tmpj"
                    ;;
            esac
        done < "$(_tmp paths.u)"
        [ "$_dn" = 0 ] && fact "no enumerated jar matched the requested patterns"
        # a class named with --class may be an application class of an
        # executable jar rather than a library class
        for _fq in $OPT_CLASSES; do
            _rel="$(printf '%s' "$_fq" | tr '.' '/').class"
            for pid in $D_MARKED; do
                _jarp="$(_all_jvm_args "$pid" 2>/dev/null | awk 'p=="-jar"{print; exit} {p=$0}')"
                [ -n "$_jarp" ] || continue
                _fsj2="$(_rpath "$pid" "$_jarp")"
                [ -n "$_fsj2" ] || continue
                have unzip || continue
                _bounded unzip -Z1 "$_fsj2" "BOOT-INF/classes/$_rel" >/dev/null 2>&1 || continue
                fact "-- $_fq is an application class of $_jarp (BOOT-INF/classes)"
                if ! have javap; then
                    fact "   member signatures: n/a (command not found: javap)"
                    continue
                fi
                _cd="$(_tmp cls)"
                _rmtmp "$_cd"; mkdir -p "$_cd" 2>/dev/null
                if _bounded unzip -o -q -d "$_cd" "$_fsj2" "BOOT-INF/classes/$_rel" 2>/dev/null; then
                    fact "   member signatures (javap -p -s, first 400 lines):"
                    _bounded javap -p -s -classpath "$_cd/BOOT-INF/classes" "$_fq" 2>&1 | head -n 400 | while IFS= read -r _l; do printf '             %s\n' "$_l"; done
                else
                    fact "   member signatures: n/a (class entry could not be extracted)"
                fi
                _rmtmp "$_cd"
            done
        done
    fi
}

# [15] N. Application class index — only when explicitly requested
# Attaching a transaction to an application that no weaving module covers
# starts from one question: which classes are the application's own? The
# customer's source is frequently out of reach for procurement or security
# reasons, and the deployed artifact answers the same question. Section F
# inventories the LIBRARIES; this section inventories the classes the
# application itself ships, from the same roots the JVM loads them from.
_rep_appclasses() {
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
            fact "-- jars named with --library that join this index: ${_lrn:-0} (cap 60)"
        fi
        if [ ! -s "$_APPSINK" ] && [ ! -s "$_LIBROOTS" ]; then
            fact "requested, but section F enumerated no application class root (no directory classpath entry, no WEB-INF/classes, no BOOT-INF/classes) and no jar was named with --library"
        else
        fact "-- a leading BOOT-INF/classes/ or WEB-INF/classes/ segment is removed from each class name below"
        { sort -u "$_APPSINK" 2>/dev/null; head -n 60 "$_LIBROOTS" 2>/dev/null; } > "$(_tmp approots.u)" 2>/dev/null
        _NAMES="$(_tmp appnames)"
        true > "$_NAMES" 2>/dev/null
        _rn=0
        while IFS= read -r _rec; do
            [ -n "$_rec" ] || continue
            _rn=$((_rn + 1))
            _rcap=12; [ -s "$_LIBROOTS" ] && _rcap=72
            [ "$_rn" -gt "$_rcap" ] && { fact "-- cap reached: $_rcap class roots read, later roots skipped"; break; }
            case "$_rec" in
                dir\|*)
                    _rt="${_rec#dir|}"
                    case "$_rt" in /proc/[0-9]*/root*) _rt="$(_vfix "$_rt")" ;; esac
                    if [ ! -d "$_rt" ]; then fact "-- directory root $_rt: n/a (path not found)"; continue; fi
                    if [ ! -r "$_rt" ]; then fact "-- directory root $_rt: n/a (permission denied)"; continue; fi
                    _bounded find "$_rt" -name '*.class' -type f > "$(_tmp rootcls.all)" 2>/dev/null; _frc=$?
                    head -n 20000 "$(_tmp rootcls.all)" > "$(_tmp rootcls)" 2>/dev/null
                    _cnt="$(grep -c . "$(_tmp rootcls)" 2>/dev/null)"
                    fact "-- directory root $_rt: ${_cnt:-0} class files (read bound: 20000)$( [ "$_frc" = 124 ] && echo "; find timed out at ${CMD_TIMEOUT}s, the count is partial")"
                    # A deployment unit can ship the application's own code as
                    # jars next to this directory rather than as class files in
                    # it. When the directory holds nothing, the count of the
                    # sibling lib directory is the fact that says where else to
                    # look; --library <name> then details those jars (section M).
                    if [ "${_cnt:-0}" -eq 0 ]; then
                        _sib="${_rt%/classes}/lib"
                        if [ -d "$_sib" ]; then
                            _sibn="$(_names "$_sib" | grep -i -c '\.jar$')"
                            fact "   sibling ${_sib}: ${_sibn:-0} jar files"
                        else
                            fact "   sibling ${_sib}: absent"
                        fi
                    fi
                    while IFS= read -r _cf; do
                        _fq="${_cf#"$_rt"/}"; _fq="${_fq%.class}"
                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_NAMES" 2>/dev/null
                    done < "$(_tmp rootcls)"
                    ;;
                libjar\|*)
                    _rt="${_rec#libjar|}"
                    _fsl="$(_rpath "" "$_rt")"
                    if [ -z "$_fsl" ]; then fact "-- named jar $_rt: n/a ($(_path_why "$_rt"))"; continue; fi
                    _lst="$(_zlist "$_fsl" '*.class')"; _zrc=$?
                    if [ "$_zrc" != 0 ] && [ "$_zrc" != 11 ]; then fact "-- named jar $_rt: n/a ($(_zwhy))"; continue; fi
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
                    _lst="$(_zlist "$_rt" 'WEB-INF/classes/*.class' 'BOOT-INF/classes/*.class')"; _zrc=$?
                    if [ "$_zrc" != 0 ] && [ "$_zrc" != 11 ]; then fact "-- archive root $_rt: n/a ($(_zwhy))"; continue; fi
                    _cnt="$(printf '%s\n' "$_lst" | grep -c .)"
                    fact "-- archive root $_rt: ${_cnt:-0} class entries under WEB-INF/classes or BOOT-INF/classes (read bound: 20000)"
                    printf '%s\n' "$_lst" | head -n 20000 | while IFS= read -r _ce; do
                        [ -n "$_ce" ] || continue
                        _fq="${_ce#WEB-INF/classes/}"; _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq%.class}"
                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_NAMES" 2>/dev/null
                    done
                    ;;
            esac
        done < "$(_tmp approots.u)"
        if [ ! -s "$_NAMES" ]; then
            fact "no class file was read from the enumerated roots"
        else
            sort -u "$_NAMES" > "${_NAMES}.u" 2>/dev/null
            _tot="$(grep -c . "${_NAMES}.u" 2>/dev/null)"
            fact "-- distinct application classes: ${_tot:-0}"
            fact "-- package histogram, class count per package (top 40):"
            sed 's/\.[^.]*$//; t; s/.*/(default package)/' "${_NAMES}.u" 2>/dev/null | sort | uniq -c | sort -rn | head -n 40 | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
            fact "-- name-pattern index over a fixed pattern list carried by this collector, printed verbatim:"
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
                _refdir="$(_tmp refx)"
                for _tk in $OPT_REFS; do
                    _tki="$(printf '%s' "$_tk" | tr '.' '/')"
                    _hits="$(_tmp refhits)"; true > "$_hits" 2>/dev/null
                    _rr=0
                    while IFS= read -r _rrec; do
                        [ -n "$_rrec" ] || continue
                        _rr=$((_rr + 1)); [ "$_rr" -gt 72 ] && break
                        case "$_rrec" in
                            dir\|*)
                                _rt="${_rrec#dir|}"
                                case "$_rt" in /proc/[0-9]*/root*) _rt="$(_vfix "$_rt")" ;; esac
                                [ -d "$_rt" ] || continue
                                _bounded grep -rlF -a --include='*.class' -- "$_tki" "$_rt" 2>/dev/null | head -n 400 \
                                  | while IFS= read -r _hf; do
                                        _fq="${_hf#"$_rt"/}"; _fq="${_fq%.class}"
                                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_hits" 2>/dev/null
                                    done
                                ;;
                            libjar\|*|archive\|*)
                                case "$_rrec" in libjar\|*) _rt="${_rrec#libjar|}" ;; *) _rt="${_rrec#archive|}" ;; esac
                                _fsr="$(_rpath "" "$_rt")"
                                [ -n "$_fsr" ] || continue
                                have unzip || continue
                                _sz="$(wc -c < "$_fsr" 2>/dev/null)"
                                if [ -n "$_sz" ] && [ "$_sz" -gt 83886080 ] 2>/dev/null; then
                                    fact "   $_rt: skipped for this scan (above the 80 MB unpack bound)"
                                    continue
                                fi
                                _rmtmp "$_refdir"; mkdir -p "$_refdir" 2>/dev/null || continue
                                _bounded unzip -qq -o -d "$_refdir" "$_fsr" '*.class' >/dev/null 2>&1
                                _bounded grep -rlF -a --include='*.class' -- "$_tki" "$_refdir" 2>/dev/null | head -n 400 \
                                  | while IFS= read -r _hf; do
                                        _fq="${_hf#"$_refdir"/}"; _fq="${_fq%.class}"
                                        _fq="${_fq#BOOT-INF/classes/}"; _fq="${_fq#WEB-INF/classes/}"
                                        printf '%s\n' "$_fq" | tr '/' '.' >> "$_hits" 2>/dev/null
                                    done
                                _rmtmp "$_refdir"
                                ;;
                        esac
                    done < "$(_tmp approots.u)"
                    sort -u "$_hits" > "${_hits}.u" 2>/dev/null
                    _hn="$(grep -c . "${_hits}.u" 2>/dev/null)"
                    fact "-- classes naming $_tk in their bytecode: ${_hn:-0} (byte search for the internal form $_tki in the class files of the roots above)"
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
            if [ -s "$(_tmp tfreq)" ]; then
                awk 'NR==FNR { a[$0]=1; next } { c=$2; sub(/\.[^.]*$/, "", c); if (c in a) print }' "${_NAMES}.u" "$(_tmp tfreq)" > "$(_tmp tjoin)" 2>/dev/null
                _tjn="$(grep -c . "$(_tmp tjoin)" 2>/dev/null)"
                _tjs="$(awk '{s+=$1} END{print s+0}' "$(_tmp tjoin)" 2>/dev/null)"
                fact "-- frames in the section L dump(s) whose class is in this index: ${_tjn:-0} distinct frames, ${_tjs:-0} occurrences (top 60):"
                if [ "${_tjn:-0}" -gt 0 ]; then
                    head -n 60 "$(_tmp tjoin)" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
                else
                    printf '        (no frame of any counted dump belongs to a class in this index)\n'
                fi
            else
                fact "-- frames in the section L dump(s) whose class is in this index: n/a (no thread dump was counted in this run: --threads and --dump-file absent, or no dump text)"
            fi
        fi
        fi
    fi
}

# The goals, resolved from the flags the sections recorded: most of them ran
# inside `| while` pipelines, where an assignment does not survive.
_rep_goals() {
    _vis="$(_visibility)"
    _n="$(echo $D_JVM_PIDS | wc -w | tr -d ' ')"
    # A JVM whose environment or VM options this run could not read may carry
    # the agent or name a config, so the two goals are blocked by it even
    # when another JVM's agent and config were read.
    _vhint=""
    if [ -n "$D_ENV_UNREAD" ] || [ "${D_PROC_SKIPPED:-0}" -gt 0 ]; then _vhint="$(_priv_hint)"; fi
    # agent: obtained only when an agent jar opened as an archive (or, with no
    # jar named anywhere, when an agent home was read)
    if [ -n "$_vis" ]; then
        missed agent "$_vis$(_flagged agent_read && printf '; read for the other JVMs: %s' "$(_flag_text agent_read)")$_vhint"
    # every JVM that names an agent has to have it read: one JVM's corrupt or
    # unreadable jar is not covered by another JVM's good one
    elif _flagged agent_unread || _flagged agent_absent; then
        _at="$(_flag_text agent_unread)"; _ab="$(_flag_text agent_absent)"
        _at="$_at${_at:+${_ab:+; }}${_ab:+named, but not found from this run: $_ab}"
        case "$_at" in
            *"permission denied"*) missed agent "$_at$(_priv_hint)" ;;
            *) missed agent "$_at" ;;
        esac
    elif _flagged agent_read; then got agent
    elif [ -z "$D_AGENT_JARS" ] && _flagged agent_home_read; then got agent
    elif [ -n "$D_HOMES" ] || [ -n "$D_AGENT_JARS" ]; then missed agent "named, but nothing of it was read"
    elif [ "${_n:-0}" -eq 0 ]; then na agent "no JVM process among the $D_PROC_SCANNED /proc entries read, no /whatap-agent, no WHATAP_HOME in the collector shell"
    else na agent "no whatap -javaagent, -Dwhatap.* property or WHATAP_* variable in the arguments and environment of the $_n JVM process(es) found (all read), no /whatap-agent, no WHATAP_HOME in the collector shell"; fi
    # conf
    if [ -n "$_vis" ]; then
        missed conf "$_vis$(_flagged conf_read && printf '; read for the other JVMs: %s' "$(_flag_text conf_read)")$_vhint"
    # every JVM that names an agent has to have its config read, as for the
    # agent goal: one JVM's config found is not another's
    elif _flagged conf_unread || _flagged conf_absent; then
        _ct="$(_flag_text conf_unread)"; _cb="$(_flag_text conf_absent)"
        _ct="$_ct${_ct:+${_cb:+; }}${_cb:+no file at the config path the JVM resolves: $_cb}"
        case "$_ct" in
            *"permission denied"*) missed conf "$_ct$(_priv_hint)" ;;
            *) missed conf "$_ct" ;;
        esac
    elif _flagged conf_read; then got conf
    elif _flagged conf_absent_home; then na conf "no attached JVM, and no whatap.conf (the assumed default name) in the agent home(s) found: $(_flag_text conf_absent_home)"
    else na conf "no JVM carrying a WhaTap attach marker and no readable agent home, so there is no config path to read"; fi
    # requested opt-ins
    if [ "$OPT_THREADS" != 0 ]; then
        if _flagged threads_fail; then missed threads "$(_flag_text threads_fail)"
        elif _flagged threads_ok; then got threads
        elif [ -n "$_vis" ]; then missed threads "no JVM carrying a WhaTap attach marker was visible; $_vis$_vhint"
        else na threads "no JVM carrying a WhaTap attach marker among the $_n JVM process(es) found"; fi
    fi
    if [ "$OPT_JCMD" != 0 ]; then
        if _flagged jcmd_fail; then missed jcmd "$(_flag_text jcmd_fail)"
        elif _flagged jcmd_ok; then got jcmd
        elif [ -n "$_vis" ]; then missed jcmd "no JVM carrying a WhaTap attach marker was visible; $_vis$_vhint"
        else na jcmd "no JVM carrying a WhaTap attach marker, and none whose options are absent from /proc, among the $_n JVM process(es) found"; fi
    fi
    if [ -n "$(printf '%s' "$OPT_DUMPS" | tr -d '\n')" ]; then
        if _flagged dump_fail; then missed dumpfile "$(_flag_text dump_fail)"
        else got dumpfile; fi
    fi
}

run_report() {
    emit_header

    # Without an agent on disk and a config to read, nothing downstream can be
    # settled remotely. Both are resolved just before emit_status, from the
    # flags the sections record. A requested opt-in is a goal of its own.
    goal agent "whatap agent artifacts on disk"
    goal conf  "agent configuration"
    [ "$OPT_THREADS" != 0 ] && goal threads "thread dumps (--threads)"
    [ "$OPT_JCMD" != 0 ] && goal jcmd "jcmd VM data (--jcmd)"
    [ -n "$(printf '%s' "$OPT_DUMPS" | tr -d '\n')" ] && goal dumpfile "supplied thread dump files (--dump-file)"

    _rep_env

    _PATHSINK="$(_tmp paths)"
    true > "$_PATHSINK" 2>/dev/null
    _APPSINK="$(_tmp approots)"
    true > "$_APPSINK" 2>/dev/null
    true > "$(_tmp flags)" 2>/dev/null
    _write_helpers

    discover
    # the attached-JVM count sections E to J test
    _nm="$(echo $D_MARKED | wc -w | tr -d ' ')"

    _rep_host
    _rep_runtimes
    _rep_artifacts
    _rep_jvms
    _rep_conf
    _rep_libs
    _rep_weaving
    _rep_logging
    _rep_agentlogs
    _rep_network
    _rep_k8s
    _rep_tier2
    _rep_libpack
    _rep_appclasses
    _rep_goals

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
    HOST="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="./$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
