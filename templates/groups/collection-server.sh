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
#   from the skeleton blocks: fact, have, warn, _indent, _bounded, _tab, _nl,
#     CMD_TIMEOUT
#   systemd:          _tmp_dir (the run's private directory, for the hung mark)
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
