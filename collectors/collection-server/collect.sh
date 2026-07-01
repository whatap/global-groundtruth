#!/usr/bin/env bash
#
# WhaTap Global Groundtruth — collection-server collector (seeded v0)
# -----------------------------------------------------------------------------
# Gathers facts about a WhaTap backend host (yard/proxy/gateway/keeper/account/
# notihub/eureka/front/...) so a remote developer does not have to ask the field
# engineer twenty questions. Emits the shared report shape (docs/output-format.md)
# to a single .txt file; with --bundle it also archives real logs, configs and
# host snapshots as a tar.gz.
#
# THE CONTRACT (../../CONTRACT.md) — facts only, no diagnosis / no judgment.
# DESIGN GUIDELINES (../../docs/collector-engineering.md):
#   * MECE sections     — every fact lives in exactly one domain (A..F below).
#   * Load-safe by tier — Tier 0 (default report) never runs a command that can
#                         pause a JVM (jstack/jmap), walk a huge tree (recursive
#                         du) or read whole rotated logs. Heavy probes are opt-in.
#   * Portable          — read /proc and /sys first; fall back through command
#                         chains; target bash 3.2+; assume nothing about the OS.
#   * Reasoned absence  — a value we cannot obtain is a fact too, carrying WHY
#                         (command not found / permission denied / path not found
#                         / timed out / not applicable / empty output).
#
# NOTE: no `set -e` / no `set -u`. A collector must run to completion and emit
# its footer even when individual steps fail; each step guards itself.
# -----------------------------------------------------------------------------

export LC_ALL=C

# ---- collector metadata -----------------------------------------------------
COLLECTOR_NAME="whatap-collection-server"
VERSION="0.3.0"
DOMAIN="collection-server"
TARGET="collection-server/$(hostname 2>/dev/null || echo unknown)"   # refined after WHATAP_HOME is resolved

# ---- options ----------------------------------------------------------------
OPT_BUNDLE=0
OPT_FILE=0           # write the Tier 0 report to a .txt file
OPT_STDOUT=0
OPT_QUIET=0          # suppress progress narration on stderr
OPT_HOME=""
OPT_OUT="."
OPT_HOURS=24
OPT_MAXLOG_MB=50
OPT_LOG_DAYS=14      # bundle: copy rotated logs only from the last N days
OPT_THREADS=0        # Tier 2: jstack iterations (0 = off)
OPT_HISTO=0          # Tier 2: jmap -histo (no :live)
OPT_HEAP=0           # Tier 2: full heap dump
OPT_DU=0             # Tier 2: recursive du of yardbase
OPT_TIMEREF=0        # Tier 2: compare clock to an external time source (network call)
TIMEREF_SERVER="pool.ntp.org"

usage() {
    cat <<'EOF'
Run on the collection-server host. Produces one facts .txt or a tar.gz.
Run with no arguments (or --help) to print this help — a collection needs an
explicit action flag (--file / --stdout / --bundle) so nothing starts by accident.

  collect.sh                          print this help (no collection)
  collect.sh --file                   Tier 0 facts report -> one .txt file
  collect.sh --stdout                 print the report to stdout instead of a file
  collect.sh --bundle                 Tier 0 report + Tier 1 artifacts -> tar.gz
  collect.sh --quiet ...              silence progress on stderr (for automation)
  collect.sh --home DIR               force WHATAP_HOME (else auto-resolved)
  collect.sh --out DIR                output directory (default: .)
  collect.sh --bundle --hours N       journal window for the bundle (default: 24)
  collect.sh --bundle --max-log-mb M  per-file log copy cap (default: 50)
  collect.sh --bundle --log-days N    copy rotated logs from the last N days (default: 14)

  Tier 2 (opt-in, may add load — printed to stderr before running):
  collect.sh --bundle --threads[=N]   jstack -l each JVM N times (default N=1)
  collect.sh --bundle --histo         jmap -histo (NOT :live, no full GC)
  collect.sh --bundle --heap          full heap dump (large, pauses the JVM)
  collect.sh --bundle --du            recursive du of yardbase (data-disk I/O)
  collect.sh --file --time-ref[=SRV]  also compare the clock to an external NTP/
                                      HTTP source (network call; clock not set)
EOF
}

ARGC=$#              # 0 args -> usage (handled in main, below)
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) OPT_BUNDLE=1 ;;
        --file) OPT_FILE=1 ;;
        --stdout) OPT_STDOUT=1 ;;
        --quiet) OPT_QUIET=1 ;;
        --home) OPT_HOME="$2"; shift ;;
        --home=*) OPT_HOME="${1#*=}" ;;
        --out) OPT_OUT="$2"; shift ;;
        --out=*) OPT_OUT="${1#*=}" ;;
        --hours) OPT_HOURS="$2"; shift ;;
        --hours=*) OPT_HOURS="${1#*=}" ;;
        --max-log-mb) OPT_MAXLOG_MB="$2"; shift ;;
        --max-log-mb=*) OPT_MAXLOG_MB="${1#*=}" ;;
        --log-days) OPT_LOG_DAYS="$2"; shift ;;
        --log-days=*) OPT_LOG_DAYS="${1#*=}" ;;
        --threads) OPT_THREADS=1 ;;
        --threads=*) OPT_THREADS="${1#*=}" ;;
        --histo) OPT_HISTO=1 ;;
        --heap) OPT_HEAP=1 ;;
        --du) OPT_DU=1 ;;
        --time-ref) OPT_TIMEREF=1 ;;
        --time-ref=*) OPT_TIMEREF=1; TIMEREF_SERVER="${1#*=}" ;;
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

# try CMD...  -> output as facts, or a bare "n/a" (kept for simple cases).
try() {
    local out
    if out="$("$@" 2>/dev/null)" && [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do fact "$line"; done
    else
        fact "n/a"
    fi
}

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
        *"o such file"*|*"annot access"*|*"oes not exist"*|*"o such device"*)
            echo "path not found"; return ;;
    esac
    if [ -n "$txt" ]; then
        printf 'error: %s' "$(printf '%s' "$txt" | head -n1 | cut -c1-100)"
    else
        echo "nonzero exit"
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
        printf '%s\n' "$body" | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
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

# probe_merged: like probe but folds stderr into stdout (for tools that print to
# stderr, e.g. `java -version`).
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

# read_proc "label" PATH -> emits a /proc or /sys file's content with a reason.
read_proc() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then fact "$label: n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "$label: n/a (permission denied: $path)"; return; fi
    local out; out="$(cat "$path" 2>"$_errfile")"
    if [ -z "$out" ]; then fact "$label: n/a (empty output)"; return; fi
    _emit_labeled "$label" "$out"
}

# dump_file PATH -> emits a file's full content (bounded), or a reason.
dump_file() {
    local path="$1" cap="${2:-4000}"
    if [ ! -e "$path" ]; then fact "n/a (path not found: $path)"; return; fi
    if [ ! -r "$path" ]; then fact "n/a (permission denied: $path)"; return; fi
    if [ ! -s "$path" ]; then fact "(empty file)"; return; fi
    head -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}

warn() { printf '%s\n' "$*" >&2; }

# progress: operational narration to the terminal (fd 3, saved from stderr in main
# before any stdout/stderr redirection). It NEVER lands in the report — stdout stays
# byte-for-byte the report even in --file mode. Silenced by --quiet. Keep the text a
# fact about collection state (no judgment words) so validate.sh keeps passing.
progress() { [ "$OPT_QUIET" = 1 ] && return; printf '>> %s\n' "$*" >&3 2>/dev/null; }

# ---- portable helpers -------------------------------------------------------
cmdline_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }

get_listen_ports() {
    if have ss; then
        ss -ltn 2>/dev/null | awk 'NR>1{n=split($4,a,":"); print a[n]}'
    elif have netstat; then
        netstat -ltn 2>/dev/null | awk '/^tcp/{n=split($4,a,":"); print a[n]}'
    else
        # /proc/net/tcp{,6}: state 0A == LISTEN; local port is hex after ':'
        awk '$4=="0A"{split($2,a,":"); print a[2]}' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
            | while IFS= read -r h; do [ -n "$h" ] && printf '%d\n' "$((16#$h))"; done
    fi
}

fstype_of() {
    local p="$1"
    if have findmnt; then findmnt -no FSTYPE -T "$p" 2>/dev/null && return; fi
    if have stat; then stat -f -c '%T' "$p" 2>/dev/null && return; fi
    echo ""
}

source_of() {
    local p="$1"
    have findmnt && findmnt -no SOURCE -T "$p" 2>/dev/null
}

# systemd helpers — avoid `--value` (unsupported on systemd <230 / Ubuntu 16.04)
sd_show() { have systemctl && systemctl show -p "$1" "$2.service" 2>/dev/null | cut -d= -f2-; }
unit_loaded() { [ "$(sd_show LoadState "$1")" = "loaded" ]; }

WHATAP_UNITS="yard proxy gateway keeper account notihub eureka front router billing crane flexreport"

# ---- discovery (run once) ---------------------------------------------------
# PIDS[] and MODS[] are parallel indexed arrays of discovered whatap JVMs.
discover_services() {
    PIDS=(); MODS=()
    local d pid cl mod
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cl="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
        case "$cl" in
            *whatap.server.*|*whatap.opslake.*|*.yard.boot*)
                pid="${d#/proc/}"
                # module name comes from the jar (reliable), not the first cmdline
                # token — otherwise "-Dwhatap.server.home=" would win every time.
                local _jar _mod
                _jar="$(printf '%s\n' "$cl" | grep -oE 'whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar' | head -n1)"
                if [ -n "$_jar" ]; then
                    _mod="$(printf '%s' "$_jar" | grep -oE 'whatap\.(server|opslake)\.[a-zA-Z0-9]+' | head -n1)"
                else
                    _mod="$(printf '%s\n' "$cl" | tr ' ' '\n' | grep -oE 'whatap\.(server|opslake)\.[a-zA-Z0-9]+' | grep -vE '\.(home|conf|path|timezone)$' | head -n1)"
                fi
                mod="$_mod"
                [ -z "$mod" ] && mod="whatap.(unknown-module)"
                PIDS[${#PIDS[@]}]="$pid"
                MODS[${#MODS[@]}]="$mod"
                ;;
        esac
    done
}

WHOME=""
WHOME_SRC=""
resolve_home() {
    local i pid cl v unit wd
    if [ -n "$OPT_HOME" ]; then WHOME="$OPT_HOME"; WHOME_SRC="option --home"; return; fi
    # from a running JVM's -Dwhatap.server.home=
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; cl="$(cmdline_of "$pid")"
        v="$(printf '%s\n' "$cl" | grep -oE '[-]Dwhatap\.server\.home=[^ ]+' | head -n1 | cut -d= -f2-)"
        if [ -n "$v" ]; then WHOME="$v"; WHOME_SRC="process $pid (-Dwhatap.server.home)"; return; fi
        i=$((i + 1))
    done
    # from a systemd unit WorkingDirectory
    if have systemctl; then
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            wd="$(sd_show WorkingDirectory "$unit")"
            if [ -n "$wd" ] && [ "$wd" != "/" ]; then WHOME="$wd"; WHOME_SRC="systemd $unit.service WorkingDirectory"; return; fi
        done
    fi
    # from script location (if collect.sh was copied into $WHATAP_HOME/bin)
    local sd; sd="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
    if [ -n "$sd" ] && [ -d "$sd/../conf" ] && [ -d "$sd/../logs" ]; then
        WHOME="$(cd "$sd/.." && pwd)"; WHOME_SRC="script parent dir"; return
    fi
    WHOME=""; WHOME_SRC="n/a (not resolved)"
}

YARDBASE=""
resolve_yardbase() {
    local v
    if [ -n "$WHOME" ] && [ -f "$WHOME/conf/yard.conf" ]; then
        v="$(grep -E '^[[:space:]]*yardbase[[:space:]]*=' "$WHOME/conf/yard.conf" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d ' \r')"
        [ -n "$v" ] && YARDBASE="$v"
    fi
    if [ -z "$YARDBASE" ] && [ -n "$WHOME" ] && [ -d "$WHOME/yardbase" ]; then YARDBASE="$WHOME/yardbase"; fi
    # resolve relative to WHATAP_HOME
    case "$YARDBASE" in
        ""|/*) : ;;
        *) [ -n "$WHOME" ] && YARDBASE="$WHOME/$YARDBASE" ;;
    esac
}

# time_ref_probe: opt-in external time comparison (--time-ref). Makes ONE network
# call and NEVER sets the clock. Tries ntpdate -q, then sntp, then an HTTPS Date
# header. Emitted as facts (raw output + numeric delta); the reader interprets.
time_ref_probe() {
    warn "[time-ref] querying $TIMEREF_SERVER — this makes a network call (the clock is not modified)"
    progress "querying external time reference ($TIMEREF_SERVER) — network call"
    if have ntpdate; then
        probe "ntpdate -q $TIMEREF_SERVER (query only)" ntpdate -q "$TIMEREF_SERVER"
    elif have sntp; then
        probe "sntp $TIMEREF_SERVER" sntp "$TIMEREF_SERVER"
    elif have curl; then
        local hdr rt lt d
        hdr="$(curl -sI --max-time 10 https://www.google.com 2>"$_errfile" | grep -i '^date:' | head -n1 | cut -d' ' -f2-)"
        if [ -n "$hdr" ]; then
            fact "HTTP Date header (https://www.google.com): $hdr"
            rt="$(date -u -d "$hdr" +%s 2>/dev/null)"; lt="$(date -u +%s 2>/dev/null)"
            if [ -n "$rt" ] && [ -n "$lt" ]; then d=$((lt - rt)); fact "local clock minus reference: ${d}s (1s resolution + network latency)"; fi
        else
            fact "external time: n/a ($(_classify_err))"
        fi
    else
        fact "external time: n/a (command not found: ntpdate/sntp/curl)"
    fi
}

# =============================================================================
# Report body (Tier 0 — MECE domains A..G)
# =============================================================================
run_report() {
    emit_header

    section "Collection environment"
    fact "collector: $COLLECTOR_NAME $VERSION"
    fact "bash: ${BASH_VERSION:-unknown}"
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($( [ "$(id -u 2>/dev/null)" = 0 ] && echo root || echo non-root ))"
    fact "tools:"
    local t
    for t in ss netstat findmnt df stat systemctl journalctl timedatectl chronyc ntpq zfs zpool jstack jmap jcmd java timeout du tar ps awk; do
        if command -v "$t" >/dev/null 2>&1; then printf '        %-12s present\n' "$t"; else printf '        %-12s absent\n' "$t"; fi
    done
    fact "note: every 'n/a (...)' below names why a value was not obtained"

    # -- A. Host & platform ---------------------------------------------------
    section "A. Host & platform"
    probe "hostname" hostname
    probe "kernel" uname -sr
    probe "arch" uname -m
    read_proc "os-release" /etc/os-release
    probe "date(UTC)" date -u +%Y-%m-%dT%H:%M:%SZ
    fact "timezone: $( { cat /etc/timezone 2>/dev/null; } || date +%Z 2>/dev/null || echo n/a )"
    read_proc "uptime" /proc/uptime
    fact "nproc: $(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo n/a)"
    if have free; then probe "memory (free -m)" free -m; else read_proc "meminfo" /proc/meminfo; fi
    read_proc "loadavg" /proc/loadavg
    subsection "cgroup limits (container-aware)"
    read_proc "cgroup v2 memory.max" /sys/fs/cgroup/memory.max
    read_proc "cgroup v2 cpu.max" /sys/fs/cgroup/cpu.max
    read_proc "cgroup v1 memory.limit_in_bytes" /sys/fs/cgroup/memory/memory.limit_in_bytes
    probe_merged "java -version" java -version

    # -- B. Time & clock synchronization --------------------------------------
    # Clock skew on a collection server puts data in the wrong time buckets and
    # trips time-based queries/alerts. These are facts about the clock and its
    # sync state (no judgment). "Wrong" needs a reference: the running NTP daemon
    # already computed its offset, so Tier 0 harvests that with NO network call;
    # an external comparison is opt-in (--time-ref) because it hits the network.
    section "B. Time & clock synchronization"
    probe "timedatectl" timedatectl
    fact "system timezone: $( { cat /etc/timezone 2>/dev/null; } || { readlink -f /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##'; } || echo 'n/a' )"
    fact "local time: $(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo n/a)"
    fact "UTC time:   $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo n/a)"
    read_proc "clocksource" /sys/devices/system/clocksource/clocksource0/current_clocksource
    fact "virtualization: $(systemd-detect-virt 2>/dev/null || echo 'n/a (command not found or bare metal)')"
    # WhaTap servers run with -Duser.timezone (yard forces GMT); surface it per JVM.
    local jtz="" _ti _tz
    _ti=0
    while [ "$_ti" -lt "${#PIDS[@]}" ]; do
        _tz="$(cmdline_of "${PIDS[$_ti]}" | grep -oE '[-]Duser\.timezone=[^ ]+' | head -n1)"
        [ -n "$_tz" ] && jtz="$jtz ${MODS[$_ti]}=${_tz#*=}"
        _ti=$((_ti + 1))
    done
    fact "JVM -Duser.timezone (running servers):${jtz:- n/a (no running whatap JVM or flag unset)}"
    subsection "NTP client offset (reads the running daemon — no network call)"
    if have chronyc; then
        probe "chronyc tracking" chronyc tracking
        probe "chronyc sources" chronyc -n sources
    elif have ntpq; then
        probe "ntpq -pn" ntpq -pn
    elif have timedatectl; then
        probe "timedatectl timesync-status" timedatectl timesync-status
    else
        fact "NTP offset: n/a (no chrony/ntpd/timesyncd client found)"
    fi
    subsection "time-sync service state"
    if have systemctl; then
        local _sd _sany=0
        for _sd in chrony chronyd systemd-timesyncd ntp ntpd ntpsec; do
            unit_loaded "$_sd" || continue
            _sany=1
            fact "$_sd.service: active=$(systemctl is-active "$_sd.service" 2>/dev/null) enabled=$(systemctl is-enabled "$_sd.service" 2>/dev/null)"
        done
        [ "$_sany" = 0 ] && fact "no chrony/ntpd/timesyncd *.service loaded"
    else
        fact "time-sync service: n/a (command not found: systemctl)"
    fi
    if [ "$OPT_TIMEREF" = 1 ]; then
        subsection "external time reference (opt-in --time-ref; network call)"
        time_ref_probe
    fi

    # -- C. Storage & filesystem (infra focus) --------------------------------
    section "C. Storage & filesystem"
    if [ -n "$YARDBASE" ]; then
        fact "yardbase path: $YARDBASE ($( [ -d "$YARDBASE" ] && echo present || echo 'path not found' ))"
    else
        fact "yardbase path: n/a (not resolved from yard.conf or WHATAP_HOME/yardbase)"
    fi
    local ypath fstype src
    ypath="$YARDBASE"; [ -z "$ypath" ] && ypath="$WHOME"; [ -z "$ypath" ] && ypath="."
    fstype="$(fstype_of "$ypath")"; [ -z "$fstype" ] && fstype="n/a (not resolved)"
    src="$(source_of "$ypath")"; [ -z "$src" ] && src="n/a"
    fact "yardbase filesystem type: $fstype"
    fact "yardbase mount source: $src"
    if have findmnt; then probe "mount (findmnt)" findmnt -no FSTYPE,SOURCE,TARGET,OPTIONS -T "$ypath"; fi
    probe "capacity (df -h)" df -h "$ypath"
    subsection "ZFS (only if this host runs ZFS)"
    if have zfs || have zpool; then
        probe "zfs version" zfs version
        probe "zpool list" zpool list -o name,size,alloc,free,cap,frag,health,ashift
        probe "zpool status" zpool status
        if [ "$fstype" = "zfs" ] && [ -n "$src" ] && [ "$src" != "n/a" ]; then
            probe "zfs get (yardbase dataset)" zfs get -H used,available,recordsize,compression,compressratio,atime,logbias,sync,primarycache,secondarycache,dedup,quota,refquota "$src"
        else
            fact "zfs get (yardbase dataset): n/a (not applicable: yardbase fstype is $fstype)"
        fi
        read_proc "ARC stats" /proc/spl/kstat/zfs/arcstats
    else
        fact "n/a (not applicable: zfs/zpool commands absent — this host does not run ZFS)"
    fi
    subsection "data directory markers"
    if [ -n "$YARDBASE" ] && [ -d "$YARDBASE" ]; then
        fact "YARDB_LOCK: $( [ -e "$YARDBASE/YARDB_LOCK" ] && echo "present ($(date -u -r "$YARDBASE/YARDB_LOCK" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo mtime-unknown))" || echo absent )"
        # shallow listing only — never a deep find/du in Tier 0
        probe "pcode dirs (depth 1)" ls -1 "$YARDBASE"
    else
        fact "YARDB_LOCK / pcode dirs: n/a (yardbase not present)"
    fi
    if [ -n "$WHOME" ]; then
        for sub in keeperbase logsink db; do
            fact "$sub dir: $( [ -d "$WHOME/$sub" ] && echo present || echo absent )"
        done
    fi

    # -- D. Deployment layout (on-disk) ---------------------------------------
    section "D. Deployment layout (on-disk)"
    fact "WHATAP_HOME: ${WHOME:-n/a}"
    fact "WHATAP_HOME resolved by: $WHOME_SRC"
    if [ -n "$WHOME" ] && [ -d "$WHOME" ]; then
        probe "top-level (depth 1)" ls -1 "$WHOME"
        if [ -d "$WHOME/lib" ]; then probe "lib jars" ls -1 "$WHOME/lib"; else fact "lib jars: n/a (path not found: $WHOME/lib)"; fi
        if [ -d "$WHOME/conf" ]; then probe "conf files" ls -1 "$WHOME/conf"; else fact "conf files: n/a (path not found: $WHOME/conf)"; fi
    else
        fact "layout: n/a (WHATAP_HOME not resolved)"
    fi

    # -- E. Runtime processes (current state) ---------------------------------
    section "E. Runtime processes (current state)"
    if [ "${#PIDS[@]}" -eq 0 ]; then
        fact "no whatap.server.* / whatap.opslake.* JVM found in /proc (none running, or /proc unreadable)"
    fi
    local i pid mod cl jar xmx xx rss st
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"; cl="$(cmdline_of "$pid")"
        subsection "$mod (pid $pid)"
        jar="$(printf '%s\n' "$cl" | grep -oE 'whatap\.(server|opslake)\.[A-Za-z0-9._-]+\.jar' | head -n1)"; [ -z "$jar" ] && jar="n/a"
        xmx="$(printf '%s\n' "$cl" | grep -oE '[-]Xm[sx][0-9]+[kKmMgG]?' | tr '\n' ' ')"; [ -z "$xmx" ] && xmx="n/a"
        xx="$(printf '%s\n' "$cl" | grep -oE '[-]XX:[^ ]+' | tr '\n' ' ')"; [ -z "$xx" ] && xx="n/a"
        rss="$(awk '/^VmRSS/{print $2" "$3}' "/proc/$pid/status" 2>/dev/null)"; [ -z "$rss" ] && rss="n/a"
        st="$(ps -o lstart= -p "$pid" 2>/dev/null)"; [ -z "$st" ] && st="n/a"
        fact "jar(version): $jar"
        fact "heap flags: $xmx"
        fact "-XX flags: $xx"
        fact "RSS: $rss"
        fact "started: $st"
        i=$((i + 1))
    done
    subsection "PID run-files"
    if [ -n "$WHOME" ]; then probe "*.run" ls -1 "$WHOME"/*.run; else fact "*.run: n/a (WHATAP_HOME not resolved)"; fi
    subsection "listening ports"
    local lports p name port
    lports=" $(get_listen_ports | tr '\n' ' ') "
    for p in "yard-data 6610" "yard-data-alt 6600" "yard-web 7710" "yard-sync 6620" "yard-rpc 7770" \
             "proxy-web 7700" "eureka 6761" "keeper 6789" "gateway-http 8800" "gateway-grpc 8870" \
             "notihub 6500" "front 8080" "account 18080"; do
        name="${p% *}"; port="${p#* }"
        case "$lports" in *" $port "*) fact "$name ($port): LISTEN" ;; *) fact "$name ($port): not listening" ;; esac
    done
    if have ss; then probe "ss -ltnp (whatap procs)" sh -c 'ss -ltnp 2>/dev/null | grep -E "whatap|java" || true'
    elif have netstat; then probe "netstat -ltnp (whatap procs)" sh -c 'netstat -ltnp 2>/dev/null | grep -E "whatap|java" || true'
    else fact "socket->pid map: n/a (command not found: ss/netstat)"; fi
    subsection "systemd unit state (installed units only)"
    if have systemctl; then
        local any=0
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            any=1
            fact "$unit.service: active=$(systemctl is-active "$unit.service" 2>/dev/null) enabled=$(systemctl is-enabled "$unit.service" 2>/dev/null) restarts=$(sd_show NRestarts "$unit")"
        done
        [ "$any" = 0 ] && fact "no whatap *.service units are installed (LoadState != loaded)"
    else
        fact "systemd: n/a (command not found: systemctl — non-systemd host or container)"
    fi

    # -- F. Configuration (raw) -----------------------------------------------
    section "F. Configuration"
    if [ -n "$WHOME" ] && [ -d "$WHOME/conf" ]; then
        local cf
        for cf in "$WHOME"/conf/*.conf; do
            [ -e "$cf" ] || { fact "no *.conf files under $WHOME/conf"; break; }
            fact "$(basename "$cf") ($(wc -c < "$cf" 2>/dev/null | tr -d ' ') bytes, mtime $(date -u -r "$cf" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)):"
            dump_file "$cf"
        done
    else
        fact "conf/: n/a (path not found or WHATAP_HOME not resolved)"
    fi

    # -- G. Logs & recent events ----------------------------------------------
    section "G. Logs & recent events"
    if [ -n "$WHOME" ] && [ -d "$WHOME/logs" ]; then
        # A production yard accumulates hundreds of rotated logs (logback
        # "<base>.<yyyyMMdd>.<i>.log"). Listing each drowns the report and reading
        # the tail of every one is real disk load — so current logs are listed
        # individually while rotated ones are summarized per base (metadata only).
        subsection "current logs (non-rotated) — name / size / mtime"
        local _f _cur=0
        for _f in $(ls -1 "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log 2>/dev/null); do
            [ -f "$_f" ] || continue
            case "$_f" in *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;; esac
            _cur=1
            fact "$(printf '%s\t%s bytes\t%s' "${_f#"$WHOME"/}" "$(wc -c < "$_f" 2>/dev/null | tr -d ' ')" "$(date -u -r "$_f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)")"
        done
        [ "$_cur" = 0 ] && fact "no non-rotated *.log found under $WHOME/logs"

        subsection "rotated logs (summary per base: count / total bytes / date span)"
        # ls -l is metadata only (no content read) — safe with hundreds of files.
        local _rot
        _rot="$(ls -l "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log 2>/dev/null | awk '
            { p=$NF }
            p ~ /\.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9]+\.log$/ {
                m=split(p,a,"/"); fn=a[m]
                sub(/\.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9]+\.log$/, "", fn)
                match(p, /\.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\./); d=substr(p,RSTART+1,8)
                c[fn]++; s[fn]+=$5
                if (mn[fn]==""||d<mn[fn]) mn[fn]=d
                if (d>mx[fn]) mx[fn]=d
            }
            END { for (b in c) printf "%s: %d files, %d bytes total, %s..%s\n", b, c[b], s[b], mn[b], mx[b] }
        ' | sort)"
        if [ -n "$_rot" ]; then printf '%s\n' "$_rot" | while IFS= read -r _l; do fact "$_l"; done
        else fact "no rotated logs"; fi

        subsection "recent ERROR/WARN/Exception counts (current logs only, last 2MB each)"
        for _f in $(ls -1 "$WHOME"/logs/*.log "$WHOME"/logs/*/*.log 2>/dev/null); do
            [ -f "$_f" ] || continue
            case "$_f" in *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;; esac
            local c; c="$(tail -c 2097152 "$_f" 2>/dev/null | grep -cE 'ERROR|WARN|Exception' 2>/dev/null)"
            fact "${_f#"$WHOME"/}: ${c:-0}"
        done
        subsection "per-service log tails (base logs, newest-first, 40 lines each)"
        # A collection server co-locates many service logs (yard/proxy/gateway/
        # keeper/account/notihub/eureka/front) — tail each base *.log, not just
        # one. Sorted by mtime (ls -t) so the actively-written logs come first;
        # excludes rotated .log.<date> and the _self/_api/access/checker/gc
        # streams. Bounded: 40 lines each, at most 12 logs (rest are in inventory).
        local TAIL_LINES=40 LOG_TAIL_FILES=12 _lc=0 _lf
        for _lf in $(ls -1t "$WHOME"/logs/*.log 2>/dev/null); do
            [ -f "$_lf" ] || continue
            # skip secondary streams and rotated (logback ".<yyyyMMdd>.<i>.log") files
            case "$_lf" in
                *_self.log|*_api.log|*access*|*checker*|*/gc*.log) continue ;;
                *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log) continue ;;
            esac
            _lc=$((_lc + 1))
            if [ "$_lc" -gt "$LOG_TAIL_FILES" ]; then
                fact "(+ more base logs not tailed — see inventory above; use --bundle for full logs)"
                break
            fi
            fact "${_lf#"$WHOME"/} (mtime $(date -u -r "$_lf" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo n/a)):"
            tail -n "$TAIL_LINES" "$_lf" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
        done
        [ "$_lc" -eq 0 ] && fact "no base service logs found (only _self/_api/access streams, or none)"
        subsection "self-mon / checker"
        fact "yard_self.log: $( ls "$WHOME"/logs/*_self.log >/dev/null 2>&1 && echo present || echo 'n/a (path not found)' )"
        local chk; chk="$(find "$WHOME/logs" -maxdepth 2 -name '*checker*.log' 2>/dev/null | head -n1)"
        if [ -n "$chk" ]; then fact "$chk (last 20 lines):"; tail -n 20 "$chk" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else fact "checker log: n/a (path not found)"; fi
    else
        fact "logs/: n/a (path not found or WHATAP_HOME not resolved)"
    fi
    subsection "heap dumps / GC log / restart"
    if [ -n "$WHOME" ]; then
        probe "*.hprof" sh -c "ls -la $WHOME/*.hprof $WHOME/logs/*.hprof 2>/dev/null || true"
        fact "gc log: $( ls "$WHOME"/logs/gc*.log >/dev/null 2>&1 && echo present || echo 'n/a (not enabled by default)' )"
        if [ -f "$WHOME/restart.out" ]; then fact "restart.out (last 20 lines):"; tail -n 20 "$WHOME/restart.out" 2>/dev/null | while IFS= read -r _l; do printf '        %s\n' "$_l"; done
        else fact "restart.out: n/a (path not found)"; fi
    fi
    subsection "journal errors (last ${OPT_HOURS}h, bounded, installed units only)"
    if have journalctl; then
        for unit in $WHATAP_UNITS; do
            unit_loaded "$unit" || continue
            local jout
            jout="$(journalctl -u "$unit.service" -p err --since "${OPT_HOURS} hours ago" -n 20 --no-pager 2>/dev/null)"
            [ -n "$jout" ] && { fact "$unit.service (last 20 err):"; printf '%s\n' "$jout" | while IFS= read -r _l; do printf '        %s\n' "$_l"; done; }
        done
    else
        fact "journal: n/a (command not found: journalctl)"
    fi

    emit_footer
}

# =============================================================================
# Bundle (Tier 1 default; Tier 2 opt-in)
# =============================================================================
collect_conf() {
    local dest="$1"
    [ -n "$WHOME" ] && [ -d "$WHOME/conf" ] || { warn "conf: skipped (no WHATAP_HOME/conf)"; return; }
    mkdir -p "$dest" 2>/dev/null
    cp -a "$WHOME/conf/." "$dest/" 2>/dev/null
    progress "conf: copied $WHOME/conf"
}

collect_logs() {
    local dest="$1"
    [ -n "$WHOME" ] && [ -d "$WHOME/logs" ] || { warn "logs: skipped (no WHATAP_HOME/logs)"; return; }
    local cap=$((OPT_MAXLOG_MB * 1024 * 1024)) days="$OPT_LOG_DAYS"
    find "$WHOME/logs" -maxdepth 2 -type f \( -name '*.log' -o -name '*.log.*' \) 2>/dev/null | while IFS= read -r f; do
        # rotated logs (date-stamped or .log.N/.gz): only copy those from the last
        # $days days, so a year of history does not balloon the bundle. Current
        # (non-rotated) logs are always copied.
        case "$f" in
            *.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].*.log|*.log.[0-9]*|*.log.gz)
                [ -n "$(find "$f" -mtime "-$days" 2>/dev/null)" ] || continue ;;
        esac
        local rel sub sz
        rel="${f#"$WHOME"/logs/}"; sub="$(dirname "$rel")"
        mkdir -p "$dest/$sub" 2>/dev/null
        sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"; [ -z "$sz" ] && sz=0
        if [ "$sz" -le "$cap" ]; then cp -a "$f" "$dest/$rel" 2>/dev/null
        else tail -c "$cap" "$f" > "$dest/$rel" 2>/dev/null; printf 'truncated to last %sMB of %s bytes\n' "$OPT_MAXLOG_MB" "$sz" > "$dest/$rel.trunc"; fi
    done
    progress "logs: copied (current + rotated within ${days}d, cap ${OPT_MAXLOG_MB}MB/file)"
}

collect_fs() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have findmnt && findmnt > "$dest/findmnt.txt" 2>/dev/null
    have df && df -T > "$dest/df-T.txt" 2>/dev/null
    cat /proc/self/mountinfo > "$dest/mountinfo.txt" 2>/dev/null
    if have zpool; then
        zpool status -v > "$dest/zpool-status.txt" 2>/dev/null
        zpool list > "$dest/zpool-list.txt" 2>/dev/null
        zpool history > "$dest/zpool-history.txt" 2>/dev/null
    fi
    if have zfs; then
        zfs list -o space > "$dest/zfs-list.txt" 2>/dev/null
        [ -n "$YARDBASE" ] && zfs get all "$(source_of "$YARDBASE")" > "$dest/zfs-get.txt" 2>/dev/null
    fi
    cat /proc/spl/kstat/zfs/arcstats > "$dest/arcstats.txt" 2>/dev/null
    progress "fs: snapshot written"
}

collect_os() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have ps && ps aux > "$dest/ps-aux.txt" 2>/dev/null
    have ss && ss -s > "$dest/ss-summary.txt" 2>/dev/null
    have ss && ss -ltnp > "$dest/ss-listen.txt" 2>/dev/null
    have df && df -h > "$dest/df-h.txt" 2>/dev/null
    have free && free -m > "$dest/free.txt" 2>/dev/null
    cat /proc/loadavg > "$dest/loadavg.txt" 2>/dev/null
    dmesg 2>/dev/null | tail -n 200 > "$dest/dmesg-tail.txt" 2>/dev/null
    have top && top -bn1 2>/dev/null | head -n 40 > "$dest/top.txt" 2>/dev/null
    local i pid
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"
        { cat "/proc/$pid/status"; echo '--- limits ---'; cat "/proc/$pid/limits"; } > "$dest/proc-$pid.txt" 2>/dev/null
        i=$((i + 1))
    done
    progress "os: snapshot written"
}

collect_time() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have timedatectl && timedatectl > "$dest/timedatectl.txt" 2>&1
    have timedatectl && timedatectl timesync-status > "$dest/timesync-status.txt" 2>&1
    if have chronyc; then
        chronyc tracking    > "$dest/chrony-tracking.txt"   2>&1
        chronyc -n sources  > "$dest/chrony-sources.txt"    2>&1
        chronyc sourcestats > "$dest/chrony-sourcestats.txt" 2>&1
    fi
    have ntpq && ntpq -pn > "$dest/ntpq.txt" 2>&1
    cat /sys/devices/system/clocksource/clocksource0/current_clocksource > "$dest/clocksource.txt" 2>/dev/null
    readlink -f /etc/localtime > "$dest/localtime.txt" 2>/dev/null
    progress "time: snapshot written"
}

collect_journal() {
    local dest="$1"; have journalctl || { warn "journal: skipped (journalctl absent)"; return; }
    mkdir -p "$dest" 2>/dev/null
    local unit
    for unit in $WHATAP_UNITS; do
        unit_loaded "$unit" || continue
        journalctl -u "$unit.service" --since "${OPT_HOURS} hours ago" --no-pager > "$dest/$unit.journal.txt" 2>/dev/null
    done
    progress "journal: last ${OPT_HOURS}h written"
}

# ---- Tier 2 (opt-in) --------------------------------------------------------
collect_threads() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    local n="$OPT_THREADS"; [ "$n" -lt 1 ] 2>/dev/null && n=1
    local i pid mod k
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"
        warn "[Tier2] thread dump: pid $pid ($mod) x$n — may cause a JVM safepoint pause"
        k=1
        while [ "$k" -le "$n" ]; do
            if have jstack; then jstack -l "$pid" > "$dest/$mod-$pid.jstack.$k.txt" 2>&1
            else kill -3 "$pid" 2>/dev/null; printf 'jstack absent; sent SIGQUIT to %s (output goes to the JVM stdout/journal)\n' "$pid" > "$dest/$mod-$pid.sigquit.$k.txt"; fi
            k=$((k + 1))
        done
        i=$((i + 1))
    done
}

collect_histo() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have jmap || { warn "[Tier2] histo: jmap absent"; return; }
    local i pid mod
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"
        warn "[Tier2] jmap -histo: pid $pid ($mod) — walks the live heap (no full GC)"
        jmap -histo "$pid" 2>&1 | head -n 200 > "$dest/$mod-$pid.histo.txt" 2>/dev/null
        i=$((i + 1))
    done
}

collect_heap() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    have jmap || { warn "[Tier2] heap: jmap absent"; return; }
    local i pid mod
    i=0
    while [ "$i" -lt "${#PIDS[@]}" ]; do
        pid="${PIDS[$i]}"; mod="${MODS[$i]}"
        warn "[Tier2] FULL HEAP DUMP: pid $pid ($mod) — large file and a JVM pause"
        jmap -dump:format=b,file="$dest/$mod-$pid.hprof" "$pid" > "$dest/$mod-$pid.heap.log" 2>&1
        i=$((i + 1))
    done
}

collect_du() {
    local dest="$1"; mkdir -p "$dest" 2>/dev/null
    [ -n "$YARDBASE" ] && [ -d "$YARDBASE" ] || { warn "[Tier2] du: yardbase absent"; return; }
    warn "[Tier2] recursive du of $YARDBASE — reads data-disk metadata"
    if have timeout; then timeout 120 du --max-depth=1 -h "$YARDBASE" > "$dest/yardbase-du.txt" 2>&1
    else du --max-depth=1 -h "$YARDBASE" > "$dest/yardbase-du.txt" 2>&1; fi
}

do_bundle() {
    local work tarball
    work="$(mktemp -d 2>/dev/null || echo "$OPT_OUT/$BASENAME.tmp.$$")"
    mkdir -p "$work" 2>/dev/null
    run_report > "$work/report.txt" 2>/dev/null
    progress "report: written to bundle"
    collect_conf    "$work/conf"
    collect_logs    "$work/logs"
    collect_fs      "$work/fs"
    collect_time    "$work/time"
    collect_os      "$work/os"
    collect_journal "$work/journal"
    [ "$OPT_THREADS" -ge 1 ] 2>/dev/null && collect_threads "$work/jvm"
    [ "$OPT_HISTO" = 1 ] && collect_histo "$work/jvm"
    [ "$OPT_HEAP" = 1 ] && collect_heap "$work/jvm"
    [ "$OPT_DU" = 1 ] && collect_du "$work/fs"

    tarball="$OPT_OUT/$BASENAME.tar.gz"
    if have tar; then
        # Use -C instead of `cd "$work"`: with a relative --out (the default "."),
        # a `cd` into $work would make $tarball land INSIDE $work and then be
        # deleted with it. -C changes only where tar reads inputs; $tarball stays
        # relative to the caller's CWD. Only remove $work if tar actually wrote it.
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

# An action flag is required. Modifiers alone (--home/--out/--hours/--quiet/...) are
# not enough — say so and show help rather than silently doing nothing.
if [ "$OPT_BUNDLE" = 0 ] && [ "$OPT_STDOUT" = 0 ] && [ "$OPT_FILE" = 0 ]; then
    warn "no action flag given — need one of --file / --stdout / --bundle"
    usage >&2
    exit 2
fi

_init_errfile
have timeout && _timeout_bin="$(command -v timeout)"
mkdir -p "$OPT_OUT" 2>/dev/null

progress "discovering WhaTap services / resolving WHATAP_HOME ..."
discover_services
resolve_home
resolve_yardbase
TARGET="collection-server/$(hostname 2>/dev/null || echo unknown)@${WHOME:-unresolved}"
progress "WHATAP_HOME: ${WHOME:-n/a} (via $WHOME_SRC); whatap JVMs found: ${#PIDS[@]}"

TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASENAME="whatap-collserver-${HOST}-${TS}"

if [ "$OPT_BUNDLE" = 1 ]; then
    progress "mode: bundle (Tier 0 report + Tier 1 artifacts) -> $OPT_OUT/$BASENAME.tar.gz"
    do_bundle
    progress "done."
elif [ "$OPT_STDOUT" = 1 ]; then
    progress "mode: stdout (Tier 0 report, read-only)"
    run_report
    progress "done."
else
    OUTFILE="$OPT_OUT/$BASENAME.txt"
    progress "mode: file (Tier 0 report, read-only) -> writing $OUTFILE"
    run_report > "$OUTFILE" 2>/dev/null
    progress "report written: $OUTFILE"
fi

[ -n "$_errfile" ] && rm -f "$_errfile" 2>/dev/null
exit 0
