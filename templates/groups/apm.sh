# templates/groups/apm.sh — owner of the apm group blocks
# shellcheck shell=bash disable=SC2154,SC2034  # a fragment: the members set these names
# -----------------------------------------------------------------------------
# NOT A SCRIPT. Nothing sources this file: every collector stays one file that
# runs by itself (`sh -s` in a container included, CONTRACT rule 3). The blocks
# below are copied verbatim into their members by
#   tools/sync-shared-block.sh --apply     (--check reports drift)
# the same way the skeleton's blocks reach every collector.
#
# The block format (banner, `# members:`, STRAY, `place: end`) is defined once
# in [tools/sync-shared-block.sh](../../tools/sync-shared-block.sh); this file
# only adds what apm's blocks need, below.
#
# To change a helper here: edit this file, run --apply, bump each member's
# VERSION and add its CHANGELOG entry, and compare the members' reports before
# and after. To add a helper: it goes in only when it behaves the same in
# every member; one that differs stays in its collector.
#
# What the blocks rely on the members to define (before any call, at run time):
#   from the skeleton blocks: fact, _tmp, _bounded, _cmd_kind, _past_deadline,
#     _nl, CMD_TIMEOUT, RUN_DEADLINE
#   probe helpers:    _errfile (set by the member's _init_probe)
#   report helpers:   read_proc, probe, _note_privilege, _note_boot and its
#                     _priv_uid (skeleton); _proc_words,
#                     _u8cut (text helpers)
#   process table:    _U8CUT_AWK (text helpers)
#   text helpers:     _nl (skeleton)
#   machine arch:     probe's PROBE_OUT / PROBE_RC (skeleton)
#   path helpers:     D_HOMES, D_UNREAD (the discovery records), and for
#                     resolve_fs the member's pid lists D_<KIND>_PIDS
#   environ readers:  D_UNREAD, D_HIDEPID (_scan_gaps), and the _ev_<NAME>
#                     variables it sets; _proc_lines (text helpers)
#   numbers:          _pl, _plab, _pbad (the caller's port accumulators)
#   output directory: OPT_OUT, OPT_STDOUT (the CLI harness), warn, _bounded
#   main:             ARGC, OPT_FILE, OPT_STDOUT, OPT_OUT, COLLECTOR_NAME,
#                     TARGET (host/<name>, the name of the --file report), usage,
#                     _init_probe, run_report (the member's), _run_init,
#                     progress, _report_to_file (skeleton), _out_check (above).
#                     It is each member's last block (`# place: end`): nothing
#                     may follow it.
# Shell: bash 3.2+ and POSIX sh/dash (no [[, arrays, ${v//}, process
# substitution).
# -----------------------------------------------------------------------------

# ---- apm: probe helpers — DO NOT EDIT ---------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _classify_err -> the reason a probe failed, from _errfile. An unknown error is
# its first line; a line over 100 bytes keeps both ends, the first 45 and the
# last 52 bytes: the kind of error is at the start ("PHP Fatal error: ...",
# "Error: Cannot find module"), and after a long path the message is at the
# end ("<long path>: No module named pip").
_classify_err() {
    local txt=""
    [ -f "$_errfile" ] && txt="$(cat "$_errfile" 2>/dev/null)"
    case "$txt" in
        *[Pp]"ermission denied"*|*"peration not permitted"*) echo "permission denied"; return ;;
        *"o such file"*|*"annot access"*|*"oes not exist"*)   echo "path not found";    return ;;
    esac
    if [ -n "$txt" ]; then printf 'error: %s' "$(printf '%s\n' "$txt" | awk 'NR == 1 { if (length($0) > 100) $0 = substr($0, 1, 45) "..." substr($0, length($0) - 51); print; exit }')"
    else echo "nonzero exit"; fi
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

# ---- apm: text helpers — DO NOT EDIT ----------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _U8CUT_AWK: the awk function u8cut(S, N) -> S cut to N bytes, then any UTF-8
# sequence left incomplete at its end dropped (cut -c and substr count bytes
# under LC_ALL=C, and a cut inside a character makes the report invalid
# UTF-8). The byte classes are looked up with index(), so mawk, busybox awk
# and gawk agree. One text for _u8cut and for the awk programs that cut a
# field (the process table), so every cut in every member is the same.
_U8CUT_AWK='function u8cut(s, n,   l, k, b, w, i) {
    if (length(s) <= n) return s
    if (!_u8n) {
        for (i = 128; i < 192; i++) _u8c = _u8c sprintf("%c", i)
        for (i = 192; i < 224; i++) _u8l2 = _u8l2 sprintf("%c", i)
        for (i = 224; i < 240; i++) _u8l3 = _u8l3 sprintf("%c", i)
        for (i = 240; i < 248; i++) _u8l4 = _u8l4 sprintf("%c", i)
        _u8n = 1 }
    s = substr(s, 1, n); l = length(s); k = l
    while (k > 0 && k > l - 3 && index(_u8c, substr(s, k, 1))) k--
    if (k > 0) {
        b = substr(s, k, 1); w = 1
        if (index(_u8l2, b)) w = 2; else if (index(_u8l3, b)) w = 3; else if (index(_u8l4, b)) w = 4
        if (w > 1 && l - k + 1 < w) s = substr(s, 1, k - 1)
    }
    return s }'

# _u8cut N -> each stdin line cut to N bytes on a UTF-8 boundary (u8cut above)
_u8cut() { awk -v n="$1" "$_U8CUT_AWK"' { print u8cut($0, n) }'; }

# /proc/<pid>/cmdline and environ are NUL-separated, and an entry may itself
# hold a newline or a CR. Printed as read, a newline puts the rest of the
# entry at column 0 of the report, where it reads as a section line of its
# own (an argument "x\n[5] Collection status" made one); inside a
# one-entry-per-line list it would read as one more entry. Every cmdline and
# environ the members read goes through one of these two, so an entry is one
# line of text.
# _proc_words FILE -> FILE on one line: each NUL, newline and CR as a space
# _proc_lines FILE -> one entry of FILE per line: each NUL as a newline, a
#   newline or CR inside an entry as a space
# Both print nothing (stderr silenced) when FILE cannot be read.
_proc_words() { { tr '\000\n\r' '   ' < "$1"; } 2>/dev/null; }
_proc_lines() { { tr '\000\n\r' '\n  ' < "$1"; } 2>/dev/null; }

# The same holds for a process's comm and for the targets of its exe, cwd and
# fd links: the process chose them. _oneline TEXT -> TEXT with each newline
# and CR as a space; it forks only when TEXT holds one.
_cr="$(printf '\r')"
_oneline() {
    case "$1" in
        *"$_nl"*|*"$_cr"*) printf '%s' "$1" | tr '\n\r' '  ' ;;
        *) printf '%s' "$1" ;;
    esac
}
# _comm PID -> /proc/PID/comm on one line, its lines joined by a space (empty
# when unreadable); read with the read builtin, no fork
_comm() {
    local l c=""
    { while IFS= read -r l; do c="${c:+$c }$l"; done < "/proc/$1/comm"; } 2>/dev/null
    _oneline "$c"
}
# _is_odd TEXT -> success when TEXT holds a newline or a CR
_is_odd() { case "$1" in *"$_nl"*|*"$_cr"*) return 0 ;; esac; return 1; }
# _link_text [-f] PATH -> readlink [-f] PATH on one line; fails as readlink does
_link_text() { local o; o="$(readlink "$@" 2>/dev/null)" || return 1; _oneline "$o"; }
# ---- end apm: text helpers

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
    total="$( { wc -l < "$path"; } 2>/dev/null | tr -d ' ')"
    fact "$label ($w $cap of ${total:-?} lines):"
    "$how" -n "$cap" "$path" 2>/dev/null | _indent '        '
}

# _sock_list TOOL FLAGS PORTS [NAMES] -> the socket table lines matching the
# ERE NAMES (default whatap) or naming one of PORTS (space-separated), header
# kept, first 50; exits with TOOL's status
_sock_list() {
    local pat rc
    pat=":($(printf '%s' "$3" | tr -s ' ' '|' | sed 's/^|//; s/|$//'))([^0-9]|\$)"
    "$1" "$2" > "$(_tmp sock.out)"; rc=$?
    awk -v p="$pat" -v n="${4:-whatap}" '(NR <= 2 && /State|Proto|Recv-Q/) || $0 ~ n || $0 ~ p' "$(_tmp sock.out)" 2>/dev/null | head -n 50
    return "$rc"
}
# ---- end apm: file helpers

# ---- apm: process table — DO NOT EDIT ---------------------------------------
# members: apmnodejs apmphp apmpython
# _proc_table -> one line per process that has a command line, fields joined by
# the unit separator \037 (a whitespace IFS would merge empty fields):
#   pid comm exe argv0 cmdline
# Read in one pass over /proc: three readers for every pid instead of several
# forks per pid (readlink + basename per pid took 20 s on a 687-process host).
# exe is empty where /proc/<pid>/exe is not readable by this uid. `ls -l`
# prints a link target holding a newline over two lines, and the second can
# pose as the line of another pid: a line naming no /proc/<pid>/exe, or a pid
# named twice, makes the exe of the pids involved (the one named twice, and the
# one whose line came before) be read again with readlink, newlines and CRs as
# spaces; nothing else is re-read, so one process cannot make every pid cost a
# fork (rare: the common case
# stays one ls). A posing line can only name a pid that does not exist (an
# existing one has its own line), which no row joins. comm is at most 15
# bytes, shorter than any header line (17 bytes and more), and always ends in a newline:
# `head -n 16` reads every line of it in the same pass, and they are joined
# with spaces, the separator line head adds before the next header dropped.
# cmdline has
# its NULs, newlines and CRs turned into spaces and is cut at 300 bytes on a
# UTF-8 boundary (u8cut, text helpers).
# `head -n 1` stops at a newline, and after a file whose first line ended in
# one it prints a blank line before the next header (GNU and busybox alike;
# /dev/null gives the last pid a header after it). That blank line marks a
# command line holding a newline: only that pid's file is read again, whole,
# so the common case stays one pass and argv0 and the words after the newline
# are not lost. A process gone by then keeps what head read.
_us="$(printf '\037')"
_proc_table() {
    {
        ls -l /proc/[0-9]*/exe 2>/dev/null | awk '{
            if (index($0, "\r")) gsub(/\r/, " ")
            i = index($0, " -> "); q = ""
            for (f = 1; f <= NF; f++) if ($f ~ /^\/proc\/[0-9]+\/exe$/) { split($f, a, "/"); q = a[3]; break }
            if (q == "" || (q in s)) { if (pq != "") print "R\037" pq; if (q != "") print "R\037" q; next }
            s[q] = 1; pq = q; if (!i) next
            t = substr($0, i + 4); sub(/ \(deleted\)$/, "", t)
            print "E\037" q "\037" t }'
        head -n 16 /proc/[0-9]*/comm /dev/null 2>/dev/null | awk '
            function out() { if (p != "") { if (n > 1 && v == "") v = c; else if (n > 1) v = c " " v
                                 print "C\037" p "\037" v }
                             p = ""; n = 0; c = ""; v = "" }
            /^==> (\/proc\/[0-9]+\/comm|\/dev\/null) <==$/ { out(); if ($2 != "/dev/null") { split($2, a, "/"); p = a[3] }; next }
            p != "" { if (index($0, "\r") || index($0, "\037")) gsub(/[\r\037]/, " ")
                      if (n) c = (n > 1 ? c " " : "") v
                      v = $0; n++ }
            END { out() }'
        head -n 1 /proc/[0-9]*/cmdline /dev/null 2>/dev/null | tr '\000\037\r' '\001  ' | awk "$_U8CUT_AWK"'
            function emit(p, s,   i, c) {
                i = index(s, "\001"); if (i == 1 || s == "") return
                c = s; gsub(/\001/, " ", c); sub(/ +$/, "", c)
                print "A\037" p "\037" (i ? substr(s, 1, i - 1) : s) "\037" u8cut(c, 300) }
            st == 1 { d = $0; st = 2; next }
            st == 2 && $0 == "" {
                r = ""; f = "tr \"\\000\\012\\015\\037\" \"\\001   \" 2>/dev/null < /proc/" p "/cmdline"
                while ((f | getline l) > 0) r = r l
                close(f); emit(p, r != "" ? r : d); st = 0; next }
            st == 2 { emit(p, d); st = 0 }
            /^==> \/proc\/[0-9]+\/cmdline <==$/ { split($2, a, "/"); p = a[3]; st = 1 }
            END { if (st == 2) emit(p, d) }'
    } | awk -F'\037' '
        $1 == "R" { rr[$2] = 1; next }
        $1 == "E" { e[$2] = $3; next }
        $1 == "C" { c[$2] = $3; next }
        $1 == "A" { o[++n] = $2; a0[$2] = $3; cl[$2] = $4 }
        END {
            for (i = 1; i <= n; i++) { p = o[i]
                if (p in rr) { r = ""; k = 0; f = "readlink /proc/" p "/exe 2>/dev/null"
                           while ((f | getline l) > 0) r = r (k++ ? " " : "") l
                           close(f); gsub(/\r/, " ", r); sub(/ \(deleted\)$/, "", r); e[p] = r }
                print p "\037" c[p] "\037" e[p] "\037" a0[p] "\037" cl[p] } }'
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

# _quote_nl TEXT -> TEXT with each newline written as \n and each CR as \r
_quote_nl() { printf '%s' "$1" | awk '{ gsub(/\r/, "\\r") } NR > 1 { printf "\\n" } { printf "%s", $0 }'; }

# D_ODD: candidate paths holding a newline or '|', the record delimiters, or a
# CR (a process's cwd or environ can hold any of them). They are reported,
# quoted, and counted as unread, never split into two records or looked up.
D_ODD="" D_ODD_HOME=""

# Membership tests bound by the record delimiter, so /opt/whatap is not taken
# for already listed when /data/opt/whatap is.
_add_home() {  # _add_home PATH SOURCE
    local p="$1" s="$2"
    [ -n "$p" ] || return
    case "$p" in *"$_nl"*|*"$_cr"*|*"|"*)
        p="\"$(_quote_nl "$p")\""
        case "$D_ODD " in *" $p "*) ;; *) D_ODD="$D_ODD $p" ;; esac
        D_ODD_HOME=1; return ;; esac
    case "$_nl$D_HOMES" in *"$_nl$p|"*) return ;; esac
    if [ -n "$D_HOMES" ]; then D_HOMES="$D_HOMES$_nl$p|$s"; else D_HOMES="$p|$s"; fi
}

# resolve_fs PATH -> prints a readable filesystem view of PATH: the path itself
# if it exists here, otherwise the same path seen through the root of a
# discovered agent or application process (/proc/<pid>/root<PATH>). Empty if
# neither is visible. This lets the collector run from a kubectl-debug
# ephemeral container (or any different mount namespace) and still read the
# target's files. The pid lists are each member's own (nodejs: GO APP, python:
# GO APP ODOO, php: AGENT WEB ALT); the ones a member does not have are empty.
resolve_fs() {
    local p="$1" pid
    # a relative path is never read against the collector's own cwd
    case "$p" in /*) ;; *) return 1 ;; esac
    [ -e "$p" ] && { printf '%s\n' "$p"; return; }
    # shellcheck disable=SC2154  # each member sets only its own lists
    for pid in $D_GO_PIDS $D_APP_PIDS $D_ODOO_PIDS $D_AGENT_PIDS $D_WEB_PIDS $D_ALT_PIDS; do
        [ -e "/proc/$pid/root$p" ] && { printf '%s\n' "/proc/$pid/root$p"; return; }
    done
    return 1
}
# ---- end apm: path helpers

# ---- apm: environ readers — DO NOT EDIT -------------------------------------
# members: apmnodejs apmpython
# _read_proc_env PID -> sets _env to the process environ, one variable per line;
# a newline or CR inside a value is held as \001 or \002, never a variable of
# its own, and _env_pick gives it back, so a WHATAP_HOME holding one reaches
# _add_home as it is (and is listed in D_ODD, not looked up); returns 1 (and
# adds PID to D_UNREAD) when this uid cannot read it
_m1="$(printf '\001')" _m2="$(printf '\002')"
_read_proc_env() {
    _env=""
    if [ ! -r "/proc/$1/environ" ]; then
        [ -e "/proc/$1/environ" ] && D_UNREAD="$D_UNREAD $1"
        return 1
    fi
    _env="$( { tr '\000\n\r' '\n\001\002' < "/proc/$1/environ"; } 2>/dev/null )"
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
    # a value that held a newline or CR gets it back (a fork only then)
    for n in $_p; do
        eval "l=\${_ev_$n}"
        case "$l" in *"$_m1"*|*"$_m2"*)
            l="$(printf '%s' "$l" | tr '\001\002' '\n\r')"; eval "_ev_$n=\$l" ;; esac
    done
}

# _scan_gaps -> the inputs of the agent-home search this run could not read,
# as one phrase; empty when every one was read
_scan_gaps() {
    local n g=""
    if [ -n "$D_UNREAD" ]; then
        n="$(echo $D_UNREAD | wc -w | tr -d ' ')"
        g="environ/cwd of $n candidate process(es) not readable by uid $(id -u 2>/dev/null || echo '?') (pids: $(echo $D_UNREAD | cut -d' ' -f1-10))"
    fi
    [ -n "$D_HIDEPID" ] && g="${g:+$g; }$D_HIDEPID"
    printf '%s' "$g"
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

# ---- apm: report helpers — DO NOT EDIT -------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _env_head -> the opening facts of the environment section: shell, uid,
# privilege, boot time and the collector's cwd
_env_head() {
    section "Collection environment"
    if [ -n "${BASH_VERSION:-}" ]; then fact "shell: bash $BASH_VERSION"
    else fact "shell: POSIX sh (non-bash)"; fi
    fact "uid: $(id -u 2>/dev/null || echo unknown) ($(id -un 2>/dev/null || echo unknown))"
    _note_privilege
    fact "privilege: $PRIV_WHY"
    _note_boot
    fact "collector cwd: $(pwd 2>/dev/null || echo unknown)"
}

# _cgroup_facts -> the cgroup version and the memory and cpu limits as this
# process's cgroup sees them (container-vs-host metric questions need them)
_cgroup_facts() {
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
}

# _container_facts -> the container markers, KUBERNETES_SERVICE_HOST and this
# process's cgroup lines
_container_facts() {
    local m
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
}

# _pid1_cmd -> pid 1's command line on one line (_proc_words), first 160 bytes
# (_u8cut); for probe "pid 1 command"
_pid1_cmd() { _proc_words /proc/1/cmdline | _u8cut 160; }

# _product_uuid -> the `ls -l` line of /sys/class/dmi/id/product_uuid and
# whether this run could read it, by opening and reading it (sysfs mode bits
# alone do not say). The value is printed only when it was read, as read. The
# open and the read are shell redirections and the uid is _note_privilege's,
# so a readable file costs one fork (ls); `cat` runs only to name the error
# of a failed open or read (its stderr, through _classify_err).
_product_uuid() {
    local f=/sys/class/dmi/id/product_uuid v="" l u="${_priv_uid:-?}"
    if [ ! -e "$f" ]; then fact "dmi product_uuid: n/a (path not found: $f)"; return; fi
    l="$(ls -l "$f" 2>/dev/null)"
    fact "dmi product_uuid (ls -l): ${l:-n/a (ls -l printed nothing)}"
    # `true`, not `:`: a redirection that fails on a special builtin ends a
    # POSIX shell (dash exited here)
    if ! { true < "$f"; } 2>/dev/null; then
        cat "$f" >/dev/null 2>"$_errfile"
        fact "dmi product_uuid readable by uid $u: no (open failed: $(_classify_err))"
        return
    fi
    { IFS= read -r v < "$f"; } 2>/dev/null
    if [ -n "$v" ]; then
        fact "dmi product_uuid readable by uid $u: yes"
        fact "dmi product_uuid: $(_oneline "$v")"
    elif cat "$f" >/dev/null 2>"$_errfile"; then
        fact "dmi product_uuid readable by uid $u: yes"
        fact "dmi product_uuid: (empty file)"
    else
        fact "dmi product_uuid readable by uid $u: no (opened, read failed: $(_classify_err))"
    fi
}
# ---- end apm: report helpers

# ---- apm: machine arch — DO NOT EDIT ---------------------------------------
# members: apmnodejs apmphp apmpython
# _kernel_arch -> the kernel line (uname -srm) and the machine arch, its last
# field (uname prints the fields in its own order, and a kernel release has no
# blank). Read from probe's PROBE_OUT: one uname call, no parse of the fact
# line. Without a machine field the reason is the kernel line's.
_kernel_arch() {
    probe "kernel" uname -srm
    case "$PROBE_RC:$PROBE_OUT" in
        0:*" "*) fact "machine arch: ${PROBE_OUT##* }" ;;
        *:*" "*) fact "machine arch (exit $PROBE_RC): ${PROBE_OUT##* }" ;;
        127:)    fact "machine arch: n/a (command not found: uname)" ;;
        124:)    if _past_deadline; then fact "machine arch: n/a (run deadline reached: ${RUN_DEADLINE}s)"
                 else fact "machine arch: n/a (timed out: ${CMD_TIMEOUT}s)"; fi ;;
        0:)      fact "machine arch: n/a (empty output)" ;;
        *:)      fact "machine arch: n/a ($(_classify_err))" ;;
        *)       fact "machine arch: n/a (no machine field in the uname -srm output)" ;;
    esac
}
# ---- end apm: machine arch

# ---- apm: conf bytes — DO NOT EDIT -----------------------------------------
# members: apmnodejs apmphp
# conf_bytes "label" PATH -> byte-level facts a plain `cat` hides: total bytes
# and CR (\r, 0x0D) count. Windows-edited config files reach Linux hosts
# through support cases; the reader compares these numbers against the dumped
# text. Nothing when PATH is absent or unreadable (the dump says why).
conf_bytes() {
    local label="$1" path="$2" sz cr
    [ -e "$path" ] || return
    [ -r "$path" ] || return
    sz="$( { wc -c < "$path"; } 2>/dev/null | tr -d ' ')"
    cr="$( { tr -dc '\r' < "$path"; } 2>/dev/null | wc -c | tr -d ' ')"
    fact "$label: size ${sz:-?} bytes, CR (0x0D) bytes: ${cr:-?}"
}
# ---- end apm: conf bytes

# ---- apm: output directory — DO NOT EDIT ------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# _out_check -> for --file, makes sure the --out directory (OPT_OUT, default:
# the working directory) exists and this uid can write into it, before anything
# is collected: an unwritable directory fails at once, not after a full run.
# With --stdout the report goes to stdout, and an --out given is named as not
# used. Fails (the reason on the operator stream) when the report cannot be
# written; the message is the one collserver gives.
_out_check() {
    local d="${OPT_OUT:-.}"
    if [ "$OPT_STDOUT" = 1 ]; then
        [ -n "$OPT_OUT" ] && warn "--out $OPT_OUT is not used: the report goes to stdout (--out is for --file)"
        return 0
    fi
    [ -d "$d" ] || _bounded mkdir -p -- "$d" 2>/dev/null
    if [ ! -d "$d" ] || [ ! -w "$d" ] || [ ! -x "$d" ]; then
        warn "the report was not written: output directory $d is not writable by uid $(id -u 2>/dev/null || echo '?')"
        return 1
    fi
    return 0
}
# ---- end apm: output directory

# ---- apm: main — DO NOT EDIT ------------------------------------------------
# members: apmjava apmnodejs apmphp apmpython
# place: end
# The run itself; the last lines of every member. fd 3 = the terminal, saved
# before any redirection so progress() reaches the operator even in --file mode
# (which redirects both stdout and stderr). A member's own option checks that
# need warn go in its _init_probe, which runs before anything is collected.
exec 3>&2

# No arguments -> print help and stop; a collection needs an explicit action flag.
[ "$ARGC" -eq 0 ] && { usage; exit 0; }

# Modifiers alone (e.g. --quiet) are not an action — say so and show help.
if [ "$OPT_FILE" = 0 ] && [ "$OPT_STDOUT" = 0 ]; then
    printf 'no action flag given — need --file or --stdout\n' >&2
    usage >&2
    exit 2
fi

_run_init
_init_probe
_out_check || exit 1
if [ "$OPT_STDOUT" = 1 ]; then
    progress "collecting facts (read-only) -> stdout"
    run_report
    progress "done."
else
    HOST="${TARGET#host/}"   # the name TARGET already resolved, not a second lookup
    TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    OUTFILE="${OPT_OUT:-.}/$COLLECTOR_NAME-$HOST-$TS.txt"
    progress "collecting facts (read-only) -> writing $OUTFILE"
    _report_to_file "$OUTFILE" || exit 1
    progress "report written: $OUTFILE"
fi
# ---- end apm: main
