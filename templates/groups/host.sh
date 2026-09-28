# templates/groups/host.sh — owner of the host group blocks
# shellcheck shell=bash disable=SC2154,SC2034  # a fragment: the members set these names
# -----------------------------------------------------------------------------
# NOT A SCRIPT. Nothing sources this file: every collector stays one file that
# runs by itself (CONTRACT rule 3). The blocks below are copied verbatim into
# their members by
#   tools/sync-shared-block.sh --apply     (--check reports drift)
# the same way the skeleton's blocks reach every collector.
#
# The host group is the collectors that run on the host of the agent they
# describe and scan its /proc for it (db, nms). k8s is not a member: it has
# its own _classify_err (kubectl's errors) and no /proc scan.
#
# The block format (banner, `# members:`, STRAY, `place: end`) is defined once
# in [tools/sync-shared-block.sh](../../tools/sync-shared-block.sh); this file
# only adds what the host group's blocks need, below.
#
# To change a helper here: edit this file, run --apply, bump each member's
# VERSION and add its CHANGELOG entry, and compare the members' reports before
# and after. To add a helper: it goes in only when it behaves the same in
# every member; one that differs stays in its collector.
#
# What the blocks rely on the members to define (before any call, at run time):
#   _errfile (set by _run_init)
# Shell: bash 3.2+ and POSIX sh/dash (nms runs under both).
# -----------------------------------------------------------------------------

# ---- host: helpers — DO NOT EDIT --------------------------------------------
# members: db nms
# _classify_err -> the reason a probe failed, from _errfile: permission denied,
# path not found, else the first line of the error (100 bytes)
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

# _proc_hidden -> 0 when a non-root run sees /proc through hidepid=1|2|
# invisible|noaccess, i.e. other users' processes are hidden or unreadable.
# PROC_STATE says what the run knows about /proc visibility, for [1].
PROC_STATE=""
_proc_hidden() {
    # hidepid=1|noaccess: other users' /proc/<pid> entries are listed but not
    # readable; hidepid=2|invisible: they are not listed at all. A run holding
    # the gid= group is exempt. Unread mountinfo is not "no hidepid".
    local o hp g
    if [ "$(id -u 2>/dev/null)" = 0 ]; then PROC_STATE="run as root (hidepid does not apply)"; return 1; fi
    if [ ! -r /proc/self/mountinfo ]; then
        PROC_STATE="n/a (/proc/self/mountinfo not readable; visibility of other users' processes unknown)"; return 0
    fi
    # the last /proc mount in mountinfo is the one on top
    o="$(awk '$5 == "/proc" {o = $6 "," $NF} END {print o}' /proc/self/mountinfo 2>/dev/null)"
    if [ -z "$o" ]; then
        PROC_STATE="n/a (no /proc mount in /proc/self/mountinfo; visibility of other users' processes unknown)"; return 0
    fi
    hp="$(printf '%s' "$o" | tr ',' '\n' | sed -n 's/^hidepid=//p' | tail -n1)"
    g="$(printf '%s' "$o" | tr ',' '\n' | sed -n 's/^gid=//p' | tail -n1)"
    case "$hp" in
        ""|0|off) PROC_STATE="no hidepid option on the /proc mount"; return 1 ;;
    esac
    if [ -n "$g" ] && id -G 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
        PROC_STATE="mounted with hidepid=$hp, gid=$g, a group of this run (other users' processes readable)"; return 1
    fi
    case "$hp" in
        1|noaccess) PROC_STATE="mounted with hidepid=$hp${g:+ (gid=$g is not a group of this run)}: other users' /proc/<pid> entries listed but not readable" ;;
        *)          PROC_STATE="mounted with hidepid=$hp${g:+ (gid=$g is not a group of this run)}: other users' processes not listed" ;;
    esac
    return 0
}

# _self_tree -> " pid " for this collector and each of its ancestors, so the
# shell that started the collector is never counted as a component process
_self_tree() {
    local p="$$" n=0
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$n" -lt 30 ]; do
        printf ' %s ' "$p"
        p="$(awk '/^PPid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)"
        n=$((n + 1))
    done
}
# ---- end host: helpers
