# templates/groups/collection-server.sh — owner of the collection-server group blocks
# shellcheck shell=bash disable=SC2154,SC2034  # a fragment: the members set these names
# -----------------------------------------------------------------------------
# NOT A SCRIPT. Nothing sources this file: every collector stays one file that
# runs by itself (CONTRACT rule 3). The blocks below are copied verbatim into
# their members by
#   tools/sync-shared-block.sh --apply     (--check reports drift)
# the same way the skeleton's blocks reach every collector.
#
# The block format (banner, `# members:`, STRAY, `place: end`) is defined once
# in [tools/sync-shared-block.sh](../../tools/sync-shared-block.sh); this file
# only adds what collection-server's blocks need, below.
#
# To change a helper here: edit this file, run --apply, bump each member's
# VERSION and add its CHANGELOG entry, and compare the members' reports before
# and after. To add a helper: it goes in only when it behaves the same in
# every member; one that differs (_classify_err, resolve_home, ...) stays in its
# collector.
#
# What the blocks rely on the members to define (before any call, at run time):
#   from the skeleton blocks: fact, have, warn, _tmp, _bounded, _bounded_in,
#     _past_deadline, _tab, CMD_TIMEOUT, RUN_DEADLINE
#   probe helpers:    _run_init before _init_probe
#   systemd:          _tmp_dir (the run's private directory, for the hung mark)
#   main helpers:     OPT_OUT
# Placement: the options block comes before the member's option loop (after the
# skeleton's emit helpers, which define _optval); the others anywhere before main.
# Shell: bash 3.2+ (the members need bash); the file also parses under dash.
# -----------------------------------------------------------------------------

# ---- collection-server: options — DO NOT EDIT -------------------------------
# members: collmysql collserver collzfs
# _removed MESSAGE -> an option that no longer exists: exit 2, naming what
# replaced it (fd 3 is not open yet, so stderr)
_removed() { printf '!! %s\n' "$1" >&2; exit 2; }
# ---- end collection-server: options

# ---- collection-server: probe helpers — DO NOT EDIT -------------------------
# members: collmysql collserver collzfs
# _init_probe -> _errfile, the private file (after _run_init) a probe's stderr
# goes to; the member's _classify_err reads it.
_errfile=""
_init_probe() { _errfile="$(_tmp probe.err)"; }

# _why_124 -> why a bounded call returned 124: the run deadline, or its own cap
# (the same two wordings as probe)
_why_124() {
    if _past_deadline; then printf 'run deadline reached: %ss' "$RUN_DEADLINE"
    else printf 'timed out: %ss' "$CMD_TIMEOUT"; fi
}

# ---- end collection-server: probe helpers

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

# fstype_of PATH / source_of PATH -> the filesystem type / the source (device
# or dataset) of the mount PATH is on; empty when neither tool answers
fstype_of() {
    local p="$1"
    if have findmnt; then _bounded findmnt -no FSTYPE -T "$p" 2>/dev/null && return; fi
    if have stat; then _bounded stat -f -c '%T' "$p" 2>/dev/null && return; fi
    echo ""
}

source_of() {
    local p="$1"
    if have findmnt; then _bounded findmnt -no SOURCE -T "$p" 2>/dev/null && return; fi
    echo ""
}

# _dir_ok DIR -> true when this uid can list DIR (read + search)
_dir_ok() { [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ]; }

# _path_state P -> ok (listable), absent (the nearest existing ancestor was
# searched and P is not there), notdir, dangling:TARGET, or unlistable
_path_state() {
    local p="$1" a t
    _dir_ok "$p" && { printf ok; return; }
    if [ -e "$p" ]; then [ -d "$p" ] && printf unlistable || printf notdir; return; fi
    if [ -L "$p" ]; then
        t="$(readlink "$p")"; a="$t"
        case "$a" in /*) ;; *) a="$(dirname "$p")/$a" ;; esac
        a="$(dirname "$a")"
        if [ -d "$a" ] && [ -x "$a" ]; then printf 'dangling:%s' "$t"; else printf unlistable; fi
        return
    fi
    a="$(dirname "$p")"
    while [ ! -e "$a" ] && [ "$a" != / ] && [ "$a" != . ]; do a="$(dirname "$a")"; done
    if [ -x "$a" ]; then printf absent; else printf unlistable; fi
}

# resolve_yardbase -> YARDBASE from WHOME: yard.conf's yardbase, else
# WHOME/yardbase; a relative value is taken relative to WHOME
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
# ---- end collection-server: file helpers

# ---- collection-server: process scan — DO NOT EDIT --------------------------
# members: collserver collzfs
# cmdline_of PID -> sets _CL to the process's argv joined by spaces (the bytes
# `tr '\0' ' '` gives), with builtins only: no fork per process.
_CL=""
cmdline_of() {
    local a=""
    _CL=""
    while IFS= read -r -d '' a; do _CL="$_CL$a "; done 2>/dev/null < "/proc/$1/cmdline"
    _CL="$_CL$a"
}

# _whatap_cmdlines -> /proc/<pid>/cmdline paths that name a whatap module, in
# /proc order. One bounded grep over every entry instead of a read per process,
# fed through xargs so a host with tens of thousands of processes does not hit
# ARG_MAX. Its exit status is kept: grep answers 0 (match) or 1 (none), and 2
# when a process vanished mid-scan, which xargs reports as 123; anything else
# (a cap, a failed exec) means the table was not read, and says so.
CMDLINE_SCAN_WHY=""
_whatap_cmdlines() {
    # The list goes through a file and _bounded_in, not a pipe into _bounded:
    # with the script on stdin (bash -s), _bounded gives its command /dev/null
    # as stdin, and a piped list would arrive empty and read as "no JVM".
    local lst; lst="$(_tmp cmdlines.lst)"
    if have xargs && [ "$lst" != /dev/null ] && printf '%s\0' /proc/[0-9]*/cmdline > "$lst" 2>/dev/null; then
        _bounded_in "$lst" xargs -0 grep -lsE 'whatap\.server\.|whatap\.opslake\.|\.yard\.boot'
    else
        # No xargs or no private directory: the paths as arguments (bounded by ARG_MAX).
        _bounded grep -lsE 'whatap\.server\.|whatap\.opslake\.|\.yard\.boot' /proc/[0-9]*/cmdline
    fi
}
_scan_cmdlines() {
    local rc
    _SCAN_OUT="$(_whatap_cmdlines)"; rc=$?
    case "$rc" in
        0|1|2|123) CMDLINE_SCAN_WHY="" ;;
        124) CMDLINE_SCAN_WHY="the /proc/<pid>/cmdline scan did not finish within ${CMD_TIMEOUT}s" ;;
        *)   CMDLINE_SCAN_WHY="the /proc/<pid>/cmdline scan failed (xargs/grep exit $rc)" ;;
    esac
}

# _is_whatap_server PID CMDLINE -> true for a java process that runs a WhaTap
# backend module: a whatap.server.*.jar / whatap.opslake.*.jar on its command
# line, or the yard boot class. "whatap.server." alone is not enough: the
# WhaTap Java agent passes -Dwhatap.server.host=..., and `tail -f
# whatap.server.log` names it too. Patterns, not [[ =~ ]], so the block parses
# under dash; the jar test is whatap.(server|opslake). followed by a run of
# [A-Za-z0-9._-] that holds ".jar" after its first character.
_is_whatap_server() {
    local hit="" pfx s tok comm="" a0="${2%% *}"
    case "$2" in *[A-Za-z0-9_].yard.boot*) hit=1 ;; esac
    for pfx in whatap.server. whatap.opslake.; do
        s="$2"
        while [ -z "$hit" ]; do
            case "$s" in *"$pfx"*) ;; *) break ;; esac
            s="${s#*"$pfx"}"
            tok="${s%%[!A-Za-z0-9._-]*}"
            case "$tok" in ?*.jar*) hit=1 ;; esac
            # past tok: a later hit inside it is a suffix of tok, no .jar either
            # (only when tok holds one: the strip copies the rest of the string)
            case "$tok" in *"$pfx"*) s="${s#"$tok"}" ;; esac
        done
    done
    [ -n "$hit" ] || return 1
    { IFS= read -r comm < "/proc/$1/comm"; } 2>/dev/null
    [ "$comm" = java ] || [ "${a0##*/}" = java ]
}
# ---- end collection-server: process scan

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

# ---- collection-server: main helpers — DO NOT EDIT --------------------------
# members: collmysql collserver collzfs
# _need_int NAME VALUE -> exit 2 unless VALUE is a non-negative integer
_need_int() {
    case "$2" in
        ''|*[!0-9]*) warn "$1 takes a non-negative integer; got '$2'"; exit 2 ;;
    esac
}

# _out_dir_check -> creates the output directory OPT_OUT when missing and fails,
# saying so on the operator stream, when this uid cannot write into it. Called
# before anything is collected, so an unwritable one fails at once rather than
# after a full run.
_out_dir_check() {
    mkdir -p "$OPT_OUT" 2>/dev/null
    if [ ! -d "$OPT_OUT" ] || [ ! -w "$OPT_OUT" ] || [ ! -x "$OPT_OUT" ]; then
        warn "the report was not written: output directory $OPT_OUT is not writable by uid $(id -u 2>/dev/null || echo '?')"
        return 1
    fi
}
# ---- end collection-server: main helpers

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
