#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — APM PHP agent collector
# -----------------------------------------------------------------------------
# Gathers the hidden facts a remote WhaTap PHP-agent developer repeatedly asks a
# field engineer for, from the host or container where the PHP application (and
# the whatap-php agent) runs. Derived from an exhaustive review of #ask-dev-apm
# support threads (2025-06 .. 2026-08) and from the shipped whatap-php package
# itself (rpm 2.14-2 and the Alpine tarball: install.sh, whatap-php service
# wrapper, whatap-php.service, template.ini, modules/, whatap_php, whatap.so).
#
# The PHP agent has two halves that are installed and configured separately:
#   * the tracer  — a Zend extension (whatap.so) loaded into every Apache /
#     PHP-FPM / CLI worker, built per PHP API version (whatap[_zts]_<API>.so),
#   * the agent   — a Go process (whatap_php, or whatap_php_static on musl)
#     that receives from the tracer over UDP and talks to the collection server.
# install.sh resolves the environment once (php binary, extension_dir, ini scan
# dir) and writes the result into the service files. Almost every support case
# is about a mismatch between what it resolved then and what runs now.
#
# Recurring field questions this report answers with facts:
#   * Which PHP binaries/SAPIs exist, at which version, PHP API and thread
#     safety (NTS/ZTS) — and which extension_dir and ini files does each use?
#   * Is whatap.so present in that extension_dir, and which
#     whatap[_zts]_<API>.so does the symlink actually point to?
#   * Is the extension actually mapped into the live Apache/PHP-FPM workers, or
#     only configured on disk? Does starting PHP emit a load warning?
#   * Where did install.sh put whatap.ini, and does that ini tree belong to the
#     SAPI that serves traffic (cli vs fpm vs apache2 trees differ)?
#   * What do whatap.ini / the [whatap] block in php.ini actually contain
#     (accesskey, server host, app_name, app_process_name, hook options)?
#   * Is whatap_php running, from which home, with which WHATAP_* environment
#     (WHATAP_CONFIG_HOME is written by install.sh into the unit/init script)?
#   * Is the UDP channel (net_udp_port, default 6600) bound, is there a TCP
#     session to the collection server, and does the SysV shared memory /
#     semaphore pair the agent uses exist?
#   * Which application server model runs the app (Apache prefork/worker/event,
#     PHP-FPM pools, or a persistent-worker runtime such as Swoole/Octane,
#     RoadRunner, FrankenPHP)?
#   * What do the agent logs (whatap-boot-*.log, whatap-install-*.log) and the
#     web server error log (WA*-coded lines from whatap.so) say?
#
# THE CONTRACT (../../../CONTRACT.md):
#   1. Facts only. No conclusion is stated on any emitted line.
#   2. Discover, never assume. Resolve symlinks, process maps, args, env, ini.
#   3. One field command -> paste the whole output.
#   4. Domain-team owned. Seed v0 by the Global team; ownership transfers to
#      the APM/PHP agent developers.
#
# DESIGN GUIDELINES (../../../docs/collector-engineering.md): MECE sections,
# Tier-0 load-safe defaults (bounded reads, no whole-log grep, no deep find),
# bash 3.2+, reasoned absence for every missing value.
#
# The PHP binaries found are executed read-only, with -v / -m / -i / --ini only
# — the same calls the vendor installer makes. No application code is run. The
# agent binary is only ever executed with its `version` argument (running it
# bare would start an agent).
#
# NOTE: no `set -e` — a collector must reach its footer even when every probe
# fails. Failures are handled locally by the helpers.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata ------------------------------------------------------
COLLECTOR_NAME="whatap-apmphp"
VERSION="0.1.0"
DOMAIN="apm/php"
TARGET="host/$(hostname 2>/dev/null || echo unknown)"

# ---- CLI harness — DO NOT EDIT ----------------------------------------------
OPT_FILE=0        # write the report to a .txt file
OPT_STDOUT=0      # print the report to stdout
OPT_QUIET=0       # suppress progress narration on stderr

usage() {
    cat <<EOF
$COLLECTOR_NAME $VERSION — a WhaTap Global Groundtruth collector (facts only).
Collects PHP APM agent facts from the host or container where the PHP
application runs (run it inside the container for containerized apps, e.g.
kubectl exec / docker exec, as root or as the web server user where possible).

Run with no arguments (or --help) to print this help; a collection needs an
explicit action flag so nothing starts by accident.

  $(basename "$0")            print this help (no collection)
  $(basename "$0") --file     write the facts report -> ./$COLLECTOR_NAME-<host>-<UTC>.txt
  $(basename "$0") --stdout   print the facts report to stdout
  $(basename "$0") --quiet .. silence progress on stderr (add to --file / --stdout)
EOF
}

ARGC=$#
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

progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }
warn() { printf '%s\n' "$*" >&2; }

# ---- reasoned-absence helpers -------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

_errfile=""
_infofile=""
_timeout_bin=""
CMD_TIMEOUT=15
_init_probe() {
    _errfile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.err")"
    _infofile="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/.ggt.$$.info")"
    have timeout && _timeout_bin="$(command -v timeout)"
}
_end_probe() { [ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null; [ -n "$_infofile" ] && rm -f "$_infofile" 2>/dev/null; }

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
# never masked (see collectors/apm/php/README.md security note).
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
# and CR (\r, 0x0D) count. Windows-edited ini files reach Linux hosts through
# support cases; the reader compares these numbers against the dumped text.
conf_bytes() {
    local label="$1" path="$2" sz cr
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
    cr="$(tr -dc '\r' < "$path" 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}

# file_facts "label" PATH -> ls -l line, size, mtime and (when available) the
# SHA-256 of a binary artifact, so two hosts can be compared byte-for-byte.
file_facts() {
    local label="$1" path="$2" sum=""
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    fact "$label:"
    printf '        %s\n' "$(ls -ld "$path" 2>/dev/null)"
    if [ -f "$path" ]; then
        if have sha256sum; then sum="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
        elif have shasum; then sum="$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')"; fi
        if [ -n "$sum" ]; then printf '        sha256: %s\n' "$sum"
        else printf '        sha256: n/a (command not found: sha256sum, shasum)\n'; fi
    fi
    if [ -L "$path" ]; then
        printf '        symlink target: %s\n' "$(readlink "$path" 2>/dev/null)"
        printf '        resolves to: %s\n' "$(readlink -f "$path" 2>/dev/null || echo 'n/a (unresolvable)')"
    fi
}

# php_run "label" PHP_BIN [ARGS...] -> run a PHP binary with read-only flags
# under timeout; stdout becomes facts and any stderr is emitted as its own
# labeled block (a PHP startup warning about the extension lands there).
php_run() {
    local label="$1" php="$2"; shift 2
    [ -x "$php" ] || { fact "$label: n/a (not executable: $php)"; return; }
    local out rc err
    if [ -n "$_timeout_bin" ]; then out="$("$_timeout_bin" "$CMD_TIMEOUT" "$php" "$@" 2>"$_errfile")"; rc=$?
    else out="$("$php" "$@" 2>"$_errfile")"; rc=$?; fi
    err="$(head -c 2000 "$_errfile" 2>/dev/null)"
    if [ "$rc" -eq 124 ] && [ -n "$_timeout_bin" ]; then fact "$label: n/a (timed out: ${CMD_TIMEOUT}s)"; return; fi
    if [ -n "$out" ]; then _emit_labeled "$label" "$out"
    elif [ "$rc" -ne 0 ]; then fact "$label: n/a ($(_classify_err))"
    else fact "$label: n/a (empty output)"; fi
    [ -n "$err" ] && _emit_labeled "$label (stderr)" "$err"
    return 0
}

# php_info PHP_BIN -> capture `php -i` into $_infofile (0 on success). Used by
# php_info_grep so one execution serves every extracted field.
php_info() {
    local php="$1" rc
    : > "$_infofile" 2>/dev/null
    [ -x "$php" ] || return 1
    if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$CMD_TIMEOUT" "$php" -i > "$_infofile" 2>"$_errfile"; rc=$?
    else "$php" -i > "$_infofile" 2>"$_errfile"; rc=$?; fi
    [ -s "$_infofile" ] || return 1
    return 0
}

# php_info_grep "label" PATTERN [CAP] -> lines of the captured `php -i` output
# matching PATTERN, or a reason.
php_info_grep() {
    local label="$1" pat="$2" cap="${3:-20}" out
    out="$(grep -E "$pat" "$_infofile" 2>/dev/null | head -n "$cap")"
    [ -z "$out" ] && { fact "$label: n/a (no matching line in php -i output)"; return; }
    _emit_labeled "$label" "$out"
}

# php_info_block "label" START_PATTERN [CAP] -> a multi-line, comma-continued
# block of the captured `php -i` output (the "Additional .ini files parsed"
# list wraps across lines: every line but the last ends with a comma).
php_info_block() {
    local label="$1" pat="$2" cap="${3:-40}" out
    out="$(awk -v p="$pat" -v cap="$cap" '
        $0 ~ p {inb=1}
        inb {print; n++; if (n >= cap || $0 !~ /,[[:space:]]*$/) exit}
    ' "$_infofile" 2>/dev/null)"
    [ -z "$out" ] && { fact "$label: n/a (no matching line in php -i output)"; return; }
    _emit_labeled "$label" "$out"
}

# ---- discovery (internal; emits nothing) --------------------------------------
# Populates:
#   D_PHP_BINS    distinct php / php-fpm / php-cgi binaries (PATH, globs, procs)
#   D_AGENT_PIDS  pids of the Go agent (comm: whatap_php / whatap_php_stat*)
#   D_WEB_PIDS    pids of httpd / apache2 / php-fpm / php-cgi / php processes
#   D_ALT_PIDS    pids of persistent-worker PHP runtimes (swoole/octane/rr/...)
#   D_HOMES       agent home candidates with their discovery source
#   D_SERVICE_FILES  service/unit/init files that carry the resolved install env
#   D_EXT_DIRS    extension_dir values seen (php -i, service files)
#   D_INI_FILES   whatap ini files found on disk
D_PHP_BINS=""
D_PHP_KEYS=""
D_AGENT_PIDS=""
D_WEB_PIDS=""
D_ALT_PIDS=""
D_HOMES=""
D_SERVICE_FILES=""
D_EXT_DIRS=""
D_INI_FILES=""
D_DEFAULT_HOME="/usr/whatap/php"

# resolve_fs PATH -> a readable filesystem view of PATH: the path itself if it
# exists here, otherwise the same path seen through the root of a discovered
# agent/web process (/proc/<pid>/root<PATH>). Empty if neither is visible. This
# lets the collector run from an ephemeral debug container and still read the
# target's files.
resolve_fs() {
    local p="$1" pid
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    for pid in $D_AGENT_PIDS $D_WEB_PIDS $D_ALT_PIDS; do
        [ -e "/proc/$pid/root$p" ] && { printf '%s\n' "/proc/$pid/root$p"; return; }
    done
    return 1
}

_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$D_HOMES" in *"$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES
$p|$s"; else D_HOMES="$p|$s"; fi
}

_add_svc() {  # _add_svc PATH
    local p="$1"
    [ -f "$p" ] || return
    case "$D_SERVICE_FILES" in *"|$p|"*) return ;; esac
    D_SERVICE_FILES="$D_SERVICE_FILES|$p|"
}

_add_ext_dir() {  # _add_ext_dir DIR SOURCE
    local d="$1" s="$2"
    [ -n "$d" ] || return
    case "$d" in /*) ;; *) return ;; esac
    case "$D_EXT_DIRS" in *"$d|"*) return ;; esac
    if [ -n "$D_EXT_DIRS" ]; then D_EXT_DIRS="$D_EXT_DIRS
$d|$s"; else D_EXT_DIRS="$d|$s"; fi
}

_add_ini() {  # _add_ini PATH
    local p="$1"
    [ -f "$p" ] || return
    case "$D_INI_FILES" in *"|$p|"*) return ;; esac
    D_INI_FILES="$D_INI_FILES|$p|"
}

# Dedup key for PHP binaries: the resolved target. Distinct names that resolve
# to one binary (php / php8.2 / php-cli) are one runtime; php-fpm and php-cgi
# are separate binaries and stay separate entries.
_add_php() {
    local p="$1" k
    [ -n "$p" ] || return
    [ -x "$p" ] || return
    case "$p" in *-config|*.ini|*.conf) return ;; esac
    k="$(readlink -f "$p" 2>/dev/null || echo "$p")"
    case "$D_PHP_KEYS" in *"|$k|"*) return ;; esac
    D_PHP_KEYS="$D_PHP_KEYS|$k|"
    D_PHP_BINS="$D_PHP_BINS $p"
}

# _proc_env PID NAME -> value of NAME= in the process environ (empty if none).
# The braces put the input redirection inside the silenced subshell: a process
# that exits mid-scan would otherwise make the SHELL print "No such file".
_proc_env() {
    { tr '\0' '\n' < "/proc/$1/environ" | grep "^$2=" | head -n1 | cut -d= -f2- ; } 2>/dev/null
}

_proc_cmd() {
    { tr '\0' ' ' < "/proc/$1/cmdline" | cut -c1-300 ; } 2>/dev/null
}

# _link_target /proc/<pid>/{exe,cwd} -> the resolved target, but only when it
# resolves to something that exists and is not the link path itself. A zombie's
# /proc/<pid>/exe resolves to the link path on some readlink implementations,
# which would otherwise be reported as a real binary (and its dirname taken for
# an agent home).
_link_target() {
    local l="$1" t
    t="$(readlink -f "$l" 2>/dev/null)" || return 1
    [ -n "$t" ] || return 1
    [ "$t" = "$l" ] && return 1
    [ -e "$t" ] || return 1
    printf '%s\n' "$t"
}

# _proc_start PID -> process start time, from ps when it supports lstart,
# otherwise from the timestamp of the /proc/<pid> directory.
_proc_start() {
    local s
    s="$( { ps -o lstart= -p "$1" ; } 2>/dev/null | head -n1 )"
    [ -n "$s" ] || s="$( { ls -ld "/proc/$1" ; } 2>/dev/null | awk '{print $6, $7, $8}')"
    [ -n "$s" ] || s="n/a (ps lstart unsupported and /proc/$1 unreadable)"
    printf '%s\n' "$s"
}

discover() {
    progress "discovery: php binaries, web/app processes, agent home, ini files"
    local c p pid comm cmd exe cwd envh d

    # process scan (reads comm per pid; cmdline/environ only for matches)
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [ "$pid" = "$$" ] && continue
        comm="$(cat "/proc/$pid/comm" 2>/dev/null)"
        case "$comm" in
            # /proc/<pid>/comm is capped at 15 characters, so the musl build
            # whatap_php_static appears as whatap_php_stat
            whatap_php*) D_AGENT_PIDS="$D_AGENT_PIDS $pid"; continue ;;
            httpd*|apache2*|php-fpm*|php5-fpm*|php-cgi*|php|php[0-9]*|lighttpd*)
                D_WEB_PIDS="$D_WEB_PIDS $pid"
                # only PHP binaries join the runtime list — an httpd/apache2
                # binary carries PHP as a module and cannot be run with -i
                case "$comm" in
                    php*)
                        exe="$(_link_target "/proc/$pid/exe")"
                        [ -n "$exe" ] && _add_php "$exe"
                        ;;
                esac
                ;;
            frankenphp*|rr|roadrunner*) D_ALT_PIDS="$D_ALT_PIDS $pid"; continue ;;
        esac
        # persistent-worker runtimes rename their process title, so the
        # command line is the identifying fact, not comm
        cmd="$( { tr '\0' ' ' < "/proc/$pid/cmdline" ; } 2>/dev/null )"
        case "$cmd" in
            *octane*|*swoole*|*roadrunner*|*frankenphp*|*workerman*|*"php-pm"*|*"artisan queue"*|*"artisan horizon"*)
                D_ALT_PIDS="$D_ALT_PIDS $pid" ;;
        esac
    done

    # php binaries on PATH and in the usual install locations (shallow globs
    # only — no directory walk)
    for c in php php-fpm php-cgi php5 php5-fpm php-zts zts-php; do
        p="$(command -v "$c" 2>/dev/null)"
        [ -n "$p" ] && _add_php "$p"
    done
    for p in /usr/bin/php /usr/bin/php[0-9]* /usr/sbin/php-fpm* /usr/bin/php-fpm* \
             /usr/local/bin/php /usr/local/bin/php[0-9]* /usr/local/sbin/php-fpm* \
             /opt/*/bin/php /opt/*/sbin/php-fpm /opt/remi/php*/root/usr/bin/php \
             /usr/local/php*/bin/php /usr/local/php*/sbin/php-fpm; do
        [ -x "$p" ] && [ -f "$p" ] && _add_php "$p"
    done

    # agent home candidates
    [ -n "${WHATAP_HOME:-}" ] && _add_home "$WHATAP_HOME" "env WHATAP_HOME (collector shell)"
    [ -d "$D_DEFAULT_HOME" ] && _add_home "$D_DEFAULT_HOME" "package install path (present on disk)"
    for pid in $D_AGENT_PIDS; do
        cwd="$(_link_target "/proc/$pid/cwd")"
        [ -n "$cwd" ] && [ -d "$cwd" ] && _add_home "$cwd" "cwd of whatap_php pid $pid"
        envh="$(_proc_env "$pid" WHATAP_HOME)"
        [ -n "$envh" ] && _add_home "$envh" "environ of whatap_php pid $pid"
        exe="$(_link_target "/proc/$pid/exe")"
        [ -n "$exe" ] && [ -f "$exe" ] && _add_home "$(dirname "$exe")" "exe path of whatap_php pid $pid"
    done

    # service / unit / init files: install.sh writes the resolved php
    # environment into every one of them that exists
    _add_svc "$D_DEFAULT_HOME/whatap-php"
    _add_svc "/etc/init.d/whatap-php"
    _add_svc "/usr/lib/systemd/system/whatap-php.service"
    _add_svc "/lib/systemd/system/whatap-php.service"
    _add_svc "/etc/systemd/system/whatap-php.service"
    _add_svc "/etc/rc.d/whatap_php"
    printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r d; do
        [ -n "$d" ] && [ -f "$d/whatap-php" ] && printf '%s\n' "$d/whatap-php"
    done > /dev/null 2>&1

    # extension dirs and ini files declared by the service files
    printf '%s\n' "$D_SERVICE_FILES" | tr '|' '\n' | grep -v '^$' | while IFS= read -r p; do
        [ -f "$p" ] || continue
        grep -h 'WHATAP_PHP_EXT_HOME=' "$p" 2>/dev/null | sed 's/.*WHATAP_PHP_EXT_HOME=//; s/"$//'
    done > "$_errfile.extdirs" 2>/dev/null
    if [ -f "$_errfile.extdirs" ]; then
        while IFS= read -r d; do
            [ -n "$d" ] && _add_ext_dir "$d" "WHATAP_PHP_EXT_HOME in a service file"
        done < "$_errfile.extdirs"
        rm -f "$_errfile.extdirs" 2>/dev/null
    fi

    # whatap ini files: the installer copies template.ini to
    # <ini scan dir>/whatap.ini, and falls back to the agent home when PHP
    # reports no scan dir. Shallow globs over the known ini tree shapes
    # (RHEL, Debian/Ubuntu per-version+per-SAPI, Alpine, source builds).
    for p in /etc/php.d/whatap.ini /etc/php/conf.d/whatap.ini \
             /etc/php[0-9]*/conf.d/whatap.ini /etc/php[0-9]*/php.d/whatap.ini \
             /etc/php/*/mods-available/whatap.ini /etc/php/*/*/conf.d/*whatap.ini \
             /etc/php/*/conf.d/*whatap.ini \
             /usr/local/etc/php/conf.d/whatap.ini /usr/local/etc/php/conf.d/*whatap.ini \
             /usr/local/lib/php.d/whatap.ini /opt/remi/php*/root/etc/php.d/whatap.ini \
             "$D_DEFAULT_HOME"/whatap.ini; do
        _add_ini "$p"
    done
    printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u > "$_errfile.homes" 2>/dev/null
    if [ -f "$_errfile.homes" ]; then
        while IFS= read -r d; do
            [ -n "$d" ] && _add_ini "$d/whatap.ini"
        done < "$_errfile.homes"
        rm -f "$_errfile.homes" 2>/dev/null
    fi
}

# ---- report body ---------------------------------------------------------------
run_report() {
    emit_header

    # [1] capability preamble: every downstream "command not found" is
    # pre-explained here.
    section "Collection environment"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
    fact "tools:"
    for t in php php-fpm apachectl httpd apache2 nginx ipcs ss netstat systemctl rpm dpkg apk readlink timeout stat awk tr sha256sum; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present (%s)\n' "$t" "$(command -v "$t")"
        else printf '        %-12s absent\n' "$t"; fi
    done

    discover

    # [2] host / platform
    section "Host / platform"
    probe "kernel" uname -srm
    probe "machine arch" uname -m
    read_proc "os-release" /etc/os-release
    probe "libc" sh -c "ldd --version 2>&1 | head -n 1"
    probe "cpu count (nproc)" nproc
    fact "memory:"
    grep -E '^(MemTotal|MemAvailable)' /proc/meminfo 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
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
    probe "local time" date
    probe "utc time" date -u
    probe "pid 1 command" sh -c "tr '\0' ' ' < /proc/1/cmdline | cut -c1-160"

    # [3] PHP runtimes: one block per distinct binary. `php -i` is executed
    # once per binary and every field below is extracted from that capture.
    section "PHP runtimes and SAPIs"
    if [ -z "$D_PHP_BINS" ]; then
        fact "php binaries: n/a (none found on PATH, in the usual install paths, or among running processes)"
    fi
    local _n=0 php
    for php in $D_PHP_BINS; do
        _n=$((_n + 1))
        if [ "$_n" -gt 6 ]; then
            fact "-- more php binaries found but not detailed (cap: 6): $(echo $D_PHP_BINS | tr ' ' '\n' | tail -n +7 | tr '\n' ' ')"
            break
        fi
        fact "-- php binary: $php"
        fact "   resolves to: $(readlink -f "$php" 2>/dev/null || echo "$php")"
        php_run "   version" "$php" -v
        if php_info "$php"; then
            php_info_grep "   php version / system" '^(PHP Version|System) =>' 4
            php_info_grep "   SAPI" '^Server API =>' 2
            php_info_grep "   ini paths" '^(Configuration File \(php\.ini\) Path|Loaded Configuration File|Scan this dir for additional \.ini files) =>' 4
            php_info_block "   additional ini files parsed" '^Additional \.ini files parsed =>' 40
            php_info_grep "   php api / build" '^(PHP API|PHP Extension|Zend Extension|Zend Extension Build|PHP Extension Build|Debug Build|Thread Safety|Zend Signal Handling) =>' 10
            php_info_grep "   extension_dir" '^extension_dir =>' 2
            php_info_grep "   opcache" '^opcache\.(enable|enable_cli|jit|jit_buffer_size|preload) =>' 8
            php_info_grep "   whatap directives visible to this binary (local => master)" '^whatap\.' 80
            # extension_dir feeds the module-binding section
            _add_ext_dir "$(grep -E '^extension_dir =>' "$_infofile" 2>/dev/null | head -n1 | sed 's/.*=> *//; s/ *=>.*//')" "php -i of $php"
            # the ini files this binary actually parses feed the config section
            grep -E '^(Loaded Configuration File|Additional \.ini files parsed) =>' "$_infofile" 2>/dev/null \
                | sed 's/^[^=]*=> *//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
                | grep -i whatap > "$_errfile.ini" 2>/dev/null
            if [ -s "$_errfile.ini" ]; then
                while IFS= read -r _p; do _add_ini "$_p"; done < "$_errfile.ini"
            fi
            rm -f "$_errfile.ini" 2>/dev/null
        else
            fact "   php -i: n/a ($(_classify_err))"
        fi
        php_run "   extensions loaded (php -m)" "$php" -m
    done
    # co-resident tracers and profilers: they occupy the same hook surface
    fact "other APM / profiler extensions among the loaded module lists above:"
    _other=""
    for php in $D_PHP_BINS; do
        [ -x "$php" ] || continue
        _o="$( { "$php" -m | grep -iE 'newrelic|datadog|ddtrace|elastic|opentelemetry|otel|tideways|blackfire|xdebug|xhprof|pinpoint|scoutapm|instana' | tr '\n' ' ' ; } 2>/dev/null )"
        [ -n "$_o" ] && printf '        %-40s %s\n' "$php" "$_o" && _other="y"
    done
    [ -z "$_other" ] && fact "   none found (searched: newrelic, datadog/ddtrace, elastic, opentelemetry, tideways, blackfire, xdebug, xhprof, pinpoint, scoutapm, instana)"

    # [4] what actually serves the traffic
    section "Web server / application server layer"
    fact "web / application server binaries on PATH:"
    for c in httpd apache2 apachectl php-fpm php5-fpm php-cgi nginx lighttpd frankenphp rr; do
        p="$(command -v "$c" 2>/dev/null)"
        if [ -n "$p" ]; then printf '        %-12s present (%s)\n' "$c" "$p"
        else printf '        %-12s absent\n' "$c"; fi
    done
    for c in apachectl httpd apache2; do
        if have "$c"; then
            probe "$c -V (MPM, SERVER_CONFIG_FILE, compile settings)" sh -c "$c -V 2>&1 | head -n 30"
            probe "$c loaded modules (php / mpm entries)" sh -c "$c -M 2>&1 | grep -iE 'php|mpm|proxy_fcgi' | head -n 20"
            break
        fi
    done
    if have php-fpm; then probe "php-fpm version" sh -c "php-fpm -v 2>&1 | head -n 3"
    else fact "php-fpm version: n/a (command not found: php-fpm)"; fi
    fact "php-fpm configuration files on disk:"
    _found=0
    for p in /etc/php-fpm.conf /etc/php-fpm.d/*.conf /etc/php/*/fpm/php-fpm.conf /etc/php/*/fpm/pool.d/*.conf \
             /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.d/*.conf /etc/php[0-9]*/php-fpm.conf /etc/php[0-9]*/php-fpm.d/*.conf; do
        [ -f "$p" ] || continue
        _found=1
        printf '        %s\n' "$(ls -l "$p" 2>/dev/null)"
    done
    [ "$_found" = 0 ] && fact "   none found in the known php-fpm config locations"
    for p in /etc/php-fpm.d/www.conf /etc/php/*/fpm/pool.d/www.conf /usr/local/etc/php-fpm.d/www.conf /etc/php[0-9]*/php-fpm.d/www.conf; do
        [ -f "$p" ] || continue
        probe "   pool settings in $p" sh -c "grep -vE '^[[:space:]]*(;|$)' '$p' | head -n 60"
    done
    if have nginx; then probe "nginx version" sh -c "nginx -v 2>&1 | head -n 2"
    else fact "nginx version: n/a (command not found: nginx)"; fi
    fact "web / php processes found: $(echo $D_WEB_PIDS | wc -w | tr -d ' ')"
    _shown=0
    for pid in $D_WEB_PIDS; do
        _shown=$((_shown + 1))
        [ "$_shown" -gt 20 ] && { fact "-- remaining processes not detailed (cap: 20)"; break; }
        printf '        -- pid %s (ppid %s) comm=%s uid=%s\n' "$pid" \
            "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)" \
            "$(cat "/proc/$pid/comm" 2>/dev/null)" \
            "$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
        printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
        printf '           exe: %s\n' "$(_link_target "/proc/$pid/exe" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
    done
    if [ -z "$D_ALT_PIDS" ]; then
        fact "persistent-worker PHP runtimes (swoole/octane/roadrunner/frankenphp/workerman/php-pm): none found by comm or cmdline"
    else
        fact "persistent-worker PHP runtimes found (per-request extension hooks do not bound their request cycle the same way):"
        for pid in $D_ALT_PIDS; do
            printf '        -- pid %s comm=%s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
            printf '           cwd: %s\n' "$(_link_target "/proc/$pid/cwd" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
        done
    fi

    # [5] the agent package as it sits on disk
    section "WhaTap PHP agent installation on disk"
    fact "env WHATAP_HOME (collector shell): ${WHATAP_HOME:-not set}"
    if [ -z "$D_HOMES" ]; then
        fact "agent home candidates: none discovered (env, $D_DEFAULT_HOME, process scan all empty)"
    else
        fact "agent home candidates discovered:"
        printf '%s\n' "$D_HOMES" | while IFS='|' read -r _p _s; do printf '        %s   <- %s\n' "$_p" "$_s"; done
    fi
    printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")"
        if [ -z "$fshome" ]; then fact "-- home $home: n/a (path not visible from this mount namespace)"; continue; fi
        fact "-- home: $home"
        [ "$fshome" != "$home" ] && fact "   filesystem view: $fshome (read through a process root)"
        probe "   listing" sh -c "ls -la '$fshome' 2>/dev/null | head -n 40"
        for b in whatap_php whatap_php_static; do
            file_facts "   agent binary $b" "$fshome/$b"
        done
        # the agent binary prints its build when called with `version`; calling
        # it bare would start an agent, so only this argument is ever used
        if [ -x "$fshome/whatap_php" ]; then
            probe "   whatap_php version" "$fshome/whatap_php" version
        elif [ -x "$fshome/whatap_php_static" ]; then
            probe "   whatap_php_static version" "$fshome/whatap_php_static" version
        else
            fact "   agent binary version: n/a (no executable whatap_php / whatap_php_static in $fshome)"
        fi
        head_file "   ChangeLog (top: shipped agent version and date)" "$fshome/ChangeLog" 6
        file_facts "   install.sh" "$fshome/install.sh"
        dump_file "   template.ini (installer's ini template)" "$fshome/template.ini" 60
        # the PHP-version -> Zend API table the INSTALLED installer uses, read
        # from that installer rather than assumed
        if [ -r "$fshome/install.sh" ]; then
            _map="$(sed -n '/get_php_api_version()/,/^}/p' "$fshome/install.sh" 2>/dev/null | grep -oE '"[0-9]+\.[0-9]+"\) PHP_API="[0-9]+"' | tr -d '"' | sed 's/) PHP_API=/ -> /' | tr '\n' ' ')"
            if [ -n "$_map" ]; then fact "   php version -> PHP API map in this install.sh: $_map"
            else fact "   php version -> PHP API map: n/a (no get_php_api_version block in $fshome/install.sh)"; fi
        fi
        if [ -d "$fshome/modules" ]; then
            probe "   shipped tracer modules per arch (count)" sh -c "for d in '$fshome'/modules/*; do [ -d \"\$d\" ] && echo \"\$(basename \$d): \$(ls \$d 2>/dev/null | wc -l | tr -d ' ') files\"; done"
            probe "   shipped tracer modules (names)" sh -c "ls '$fshome'/modules/*/ 2>/dev/null | tr '\n' ' ' | cut -c1-1200"
        else
            fact "   modules dir: n/a (path not found: $fshome/modules)"
        fi
        [ -d "$fshome/lib/Whatap" ] && probe "   bundled PHP API helpers" sh -c "ls '$fshome/lib/Whatap' 2>/dev/null" \
            || fact "   bundled PHP API helpers (lib/Whatap): absent"
    done
    fact "package manager records (the Alpine tarball install leaves none by design):"
    if have rpm; then probe "   rpm -q whatap-php" sh -c "rpm -q whatap-php 2>&1 | head -n 3"
    else fact "   rpm: n/a (command not found: rpm)"; fi
    if have dpkg; then probe "   dpkg -l whatap-php" sh -c "dpkg -l whatap-php 2>&1 | tail -n 3"
    else fact "   dpkg: n/a (command not found: dpkg)"; fi
    if have apk; then probe "   apk info whatap-php" sh -c "apk info -v whatap-php 2>&1 | head -n 3"
    else fact "   apk: n/a (command not found: apk)"; fi

    # [6] how the tracer is bound to each PHP runtime
    section "Tracer binding: whatap.so, ini placement, live load status"
    if [ -z "$D_EXT_DIRS" ]; then
        fact "extension_dir values: none discovered (php -i and service files both empty)"
    else
        fact "extension_dir values discovered:"
        printf '%s\n' "$D_EXT_DIRS" | while IFS='|' read -r _d _s; do printf '        %s   <- %s\n' "$_d" "$_s"; done
        printf '%s\n' "$D_EXT_DIRS" | cut -d'|' -f1 | sort -u | while IFS= read -r d; do
            [ -n "$d" ] || continue
            fsd="$(resolve_fs "$d")"
            if [ -z "$fsd" ]; then fact "-- extension_dir $d: n/a (path not visible from this mount namespace)"; continue; fi
            fact "-- extension_dir: $d"
            if [ -e "$fsd/whatap.so" ]; then
                file_facts "   whatap.so" "$fsd/whatap.so"
                _t="$(readlink -f "$fsd/whatap.so" 2>/dev/null)"
                if [ -n "$_t" ]; then
                    _b="$(basename "$_t")"
                    fact "   module file it resolves to: $_b (name encodes: thread-safe build = $(case "$_b" in *_zts_*) echo yes ;; *) echo no ;; esac), PHP API = $(echo "$_b" | grep -oE '[0-9]{8}' | head -n1))"
                fi
            else
                fact "   whatap.so: n/a (path not found: $d/whatap.so)"
            fi
            probe "   other whatap* files in this dir" sh -c "ls -la '$fsd' 2>/dev/null | grep -i whatap | head -n 10"
        done
    fi
    fact "whatap ini files found on disk:"
    if [ -z "$D_INI_FILES" ]; then
        fact "   none found (searched the RHEL, Debian/Ubuntu per-SAPI, Alpine, source-build and agent-home ini locations)"
    else
        printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do
            printf '        %s\n' "$(ls -l "$p" 2>/dev/null)"
        done
    fi
    fact "php.ini files carrying whatap lines (the installer's fallback when PHP reports no ini scan dir):"
    _hit=0
    for p in /etc/php.ini /etc/php/*/*/php.ini /etc/php[0-9]*/php.ini /usr/local/etc/php/php.ini /usr/local/lib/php.ini /opt/remi/php*/root/etc/php.ini; do
        [ -f "$p" ] || continue
        _c="$(grep -c -i whatap "$p" 2>/dev/null)"
        [ "${_c:-0}" -gt 0 ] || continue
        _hit=1
        fact "   -- $p (${_c} whatap line(s)):"
        grep -n -i whatap "$p" 2>/dev/null | head -n 30 | while IFS= read -r _l; do printf '           %s\n' "$_l"; done
    done
    [ "$_hit" = 0 ] && fact "   none found"
    fact "ini directory trees present (per-SAPI trees are separate: a file in the cli tree is not read by fpm or apache):"
    _hit=0
    for d in /etc/php.d /etc/php/*/cli/conf.d /etc/php/*/fpm/conf.d /etc/php/*/apache2/conf.d /etc/php/*/mods-available \
             /etc/php[0-9]*/conf.d /usr/local/etc/php/conf.d /opt/remi/php*/root/etc/php.d; do
        [ -d "$d" ] || continue
        _hit=1
        printf '        %-46s %s\n' "$d" "$(ls "$d" 2>/dev/null | grep -i whatap | tr '\n' ' ' | sed 's/^$/(no whatap entry)/')"
    done
    [ "$_hit" = 0 ] && fact "   none of the known ini tree paths exist on this host"
    fact "live load status — whatap module mapped into running processes (from /proc/<pid>/maps):"
    _any=0
    for pid in $D_WEB_PIDS $D_ALT_PIDS; do
        if cat "/proc/$pid/maps" >/dev/null 2>&1; then
            _m="$(awk '$NF ~ /whatap/ {print $NF}' "/proc/$pid/maps" 2>/dev/null | sort -u | tr '\n' ' ')"
            if [ -n "$_m" ]; then
                _any=1
                printf '        pid %-7s comm=%-12s maps: %s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)" "$_m"
            fi
        fi
    done
    if [ "$_any" = 0 ]; then
        if [ -z "$D_WEB_PIDS$D_ALT_PIDS" ]; then
            fact "   no web/php processes found to inspect"
        else
            fact "   no whatap module path present in the memory maps of the processes listed above (maps unreadable for other users' processes when not root)"
        fi
    fi

    # [7] configuration content, verbatim
    section "Agent configuration (verbatim)"
    if [ -z "$D_INI_FILES" ]; then
        fact "whatap ini files: none found to dump"
    else
        printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do
            conf_bytes "-- $p" "$p"
            dump_file "   content" "$p" 300
        done
    fi
    fact "service / unit / init files written by install.sh (they carry the environment the agent starts with):"
    if [ -z "$D_SERVICE_FILES" ]; then
        fact "   none found (searched agent home, /etc/init.d, systemd unit dirs, /etc/rc.d)"
    else
        printf '%s\n' "$D_SERVICE_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do
            dump_file "-- $p" "$p" 120
        done
    fi
    fact "WHATAP_* environment of the running processes:"
    _any=0
    for pid in $D_AGENT_PIDS $D_WEB_PIDS $D_ALT_PIDS; do
        if [ -r "/proc/$pid/environ" ]; then
            _e="$( { tr '\0' '\n' < "/proc/$pid/environ" | grep -E '^WHATAP_' | tr '\n' ' ' ; } 2>/dev/null )"
            if [ -n "$_e" ]; then _any=1; printf '        pid %-7s comm=%-16s %s\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null)" "$_e"; fi
        else
            printf '        pid %-7s environ: n/a (permission denied: /proc/%s/environ)\n' "$pid" "$pid"
        fi
    done
    [ "$_any" = 0 ] && fact "   no WHATAP_* variable found in the environ of the processes inspected"
    # app_process_name drives the process-memory metric; the matching live
    # process count is the fact that makes it verifiable
    _apn="$(printf '%s\n' "$D_INI_FILES" | tr '|' '\n' | grep -v '^$' | sort -u | while IFS= read -r p; do grep -h '^[[:space:]]*whatap\.app_process_name' "$p" 2>/dev/null; done | head -n1 | sed 's/.*= *//')"
    if [ -n "$_apn" ]; then
        fact "whatap.app_process_name configured value: $_apn"
        fact "processes whose comm matches that value right now: $(ls /proc 2>/dev/null | grep -E '^[0-9]+$' | while read -r p; do cat "/proc/$p/comm" 2>/dev/null; done | grep -c "^${_apn}$")"
    else
        fact "whatap.app_process_name: not set in any ini file found"
    fi
    # key material: presence only, by data scope (this is not masking of a
    # dumped file — the file is not collected at all)
    fact "agent key material files (content not collected — data scope: encryption key material):"
    [ -z "$D_HOMES" ] && fact "   n/a (no agent home discovered)"
    printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")" || continue
        for f in security.conf paramkey.txt; do
            if [ -e "$fshome/$f" ]; then printf '        %s\n' "$(ls -l "$fshome/$f" 2>/dev/null)"
            else printf '        %-46s absent\n' "$fshome/$f"; fi
        done
    done

    # [8] the agent process and its channels
    section "Agent process, service state and channels"
    if [ -z "$D_AGENT_PIDS" ]; then
        fact "whatap_php processes: none found in /proc (comm is capped at 15 chars, so the musl build appears as whatap_php_stat)"
    else
        fact "whatap_php processes:"
        for pid in $D_AGENT_PIDS; do
            printf '        -- pid %s (ppid %s)\n' "$pid" "$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
            printf '           comm: %s\n' "$(cat "/proc/$pid/comm" 2>/dev/null)"
            printf '           cmdline: %s\n' "$(_proc_cmd "$pid")"
            printf '           exe: %s\n' "$(_link_target "/proc/$pid/exe" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
            printf '           cwd: %s\n' "$(_link_target "/proc/$pid/cwd" || echo 'n/a (unresolvable: exited, zombie, or permission denied)')"
            printf '           uid/state/threads: %s\n' "$(awk '/^Uid:/{u=$2} /^State:/{s=$2" "$3} /^Threads:/{t=$2} END{print u" / "s" / "t}' "/proc/$pid/status" 2>/dev/null)"
            _rss="$(awk '/^VmRSS:/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"
            printf '           rss: %s\n' "${_rss:-n/a (no VmRSS line: zombie or permission denied)}"
            printf '           start time: %s\n' "$(_proc_start "$pid")"
        done
    fi
    printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")" || continue
        if [ -f "$fshome/whatap_php.pid" ]; then
            _pid="$(cat "$fshome/whatap_php.pid" 2>/dev/null | tr -d ' \n')"
            if [ -n "$_pid" ] && [ -d "/proc/$_pid" ]; then
                fact "pid file $home/whatap_php.pid: $_pid (process exists; comm: $(cat "/proc/$_pid/comm" 2>/dev/null))"
            else
                fact "pid file $home/whatap_php.pid: ${_pid:-empty} (no process with this pid in this pid namespace)"
            fi
        else
            fact "pid file $home/whatap_php.pid: n/a (path not found)"
        fi
    done
    probe "systemd unit state (whatap-php)" sh -c "systemctl is-enabled whatap-php 2>&1; systemctl is-active whatap-php 2>&1"
    probe "systemd unit status (first 20 lines)" sh -c "systemctl status whatap-php --no-pager 2>&1 | head -n 20"
    probe "sysv service status" sh -c "[ -x /etc/init.d/whatap-php ] && /etc/init.d/whatap-php status 2>&1 | head -n 5 || echo 'n/a (path not found: /etc/init.d/whatap-php)'"
    if have ss; then
        probe "udp sockets (whatap or ports 66xx)" sh -c "ss -ulnp 2>/dev/null | awk 'NR==1 || /whatap/ || /:66[0-9][0-9] /' | head -n 40"
        probe "tcp sessions (whatap or port 6600)" sh -c "ss -tnp 2>/dev/null | awk 'NR==1 || /whatap/ || /:6600/' | head -n 40"
    elif have netstat; then
        probe "udp sockets (whatap or ports 66xx)" sh -c "netstat -ulnp 2>/dev/null | awk 'NR<=2 || /whatap/ || /:66[0-9][0-9] /' | head -n 40"
        probe "tcp sessions (whatap or port 6600)" sh -c "netstat -tnp 2>/dev/null | awk 'NR<=2 || /whatap/ || /:6600/' | head -n 40"
    else
        fact "socket listing: n/a (command not found: ss, netstat); raw tables follow"
        probe "raw /proc/net/udp (first 30 lines, ports in hex)" sh -c "head -n 30 /proc/net/udp"
        probe "raw /proc/net/tcp (first 30 lines, ports in hex)" sh -c "head -n 30 /proc/net/tcp"
    fi
    # the tracer and the agent also share SysV shared memory + a semaphore;
    # install.sh removes key 6600 (0x19c8) on uninstall
    probe "sysv shared memory segments" sh -c "ipcs -m 2>/dev/null | head -n 30"
    probe "sysv semaphore arrays" sh -c "ipcs -s 2>/dev/null | head -n 30"

    # [9] logs
    section "Agent logs and web server error markers"
    if [ -z "$D_HOMES" ]; then
        fact "no agent home discovered; no agent log locations to read"
    else
        printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
            [ -n "$home" ] || continue
            fshome="$(resolve_fs "$home")" || continue
            fact "-- home: $home"
            if [ -d "$fshome/logs" ]; then
                probe "   logs dir listing" sh -c "ls -la '$fshome/logs' 2>/dev/null | head -n 60"
                _boot="$(ls -t "$fshome"/logs/whatap-boot-*.log 2>/dev/null | head -n 1)"
                if [ -n "$_boot" ]; then
                    head_file "   $(basename "$_boot") (first lines: startup banner and configuration)" "$_boot" 80
                    _tot="$(wc -l < "$_boot" 2>/dev/null | tr -d ' ')"
                    if [ "${_tot:-0}" -gt 80 ]; then
                        tail_file "   $(basename "$_boot") (recent lines)" "$_boot" 150
                    else
                        fact "   $(basename "$_boot"): ${_tot:-?} lines total — the block above is the whole file"
                    fi
                else
                    fact "   whatap-boot-*.log: n/a (no such file in $fshome/logs)"
                fi
                _inst="$(ls -t "$fshome"/logs/whatap-install-*.log 2>/dev/null | head -n 1)"
                if [ -n "$_inst" ]; then
                    tail_file "   $(basename "$_inst") (what install.sh resolved on this host)" "$_inst" 120
                else
                    fact "   whatap-install-*.log: n/a (no such file in $fshome/logs)"
                fi
            else
                fact "   logs dir: n/a (path not found: $fshome/logs)"
            fi
        done
    fi
    # the tracer writes its own messages (WA-coded) to the web server error log
    fact "web server error logs — last 300 lines scanned for whatap / WA-coded lines:"
    _hit=0
    for p in /var/log/httpd/error_log /var/log/apache2/error.log /var/log/php-fpm/error.log \
             /var/log/php-fpm.log /var/log/php[0-9]*-fpm.log /var/log/php/*.log \
             /usr/local/var/log/php-fpm.log /var/log/nginx/error.log; do
        [ -f "$p" ] || continue
        [ -r "$p" ] || { fact "   -- $p: n/a (permission denied)"; continue; }
        _hit=1
        _m="$(tail -n 300 "$p" 2>/dev/null | grep -E 'whatap|WA[0-9]{3}|Whatap' | tail -n 40)"
        if [ -n "$_m" ]; then
            fact "   -- $p (matching lines, last 40):"
            printf '%s\n' "$_m" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else
            fact "   -- $p: no whatap / WA-coded line in the last 300 lines"
        fi
    done
    [ "$_hit" = 0 ] && fact "   none of the known web server error log paths exist and are readable here"

    # [10] container / orchestration context
    section "Container / Kubernetes context"
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
    printf '%s\n' "$D_HOMES" | cut -d'|' -f1 | sort -u | while IFS= read -r home; do
        [ -n "$home" ] || continue
        fshome="$(resolve_fs "$home")" || continue
        dump_file "container.conf in $home" "$fshome/container.conf" 60
    done
    for v in POD_NAME NODE_NAME POD_NAMESPACE OKIND ONAME ONODE; do
        eval "_val=\${$v:-}"
        [ -n "$_val" ] && fact "env $v: $_val"
    done
    [ -d /var/run/secrets/kubernetes.io ] && fact "/var/run/secrets/kubernetes.io: present" || fact "/var/run/secrets/kubernetes.io: absent"
    read_proc "container hostname (/etc/hostname)" /etc/hostname

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
