# templates/groups/apm.sh — owner of the apm group blocks
# shellcheck shell=bash disable=SC2154,SC2034  # a fragment: the members set these names
# -----------------------------------------------------------------------------
# NOT A SCRIPT. Nothing sources this file: every collector stays one file that
# runs by itself (`sh -s` in a container included, CONTRACT rule 3). The blocks
# below are copied verbatim into their members by
#   tools/sync-shared-block.sh --apply     (--check reports drift)
# the same way the skeleton's blocks reach every collector.
#
# A group block runs from `# ---- <group>: <name> — DO NOT EDIT` to
# `# ---- end <group>: <name>`. Its second line, `# members: ...`, names the
# collectors that carry it by the stem of their file name (collect-<stem>.sh);
# it is the only membership list. A collector not named there must not carry
# the block (the sync tool reports it as STRAY and leaves it alone).
#
# To change a helper here: edit this file, run --apply, bump each member's
# VERSION, and compare the members' reports before and after. To add a helper:
# it goes in only when it behaves the same in every member; one that differs
# stays in its collector.
#
# What the blocks rely on the members to define (before any call, at run time):
#   from the skeleton blocks: fact, _tmp, _bounded, _cmd_kind, _past_deadline,
#     _nl, CMD_TIMEOUT, RUN_DEADLINE
#   probe helpers:   _errfile (set by the member's _init_probe)
#   path helpers:    D_HOMES, D_UNREAD (the discovery records)
#   environ readers: D_UNREAD, and the _ev_<NAME> variables it sets
#   numbers:         _pl, _plab, _pbad (the caller's port accumulators)
# Shell: bash 3.2+ and POSIX sh/dash (no [[, arrays, ${v//}, process
# substitution).
# -----------------------------------------------------------------------------

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

# ---- apm: file helpers — DO NOT EDIT ----------------------------------------
# members: apmnodejs apmphp apmpython
# _head_of N CMD... -> the first N lines of CMD's stdout, with CMD's own exit
# status (a `CMD | head` pipeline reports head's, and hides a failed CMD as
# empty output).
_head_of() {
    local n="$1" rc; shift
    "$@" > "$(_tmp head.out)"; rc=$?
    head -n "$n" "$(_tmp head.out)" 2>/dev/null
    return "$rc"
}

# _ls_head DIR N -> `ls -la DIR`, first N lines, failing when ls fails. Takes the
# path as an argument, so a quote or a space in it cannot break a `sh -c` string.
_ls_head() { _head_of "$2" ls -la -- "$1"; }

# _file_lines head|tail "label" PATH CAP -> the first or last CAP lines of the
# file, verbatim, or a reason. Configuration is dumped as is, never masked (the
# collector README, "What the report can contain").
_file_lines() {
    local how="$1" label="$2" path="$3" cap="$4" w=first total
    [ "$how" = tail ] && w=last
    [ -e "$path" ] || { fact "$label: n/a (path not found: $path)"; return; }
    [ -r "$path" ] || { fact "$label: n/a (permission denied: $path)"; return; }
    [ -s "$path" ] || { fact "$label: (empty file)"; return; }
    total="$(wc -l < "$path" 2>/dev/null | tr -d ' ')"
    fact "$label ($w $cap of ${total:-?} lines):"
    "$how" -n "$cap" "$path" 2>/dev/null | while IFS= read -r _l || [ -n "$_l" ]; do printf '        %s\n' "$_l"; done
}
# ---- end apm: file helpers

# ---- apm: process table — DO NOT EDIT ---------------------------------------
# members: apmnodejs apmphp apmpython
# _proc_table -> one line per process that has a command line, fields joined by
# the unit separator \037 (a whitespace IFS would merge empty fields):
#   pid comm exe argv0 cmdline
# Read in one pass over /proc: three readers for every pid instead of several
# forks per pid (readlink + basename per pid took 20 s on a 687-process host).
# exe is empty where /proc/<pid>/exe is not readable by this uid. cmdline has
# its NULs turned into spaces and is cut at 300 characters.
_us="$(printf '\037')"
_proc_table() {
    {
        ls -l /proc/[0-9]*/exe 2>/dev/null | awk '{
            i = index($0, " -> "); if (!i) next
            for (f = 1; f <= NF; f++) if ($f ~ /^\/proc\/[0-9]+\/exe$/) {
                split($f, a, "/"); t = substr($0, i + 4); sub(/ \(deleted\)$/, "", t)
                print "E\037" a[3] "\037" t; break } }'
        head -n 1 /proc/[0-9]*/comm /dev/null 2>/dev/null | awk '
            /^==> \/proc\/[0-9]+\/comm <==$/ { split($2, a, "/"); p = a[3]; next }
            p != "" { print "C\037" p "\037" $0; p = "" }'
        head -n 1 /proc/[0-9]*/cmdline /dev/null 2>/dev/null | tr '\000\037' '\001 ' | awk '
            /^==> \/proc\/[0-9]+\/cmdline <==$/ { split($2, a, "/"); p = a[3]; next }
            p != "" { split($0, v, "\001"); c = $0; gsub(/\001/, " ", c); sub(/ +$/, "", c)
                      if (v[1] != "") print "A\037" p "\037" v[1] "\037" substr(c, 1, 300)
                      p = "" }'
    } | awk -F'\037' '
        $1 == "E" { e[$2] = $3; next }
        $1 == "C" { c[$2] = $3; next }
        $1 == "A" { o[++n] = $2; a0[$2] = $3; cl[$2] = $4 }
        END { for (i = 1; i <= n; i++) { p = o[i]; print p "\037" c[p] "\037" e[p] "\037" a0[p] "\037" cl[p] } }'
}
# ---- end apm: process table

# ---- apm: path helpers — DO NOT EDIT ----------------------------------------
# members: apmnodejs apmphp apmpython
# _absent_why PATH [SOURCE] -> why resolve_fs found nothing: "permission denied:
# <dir>" when an existing ancestor cannot be searched by this uid, or when the
# process named in SOURCE ("... pid N") has a root this uid cannot enter;
# otherwise "path not found: PATH".
_absent_why() {
    local p="$1" s="${2:-}" d pid i=0
    # a relative path has no ancestor to walk; the ${d%/*} walk below only
    # shrinks an absolute one (and is capped anyway)
    case "$p" in /*) ;; *) printf 'relative path, not resolved: %s' "$p"; return ;; esac
    d="${p%/*}"
    while [ -n "$d" ] && [ ! -e "$d" ] && [ "$i" -lt 256 ]; do d="${d%/*}"; i=$((i + 1)); done
    if [ -n "$d" ] && [ ! -e "$d" ]; then printf 'not resolved (path depth over 256): %s' "$p"; return; fi
    if [ -n "$d" ] && [ -e "$d" ] && [ ! -x "$d" ]; then printf 'permission denied: %s' "$d"; return; fi
    case "$s" in
        *" pid "*)
            pid="${s##* pid }"; pid="${pid%% *}"
            if [ -d "/proc/$pid" ] && [ ! -e "/proc/$pid/root/" ]; then
                printf 'permission denied: /proc/%s/root' "$pid"; return
            fi ;;
    esac
    printf 'path not found: %s' "$p"
}

# _abs_for_pid PID PATH -> PATH, made absolute against the cwd of PID when it
# is relative (a relative WHATAP_HOME in a process environ is relative to that
# process). Fails when PATH is relative and that cwd cannot be read: the path
# is then never tested against the collector's own cwd.
_abs_for_pid() {
    local c
    case "$2" in
        /*) printf '%s' "$2" ;;
        *)  c="$(readlink -f "/proc/$1/cwd" 2>/dev/null)"
            [ -n "$c" ] || return 1
            printf '%s/%s' "$c" "${2#./}" ;;
    esac
}

# _home_from_pid PID PATH SOURCE -> add PATH (from the environ of PID) as a home
# candidate. A relative PATH whose process cwd cannot be read is an unread
# input while the process lives (D_UNREAD), and a fact once it has exited
# (D_GONE).
D_GONE=""
_home_from_pid() {
    local v
    if v="$(_abs_for_pid "$1" "$2")"; then _add_home "$v" "$3"
    elif [ -e "/proc/$1" ]; then D_UNREAD="$D_UNREAD $1"
    else D_GONE="${D_GONE}pid $1: $2$_nl"; fi
}

# _home_from_self VALUE NAME -> add a home candidate from the collector's own
# environment. It belongs to this process, so a relative VALUE is taken
# against the collector's physical cwd (the operator set it and ran the
# collector from there); values from other processes use their cwd instead.
_home_from_self() {
    local c
    case "$1" in
        /*) _add_home "$1" "env $2 (collector shell)" ;;
        *)  c="$(pwd -P 2>/dev/null)"
            if [ -n "$c" ]; then _add_home "$c/${1#./}" "collector environment $2, relative to the collector's cwd $(_quote_nl "$c")"
            else _add_home "$1" "env $2 (collector shell)"; fi ;;
    esac
}

# _quote_nl TEXT -> TEXT with each newline written as \n
_quote_nl() { printf '%s' "$1" | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

# D_ODD: candidate paths holding a newline or '|', the record delimiters. They
# are reported and counted as unread, never split into two records.
D_ODD="" D_ODD_HOME=""

# Membership tests bound by the record delimiter, so /opt/whatap is not taken
# for already listed when /data/opt/whatap is.
_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$p" in *"$_nl"*|*"|"*) D_ODD="$D_ODD \"$(_quote_nl "$p")\"" D_ODD_HOME=1; return ;; esac
    case "$_nl$D_HOMES" in *"$_nl$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES$_nl$p|$s"; else D_HOMES="$p|$s"; fi
}
# ---- end apm: path helpers

# ---- apm: environ readers — DO NOT EDIT -------------------------------------
# members: apmnodejs apmpython
# _read_proc_env PID -> sets _env to the process environ, one variable per line;
# returns 1 (and adds PID to D_UNREAD) when this uid cannot read it
_read_proc_env() {
    _env=""
    if [ ! -r "/proc/$1/environ" ]; then
        [ -e "/proc/$1/environ" ] && D_UNREAD="$D_UNREAD $1"
        return 1
    fi
    _env="$( { tr '\0' '\n' < "/proc/$1/environ"; } 2>/dev/null )"
    return 0
}

# _env_pick NAME... -> sets _ev_NAME to the value of NAME= in _env (empty if
# none; the last line wins when a name repeats), for each NAME, in one pass
# with shell builtins only: a $(...) per variable costs a fork per variable per
# process. The lines are split by IFS, not by a `read` loop over a here-doc,
# which costs a builtin call per line; ${v#*X} cuts are no cheaper, as they
# rescan the string for each position.
_env_pick() {
    local l n _o _p=""
    # a name absent from the whole environ is settled by one match on it,
    # without walking the lines
    for n in "$@"; do
        eval "_ev_$n=''"
        case "$_nl$_env" in *"$_nl$n="*) _p="$_p$n$_nl" ;; esac
    done
    [ -n "$_p" ] || return 0
    _o="$IFS"; IFS="$_nl"; set -f
    for l in $_env; do
        for n in $_p; do
            case "$l" in "$n="*) eval "_ev_$n=\${l#*=}" ;; esac
        done
    done
    set +f; IFS="$_o"
}
# ---- end apm: environ readers

# ---- apm: numbers — DO NOT EDIT ---------------------------------------------
# members: apmnodejs apmphp apmpython
# _num_norm V MAXDIGITS -> V without leading zeros when it is 1..MAXDIGITS
# digits (a leading zero would read as octal in $((...))); fails otherwise
_num_norm() {
    local v="$1"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#v}" -le "$2" ] || return 1
    while :; do case "$v" in 0?*) v="${v#0}" ;; *) break ;; esac; done
    printf '%s' "$v"
}

# _port_norm V -> V as a port (1..65535), or fails
_port_norm() {
    local v
    v="$(_num_norm "$1" 5)" || return 1
    [ "$v" -ge 1 ] && [ "$v" -le 65535 ] || return 1
    printf '%s' "$v"
}

# _conf_vals KEY FILE... -> the raw values of KEY= in FILEs, one per line
_conf_vals() {
    local k="$1"; shift
    [ "$#" -gt 0 ] || return 0
    awk -F= -v k="$k" '{ gsub(/[ \t\r]/, "") } $1 == k && $2 != "" { print $2 }' "$@" 2>/dev/null
}

# _ports_add LABEL <<VALUES -> the valid ports among VALUES (one per line) join
# _pl, and "; PORTS (LABEL)" joins _plab; refused values join _pbad
_ports_add() {
    local v n got=""
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        if n="$(_port_norm "$v")"; then
            case " $got " in *" $n "*) ;; *) got="${got:+$got }$n" ;; esac
        else _pbad="${_pbad:+$_pbad; }$(_quote_nl "$v") ($1)"; fi
    done
    [ -n "$got" ] && { _pl="$_pl $got"; _plab="$_plab; $got ($1)"; }
    return 0
}

# _uniq_ports PORT... -> the distinct ports, space-joined (validated numbers only)
_uniq_ports() { [ "$#" -gt 0 ] || return 0; printf '%s\n' "$@" | sort -un | tr '\n' ' ' | sed 's/ $//'; }
# ---- end apm: numbers
